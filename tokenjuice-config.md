# Tokenjuice Configuration (post-install, treatment side)

- **Version:** 0.4.0
- **Install host:** host-b (Windows 11)
- **Install path:** `%USERPROFILE%\AppData\Roaming\npm\node_modules\tokenjuice\`
- **Hook wired into:** `%USERPROFILE%\.claude\settings.json` → `hooks.PostToolUse[matcher=Bash]`
- **Hook command:** `'%USERPROFILE%\AppData\Roaming\npm\tokenjuice.cmd' claude-code-post-tool-use`
- **Status message (shown in spinner):** "compacting bash output with tokenjuice"
- **Doctor check:** `tokenjuice doctor hooks` → `health: ok`
- **Built-in backup:** `%USERPROFILE%\.claude\settings.json.bak` (tokenjuice made this automatically; we also saved our own `settings.pre.json`)
- **Rule validation:** `tokenjuice verify --fixtures` → **97 rules validated, 101 fixtures verified**

## Rule families present
```
archive/  build/  cloud/  database/  devops/  filesystem/  fixtures/
generic/  git/  install/  lint/  media/  network/  observability/
openclaw/  package/  search/  service/  system/  task/  tests/  transfer/
```

## Expected reducer match for our gauntlet
| # | Gauntlet command       | Matched rule        | Summarize head/tail | Notes |
|---|------------------------|---------------------|---------------------|-------|
| 1 | `git log -30`          | `generic/fallback`  | 8 / 8               | No `--oneline` flag, so `git/log-oneline` does NOT match. Falls through to generic. |
| 2 | `git log --stat -10`   | `generic/fallback`  | 8 / 8               | Same — no `--oneline`, log-oneline doesn't match. |
| 3 | `git status`           | `git/status`        | 10 / 4 + counters   | Strips "On branch…", "Your branch is…", help hints, etc. |
| 4 | `git diff HEAD~5 --stat` | `git/diff-stat`   | 12 / 6 + counters   | Matches `diff` + `--stat` argv pair. |
| 5 | `pnpm --help`          | `generic/help`      | 80 / 40             | Very light trim — help output is considered valuable to preserve. |

## Other hosts available (not installed in this trial)
- `tokenjuice install codex` — Codex CLI hook (disabled)
- `tokenjuice install pi` — OpenClaw/Pi runtime hook (disabled)

## Stats at install time
```
entries: 0
raw chars: 0
reduced chars: 0
saved chars: 0
avg ratio: n/a
savings: n/a
```
(Expected — no tool calls through the hook yet.)
