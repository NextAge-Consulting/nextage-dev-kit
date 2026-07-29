#!/bin/bash
# Dev Server Guard Hook — enforces rule 4 of `.claude/rules/dev-server.md`:
# "Never kill processes you didn't start."
#
# Rules 1–3 + 5 of the dev-server protocol are behavioral (read the rule
# file, follow it). This hook only catches the rule the user hits hardest:
# killing the dev server mid-test destroys their flow.
#
# Prior versions of this hook also blocked `npm run dev` / `npm start`
# starts outright. That was removed because it over-corrected for a
# separate behavioral problem (reckless starts) that the revised rule
# handles via "always check first" + "use an occupied port". Blocking
# every start forced a permission ping-pong on every legitimate E2E run.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Emergency override — set SKIP_SERVER_GUARD=1 to bypass. Use when the
# user has explicitly authorized killing a specific process.
if [ "$SKIP_SERVER_GUARD" = "1" ]; then
    exit 0
fi

# Only audit Bash-class tool calls.
if [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "mcp__acp__Bash" ]; then
    exit 0
fi

# Block: kill / pkill / fuser targeting dev servers or the ports they run
# on. Matches the common patterns without being exhaustive — a determined
# bypass is possible via SKIP_SERVER_GUARD=1 (which the user gates).
if echo "$COMMAND" | grep -qE "pkill.*vite|pkill.*npm.*dev|pkill.*node.*dev|fuser -k|kill -9.*vite|kill.*\$\(lsof|lsof.*\| *xargs.*kill"; then
    cat <<BLOCK
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "🚫 DEV SERVER KILL BLOCKED\n\nCommand: $COMMAND\n\nRule 4 of .claude/rules/dev-server.md — Never kill processes you didn't start. 99% of the time a dev server is running, the user is actively testing against it. Killing it mid-stream destroys their session.\n\nIf you need to restart a server because it's misbehaving, surface it to the user — don't cull it.\n\nEmergency override (user-authorized only): prefix the command with SKIP_SERVER_GUARD=1"
  }
}
BLOCK
    exit 0
fi

# Everything else — including `npm run dev` starts — is allowed. Rule 1
# ("always check first") + rule 2 ("if the port is occupied, USE IT")
# + rule 5 ("leave servers running after use") govern start behavior.
exit 0
