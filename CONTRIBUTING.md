# Contributing

This is a small tool with a small surface. Issues are as welcome as pull
requests — often more useful, because they say what people actually need.

## Good first things

**Add a language.** The `L(ru, en)` helper in `Sources/Overlimit.swift` takes
exactly two strings, which is fine for two languages and wrong for three. If
you want a third, the honest fix is turning it into a dictionary keyed by
language code. Open an issue with the language you need before doing the work —
if nobody else asks for it, a simpler patch may be enough.

**Report what breaks.** This tool depends on an undocumented endpoint and on
where Claude Code keeps its credentials. Both can change without notice. If
the panel says `data is stale` and never recovers, that is worth an issue:
include the last few lines of `~/.overlimit/usage-log.err`, your macOS version,
and the Claude Code version from `claude --version`. Never paste the contents
of the keychain entry or anything starting with `sk-ant-`.

## Building

No package manager, no dependencies:

```sh
swiftc -O -o /tmp/overlimit Sources/Overlimit.swift
```

`./install.sh` does the same and assembles the bundle, icon and launchd agents.
It is safe to re-run; it overwrites the installed copy and keeps collected data.

## Style

Comments in English. Explain *why*, not *what* — the "Known quirks" section of
the README exists because several of these decisions look arbitrary until you
know what went wrong. If you work around something surprising, leave a note
next to it.

Keep the panel readable at a glance. Every number on it has to earn its place:
the fourth row was removed once already because the colour of the first three
said the same thing.
