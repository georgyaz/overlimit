#!/bin/bash
# watch.sh - keeps the panel running while Claude is open.
# Run by the app.overlimit.watch launchd agent every 300 s.
#
# Rules:
#   - panel already up -> do nothing;
#   - Claude closed -> hide the panel, reset the close counter;
#   - closed twice in a row -> stop relaunching it
#     until Claude itself restarts (compared by process id).

APP="$HOME/Applications/Overlimit.app"
NOAUTO="$HOME/.overlimit/no-autostart"
NOAUTO="$HOME/.overlimit/no-autostart"
STATE="$HOME/.overlimit/panel-state"
MAX_CLOSES=2

# IMPORTANT: pgrep -f cannot see the main Claude process - its command-line
# arguments are unreadable under hardened runtime, only helpers show up.
# So match on comm via ps, where the executable path is visible.
claude_pid() {
  ps -A -o pid=,comm= \
    | sed -n 's#^ *\([0-9][0-9]*\) /Applications/Claude.app/Contents/MacOS/Claude$#\1#p' \
    | head -1
}
PANEL_EXE="Overlimit.app/Contents/MacOS/Overlimit"
panel_pid() {
  ps -A -o pid=,comm= | grep -F "$PANEL_EXE" | awk '{print $1}' | head -1
}
panel_running() { [ -n "$(panel_pid)" ]; }
kill_panel() { P=$(panel_pid); [ -n "$P" ] && kill "$P" 2>/dev/null; }

closes=0; last_pid=""; was_up=0
[ -f "$STATE" ] && . "$STATE"

save() {
  printf 'closes=%s\nlast_pid="%s"\nwas_up=%s\n' "$closes" "$last_pid" "$was_up" > "$STATE"
}

# Quit sets a flag - never relaunch until started manually
if [ -f "$NOAUTO" ]; then
  exit 0
fi

# Quit from the menu sets a flag - do not relaunch until started manually
if [ -f "$NOAUTO" ]; then exit 0; fi

CPID=$(claude_pid)

# Claude is not running: hide the panel and reset state
if [ -z "$CPID" ]; then
  panel_running && kill_panel
  closes=0; last_pid=""; was_up=0
  save
  exit 0
fi

# Claude restarted (different pid) - reset the close counter
if [ "$CPID" != "$last_pid" ]; then
  closes=0
  last_pid="$CPID"
fi

# Panel is up - leave it alone
if panel_running; then
  was_up=1
  save
  exit 0
fi

# Panel is gone. If it was up last time, the user closed it
if [ "$was_up" = "1" ]; then
  closes=$((closes + 1))
fi
was_up=0

if [ "$closes" -ge "$MAX_CLOSES" ]; then
  # closed twice in a row - stop relaunching entirely
  touch "$NOAUTO"
  save
  exit 0
fi

open -g "$APP" && was_up=1
save
exit 0
