# tokenjuice trial — phase 2 (Codex on host-a)

**Date:** 2026-04-19
**Host:** host-a (`user@host-a`)
**Codex CLI:** `codex-cli 0.120.0` (via `@openai/codex` npm)
**tokenjuice:** `0.4.0` (global npm install)
**Repo under gauntlet:** `~/repos/sample-repo-b`
**Measurement:** `codex exec --json` JSONL stream → sum `turn.completed.usage` across turns.
**Sample size:** 11 baseline + 11 treatment runs (initial 3+3, extended with 8+8).

## Headline

**Codex honors tokenjuice hook output — but the saving is bimodal at n=11.** Net input-token delta is **−4.4%** once the sample is large enough to catch a retry-via-escape-hatch behavior that was invisible at n=3.

| phase     | n  | input mean | input sd | output mean | cmd mean |
| --------- | -: | ---------: | -------: | ----------: | -------: |
| baseline  | 11 | **193,519** |     186 |         519 |     5.00 |
| treatment | 11 | **184,952** |  14,208 |         571 |     5.27 |
| delta     |    | **−8,567 (−4.43%)** |   |         +52 |    +0.27 |

Baseline is rock-steady (sd=186, 0.1% coefficient of variation). Treatment is bimodal:

| treatment subset                      | n  | input mean | note |
| ------------------------------------- | -: | ---------: | ---- |
| "clean" — 5 commands                  | 8  | **176,658** | tokenjuice substitution accepted → **−8.7%** vs baseline |
| "retry" — 6 commands                  | 3  | **207,068** | agent discovered `tokenjuice wrap --raw` and re-ran git status → **+7.0%** vs baseline |

## Key findings

### 1. Codex substitution works

Unlike Claude Code (phase 1) where PostToolUse hook stdout is ignored, **Codex substitutes the model-visible `function_call_output` with the hook's stdout**. Verified in `~/.codex/sessions/*.jsonl`. Baseline `git log -30` output delivered to model was the raw 1,397-token log; treatment delivered the "Chunk ID / Wall time / Original token count: 1397 / Output:" wrapper with a heavily-reduced body. The engine is real.

### 2. Agents route around the over-compactor 27% of the time

In 3 of 11 treatment runs (runs 5, 9, 11), after receiving the over-compacted `git status` output, the agent **discovered and used the `tokenjuice wrap --raw --` escape hatch** to re-run `git status` and get the real output:

```
cmd: /bin/bash -lc 'git status'                      # compacted by tokenjuice
cmd: /bin/bash -lc 'tokenjuice wrap --raw -- git status'   # agent bypasses it
```

This is a real quality problem for the value proposition — the agent is explicitly undoing tokenjuice's work. When it happens, the round-trip costs roughly +14k input tokens (+7% vs baseline) because the retry runs full context through another tool call. It's nondeterministic (happened 3/11 times with identical input). Likely root cause: `git/status` reducer strips too much, and the `tokenjuice wrap --raw` escape hatch is advertised (maybe in the agent's instructions or tool descriptions) enough that the model finds it when compaction degrades output quality.

### 3. Installer doesn't enable the feature flag

`tokenjuice install codex` writes `~/.codex/hooks.json` with a valid PostToolUse entry, but **Codex does not load `hooks.json` unless the `codex_hooks` feature flag is enabled**. Without the flag, the hook is a no-op — first treatment batch (archived in `treatment-no-feature-flag/`) showed zero `tokenjuice` entries and identical token counts to baseline.

Ways to enable:
- Per-invocation: `codex exec --enable codex_hooks ...`
- Per-invocation config: `codex exec -c features.codex_hooks=true ...`
- Persistent (`~/.codex/config.toml`):
  ```toml
  [features]
  codex_hooks = true
  ```

Neither `tokenjuice install codex` nor `tokenjuice doctor hooks` warn the feature flag is off. Doctor reports `codex: health: ok`.

**Matcher:** tokenjuice's `"matcher": "^Bash$"` works — Codex presents its shell tool to hooks under the Claude-Code-compatible name `Bash`, even though internally the tool is called `exec_command`.

## Engine stats (all 11 treatment runs, 66 bash invocations)

- raw chars: 140.8k → reduced chars: 40k
- saved chars: 100.8k (**72% char savings**)
- avg reducer ratio: 53%
- reducers used: `generic/fallback` (27x, 29% kept), `git/status` (15x, 29% kept), `generic/help` (12x, 93% kept), `git/diff-stat` (11x, 100% kept), `git/log-oneline` (1x, 98% kept)
- top commands: `git` 49x saved 99.7k chars; `npm` 11x saved 1.1k; `tokenjuice` 5x saved 0 (the retry calls)

Engine efficiency is consistent with the 3-run preview. The gap between 72% char reduction and 4.4% token reduction is explained by (a) the Codex system prompt + repo manifest dominating token count regardless of tool output (cached), and (b) the retry runs inflating treatment.

## Answer quality

- `git log -30` ✅ correct across all 11 treatment runs
- `git log --stat -10` ✅ correct
- `git status` ⚠️ **noticeable regression**: in the 8 clean runs, agent frequently said "no visible output" / "produced no visible output" instead of the correct "clean working tree"; in the 3 retry runs, the agent used the escape hatch and got it right but paid the token cost. Baseline was fully correct all 11 times.
- `git diff HEAD~5 --stat` ✅ correct
- `npm --help` ✅ correct

Net: the compaction is degrading `git status` summary quality badly enough that a smart model actively works around it at a ~27% rate on this gauntlet.

## Delta vs phase 1 (Claude Code on host-b)

| host        | harness     | sample  | input token delta vs baseline |
| ----------- | ----------- | :-----: | ----------------------------: |
| host-b     | Claude Code |  3+3   | **+1.1%** (engine worked; Claude Code ignored replacement output) |
| host-a   | Codex CLI   | 11+11  | **−4.4%** overall (−8.7% clean, +7.0% retry; 27% retry rate)     |

Phase 1 showed the engine is solid but Claude Code's PostToolUse contract doesn't substitute tool_result. Phase 2 shows Codex's contract does, and the value proposition works — but is fragile. A less-over-aggressive `git/status` reducer would likely close the retry gap and deliver the full −8.7% consistently.

## Artifacts

```
~/tokenjuice-trial/codex/
  gauntlet.txt
  run.sh                          # phase-aware: treatment gets --enable codex_hooks, baseline doesn't
  config.toml.pre-tj              # backup of codex config before tj install
  baseline/
    run-{1..11}.jsonl             # raw codex --json stream
    run-{1..11}.summary.json      # extracted token/turn/command counts
  treatment/
    run-{1..11}.jsonl
    run-{1..11}.summary.json
  treatment-no-feature-flag/
    run-1.{jsonl,summary.json}    # proves hook is a no-op without --enable codex_hooks
  report.md                       # this file
```

## Recommendations for @vincentkoc

1. **Block on the retry behavior.** The `tokenjuice wrap --raw` escape hatch is being discovered and used by gpt-5.4 at ~27% rate on a trivial gauntlet. Either (a) don't advertise the escape hatch to the model, (b) make the compacted-output preamble tell the model not to retry via wrap, or (c) tune reducers so output quality is good enough that the model doesn't want to retry. Current behavior gives the model both the compaction AND the knowledge of how to undo it.
2. **Tune `git/status` reducer** — collapsing `## main...origin/main` into "Process exited with code 0" style makes the model report no output at all. Either preserve short outputs verbatim (reducer should be no-op under some char threshold) or explicitly preserve the clean/dirty signal.
3. **Installer UX:** `tokenjuice install codex` should add `[features]\ncodex_hooks = true` to `~/.codex/config.toml`, or print a loud notice that it must be enabled elsewhere. Current behavior silently produces zero savings.
4. **`tokenjuice doctor hooks`** should verify the `codex_hooks` feature flag is actually active — current doctor says `ok` for a completely inert install.
5. **Phase 3 (OpenClaw Pi):** will proceed — engine validated at n=22. Report in progress.

## Reproduce

```bash
# on host-a (or any codex-authed host)
npm install -g tokenjuice
tokenjuice install codex
# IMPORTANT — the install step doesn't do this for you:
printf '\n[features]\ncodex_hooks = true\n' >> ~/.codex/config.toml
# run the gauntlet
~/tokenjuice-trial/codex/run.sh baseline 1
~/tokenjuice-trial/codex/run.sh treatment 1
tokenjuice stats
```
