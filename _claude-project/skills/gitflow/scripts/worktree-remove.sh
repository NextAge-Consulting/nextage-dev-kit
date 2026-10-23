#!/bin/bash
# gitflow worktree-remove: remove one finished worktree and its local branch.
# Usage: worktree-remove.sh <worktree-path> [--branch <name>]
#
# Run from the primary checkout, AFTER the session has left the worktree
# (ExitWorktree, action keep): deleting the folder a session stands in breaks every
# shell the session spawns from then on. /merge and /deploy run it as their last step.
#
# Removes only when nothing can be lost:
#   - On a branch: that branch's PR is merged. Detached (kept to /deploy from): HEAD is
#     already on origin/main.
#   - Clean: no modified and no untracked files. Gitignored files — node_modules, the
#     linked .env, the worktree's own handoff — go with it.
# Then `git worktree remove` (never --force), `git worktree prune`, and the local
# branch. A refusal names its reason and removes nothing.
#
# Idempotent: a folder already gone is pruned; a branch already gone is skipped.
# Touches the one worktree named, never any other.
#
# Exit codes: 0 removed (or nothing left to remove) · 2 usage · 3 run from inside the
# worktree · 4 its work is not merged · 5 it has uncommitted changes · 6 git refused
# the removal · 7 GitHub could not say whether the PR merged

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

WT=""
BRANCH=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --branch) BRANCH="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        -*) echo "worktree-remove.sh: unknown option: $1" >&2; exit 2 ;;
        *)  [ -z "$WT" ] || { echo "worktree-remove.sh: one worktree at a time" >&2; exit 2; }
            WT="$1"; shift ;;
    esac
done
[ -n "$WT" ] || { echo "worktree-remove.sh: usage: worktree-remove.sh <worktree-path> [--branch <name>]" >&2; exit 2; }
WT="${WT%/}"

# A branch is removed only once its PR is merged, which GitHub alone can say.
require_merged() {
    local state
    state=$(pr_state_for_branch "$1")
    case "$state" in
        MERGED) return 0 ;;
        "") echo "worktree-remove.sh: GitHub could not say whether '$1' merged — nothing removed." >&2; exit 7 ;;
        *)  echo "worktree-remove.sh: '$1' is not merged (its PR is $(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')) — nothing removed." >&2; exit 4 ;;
    esac
}

delete_branch() {
    local b="$1"
    [ -n "$b" ] || return 0
    if ! git show-ref --verify --quiet "refs/heads/$b"; then
        return 0
    fi
    # Squash-merged, so `-d` would call it unmerged; the PR's state was checked instead.
    if git branch -D "$b" >/dev/null; then
        echo "worktree-remove.sh: deleted local branch $b." >&2
    else
        echo "worktree-remove.sh: could not delete local branch $b (git's reason above)." >&2
        return 1
    fi
}

if [ ! -d "$WT" ]; then
    git worktree prune
    echo "worktree-remove.sh: $WT is already gone; pruned git's record of it." >&2
    if [ -n "$BRANCH" ] && git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        require_merged "$BRANCH"
        delete_branch "$BRANCH" || exit 6
    fi
    exit 0
fi

WT=$(cd "$WT" && pwd -P)
if [ "$WT" = "$(cd "$(primary_checkout_root)" && pwd -P)" ]; then
    echo "worktree-remove.sh: $WT is the primary checkout — never removed." >&2
    exit 6
fi
HERE=$(pwd -P)
case "$HERE/" in
    "$WT/"*)
        echo "worktree-remove.sh: run from inside $WT — leave it first (ExitWorktree, action keep), then run this from the primary checkout." >&2
        exit 3 ;;
esac

if ! LISTING=$(git worktree list --porcelain); then
    echo "worktree-remove.sh: 'git worktree list' failed — nothing removed." >&2
    exit 6
fi
FOUND=0 ON=""
while IFS= read -r line; do
    case "$line" in
        "worktree "*) [ "$FOUND" -eq 1 ] && break; dir="${line#worktree }"
                      [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$WT" ] && FOUND=1 ;;
        "branch refs/heads/"*) [ "$FOUND" -eq 1 ] && ON="${line#branch refs/heads/}" ;;
    esac
done <<< "$LISTING"
if [ "$FOUND" -eq 0 ]; then
    echo "worktree-remove.sh: $WT is not a worktree of this repository — nothing removed." >&2
    exit 6
fi
[ -n "$ON" ] && BRANCH="$ON"

if [ -n "$ON" ]; then
    require_merged "$ON"
else
    if ! git -C "$WT" fetch -q origin main; then
        echo "worktree-remove.sh: could not fetch origin/main to check the detached worktree — nothing removed." >&2
        exit 7
    fi
    if ! git -C "$WT" merge-base --is-ancestor HEAD origin/main; then
        echo "worktree-remove.sh: $WT is detached at a commit origin/main does not have — nothing removed." >&2
        exit 4
    fi
    if [ -n "$BRANCH" ] && git show-ref --verify --quiet "refs/heads/$BRANCH"; then
        require_merged "$BRANCH"
    fi
fi

if ! DIRTY=$(git -C "$WT" status --porcelain --untracked-files=all); then
    echo "worktree-remove.sh: 'git status' failed in $WT — nothing removed." >&2
    exit 6
fi
if [ -n "$DIRTY" ]; then
    echo "worktree-remove.sh: $WT has uncommitted changes — nothing removed:" >&2
    printf '%s\n' "$DIRTY" | sed 's/^/  /' >&2
    exit 5
fi

if ! git worktree remove "$WT"; then
    echo "worktree-remove.sh: git refused to remove $WT (its reason above) — nothing removed." >&2
    exit 6
fi
git worktree prune
echo "worktree-remove.sh: removed worktree $WT." >&2
delete_branch "$BRANCH" || exit 6
