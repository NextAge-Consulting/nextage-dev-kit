#!/bin/bash
# timeout Guard — refuses a shell command that runs `timeout` or `gtimeout`.
#
# macOS ships neither, so `timeout 180 <check> | tail` exits 127 behind the pipe and the
# check reads as clean. The Bash tool's own `timeout` parameter limits a command on every
# platform and cannot fail that way, so the guard refuses the word on every platform,
# Linux included, where it would work.
#
# Only commands this machine runs are judged: the command is tokenized as the shell does
# (quotes respected, heredoc bodies dropped) and split on | || && ; & ( ) and newlines.
# The first word of each segment, after VAR=value assignments and the wrappers below, is
# the command. `--timeout 30`, a quoted "timeout", and `ssh host 'timeout 30 …'` (run on
# the remote machine) all pass.
#
# Emergency override (user-authorized only): prefix with SKIP_TIMEOUT_GUARD=1

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

INPUT=$(cat)
require_tools PreToolUse jq python3
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

if [ "${SKIP_TIMEOUT_GUARD:-}" = "1" ] || printf '%s' "$COMMAND" | grep -q "^SKIP_TIMEOUT_GUARD=1"; then
    exit 0
fi
if [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "mcp__acp__Bash" ]; then
    exit 0
fi
[ -n "$COMMAND" ] || exit 0

python3 -c '
import json, re, shlex, sys
cmd = sys.argv[1]

# Drop heredoc bodies: they are data, not commands.
lines, out, delim = cmd.split("\n"), [], None
for line in lines:
    if delim is not None:
        if line.strip() == delim: delim = None
        continue
    out.append(line)
    m = re.search(r"<<-?\s*([\"\x27]?)(\w+)\1", line)
    if m: delim = m.group(2)
text = "\n".join(out)

WRAPPERS = {"sudo", "env", "command", "exec", "nice", "nohup", "time", "builtin", "xargs"}
try:
    lex = shlex.shlex(text, posix=True, punctuation_chars="|&;()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    raise SystemExit  # unbalanced quotes: the shell will refuse it; nothing to judge

found, first = None, True
for tok in tokens:
    if tok and set(tok) <= set("|&;()\n"):
        first = True
        continue
    if not first: continue
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", tok) or tok in WRAPPERS or (tok.startswith("-") and tok != "-"):
        continue
    if tok.rsplit("/", 1)[-1] in ("timeout", "gtimeout"):
        found = tok
        break
    first = False

if found:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason":
            "🚫 `" + found + "` BLOCKED\n\n"
            "macOS has no `timeout`: the command exits 127, and behind a pipe or a redirect "
            "that failure is invisible, so the step reads as passing.\n\n"
            "Drop `" + found + "` and set the Bash tool'"'"'s `timeout` parameter (milliseconds) "
            "instead — it limits the command on every platform."}}))
' "$COMMAND"
exit 0
