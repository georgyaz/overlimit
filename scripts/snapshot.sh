#!/bin/bash
# snapshot.sh — снимок лимитов Claude в CSV. Запускается по launchd раз в 5 мин.
# Рабочая копия: ~/.overlimit/snapshot.sh
set -uo pipefail

DIR="$HOME/.overlimit"
CSV="$DIR/usage-log.csv"
ERR="$DIR/usage-log.err"
mkdir -p "$DIR"

VER=$("$HOME/.local/bin/claude" --version 2>/dev/null | awk '{print $1}')
[ -z "$VER" ] && VER="2.1.223"

TOKEN=$(python3 "$DIR/token.py" 2>>"$ERR")

if [ -z "${TOKEN:-}" ]; then
  echo "$(date -u +%FT%TZ) no_token" >> "$ERR"
  exit 1
fi

RESP=$(curl -s -m 20 -w $'\n%{http_code}' "https://api.anthropic.com/api/oauth/usage" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/$VER")

CODE=$(printf '%s' "$RESP" | tail -1)
BODY=$(printf '%s' "$RESP" | sed '$d')

if [ "$CODE" = "401" ]; then
  # токен протух между проверкой и запросом — обновляем принудительно и пробуем ещё раз
  TOKEN=$(python3 "$DIR/token.py" --force 2>>"$ERR")
  if [ -n "${TOKEN:-}" ]; then
    RESP=$(curl -s -m 20 -w $'\n%{http_code}' "https://api.anthropic.com/api/oauth/usage" \
      -H "Authorization: Bearer $TOKEN" \
      -H "anthropic-beta: oauth-2025-04-20" \
      -H "User-Agent: claude-code/$VER")
    CODE=$(printf '%s' "$RESP" | tail -1)
    BODY=$(printf '%s' "$RESP" | sed '$d')
  fi
fi

if [ "$CODE" != "200" ]; then
  echo "$(date -u +%FT%TZ) http_$CODE" >> "$ERR"
  exit 1
fi

[ -f "$CSV" ] || echo "ts_utc,kind,group,model,percent,severity,resets_at,is_active" > "$CSV"

printf '%s' "$BODY" | python3 -c '
import sys, json, datetime
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
rows = []
for l in d.get("limits") or []:
    sc = l.get("scope") or {}
    model = ((sc.get("model") or {}).get("display_name")) or ""
    rows.append([now, l.get("kind",""), l.get("group",""), model,
                 l.get("percent",""), l.get("severity",""),
                 l.get("resets_at") or "",          # None -> пусто, иначе ломается парсер
                 l.get("is_active","")])
for r in rows:
    print(",".join(str(x) for x in r))
' >> "$CSV"

# --- фиксация итогов закрывшихся окон ---
# Если resets_at изменился с прошлого снапшота, значит окно закрылось.
# Дописываем в history.csv, с каким итогом оно закрылось (последнее известное значение).
# Тело ответа кладём во временный файл: heredoc ниже занимает stdin,
# поэтому передать JSON через пайп нельзя.
printf '%s' "$BODY" > "$DIR/.last-body.json"
python3 - "$DIR/.last-body.json" "$CSV" "$DIR/history.csv" <<'PYEOF'
import sys, json, csv, os, datetime

body = json.load(open(sys.argv[1]))
csv_path, hist_path = sys.argv[2], sys.argv[3]

# текущие resets_at по каждому лимиту
now_resets = {}
for l in body.get("limits") or []:
    model = ((l.get("scope") or {}).get("model") or {}).get("display_name") or ""
    if l.get("kind", "").startswith("weekly"):
        now_resets[(l["kind"], model)] = l.get("resets_at") or ""

if not os.path.exists(csv_path):
    sys.exit(0)

# последнее состояние из лога (предыдущий снапшот)
rows = list(csv.DictReader(open(csv_path)))
if not rows:
    sys.exit(0)
# блок выполняется ПОСЛЕ дозаписи, поэтому последняя метка — уже текущий снимок.
# Предыдущим считаем предпоследнюю уникальную метку времени.
stamps = sorted({r["ts_utc"] for r in rows})
if len(stamps) < 2:
    sys.exit(0)
prev_ts = stamps[-2]
prev = {(r["kind"], r["model"]): r for r in rows if r["ts_utc"] == prev_ts
        and r["kind"].startswith("weekly")}

closed = []


def parse(s):
    try:
        return datetime.datetime.fromisoformat(s)
    except Exception:
        return None


for key, old in prev.items():
    new_r, old_r = parse(now_resets.get(key) or ""), parse(old["resets_at"])
    # доли секунды в resets_at пляшут от запроса к запросу — сравниваем с допуском
    if new_r and old_r and abs((new_r - old_r).total_seconds()) > 3600:
        closed.append({"window_end": old["resets_at"], "kind": key[0],
                       "model": key[1], "final_percent": old["percent"],
                       "logged_at": datetime.datetime.now(datetime.timezone.utc)
                                    .strftime("%Y-%m-%dT%H:%M:%SZ")})

if closed:
    new_file = not os.path.exists(hist_path)
    with open(hist_path, "a", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["window_end", "kind", "model",
                                          "final_percent", "logged_at"])
        if new_file:
            w.writeheader()
        w.writerows(closed)
PYEOF
