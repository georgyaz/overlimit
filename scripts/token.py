#!/usr/bin/env python3
"""token.py - returns a valid access token, refreshing it when needed.

The source of truth is the macOS keychain (service "Claude Code-credentials"),
the same entry Claude Code CLI uses. When the access token has expired it is
refreshed via the refresh token and written back to that entry, so the CLI and
this tool never drift apart.

Usage:  python3 token.py           -> prints the access token
        python3 token.py --force   -> force a refresh
"""
import json, subprocess, sys, time, urllib.request, urllib.error

SERVICE = "Claude Code-credentials"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
# The endpoint moved from console.anthropic.com to platform.claude.com;
# the old one is kept as a fallback in case it moves back.
TOKEN_URLS = ["https://platform.claude.com/v1/oauth/token",
              "https://console.anthropic.com/v1/oauth/token"]
SKEW_MS = 5 * 60 * 1000          # refresh 5 minutes before expiry
BACKOFF = "/tmp/.overlimit-refresh-backoff"


def keychain_account():
    """The acct field of the CLI keychain entry (the macOS username).
    Writing with a different acct silently creates a SECOND entry while the CLI
    keeps reading the old one - and since refresh tokens rotate, that breaks
    the CLI's authentication."""
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
        raise SystemExit("keychain: entry not found")
    return json.loads(out.stdout)


def write_keychain(data):
    acct = keychain_account()
    if not acct:
        raise SystemExit("keychain: acct unknown, refusing to write")
    subprocess.run(["security", "add-generic-password", "-U", "-s", SERVICE,
                    "-a", acct, "-w", json.dumps(data)],
                   capture_output=True, text=True, check=True)


def refresh(data):
    """Refreshes the token. Backs off for 30 minutes on HTTP 429."""
    try:
        until = float(open(BACKOFF).read().strip())
        if time.time() < until:
            raise SystemExit("refresh: backing off after 429, %d s left" % (until - time.time()))
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
                    f.write(str(time.time() + 1800))     # 30-minute backoff
                break
        except Exception as e:
            last = type(e).__name__
    if not new:
        raise SystemExit("refresh: failed, last response %s" % last)

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
