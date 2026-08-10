# Contributing

This is a small tool with a small surface. Issues are as welcome as pull
requests — often more useful, because they say what people actually need.

## Good first things

**Add a language.** Six are shipped: English, Russian, French, Spanish,
Portuguese, Chinese. Adding one is a block in `Sources/Translations.swift`,
keyed by the English string, plus an entry in the language submenu in
`showMenu`. Missing phrases fall back to English, so you can translate the
menu first and the help text later. Native speakers welcome — the current
non-English strings past Russian have not been reviewed by one.

**Report what breaks.** This tool depends on an undocumented endpoint and on
where Claude Code keeps its credentials. Both can change without notice. If
the panel says `data is stale` and never recovers, that is worth an issue:
include the last few lines of `~/.overlimit/usage-log.err`, your macOS version,
and the Claude Code version from `claude --version`. Never paste the contents
of the keychain entry or anything starting with `sk-ant-`.

## Building

No package manager, no dependencies:

```sh
swiftc -O -o /tmp/overlimit Sources/*.swift
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
