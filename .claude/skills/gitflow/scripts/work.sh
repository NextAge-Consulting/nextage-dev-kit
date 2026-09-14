#!/bin/bash
# gitflow work: start or resume a body of work on a branch in this checkout.
#
# Usage:
#   work.sh                              # refresh main and stay put, or resume the current branch
#   work.sh --issue <N>                  # ensure a branch, link issue #N, dump its context
#   work.sh --retrieve <branch>          # fetch a teammate's branch and switch to it
#
# Responsibilities:
#   - On main: refresh main from origin and STAY THERE. No branch is cut.
#   - On a feature/wip branch: resume it, untouched.
#   - For --issue: validate, derive a branch slug from the issue title, create the
#     branch, link the issue via git config, transition to In Progress, assign the
#     current user, dump issue context for the Claude session.
#   - For --retrieve: fetch the remote branch, fast-forward any local copy, switch.
#
# One checkout, one branch at a time. Parallel bodies of work are not a thing
# this shop does; `git switch` is how you move between them when it is.
#
# WHY BARE `work.sh` DOES NOT CUT A BRANCH
# ----------------------------------------
# It used to, and that was wrong in both directions.
#
# It removed a choice that had not been made yet. At session-init nobody knows
# whether the session is a feature, a kit/infra change, or a question answered
# from the handoff — and `/ship-main` REFUSES unless you are on main, so cutting
# a branch here guaranteed the infra path was blocked before it began. The two
# commands contradicted each other on every infra session.
#
# And it bought nothing, because the safety already exists downstream and is
# strictly better there: `/commit` on main auto-creates a branch named from the
# commit MESSAGE (no wip placeholder, no rename), `/checkpoint` on main
# auto-creates a wip branch, and `git-guard.sh` blocks raw `git commit`.
#
# So the branch belongs to the moment the decision is actually made — the first
# commit — not to session-init. `--issue N` still cuts immediately: typing an
# issue number IS the declaration that this is a feature heading for a PR, and
# the issue-derived name beats anything derivable from a message later.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

# ─── Arg parsing ───────────────────────────────────────────────────────────

MODE=""        # "", "issue", "retrieve"
ARG=""         # the value for the mode (issue#, branch)

while [[ $# -gt 0 ]]; do
    case $1 in
        --issue)
            [ -n "$MODE" ] && { echo "work.sh: --issue conflicts with --$MODE" >&2; exit 2; }
            MODE="issue"; ARG="$2"; shift 2 ;;
        --retrieve)
            [ -n "$MODE" ] && { echo "work.sh: --retrieve conflicts with --$MODE" >&2; exit 2; }
            MODE="retrieve"; ARG="$2"; shift 2 ;;
        *)
            # Bare positional numeric → shorthand for --issue
            if [ -z "$MODE" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                MODE="issue"; ARG="$1"; shift 1
            else
                echo "work.sh: unknown option: $1" >&2; exit 2
            fi
            ;;
    esac
done

PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "work.sh: not in a git repository" >&2
    exit 3
}
cd "$PROJECT_ROOT"

# ─── Guard: a retired global /work command shadows this project's copy ─────
# Claude Code resolves command files personal-over-project: with `work.md` in
# BOTH `~/.claude/commands/` and `<project>/.claude/commands/`, the personal one
# wins and the project's copy never loads. The kit used to ship `work.md`
# globally and no longer does — so a machine that installed it once keeps
# running the retired doc forever, silently, while the kit's current copy sits
# there inert.
#
# Nothing in the kit's own maintenance path can fix that: `/sync-dev-kit` does
# not scan `~/.claude/` by design, and there is no installer to reconcile it.
# This script is the only thing that runs on EVERY `/work` — and it runs whichever
# doc won, because both invoke it. So this is the one place the stale file can be
# caught. Fail loud rather than warn: a warning on a session-init command is read
# past, and the whole point is that the failure is otherwise invisible.
GLOBAL_WORK_CMD="$HOME/.claude/commands/work.md"
if [ -f "$GLOBAL_WORK_CMD" ]; then
    cat >&2 <<EOF
work.sh: REFUSING — a retired global /work command is shadowing this project's copy.

  Found:   $GLOBAL_WORK_CMD
  Shadows: $PROJECT_ROOT/.claude/commands/work.md

  Personal commands outrank project commands, so the file above is what /work
  reads — and it is the OLD version, which cuts a wip branch at session-init and
  blocks /ship-main. The kit no longer ships a global /work.

  Fix it with one command, then re-run /work:

      rm "$GLOBAL_WORK_CMD"

  Nothing else is needed. The project's copy takes over immediately.
EOF
    exit 8
fi

# ─── Helper: is the working tree clean? ────────────────────────────────────
# Untracked counts as dirty: an untracked file is usually the bulk of a
# half-finished change, and treating it as "clean" is how work gets stranded.
tree_is_clean() {
    git diff --quiet 2>/dev/null && \
        git diff --cached --quiet 2>/dev/null && \
        [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

# ─── Helper: refresh main, tolerating a dirty tree ─────────────────────────
# fast_forward_local_main refuses on a dirty tree by design — it is also used
# by /catchup, where a dirty tree means something is wrong. Here it does not:
# starting work with edits already in the tree is ordinary (you noticed
# something before you typed /work), and those edits stay exactly where they are.
#
# So: refresh when we can, say so loudly when we cannot, and never block.
# Nothing is lost either way — main is simply left at the commit you already had.
refresh_main_if_possible() {
    if tree_is_clean; then
        if ! fast_forward_local_main; then
            echo "work.sh: could not refresh main from origin (cause above)." >&2
            echo "  Branching off local main as it stands. /catchup once you are online." >&2
        fi
    else
        echo "work.sh: uncommitted changes present — NOT refreshing main from origin." >&2
        echo "  Your changes are untouched. Local main may be behind origin;" >&2
        echo "  /catchup when you want the latest." >&2
    fi
}

# ─── Mode: default ─────────────────────────────────────────────────────────
# On main  → refresh main and stay on it. No branch is cut; see the header for why.
# Elsewhere → resume; this is the re-entry path across consecutive sessions.
mode_default() {
    local branch
    branch=$(git branch --show-current)

    if [ -z "$branch" ]; then
        echo "work.sh: detached HEAD — no branch to start or resume." >&2
        echo "  Inspect with 'git status', then switch to a branch." >&2
        exit 7
    fi

    if is_protected_branch "$branch"; then
        refresh_main_if_possible
        echo "work.sh: on '$branch' — no branch cut; the session has not chosen a path yet." >&2
        echo "  /commit branches from your message · /ship-main commits here · /work <issue#> branches now." >&2
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — they follow you onto whichever path you take)" >&2
        fi
    else
        echo "work.sh: resuming body of work on '$branch'." >&2
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — picking up where you left off)" >&2
        fi
    fi
}

# ─── Mode: --issue <N> ─────────────────────────────────────────────────────
mode_issue() {
    local num="$ARG"
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
        echo "work.sh: --issue requires a numeric issue number, got '$num'" >&2
        exit 2
    fi

    if ! validate_issue "$num" >/dev/null; then
        echo "work.sh: issue #$num inaccessible" >&2
        exit 4
    fi

    local branch
    branch=$(git branch --show-current)

    if [ -z "$branch" ]; then
        echo "work.sh: detached HEAD — refusing to link issue #$num." >&2
        echo "  Inspect with 'git status', then switch to a branch." >&2
        exit 7
    fi

    if is_protected_branch "$branch"; then
        # Fresh start → branch named for the issue.
        refresh_main_if_possible
        local target
        target=$(resolve_collision "$(slug_from_issue "$num")")
        echo "work.sh: starting issue #$num on '$target'." >&2
        create_and_switch "$target" >&2
    else
        # Already on a body of work → /link semantics, one more issue on it.
        echo "work.sh: on branch '$branch' — linking issue #$num to it." >&2
    fi

    link_issue_to_branch "$num"
    move_issue_to_in_progress "$num"
    assign_issue_to_current_user "$num"
    dump_issue_context "$num"
}

# ─── Mode: --retrieve <branch> ─────────────────────────────────────────────
# Fetch someone else's branch and switch to it. Refuses on a dirty tree: your
# own work has to be committed before you leave it, or switching either drags
# it along or blocks halfway. /checkpoint is the one-verb answer.
mode_retrieve() {
    local branch="$ARG"
    if [ -z "$branch" ]; then
        echo "work.sh: --retrieve requires a branch name" >&2
        exit 2
    fi

    if ! tree_is_clean; then
        echo "work.sh: uncommitted changes on '$(git branch --show-current)'." >&2
        echo "  /checkpoint first, then re-run — switching branches with work in the tree" >&2
        echo "  either drags it onto theirs or refuses partway." >&2
        exit 5
    fi

    echo "work.sh: fetching origin/$branch" >&2
    if ! git fetch origin "$branch" 2>/dev/null; then
        echo "work.sh: branch '$branch' not found on origin" >&2
        exit 4
    fi

    # Fetching alone leaves an existing local branch pointing at the old commit.
    sync_local_branch "$branch"

    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch" >&2
    else
        git checkout -b "$branch" "origin/$branch" >&2
    fi
    echo "work.sh: on '$branch'. Your own branch is untouched — 'git switch <yours>' when you are done here." >&2
}

# Fast-forward a local branch to origin when it is strictly behind.
#
# Without this, --retrieve fetches origin/<branch> and then checks out the LOCAL
# branch, so a teammate's pushed commits are fetched and ignored — you land on a
# stale copy with no warning. That breaks the round trip the flag exists for.
#
# Fast-forward ONLY. A local branch carrying commits origin does not have is left
# untouched and reported; silently rewriting it would destroy work.
sync_local_branch() {
    local branch="$1"
    git show-ref --verify --quiet "refs/heads/$branch" || return 0
    git show-ref --verify --quiet "refs/remotes/origin/$branch" || return 0

    local local_sha remote_sha
    local_sha=$(git rev-parse "refs/heads/$branch")
    remote_sha=$(git rev-parse "refs/remotes/origin/$branch")
    [ "$local_sha" = "$remote_sha" ] && return 0

    if ! git merge-base --is-ancestor "$local_sha" "$remote_sha"; then
        echo "work.sh: local '$branch' has commits origin does not have — leaving it as is." >&2
        echo "work.sh:   local  $local_sha" >&2
        echo "work.sh:   origin $remote_sha" >&2
        echo "work.sh: reconcile the two before continuing." >&2
        return 0
    fi

    # Strictly behind. If it is the branch we are standing on, the merge has to
    # happen in the working tree; otherwise moving the ref is enough.
    if [ "$branch" = "$(git branch --show-current)" ]; then
        echo "work.sh: fast-forwarding '$branch' to origin" >&2
        git merge --ff-only "origin/$branch" >&2
    else
        echo "work.sh: fast-forwarding local '$branch' to origin" >&2
        git update-ref "refs/heads/$branch" "$remote_sha"
    fi
}

# ─── Dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in
    "")         mode_default ;;
    "issue")    mode_issue ;;
    "retrieve") mode_retrieve ;;
    *)
        echo "work.sh: internal error — unknown mode '$MODE'" >&2
        exit 99
        ;;
esac
