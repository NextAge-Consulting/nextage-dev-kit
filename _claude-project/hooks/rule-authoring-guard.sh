#!/bin/bash
# Rule Authoring Guard — puts the rule-authoring rules in front of Claude at the moment
# it changes a rule-prose file (rule-prose.sh defines the set).
#
# PreToolUse on Edit|Write|MultiEdit. The FIRST change to each rule-prose file in a
# session is denied. The first deny of the session carries the full text of the
# `rule-authoring` skill; later ones point back at it. Claude rewrites the change with
# the rules in hand; every later change to that same file in the session passes. One
# deny per file — never a loop.
#
# PostCompact: clears the full-text marker, so the next deny carries the rules again.
#
# Shell edits reach this hook through bash-edit-guard.sh, which replays each file a
# Bash command changed through every Edit guard. There the change is already on disk,
# so the same deny tells Claude to review and fix it in place.
#
# Override (user-authorized only): SKIP_RULE_AUTHORING=1.

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rule-prose.sh
source "$HOOK_DIR/rule-prose.sh"

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)

# Markers are per session. Without a session id, key on cwd so the caps still hold
# rather than degrading to a deny on every change.
KEY="$SESSION_ID"
[ -n "$KEY" ] || KEY="cwd-$(printf '%s' "$CWD" | shasum -a 256 | awk '{print $1}')"
MARKER_DIR="${TMPDIR:-/tmp}/.claude-rule-authoring-files-${KEY}"
FULL_SENT="$MARKER_DIR/full-text-sent"

# Compaction may summarize the rules away, so the next deny carries them in full again.
if [ "$EVENT" = "PostCompact" ]; then
    rm -f "$FULL_SENT" 2>/dev/null
    exit 0
fi

[ "${SKIP_RULE_AUTHORING:-}" = "1" ] && exit 0

case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

is_rule_prose "$FILE_PATH" || exit 0

# One deny per file per session.
MARKER="$MARKER_DIR/$(printf '%s' "$FILE_PATH" | shasum -a 256 | awk '{print $1}')"
[ -f "$MARKER" ] && exit 0
mkdir -p "$MARKER_DIR" 2>/dev/null && : > "$MARKER" 2>/dev/null || exit 0

# The full rules go out once per session (and again after a compaction); later files
# get a one-line reminder that points back at them.
FULL=1
if [ -f "$FULL_SENT" ]; then FULL=0; else : > "$FULL_SENT" 2>/dev/null; fi

SKILL="$HOOK_DIR/../skills/rule-authoring/SKILL.md"

python3 -c '
import json, sys
path, skill, full = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
head = ("📐 " + path + " is rule prose. If this change was refused before landing, make it "
        "again to the rule-authoring rules; if it already landed through a shell command, "
        "review it against them and fix it in place. This file will not be stopped again "
        "this session.")
if full:
    try:
        text = open(skill, encoding="utf-8").read()
        if text.startswith("---"):
            end = text.find("\n---", 3)
            if end != -1:
                text = text[end + 4:]
        text = text.strip()
    except OSError:
        text = "(The rule-authoring skill was not found. Invoke it with the Skill tool.)"
    reason = head + "\n\n" + text
else:
    reason = head + " The rules were given in full earlier this session."
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": reason}}))
' "$FILE_PATH" "$SKILL" "$FULL"

exit 0
