# tokenjuice v0.4.0 — independent trial (three harnesses)

A measured, reproducible evaluation of [tokenjuice](https://github.com/vincentkoc/tokenjuice) v0.4.0 across three host harnesses, run 2026-04-19. Shared as evidence for upstream bug reports and PRs.

## TL;DR

| harness       | sample | input-token delta vs baseline | notes |
| ------------- | :----: | ----------------------------: | ----- |
| Claude Code (PostToolUse)                      | 3+3    | **+1.1%** (worse)              | engine fires; Claude Code 2.1.113 ignores the replacement. Only `additionalContext` reaches the model. |
| Claude Code (PreToolUse wrapper, "Option B")   | 3+3    | **−7.8%**                      | small custom hook that rewrites bash to `tokenjuice wrap -- sh -c "…"`. Proves the engine works on Claude Code if the integration shape changes. |
| Codex CLI 0.120.0 (PostToolUse)                | 11+11  | **−4.4%** overall (bimodal)    | Codex honors substitution → −8.7% on clean runs; **27% of runs** trigger gpt-5.4 to discover and use `tokenjuice wrap --raw --` to bypass the compaction, costing +7.0%. Net average −4.4%. |
| Pi (`@mariozechner/pi-coding-agent`) 0.67.68   | 10+10  | **−17.7%** overall             | Pi honors substitution natively via its extension API — no feature flag needed. Also bimodal: clean runs **−25.3%**; 30% of runs use `cd X && <cmd>` which tokenjuice classifies as compound and skips → 0% compaction on those. |
| Pi — DIY `tool_call` wrapper (no tokenjuice)   | 10     | **−19.6%** (sd=201, flat)      | a 30-line extension that pipes every bash call through `head -c 5000 + tail -c 2000`. Beats tokenjuice on average and has zero variance. Baseline for how little cleverness is required. |

Pi is tokenjuice's flagship surface. Codex has a fixable installer bug. Claude Code needs an integration-shape change.

## Findings and upstream actions

### Installer / UX bugs (PR candidates)

1. **`tokenjuice install codex` writes `~/.codex/hooks.json` but does not enable the `codex_hooks` feature flag.** Without the flag, the hook is a silent no-op — verified in `codex/treatment-no-feature-flag/`. `tokenjuice doctor hooks` reports `codex: health: ok` for a completely inert install. Fix: installer appends `[features]\ncodex_hooks = true` to `~/.codex/config.toml` (or prints a loud notice), and doctor verifies the flag is live.
2. **`git/status` reducer collapses `## main…origin/main` too hard.** Produces agent summaries like "no visible output" instead of "clean working tree". Happens on Codex and Pi clean runs. Fix: short-output floor (keep verbatim under ~200 chars), or explicitly preserve clean/dirty signal.
3. **Compound-command gap on Pi: `cd X && <cmd>` skips the generic fallback.** `isCompoundShellCommand` classifies the whole string as compound; `skipGenericFallbackForCompoundCommands: true` blocks fallback; uncommon git forms (`git log -30`, `git log --stat -10`) have no specialized reducer and pass through verbatim. Fix: normalize a trivial `cd <dir> && <cmd>` prefix to its tail before classification, or add reducers for common read-only git forms.

### Design questions (issue candidates)

4. **`tokenjuice wrap --raw --` escape hatch is discoverable by the model.** On Codex, gpt-5.4 finds and uses it at a 27% rate on this gauntlet once output quality degrades. This actively undoes tokenjuice's savings. Options: don't advertise the escape hatch to the model, add a "do not retry via wrap --raw" note to the compacted preamble, or close the loophole by sharpening reducers so the model doesn't want to retry.
5. **Claude Code's PostToolUse contract doesn't substitute `tool_result`.** Claude Code 2.1.113 only reads `hookSpecificOutput.additionalContext`; `decision:"block"` + `reason` is ignored. Root cause is in Claude Code, not tokenjuice — but tokenjuice's value prop on that host depends on it. The PreToolUse wrapper in `claude-code/wrapper/` is a working workaround until the harness changes.

## Directory map

```
README.md                                # this file
tokenjuice-doctor.txt                    # `tokenjuice doctor hooks` output, pre-install
tokenjuice-config.md                     # install paths + versions used

claude-code/
  report.md                              # phase 1 full write-up
  gauntlet.txt                           # 5-command read-only prompt
  baseline/ treatment/                   # summary.json per run (token counts only)
  wrapper/                               # Option B fix (PreToolUse hook)
    report.md
    tokenjuice-pretool.js                # the ~40-line wrapper hook
    settings.wrapper.json                # Claude Code settings sample
    treatment/                           # summary.json per run

codex/
  report.md                              # phase 2 full write-up (n=11+11, bimodal)
  gauntlet.txt run.sh                    # scripts
  baseline/ treatment/                   # summary.json per run
  treatment-no-feature-flag/             # proof that default install is a no-op

pi/
  report.md                              # phase 3 full write-up (3 cohorts, n=10 each)
  gauntlet.txt run.sh driver.sh          # scripts
  wrapper.js                             # the ~30-line DIY wrapper extension
  baseline/ tokenjuice/ wrapper/         # summary.json per run
```

Raw JSONL transcripts and config backups are **not** published here — they contain unrelated repo commit history and auth material. Available privately on request.

## Reproducing

Each harness directory has a self-contained script. The gauntlet is the same 5 read-only commands (`git log -30`, `git log --stat -10`, `git status`, `git diff HEAD~5 --stat`, `npm --help`) on a moderately-sized repo, summarized one sentence each. We used a personal site repo; any ~30-commit repo works.

Claude Code: see `claude-code/wrapper/report.md` § Reproducing.
Codex: `codex/run.sh <baseline|treatment> <n>` — remember to add `[features]\ncodex_hooks = true` to `~/.codex/config.toml` or pass `--enable codex_hooks`, or you'll measure a silent no-op.
Pi: `pi/driver.sh` — 30 runs, interleaved by round so prompt cache warmth is roughly comparable across cohorts.

## Trial metadata

- Date: 2026-04-19
- tokenjuice: v0.4.0 (global npm install across all three hosts)
- Hosts: `host-a` (Linux, Ubuntu 24.04), `host-b` (Windows 11, Claude Code), `host-c` (not directly used in trial)
- Models: `claude-opus-4-7` (phase 1), `gpt-5.4` (phase 2), `zai/glm-4.6` (phase 3 — only provider with working auth)
- Measurement: stream native JSON/JSONL output from each CLI, sum usage across turns, compare means and standard deviations.

## Contact

Findings authored for @vincentkoc. The full evidence pack (including raw transcripts and config) is available privately — reach out and we'll share.
