#!/usr/bin/env bash
# Sticky checklist: icon + count of open items. Left-click opens a popup of
# open items (click one to tick it off) and an "Add item…" row. The sticky CLI
# and Sticky.app fire `sticky_update` after every change, so the item repaints
# at once; update_freq is only a fallback.

sketchybar --add event sticky_update \
           --add item sticky right \
           --set sticky \
                 icon="$ICON_STICKY" \
                 icon.color=$YELLOW \
                 label.color=$TEXT \
                 background.color=$SURFACE0 \
                 update_freq=120 \
                 popup.align=right \
                 popup.background.color=$BASE \
                 popup.background.border_color=$SURFACE1 \
                 popup.background.border_width=1 \
                 popup.background.corner_radius=9 \
                 popup.y_offset=4 \
                 script="$PLUGIN_DIR/sticky.sh" \
           --subscribe sticky sticky_update mouse.clicked mouse.exited.global system_woke
