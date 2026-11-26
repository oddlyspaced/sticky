# Sticky

A checklist that lives in the macOS menu bar, with an optional SketchyBar item
and a CLI that Claude Code uses to add, tick, and remind.

All front ends read and write the same two files:

| File | Content |
| --- | --- |
| `~/.claude/sticky/items.json` | Current items and tag colors |
| `~/.claude/sticky/log.jsonl` | Append-only history of every change |

Writers hold an `flock` on `~/.claude/sticky/.lock` and replace `items.json`
atomically, so the app, the CLI, and SketchyBar can change the list at the
same time.

## Features

- Menu bar panel (SwiftUI `MenuBarExtra`): add, tick, edit, reorder, remove.
- Tags: write `#tag` in any item. Each tag has a color; filter by tag chips.
- Reminders: optional time per item. The app posts a macOS notification.
- Log tab: every change grouped by day, with the time and the source
  (`app`, `cli`, `claude`, `sketchybar`).
- SketchyBar item: open-item count, popup to tick items off, Add dialog.
- CLI `sticky` for the shell and for Claude Code.

## Requirements

- macOS 14 or later, Xcode command-line tools (`swiftc`)
- Python 3
- Optional: [SketchyBar](https://github.com/FelixKratz/SketchyBar) with a Nerd Font

## Install

The paths are fixed: clone into `~/.claude/sticky`.

```sh
git clone git@github.com:oddlyspaced/sticky.git ~/.claude/sticky
~/.claude/sticky/build.sh
```

`build.sh` does these steps:

1. Compiles `app/Sticky.swift` into `~/Applications/Sticky.app` (ad-hoc signed).
2. Links `sticky.py` to `~/.local/bin/sticky`.
3. Installs the LaunchAgent `com.hardik.sticky`, which starts the app at login.

On the first reminder, macOS asks to allow notifications for Sticky. If you
deny it, the app falls back to `osascript` notifications.

## CLI

```sh
sticky add "Renew SSL cert #ops" "Reply to Priya"   # one item per argument
sticky add -t work -r "2:50pm" "Interview"          # tag + reminder
sticky list [--open] [--tag work] [--json|--tsv]
sticky done 2 | undo 2 | rm "SSL" | edit 3 "New text #tag"
sticky tag 3 work | untag 3 work
sticky remind 3 "tomorrow 9am"                      # "off" clears
sticky tags
sticky color work blue    # red orange yellow green teal blue purple pink grey
sticky clear              # remove ticked items
sticky log -n 20
```

Reminder times: `14:50`, `2:50pm`, `tomorrow 9am`, `+30m`, `+2h`,
`2026-12-01 10:00`. A bare time that is already past means tomorrow.

`--source <name>` (or `STICKY_SOURCE`) sets the name written to the log.

## SketchyBar

1. Link the scripts into your config:

   ```sh
   ln -s ~/.claude/sticky/sketchybar/items/sticky.sh   ~/.config/sketchybar/items/sticky.sh
   ln -s ~/.claude/sticky/sketchybar/plugins/sticky.sh ~/.config/sketchybar/plugins/sticky.sh
   ```

2. Add `source "$ITEM_DIR/sticky.sh"` to `sketchybarrc`.
3. Define these variables in the files your `sketchybarrc` sources:
   - Icons: `ICON_STICKY`, `ICON_BOX_OPEN`, `ICON_PLUS`, `ICON_BELL`
     (Material Design glyphs U+F0756, U+F0131, U+F0415, U+F009A).
   - Colors (Catppuccin names): `YELLOW RED PEACH GREEN TEAL BLUE MAUVE PINK
     TEXT SUBTEXT OVERLAY SURFACE0 SURFACE1 BASE`.

The CLI and the app run `sketchybar --trigger sticky_update` after each change.

Left-click opens the popup; click an item to tick it off. Right-click opens the
Add dialog.

## Claude Code

Append `claude/CLAUDE-snippet.md` to `~/.claude/CLAUDE.md`. Claude then runs
`sticky --source claude …` when you ask it to add, tick, or remind.

## Layout

```
app/Sticky.swift        menu bar app
sticky.py               CLI
build.sh                build + install
sketchybar/             SketchyBar item and plugin
claude/CLAUDE-snippet.md  instructions for Claude Code
```
