#!/bin/bash
# Usage: ./run.sh <baseline|tokenjuice|wrapper> <run-number>
set -euo pipefail
phase="$1"
n="$2"
root="$(dirname "$0")"
out_dir="${root}/${phase}"
mkdir -p "$out_dir"
jsonl="${out_dir}/run-${n}.jsonl"
summary="${out_dir}/run-${n}.summary.json"
prompt_file="${root}/gauntlet.txt"

ext_dir="${HOME}/.pi/agent/extensions"
mkdir -p "$ext_dir"

# Stage extensions for the given phase. Nothing is installed other than
# what the phase requires.
rm -f "${ext_dir}"/*.js
case "$phase" in
  baseline)
    : # no extensions
    ;;
  tokenjuice)
    cp "${root}/_assets/tokenjuice.js" "${ext_dir}/tokenjuice.js"
    ;;
  wrapper)
    cp "${root}/wrapper.js" "${ext_dir}/wrapper.js"
    ;;
  *) echo "unknown phase: $phase" >&2; exit 1 ;;
esac

# Always include a probe for observability (baseline gets probe-only).
cp "${root}/_assets/probe.js" "${ext_dir}/probe.js"
: > /tmp/pi-hook-probe.log

export $(grep -v '^#' ~/.openclaw/workspace/.env | grep -v '^$' | xargs)

echo "[run.sh] phase=${phase} run=${n} -> ${jsonl}"
start=$(date +%s)
pi --provider zai --model glm-4.6 --mode json --no-session \
  -p "$(cat "$prompt_file")" \
  > "$jsonl" 2>&1 || true
end=$(date +%s)
elapsed=$((end - start))

# Persist probe log snapshot alongside run
cp /tmp/pi-hook-probe.log "${out_dir}/run-${n}.probe.log" 2>/dev/null || true

python3 - "$jsonl" "$summary" "$elapsed" "$phase" "$n" <<'PY'
import json, sys
jsonl, summary, elapsed, phase, n = sys.argv[1:6]
elapsed = int(elapsed)
inp = cache_read = cache_write = out = total = 0
turns = 0
commands = 0
tool_results = 0
errors = 0
last_asst_text = ""
with open(jsonl) as f:
    for line in f:
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = ev.get("type")
        if t == "turn_end":
            u = (ev.get("message") or {}).get("usage") or {}
            inp += u.get("input", 0)
            cache_read += u.get("cacheRead", 0)
            cache_write += u.get("cacheWrite", 0)
            out += u.get("output", 0)
            total += u.get("totalTokens", 0)
            turns += 1
        elif t == "tool_execution_end":
            if ev.get("toolName") == "bash":
                commands += 1
                if ev.get("isError"): errors += 1
                tool_results += 1
        elif t == "message_end":
            msg = ev.get("message") or {}
            if msg.get("role") == "assistant":
                for c in msg.get("content", []):
                    if c.get("type") == "text":
                        last_asst_text = c.get("text", "")
s = {
    "phase": phase,
    "run": int(n),
    "input_tokens": inp,
    "cache_read_tokens": cache_read,
    "cache_write_tokens": cache_write,
    "output_tokens": out,
    "total_tokens": total,
    "effective_input_tokens": inp + cache_read,
    "turns": turns,
    "commands_executed": commands,
    "tool_errors": errors,
    "elapsed_seconds": elapsed,
    "last_assistant_text": last_asst_text[:4000],
}
with open(summary, "w") as f:
    json.dump(s, f, indent=2)
print(json.dumps({k:v for k,v in s.items() if k!="last_assistant_text"}))
PY
