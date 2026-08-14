#!/bin/bash

# Block console.log in projects using Pino logger
# Only activates if package.json contains "pino" dependency

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only check Edit and Write tools
if [ "$TOOL_NAME" != "Edit" ] && [ "$TOOL_NAME" != "Write" ]; then
    exit 0
fi

# Check if project uses Pino (skip if not)
if [ ! -f "package.json" ]; then
    exit 0
fi

if ! grep -q '"pino"' package.json 2>/dev/null; then
    # Also check for monorepo shared package
    if [ -f "packages/shared/package.json" ]; then
        if ! grep -q '"pino"' packages/shared/package.json 2>/dev/null; then
            exit 0
        fi
    else
        exit 0
    fi
fi

# Get the content being written
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
NEW_CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // .tool_input.content // ""')

# Only check TypeScript/JavaScript files
if ! echo "$FILE_PATH" | grep -qE '\.(ts|tsx|js|jsx)$'; then
    exit 0
fi

# Check for console.log patterns
if echo "$NEW_CONTENT" | grep -qE 'console\.(log|error|warn|info|debug)'; then
    # Emit via a JSON encoder, never string interpolation. The echoed-back snippet is
    # ATTACKER-SHAPED by construction: it is the user's own source, so it routinely
    # carries quotes, backslashes and backticks. A `sed 's/"/\\"/g'` pass escapes
    # quotes but not backslashes, so `console.log("she said \"hi\"")` produced an
    # unparseable payload — and an unparseable deny is silently DISCARDED, letting the
    # console.log straight through.
    python3 -c '
import json, re, sys
content = sys.argv[1]
snippet = "\n".join(
    [l for l in content.splitlines()
       if re.search(r"console\.(log|error|warn|info|debug)", l)][:3])
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason":
        "🚫 CONSOLE.LOG BLOCKED\n\nThis project uses Pino for structured logging.\n\n"
        "You wrote:\n" + snippet + "\n\n"
        "Use Pino instead:\n"
        "  import { logger } from \"~/lib/logger\";\n"
        "  logger.info(\"message\");\n"
        "  logger.error({ err }, \"error message\");\n\n"
        "CLIENT-SIDE CODE IS NOT AN EXCEPTION. Pino has a browser build; the logger\n"
        "should detect its environment and drop the transport in the browser. If it\n"
        "does not, fix the logger — do NOT bypass this hook and do NOT leave the\n"
        "catch empty (constitution §X).\n\n"
        "See: .claude/rules/typescript-rules.md §II (No Console.log)"}}))
' "$NEW_CONTENT"
    exit 0
fi

exit 0
