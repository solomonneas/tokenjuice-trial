# tokenjuice v0.4.0 on Claude Code — Trial Report

**Trial date:** 2026-04-19
**Trialer:** Maintainer ([redacted-email])
**Host:** host-b (Windows 11 Pro, Node 25.9.0, npm 11.12.1)
**Claude Code version:** 2.1.113 (Max subscription OAuth)
**Model under test:** `claude-opus-4-7`
**Test repo:** `%USERPROFILE%\repos\sample-repo-a` (35 commits, small TypeScript MCP server)

## TL;DR

**Tokenjuice v0.4.0 does not reduce tokens that reach the Anthropic model on
Claude Code 2.1.113.** The hook runs, matches its own rules, and emits the
correctly-reduced output with `decision: "block"` + `reason` + `additionalContext`.
Claude Code's runtime logs the hook call as `outcome: "success"`, but the
original unreduced tool_result is what ends up in the model's context. The
only thing injected is the short ~25-token `additionalContext` hint, which
pushes token usage *slightly up* (+0.88% at n=10) rather than down.

The bug is in the integration contract between tokenjuice and Claude Code,
not in tokenjuice's reduction engine (which works — `tokenjuice stats`
shows 76% char savings on the sample inputs).

## Method

Same 5-command gauntlet run 10× per condition (baseline, tokenjuice
shipped PostToolUse, and custom PreToolUse wrapper), identical prompt,
identical model, identical cwd, identical subscription. Fresh session per
run (non-interactive `claude -p --output-format json --permission-mode
bypassPermissions --model claude-opus-4-7 --add-dir ...`). Token counts
pulled from `.usage` in the `claude -p` JSON summary; transcripts archived
for byte-level comparison.

Gauntlet (`gauntlet.txt`):
```
Execute each of the following commands in the %USERPROFILE%\repos\sample-repo-a
directory, in order. Use the Bash tool. After each command, give a single terse
sentence summarizing what the output showed. Do not explain further, do not
elaborate, do not add commentary between commands. Just run and 1-line summarize.

1. git log -30
2. git log --stat -10
3. git status
4. git diff HEAD~5 --stat
5. pnpm --help

When all five are done, stop.
```

## Per-run totals (n=10 each)

| run #     | baseline | tokenjuice (PostToolUse) | wrapper (PreToolUse) |
|-----------|---------:|-------------------------:|---------------------:|
| 1         |  285,094 |                  288,413 |              262,839 |
| 2         |  285,495 |                  288,281 |              262,940 |
| 3         |  285,376 |                  288,899 |              263,785 |
| 4         |  286,086 |                  288,832 |              263,316 |
| 5         |  287,402 |                  287,022 |              263,517 |
| 6         |  285,823 |                  288,834 |              263,438 |
| 7         |  285,793 |                  287,293 |              263,204 |
| 8         |  286,330 |                  289,031 |              263,367 |
| 9         |  285,751 |                  289,775 |              263,314 |
| 10        |  286,946 |                  288,860 |              263,242 |
| **mean**  |  286,010 |                  288,524 |              263,296 |
| **sd**    |      677 |                      782 |                  257 |

## Condition means (n=10)

| condition                       | mean tokens | sd  | spread | Δ vs baseline |
|---------------------------------|------------:|----:|-------:|--------------:|
| **baseline** (no hook)          |     286,010 | 677 |  2,308 |             — |
| **tokenjuice** (shipped integration) | 288,524 | 782 |  2,753 |   **+0.88%** |
| **wrapper** (PreToolUse → `tokenjuice wrap`) | **263,296** | **257** | **946** | **−7.94%** |

Wrapper condition is ~3× less variable than either alternative (sd 257 vs
677/782) and tool_result byte lengths were **byte-identical across all 10
wrapper runs** (585 / 664 / 52 / 851 / 658). The result is deterministic
— not noise. Tokenjuice's shipped hook makes net tokens go *up* on
Claude Code; swapping it for the PreToolUse wrapper makes it go *down*.

(Baseline-1's higher `cache_create` was a one-time cold-cache warm-up. Not a
condition effect.)

## Root cause — the hook runs, its output is ignored

Used `claude -p --output-format stream-json --include-hook-events` to capture
every hook event. For each Bash call the tokenjuice PostToolUse hook:

1. Starts successfully (`subtype: "hook_started", hook_event: "PostToolUse"`).
2. Returns valid JSON on stdout — e.g. for `git log --stat -10`:
   ```json
   {
     "decision": "block",
     "reason": "1 error\ncommit 98f93c78...\n    fix(reader): ...\n src/graph/reader.ts  | 13 ++\n tests/unit/graph/reader.test.ts | 15 +++\n... 98 lines omitted ...\ncommit 3661c1c2...",
     "hookSpecificOutput": {
       "hookEventName": "PostToolUse",
       "additionalContext": "if this compaction looks wrong, rerun with `tokenjuice wrap --raw -- <command>` or `tokenjuice wrap --full -- <command>`."
     }
   }
   ```
3. Finishes with `outcome: "success", exit_code: 0`.

Despite that, the transcript `.jsonl` stores the **original unreduced**
`tool_result.content` — byte-identical to the baseline transcript for the
same command:

```
$ jq -r '.message.content[0].content[0].text | length' baseline/run-1.transcript.jsonl
6402 4159 52 852 2309
$ jq -r '.message.content[0].content[0].text | length' treatment/run-1.transcript.jsonl
6402 4159 52 852 2309
```

The `additionalContext` from `hookSpecificOutput` **is** being injected
(adds a consistent +15 input tokens per turn across all 3 treatment runs,
which matches the ~25-token hint length × 6 turns). But the `reason` field
— where tokenjuice places the reduced output — is **not** replacing
tool_result content.

This matches what `tokenjuice stats` reports internally:
```
entries: 15        (3 runs × 5 commands ✓)
raw chars: 41.3k
reduced chars: 9.9k
saved chars: 31.5k  (reduction engine works)
avg ratio: 39%
savings: 76%
top reducers:
  - generic/fallback count=6 saved=27.9k avgRatio=13%
  - generic/help     count=3 saved=3.4k  avgRatio=51%
  - git/status       count=3 saved=123   avgRatio=21%
  - git/diff-stat    count=3 saved=3     avgRatio=100%
```

Tokenjuice believes it saved 31.5k chars. It really did compute those
reductions. They just didn't land anywhere the model could see.

## Hypothesis for the maintainer

Claude Code's current `PostToolUse` hook contract does not appear to honor
`decision: "block"` + `reason` as a **replacement** for tool_result content.
Looking at the Claude Code 2.1.113 settings schema:

- `decision: "block"` is listed as "deprecated for PreToolUse; kept for
  PostToolUse/Stop/UserPromptSubmit".
- The documented path for injecting text back into the model's context is
  `hookSpecificOutput.additionalContext` — which IS honored (we measured it).
- There's no `updatedToolOutput` / `replacementContent` field in the public
  schema.

So the likely fix on tokenjuice's side is one of:

**Option A — move reduced text into `additionalContext` and also set
`suppressOutput: true`**, if Claude Code supports the latter meaningfully
for PostToolUse. (Need to verify; `suppressOutput` is documented as
"Hide stdout from transcript" but unclear whether that excludes the
original tool_result from model context too, or just from the UI.)

**Option B — accept that Claude Code doesn't support tool_result
replacement from a PostToolUse hook, and pivot to a different integration
point** (e.g. a PreToolUse hook that wraps the command in `tokenjuice
wrap -- <original>`, producing reduced stdout at the tool-output layer
before Claude Code ever sees it). The `tokenjuice wrap` subcommand already
exists for this kind of use.

**Option C — file upstream with Anthropic for a first-class tool_result
rewrite hook contract.** This is probably needed long-term; the current
schema only supports *appending* context, not *replacing* it.

Happy to test any fix builds against the same gauntlet — the artifacts in
this folder are enough to rerun exactly.

## Failure modes we did NOT hit

- No install errors. `npm install -g tokenjuice && tokenjuice install
  claude-code` worked cleanly on Windows 11.
- No JSON corruption of `~/.claude/settings.json`. The install cleanly
  appended `hooks.PostToolUse` and preserved the 17 existing plugins +
  other settings. Tokenjuice also made its own `.bak` copy — good.
- No crashes, no stderr noise. Every hook call exited 0 with valid JSON.
- `tokenjuice doctor hooks` correctly reports `health: ok`.
- `tokenjuice verify --fixtures` → 97 rules, 101 fixtures, all pass.

The packaging, CLI ergonomics, doctor UX, and reduction engine are all
solid. The one integration wire is the problem.

## What we suggest next

- **Don't install on host-a (main OpenClaw host) yet.** Wait for Claude
  Code integration fix (or eval the Pi/OpenClaw host separately — it may
  not have the same tool_result-replacement limitation).
- **Test the `pi` integration specifically.** OpenClaw's `pi-embedded`
  runtime may honor a different hook contract that actually substitutes
  output. If so, tokenjuice on OpenClaw could still be a big win even
  while the Claude Code path is broken.
- **Test the `codex` integration.** Codex CLI has its own hook contract;
  same uncertainty.

## Artifacts in this folder

```
tokenjuice-trial/
  env.md                         # host/version info
  gauntlet.txt                   # exact prompt, sent to host-b as-is
  settings.pre.json              # host-b ~/.claude/settings.json before install
  settings.post.json             # after install (shows the added PostToolUse hook)
  tokenjuice-config.md           # reducer rule inventory + expected matches
  tokenjuice-doctor.txt          # tokenjuice doctor output post-install
  tokenjuice-hook-last.json      # last hook invocation debug record
  baseline/run-{1,2,3}.summary.json       # claude -p JSON summaries
  baseline/run-{1,2,3}.transcript.jsonl   # full session transcripts
  treatment/run-{1,2,3}.summary.json
  treatment/run-{1,2,3}.transcript.jsonl
  treatment/hook-events-stream.jsonl      # stream-json run with hook events — the smoking gun
  hook-probe.json                # synthetic hook input for manual probes
  report.md                      # this file
```

Everything here is reproducible by rerunning the same two commands with
and without `tokenjuice install claude-code` in between.

## Follow-up: Option B validated (same session, 2026-04-19)

After writing the above, we built and tested the PreToolUse + `tokenjuice
wrap` approach from "Option B". It works. See
`~/tokenjuice-trial/wrapper/report.md` for full data.

**Three-condition comparison:**

All three conditions measured at n=10 for a clean comparison:

| condition                                   | n  |   mean   |  sd  |   Δ vs baseline  |
|---------------------------------------------|:--:|---------:|-----:|-----------------:|
| Baseline (no hook)                          | 10 |  286,010 |  677 |               — |
| **Tokenjuice** (shipped PostToolUse)        | 10 |  288,524 |  782 |       **+0.88%** |
| **Custom wrapper** (PreToolUse → `tokenjuice wrap`) | 10 | **263,296** | **257** | **−7.94%** |

Wrapper is ~3× less variable than the other two conditions and
tool_result byte lengths were identical on every run — reduction is
deterministic. Result is not noise.

A ~30-line PreToolUse hook rewrites Bash commands to
`tokenjuice wrap -- sh -c "<cmd>"` before they run. Tool_result content
is genuinely reduced (80% char savings on the gauntlet), the reduction
lands in the model's context (verified by byte-level transcript diff),
and total tokens drop ~22k per run.

**Recommendation for @vincentkoc:** change `tokenjuice install
claude-code` to write a `PreToolUse` hook instead of `PostToolUse`,
using a thin wrapper script that calls `tokenjuice wrap`. The heavy
reduction logic already ships in `tokenjuice wrap`; only the
Claude-Code-specific install path needs to change.

## Verdict for Solomon

**Hold on host-a rollout with the current tokenjuice build.** The
fix is known and simple (~30-line hook). Either:

- File the phase 1 report + wrapper validation with @vincentkoc and
  wait for an upstream `install claude-code` fix, OR
- Ship the wrapper hook ourselves on host-a (minimal risk — just a
  PreToolUse hook that calls existing `tokenjuice wrap`).

Phase 2 (Codex) and Phase 3 (Pi) tests still valuable — Codex may need
the same wrapper pattern, Pi may already work out of the box.
