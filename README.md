# Usage tracker

Shows your Claude Code plan limits in the Mac menu bar. The title reads
`W: 3h 23% · D:4d 41%`: `W:` is the 5-hour window and `D:` is the 7-day window,
each with the time left, rounded up, and the percent used. Percents run from
green at 0% through yellow to red at 100%.

```
5-hour  23%   resets 4:10 PM (in 2h 5m)
7-day  41%   resets Tue 9:00 AM (in 3d 9h)
Updated 3m ago
─────────────
Today  48.2M tokens (312K output)
7 days  612M tokens (4.1M output)
─────────────
Quit
```

## Install

You need macOS, Xcode Command Line Tools, `jq`, a Pro, Max or Ultra plan, and a
status line already set in `~/.claude/settings.json`.

```bash
./install.sh
```

Limits appear after the next Claude Code response. To remove everything:

```bash
./install.sh uninstall
```

The install makes these changes:

- `~/.local/bin/usage-tracker`: adds the binary.
- `~/Library/LaunchAgents/local.usage-tracker.plist`: starts it at login.
- `~/.claude/settings.json`: adds a prefix to `statusLine.command`.
- `~/.claude/usage-tracker/rate-limits.json`: holds the latest limits.

## Where the numbers come from

**Limits** come from the `rate_limits` field Claude Code sends to status line
commands. The tracker sits in front of your existing status line, passes its
input through unchanged and saves the limits. It never reads your login token.

**Token totals** come from the transcripts in `~/.claude/projects`, including
subagents. Each message counts once. The total includes input, output, cache
writes and cache reads, so output is shown separately. Today starts at local
midnight, and 7 days is a rolling window.

## Known limits

- Limits refresh only when a Claude Code session on this Mac responds. Usage
  from claude.ai or another machine shows up on the next response.
- "Updated" is when a value last changed, so it can look old during light use.
- A window past its reset time shows 0% until the next response reports it.
- The feed has no per-model limits, such as a weekly Sonnet limit.
- Token totals cover this Mac only.

## Checks

```bash
swiftc -O main.swift selfcheck.swift -o /tmp/usage-tracker
/tmp/usage-tracker --self-check
/tmp/usage-tracker --print
```

`--print` shows what the menu would show. Set `CLAUDE_CONFIG_DIR` to read from
another directory.
