# Sticky checklist

I keep a personal checklist in a macOS menu bar app (Sticky) and in SketchyBar.
`sticky` is on PATH and edits the same list. Always pass `--source claude` so
the log shows that Claude made the change.

```
sticky --source claude add "Renew SSL cert #ops" "Reply to Priya"   # one item per argument
sticky --source claude add -t work "Ship PR"        # -t/--tag tags every new item
sticky --source claude add -r "2:50pm" "Interview"   # -r/--remind: 14:50, 2:50pm, tomorrow 9am, +30m, 2026-12-01 10:00
sticky list            # numbered; --open hides ticked; --tag work filters
sticky --source claude done 2        # number, id, or unique text fragment
sticky --source claude undo 2
sticky --source claude rm "SSL"
sticky --source claude edit 3 "New text #tag"   # #tags in new text replace the item's tags
sticky --source claude tag 3 work    # / untag 3 work
sticky --source claude remind 3 "tomorrow 9am"   # "off" clears
sticky tags            # tags, colors, counts
sticky color work blue # red orange yellow green teal blue purple pink grey
sticky --source claude clear         # remove all ticked items
sticky log -n 20       # history of every change, grouped by day
```

- `#word` inside item text becomes a tag. Reuse an existing tag (`sticky tags`)
  before you invent a new one.
- When I give a time to be reminded ("remind me at 2:50"), use `-r`. The app
  shows a macOS notification at that time.
- Add, tick, or remove items only when I ask ("add X to my list", "tick off Y").
- Never remove an item I did not name. Show `sticky list` after a change.
- Data: `~/.claude/sticky/items.json` (list) and `log.jsonl` (append-only log).
  Do not edit these files directly; use the CLI, which holds the file lock.
