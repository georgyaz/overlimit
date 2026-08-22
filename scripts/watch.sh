#!/bin/bash
# watch.sh - keeps the Overlimit process alive.
#
# The panel manages its own visibility: it shows only while Claude is
# frontmost and checks that every two seconds. So there is nothing to kill
# when Claude quits - a hidden resident process costs nothing, and killing it
# used to create a gap of up to five minutes the next morning: Claude was
# already open while the watcher had not ticked yet.
#
# The watcher's whole job:
#   - start the panel at login (RunAtLoad) and restart it if it ever dies;
#   - respect the no-autostart flag written by Quit in the menu.
#     The flag is cleared when the app is started manually.

APP="$HOME/Applications/Overlimit.app"
NOAUTO="$HOME/.overlimit/no-autostart"

[ -f "$NOAUTO" ] && exit 0

# pgrep -f cannot see processes with unreadable arguments (hardened runtime),
# so match on comm via ps, where the executable path is visible.
P=$(ps -A -o comm= | grep -cF "Overlimit.app/Contents/MacOS/Overlimit")
[ "$P" -ge 1 ] && exit 0

open -g "$APP"
exit 0
