#!/bin/bash
# Overlimit — uninstaller. Removes agents, app and local data.
set -uo pipefail

DIR="$HOME/.overlimit"
APP="$HOME/Applications/Overlimit.app"
AGENTS="$HOME/Library/LaunchAgents"

for label in app.overlimit.snapshot app.overlimit.watch; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null
  rm -f "$AGENTS/$label.plist"
done

P=$(ps -A -o pid=,comm= | grep -F "Overlimit.app/Contents/MacOS/Overlimit" | awk '{print $1}' | head -1)
[ -n "$P" ] && kill "$P" 2>/dev/null

rm -rf "$APP"
defaults delete app.overlimit.panel 2>/dev/null

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DIR"
  echo "Removed everything including collected data."
else
  echo "Removed app and agents. Collected data kept in $DIR"
  echo "Run with --purge to delete it too."
fi
