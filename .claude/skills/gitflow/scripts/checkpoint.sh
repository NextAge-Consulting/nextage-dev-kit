#!/bin/bash
# gitflow checkpoint: fast WIP commit + push.
# Usage: checkpoint.sh [optional message suffix]
#
# Checkpoints skip typecheck (speed over compliance — WIP commits are not shipped).
# Message format: 🔖 wip: <timestamp> [- suffix]
#
# Branch behavior:
#   - On main/master: auto-create wip/<timestamp> branch, then checkpoint on it.
#   - On any other branch: checkpoint in place.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

TIMESTAMP=$("$SCRIPT_DIR/get_timestamp.sh")

SUFFIX=""
if [ $# -gt 0 ]; then
    SUFFIX=" - $*"
fi

MESSAGE="🔖 wip: ${TIMESTAMP}${SUFFIX}"

CURRENT_BRANCH=$(git branch --show-current)
if is_protected_branch "$CURRENT_BRANCH"; then
    WIP_NAME=$(resolve_collision "$(make_wip_branch_name)")
    echo "gitflow: on $CURRENT_BRANCH — auto-creating $WIP_NAME for checkpoint." >&2
    create_and_switch "$WIP_NAME"
    CURRENT_BRANCH="$WIP_NAME"
fi

git add -A

if git diff --cached --quiet; then
    echo "gitflow: nothing to checkpoint." >&2
    exit 5
fi

echo "gitflow: checkpoint: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE"

# Push via safe_push — handles missing-upstream AND wrong-upstream (e.g.
# origin/main leaked through from pre-fix worktree creation).
safe_push

echo "gitflow: checkpoint pushed on $CURRENT_BRANCH." >&2
