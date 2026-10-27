#!/bin/bash
# gitflow merge: squash-merge current branch's PR after CI passes, then land on main.
# Usage: merge.sh [--pr <number>] [--base main] [--force-unchecked] [--carry-uncommitted]
#                 [--deploy-from-worktree]
#
# If --pr is not provided, the script uses the PR associated with the current branch.
# If multiple open PRs exist for the current branch, the script lists them and exits —
# caller must re-invoke with --pr <number>.
#
# --force-unchecked bypasses the CI-passed gate AND the production build gate. Use only
# for emergency hotfixes with explicit user authorization.
#
# Production build gate (exit 15): every workspace's `build` script runs LOCALLY
# before the squash, in the background while the readiness wait (exit 11) polls CI and
# Gemini, so its minutes are spent inside time the merge waits anyway. Its output is
# printed whole when it finishes. Whichever of the two fails first stops the other and
# decides the exit code; the squash needs both. CI does not build — it type-checks, lints and tests — so a build-only
# break (bundler, Tailwind, a package import its `exports` map does not resolve) is
# invisible to every earlier gate. This is the last moment the PR is still OPEN, which is
# the whole point: a failure here is fixed on the branch that caused it, in the PR that is
# already under review. Catching it at /deploy instead means the branch is gone and the
# only possible remedy is a second PR to repair the first.
#
# It is NOT in CI on purpose: CI fires on every push, so building there would tax every
# commit, every /open-pr and every triage fix with a full build. Once per merge is the
# right frequency.
#
# Uncommitted changes gate (exit 26): checked first, before the build and before
# anything reaches GitHub. Each changed file is listed, marked when the PR changes it
# too. The build gate builds this folder, not the PR, so an uncommitted fix would hide
# a break the PR contains; and after the merge, edits to files the PR changed stop
# the switch to the base. --carry-uncommitted merges anyway and carries the edits onto
# the base — refused when the PR changes any of them, or in a worktree, where they
# would go when it is removed. The line `CARRY: offered` or `CARRY: not offered — <why>`
# tells merge.md which choices to give.
#
# Post-merge cleanup:
#   - Switch this checkout to the base branch and fast-forward it to the merged tip.
#   - Delete the now-merged local branch (the remote one is deleted server-side).
#   - Reinstall dependencies if landing on the new base changed a manifest.
#
# In a worktree (`/work --worktree`), the merge happens on GitHub and nothing local
# changes: git refuses to check out the base while the primary checkout holds it, and
# the worktree is removed whole. The script prints `WORKTREE-REMOVE: <path>` and
# `WORKTREE-BRANCH: <branch>`; merge.md leaves the worktree, then runs
# worktree-remove.sh from the primary. A failed removal never makes the merge a
# failure. With --deploy-from-worktree the worktree is kept to /deploy from instead:
# it is detached at the merged origin/<base> and the merged local branch deleted, and
# /deploy removes the worktree once it has shipped (`WORKTREE-DEPLOY: <path>`).
#
# The body of work ends here. The next `/work` starts a fresh branch off the
# base you are now standing on.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/gates.sh
source "$SCRIPT_DIR/gates.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/repo_kind.sh
source "$SCRIPT_DIR/repo_kind.sh"

PR_NUMBER=""
BASE="main"
FORCE_UNCHECKED=0
CARRY_UNCOMMITTED=0
DEPLOY_FROM_WORKTREE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --pr)                PR_NUMBER="$2"; shift 2 ;;
        --base)              BASE="$2"; shift 2 ;;
        --force-unchecked)   FORCE_UNCHECKED=1; shift 1 ;;
        --carry-uncommitted) CARRY_UNCOMMITTED=1; shift 1 ;;
        --deploy-from-worktree) DEPLOY_FROM_WORKTREE=1; shift 1 ;;
        *) echo "merge.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

# A PR that changes Terraform is landed by /deploy, which applies it first, so main
# only ever holds infrastructure that is live. deploy-org.sh calls this script with
# GITFLOW_ORG_DEPLOY=1 once the apply succeeded. A repo with no app (org) has nothing
# else to merge; one with an app too (combo) merges every other PR as usual.
if [ "${GITFLOW_ORG_DEPLOY:-}" != "1" ] && repo_holds_infra; then
    if ! repo_holds_app; then
        echo "merge.sh: this is an org repo — /deploy applies the PR and merges it. A docs change goes to main with /ship-main. Nothing was merged." >&2
        exit 25
    fi
    if ! TF_ROOTS=$(bash .claude/skills/terraform/scripts/changed-roots.sh "$BASE" 2>/dev/null); then
        echo "merge.sh: could not tell whether this PR changes Terraform. Nothing was merged." >&2
        exit 25
    fi
    if [ -n "$TF_ROOTS" ]; then
        echo "merge.sh: this PR changes Terraform ($(printf '%s' "$TF_ROOTS" | tr '\n' ' ')) — /deploy on this branch applies it and merges it. Nothing was merged." >&2
        exit 25
    fi
fi

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
    echo "merge.sh: 'git branch --show-current' failed. Inspect with 'git status'." >&2
    exit 15
fi
if [ -z "$CURRENT_BRANCH" ]; then
    echo "merge.sh: detached HEAD — no branch to merge." >&2
    echo "  /merge operates on a named branch's PR. Check out the body-of-work branch first." >&2
    exit 14
fi
if [ "$CURRENT_BRANCH" = "$BASE" ]; then
    echo "merge.sh: already on $BASE. Nothing to merge." >&2
    exit 3
fi

# ─── Locate the checkout ───────────────────────────────────────────────────
# Explicit failure handling — the script cannot operate without knowing where
# it is, and the explicit pattern works identically on bash 3.2 (where
# 'shopt -s inherit_errexit' is a no-op) and bash 4.4+.
if ! REPO_ROOT=$(git rev-parse --show-toplevel); then
    echo "merge.sh: 'git rev-parse --show-toplevel' failed — not in a git working tree." >&2
    exit 16
fi

# The pre-merge tip of the feature branch. Compared against the merged base
# further down to decide whether dependencies need reinstalling.
if ! PRE_MERGE_SHA=$(git rev-parse HEAD); then
    echo "merge.sh: 'git rev-parse HEAD' failed — cannot record the pre-merge commit." >&2
    exit 16
fi

IN_WORKTREE=0
in_linked_worktree && IN_WORKTREE=1
if [ "$DEPLOY_FROM_WORKTREE" -eq 1 ] && [ "$IN_WORKTREE" -eq 0 ]; then
    echo "merge.sh: --deploy-from-worktree is for a worktree; this is the primary checkout. Nothing was merged." >&2
    exit 2
fi

# ─── Uncommitted changes gate (exit 26) ────────────────────────────────────
# The header says why this runs first. Untracked files count: a new file is usually
# the bulk of a change.
if ! DIRTY=$(git status --porcelain --untracked-files=all); then
    echo "merge.sh: 'git status' failed — cannot tell whether the tree is clean. Nothing was merged." >&2
    exit 16
fi
CARRYING=0
if [ -n "$DIRTY" ]; then
    PR_FILES=""
    if MB=$(git merge-base HEAD "origin/$BASE" 2>/dev/null); then
        PR_FILES=$(git diff --name-only "$MB" HEAD)
    fi
    OVERLAP=0
    echo "merge.sh: uncommitted changes in this checkout:" >&2
    while IFS= read -r line; do
        f="${line:3}"
        f="${f##* -> }"
        if [ -n "$PR_FILES" ] && grep -qxF "$f" <<< "$PR_FILES"; then
            echo "  $f   (this PR changes it too)" >&2
            OVERLAP=1
        else
            echo "  $f" >&2
        fi
    done <<< "$DIRTY"
    WHY_NOT=""
    if [ "$OVERLAP" -eq 1 ]; then
        WHY_NOT="this PR changes some of them too"
    elif [ "$IN_WORKTREE" -eq 1 ]; then
        WHY_NOT="this is a worktree, and they would go with it when it is removed"
    fi
    if [ "$CARRY_UNCOMMITTED" -eq 1 ] && [ -z "$WHY_NOT" ]; then
        echo "gitflow: merging without them; they carry onto $BASE afterwards (--carry-uncommitted)." >&2
        CARRYING=1
    else
        if [ -n "$WHY_NOT" ]; then
            echo "CARRY: not offered — $WHY_NOT"
        else
            echo "CARRY: offered"
        fi
        echo "merge.sh: nothing was merged. Commit them first — or, when none is in this PR, merge with --carry-uncommitted." >&2
        exit 26
    fi
fi

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
echo "gitflow: merging '$CURRENT_BRANCH' in $REPO_ROOT" >&2

# ─── Stacked PR whose parent is not merged (exit 24) ───────────────────────
# A stacked PR targets the handed-off branch it was cut from. Squashing it now
# would land it in that branch, not in $BASE; merging the parent re-points it at
# $BASE (below), and then it merges like any other.
if ! PR_META=$(gh pr view "$PR_NUMBER" --json author,baseRefName --jq '[.author.login, .baseRefName] | @tsv'); then
    echo "merge.sh: could not read PR #$PR_NUMBER — nothing merged." >&2
    exit 22
fi
PR_AUTHOR=${PR_META%%$'\t'*}
PR_BASE=${PR_META#*$'\t'}
if [ "$PR_BASE" != "$BASE" ]; then
    PARENT_PR=$(open_pr_for_branch "$PR_BASE")
    echo "merge.sh: PR #$PR_NUMBER is stacked on '$PR_BASE'${PARENT_PR:+ (PR #$PARENT_PR)}, which is not merged yet." >&2
    echo "  Merge that first; this PR then targets $BASE and merges as usual." >&2
    exit 24
fi

# ─── Base drift gate (exit 23) ─────────────────────────────────────────────
# Before the build and the readiness wait: a PR that conflicts with its base
# cannot squash, and finding that out after several minutes of building and
# polling is the failure this exists to prevent. A trial merge is local and
# exact; drift that merges cleanly is reported and the merge goes ahead.
if [ "$FORCE_UNCHECKED" -eq 0 ] && ! main_drift_report "$BASE" merge.sh; then
    main_merge_conflicts "$BASE" && CONFLICT=0 || CONFLICT=$?
    case "$CONFLICT" in
        0) echo "gitflow: $BASE moved, but it merges cleanly — continuing." >&2 ;;
        1) echo "merge.sh: PR #$PR_NUMBER conflicts with origin/$BASE in the files above." >&2
           echo "  Run /catchup, resolve, and /merge again. Nothing was merged." >&2
           exit 23 ;;
        *) echo "gitflow: could not trial-merge origin/$BASE (git 2.38+ needed) — continuing." >&2 ;;
    esac
fi

# ─── Production build gate (exit 15) and readiness wait (exit 11) ──────────
# The build runs in the background while the readiness wait polls CI and Gemini in the
# foreground, so its minutes are spent inside time the merge waits anyway. The build's
# output is captured and printed whole once it finishes; the wait's polling prints live.
# Whichever fails first decides: a failed build stops the wait and exits 15 with the
# build's output; a failed wait stops the build (or, where its processes cannot be found,
# lets it finish), reports where the build stood, and exits 11. Both passing is what
# lets the squash go ahead. Non-Node repos have no package.json and run the wait alone.
# gates.sh holds the build gate; it says how many packages it built, or that none
# declares a build.

# kill_tree <pid> — stop a process and every process under it. Prints nothing; succeeds
# only when pgrep can see the children, so the caller knows whether they were stopped.
kill_tree() {
    local child children
    command -v pgrep >/dev/null 2>&1 || return 1
    children=$(pgrep -P "$1" 2>/dev/null) || children=""
    for child in $children; do kill_tree "$child" || true; done
    kill "$1" 2>/dev/null || true
    return 0
}

if [ "$FORCE_UNCHECKED" -eq 0 ]; then
    WAIT_SCRIPT="$SCRIPT_DIR/wait-for-pr-ready.sh"
    if [ ! -x "$WAIT_SCRIPT" ]; then
        echo "merge.sh: $WAIT_SCRIPT missing or not executable." >&2
        exit 12
    fi

    BUILD_PID=""
    BUILD_DIR=""
    if [ -f "$REPO_ROOT/package.json" ]; then
        BUILD_DIR=$(mktemp -d)
        (
            if run_build_gate "$REPO_ROOT"; then rc=0; else rc=$?; fi
            echo "$rc" >"$BUILD_DIR/rc.tmp" && mv "$BUILD_DIR/rc.tmp" "$BUILD_DIR/rc"
        ) >"$BUILD_DIR/out" 2>&1 &
        BUILD_PID=$!
        echo "gitflow: production build started in the background; its output follows when it finishes." >&2
    fi

    # build_result — once the build has ended: print its output whole, return its exit.
    build_result() {
        local rc=15
        wait "$BUILD_PID" 2>/dev/null || true
        cat "$BUILD_DIR/out" >&2
        if [ -f "$BUILD_DIR/rc" ]; then
            rc=$(cat "$BUILD_DIR/rc")
        else
            echo "merge.sh: the production build ended without a result — nothing merged." >&2
        fi
        rm -rf "$BUILD_DIR"
        BUILD_PID=""
        return "$rc"
    }

    # stop_job <pid> — stop a background job and everything under it, then reap it.
    stop_job() {
        kill_tree "$1" || kill "$1" 2>/dev/null || true
        wait "$1" 2>/dev/null || true
    }

    # A background job ignores Ctrl-C, so the interrupt stops both jobs here.
    WAIT_PID=""
    trap '[ -n "$WAIT_PID" ] && stop_job "$WAIT_PID"; [ -n "$BUILD_PID" ] && stop_job "$BUILD_PID"; rm -rf "$BUILD_DIR"
          echo "merge.sh: interrupted — the readiness wait and the build were stopped. Nothing merged." >&2; exit 11' INT TERM

    echo "gitflow: verifying PR is ready (CI green + Gemini reviewed HEAD if enabled)..." >&2
    "$WAIT_SCRIPT" --pr "$PR_NUMBER" &
    WAIT_PID=$!
    WAIT_EXIT=""
    while [ -z "$WAIT_EXIT" ]; do
        if [ -n "$BUILD_PID" ] && [ -f "$BUILD_DIR/rc" ]; then
            if build_result; then
                :
            else
                BUILD_EXIT=$?
                stop_job "$WAIT_PID"
                echo "merge.sh: readiness wait stopped — the build failed, so PR #$PR_NUMBER will not merge." >&2
                exit "$BUILD_EXIT"
            fi
        fi
        if ! kill -0 "$WAIT_PID" 2>/dev/null; then
            if wait "$WAIT_PID"; then WAIT_EXIT=0; else WAIT_EXIT=$?; fi
            WAIT_PID=""
            break
        fi
        sleep 1
    done

    if [ "$WAIT_EXIT" -ne 0 ] && [ -n "$BUILD_PID" ]; then
        if [ -f "$BUILD_DIR/rc" ]; then
            if build_result; then
                echo "gitflow: the production build passed (above), but the readiness wait did not." >&2
            else
                echo "merge.sh: the production build failed as well (above)." >&2
            fi
        elif kill_tree "$BUILD_PID"; then
            wait "$BUILD_PID" 2>/dev/null || true
            rm -rf "$BUILD_DIR"
            BUILD_PID=""
            echo "gitflow: production build stopped — it was still running when the readiness wait failed." >&2
        else
            echo "gitflow: the readiness wait failed; letting the production build finish to report it..." >&2
            build_result || true
        fi
    fi

    trap - INT TERM

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

    # The wait passed; the build may still be running.
    if [ -n "$BUILD_PID" ]; then
        [ -f "$BUILD_DIR/rc" ] || echo "gitflow: PR is ready; waiting for the production build to finish..." >&2
        if ! build_result; then
            exit 15
        fi
    fi
fi

# ─── Squash-merge, then delete the remote branch (two separate steps) ───────
# The merge and the remote-branch delete are split ON PURPOSE. Bundled as a
# single `gh pr merge --squash --delete-branch`, a transient failure of the
# DELETE half — e.g. a GitHub 503 — makes gh report the whole command as
# failed, so the script aborts BEFORE the base-branch sync + npm ci below,
# stranding this checkout on the merged feature branch after a merge that
# actually landed. Splitting them keeps the squash-merge fatal and the delete
# best-effort, so the checkout always ends up on a current base once the
# merge is in.
#
# Both gh calls run from /tmp with `-R <owner>/<repo>`: with no local repo
# context gh performs only the server-side operation and never attempts a
# local `git branch -D`. That local delete would fail anyway — we are standing
# ON the branch being merged — and its failure would abort the script before
# the base-branch sync below. The local cleanup happens further down, in order,
# once this checkout is back on the base branch.
if ! REMOTE_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner); then
    echo "merge.sh: 'gh repo view' failed — cannot resolve owner/repo slug for the squash-merge call." >&2
    exit 17
fi
# The squash commit carries the PR's own title and body, passed explicitly.
# GitHub's default squash message depends on a per-repository setting, and its
# "commit messages" option lists the branch's commits and DROPS the PR body —
# the `Closes #N` line /open-pr writes and /deploy reads to move shipped issues
# to the deploy status. Passing both makes that independent of the setting.
if ! PR_TITLE=$(gh -R "$REMOTE_REPO" pr view "$PR_NUMBER" --json title -q .title); then
    echo "merge.sh: could not read PR #$PR_NUMBER's title — nothing merged." >&2
    exit 22
fi
if ! PR_BODY=$(gh -R "$REMOTE_REPO" pr view "$PR_NUMBER" --json body -q .body); then
    echo "merge.sh: could not read PR #$PR_NUMBER's body — nothing merged." >&2
    exit 22
fi
# Merging someone else's PR leaves an approving review first, so the PR records who
# wrote it, who reviewed it and who merged it. A failed approval is reported and the
# merge goes ahead: the record is wanted, never a gate.
if MERGER=$(gh_login) && [ -n "$PR_AUTHOR" ] && [ "$MERGER" != "$PR_AUTHOR" ]; then
    if ( cd /tmp && gh -R "$REMOTE_REPO" pr review "$PR_NUMBER" --approve --body "Reviewed and merged by @$MERGER." >/dev/null ); then
        echo "gitflow: approved PR #$PR_NUMBER as @$MERGER (written by @$PR_AUTHOR)." >&2
    else
        echo "gitflow: could not record @$MERGER's approval on PR #$PR_NUMBER — merging anyway; approve it on GitHub for the record." >&2
    fi
fi
echo "gitflow: squash-merging PR #$PR_NUMBER (invoking gh from /tmp so it does no local git)..." >&2
# Pre-check /tmp accessibility BEFORE the subshell so a 'cd' failure
# does not get mis-blamed on 'gh pr merge'. Under any sane POSIX-ish
# system /tmp exists and is traversable; the explicit check exists to
# emit a specific diagnostic if the system is genuinely broken.
if [ ! -d /tmp ] || [ ! -x /tmp ]; then
    echo "merge.sh: /tmp is not accessible — cannot invoke gh from outside the git tree." >&2
    echo "  Diagnose the system before retrying. /tmp must exist and be traversable." >&2
    exit 21
fi
# GH_PROMPT_DISABLED: with these flags gh's only question is "already merged — delete
# the branch locally?", asked when the PR merged before this call and gh sees a
# terminal. Nobody is there to answer it, and gh waits on it. Disabled, gh warns
# that the PR was already merged and exits 0.
squash_merge() {
    ( cd /tmp
      GH_PROMPT_DISABLED=1 gh -R "$REMOTE_REPO" pr merge "$PR_NUMBER" --squash \
          --subject "$PR_TITLE (#$PR_NUMBER)" --body "$PR_BODY" )
}
# A failed `gh pr merge` does not prove nothing merged. GitHub can answer the merge
# mutation with an empty body — gh then prints a bare `EOF` — after the merge landed,
# or before it was attempted. So a failure is settled by the PR's state on GitHub:
# MERGED carries on as a success, OPEN is retried once, anything else is fatal
# (exit 20). Retrying cannot merge twice: GitHub refuses to merge a merged PR.
merge_attempt=1
while ! squash_merge; do
    pr_state=$( cd /tmp && gh -R "$REMOTE_REPO" pr view "$PR_NUMBER" --json state -q .state 2>/dev/null ) || pr_state=""
    if [ "$pr_state" = MERGED ]; then
        echo "gitflow: gh reported the squash-merge as failed, but GitHub shows PR #$PR_NUMBER merged — carrying on." >&2
        break
    fi
    if [ "$pr_state" != OPEN ] || [ "$merge_attempt" -ge 2 ]; then
        echo "merge.sh: 'gh pr merge --squash' failed for PR #$PR_NUMBER (GitHub shows it ${pr_state:-in an unknown state}). Inspect on github.com or via 'gh pr view $PR_NUMBER'." >&2
        exit 20
    fi
    merge_attempt=2
    echo "gitflow: the squash-merge failed and PR #$PR_NUMBER is still open — retrying once in 5 seconds..." >&2
    sleep 5
done

# PRs stacked on this branch (opened against it while it was under review) move to
# $BASE before the branch goes. Deleting a PR's base branch through the API closes
# that PR rather than re-pointing it, so gitflow re-points them itself instead of
# relying on GitHub to. Best effort: one that fails is named, and /catchup on that
# branch re-points it too.
STACKED=$( cd /tmp && gh -R "$REMOTE_REPO" pr list --base "$CURRENT_BRANCH" --state open --json number --jq '.[].number' 2>/dev/null ) || STACKED=""
for n in $STACKED; do
    if ( cd /tmp && gh -R "$REMOTE_REPO" pr edit "$n" --base "$BASE" >/dev/null 2>&1 ); then
        echo "gitflow: PR #$n was stacked on '$CURRENT_BRANCH' — it now targets $BASE." >&2
    else
        echo "gitflow: could not re-point PR #$n at $BASE — do it before the branch goes (gh pr edit $n --base $BASE)." >&2
    fi
done

# Delete the remote branch — BEST-EFFORT, non-fatal. A transient API failure
# here (GitHub 503, etc.) must NOT abort the script before the base-branch
# sync + npm ci below: the merge already landed and this checkout MUST end up
# on a current base. On failure the remote branch simply lingers — the next
# `git fetch --prune`, or a manual `git push origin --delete`, clears it.
#
# The DELETE may 404 when the repository deletes head branches on merge itself;
# `|| true` keeps that from aborting the script under `set -e`. `gh api` takes
# the repository in its path — it has no -R.
( cd /tmp && gh api -X DELETE "repos/$REMOTE_REPO/git/refs/heads/$CURRENT_BRANCH" >/dev/null 2>&1 ) || true
# Verify the ACTUAL outcome rather than trusting the DELETE's exit code: present
# means the delete did not take; a 404 means gone; anything else is unknown.
if REF_CHECK=$( cd /tmp && gh api "repos/$REMOTE_REPO/git/ref/heads/$CURRENT_BRANCH" 2>&1 ); then
    echo "gitflow: remote-branch delete for '$CURRENT_BRANCH' did not take — branch still exists; delete it with: git push origin --delete $CURRENT_BRANCH" >&2
elif ! printf '%s' "$REF_CHECK" | grep -q "HTTP 404"; then
    echo "gitflow: could not confirm '$CURRENT_BRANCH' is gone from origin — check on GitHub." >&2
fi

# ─── A worktree: nothing local changes; it is removed whole ────────────────
# The header says why. Only the outcome is decided here: removed by merge.md from the
# primary, or detached at the merged base to /deploy from.
cd "$REPO_ROOT"
if [ "$IN_WORKTREE" -eq 1 ]; then
    if [ "$DEPLOY_FROM_WORKTREE" -eq 1 ]; then
        if ! git fetch origin "$BASE" || ! git switch --detach "origin/$BASE"; then
            echo "merge.sh: the merge LANDED, but the worktree could not be detached at origin/$BASE (git's reason above)." >&2
            echo "WORKTREE-REMOVE: $REPO_ROOT"
            echo "WORKTREE-BRANCH: $CURRENT_BRANCH"
            exit 18
        fi
        # Detached, the merged branch is checked out nowhere, and its PR is merged.
        git branch -D "$CURRENT_BRANCH" >/dev/null 2>&1 \
            || echo "gitflow: could not delete the local branch '$CURRENT_BRANCH' — remove it with: git branch -D $CURRENT_BRANCH" >&2
        echo "gitflow: merge complete. The worktree is detached at the merged origin/$BASE to /deploy from." >&2
        echo "WORKTREE-DEPLOY: $REPO_ROOT"
        exit 0
    fi
    echo "gitflow: merge complete. The worktree is kept for cleanup: it is removed from the primary checkout." >&2
    echo "WORKTREE-REMOVE: $REPO_ROOT"
    echo "WORKTREE-BRANCH: $CURRENT_BRANCH"
    exit 0
fi

# ─── Land on the base branch ───────────────────────────────────────────────
# The merge is in. Move this checkout onto the base and fast-forward it to the
# merged tip, so the session ends where the next body of work starts.
#
# The tree is clean here unless --carry-uncommitted was given: the gate at the top
# refused every other dirty tree. Carried edits are stashed across the switch and
# restored on the new base, so a file the base changed since cannot block it.
STASHED=0
if [ "$CARRYING" -eq 1 ]; then
    if ! git stash push --include-untracked -m "gitflow merge: carried onto $BASE" >/dev/null; then
        echo "merge.sh: the merge LANDED, but your uncommitted changes could not be set aside to switch to $BASE." >&2
        echo "  This checkout is still on '$CURRENT_BRANCH' with them in place. Then: git checkout $BASE && git pull --ff-only" >&2
        exit 18
    fi
    STASHED=1
fi
echo "gitflow: switching to $BASE and fast-forwarding..." >&2
git fetch origin "$BASE"
if ! git checkout "$BASE"; then
    echo "merge.sh: could not switch to $BASE — the merge LANDED but this checkout is still on '$CURRENT_BRANCH'." >&2
    echo "  Resolve what git reported above, then: git checkout $BASE && git pull --ff-only" >&2
    [ "$STASHED" -eq 1 ] && echo "  Your uncommitted changes are in the stash (top of 'git stash list'): git stash pop" >&2
    exit 18
fi
if ! git pull --ff-only; then
    echo "merge.sh: could not fast-forward $BASE — the merge LANDED but local $BASE is behind." >&2
    echo "  Resolve what git reported above, then: git pull --ff-only" >&2
    [ "$STASHED" -eq 1 ] && echo "  Your uncommitted changes are in the stash (top of 'git stash list'): git stash pop" >&2
    exit 18
fi
if [ "$STASHED" -eq 1 ]; then
    if git stash pop >/dev/null; then
        echo "gitflow: your uncommitted changes are back in place on $BASE." >&2
    else
        echo "merge.sh: the merge LANDED and $BASE is current, but your carried changes conflict with it." >&2
        echo "  They are kept in the stash (top of 'git stash list'); resolve the files git named, then 'git stash drop'." >&2
        exit 19
    fi
fi

# ─── Delete the merged local branch ────────────────────────────────────────
# We are on the base branch now, so the ref is free to remove. gh (invoked
# from /tmp above) deleted the remote branch but never touches the local one.
#
# Suppression rationale (Constitution §XIII): best-effort cleanup AFTER a
# completed ship. Failure modes: already deleted by a concurrent process, or a
# ref-update race. Neither is merge-blocking — the PR is merged and the remote
# branch is gone; aborting here would be noise after a successful ship.
git branch -D "$CURRENT_BRANCH" 2>/dev/null || true

# ─── Reinstall dependencies if landing on the base changed a manifest ──────
# Compare the branch tip we came from against the base we now stand on. Two
# cases produce a diff here: the squash brought in a manifest change made by
# someone whose install you never ran, or the base moved under you while this
# PR was open. Either way node_modules no longer matches the lockfile on disk,
# which bites /deploy's `npm run build` gate and every later test run.
# Best-effort: a failed install is surfaced, never aborts the completed merge.
#
# `npm ci`, NEVER bare `npm install` (rules/dependencies.md §I). This is the
# last thing to touch the lockfile before /deploy's build gate. Bare
# `npm install` is free to REWRITE package-lock.json — and does, whenever the
# local npm resolves optional/peer deps differently from the npm that wrote it.
# The corrupted lockfile then sits as an uncommitted change on the base branch,
# which /deploy blocks on (dirty tree) or bakes into the release. `npm ci`
# installs strictly from the committed lockfile and never edits it.
if git diff --name-only "$PRE_MERGE_SHA..HEAD" 2>/dev/null \
     | grep -qE '(^|/)package(-lock)?\.json$'; then
    echo "gitflow: manifests changed on $BASE — reinstalling dependencies (npm ci)..." >&2
    npm ci --no-audit --no-fund >&2 \
        || echo "gitflow: npm ci FAILED — run 'npm ci' in $REPO_ROOT before /deploy." >&2
fi

echo "gitflow: merge complete." >&2
