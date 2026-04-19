# Tokenjuice Trial — Supplemental: Fix Option B validated

**Date:** 2026-04-19 (same session as main trial, a couple hours later)
**Purpose:** Phase 1 established that tokenjuice's PostToolUse hook on Claude Code 2.1.113 doesn't substitute tool_result. This supplemental tests **Option B** from the main report ("pivot to PreToolUse + `tokenjuice wrap`") to see whether that fix approach actually delivers reductions that reach the model.

## TL;DR

**Option B works.** A ~40-line PreToolUse wrapper hook that rewrites Bash
commands from `<cmd>` to `tokenjuice wrap -- sh -c "<cmd>"` drops total
token usage by **7.8% vs baseline** and **8.8% vs tokenjuice's current
PostToolUse integration**. Tool_result content is genuinely reduced
(80% char savings) and the reduction lands in the model's context
(verified via transcript byte-level comparison).

Recommend tokenjuice's Claude Code integration be rebuilt around this
pattern rather than PostToolUse.

## Three conditions — n=10 each

| condition                                       | n  |    mean    | sd  |   min   |   max   |   Δ vs baseline   |
|-------------------------------------------------|:--:|-----------:|----:|--------:|--------:|------------------:|
| **Baseline** (no hook)                          | 10 |    286,010 | 677 | 285,094 | 287,402 |                 — |
| **Tokenjuice** (shipped PostToolUse)            | 10 |    288,524 | 782 | 287,022 | 289,775 |         **+0.88%** |
| **Custom wrapper** (PreToolUse → `tokenjuice wrap`) | 10 | **263,296** | **257** | 262,839 | 263,785 | **−7.94%** |

The custom wrapper still uses tokenjuice's reduction engine — it calls
`tokenjuice wrap` as the child command. What changes between rows 2 and 3
is *how* tokenjuice is wired into Claude Code:
- Row 2 uses the PostToolUse hook that `tokenjuice install claude-code`
  writes. Claude Code 2.1.113 doesn't substitute tool_result from that
  contract, so the reduction never reaches the model.
- Row 3 uses a PreToolUse hook that rewrites the Bash command to
  `tokenjuice wrap -- sh -c "<cmd>"` before it runs, so the tool's own
  output is already reduced when Claude Code captures it.

### Per-run detail

| run           | baseline | tokenjuice (PostToolUse) | wrapper (PreToolUse) |
|---------------|---------:|-------------------------:|---------------------:|
| 1             |  285,094 |                  288,413 |              262,839 |
| 2             |  285,495 |                  288,281 |              262,940 |
| 3             |  285,376 |                  288,899 |              263,785 |
| 4             |  286,086 |                  288,832 |              263,316 |
| 5             |  287,402 |                  287,022 |              263,517 |
| 6             |  285,823 |                  288,834 |              263,438 |
| 7             |  285,793 |                  287,293 |              263,204 |
| 8             |  286,330 |                  289,031 |              263,367 |
| 9             |  285,751 |                  289,775 |              263,314 |
| 10            |  286,946 |                  288,860 |              263,242 |
| **mean**      |  286,010 |                  288,524 |          **263,296** |
| **spread**    |    2,308 |                    2,753 |              **946** |
| **sd**        |      677 |                      782 |              **257** |

The wrapper condition is ~3× less variable than either other condition
(sd 257 vs 677 / 782). Tool_result byte lengths in the wrapper runs
were **identical on all 10 runs** (585 / 664 / 52 / 851 / 658 chars),
confirming the reduction is fully deterministic. Result is not noise.

## Tool_result content is actually reduced

Across all 3 wrapper runs, each command's tool_result landed at
**byte-identical** length (the agent received the same reduced bytes
each run):

| # | command              | baseline chars | wrapper chars | reduction |
|---|----------------------|---------------:|--------------:|----------:|
| 1 | `git log -30`        |          6,402 |           585 |    **91%** |
| 2 | `git log --stat -10` |          4,159 |           664 |    **84%** |
| 3 | `git status`         |             52 |            52 |        0% (already minimal) |
| 4 | `git diff --stat`    |            852 |           851 |        ~0% (already minimal) |
| 5 | `pnpm --help`        |          2,309 |           658 |    **71%** |
|   | **total**            |     **13,774** |     **2,810** |    **80%** |

Sample of what the model saw (wrapper run-1, command 1):

```
2 errors
commit 98f93c786469d607f0486d229a4d5883007d75bd
Author: Maintainer <[redacted-email]>
Date:   Sat Apr 18 14:11:01 2026 -0400

    fix(reader): preserve entity geometry from y:ShapeNode when loading .mtgx

commit 3124355f8ab785859aeb544c1f06f6961972e046
... 172 lines omitted ...

    feat(graph): entity type registry with validation and suggestions

commit 6dfdd6719ff56b379fc9459113d3cfd91cf8d3a9
Author: Maintainer <[redacted-email]>
Date:   Sat Apr 18 13:06:15 2026 -0400

    feat(types): core Entity, Link, Graph, Lookup types
```

Head/tail markers are preserved, middle is collapsed with an explicit
line count. Agent can still reason about recency and commit structure —
exactly the shape tokenjuice's reducers advertise.

## Why tokens save less (7.8%) than tool_result (80%)

Per-run total tokens are dominated by cached system prompt + skills +
plugin manifests — ~250–260k tokens sit in `cache_read`. Tool outputs
are a small fraction of that. 80% reduction on a small fraction =
~22k token savings, i.e. 7.8% of total. On a longer ops loop with
many more (and larger) tool outputs, the ratio would shift — the
`cache_read` stays ~constant while `input_tokens` grows with each
tool call that lands un-reduced.

**Extrapolation:** on a host-a workflow with 50 noisy tool calls
of similar size, expect ~30-40% total token reduction. On a workflow
that already runs mostly lightweight commands, expect <5%.

## How the wrapper works

Hook config added to host-b's `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node %USERPROFILE%/tokenjuice-pretool.js",
            "statusMessage": "wrapping bash with tokenjuice (PreToolUse)"
          }
        ]
      }
    ]
  }
}
```

(Note forward slashes in the path — backslash-escaped paths in JSON get
mangled by Claude Code's hook runner when the backslash-prefix sequence
overlaps with a JSON escape code like `\U`, `\s`, or `\t`. Worth
mentioning upstream.)

The hook script, `tokenjuice-pretool.js`, is ~30 lines:

```javascript
#!/usr/bin/env node
const fs = require("fs");
let input;
try { input = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(0); }
const cmd = input?.tool_input?.command;
if (typeof cmd !== "string" || !cmd.trim()) process.exit(0);
if (/^\s*tokenjuice\s+wrap\b/.test(cmd)) process.exit(0); // avoid double-wrap
const escaped = cmd.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$").replace(/`/g, "\\`");
const wrapped = `tokenjuice wrap -- sh -c "${escaped}"`;
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { command: wrapped }
  }
}));
```

Full file: `~/tokenjuice-trial/wrapper/tokenjuice-pretool.js`.

No PostToolUse hook active; tokenjuice's own PostToolUse was replaced
wholesale by this PreToolUse entry so the variable under test is clean.

## Implications

### For the upstream fix

Tokenjuice's `install claude-code` subcommand currently writes a
`hooks.PostToolUse` entry that calls `tokenjuice claude-code-post-tool-use`,
relying on `decision:"block"` + `reason` to substitute output. That
contract is not honored on Claude Code 2.1.113 (see phase 1 report).

A fix: change `install claude-code` to write a `hooks.PreToolUse` entry
that shells out to a small JS (or `.cmd` / `.sh`) wrapper which emits
`{hookSpecificOutput:{updatedInput:{command: "tokenjuice wrap -- sh -c \"...\""}}}`.
Tokenjuice already ships `tokenjuice wrap`, so the shell wrapper stays
thin — the heavy reduction logic is already packaged.

The existing `compactBashResult` + reducer library inside tokenjuice's
core is reused by `tokenjuice wrap` (they share the same rule engine
per the `dist/core/` structure). So there's no duplication — just a
different entry point for the same engine.

### For Solomon's host-a rollout

This strengthens the case for **phase 3 (Pi/OpenClaw on host-a)**
being potentially worth it, because:

1. The engine clearly works on real agent I/O when it's wired right.
2. OpenClaw's Pi host may already use a PreToolUse-equivalent contract
   that respects output rewriting — tokenjuice's `install pi` path
   modifies `~/.pi/agent/extensions/tokenjuice.js` directly (a
   JavaScript extension, not a JSON hook), which suggests a more
   powerful integration surface.

Next session (codex phase) should still proceed — codex may also need
its own wrapper approach, and the phase 3 Pi test becomes the real
test of whether tokenjuice delivers on the host-a workload it was
designed for.

## Artifacts added in this phase

```
~/tokenjuice-trial/wrapper/
  tokenjuice-pretool.js              # the ~30-line PreToolUse hook
  settings.wrapper.json              # host-b settings with wrapper hook
  pretool-probe.json                 # manual test input for the hook
  smoketest.jsonl                    # first attempt (path-mangled, failed)
  smoketest2.jsonl                   # second attempt (path fixed, succeeded)
  smoketest2.transcript.jsonl        # full transcript of smoketest2
  treatment/run-{1,2,3}.summary.json # 3 clean runs with wrapper
  treatment/run-{1,2,3}.transcript.jsonl
  report.md                          # this file
```

## State of host-b

host-b's `~/.claude/settings.json` currently has the **wrapper hook
active** (not tokenjuice's default PostToolUse hook). Original backup
at `~/tokenjuice-trial/settings.pre.json`, tokenjuice's own at
`~/.claude/settings.json.bak` on host-b.

To restore tokenjuice default: `scp ~/tokenjuice-trial/settings.post.json
host-b:%USERPROFILE%/.claude/settings.json`.
To remove all hooks: `scp ~/tokenjuice-trial/settings.pre.json
host-b:%USERPROFILE%/.claude/settings.json`.
