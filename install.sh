#!/bin/bash
# Overlimit — installer. Builds the app, installs launchd agents, starts everything.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
DIR="$HOME/.overlimit"
APP="$HOME/Applications/Overlimit.app"
AGENTS="$HOME/Library/LaunchAgents"

echo "==> checking prerequisites"
command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }
if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
  echo "Claude Code credentials not found in the keychain."
  echo "Install Claude Code and sign in once:"
  echo "  curl -fsSL https://claude.ai/install.sh | bash && claude"
  exit 1
fi

echo "==> building app"
mkdir -p "$DIR" "$APP/Contents/MacOS" "$APP/Contents/Resources" "$AGENTS"
swiftc -O -o "$DIR/overlimit" "$REPO"/Sources/*.swift

echo "==> building icon"
swiftc -O -o "$DIR/make-icon" "$REPO/Tools/MakeIcon.swift"
rm -rf "$DIR/AppIcon.iconset"
"$DIR/make-icon" "$DIR/AppIcon.iconset" >/dev/null
iconutil -c icns "$DIR/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> assembling bundle"
cp "$DIR/overlimit" "$APP/Contents/MacOS/Overlimit"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Overlimit</string>
    <key>CFBundleIdentifier</key><string>app.overlimit.panel</string>
    <key>CFBundleExecutable</key><string>Overlimit</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST
codesign --force -s - "$APP" >/dev/null 2>&1 || true

echo "==> installing scripts"
cp "$REPO/scripts/snapshot.sh" "$REPO/scripts/watch.sh" "$REPO/scripts/token.py" "$DIR/"
chmod +x "$DIR/snapshot.sh" "$DIR/watch.sh"

echo "==> installing launchd agents"
for label in app.overlimit.snapshot app.overlimit.watch; do
  sed "s|__HOME__|$HOME|g" "$REPO/launchd/$label.plist" > "$AGENTS/$label.plist"
  plutil -lint "$AGENTS/$label.plist" >/dev/null
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$label.plist"
done

echo "==> first snapshot"
"$DIR/snapshot.sh" || { echo "snapshot failed, see $DIR/usage-log.err"; exit 1; }

rm -f "$DIR/no-autostart"

# A running copy must be stopped first: `open` on an already-running app does
# nothing, so the freshly built binary would sit unused until the next reboot.
RUNNING=$(ps -A -o pid=,comm= | grep -F "Overlimit.app/Contents/MacOS/Overlimit" | awk '{print $1}' | head -1)
[ -n "$RUNNING" ] && kill "$RUNNING" 2>/dev/null && sleep 1
open -g "$APP"
echo
echo "Done. The panel shows up when Claude Desktop is in the foreground."
echo "Right-click it for settings. Data: $DIR/usage-log.csv"
