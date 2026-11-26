#!/usr/bin/env python3
"""Sticky: a menu bar checklist shared by the macOS app, SketchyBar, the shell, and Claude.

State:  ~/.claude/sticky/items.json   {"items": [...], "tags": {name: color}}
Log:    ~/.claude/sticky/log.jsonl    append-only history of every change
Lock:   ~/.claude/sticky/.lock        flock held during read-modify-write

Tags: write #tag anywhere in an item's text (or pass --tag). Each tag gets a
color from PALETTE; change it with `sticky color <tag> <color>`.
The menu bar app (Sticky.app) uses the same files, lock, and palette.
"""
import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import uuid
import zlib
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

DIR = os.path.join(os.path.expanduser("~"), ".claude", "sticky")
ITEMS = os.path.join(DIR, "items.json")
LOG = os.path.join(DIR, "log.jsonl")
LOCK = os.path.join(DIR, ".lock")

# Keep in sync with Sticky.swift (TagColor) and sketchybar plugins/sticky.sh.
PALETTE = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "grey"]
TAG_RE = re.compile(r"(?<![\w#])#([A-Za-z0-9][\w-]{0,29})")


def now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


@contextmanager
def locked():
    os.makedirs(DIR, exist_ok=True)
    with open(LOCK, "a") as lf:
        fcntl.flock(lf, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lf, fcntl.LOCK_UN)


def load():
    try:
        with open(ITEMS) as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            data.setdefault("tags", {})
            for it in data["items"]:
                it.setdefault("tags", [])
            return data
    except (OSError, ValueError):
        pass
    return {"items": [], "tags": {}}


def save(data):
    tmp = f"{ITEMS}.{os.getpid()}.tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, ITEMS)


def log(action, item, source, **extra):
    entry = {"ts": now(), "action": action, "id": item["id"], "text": item["text"],
             "tags": item.get("tags", []), "source": source, **extra}
    with open(LOG, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def notify_bar():
    """Tell SketchyBar to repaint the sticky item, if SketchyBar runs."""
    for bar in ("/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"):
        if os.path.exists(bar):
            subprocess.run([bar, "--trigger", "sticky_update"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
            return


def norm_tag(t):
    return t.lstrip("#").strip().lower()


def split_tags(text):
    """'Fix login #work #urgent' -> ('Fix login', ['work', 'urgent'])."""
    tags = [norm_tag(m) for m in TAG_RE.findall(text)]
    clean = " ".join(TAG_RE.sub("", text).split())
    return clean, list(dict.fromkeys(tags))


def tag_color(data, tag):
    """Assigned color, or a stable default from the tag name."""
    c = data["tags"].get(tag)
    if c in PALETTE:
        return c
    return PALETTE[zlib.crc32(tag.encode()) % (len(PALETTE) - 1)]  # never default to grey


def register_tags(data, tags):
    for t in tags:
        if t not in data["tags"]:
            data["tags"][t] = tag_color(data, t)


def parse_when(text):
    """'14:50', '2:50pm', '2:50 PM', 'tomorrow 9am', '+30m', '+2h', '2026-12-01 10:00'
    -> aware UTC datetime. A bare time already past today means tomorrow."""
    t = " ".join(text.lower().split())
    local_now = datetime.now().astimezone()
    m = re.fullmatch(r"\+(\d+)\s*(m|min|h|hr|d)", t)
    if m:
        n, u = int(m.group(1)), m.group(2)[0]
        delta = {"m": timedelta(minutes=n), "h": timedelta(hours=n), "d": timedelta(days=n)}[u]
        return (local_now + delta).astimezone(timezone.utc)
    day = local_now.date()
    explicit_day = False
    if t.startswith("tomorrow"):
        day = day + timedelta(days=1); t = t[len("tomorrow"):].strip(); explicit_day = True
    elif t.startswith("today"):
        t = t[len("today"):].strip(); explicit_day = True
    else:
        m = re.match(r"(\d{4}-\d{2}-\d{2})[ t]?(.*)", t)
        if m:
            day = datetime.strptime(m.group(1), "%Y-%m-%d").date(); t = m.group(2).strip(); explicit_day = True
    m = re.fullmatch(r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?", t or "9am")
    if not m:
        sys.exit(f"sticky: cannot read time '{text}'. Try 14:50, 2:50pm, tomorrow 9am, +30m")
    h, mi, ap = int(m.group(1)), int(m.group(2) or 0), m.group(3)
    if ap == "pm" and h < 12:
        h += 12
    if ap == "am" and h == 12:
        h = 0
    if h > 23 or mi > 59:
        sys.exit(f"sticky: cannot read time '{text}'")
    when = datetime(day.year, day.month, day.day, h, mi, tzinfo=local_now.tzinfo)
    if when <= local_now and not explicit_day:
        when += timedelta(days=1)
    return when.astimezone(timezone.utc)


def fmt_when(iso):
    w = datetime.fromisoformat(iso).astimezone()
    today = datetime.now().astimezone().date()
    day = "" if w.date() == today else ("tomorrow " if w.date() == today + timedelta(days=1) else w.strftime("%d %b "))
    return day + w.strftime("%H:%M")


def set_remind(it, when):
    if when is None:
        it.pop("remind", None); it.pop("reminded", None)
    else:
        it["remind"] = when.isoformat(timespec="seconds"); it["reminded"] = False


def find(items, ref):
    """Resolve a 1-based index, an id, or a unique text fragment."""
    if ref.isdigit():
        i = int(ref) - 1
        if 0 <= i < len(items):
            return items[i]
    for it in items:
        if it["id"] == ref:
            return it
    hits = [it for it in items if ref.lower() in it["text"].lower()]
    if len(hits) == 1:
        return hits[0]
    if len(hits) > 1:
        sys.exit(f"sticky: '{ref}' matches {len(hits)} items; use the number from 'sticky list'")
    sys.exit(f"sticky: no item matches '{ref}'")


def show(data, show_all=True, tag=None):
    items = data["items"]
    shown = 0
    for n, it in enumerate(items, 1):
        if not show_all and it["done"]:
            continue
        if tag and tag not in it["tags"]:
            continue
        tags = "  " + " ".join("#" + t for t in it["tags"]) if it["tags"] else ""
        rem = f"  ⏰ {fmt_when(it['remind'])}" if it.get("remind") and not it["done"] else ""
        print(f"{n:>3}. [{'x' if it['done'] else ' '}] {it['text']}{tags}{rem}")
        shown += 1
    if not shown:
        print("(empty)")


def main():
    p = argparse.ArgumentParser(prog="sticky", description="Menu bar checklist. Use #tag in text to tag items.")
    p.add_argument("--source", default=os.environ.get("STICKY_SOURCE", "cli"),
                   help="who made the change, written to the log (default: cli)")
    sub = p.add_subparsers(dest="cmd")
    a = sub.add_parser("add", help="add one or more items; #tags in the text become tags")
    a.add_argument("text", nargs="+", help="each argument is one item")
    a.add_argument("-t", "--tag", action="append", default=[], help="tag every new item (repeatable)")
    a.add_argument("-r", "--remind", help="notify at this time: 14:50, 2:50pm, tomorrow 9am, +30m")
    rm_ = sub.add_parser("remind", help="set or clear an item's reminder ('off' clears)")
    rm_.add_argument("ref")
    rm_.add_argument("when", nargs="+")
    for name, hlp in [("done", "tick an item off"), ("undo", "untick an item"),
                      ("rm", "remove an item")]:
        s = sub.add_parser(name, help=hlp)
        s.add_argument("ref", nargs="+", help="item number, id, or unique text fragment")
    e = sub.add_parser("edit", help="change an item's text (#tags in it replace the item's tags)")
    e.add_argument("ref")
    e.add_argument("text")
    tg = sub.add_parser("tag", help="add tags to an item")
    tg.add_argument("ref")
    tg.add_argument("tags", nargs="+")
    ut = sub.add_parser("untag", help="remove tags from an item")
    ut.add_argument("ref")
    ut.add_argument("tags", nargs="+")
    sub.add_parser("tags", help="list tags with colors and counts")
    co = sub.add_parser("color", help=f"set a tag's color: {', '.join(PALETTE)}")
    co.add_argument("tag")
    co.add_argument("color", choices=PALETTE)
    l = sub.add_parser("list", help="show items (default command)")
    l.add_argument("--open", action="store_true", help="hide ticked items")
    l.add_argument("--tag", help="only items with this tag")
    l.add_argument("--json", action="store_true")
    l.add_argument("--tsv", action="store_true",
                   help="id<TAB>done<TAB>text<TAB>tag:color,...<TAB>remind-local-HH:MM  (for scripts)")
    sub.add_parser("clear", help="remove all ticked items")
    g = sub.add_parser("log", help="show recent history")
    g.add_argument("-n", type=int, default=20)
    args = p.parse_args()
    src = args.source

    if args.cmd in (None, "list"):
        data = load()
        tag = norm_tag(args.tag) if getattr(args, "tag", None) else None
        if getattr(args, "json", False):
            print(json.dumps(data, indent=2, ensure_ascii=False))
        elif getattr(args, "tsv", False):
            for it in data["items"]:
                tags = ",".join(f"{t}:{tag_color(data, t)}" for t in it["tags"])
                rem = fmt_when(it["remind"]) if it.get("remind") else ""
                print(f"{it['id']}\t{int(it['done'])}\t{it['text']}\t{tags}\t{rem}")
        else:
            show(data, not getattr(args, "open", False), tag)
        return

    if args.cmd == "tags":
        data = load()
        counts = {}
        for it in data["items"]:
            for t in it["tags"]:
                counts[t] = counts.get(t, 0) + 1
        names = sorted(set(counts) | set(data["tags"]))
        if not names:
            print("(no tags)")
        for t in names:
            print(f"#{t:<20} {tag_color(data, t):<7} {counts.get(t, 0)} item(s)")
        return

    if args.cmd == "log":
        try:
            with open(LOG) as f:
                lines = f.readlines()[-args.n:]
        except OSError:
            lines = []
        day = None
        for ln in lines:
            try:
                e = json.loads(ln)
            except ValueError:
                continue
            t = datetime.fromisoformat(e["ts"]).astimezone()
            if t.date() != day:
                day = t.date()
                print(f"\n{t.strftime('%a %d %b %Y')}")
            tags = " " + " ".join("#" + x for x in e.get("tags", [])) if e.get("tags") else ""
            print(f"  {t.strftime('%H:%M')}  {e['action']:<6} {e['text']}{tags}  ({e.get('source', '?')})")
        return

    with locked():
        data = load()
        items = data["items"]
        if args.cmd == "add":
            extra = [norm_tag(t) for t in args.tag if norm_tag(t)]
            when = parse_when(args.remind) if args.remind else None
            for raw in args.text:
                text, tags = split_tags(raw)
                tags = list(dict.fromkeys(tags + extra))
                if not text:
                    continue
                it = {"id": uuid.uuid4().hex[:8], "text": text, "tags": tags, "done": False,
                      "created": now(), "source": src}
                if when:
                    set_remind(it, when)
                register_tags(data, tags)
                items.append(it)
                log("add", it, src)
        elif args.cmd in ("done", "undo"):
            for it in [find(items, r) for r in args.ref]:
                it["done"] = args.cmd == "done"
                log("done" if it["done"] else "undo", it, src)
        elif args.cmd == "rm":
            for it in [find(items, r) for r in args.ref]:
                items.remove(it)
                log("remove", it, src)
        elif args.cmd == "edit":
            it = find(items, args.ref)
            text, tags = split_tags(args.text)
            it["text"] = text or it["text"]
            if tags:
                it["tags"] = tags
                register_tags(data, tags)
            log("edit", it, src)
        elif args.cmd in ("tag", "untag"):
            it = find(items, args.ref)
            names = [norm_tag(t) for t in args.tags if norm_tag(t)]
            if args.cmd == "tag":
                it["tags"] = list(dict.fromkeys(it["tags"] + names))
                register_tags(data, names)
            else:
                it["tags"] = [t for t in it["tags"] if t not in names]
            log(args.cmd, it, src)
        elif args.cmd == "remind":
            it = find(items, args.ref)
            w = " ".join(args.when)
            set_remind(it, None if w.lower() in ("off", "none", "clear") else parse_when(w))
            log("remind", it, src, remind=it.get("remind"))
        elif args.cmd == "color":
            data["tags"][norm_tag(args.tag)] = args.color
        elif args.cmd == "clear":
            for it in [i for i in items if i["done"]]:
                items.remove(it)
                log("remove", it, src)
        save(data)
    notify_bar()
    if args.cmd == "color":
        print(f"#{norm_tag(args.tag)} is now {args.color}")
    else:
        show(load())


if __name__ == "__main__":
    main()
