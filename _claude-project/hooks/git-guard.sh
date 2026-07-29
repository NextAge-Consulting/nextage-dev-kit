#!/bin/bash
# Git Guard Hook (destructive-only)
# Blocks destructive git invocations that can cause data loss.
# CI gates (commitlint, typecheck on PR) and /merge's self-gating handle workflow routing —
# this hook handles only what CI cannot catch: local destructive operations.
#
# Bypass: prefix the command with SKIP_GIT_GUARD=1 under explicit user authorization.

INPUT=$(cat)
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

# Strip leading VAR=value prefixes
CLEAN_COMMAND=$(echo "$COMMAND" | sed 's/^\([A-Za-z_][A-Za-z0-9_]*=[^ ]* *\)\+//')

# Parse compound commands (;, &&, ||, |)
# nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering - intentional: splitting on newlines for the next line's word-split; IFS is unset immediately after
IFS=$'\n'
PARTS=($(echo "$CLEAN_COMMAND" | sed 's/;/\n/g; s/&&/\n/g; s/||/\n/g; s/|/\n/g'))
unset IFS

for PART in "${PARTS[@]}"; do
    PART=$(echo "$PART" | xargs 2>/dev/null || echo "$PART")
    [ -z "$PART" ] && continue

    PART=$(echo "$PART" | sed 's/^\([A-Za-z_][A-Za-z0-9_]*=[^ ]* *\)\+//')

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
done

exit 0
