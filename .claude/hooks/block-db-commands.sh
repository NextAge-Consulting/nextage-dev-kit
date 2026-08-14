#!/bin/bash

# Drizzle/migration guard — default-DENY with an explicit-approval bypass.
# The rule this enforces (constitution §V): schema changes are never run on
# Claude's own judgment. When the human has explicitly approved a run in the
# current conversation, Claude prefixes the command with SKIP_DB_GUARD=1 and
# it passes. Same trust model as git-guard's SKIP_GIT_GUARD=1.

# Read input from Claude Code
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Check if this is a Bash command with database operations
if [ "$TOOL_NAME" = "Bash" ] || [ "$TOOL_NAME" = "mcp__acp__Bash" ]; then
    if echo "$COMMAND" | grep -E "(db:generate|db:migrate|db:push|drizzle-kit)" > /dev/null; then
        # Explicit-approval bypass: the human authorized this run.
        if echo "$COMMAND" | grep -q "^SKIP_DB_GUARD=1"; then
            exit 0
        fi
        # Emit via a JSON encoder, never string interpolation: a command carrying a
        # double quote (`db:generate -- --name="add user table"` — the normal way to
        # name a migration) produced an unparseable payload, and an unparseable deny
        # is silently DISCARDED, letting the very command this guards run unguarded.
        python3 -c '
import json, sys
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 DATABASE COMMAND BLOCKED\n\nYou attempted to run: " + sys.argv[1] + "\n\n"
        "Per constitution §V: drizzle/migration commands run ONLY with the human'"'"'s "
        "explicit approval in the current conversation.\n\n"
        "If the human has ALREADY approved this specific run: re-run it prefixed with "
        "SKIP_DB_GUARD=1.\n"
        "If not: modify schema files only, then ask for approval to run "
        "db:generate / db:migrate.\nNever use db:push."}}))
' "$COMMAND"
        exit 0
    fi
fi

# Allow all other commands
exit 0
