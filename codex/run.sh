#!/bin/bash
# Usage: ./run.sh <baseline|treatment> <run-number>
set -euo pipefail
phase="$1"
n="$2"
out_dir="$(dirname "$0")/${phase}"
mkdir -p "$out_dir"
jsonl="${out_dir}/run-${n}.jsonl"
summary="${out_dir}/run-${n}.summary.json"
prompt_file="$(dirname "$0")/gauntlet.txt"

hook_args=()
if [ "$phase" = "treatment" ]; then
  hook_args+=(--enable codex_hooks)
fi

echo "[run.sh] phase=${phase} run=${n} -> ${jsonl}"
start=$(date +%s)
codex exec --json \
  "${hook_args[@]}" \
  --dangerously-bypass-approvals-and-sandbox \
  --skip-git-repo-check \
  -C ~/repos/sample-repo-b \
  - < "$prompt_file" > "$jsonl" 2>&1
end=$(date +%s)
elapsed=$((end - start))

# Sum tokens across all turn.completed events
python3 - "$jsonl" "$summary" "$elapsed" <<'PY'
import json, sys
jsonl, summary, elapsed = sys.argv[1], sys.argv[2], int(sys.argv[3])
inp = cache = out = 0
turns = 0
commands = 0
with open(jsonl) as f:
    for line in f:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        if ev.get("type") == "turn.completed":
            u = ev.get("usage", {})
            inp += u.get("input_tokens", 0)
            cache += u.get("cached_input_tokens", 0)
            out += u.get("output_tokens", 0)
            turns += 1
        if ev.get("type") == "item.completed" and ev.get("item", {}).get("type") == "command_execution":
            commands += 1
s = {
    "input_tokens": inp,
    "cached_input_tokens": cache,
    "output_tokens": out,
    "turns": turns,
    "commands_executed": commands,
    "elapsed_seconds": elapsed,
}
with open(summary, "w") as f:
    json.dump(s, f, indent=2)
print(json.dumps(s))
PY
