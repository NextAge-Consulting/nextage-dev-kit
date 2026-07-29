#!/bin/bash
# gitflow merge: squash-merge current branch's PR after CI passes, then clean up the worktree.
# Usage: merge.sh [--pr <number>] [--base main] [--force-unchecked]
#
# If --pr is not provided, the script uses the PR associated with the current branch.
# If multiple open PRs exist for the current branch, the script lists them and exits —
# caller must re-invoke with --pr <number>.
#
# --force-unchecked bypasses the CI-passed gate. Use only for emergency hotfixes with
# explicit user authorization.
#
# Worktree cleanup (post-merge):
#   - The active worktree (where /merge was invoked from) is always removed.
#   - Primary repo's local main is synced to the new origin/main.
#   - If the active worktree was `current/`, it is removed. Next `/work`
#     recreates it fresh on a new wip/<timestamp> branch off origin/main.
#   - If the active worktree was a compartment, the compartment is removed.
#     `current/` is left alone if it has any work (uncommitted changes OR
#     commits ahead of origin/main). If `current/` is truly empty (a fresh
#     wip branch with nothing in it), it is removed too so the next `/work`
#     gets a fresh start. Either way, a warning is printed if `current/`
#     remains and may be out of date with the new main.
#
# Note: current/ never holds the main branch — it always holds a wip/*
# or feature branch. Therefore current/ is never "fast-forwarded to main";
# integrating new main into current/'s branch is the user's call
# (rebase or merge when ready).

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

PR_NUMBER=""
BASE="main"
FORCE_UNCHECKED=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pr)                PR_NUMBER="$2"; shift 2 ;;
        --base)              BASE="$2"; shift 2 ;;
        --force-unchecked)   FORCE_UNCHECKED=1; shift 1 ;;
        *) echo "merge.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "merge.sh: gh CLI is required for merge (squash-merge via REST API is not implemented here)." >&2
    echo "  Install: brew install gh  then: gh auth login" >&2
    exit 8
fi

# Read the current branch with explicit failure handling. set -e + the
# simple-substitution case would catch a non-zero exit from 'git branch'
# on bash 3.2 the same as 4.4+, but the explicit pattern lets us emit a
# specific diagnostic on git failure vs detached HEAD vs already-on-main.
if ! CURRENT_BRANCH=$(git branch --show-current); then
    echo "merge.sh: 'git branch --show-current' failed in active worktree. Inspect with 'git status'." >&2
    exit 15
fi
if [ -z "$CURRENT_BRANCH" ]; then
    echo "merge.sh: current worktree is in detached HEAD state — no branch to merge." >&2
    echo "  /merge operates on a named branch's PR. Check out the body-of-work branch first." >&2
    exit 14
fi
if [ "$CURRENT_BRANCH" = "$BASE" ]; then
    echo "merge.sh: already on $BASE. Nothing to merge." >&2
    exit 3
fi

# ─── Determine worktree context ────────────────────────────────────────────
# We need to know:
#   - ACTIVE_WORKTREE: the path of the worktree we're currently in
#   - PRIMARY_ROOT:    the path of the primary repo
#   - WORKTREES_DIR:   <primary>/.claude/worktrees
#   - WT_KIND:         "current" | "compartment" | "primary" | "unknown"
#
# git rev-parse --show-toplevel returns the CURRENT worktree's root.
# git rev-parse --git-common-dir returns the primary's .git path.
# The primary worktree is the parent directory of --git-common-dir.

# Entry-point sanity: resolve active worktree + primary repo paths.
# Explicit failure handling — these substitutions are critical (the
# script cannot operate without knowing where it is), and the explicit
# pattern works identically on bash 3.2 (where 'shopt -s inherit_errexit'
# is a no-op) and bash 4.4+.
if ! ACTIVE_WORKTREE=$(git rev-parse --show-toplevel); then
    echo "merge.sh: 'git rev-parse --show-toplevel' failed — not in a git working tree." >&2
    exit 16
fi
if ! GIT_COMMON_DIR=$(git rev-parse --git-common-dir); then
    echo "merge.sh: 'git rev-parse --git-common-dir' failed — cannot locate primary repo." >&2
    exit 16
fi
if ! PRIMARY_ROOT=$(cd "$(dirname "$GIT_COMMON_DIR")" && pwd); then
    echo "merge.sh: failed to resolve primary repo path from '$GIT_COMMON_DIR'." >&2
    exit 16
fi
WORKTREES_DIR="${PRIMARY_ROOT}/.claude/worktrees"
CURRENT_PATH="${WORKTREES_DIR}/current"

if [ "$ACTIVE_WORKTREE" = "$PRIMARY_ROOT" ]; then
    WT_KIND="primary"
elif [ "$ACTIVE_WORKTREE" = "$CURRENT_PATH" ]; then
    WT_KIND="current"
elif [[ "$ACTIVE_WORKTREE" == "$WORKTREES_DIR"/* ]]; then
    WT_KIND="compartment"
else
    WT_KIND="unknown"
fi

# Remove a worktree dir SAFELY. Refuses any path not under .claude/worktrees/,
# so a misclassified WT_KIND or an empty arg can NEVER rm the primary checkout
# (main) or anything outside the worktrees dir. (Running /merge from primary
# routes to the `primary)` arm, which never calls this.) `git worktree remove`
# is best-effort — it can exit 0 yet leave the dir when untracked/symlinked
# content remains — so the guarded `rm -rf` + `prune` are the guaranteed
# cleanup. rm -rf removes the symlink ENTRIES (node_modules, .env), not their
# targets in the primary checkout.
remove_worktree_dir() {
    case "$1" in
        "$WORKTREES_DIR"/?*)
            git worktree remove --force "$1" >/dev/null 2>&1 || true
            rm -rf "$1"
            git worktree prune
            ;;
        *)
            echo "merge.sh: refusing to remove '$1' — not under $WORKTREES_DIR. No deletion performed." >&2
            ;;
    esac
}

# Resolve PR number if not provided
if [ -z "$PR_NUMBER" ]; then
    PR_LIST=$(gh pr list --head "$CURRENT_BRANCH" --state open --json number,title,url)
    COUNT=$(echo "$PR_LIST" | jq 'length')
    if [ "$COUNT" -eq 0 ]; then
        echo "merge.sh: no open PR found for branch $CURRENT_BRANCH." >&2
        echo "  Run /open-pr first." >&2
        exit 9
    fi
    if [ "$COUNT" -gt 1 ]; then
        echo "merge.sh: multiple open PRs for branch $CURRENT_BRANCH:" >&2
        echo "$PR_LIST" | jq -r '.[] | "  #\(.number) \(.title) — \(.url)"' >&2
        echo "  Re-invoke with --pr <number>." >&2
        exit 10
    fi
    PR_NUMBER=$(echo "$PR_LIST" | jq -r '.[0].number')
fi

echo "gitflow: target PR #$PR_NUMBER" >&2
echo "gitflow: active worktree: $ACTIVE_WORKTREE (kind: $WT_KIND)" >&2

# Verify CI passed AND Gemini Code Assist has reviewed current HEAD (unless bypass).
if [ "$FORCE_UNCHECKED" -eq 0 ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    WAIT_SCRIPT="$SCRIPT_DIR/wait-for-pr-ready.sh"
    if [ ! -x "$WAIT_SCRIPT" ]; then
        echo "merge.sh: $WAIT_SCRIPT missing or not executable." >&2
        exit 12
    fi

    echo "gitflow: verifying PR is ready (CI green + Gemini reviewed HEAD if enabled)..." >&2
    set +e
    "$WAIT_SCRIPT" --pr "$PR_NUMBER"
    WAIT_EXIT=$?
    set -e
    case $WAIT_EXIT in
        0) ;;
        2)
            echo "merge.sh: CI failed on PR #$PR_NUMBER — fix and push before merging." >&2
            exit 11
            ;;
        3)
            echo "merge.sh: readiness wait timed out — see diagnostic above." >&2
            echo "  Re-invoke with --force-unchecked only if hotfix authorized." >&2
            exit 11
            ;;
        5)
            echo "merge.sh: readiness wait interrupted." >&2
            exit 11
            ;;
        *)
            echo "merge.sh: readiness wait failed with exit $WAIT_EXIT." >&2
            exit 11
            ;;
    esac
fi

# ─── Squash-merge, then delete the remote branch (two separate steps) ───────
# The merge and the remote-branch delete are split ON PURPOSE. Bundled as a
# single `gh pr merge --squash --delete-branch`, a transient failure of the
# DELETE half — e.g. a GitHub 503 — makes gh report the whole command as
# failed, so the script aborts BEFORE the primary-main sync + npm ci below,
# stranding the primary repo on stale code after a merge that actually landed.
# Splitting them keeps the squash-merge fatal and the delete best-effort, so
# primary main always ends up current once the merge is in.
#
# Both gh calls run from /tmp with `-R <owner>/<repo>`: with no local repo
# context gh performs only the server-side operation and never attempts a
# local `git branch -D` (which would collide with the two-worktree model —
# primary already holds main, and no two worktrees may hold the same branch).
# The local cleanup (worktree removal + local branch delete) happens below in
# the WT_KIND case block, which knows the topology.
if ! REMOTE_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner); then
    echo "merge.sh: 'gh repo view' failed — cannot resolve owner/repo slug for the squash-merge call." >&2
    exit 17
fi
echo "gitflow: squash-merging PR #$PR_NUMBER (invoking gh from /tmp to avoid worktree collision)..." >&2
# Pre-check /tmp accessibility BEFORE the subshell so a 'cd' failure
# does not get mis-blamed on 'gh pr merge'. Under any sane POSIX-ish
# system /tmp exists and is traversable; the explicit check exists to
# emit a specific diagnostic if the system is genuinely broken.
if [ ! -d /tmp ] || [ ! -x /tmp ]; then
    echo "merge.sh: /tmp is not accessible — cannot invoke gh from outside the git tree." >&2
    echo "  Diagnose the system before retrying. /tmp must exist and be traversable." >&2
    exit 21
fi
# The squash-merge is FATAL on failure — a failed merge means nothing shipped.
# set -e in the outer shell IS inherited by `(...)` subshells on bash 3.2 and
# 4.4+ (NOT the inherit_errexit case — that governs `$()`), so the explicit
# `if !` is for diagnostic clarity, not error propagation.
if ! (
    cd /tmp
    gh -R "$REMOTE_REPO" pr merge "$PR_NUMBER" --squash
); then
    echo "merge.sh: 'gh pr merge --squash' failed for PR #$PR_NUMBER. Inspect on github.com or via 'gh pr view $PR_NUMBER'." >&2
    exit 20
fi

# Delete the remote branch — BEST-EFFORT, non-fatal. A transient API failure
# here (GitHub 503, etc.) must NOT abort the script before the primary-main
# sync + npm ci below: the merge already landed and primary main MUST end up
# current. On failure the remote branch simply lingers — the next
# `git fetch --prune`, or a manual `git push origin --delete`, clears it.
#
# `|| true` is load-bearing: when deleteBranchOnMerge is enabled (repo default
# for many), the squash-merge above already removed the head branch, so this
# DELETE 404s and exits non-zero. Under `set -eo pipefail` a bare subshell that
# exits non-zero ABORTS the whole script — stranding primary on stale code after
# a merge that actually landed. `|| true` keeps it best-effort as documented.
( cd /tmp && gh -R "$REMOTE_REPO" api -X DELETE "repos/$REMOTE_REPO/git/refs/heads/$CURRENT_BRANCH" >/dev/null 2>&1 ) || true
# Verify the ACTUAL outcome rather than trusting the DELETE's exit code. When the
# repo has deleteBranchOnMerge enabled (common), GitHub removes the head branch
# during the squash-merge above, so this explicit DELETE 404s on an already-gone
# ref and exits non-zero — a success, not a failure. Only warn if the branch
# genuinely still exists afterward (the auto-delete-off case where our DELETE
# truly failed). A lingering ref returns 200 here; an absent one returns 404.
if ( cd /tmp && gh -R "$REMOTE_REPO" api "repos/$REMOTE_REPO/git/refs/heads/$CURRENT_BRANCH" >/dev/null 2>&1 ); then
    echo "gitflow: remote-branch delete for '$CURRENT_BRANCH' did not take — branch still exists; delete it with: git push origin --delete $CURRENT_BRANCH" >&2
fi

# ─── Sync primary repo's main ──────────────────────────────────────────────
echo "gitflow: syncing primary main at $PRIMARY_ROOT..." >&2
(
    cd "$PRIMARY_ROOT"
    # Under the new model primary is always on main. The else-branch below
    # is retained for the legacy / transition case where primary may be on
    # some other branch (e.g. mid-sync via /sync-starter-kit).
    git fetch origin "$BASE"
    if ! PRIMARY_HEAD=$(git branch --show-current); then
        echo "merge.sh: failed to read primary's HEAD branch. Inspect $PRIMARY_ROOT manually." >&2
        exit 18
    fi
    if [ "$PRIMARY_HEAD" = "$BASE" ]; then
        git pull --ff-only
    else
        # Update the local main branch ref to match origin/main without
        # checking it out. Safe because main isn't checked out anywhere
        # we're modifying. Suppression rationale (Constitution §XIII):
        # this is best-effort — if the ref update fails (e.g. main is
        # actively held by another worktree we don't control), the user
        # can pull manually; we do not want to abort the merge here.
        git fetch origin "$BASE:$BASE" 2>/dev/null || true
    fi
)

# ─── Resync primary node_modules if the merge changed dependencies ──────────
# A dependency added INSIDE the worktree updated package.json / package-lock.json
# (tracked → now merged to main) but `npm install` only populated the WORKTREE's
# node_modules. Primary's node_modules is stale until reinstalled — which bites
# /deploy's `npm run build` gate (runs from primary) and any direct primary use.
# node_modules is deliberately NOT symlinked across worktrees (vite / TanStack
# realpath plugin resolution — see settings.json worktree `_comment`), so the fix
# is a targeted reinstall here, only when the squash actually touched a manifest.
# Best-effort: a failed install is surfaced, never aborts the completed merge.
#
# `npm ci`, NEVER bare `npm install` (rules/dependencies.md §I). This is the last
# thing to touch the lockfile before /deploy's build gate. Bare `npm install` is
# free to REWRITE package-lock.json — and does, whenever the local npm resolves
# optional/peer deps differently from the npm that wrote it. The corrupted lockfile
# then sits as an uncommitted change on main, which /deploy blocks on (dirty tree)
# or bakes into the release. `npm ci` installs strictly from the committed lockfile
# and never edits it. It also errors when package.json and the lockfile disagree —
# after a squash merge they always should, so that error is real signal.
if git -C "$PRIMARY_ROOT" show --name-only --format= "origin/$BASE" 2>/dev/null \
     | grep -qE '(^|/)package(-lock)?\.json$'; then
    echo "gitflow: merge changed package manifests — resyncing primary node_modules (npm ci)..." >&2
    ( cd "$PRIMARY_ROOT" && npm ci --no-audit --no-fund >&2 ) \
        || echo "gitflow: npm ci in primary FAILED — run 'npm ci' in $PRIMARY_ROOT before /deploy." >&2
fi

# ─── Helper: delete the merged local branch ────────────────────────────────
# Run from primary's cwd, where we have a stable HEAD that is not the
# deleted branch. Best-effort — branch may already be gone (e.g. via a
# concurrent prune) and that is acceptable post-merge.
delete_merged_local_branch() {
    local branch="$1"
    [ -z "$branch" ] && return 0
    # Suppression rationale (Constitution §XIII): post-merge cleanup of a
    # branch that has already been server-deleted and whose worktree has
    # been removed. Failure modes: (1) already deleted by a concurrent
    # process, (2) somehow re-checked out somewhere we don't see, (3)
    # ref-update race. None are merge-blocking — the PR is shipped, the
    # branch is gone on the remote, surfacing this as an abort would be
    # noise after a successful ship.
    git -C "$PRIMARY_ROOT" branch -D "$branch" 2>/dev/null || true
}

# ─── Cleanup based on active worktree kind ─────────────────────────────────
case "$WT_KIND" in
    current)
        echo "gitflow: active worktree was current/ — removing. Next /work will recreate it fresh." >&2
        # Must leave the worktree before removing it. Move to primary first.
        cd "$PRIMARY_ROOT"
        remove_worktree_dir "$CURRENT_PATH"
        # Delete the now-merged local branch. gh (invoked from /tmp above)
        # deleted the remote branch but cannot touch the local one.
        delete_merged_local_branch "$CURRENT_BRANCH"
        # Do NOT recreate current/ here. current/ never holds main, and the
        # next /work invocation will create it on a fresh wip/<timestamp>
        # branch off the (now updated) origin/main.
        ;;

    compartment)
        echo "gitflow: active worktree was a compartment — removing $ACTIVE_WORKTREE..." >&2
        # Must leave the compartment before removing it.
        cd "$PRIMARY_ROOT"
        remove_worktree_dir "$ACTIVE_WORKTREE"
        # Delete the now-merged local branch. gh (invoked from /tmp above)
        # deleted the remote branch but cannot touch the local one.
        delete_merged_local_branch "$CURRENT_BRANCH"
        echo "gitflow: compartment removed" >&2

        # Handle current/ if it exists.
        # current/ is on some wip/* or feature branch (never main). We do not
        # automatically integrate new main into current/'s branch — that's
        # the user's call (rebase or merge when ready). We only auto-clean
        # current/ if it is TRULY empty: no uncommitted changes AND its branch
        # has zero commits ahead of origin/main. Otherwise leave alone + warn.
        if [ -d "$CURRENT_PATH" ]; then
            # Read current/'s branch. Detached HEAD → exits 0 with empty
            # stdout (acceptable here — the downstream comparisons treat
            # empty as "not a wip branch, not a meaningful name"). Any other
            # git failure → explicit if-! check aborts loudly so the user
            # sees a clear error. Constitution §X (fail fast, fail loud).
            # Explicit pattern (vs implicit set -e) for bash 3.2 portability.
            if ! CURRENT_BRANCH_IN_CURRENT=$(git -C "$CURRENT_PATH" branch --show-current); then
                echo "merge.sh: failed to read current/'s HEAD branch. Inspect $CURRENT_PATH manually." >&2
                exit 19
            fi
            CURRENT_CLEAN=0
            if git -C "$CURRENT_PATH" diff --quiet 2>/dev/null && \
               git -C "$CURRENT_PATH" diff --cached --quiet 2>/dev/null && \
               [ -z "$(git -C "$CURRENT_PATH" ls-files --others --exclude-standard 2>/dev/null)" ]; then
                CURRENT_CLEAN=1
            fi

            # Compute commits ahead of origin/BASE. Explicit failure check —
            # do NOT mask via `|| echo "0"`. A spurious 0 combined with
            # CURRENT_CLEAN=1 triggers removal of current/ and would delete
            # the user's in-progress work. Constitution §X (fail fast, fail
            # loud). The explicit check is bash-version-independent: works
            # on bash 3.2 (macOS default, where shopt -s inherit_errexit is
            # a no-op) the same as on bash 4.4+.
            if ! COMMITS_AHEAD=$(git -C "$CURRENT_PATH" rev-list --count "origin/${BASE}..HEAD"); then
                # git rev-list will have written its error to stderr already;
                # the user sees it directly. Do not redirect it into the
                # variable — mixing stderr in on the success path would
                # poison the numeric comparison below.
                echo "merge.sh: failed to compute commits-ahead for current/ — refusing to evaluate cleanup. Inspect manually." >&2
                exit 13
            fi

            if [ "$CURRENT_CLEAN" -eq 1 ] && [ "$COMMITS_AHEAD" = "0" ]; then
                echo "gitflow: current/ is empty (no uncommitted changes, no commits ahead of origin/${BASE}) — removing so next /work starts fresh." >&2
                remove_worktree_dir "$CURRENT_PATH"
                # Delete the now-orphaned wip branch if it looks like a wip/* throwaway.
                if [[ "$CURRENT_BRANCH_IN_CURRENT" == wip/* ]]; then
                    # Suppression rationale (Constitution §XIII): this is
                    # best-effort cleanup AFTER current/ has already been
                    # removed and confirmed empty (no uncommitted changes,
                    # zero commits ahead of origin/$BASE). Acceptable failure
                    # modes: (1) branch already pruned by a concurrent
                    # session, (2) branch checked out in another worktree
                    # we don't know about, (3) git race against another
                    # process. None of these are merge-blocking — the PR is
                    # already merged at this point; surfacing the error as
                    # a script abort would be noise after a successful ship.
                    git branch -D "$CURRENT_BRANCH_IN_CURRENT" 2>/dev/null || true
                fi
            elif [ "$CURRENT_CLEAN" -eq 0 ]; then
                echo "gitflow: NOTE — current/ has uncommitted changes on branch '$CURRENT_BRANCH_IN_CURRENT'. The PR you just merged is on $BASE; current/ is now out of sync with $BASE. Rebase/merge when ready." >&2
            else
                echo "gitflow: NOTE — current/ has $COMMITS_AHEAD commit(s) on branch '$CURRENT_BRANCH_IN_CURRENT' not yet shipped. Left alone. Rebase onto new $BASE when ready." >&2
            fi
        fi
        ;;

    primary)
        # Pre-worktree-era invocation (or someone bypassed /work). Old behavior:
        # switch primary to base and pull. Don't touch worktrees.
        echo "gitflow: active worktree is the primary — switching to $BASE and pulling (legacy path)..." >&2
        cd "$PRIMARY_ROOT"
        git checkout "$BASE"
        git pull --ff-only
        # Delete the now-merged local branch (gh from /tmp deleted remote only).
        delete_merged_local_branch "$CURRENT_BRANCH"
        ;;

    unknown)
        echo "gitflow: WARN — active worktree '$ACTIVE_WORKTREE' is neither primary nor under .claude/worktrees/." >&2
        echo "  Skipping worktree cleanup. Primary main has been synced." >&2
        ;;
esac

echo "gitflow: merge complete." >&2
