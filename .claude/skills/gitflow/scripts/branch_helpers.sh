#!/bin/bash
# gitflow branch helpers: shared functions for branch creation and rename.
# Sourced by the gitflow command scripts. Every function is safe under `set -e`.

# post_gemini_review <pr_number> — posts the `/gemini review` trigger comment on the
# PR; returns gh's exit status. The text goes on stdin, never as an argument: Git Bash
# rewrites an argument that starts with "/" into a Windows path before gh sees it, and
# the PR would get "C:/Program Files/Git/gemini review", which triggers nothing.
post_gemini_review() {
    printf '%s' "/gemini review" | gh pr comment "$1" --body-file -
}

# ─── PR hand-off ────────────────────────────────────────────────────────────
# A PR assigned to someone other than you has left your hands: the review is
# theirs, and the next thing you commit belongs on a branch of its own, cut from
# this one (a stacked branch). GitHub's assignee is the record; nothing is kept
# locally except which branch a stacked one was cut from.

# gh_login — the GitHub login gh is signed in as; returns 1, printing nothing,
# when gh cannot say.
gh_login() {
    local login
    login=$(gh api user --jq .login 2>/dev/null) || return 1
    [ -n "$login" ] || return 1
    printf '%s\n' "$login"
}

# open_pr_for_branch <branch> — the number of the branch's open PR, or nothing.
open_pr_for_branch() {
    gh pr list --head "$1" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true
}

# pr_state_for_branch <branch> — OPEN, MERGED or CLOSED for the newest PR whose head
# is <branch>, or nothing when it has none or gh cannot say.
pr_state_for_branch() {
    gh pr list --head "$1" --state all --json state --jq '.[0].state // empty' 2>/dev/null || true
}

# pr_handed_off <branch> — returns 0, printing the assignees, when the branch's open
# PR is assigned and not to you. Returns 1 when it is yours: assigned to you, to
# nobody, or there is no open PR. Returns 2 when gh cannot answer.
pr_handed_off() {
    local me assignees a
    me=$(gh_login) || return 2
    assignees=$(gh pr list --head "$1" --state open --json assignees \
        --jq '.[0].assignees // [] | map(.login) | join(" ")' 2>/dev/null) || return 2
    [ -n "$assignees" ] || return 1
    for a in $assignees; do [ "$a" = "$me" ] && return 1; done
    printf '%s\n' "$assignees"
}

# list_collaborators — the repository's collaborators, one login per line, without you.
list_collaborators() {
    local me all
    me=$(gh_login) || me=""
    all=$(gh api "repos/{owner}/{repo}/collaborators" --paginate --jq '.[].login') || return 1
    printf '%s\n' "$all" | awk -v me="$me" 'NF && $0 != me'
}

# hand_pr_to <pr_number> <login> — make <login> the PR's only assignee, and request
# their review unless they wrote it (GitHub refuses an author's own review request).
hand_pr_to() {
    local pr="$1" who="$2" info author current remove="" a
    info=$(gh pr view "$pr" --json author,assignees \
        --jq '[.author.login, (.assignees | map(.login) | join(" "))] | @tsv') || return 1
    author=${info%%$'\t'*}
    current=${info#*$'\t'}
    for a in $current; do [ "$a" = "$who" ] || remove="${remove:+$remove,}$a"; done
    local args=(pr edit "$pr" --add-assignee "$who")
    [ -n "$remove" ] && args+=(--remove-assignee "$remove")
    [ "$who" != "$author" ] && args+=(--add-reviewer "$who")
    gh "${args[@]}" >/dev/null
}

# set_branch_parent <branch> <parent> · branch_parent <branch> · clear_branch_parent <branch>
# The handed-off branch a stacked branch was cut from, in git config
# (branch.<name>.gitflow-parent). /open-pr points the stacked PR at it while it is
# open; /catchup follows it, and drops it once the parent has merged.
set_branch_parent() { git config --local "branch.$1.gitflow-parent" "$2"; }
branch_parent() { git config --local --get "branch.$1.gitflow-parent" 2>/dev/null || true; }
clear_branch_parent() { git config --local --unset-all "branch.$1.gitflow-parent" 2>/dev/null || true; }

# is_protected_branch <name> — returns 0 if branch is main or master.
is_protected_branch() {
    [ "$1" = "main" ] || [ "$1" = "master" ]
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

# ─── Checkpoints ──────────────────────────────────────────────────────────
# A checkpoint is a LOCAL commit on whatever branch is checked out — main
# included — and is never pushed. /commit and /ship-main fold every unpushed
# checkpoint into the one real commit they make, so a `🔖 wip:` subject never
# reaches origin, where /deploy would read it to compute the version bump.
CHECKPOINT_PREFIX='🔖 wip:'

# checkpoint_fold_base — echoes the commit that the trailing run of unpushed
# checkpoint commits sits on; HEAD itself when there are none.
#
# Walks back from HEAD while the commit is a checkpoint AND no remote ref
# contains it. A pushed checkpoint (from before checkpoints went local) is never
# folded: rewriting it would need a force-push. A root commit stops the walk.
checkpoint_fold_base() {
    local base subject
    base=$(git rev-parse HEAD)
    while :; do
        subject=$(git log -1 --format=%s "$base")
        case "$subject" in
            "$CHECKPOINT_PREFIX"*) ;;
            *) break ;;
        esac
        [ -z "$(git for-each-ref --contains "$base" --format='%(refname)' refs/remotes)" ] || break
        git rev-parse --verify --quiet "${base}^" >/dev/null || break
        base=$(git rev-parse "${base}^")
    done
    echo "$base"
}

# fold_checkpoints <base> — soft-reset HEAD to <base>, so every checkpoint
# commit above it becomes staged content for the caller's single commit.
# No-op when <base> is HEAD. Run it only after every gate has passed: a gate
# that fails afterwards would leave the checkpoints already unwound.
fold_checkpoints() {
    local base="$1" n
    [ "$base" = "$(git rev-parse HEAD)" ] && return 0
    n=$(git rev-list --count "${base}..HEAD")
    echo "gitflow: folding $n checkpoint commit(s) into this commit." >&2
    git reset --soft "$base"
}

# fast_forward_local_main — refresh local main from origin/main (fail-loud).
#
# Used in two places:
#   1. /catchup invoked while standing on main (no body of work in flight, or
#      the user is just reviewing) — updates local main.
#   2. /work started on main — so work begins on freshly-pulled main, not a
#      stale local copy.
#
# Caller MUST be standing on main when invoking — this fast-forwards the
# checked-out branch.
#
# Uncommitted changes on main are carried across the fast-forward
# (`git merge --ff-only --autostash`): the usual case is work started before
# catching up, and the person needs the new commits under it without choosing a
# branch first.
#
# Failure semantics (fail-loud):
#   - Not on main/master → exit 3, instruct caller
#   - An untracked file has the name of one the pull adds → exit 5; main and the
#     changes are both left as they were, and git's message names the file
#   - `git fetch origin main` fails → exit 6 (network / auth / scope)
#   - Local main has commits origin/main lacks → exit 7. Checkpoints are the
#     one ordinary cause (they are local by design), and the message names
#     /commit or /ship-main as the way out; anything else is anomalous
#   - Main moved but the uncommitted changes conflict with the pulled commits →
#     exit 8; the changes are kept in the stash, the conflicted files named
#   - Already up-to-date → exit 0 with informational message, nothing stashed
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

    local dirty=0
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        dirty=1
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
        if [ "$dirty" -eq 0 ]; then
            local ff_out
            if ! ff_out=$(git merge --ff-only "origin/$branch" 2>&1); then
                printf '%s\n' "$ff_out" >&2
                echo "fast_forward_local_main: could not fast-forward $branch (git's reason above)." >&2
                echo "  $branch and your files are unchanged. Usually an untracked file has the name of one the pull adds; move it aside and re-run." >&2
                return 5
            fi
            return 0
        fi
        local stashes_before merge_out conflicted
        stashes_before=$(git stash list | wc -l)
        echo "gitflow: carrying your uncommitted changes across the fast-forward." >&2
        if ! merge_out=$(git merge --ff-only --autostash "origin/$branch" 2>&1); then
            printf '%s\n' "$merge_out" >&2
            echo "fast_forward_local_main: could not fast-forward $branch (git's reason above)." >&2
            echo "  $branch and your changes are unchanged. Usually an untracked file has the name of one the pull adds; move it aside and re-run." >&2
            return 5
        fi
        conflicted=$(git diff --name-only --diff-filter=U)
        if [ -n "$conflicted" ] || [ "$(git stash list | wc -l)" -gt "$stashes_before" ]; then
            echo "fast_forward_local_main: $branch is up to date, but your uncommitted changes and the pulled commits changed the same lines." >&2
            [ -n "$conflicted" ] && printf '%s\n' "$conflicted" | sed 's/^/  conflicted: /' >&2
            echo "  Your changes are safe in the stash (the top entry of 'git stash list')." >&2
            echo "  Resolve the conflict markers in the files above, then 'git stash drop' that entry." >&2
            return 8
        fi
        echo "gitflow: your uncommitted changes are back in place on the new $branch." >&2
        return 0
    fi

    if [ "$(checkpoint_fold_base)" != "$local_sha" ]; then
        echo "fast_forward_local_main: local $branch carries unpushed checkpoint commits." >&2
        echo "  /commit (branch + PR) or /ship-main (straight to $branch) folds them into one real commit." >&2
        return 7
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

# main_drift_report [base] [who] — say how far the current branch has fallen
# behind origin/<base>, and which files both sides touched. Silent when it has not.
#
# A branch cut from a stale local main, or left open while another PR merges,
# otherwise goes unnoticed until the final squash fails — after the review, the
# triage and the build have all run on code that cannot merge. So every command
# that starts or advances a body of work calls this and reports early, while the
# conflict is still small and the tree is still yours.
#
# "Ours" counts uncommitted and untracked changes too: on main, before /commit
# cuts a branch, the whole body of work is still in the working tree.
#
# Returns 0 when HEAD already contains origin/<base>, and also when the fetch
# failed (reported — being offline never blocks work). Returns 10 when HEAD is
# behind. Callers WARN on 10; only /merge refuses, and only on a real conflict
# (main_merge_conflicts).
main_drift_report() {
    local base="${1:-main}" who="${2:-gitflow}" target mb n theirs ours overlap
    target="origin/$base"
    if ! git fetch -q origin "$base" 2>/dev/null; then
        echo "$who: could not fetch $target — whether $base has moved is unknown." >&2
        return 0
    fi
    if git merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
        return 0
    fi
    if ! mb=$(git merge-base HEAD "$target" 2>/dev/null); then
        return 0
    fi
    n=$(git rev-list --count "HEAD..$target")
    echo "$who: $base has moved — this checkout is $n commit(s) behind $target:" >&2
    git log -n 10 --format='    %h %s' "HEAD..$target" >&2
    if [ "$n" -gt 10 ]; then
        echo "    … and $((n - 10)) more" >&2
    fi
    theirs=$(git diff --name-only "$mb" "$target" | sort -u)
    ours=$( { git diff --name-only "$mb" HEAD; git diff --name-only HEAD; \
              git ls-files --others --exclude-standard; } | sort -u)
    overlap=$(comm -12 <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | grep -v '^$' || true)
    if [ -n "$overlap" ]; then
        echo "  Changed on both sides — catch up now, while the conflict is small:" >&2
        printf '%s\n' "$overlap" | sed -n '1,20s/^/    /p' >&2
    fi
    if is_protected_branch "$(git branch --show-current)"; then
        echo "  Run /catchup to fast-forward $base (commit or checkpoint uncommitted edits first)." >&2
    else
        echo "  Run /catchup to merge $base into this branch." >&2
    fi
    return 10
}

# main_merge_conflicts [base] — would merging origin/<base> into HEAD conflict?
#
# A trial merge with `git merge-tree`: nothing in the working tree, the index or
# any ref is touched. Deterministic and local, unlike the host's own "mergeable"
# flag, which is recomputed asynchronously and reads UNKNOWN for seconds after
# every push. Needs git 2.38+.
#
# Returns 0 when it merges cleanly, 1 on a conflict (conflicted paths printed),
# 2 when it cannot tell (old git, missing ref) — callers treat 2 as unknown.
main_merge_conflicts() {
    local base="${1:-main}" out rc
    # `&& rc=0 || rc=$?`, never a bare assignment: under a caller's `set -e` a
    # conflict (exit 1) would otherwise end the caller instead of reporting.
    out=$(git merge-tree --write-tree --name-only --no-messages HEAD "origin/$base" 2>/dev/null) && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
        return 0
    fi
    if [ "$rc" -eq 1 ]; then
        printf '%s\n' "$out" | sed -n '2,$ { /^$/d; s/^/    /; p; }' >&2
        return 1
    fi
    return 2
}
