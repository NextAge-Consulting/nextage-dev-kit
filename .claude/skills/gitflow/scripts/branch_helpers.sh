#!/bin/bash
# gitflow branch helpers: shared functions for branch creation and rename.
# Sourced by branch.sh, checkpoint.sh, commit.sh.

# is_protected_branch <name> — returns 0 if branch is main or master.
is_protected_branch() {
    [ "$1" = "main" ] || [ "$1" = "master" ]
}

# is_wip_branch <name> — returns 0 if branch looks like an auto-created wip branch.
is_wip_branch() {
    [[ "$1" =~ ^wip/ ]]
}

# get_project_abbrev — echoes a short project label for embedding in wip/ branch names.
#
# Resolution order:
#   1. PROJECT_ABBREV from <repo-root>/.claude/sync-substitutions.json (jq, runtime-read).
#   2. basename of the repo root (via `git rev-parse --git-common-dir`, then dirname).
#   3. "proj" as a last-ditch fallback if no git context is available.
#
# Output is sanitized to branch-name-safe chars (lowercase, [a-z0-9._-]).
#
# Resolved from the repo root rather than cwd, so the abbrev is stable no matter
# which subdirectory the command was invoked from.
get_project_abbrev() {
    local repo_root abbrev common_dir

    # Resolve the repo root. --git-common-dir points at <root>/.git; `dirname`
    # gives the root itself.
    if common_dir=$(git rev-parse --git-common-dir 2>/dev/null); then
        # --git-common-dir can return a relative path; resolve to absolute.
        if [ "${common_dir:0:1}" != "/" ]; then
            common_dir="$(cd "$common_dir" 2>/dev/null && pwd)"
        fi
        repo_root="$(dirname "$common_dir")"
    fi

    abbrev=""
    if [ -n "$repo_root" ] && [ -f "$repo_root/.claude/sync-substitutions.json" ] && command -v jq >/dev/null 2>&1; then
        abbrev=$(jq -r '.PROJECT_ABBREV // ""' "$repo_root/.claude/sync-substitutions.json" 2>/dev/null)
    fi

    if [ -z "$abbrev" ]; then
        if [ -n "$repo_root" ]; then
            abbrev=$(basename "$repo_root")
        else
            abbrev="proj"
        fi
    fi

    # Sanitize: lowercase, non-[a-z0-9._-] → '-', collapse, trim.
    abbrev=$(printf '%s' "$abbrev" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [ -z "$abbrev" ] && abbrev="proj"

    echo "$abbrev"
}

# make_wip_branch_name — echoes wip/<project-abbrev>-YYYY-MM-DD-HHMMSSZ.
#
# Timestamp is UTC + ISO 8601 (with trailing Z) per Constitution §VI: every
# timestamp in the codebase must be timezone-aware. Branch names produced on
# different developers' machines collide deterministically when keyed to a
# single timezone; the second-precision avoids back-to-back collisions when
# /work and /checkpoint fire in the same minute.
#
# The project-abbrev prefix lets the Agents view distinguish concurrent
# wip/ branches across multiple projects — without it, every wip/ branch
# looks like timestamp-only and projects are indistinguishable in the UI.
make_wip_branch_name() {
    echo "wip/$(get_project_abbrev)-$(date -u +%Y-%m-%d-%H%M%SZ)"
}

# derive_branch_from_message <commit_message> — echoes <type>/<slug> derived from
# the first line of a conventional commit message.
derive_branch_from_message() {
    local msg="$1"
    local first_line="${msg%%$'\n'*}"

    local type="chore"
    local description="$first_line"

    # Conventional commit format requires a colon. If missing, fall back to chore/<slug>.
    if [[ "$first_line" == *:* ]]; then
        local before_colon="${first_line%%:*}"
        description="${first_line#*:}"
        description="${description# }"

        # Type = FIRST lowercase word before the colon (strip ! breaking marker).
        # Conventional commits are `type(scope):` — the type comes first, the
        # optional scope comes second in parens. Using `tail -1` wrongly picked
        # the scope as the branch prefix (e.g., `fix(gitflow):` → `gitflow/...`
        # instead of `fix/...`). `head -1` selects the type regardless of
        # whether a scope is present.
        local extracted
        extracted=$(printf '%s' "$before_colon" | grep -oE '[a-z]+!?' | head -1 | tr -d '!')
        [ -n "$extracted" ] && type="$extracted"
    fi

    # Slugify description: lowercase, non-alnum → '-', collapse, trim, truncate to 40 chars.
    local slug
    slug=$(printf '%s' "$description" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//')
    [ -z "$slug" ] && slug="changes"

    echo "${type}/${slug}"
}

# branch_exists <name> — returns 0 if branch exists locally or on origin.
branch_exists() {
    local name="$1"
    if git show-ref --verify --quiet "refs/heads/$name"; then
        return 0
    fi
    if git ls-remote --exit-code --heads origin "$name" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# resolve_collision <base_name> — echoes a free branch name, appending -2, -3, etc.
# if base_name is taken.
resolve_collision() {
    local base="$1"
    local candidate="$base"
    local n=2
    while branch_exists "$candidate"; do
        candidate="${base}-${n}"
        n=$((n + 1))
    done
    echo "$candidate"
}

# has_open_pr <branch> — returns 0 if the branch has an OPEN PR on GitHub.
# Returns non-zero if gh is unavailable or no open PR exists.
has_open_pr() {
    local branch="$1"
    command -v gh >/dev/null 2>&1 || return 1
    local state
    state=$(gh pr view "$branch" --json state -q .state 2>/dev/null)
    [ "$state" = "OPEN" ]
}

# rename_current_branch <new_name> — renames the current local branch and syncs remote.
# If the old branch was pushed to origin, pushes the new branch and deletes the old remote ref.
rename_current_branch() {
    local new="$1"
    local old
    old=$(git branch --show-current)

    if [ "$old" = "$new" ]; then
        return 0
    fi

    git branch -m "$new"

    # ALWAYS clear upstream tracking after rename — regardless of whether the
    # old branch existed on remote. Rationale: `git branch -m` preserves the
    # old branch's upstream config (branch.<new>.remote, branch.<new>.merge),
    # which often points at a name unrelated to the renamed branch — a branch
    # cut from origin/main can inherit origin/main as its upstream. Without
    # clearing here, the caller's subsequent `git push` fails under
    # push.default=simple because the upstream name (main) does not match the
    # local name (the new name).
    # Suppression rationale (Constitution §XIII): --unset-upstream exits
    # non-zero when there is no upstream to remove; that is the expected
    # state for some renames, not an error.
    git branch --unset-upstream 2>/dev/null || true

    # If old branch existed on remote, mirror the rename there too.
    if git ls-remote --exit-code --heads origin "$old" >/dev/null 2>&1; then
        git push -u origin "$new"
        if ! git push origin --delete "$old"; then
            echo "gitflow: warning — failed to delete remote branch $old (non-fatal)" >&2
        fi
    fi
}

# create_and_switch <name> — creates branch from current HEAD and switches to it.
# Carries uncommitted changes via git's default checkout -b behavior.
create_and_switch() {
    local name="$1"
    git checkout -b "$name"
}

# safe_push — push the current branch to origin, ensuring upstream is set
# to the matching remote branch (origin/<local-branch>).
#
# Why this exists: a plain `git push` under `push.default=simple` (the modern
# default) requires the branch's upstream name to match the local branch name.
# Several flows in this repo can leave a branch with the WRONG upstream:
#
#   - A branch created from `origin/main` can inherit origin/main as its
#     upstream (branch.autoSetupMerge). `push.default=simple` then refuses
#     plain `git push` because "main" != "<new>". This function is the
#     belt-and-suspenders so any branch with leftover bogus tracking still
#     pushes correctly.
#
#   - `git branch -m <old> <new>` carries forward <old>'s upstream config
#     under the new branch name. `rename_current_branch` above explicitly
#     calls `--unset-upstream` for this reason; safe_push handles the case
#     where some other caller forgot to.
#
# Detection: read @{u} via rev-parse --symbolic-full-name. If it matches
# origin/<local-branch>, do a plain `git push` (preserves the user's
# explicit `--force` / extra args via "$@"). Otherwise, treat the upstream
# as unset-or-wrong and use `git push -u origin <local-branch>` to
# (re)point it correctly. The -u flag overwrites any existing
# branch.<name>.{remote,merge} config — that's the whole point.
safe_push() {
    local local_branch upstream expected
    local_branch=$(git branch --show-current)
    if [ -z "$local_branch" ]; then
        echo "gitflow: safe_push — detached HEAD, refusing to push." >&2
        return 1
    fi
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
    expected="origin/${local_branch}"
    if [ "$upstream" = "$expected" ]; then
        git push "$@"
    else
        # No upstream OR upstream points elsewhere (e.g. origin/main from
        # inherited from the start-point). Set/correct tracking and push.
        git push -u origin "$local_branch" "$@"
    fi
}

# fast_forward_local_main — refresh local main from origin/main (fail-loud).
#
# Used in two places:
#   1. /catchup invoked while standing on main (no body of work in flight, or
#      the user is just reviewing) — updates local main.
#   2. /work cutting a NEW body-of-work branch — ensures the branch is
#      branched off freshly-pulled main, not a stale local copy.
#
# Caller MUST be standing on main when invoking — this fast-forwards the
# checked-out branch.
#
# Failure semantics (fail-loud):
#   - Not on main/master → exit 3, instruct caller
#   - Working tree dirty → exit 5, refuse (a fast-forward would either fail or
#     silently strand the edits; /work handles the dirty case separately)
#   - `git fetch origin main` fails → exit 6 (network / auth / scope)
#   - Local main has diverged from origin/main (local-only commits) → exit 7
#     with diff summary; this is anomalous under gitflow (Claude doesn't
#     commit to main directly)
#   - Already up-to-date → exit 0 with informational message
#   - Fast-forward succeeds → exit 0, report old → new SHA + commits pulled
fast_forward_local_main() {
    local branch
    branch=$(git branch --show-current)
    if [ -z "$branch" ]; then
        echo "fast_forward_local_main: detached HEAD — cannot refresh main." >&2
        return 3
    fi
    if ! is_protected_branch "$branch"; then
        echo "fast_forward_local_main: must be on main (currently on '$branch')." >&2
        return 3
    fi

    if ! git diff --quiet 2>/dev/null \
       || ! git diff --cached --quiet 2>/dev/null \
       || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        echo "fast_forward_local_main: working tree on $branch has uncommitted or untracked changes." >&2
        echo "  Commit, checkpoint, or stash them before refreshing main." >&2
        echo "  Inspect with 'git status' and resolve before re-running." >&2
        return 5
    fi

    echo "gitflow: fetching origin/$branch." >&2
    local fetch_out
    if ! fetch_out=$(git fetch origin "$branch" 2>&1); then
        echo "fast_forward_local_main: git fetch origin $branch failed: $fetch_out" >&2
        echo "  Fix: check network + gh auth (gh auth status)." >&2
        return 6
    fi

    local local_sha remote_sha
    local_sha=$(git rev-parse HEAD)
    remote_sha=$(git rev-parse "origin/$branch")

    if [ "$local_sha" = "$remote_sha" ]; then
        echo "gitflow: $branch already at origin/$branch ($local_sha) — nothing to pull." >&2
        return 0
    fi

    if git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
        # Local is strict ancestor of remote → clean fast-forward.
        local n
        n=$(git rev-list --count "$local_sha..$remote_sha")
        echo "gitflow: fast-forwarding $branch: ${local_sha:0:8} → ${remote_sha:0:8} (+$n commit(s))." >&2
        if ! git merge --ff-only "origin/$branch"; then
            echo "fast_forward_local_main: merge --ff-only failed unexpectedly." >&2
            return 6
        fi
        return 0
    fi

    if git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
        echo "fast_forward_local_main: local $branch is AHEAD of origin/$branch." >&2
        echo "  Local has commits not on origin/$branch — anomalous under gitflow's model (main is read-only)." >&2
        echo "  Inspect with: git log origin/$branch..HEAD" >&2
        return 7
    fi

    echo "fast_forward_local_main: local $branch and origin/$branch have DIVERGED (no fast-forward path)." >&2
    echo "  Local SHA:  $local_sha" >&2
    echo "  Remote SHA: $remote_sha" >&2
    echo "  Inspect with: git log --oneline --all --graph origin/$branch HEAD" >&2
    return 7
}
