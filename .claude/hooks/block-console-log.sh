#!/bin/bash

# Block console.log in projects using Pino logger.
# Activates when any of the project's package manifests names "pino": the root
# package.json, every workspace its `workspaces` globs (or pnpm-workspace.yaml) match,
# and the nearest package.json above the edited file. A monorepo keeps its logger in
# whichever workspace it likes, so no single manifest can stand for the project.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

INPUT=$(cat)
require_tools PreToolUse jq python3
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name' 2>/dev/null)

# Only check the file-writing tools
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
FILE_PATH=$(path_spelling "$FILE_PATH")

# Only check TypeScript/JavaScript files
if ! printf '%s' "$FILE_PATH" | grep -qE '\.(ts|tsx|js|jsx)$'; then
    exit 0
fi

PROJECT_DIR=$(normalize_path "${CLAUDE_PROJECT_DIR:-$PWD}")
REL=$(path_rel_to "$PROJECT_DIR" "$FILE_PATH") || REL=""
if ! python3 -c '
import glob, json, os, re, sys
root, target = sys.argv[1], sys.argv[2]
def manifest_text(path):
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        return ""
root_text = manifest_text(os.path.join(root, "package.json"))
manifests = {os.path.join(root, "package.json")}
patterns = []
try:
    ws = json.loads(root_text).get("workspaces") if root_text else None
except Exception:
    ws = None
if isinstance(ws, dict):
    ws = ws.get("packages")
if isinstance(ws, list):
    patterns += [p for p in ws if isinstance(p, str)]
pnpm = manifest_text(os.path.join(root, "pnpm-workspace.yaml"))
patterns += re.findall(r"^\s*-\s*[\x27\"]?([^\x27\"#\s]+)", pnpm, re.M)
for p in patterns:
    if p.startswith("!"):
        continue
    manifests.update(glob.glob(os.path.join(root, p, "package.json"), recursive=True))
parts = target.split("/")[:-1] if target else []
while parts:
    manifests.add(os.path.join(root, *parts, "package.json"))
    parts.pop()
sys.exit(0 if any("\"pino\"" in manifest_text(m) for m in manifests) else 1)
' "$PROJECT_DIR" "$REL" 2>/dev/null; then
    exit 0
fi

# Get the content being written
# MultiEdit carries neither new_string nor content — its payload is edits[].new_string.
# Without that branch this guard is INVOKED on a MultiEdit and matches nothing, which is
# an allow that looks exactly like a pass.
NEW_CONTENT=$(printf '%s' "$INPUT" | jq -r '
    .tool_input.new_string
    // .tool_input.content
    // ([.tool_input.edits[]?.new_string] | join("\n"))
    // ""')

# Check for console.log patterns
if printf '%s' "$NEW_CONTENT" | grep -qE 'console\.(log|error|warn|info|debug)'; then
    # Emit via a JSON encoder, never string interpolation. The echoed-back snippet is
    # ATTACKER-SHAPED by construction: it is the user's own source, so it routinely
    # carries quotes, backslashes and backticks. A `sed 's/"/\\"/g'` pass escapes
    # quotes but not backslashes, so `console.log("she said \"hi\"")` produced an
    # unparseable payload — and an unparseable deny is silently DISCARDED, letting the
    # console.log straight through.
    #
    # The content arrives on STDIN, never as an argv. A Write carries the WHOLE FILE, and
    # an argv is bounded by ARG_MAX — so a large enough file made python3 die with E2BIG,
    # which prints nothing and falls through to the `exit 0` below. That is an ALLOW: the
    # guard failed open on exactly the large files most likely to be carrying a stray
    # console.log. stdin has no such bound.
    printf '%s' "$NEW_CONTENT" | python3 -c '
import json, re, sys
content = sys.stdin.read()
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
        "See: .claude/rules/typescript-rules.md §II (Logging)"}}))
'
    exit 0
fi

exit 0
