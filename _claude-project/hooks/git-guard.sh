#!/bin/bash
# Git Guard Hook
# Blocks two classes of git invocation:
#   1. Destructive operations that can cause data loss (reset, restore, revert,
#      clean, checkout-of-files).
#   2. Raw `git commit` — commits must go through the gitflow commands so the
#      changelog, conventional-commit format, and version bookkeeping stay correct.
#
# The commit block does NOT interfere with gitflow itself. This hook inspects the
# top-level command string of a Bash tool call; gitflow's own `git commit
# --no-verify` runs as a subprocess inside commit.sh / checkpoint.sh /
# ship-main.sh / catchup.sh / deploy.sh, which the hook never sees. No bypass
# token or allowlist is needed.
#
# Scope: fires only on Claude's Bash tool calls. A human committing from a
# terminal or an IDE is out of reach — deliberately so. The kit does not manage
# .git/hooks (they cannot be tracked in git and do not survive a clone), so
# terminal-side enforcement is out of scope rather than half-delivered.
#
# CI gates (commitlint, typecheck on PR) and /merge's self-gating remain the
# authority on workflow routing; this hook is the local fast-fail.
#
# Bypass: prefix the command with SKIP_GIT_GUARD=1 under explicit user authorization.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

INPUT=$(cat)
require_tools PreToolUse jq python3
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only process Bash-family tool calls
if [ "$TOOL_NAME" != "Bash" ] && [ "$TOOL_NAME" != "mcp__acp__Bash" ]; then
    exit 0
fi

# Explicit bypass
if echo "$COMMAND" | grep -q "^SKIP_GIT_GUARD=1"; then
    exit 0
fi

deny() {
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$1"
    exit 0
}

# Drop heredoc BODIES before parsing. A heredoc body is data being written to a file,
# never a command being run — so documenting `git reset` used to trip this guard, and
# the kit's own rules quote every command in this list. A false block here stops
# ordinary writing dead and teaches the bypass as a habit.
# Any failure in the stripper falls back to the raw command: fail closed.
SCAN_COMMAND=$(python3 -c '
import re, sys
lines = sys.argv[1].split("\n")
out, i = [], 0
while i < len(lines):
    out.append(lines[i])
    m = re.search(r"<<-?\s*[\x27\"]?([A-Za-z_][A-Za-z0-9_]*)[\x27\"]?", lines[i])
    if m:
        delim = m.group(1)
        i += 1
        while i < len(lines) and lines[i].strip() != delim:
            i += 1
    i += 1
print("\n".join(out))
' "$COMMAND" 2>/dev/null) || SCAN_COMMAND="$COMMAND"
[ -n "$SCAN_COMMAND" ] || SCAN_COMMAND="$COMMAND"

# Split into simple commands and normalize each git invocation to `git <subcommand> …`:
# segments split on ; && || | & and newlines, subshell and group brackets dropped,
# VAR=value prefixes dropped, and git's global options (-C <dir>, -c <k=v>, --no-pager,
# --git-dir=…) dropped — so `(cd "/a b" && git -C x commit)` is judged as `git commit`.
# One normalized command per output line; non-git segments are omitted.
# Any failure in the normalizer falls back to scanning the raw command: fail closed.
# shellcheck disable=SC2016 # the single-quoted body is Python source; "$(" in it is a Python string, not an expansion
PARTS_TEXT=$(python3 -c '
import re, shlex, sys
GLOBAL_WITH_ARG = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
for seg in re.split(r"\|\||&&|[;|&\n]", sys.argv[1]):
    try:
        toks = shlex.split(seg)
    except ValueError:
        toks = seg.split()
    toks = [t.strip("(){}`") if t not in ("(", ")", "{", "}") else "" for t in toks]
    toks = [t for t in toks if t]
    toks = [t[2:] if t.startswith("$(") else t for t in toks]
    while toks and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0]):
        toks.pop(0)
    if not toks or toks[0] != "git":
        continue
    i = 1
    while i < len(toks) and toks[i].startswith("-"):
        i += 2 if toks[i] in GLOBAL_WITH_ARG else 1
    print(" ".join(["git"] + toks[i:]))
' "$SCAN_COMMAND" 2>/dev/null) || PARTS_TEXT="$SCAN_COMMAND"

PARTS=()
while IFS= read -r PART_LINE; do
    # Python on Windows ends each line with CRLF; a stray CR defeats every `$` anchor below.
    PARTS+=("${PART_LINE%$'\r'}")
done <<< "$PARTS_TEXT"

for PART in "${PARTS[@]}"; do
    [ -z "$PART" ] && continue

    echo "$PART" | grep -q "^git " || continue

    # === DESTRUCTIVE OPERATIONS — blocked ===

    if echo "$PART" | grep -qE "^git reset(\s|$)"; then
        deny "GIT RESET BLOCKED\\n\\nAttempted: $PART\\n\\nDESTRUCTIVE — discards commits or staging. Data can be lost.\\nNEVER run without explicit user direction. Fix problems with Read/Edit/Write instead.\\n\\nEmergency override: SKIP_GIT_GUARD=1 (user authorization required)."
    fi

    if echo "$PART" | grep -qE "^git restore(\s|$)"; then
        deny "GIT RESTORE BLOCKED\\n\\nAttempted: $PART\\n\\nDESTRUCTIVE — discards file changes. Use Edit tool to restore content instead.\\n\\nEmergency override: SKIP_GIT_GUARD=1."
    fi

    if echo "$PART" | grep -qE "^git revert(\s|$)"; then
        deny "GIT REVERT BLOCKED\\n\\nAttempted: $PART\\n\\nCreates a commit that undoes previous changes. Requires explicit user intent — often confused with 'edit file to undo a change'.\\n\\nEmergency override: SKIP_GIT_GUARD=1."
    fi

    if echo "$PART" | grep -qE "^git clean(\s|$)"; then
        deny "GIT CLEAN BLOCKED\\n\\nAttempted: $PART\\n\\nDESTRUCTIVE — permanently deletes untracked files. NEVER run without explicit user direction.\\n\\nEmergency override: SKIP_GIT_GUARD=1."
    fi

    if echo "$PART" | grep -qE "^git checkout(\s|$)"; then
        # Block wholesale-working-tree restore: git checkout . / *
        echo "$PART" | grep -qE "^git checkout [.\*]$" && \
            deny "GIT CHECKOUT FILE BLOCKED\\n\\nAttempted: $PART\\n\\nDESTRUCTIVE — restores entire working tree from index, discarding all uncommitted changes.\\n\\nEmergency override: SKIP_GIT_GUARD=1."
        # Allow branch-level operations (create/switch/track/detach) — not file-destructive
        echo "$PART" | grep -qE "^git checkout -[bB] [a-zA-Z0-9_./-]+( [a-zA-Z0-9_./-]+)?$" && continue
        echo "$PART" | grep -qE "^git checkout --track [a-zA-Z0-9_./-]+$" && continue
        echo "$PART" | grep -qE "^git checkout --detach( [a-zA-Z0-9_./-]+)?$" && continue
        # Allow bare branch switch: git checkout <branch>
        echo "$PART" | grep -qE "^git checkout [a-zA-Z0-9_./-]+$" && continue
        deny "GIT CHECKOUT FILE BLOCKED\\n\\nAttempted: $PART\\n\\nDESTRUCTIVE — checking out specific files discards uncommitted changes.\\nFix issues with Read/Edit/Write instead.\\n\\nEmergency override: SKIP_GIT_GUARD=1."
    fi

    # === WORKFLOW ROUTING — blocked ===
    # `git commit-tree` and other `git commit*` subcommands are unaffected: the
    # (\s|$) anchor requires whitespace or end-of-string right after "commit".
    if echo "$PART" | grep -qE "^git commit(\s|$)"; then
        deny "GIT COMMIT BLOCKED\\n\\nAttempted: $PART\\n\\nRaw commits bypass changelog, conventional-commit format, and version bookkeeping.\\nUse the gitflow commands instead:\\n\\n  /commit       - full conventional commit with changelog\\n  /checkpoint   - quick timestamped WIP commit\\n  /ship-main    - commit and push straight to main\\n\\nEmergency override: SKIP_GIT_GUARD=1 (user authorization required)."
    fi
done

exit 0
