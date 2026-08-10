#!/bin/bash
# watch.sh — держит плашку запущенной, пока открыт Claude.
# Запускается launchd-агентом app.overlimit.watch раз в 300 с.
#
# Правила:
#   - плашка уже висит → ничего не делаем;
#   - Claude закрыт → гасим плашку, счётчик закрытий обнуляем;
#   - закрыл второй раз подряд → больше не поднимаем
#     до перезапуска самого Claude (сравниваем PID приложения).

APP="$HOME/Applications/Overlimit.app"
NOAUTO="$HOME/.overlimit/no-autostart"
NOAUTO="$HOME/.overlimit/no-autostart"
STATE="$HOME/.overlimit/panel-state"
MAX_CLOSES=2

# ВАЖНО: pgrep -f не видит главный процесс Claude — у него недоступны аргументы
# командной строки (hardened runtime), находятся только helper-процессы.
# Поэтому ищем по comm через ps: там путь виден.
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

# «Выйти» ставит флаг — не поднимаем вообще, пока не запустят руками
if [ -f "$NOAUTO" ]; then
  exit 0
fi

# «Выйти» из меню ставит флаг — не поднимаем, пока не запустят руками
if [ -f "$NOAUTO" ]; then exit 0; fi

CPID=$(claude_pid)

# Claude не запущен: гасим плашку и сбрасываем состояние
if [ -z "$CPID" ]; then
  panel_running && kill_panel
  closes=0; last_pid=""; was_up=0
  save
  exit 0
fi

# Claude перезапустили (другой PID) — счётчик закрытий обнуляется
if [ "$CPID" != "$last_pid" ]; then
  closes=0
  last_pid="$CPID"
fi

# Плашка висит — ничего не трогаем
if panel_running; then
  was_up=1
  save
  exit 0
fi

# Плашки нет. Если в прошлый раз была — значит закрыли крестиком
if [ "$was_up" = "1" ]; then
  closes=$((closes + 1))
fi
was_up=0

if [ "$closes" -ge "$MAX_CLOSES" ]; then
  # закрыли второй раз подряд — больше не поднимаем совсем
  touch "$NOAUTO"
  save
  exit 0
fi

open -g "$APP" && was_up=1
save
exit 0
