/**
 * DIY wrapper extension — PreToolUse command mutation.
 *
 * Mutates each bash command to pipe through head+tail truncation,
 * producing at most ~7k chars (5k head + 2k tail + size annotation).
 * No tokenjuice dependency — tests whether a dumb wrapper can
 * compete with tokenjuice's specialized reducers.
 */
export default (pi) => {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;
    const cmd = event.input?.command;
    if (typeof cmd !== "string" || !cmd.trim()) return;
    const escaped = cmd.replace(/'/g, "'\\''");
    const tmp = `/tmp/pi-wrap-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    // NOTE: shell variables ($bytes, $lines, $rc) must be written as literal
    // '$' in the emitted shell string — in JS template literals we escape
    // the dollar sign so JS won't interpolate.
    const wrapped =
      `( sh -c '${escaped}' ) >${tmp} 2>&1; ` +
      `rc=$?; ` +
      `bytes=$(wc -c <${tmp}); ` +
      `lines=$(wc -l <${tmp}); ` +
      `if [ "$bytes" -le 2048 ]; then cat ${tmp}; ` +
      `else head -c 1024 ${tmp}; echo; ` +
      `echo "... [truncated: $bytes bytes / $lines lines total, kept head 1k + tail 512b] ..."; ` +
      `tail -c 512 ${tmp}; fi; ` +
      `rm -f ${tmp}; exit $rc`;
    event.input.command = wrapped;
    return undefined;
  });
};
