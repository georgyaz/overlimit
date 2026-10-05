#!/bin/bash
# Opened by the panel's sign-in button. Terminal.app runs .command files in a
# real TTY, which `claude auth login` needs; the browser opens from there.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
echo "Overlimit: signing in to Claude Code..."
echo
claude auth login || { echo; echo "Sign-in failed. Close this window and try again."; read -r; exit 1; }
echo
echo "Signed in. Taking the first snapshot..."
"$HOME/.overlimit/snapshot.sh" && echo "Done. You can close this window." || echo "Snapshot failed; see ~/.overlimit/usage-log.err"
sleep 2
