#!/usr/bin/env python3
"""token.py — выдаёт валидный access token, обновляя его при необходимости.

Источник правды — связка ключей macOS (сервис "Claude Code-credentials"),
та же, что использует Claude Code CLI. Если access token протух, обновляем его
по refresh-токену и пишем обратно в связку, чтобы CLI и этот скрипт не
разъезжались.

Использование:  python3 token.py           -> печатает access token
                python3 token.py --force   -> принудительно обновить
"""
import json, subprocess, sys, time, urllib.request, urllib.error

SERVICE = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
# Эндпоинт переехал с console.anthropic.com на platform.claude.com;
# старый оставлен запасным на случай обратного переезда.
TOKEN_URLS = ["https://platform.claude.com/v1/oauth/token",
              "https://console.anthropic.com/v1/oauth/token"]
SKEW_MS = 5 * 60 * 1000          # обновляем за 5 минут до истечения
BACKOFF = "/tmp/.overlimit-refresh-backoff"


def keychain_account():
    """Поле acct у записи CLI (у Georgy — имя пользователя macOS).
    Если писать с другим acct, создаётся ВТОРАЯ запись, а CLI продолжает
    читать старую — и его refresh-токен протухает. Так уже было 2026-08-07."""
    out = subprocess.run(["security", "find-generic-password", "-s", SERVICE],
                         capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if '"acct"' in line and '=' in line:
            return line.split('="', 1)[1].rstrip('"')
    return None


def read_keychain():
    out = subprocess.run(["security", "find-generic-password", "-s", SERVICE, "-w"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit("keychain: запись не найдена")
    return json.loads(out.stdout)


def write_keychain(data):
    acct = keychain_account()
    if not acct:
        raise SystemExit("keychain: не определён acct, запись отменена")
    subprocess.run(["security", "add-generic-password", "-U", "-s", SERVICE,
                    "-a", acct, "-w", json.dumps(data)],
                   capture_output=True, text=True, check=True)


def refresh(data):
    """Обновляет токен. При 429 ставит паузу, чтобы не долбиться в стену."""
    try:
        until = float(open(BACKOFF).read().strip())
        if time.time() < until:
            raise SystemExit("refresh: пауза после 429, ещё %d с" % (until - time.time()))
    except (FileNotFoundError, ValueError):
        pass

    oauth = data["claudeAiOauth"]
    body = json.dumps({"grant_type": "refresh_token",
                       "refresh_token": oauth["refreshToken"],
                       "client_id": CLIENT_ID}).encode()
    new, last = None, "?"
    for url in TOKEN_URLS:
        req = urllib.request.Request(url, data=body, headers={
            "Content-Type": "application/json",
            "User-Agent": "claude-cli/2.1.223 (external, cli)",
            "Accept": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                new = json.loads(r.read())
                break
        except urllib.error.HTTPError as e:
            last = str(e.code)
            if e.code == 429:
                with open(BACKOFF, "w") as f:
                    f.write(str(time.time() + 1800))     # пауза 30 минут
                break
        except Exception as e:
            last = type(e).__name__
    if not new:
        raise SystemExit("refresh: не удалось, последний ответ %s" % last)

    oauth["accessToken"] = new["access_token"]
    if new.get("refresh_token"):
        oauth["refreshToken"] = new["refresh_token"]
    oauth["expiresAt"] = int(time.time() * 1000) + int(new.get("expires_in", 3600)) * 1000
    write_keychain(data)
    return oauth["accessToken"]


if __name__ == "__main__":
    data = read_keychain()
    o = data["claudeAiOauth"]
    force = "--force" in sys.argv
    if force or o.get("expiresAt", 0) - SKEW_MS < time.time() * 1000:
        print(refresh(data))
    else:
        print(o["accessToken"])
