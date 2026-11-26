#!/usr/bin/env bash
# Sticky tile brain.
#   - repaint label and popup rows on sticky_update / routine / system_woke
#   - left-click: toggle popup; right-click: open "Add item…" dialog
#   - mouse.exited.global: close popup
# Data comes from `sticky list --tsv` (id<TAB>done<TAB>text).
source "$HOME/.config/sketchybar/icons.sh"
source "$HOME/.config/sketchybar/colors.sh"

STICKY="$HOME/.local/bin/sticky"
MAX_ROWS=15

add_dialog() {
  local text
  text=$(osascript -e 'text returned of (display dialog "Add to Sticky:" default answer "" with title "Sticky" buttons {"Cancel", "Add"} default button "Add")' 2>/dev/null) || return
  [ -n "$text" ] && "$STICKY" --source sketchybar add "$text" >/dev/null
}

# Tag color names (sticky.py PALETTE) -> Catppuccin colors.
tag_color() {
  case "$1" in
    red) echo "$RED" ;; orange) echo "$PEACH" ;; yellow) echo "$YELLOW" ;;
    green) echo "$GREEN" ;; teal) echo "$TEAL" ;; blue) echo "$BLUE" ;;
    purple) echo "$MAUVE" ;; pink) echo "$PINK" ;; *) echo "$OVERLAY" ;;
  esac
}

render() {
  local open=0 total=0 rows=()
  while IFS=$'\037' read -r id done text tags remind; do
    [ -z "$id" ] && continue
    total=$((total + 1))
    if [ "$done" = "0" ]; then
      open=$((open + 1))
      rows+=("$id"$'\t'"$text"$'\t'"$tags"$'\t'"$remind")
    fi
  done < <("$STICKY" list --tsv 2>/dev/null | tr '\t' '\037')

  if [ "$open" -gt 0 ]; then
    sketchybar --set "$NAME" icon.color="$YELLOW" icon.padding_right=4 label.drawing=on label="$open"
  else
    sketchybar --set "$NAME" icon.color="$SUBTEXT" icon.padding_right=10 label.drawing=off
  fi

  # Rebuild popup rows.
  sketchybar --remove '/sticky\.row\..*/' >/dev/null 2>&1
  local args=() i=0 row id text tags remind rest first color tagtxt
  for row in "${rows[@]:0:$MAX_ROWS}"; do
    id="${row%%$'\t'*}"; rest="${row#*$'\t'}"
    text="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
    tags="${rest%%$'\t'*}"; remind="${rest#*$'\t'}"
    [ "${#text}" -gt 44 ] && text="${text:0:43}…"
    # Checkbox takes the first tag's color; tag names follow the text.
    color="$SUBTEXT"; tagtxt=""
    if [ -n "$tags" ]; then
      first="${tags%%,*}"; color=$(tag_color "${first#*:}")
      tagtxt="  $(echo "$tags" | sed -E 's/:[a-z]+//g; s/(^|,)/ #/g; s/^ //')"
    fi
    args+=(--add item "sticky.row.$i" popup."$NAME"
           --set "sticky.row.$i"
             icon="$ICON_BOX_OPEN" icon.color="$color" icon.padding_left=10
             label="$text$tagtxt${remind:+  $ICON_BELL $remind}" label.color="$TEXT" label.padding_right=12
             background.drawing=off
             click_script="$STICKY --source sketchybar done $id >/dev/null")
    i=$((i + 1))
  done
  if [ "$open" -gt "$MAX_ROWS" ]; then
    args+=(--add item sticky.row.more popup."$NAME"
           --set sticky.row.more icon.drawing=off label="+$((open - MAX_ROWS)) more in Sticky"
             label.color="$OVERLAY" label.padding_left=12 background.drawing=off)
  fi
  [ "$open" -eq 0 ] && args+=(--add item sticky.row.empty popup."$NAME"
           --set sticky.row.empty icon.drawing=off label="All done" label.color="$OVERLAY"
             label.padding_left=12 background.drawing=off)
  args+=(--add item sticky.row.add popup."$NAME"
         --set sticky.row.add icon="$ICON_PLUS" icon.color="$GREEN" icon.padding_left=10
           label="Add item…" label.color="$SUBTEXT" background.drawing=off
           click_script="sketchybar --set $NAME popup.drawing=off; $PLUGIN_DIR/sticky.sh add")
  sketchybar "${args[@]}" >/dev/null
}

# Called from the "Add item…" row's click_script.
if [ "$1" = "add" ]; then add_dialog; exit 0; fi

case "$SENDER" in
  mouse.clicked)
    if [ "$BUTTON" = "right" ]; then
      add_dialog
    else
      render
      sketchybar --set "$NAME" popup.drawing=toggle
    fi
    ;;
  mouse.exited.global)
    sketchybar --set "$NAME" popup.drawing=off
    ;;
  *)
    render
    ;;
esac
