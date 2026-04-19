#!/usr/bin/env node
// PreToolUse hook: rewrites Bash commands to use `tokenjuice wrap -- sh -c "<cmd>"`
// so the tool_result returned to Claude contains reduced output natively.
// Validates fix Option B from the 2026-04-19 tokenjuice trial report.
const fs = require("fs");

let input;
try {
  input = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  process.exit(0);
}

const cmd = input && input.tool_input && input.tool_input.command;
if (typeof cmd !== "string" || !cmd.trim()) process.exit(0);

// Skip if already wrapped (avoid double-wrap loops)
if (/^\s*tokenjuice\s+wrap\b/.test(cmd)) process.exit(0);

// Escape for double-quoted sh -c context
const escaped = cmd.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\$/g, "\\$").replace(/`/g, "\\`");
const wrapped = `tokenjuice wrap -- sh -c "${escaped}"`;

const out = {
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "allow",
    updatedInput: { command: wrapped }
  }
};
process.stdout.write(JSON.stringify(out));
