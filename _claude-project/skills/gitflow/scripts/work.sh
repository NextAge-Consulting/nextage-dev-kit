#!/bin/bash
# gitflow work: enter or create a working area (worktree) for the current project.
#
# Usage:
#   work.sh                              # enter current/ worktree, create on main if missing
#   work.sh --issue <N>                  # enter current/, ensure branch, link issue #N
#   work.sh --new <name>                 # create compartment at .claude/worktrees/<name>/
#   work.sh --retrieve <branch>          # fetch + fast-forward <branch>; into current/ if clean, else compartment
#   work.sh --discard <name>             # remove compartment .claude/worktrees/<name>/
#   work.sh --discard <name> --force     # skip dirty-tree refusal; also REQUIRED to discard 'current'
#   work.sh --discard current --force    # explicitly remove the persistent current/ worktree
#                                          (use case: orphaned current/ after shipping work through
#                                          a different compartment; or hard reset)
#
# Responsibilities:
#   - Detect project root from cwd (handles being invoked from inside a worktree)
#   - Create/enter the named worktree under <project-root>/.claude/worktrees/
#   - For --issue: validate, derive branch slug from issue title, create branch,
#     link issue via git config, transition to In Progress, assign current user,
#     dump issue context for the Claude session.
#   - For --retrieve: fetch the remote branch; checkout in current/ if clean,
#     otherwise create a new compartment named after the branch.
#   - For --discard: refuse if uncommitted changes unless confirmed (--force skips prompt).
#
# Output:
#   On success, the LAST line of stdout is `WORKTREE_PATH=<absolute-path>`.
#   The caller (Claude) reads this and invokes EnterWorktree with that path.
#
# Refuses to operate on the primary worktree as a working area. The primary
# is reserved for git substrate; all work lives under .claude/worktrees/.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

# ─── Arg parsing ───────────────────────────────────────────────────────────

MODE=""        # "", "issue", "new", "retrieve", "discard"
ARG=""         # the value for the mode (issue#, name, branch)
FORCE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --issue)
            [ -n "$MODE" ] && { echo "work.sh: --issue conflicts with --$MODE" >&2; exit 2; }
            MODE="issue"; ARG="$2"; shift 2 ;;
        --new)
            [ -n "$MODE" ] && { echo "work.sh: --new conflicts with --$MODE" >&2; exit 2; }
            MODE="new"; ARG="$2"; shift 2 ;;
        --retrieve)
            [ -n "$MODE" ] && { echo "work.sh: --retrieve conflicts with --$MODE" >&2; exit 2; }
            MODE="retrieve"; ARG="$2"; shift 2 ;;
        --discard)
            [ -n "$MODE" ] && { echo "work.sh: --discard conflicts with --$MODE" >&2; exit 2; }
            MODE="discard"; ARG="$2"; shift 2 ;;
        --force)
            FORCE=1; shift 1 ;;
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

# ─── Project root detection ────────────────────────────────────────────────
# When invoked from inside an additional worktree, git rev-parse returns
# THAT worktree's root, not the primary. We need the PRIMARY (the canonical
# repo on disk where additional worktrees live under .claude/worktrees/).
#
# Strategy: --git-common-dir always points at the primary repo's .git/.
# The primary worktree is its parent directory.

PROJECT_ROOT=$(cd "$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")" && pwd 2>/dev/null) || {
    echo "work.sh: not in a git repository" >&2
    exit 3
}

WORKTREES_DIR="${PROJECT_ROOT}/.claude/worktrees"

# ─── Helper: emit WORKTREE_PATH marker for Claude to consume ───────────────
emit_path() {
    local path="$1"
    echo
    echo "WORKTREE_PATH=$path"
}

# ─── Helper: create a worktree at <path> on a NEW branch off origin/main ──
# Always creates a new branch. Never checks out main directly — main is
# owned by the primary repo and cannot coexist in two worktrees.
create_worktree() {
    local path="$1"
    local branch_name="$2"    # required

    if [ -z "$branch_name" ]; then
        echo "work.sh: internal error — create_worktree requires a branch name" >&2
        exit 99
    fi

    mkdir -p "$(dirname "$path")"

    # Refresh local main from origin/main BEFORE branching, fail-loud. This
    # closes the "a dev starts /work two days after another dev merged + deployed,
    # gets a worktree based on stale local main" gap. fast_forward_local_main
    # runs in the PRIMARY repo (where main is checked out) and refuses on
    # dirty / diverged main. On any failure, abort worktree creation — the
    # whole point is "current/ is always based on the latest main."
    #
    # Previous behavior: `git fetch origin main >/dev/null 2>&1 || true` —
    # silently swallowed every failure mode (offline, expired auth, missing
    # scope) and proceeded to branch off the stale remote-tracking ref. Per
    # the fail-loud-when-configured rule (issue_helpers.sh header), removed.
    if ! (cd "$PROJECT_ROOT" && fast_forward_local_main); then
        echo "work.sh: refusing to create worktree at $path — local main could not be refreshed." >&2
        echo "  Resolve the cause reported above (likely network, auth scope, or diverged main), then re-run /work." >&2
        exit 6
    fi

    # Idempotency: if the local branch already exists (e.g. a previous
    # session's worktree dir was manually removed but the branch survived),
    # attach the new worktree to that existing branch instead of trying
    # to create it again. Otherwise create a fresh branch off origin/main.
    #
    # --no-track on the fresh-branch path: without it, git defaults
    # (branch.autoSetupMerge=true) cause the new branch to inherit
    # origin/main as upstream — because origin/main is a remote-tracking
    # branch used as the start-point. That breaks downstream `git push`
    # under push.default=simple (modern default): plain push fails because
    # the upstream NAME (main) does not match the local branch NAME.
    # safe_push() in branch_helpers.sh is the belt-and-suspenders; --no-track
    # here is the primary fix — the branch is created with NO upstream and
    # the first /commit's push uses `-u origin <branch>` to set it correctly.
    local rc=0
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
        git worktree add "$path" "$branch_name" >&2 || rc=$?
    else
        git worktree add --no-track -b "$branch_name" "$path" "origin/main" >&2 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "work.sh: failed to create worktree at $path on branch '$branch_name'" >&2
        exit 6
    fi

    apply_worktree_symlinks "$path"
    run_post_create "$path"
}

# ─── Helper: run worktree.postCreate commands declared in settings.json ────
# Each command runs in the worktree dir, sequentially. Failure of any command
# aborts the rest with a clear error message (worktree is still left in place
# so user can debug). Commands run only on CREATE, not on re-entry — they're
# initialization steps (npm install, drizzle generate, etc.), not idempotent
# operations like the symlink helper.
#
# Why this exists: vite + TanStack Start (and most monorepo dev tooling)
# fundamentally cannot work when node_modules is symlinked across worktrees
# — the plugin's resolve.alias paths run through import.meta.url -> realpath,
# which then doesn't match the worktree's URL paths. Each worktree needs its
# own REAL node_modules. The symlink approach for node_modules has been
# deprecated; postCreate runs npm install (or the project's equivalent)
# per worktree instead. See TanStack Router issue #6588.
run_post_create() {
    local worktree_path="$1"
    local settings="${PROJECT_ROOT}/.claude/settings.json"

    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local cmd
    while IFS= read -r cmd; do
        [ -z "$cmd" ] && continue
        echo "work.sh: postCreate → $cmd" >&2
        if ! (cd "$worktree_path" && eval "$cmd") >&2; then
            echo "work.sh: postCreate command failed: $cmd" >&2
            echo "work.sh: worktree left in place at $worktree_path for debugging" >&2
            exit 7
        fi
    done < <(jq -r '.worktree.postCreate // [] | .[]' "$settings" 2>/dev/null)
}

# ─── Helper: apply gitignored-asset symlinks declared in settings.json ─────
# Claude Code's built-in `worktree.symlinkDirectories` / `worktree.symlinkPaths`
# settings only fire when Claude Code's own `EnterWorktree` tool CREATES the
# worktree. /work uses `git worktree add` directly + EnterWorktree(path=...)
# to enter an existing worktree, which bypasses the symlink machinery.
#
# Solution: read the same setting and create the symlinks here, immediately
# after `git worktree add` succeeds. Idempotent — skips paths that already
# exist as files/dirs/symlinks in the worktree. Silently skips paths that
# don't exist in the primary (matches Claude Code's own behavior per
# dh3 in the 2.1.139 binary).
#
# Symlink target is ABSOLUTE (primary repo root + relative path). Relative
# would also work given the standard layout (worktrees live at
# <primary>/.claude/worktrees/<name>/) but absolute is unambiguous when
# diagnosing and survives any relocation of the worktree.
#
# Settings precedence: project `.claude/settings.json`. Reads two arrays:
#   .worktree.symlinkDirectories  — gitignored dirs (node_modules, .venv, ...)
#   .worktree.symlinkPaths        — gitignored files (.env, .env.local, ...)
apply_worktree_symlinks() {
    local worktree_path="$1"
    local settings="${PROJECT_ROOT}/.claude/settings.json"

    [ -f "$settings" ] || return 0
    command -v jq >/dev/null 2>&1 || {
        echo "work.sh: jq not available — skipping worktree symlinks" >&2
        return 0
    }

    # Inner helper: symlink one resolved entry (relative path) from primary
    # into worktree. Silently no-ops if primary lacks it OR target already exists.
    _symlink_one() {
        local rel="$1"
        local source="${PROJECT_ROOT}/${rel}"
        local target="${worktree_path}/${rel}"

        # Source missing in primary → silently skip (matches Claude Code behavior).
        [ -e "$source" ] || [ -L "$source" ] || return 0

        # Target already exists → idempotent skip.
        if [ -e "$target" ] || [ -L "$target" ]; then
            return 0
        fi

        mkdir -p "$(dirname "$target")"
        ln -s "$source" "$target"
        echo "work.sh: symlinked $rel" >&2
    }

    local entry expanded prev_dir
    # Combine both lists; jq emits empty for missing keys.
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue

        # Glob expansion: entries like `apps/*/node_modules` expand against
        # primary's filesystem to one or more relative paths. Non-glob entries
        # pass through unchanged. nullglob makes unmatched patterns expand to
        # empty (not the literal pattern). dotglob lets `.env*` match dotfiles.
        if [[ "$entry" == *"*"* || "$entry" == *"?"* || "$entry" == *"["* ]]; then
            prev_dir="$PWD"
            cd "$PROJECT_ROOT" || continue
            shopt -s nullglob dotglob
            # shellcheck disable=SC2206 # $entry is a glob literal expanded into the array intentionally; word-splitting is the desired effect (nullglob/dotglob are set immediately above)
            local matches=($entry)
            shopt -u nullglob dotglob
            cd "$prev_dir" || true
            for expanded in "${matches[@]}"; do
                _symlink_one "$expanded"
            done
        else
            _symlink_one "$entry"
        fi
    done < <(jq -r '
        (.worktree.symlinkDirectories // [])
        + (.worktree.symlinkPaths // [])
        | .[]
    ' "$settings" 2>/dev/null)

    unset -f _symlink_one
}

# ─── Helper: ensure current/ exists, return its path ───────────────────────
# Missing → create on a fresh wip/<abbrev>-<timestamp> branch off origin/main
# (see branch_helpers.sh:make_wip_branch_name for the prefix + format rationale).
# Present → just return its path (re-entry; same body of work continues
# across consecutive sessions until /merge ships it).
#
# STDOUT IS THIS FUNCTION'S RETURN CHANNEL — the caller reads it via
# `path=$(ensure_current)`. Anything it or its callees print to stdout is
# captured into that path and silently corrupts it. So every command reachable
# from here MUST send human output to stderr: `git worktree add` prints
# "HEAD is now at <sha>" to stdout, and postCreate runs `npm ci`, whose stdout
# is voluminous — both are redirected with `>&2` at their call sites for exactly
# this reason. Keep it that way when adding steps.
ensure_current() {
    local current_path="${WORKTREES_DIR}/current"
    if [ ! -d "$current_path" ]; then
        local wip
        wip=$(make_wip_branch_name)
        echo "work.sh: creating current/ worktree on new branch '$wip'" >&2
        create_worktree "$current_path" "$wip"
    else
        # Re-entry path: heal any missing gitignored-asset symlinks
        # (e.g. user manually rm'd .env, or settings.json gained new entries
        # since the worktree was created). apply_worktree_symlinks is idempotent.
        apply_worktree_symlinks "$current_path"
    fi
    echo "$current_path"
}

# ─── Helper: sanitize a branch name into a worktree folder name ────────────
# feat/dealer-fix → feat-dealer-fix
sanitize_name() {
    printf '%s' "$1" | sed -E 's#[/]+#-#g; s#[^A-Za-z0-9._-]+#-#g'
}

# ─── Helper: check if a worktree is clean (no uncommitted changes) ─────────
worktree_is_clean() {
    local path="$1"
    [ -d "$path" ] || return 0   # nonexistent counts as clean
    git -C "$path" diff --quiet 2>/dev/null && \
        git -C "$path" diff --cached --quiet 2>/dev/null && \
        [ -z "$(git -C "$path" ls-files --others --exclude-standard 2>/dev/null)" ]
}

# ─── Mode: default (enter current/) ────────────────────────────────────────
mode_default() {
    local path
    path=$(ensure_current)
    echo "work.sh: entering current/ worktree at $path" >&2
    emit_path "$path"
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

    local current_path="${WORKTREES_DIR}/current"

    if [ ! -d "$current_path" ]; then
        # Fresh current/ → create directly on the issue-derived branch.
        local target
        target=$(slug_from_issue "$num")
        target=$(resolve_collision "$target")
        echo "work.sh: creating current/ worktree on issue branch '$target'" >&2
        create_worktree "$current_path" "$target"
    else
        # current/ already exists. Under the new model it should be on a
        # wip/* or feature branch (never main). Defensive check for the
        # migration window — pre-fix sessions may have left current/ on
        # main, or a user may have manually created the worktree on main.
        # Read the current branch. Detached HEAD → exits 0 with empty stdout
        # (handled by the empty-check below). Any other git failure (corrupt
        # worktree, missing .git, etc.) → non-zero exit; set -e aborts and
        # the user sees git's stderr directly. Do NOT suppress.
        local existing_branch
        existing_branch=$(git -C "$current_path" branch --show-current)

        if [ -z "$existing_branch" ]; then
            # Detached HEAD inside current/. Should not occur under the new
            # model (worktrees are always created on a named branch), but
            # CAN happen if the user manually 'git checkout <sha>' inside
            # current/. Refuse rather than silently falling into /link
            # semantics — there is no meaningful branch to link to.
            echo "work.sh: current/ is in a detached HEAD state — refusing to link issue #$num." >&2
            echo "  Inspect with 'git -C $current_path status' and either check out the body-of-work branch or remove current/." >&2
            exit 7
        elif is_protected_branch "$existing_branch"; then
            # current/ landed on a protected branch (legacy / manual setup).
            # Create the issue's feature branch inside the worktree.
            local target
            target=$(slug_from_issue "$num")
            target=$(resolve_collision "$target")
            echo "work.sh: current/ is on protected branch '$existing_branch' — creating '$target' for issue #$num" >&2
            git -C "$current_path" checkout -b "$target"
        else
            # current/ on a feature branch → /link semantics (add issue to existing branch).
            echo "work.sh: current/ is on branch '$existing_branch' — linking issue #$num to it" >&2
        fi
    fi

    # Link, transition, assign, dump (operate from inside the worktree so git config
    # writes to the correct branch context).
    pushd "$current_path" >/dev/null
    link_issue_to_branch "$num"
    move_issue_to_in_progress "$num"
    assign_issue_to_current_user "$num"
    dump_issue_context "$num"
    popd >/dev/null

    emit_path "$current_path"
}

# ─── Mode: --new <name> ────────────────────────────────────────────────────
mode_new() {
    local name="$ARG"
    if [ -z "$name" ]; then
        echo "work.sh: --new requires a compartment name" >&2
        exit 2
    fi
    name=$(sanitize_name "$name")
    if [ "$name" = "current" ]; then
        echo "work.sh: 'current' is reserved — pick a different name" >&2
        exit 2
    fi

    local path="${WORKTREES_DIR}/${name}"
    if [ -d "$path" ]; then
        echo "work.sh: compartment '$name' already exists at $path — entering it" >&2
        emit_path "$path"
        return 0
    fi

    local branch abbrev
    abbrev=$(get_project_abbrev)
    branch="wip/${abbrev}-${name}"
    echo "work.sh: creating compartment '$name' on new branch '$branch'" >&2
    create_worktree "$path" "$branch"
    emit_path "$path"
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

    # Strictly behind. If the branch is checked out in a worktree the merge has to
    # happen there so index and working tree follow; otherwise moving the ref is
    # enough. A dirty tree makes --ff-only refuse, which is the correct outcome:
    # loud, and nothing overwritten.
    local wt
    wt=$(git worktree list --porcelain \
         | awk -v b="branch refs/heads/$branch" '/^worktree /{p=$2} $0==b{print p}')
    if [ -n "$wt" ]; then
        echo "work.sh: fast-forwarding '$branch' to origin in $wt" >&2
        if ! git -C "$wt" merge --ff-only "origin/$branch" >&2; then
            echo "work.sh: could not fast-forward '$branch' in $wt (uncommitted changes?)." >&2
            echo "work.sh: that worktree stays on the older commit." >&2
        fi
    else
        echo "work.sh: fast-forwarding local '$branch' to origin" >&2
        git update-ref "refs/heads/$branch" "$remote_sha"
    fi
}

# ─── Mode: --retrieve <branch> ─────────────────────────────────────────────
mode_retrieve() {
    local branch="$ARG"
    if [ -z "$branch" ]; then
        echo "work.sh: --retrieve requires a branch name" >&2
        exit 2
    fi

    echo "work.sh: fetching origin/$branch" >&2
    if ! git fetch origin "$branch" 2>/dev/null; then
        echo "work.sh: branch '$branch' not found on origin" >&2
        exit 4
    fi

    # Fetching alone leaves an existing local branch pointing at the old commit.
    sync_local_branch "$branch"

    local current_path="${WORKTREES_DIR}/current"

    # If current/ doesn't exist OR is clean, use current/.
    if [ ! -d "$current_path" ] || worktree_is_clean "$current_path"; then
        if [ ! -d "$current_path" ]; then
            echo "work.sh: creating current/ on branch '$branch'" >&2
            mkdir -p "$(dirname "$current_path")"
            if git show-ref --verify --quiet "refs/heads/$branch"; then
                git worktree add "$current_path" "$branch" >&2
            else
                git worktree add -b "$branch" "$current_path" "origin/$branch" >&2
            fi
        else
            # current/ exists and is clean — switch its branch to the retrieved one.
            echo "work.sh: switching current/ to branch '$branch'" >&2
            if git show-ref --verify --quiet "refs/heads/$branch"; then
                git -C "$current_path" checkout "$branch"
            else
                git -C "$current_path" checkout -b "$branch" "origin/$branch"
            fi
        fi
        emit_path "$current_path"
        return 0
    fi

    # current/ is dirty → auto-promote to a compartment named after the branch.
    local compartment_name
    compartment_name=$(sanitize_name "$branch")
    local compartment_path="${WORKTREES_DIR}/${compartment_name}"

    echo "work.sh: current/ has uncommitted changes — creating compartment '$compartment_name' for branch '$branch'" >&2

    if [ -d "$compartment_path" ]; then
        echo "work.sh: compartment '$compartment_name' already exists at $compartment_path — entering it" >&2
        emit_path "$compartment_path"
        return 0
    fi

    mkdir -p "$(dirname "$compartment_path")"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
        git worktree add "$compartment_path" "$branch" >&2
    else
        git worktree add -b "$branch" "$compartment_path" "origin/$branch" >&2
    fi
    emit_path "$compartment_path"
}

# ─── Mode: --discard <name> ────────────────────────────────────────────────
mode_discard() {
    local name="$ARG"
    if [ -z "$name" ]; then
        echo "work.sh: --discard requires a compartment name" >&2
        exit 2
    fi
    # 'current' is the persistent workspace — discarding requires --force.
    # Without --force: refuse (protects accidental wipeout of the long-lived
    # session worktree). With --force: allow, on the assumption the caller
    # has reconciled any unshipped work elsewhere (e.g. shipped via a
    # separate compartment, or knowingly throwing it away). This mirrors the
    # compartment-discard semantics where --force overrides the dirty check.
    # Use cases: post-incident cleanup of an orphaned current/ (where the
    # body of work was shipped through a different compartment), or hard
    # reset when current/ has drifted into an unrecoverable state.
    if [ "$name" = "current" ] && [ "$FORCE" -eq 0 ]; then
        echo "work.sh: refusing to discard 'current' — that is the persistent workspace." >&2
        echo "  Re-invoke with --force to discard anyway, or /merge to ship the body of work cleanly." >&2
        exit 2
    fi

    local path="${WORKTREES_DIR}/${name}"
    if [ ! -d "$path" ]; then
        echo "work.sh: compartment '$name' does not exist at $path" >&2
        exit 4
    fi

    if ! worktree_is_clean "$path"; then
        if [ "$FORCE" -eq 1 ]; then
            echo "work.sh: '$name' has uncommitted changes — discarding (--force)" >&2
        else
            echo "work.sh: '$name' has uncommitted changes." >&2
            echo "  Re-invoke with --force to discard anyway, or commit/checkpoint first." >&2
            exit 5
        fi
    fi

    echo "work.sh: removing worktree '$name' at $path" >&2
    git worktree remove --force "$path" 2>&1 | sed 's/^/  /' >&2 || {
        # Fallback: if git worktree remove fails (rare), nuke the dir + prune.
        rm -rf "$path"
        git worktree prune
    }

    echo "work.sh: discard complete (no worktree to enter)" >&2
    # No WORKTREE_PATH emit — caller stays where it was.
}

# ─── Dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in
    "")        mode_default ;;
    "issue")   mode_issue ;;
    "new")     mode_new ;;
    "retrieve") mode_retrieve ;;
    "discard") mode_discard ;;
    *)
        echo "work.sh: internal error — unknown mode '$MODE'" >&2
        exit 99
        ;;
esac
