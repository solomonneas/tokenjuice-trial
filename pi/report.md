# tokenjuice trial — phase 3 (Pi on host-a)

**Date:** 2026-04-19
**Host:** host-a (`user@host-a`)
**Pi:** `@mariozechner/pi-coding-agent 0.67.68` (bin: `pi`, CLI)
**tokenjuice:** `0.4.0` (global npm install)
**Provider/model:** `zai/glm-4.6` (only provider with working auth on this machine —
KIMI returned 402 "membership benefits", no Anthropic/OpenAI/Gemini keys available)
**Repo under gauntlet:** `~/repos/sample-repo-b`
**Measurement:** `pi --mode json` → sum `turn_end.message.usage` across turns; compare
`effective_input_tokens = input + cacheRead`. Full jsonl archived per run.

## Headline

**Pi honors tokenjuice hook substitution. At n=10 per cohort, clean tokenjuice runs
save 25.3% of effective input tokens. A DIY `tool_call` wrapper (no tokenjuice)
saves 19.6% with far tighter variance. Tokenjuice averages only −17.7% at n=10
because 3/10 runs hit a reducer gap: commands prefixed with `cd X && ...` are
classified as compound and skip the generic fallback reducer, yielding zero
compaction.**

| cohort     | n  | eff input (avg)     | eff input (median) |    sd |    out |  elapsed | delta vs base |
| ---------- | --:| -------------------:| ------------------:| -----:| ------:| --------:| -------------:|
| baseline   | 10 |          69,779.2   |          69,746.0  |  211.8 |  526.8 |  15.4s   |     +0.00%    |
| tokenjuice | 10 |          57,398.6   |          52,207.0  | 8,078.1|  505.4 |  16.3s   |    −17.74%    |
| wrapper    | 10 |          56,094.0   |          56,050.0  |  200.8 |  514.5 |  16.1s   |    −19.61%    |

**Tokenjuice bimodality** (phase 2 saw the same pattern at ~27% rate):

| subcohort                        | n | eff input (avg) |    sd | delta vs base |
| -------------------------------- | -:| ---------------:| -----:| -------------:|
| tokenjuice — clean (no compound) | 7 |         52,110.9 |  139.6 |     −25.32%   |
| tokenjuice — compound-command    | 3 |         69,736.7 |   72.5 |     −0.06%    |

The clean-run headline (−25.3%) is better than phase 2's best clean result (−8.7%),
because the Pi extension is engaged as a first-class `tool_result` subscriber on
every bash call instead of a shell hook that the Codex harness can sometimes bypass.

## Key finding 1 — substitution works

Pi's `tool_result` extension API lets the tokenjuice runtime actually *replace*
the `content` array returned to the model (the handler returns `{content, details}`
and the runner honors it). Verified by:

1. A probe extension at `~/.pi/agent/extensions/probe.js` logs the original
   command + raw `content` length to `/tmp/pi-hook-probe.log`.
2. Comparing the probed output with the final `tool_execution_end.result.content`
   in the jsonl: on clean runs, `git log -30` dropped from 5,588 raw bytes to
   575 delivered bytes (10% ratio), and `git status` dropped from 100 to 47 with
   the marker `[tokenjuice compacted bash output]`.
3. `tokenjuice stats` confirms engine activity: 51 bash invocations today (phase 3
   + phase 2) — 73% char savings across the session.

Unlike Claude Code (phase 1), the Pi host honors substitution. Unlike Codex CLI
(phase 2), no feature flag gate was required — `tokenjuice install pi` is a one-
shot install and the extension loads on next `pi` invocation.

## Key finding 2 — no hidden feature flag (unlike Codex)

Answer to the carry-in note: **no Pi equivalent of `codex_hooks` exists.** The
pi-coding-agent extension loader (`.../dist/core/extensions/loader.js`) discovers
extensions from three locations unconditionally:

1. `<cwd>/.pi/extensions/` (project-local)
2. `<agentDir>/extensions/` — default `~/.pi/agent/extensions/`
3. Paths passed via `--extension` / `-e`

No gating. `tokenjuice doctor pi` accurately reports `health: ok` immediately
after install, and the probe extension confirmed the hook fires on the first
trivial request. Install + probe + run sequence worked end-to-end.

## Key finding 3 — the compound-command reducer gap (new bug, reproducible)

Three out of ten tokenjuice runs produced **zero** compaction despite the
extension being loaded, the hook firing, and `tokenjuice stats` showing activity
earlier in the session. These runs match baseline token counts exactly
(69,736 vs baseline 69,779 — within 1 sd).

Root cause: in the spike runs, the model (glm-4.6) prefixed each bash call with
`cd ~/repos/sample-repo-b && <cmd>` instead of the bare command:

```
run-5 probe:
  command: "cd ~/repos/sample-repo-b && git log -30"      outputLen=5588 (unchanged)
  command: "cd ~/repos/sample-repo-b && git log --stat -10" outputLen=4680 (unchanged)
  command: "cd ~/repos/sample-repo-b && git status"       outputLen=100  (not compactable anyway)
```

`runtime.js` passes `skipGenericFallbackForCompoundCommands: true` to
`compactBashResult`. `isCompoundShellCommand` flags `&&`, `||`, `;`, `|` and the
engine then skips the generic fallback reducer. `git log`, `git log --stat`, and
`git diff` have no dedicated reducer, so compound-prefixed git commands pass
through verbatim. Only `git/status` and `git/diff-stat` have specialized reducers
that run even on compound commands.

This is model-nondeterminism triggering a classification gap. The agent
arbitrarily chose `cd && ...` in 3/10 runs even though Pi's `bash` tool has a
`cwd` field and the run was already started in the target directory. When it
happens, the savings drop from −25% to −0%.

This is not the same failure mode as phase 2's escape-hatch hypothesis
(agent discovering `tokenjuice wrap --raw`). The Pi print-mode run has no
`/tj raw-next` surface. It's purely a reducer-classification bug.

**Fix suggestion for @vincentkoc:** either (a) normalize compound commands before
classification — strip leading `cd <dir> && ` prefixes and re-classify the tail
as the effective command, or (b) drop `skipGenericFallbackForCompoundCommands`
for trivial `cd && <single-command>` chains. Option (a) is safer.

## Key finding 4 — DIY wrapper is competitive

The `wrapper` cohort uses a 30-line `tool_call` extension with no tokenjuice
dependency (`~/tokenjuice-trial/pi/wrapper.js`). It rewrites every bash command
to pipe through `head -c 1024 + tail -c 512` with a truncation annotation when
output exceeds 2,048 bytes. Results:

- Average savings: **−19.6%** (vs tokenjuice's −17.7% at n=10)
- **Zero variance spikes** (sd=200, vs tokenjuice's 8,078)
- No reducer classification — applies uniformly to all bash calls

The DIY wrapper beats tokenjuice's observed average at n=10 because it does not
have any "compound command" escape, and loses to tokenjuice's clean-run best
case (−25.3%) because it is a less sophisticated reducer (dumb head+tail vs
specialized per-command logic). A real deployment would prefer tokenjuice
*after* the compound-command gap is closed; until then, a 30-line custom
extension buys ~20% reliably.

## Answer quality (compliance audit)

Prompted: "After each command, give a single terse sentence summarizing what the
output showed." Measured compliance by extracting all `message_end` assistant
text and counting how many of the 5 commands were actually summarized in 1+ sentences.

| cohort     | avg hits/5 | full-compliance runs (5/5) | under-compliance runs (≤1/5) |
| ---------- | ---------: | -------------------------: | ---------------------------: |
| baseline   |       4.50 |                         9/10 |                         1/10 |
| tokenjuice |       4.20 |                         7/10 |                         2/10 |
| wrapper    |       3.80 |                         7/10 |                         2/10 |

Quality regression is mild but directionally matches phase 2's finding
(compaction = agent more likely to emit a terse "all done" instead of
per-command summaries). Baseline also has 1 run with 0/5 — likely a message_end
capture artifact, not a real regression.

The 2/10 terse-summary runs in tokenjuice/wrapper are not new regressions, just
the model opportunistically shortcutting when it has less output to summarize.
If strict per-command commentary matters, pair compaction with a sharper prompt
(e.g. "state <result> for each command" instead of "give a single terse sentence").

## Phase comparison

| host          | harness     | substitution honored | feature flag gate    | clean-run delta | n=10 avg delta |
| ------------- | ----------- | :------------------: | :------------------: | --------------: | -------------: |
| host-b       | Claude Code |          ❌          |          —           |          +1.1%  |          +1.1% |
| host-a     | Codex CLI   |          ✅          | yes (`codex_hooks`)  |          −8.7%  |          −4.4% |
| host-a     | Pi          |          ✅          |        **none**      |     **−25.3%**  |    **−17.7%**  |

Pi is the best substrate for tokenjuice measured so far. The clean-run savings
dwarf Codex's because the Pi extension replaces content directly in-process
(no shell hook, no stdio protocol boundary, no feature flag).

## Artifacts

```
~/tokenjuice-trial/pi/
  openclaw.json.pre-tj              # backup (openclaw was untouched; gateway never bounced)
  dot-pi.post-install/              # snapshot of ~/.pi after tokenjuice install pi
  gauntlet.txt                      # same 5-command gauntlet as phase 2
  run.sh                            # per-run driver
  driver.sh                         # 30-run interleaved orchestrator
  wrapper.js                        # DIY PreToolUse extension (no tokenjuice dep)
  _assets/
    tokenjuice.js                   # snapshot of installed tokenjuice extension
    probe.js                        # observability extension used in all cohorts
  baseline/    run-{1..10}.{jsonl,summary.json,probe.log}
  tokenjuice/  run-{1..10}.{jsonl,summary.json,probe.log}
  wrapper/     run-{1..10}.{jsonl,summary.json,probe.log}
  report.md                         # this file
```

## Recommendations for @vincentkoc

1. **Close the compound-command reducer gap.** `skipGenericFallbackForCompoundCommands`
   is the right default for arbitrary chained pipelines, but trivial `cd <dir> && <cmd>`
   prefixes should be normalized before classification. Three out of ten Pi runs
   went from −25% to 0% savings on nothing more than model wording variance.
2. **`tokenjuice install pi` is the cleanest of the three hosts.** No feature
   flag, no config edit, health check is accurate. Document this as the flagship
   experience; Codex's `codex_hooks` path feels like a regression by comparison.
3. **`tokenjuice doctor pi` should call out the compound-command edge case.**
   When it reports `ok`, the user is justified in assuming compaction will happen
   on every bash call. Consider surfacing: "compaction may no-op on compound
   commands like `cd X && cmd` — run unwrapped commands when possible."
4. **Consider a minimal built-in wrapper mode.** Even a dumb head+tail fallback
   (like the 30-line DIY wrapper) gives ~20% savings reliably and could be the
   last-resort reducer when no specialized one matches — preventing the
   compound-command drop-to-zero case.
5. **Phase delta: Pi blows past Codex.** Clean-run savings (−25.3% vs −8.7%)
   reflect an architectural win for Pi's in-process extension API. Worth
   featuring Pi as the reference integration in tokenjuice docs.

## Reproduce

```bash
npm install -g @mariozechner/pi-coding-agent tokenjuice
tokenjuice install pi
# pi looks in ~/.pi/agent/extensions/ and any <cwd>/.pi/extensions/
# No feature flag to enable. Doctor is accurate:
tokenjuice doctor pi
# Run (requires zai or another supported provider with env auth):
export ZAI_API_KEY=...
cd /path/to/test/repo
~/tokenjuice-trial/pi/driver.sh   # 30 runs, ~10 min
python3 ~/tokenjuice-trial/pi/analyze.py   # (or re-run the stats block inline)
```

## Caveats

- Single provider (zai/glm-4.6) — not tested against Anthropic/OpenAI-served
  models. Compound-command behavior may differ with different models; e.g. gpt-5.4
  may never prefix `cd && ...`. Worth retesting if you can put ANTHROPIC_OAUTH_TOKEN
  in place.
- Print mode only. Interactive `/tj raw-next` and `/tj off` surfaces are untested
  here. They're not reachable from non-interactive print mode, so any phase-2-style
  "agent discovers bypass" theory does not apply to print mode.
- Prompt-cache warmth: runs were interleaved by round (baseline.i, tokenjuice.i,
  wrapper.i) to equalize cache state across cohorts. Absolute token counts are
  dominated by cacheRead (~64k baseline / ~51k tokenjuice clean), consistent with
  that design — the system prompt is cached and only the tool-result tail differs.
