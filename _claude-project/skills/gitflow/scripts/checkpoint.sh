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
# shellcheck source=./issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

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
    PREVIOUS_BRANCH="$CURRENT_BRANCH"
    create_and_switch "$WIP_NAME"
    CURRENT_BRANCH="$WIP_NAME"
    # Carry any /work <issue#> link parked on main onto the wip branch. A later
    # /commit renames this branch, and `git branch -m` moves the config section
    # with it, so no second migration is needed.
    migrate_branch_linked_issues "$PREVIOUS_BRANCH" "$CURRENT_BRANCH"
fi

git add -A

if git diff --cached --quiet; then
    echo "gitflow: nothing to checkpoint." >&2
    exit 5
fi

echo "gitflow: checkpoint: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE"

# Push via safe_push — handles missing-upstream AND wrong-upstream (e.g.
# origin/main inherited from the branch's start-point).
safe_push

echo "gitflow: checkpoint pushed on $CURRENT_BRANCH." >&2
