#!/bin/bash
# Build Sticky.app into ~/Applications, link the CLI, and start the app at login.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Sticky.app"
AGENT="$HOME/Library/LaunchAgents/com.hardik.sticky.plist"

mkdir -p "$APP/Contents/MacOS" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
swiftc -O -parse-as-library -o "$APP/Contents/MacOS/Sticky" "$HERE/app/Sticky.swift"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.hardik.sticky</string>
  <key>CFBundleName</key><string>Sticky</string>
  <key>CFBundleExecutable</key><string>Sticky</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force -s - "$APP" >/dev/null

chmod +x "$HERE/sticky.py"
ln -sf "$HERE/sticky.py" "$HOME/.local/bin/sticky"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.hardik.sticky</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/Sticky</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
</dict></plist>
PLIST
launchctl bootout "gui/$(id -u)/com.hardik.sticky" 2>/dev/null || true
pkill -x Sticky 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT"
echo "Sticky built: $APP (starts at login)"
