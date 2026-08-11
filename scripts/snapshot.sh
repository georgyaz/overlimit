#!/bin/bash
# snapshot.sh - snapshots Claude usage limits into a CSV. Run by launchd every 5 min.
# Installed copy: ~/.overlimit/snapshot.sh
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
  # token expired between the check and the call - force a refresh and retry once
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
                 l.get("resets_at") or "",          # None -> empty, otherwise the parser breaks
                 l.get("is_active","")])
for r in rows:
    print(",".join(str(x) for x in r))
' >> "$CSV"

# --- record the outcome of closed windows ---
# A changed resets_at means the previous window has closed.
# Append the final known percentage to history.csv.
# The response body goes to a temp file: the heredoc below occupies stdin,
# so the JSON cannot be piped in.
printf '%s' "$BODY" > "$DIR/.last-body.json"
python3 - "$DIR/.last-body.json" "$CSV" "$DIR/history.csv" <<'PYEOF'
import sys, json, csv, os, datetime

body = json.load(open(sys.argv[1]))
csv_path, hist_path = sys.argv[2], sys.argv[3]

# current resets_at for every limit
now_resets = {}
for l in body.get("limits") or []:
    model = ((l.get("scope") or {}).get("model") or {}).get("display_name") or ""
    if l.get("kind", "").startswith("weekly"):
        now_resets[(l["kind"], model)] = l.get("resets_at") or ""

if not os.path.exists(csv_path):
    sys.exit(0)

# last state from the log (previous snapshot)
rows = list(csv.DictReader(open(csv_path)))
if not rows:
    sys.exit(0)
# this block runs AFTER the append, so the newest stamp is the current snapshot.
# Treat the second-newest unique timestamp as the previous one.
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
    raw_new = now_resets.get(key) or ""
    new_r, old_r = parse(raw_new), parse(old["resets_at"])
    if not old_r:
        continue
    # At rollover the API returns an EMPTY resets_at before publishing the new
    # one, so "empty now, filled before" is itself a rollover. Missing this is
    # how the first real reset went unrecorded.
    rolled = (not raw_new) or (new_r and abs((new_r - old_r).total_seconds()) > 3600)
    # fractional seconds in resets_at differ on every call - compare with tolerance
    if rolled:
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
