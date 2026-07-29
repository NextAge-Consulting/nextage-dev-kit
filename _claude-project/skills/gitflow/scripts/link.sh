#!/bin/bash
# gitflow link: link one or more GitHub issues to the CURRENT branch.
# Usage: link.sh --issues "23,25,26"
#
# Used when additional issues are discovered mid-work on a branch that
# already has linked issues (or started without any). Stores the link in
# branch-scoped git config so /open-pr can inject Closes #N lines into
# the PR body. Best-effort: also moves each issue to In Progress on the
# project board and assigns the current user.
#
# Refuses to run on main/master — branching there would bypass the flow.
#
# Idempotent: re-linking an already-linked issue is a no-op.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=./issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

ISSUES_RAW=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --issues) ISSUES_RAW="$2"; shift 2 ;;
        *) echo "link.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$ISSUES_RAW" ]; then
    echo "link.sh: --issues is required" >&2
    exit 2
fi

ISSUES=$(parse_issue_csv "$ISSUES_RAW")
if [ -z "$ISSUES" ]; then
    echo "link.sh: --issues had no valid issue numbers: '$ISSUES_RAW'" >&2
    exit 2
fi

CURRENT_BRANCH=$(git branch --show-current)
if is_protected_branch "$CURRENT_BRANCH"; then
    echo "link.sh: refusing to link on '$CURRENT_BRANCH'. Start a branch first with /work <issue#>." >&2
    exit 3
fi

# Validate all issues before applying any side-effects.
for num in $ISSUES; do
    if ! validate_issue "$num" >/dev/null; then
        echo "link.sh: issue #$num inaccessible; aborting without linking anything" >&2
        exit 4
    fi
done

# Apply side-effects per issue. Best-effort for project/assign;
# linking the git config itself cannot fail.
for num in $ISSUES; do
    link_issue_to_branch "$num" "$CURRENT_BRANCH"
    move_issue_to_in_progress "$num"
    assign_issue_to_current_user "$num"
done

echo "gitflow: linked issues to branch '$CURRENT_BRANCH': $ISSUES" >&2

# Dump issue context for Claude's session.
for num in $ISSUES; do
    dump_issue_context "$num"
done
