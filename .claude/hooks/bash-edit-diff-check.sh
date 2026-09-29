#!/bin/bash
# bash-edit-diff-check.sh — SessionStart. Warns when Claude Code will not report the
# files a shell command changes, because bash-edit-guard.sh then cannot run the Edit
# guards over shell edits.
#
# The recording is on in every mode only when `bashEditDiffEnabled` is true in user or
# managed settings, or CLAUDE_CODE_BASH_EDIT_DIFF=1 is in the launch environment. A
# project cannot turn it on: Claude Code ignores both the key and the variable from a
# repository's settings. So this hook resolves the effective value the way Claude Code
# does, and when it is not on:
#   - the user sees a warning naming the one line to add, every session until it is;
#   - Claude is told to make file changes with Edit and Write, which the guards see.
#
# Resolution, highest first:
#   CLAUDE_CODE_BASH_EDIT_DIFF in the environment (1 on, 0 off)
#   managed settings (managed-settings.json and managed-settings.d/*.json)
#   a `false` in the project's .claude/settings.local.json or .claude/settings.json
#   ~/.claude/settings.json
#
# KIT_MANAGED_SETTINGS_DIR overrides the managed-settings directory (the suite uses it).

INPUT=$(cat)
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)}"

if [ -n "${KIT_MANAGED_SETTINGS_DIR:-}" ]; then
    MANAGED_DIR="$KIT_MANAGED_SETTINGS_DIR"
elif [ "$(uname -s)" = "Darwin" ]; then
    MANAGED_DIR="/Library/Application Support/ClaudeCode"
else
    MANAGED_DIR="/etc/claude-code"
fi

PROJECT_DIR="$PROJECT_DIR" MANAGED_DIR="$MANAGED_DIR" python3 -c '
import glob, json, os

def key_in(path):
    """True/False when the file sets bashEditDiffEnabled to a boolean, else None."""
    try:
        v = json.load(open(path, encoding="utf-8")).get("bashEditDiffEnabled")
    except Exception:
        return None
    return v if isinstance(v, bool) else None

def resolve():
    env = os.environ.get("CLAUDE_CODE_BASH_EDIT_DIFF")
    if env == "1":
        return True
    if env == "0":
        return False
    managed = os.environ["MANAGED_DIR"]
    for p in [os.path.join(managed, "managed-settings.json")] + sorted(glob.glob(os.path.join(managed, "managed-settings.d", "*.json"))):
        v = key_in(p)
        if v is not None:
            return v
    project = os.environ.get("PROJECT_DIR") or ""
    if project:
        for name in ("settings.local.json", "settings.json"):
            if key_in(os.path.join(project, ".claude", name)) is False:
                return False
    return key_in(os.path.join(os.path.expanduser("~"), ".claude", "settings.json")) is True

if resolve():
    raise SystemExit(0)

print(json.dumps({
    "systemMessage":
        "⚠️ Shell edits are not being checked by this project’s guards. Add "
        "\"bashEditDiffEnabled\": true to ~/.claude/settings.json and restart Claude Code.",
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext":
            "Claude Code is not reporting which files shell commands change in this session, "
            "so the project’s file guards cannot see edits made through Bash. Make every "
            "file change in this session with the Edit and Write tools."}}))
'
exit 0
