#!/bin/bash
# Drive the full 30-run trial: 10 baseline + 10 tokenjuice + 10 wrapper.
# Interleave cohorts so prompt-cache warmth is roughly comparable across
# cohorts: round 1 = baseline.1, tokenjuice.1, wrapper.1; round 2 = ...
set -euo pipefail
root="$(dirname "$0")"
for i in $(seq 1 10); do
  for phase in baseline tokenjuice wrapper; do
    cd ~/repos/sample-repo-b
    "$root/run.sh" "$phase" "$i" 2>&1 | tail -2
    sleep 2
  done
done
