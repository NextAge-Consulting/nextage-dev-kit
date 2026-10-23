#!/bin/bash
# gitflow work: start or resume a body of work on a branch in this checkout.
#
# Usage:
#   work.sh                              # refresh main and stay put, or resume the current branch
#   work.sh --issue <N[,N…]>            # link issue(s) to the current branch, dump their context
#   work.sh <PR#>                        # pick up a pull request: switch to its branch
#   work.sh --retrieve <branch>          # fetch a teammate's branch and switch to it
#   work.sh --discussion <slug|url>      # default mode, then print a finished discussion's folder
#   work.sh --worktree [<name>|<issue#>] # create or re-enter an isolated worktree (opt-in)
#
# Responsibilities:
#   - On main: refresh main from origin and STAY THERE. No branch is cut.
#   - On any other branch: resume it, untouched.
#   - For --issue: validate, link the issue via git config on the CURRENT branch,
#     transition to In Progress, assign the current user, dump issue context for
#     the Claude session. No branch is cut — see below.
#   - For --retrieve: fetch the remote branch, fast-forward any local copy, switch.
#   - For a number that is a pull request (GitHub numbers issues and PRs from one
#     sequence, so a number is never both): switch to the PR's branch as --retrieve
#     does. The readiness wait and the hand-off to /triage or /merge are work.md's.
#   - For --discussion: find the discussion folder the analysis skill wrote (by its
#     slug or by the artifact URL recorded in its pointer), run the default mode,
#     then print the pointer and the folder's files. Reading the published page and
#     its comments needs Claude's own tools, so the pull-back itself is work.md's.
#   - For --worktree: create <primary>/.claude/worktrees/<label> on a new wip/
#     branch, link the per-machine files, install dependencies — or re-enter it.
#     Entering it is work.md's (EnterWorktree), since only Claude can move the session.
#   - In the primary checkout, every mode but --worktree names each open worktree
#     and asks whether to work in it or here.
#
# By default: one checkout, one branch at a time, and `git switch` moves between
# bodies of work. Worktree mode is the opt-in for two sessions at once. They
# cannot share a checkout: they would share one branch and one index, and /commit
# commits everything, so one session's commit would sweep up the other's
# half-done work.
#
# WHY --worktree CUTS A BRANCH AT ONCE
# ------------------------------------
# The one exception to "the branch is cut at the first commit" (below). Two
# worktrees cannot both have `main` checked out, so the worktree gets its own
# branch the moment it exists, cut from origin/main under a placeholder name,
# wip/<login>-<label>. /commit renames it from the first commit's message while
# it is still unpushed, so the branch ends up named as it would have been
# anyway.
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
# commit MESSAGE, and `git-guard.sh` blocks raw `git commit`.
#
# So the branch belongs to the moment the decision is actually made — the first
# commit — not to session-init. `--issue N` is NOT an exception to that. An
# issue number says what the work is ABOUT, never which pipeline it belongs in:
# an issue can be a docs or infra change that belongs straight on main, and in
# a repo with no CI and no deploy the PR round-trip buys nothing at all. Cutting
# a branch on the issue number made /ship-main unreachable for the whole session,
# which is the same failure the paragraph above describes.
#
# --issue therefore parks the link on the current branch and lets the first
# commit carry it across (migrate_branch_linked_issues). /ship-main consumes it
# instead, as a `Closes #N` line for each issue answered code complete — so an
# issue still reaches the deploy status with no PR anywhere in the picture.

set -eo pipefail
shopt -s inherit_errexit 2>/dev/null || true   # propagate errexit into $(…) subshells (bash 4.4+)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

# ─── Arg parsing ───────────────────────────────────────────────────────────

MODE=""        # "", "issue", "retrieve", "discussion", "worktree"
ARG=""         # the value for the mode (issue#, branch, discussion slug or URL, worktree name)

# A value flag given last with no value leaves one argument to shift, not two;
# `shift 2` would then fail and end the script before the mode could say what
# was missing. Each mode reports its own empty value.
while [[ $# -gt 0 ]]; do
    case $1 in
        --issue)
            [ -n "$MODE" ] && { echo "work.sh: --issue conflicts with --$MODE" >&2; exit 2; }
            MODE="issue"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --retrieve)
            [ -n "$MODE" ] && { echo "work.sh: --retrieve conflicts with --$MODE" >&2; exit 2; }
            MODE="retrieve"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --discussion)
            [ -n "$MODE" ] && { echo "work.sh: --discussion conflicts with --$MODE" >&2; exit 2; }
            MODE="discussion"; ARG="${2:-}"; shift $(( $# > 1 ? 2 : 1 )) ;;
        --worktree)
            # The value is optional: a bare --worktree takes a generated label.
            [ -n "$MODE" ] && { echo "work.sh: --worktree conflicts with --$MODE" >&2; exit 2; }
            MODE="worktree"
            if [ $# -gt 1 ] && [ "${2#--}" = "$2" ]; then ARG="$2"; shift 2; else shift 1; fi ;;
        *)
            # Bare positional issue token(s) → shorthand for --issue. Accepts
            # every shape --issue does ("27", "27,28", "#27,#28", "27, 28"), so
            # the two spellings cannot disagree, and the pattern demands a
            # leading digit or #, so a branch name never matches and still
            # reaches the error below.
            #
            # Tokens ACCUMULATE rather than overwrite, which is what makes
            # `work.sh 27 28` work. The shell splits that into two arguments
            # before this loop ever sees it, so a version that only took the
            # first rejected the second as an unknown option — the spelling a
            # person is most likely to type by hand.
            if [[ "$1" =~ ^[#0-9][#0-9,\ ]*$ ]] && { [ -z "$MODE" ] || [ "$MODE" = "issue" ]; }; then
                MODE="issue"; ARG="${ARG:+$ARG,}$1"; shift 1
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

# ─── Guard: a retired global command shadows this project's copy ──────────
# Claude Code resolves command files personal-over-project: with the same file in
# BOTH `~/.claude/commands/` and `<project>/.claude/commands/`, the personal one
# wins and the project's copy never loads. The kit once installed `work.md` and
# `sync-dev-kit.md` globally and now ships both per project — so a machine that
# installed one keeps running the retired doc forever, silently, while the kit's
# current copy sits there inert.
#
# Nothing in the kit's own maintenance path can fix that: `/sync-dev-kit` does
# not scan `~/.claude/` by design, and there is no installer to reconcile it.
# This script is the only thing that runs on EVERY `/work` — and it runs whichever
# doc won, because both invoke it. So this is the one place the stale file can be
# caught. Fail loud rather than warn: a warning on a session-init command is read
# past, and the whole point is that the failure is otherwise invisible.
for RETIRED in work sync-dev-kit; do
    GLOBAL_CMD="$HOME/.claude/commands/$RETIRED.md"
    [ -f "$GLOBAL_CMD" ] || continue
    case "$RETIRED" in
        work)
            WHY="it is the OLD version, which cuts a wip branch at session-init and
  blocks /ship-main. The kit no longer ships a global /work."
            FIX="      rm \"$GLOBAL_CMD\""
            AFTER="Nothing else is needed. The project's copy takes over immediately."
            ;;
        sync-dev-kit)
            WHY="it is the OLD maintainer-only sync, which runs a copied script instead
  of the kit clone's own engine. The kit now ships /sync-dev-kit per project."
            FIX="      rm \"$GLOBAL_CMD\" \"$HOME/.claude/scripts/sync-dev-kit.sh\" \"$HOME/.claude/scripts/sync-dev-kit.test.sh\""
            AFTER="A project with no .claude/commands/sync-dev-kit.md yet gets it from 'Set up'
  in the kit's project-documentation/kit-sync-cheatsheet.md."
            ;;
    esac
    cat >&2 <<EOF
work.sh: REFUSING — a retired global /$RETIRED command is shadowing this project's copy.

  Found:   $GLOBAL_CMD
  Shadows: $PROJECT_ROOT/.claude/commands/$RETIRED.md

  Personal commands outrank project commands, so the file above is what /$RETIRED
  reads — and $WHY

  Fix it with one command, then re-run /work:

$FIX

  $AFTER
EOF
    exit 8
done

# ─── Helper: is the working tree clean? ────────────────────────────────────
# Untracked counts as dirty: an untracked file is usually the bulk of a
# half-finished change, and treating it as "clean" is how work gets stranded.
tree_is_clean() {
    git diff --quiet 2>/dev/null && \
        git diff --cached --quiet 2>/dev/null && \
        [ -z "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

# ─── Helper: refresh main, never blocking ──────────────────────────────────
# Starting work with edits already in the tree is ordinary (you noticed something
# before you typed /work). fast_forward_local_main carries them across the
# fast-forward, so the work continues on the newest main.
#
# So: refresh when we can, say so loudly when we cannot, and never block.
refresh_main_if_possible() {
    local rc=0
    fast_forward_local_main || rc=$?
    case "$rc" in
        0) ;;
        8) echo "work.sh: main is refreshed, but your changes conflict with what came in (files above)." >&2
           echo "  Resolve those before anything else." >&2 ;;
        *) echo "work.sh: could not refresh main from origin (cause above)." >&2
           echo "  Your changes are untouched; main is left at the commit you had. /catchup once it is fixed." >&2
           main_drift_report main work.sh || true ;;
    esac
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
        echo "  /commit branches from your message · /ship-main commits here." >&2
        report_parked_issue_links "$branch"
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — they follow you onto whichever path you take)" >&2
        fi
    else
        echo "work.sh: resuming body of work on '$branch'." >&2
        # Resuming refreshes nothing — but a main that moved while this branch sat
        # is exactly what the rest of the body of work would otherwise trip over.
        main_drift_report main work.sh || true
        if ! tree_is_clean; then
            echo "work.sh: (uncommitted changes present — picking up where you left off)" >&2
        fi
    fi
}

# ─── Mode: --issue <N[,N…]> ────────────────────────────────────────────────
#
# Linking the FIRST issue and linking a further issue mid-work are the same act,
# so this is the only place either happens. Nothing here cares whether the branch
# already carries links; `link_issue_to_branch` is idempotent and the git-config
# list simply grows.
mode_issue() {
    local nums
    nums=$(parse_issue_csv "$ARG")
    if [ -z "$nums" ]; then
        echo "work.sh: --issue had no valid issue numbers: '$ARG'" >&2
        echo "  Accepts: 27 · 27,28 · '#27 #28'" >&2
        exit 2
    fi

    local branch num
    branch=$(git branch --show-current)

    if [ -z "$branch" ]; then
        echo "work.sh: detached HEAD — refusing to link $(format_issue_refs "$nums")." >&2
        echo "  Inspect with 'git status', then switch to a branch." >&2
        exit 7
    fi

    # EVERY issue is validated before ANY side-effect fires. Validating inside
    # the apply loop would leave the first two issues linked, transitioned and
    # assigned when the third turns out to be a typo — a half-applied state the
    # user then has to find and unpick by hand.
    for num in $nums; do
        if ! validate_issue "$num" >/dev/null; then
            echo "work.sh: issue #$num inaccessible; aborting without linking anything" >&2
            exit 4
        fi
    done

    if is_protected_branch "$branch"; then
        # No branch is cut here. An issue number says what the work is ABOUT,
        # not which pipeline it belongs in: plenty of issues are a docs or
        # infra change that should go straight to main, and cutting a branch
        # now blocks /ship-main for the rest of the session. The link parks on
        # this branch and the first commit carries it onto whatever branch it
        # creates. See the header.
        refresh_main_if_possible
        echo "work.sh: $(format_issue_refs "$nums") linked on '$branch' — no branch cut." >&2
        echo "  /commit branches from your message and carries the link · /ship-main commits here and closes it." >&2
    else
        # Already on a body of work → one more issue on it.
        echo "work.sh: on branch '$branch' — linking $(format_issue_refs "$nums") to it." >&2
    fi

    for num in $nums; do
        link_issue_to_branch "$num"
        move_issue_to_in_progress "$num"
        assign_issue_to_current_user "$num"
    done

    # Context last, and in its own loop: the linking chatter above is noise the
    # reader scrolls past, and the issue bodies are the part actually read.
    for num in $nums; do
        dump_issue_context "$num"
    done
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

# ─── Mode: <PR#> — pick up a pull request ──────────────────────────────────
# An issue number and a PR number never collide, so `/work <N>` asks GitHub which
# one N is. A PR is picked up: its branch fetched and switched to. A PR mixed into a
# list of issues is refused before anything is linked.
is_pull_request() {
    gh api "repos/{owner}/{repo}/issues/$1" --jq 'has("pull_request")' 2>/dev/null | grep -qx true
}

mode_pickup_pr() {
    local pr="$1" info state branch cross url
    if ! info=$(gh pr view "$pr" --json state,headRefName,isCrossRepository,url \
            --jq '[.state, .headRefName, (.isCrossRepository|tostring), .url] | @tsv' 2>&1); then
        echo "work.sh: could not read PR #$pr: $info" >&2
        exit 4
    fi
    IFS=$'\t' read -r state branch cross url <<< "$info"
    if [ "$state" != "OPEN" ]; then
        echo "work.sh: PR #$pr is $(printf '%s' "$state" | tr '[:upper:]' '[:lower:]') — nothing to pick up. ($url)" >&2
        exit 0
    fi
    if [ "$cross" = "true" ]; then
        echo "work.sh: PR #$pr comes from a fork; its branch is not on origin. Review it on GitHub: $url" >&2
        exit 4
    fi
    ARG="$branch"
    mode_retrieve
    echo "work.sh: picked up PR #$pr ($url)." >&2
}

# ─── Mode: --discussion <slug|url> ─────────────────────────────────────────
# A discussion lives in project-documentation/temporary/discussion-<slug>/, with a
# pointer <slug>-discussion.md whose front matter records the artifact URL. The human
# copies whichever is to hand — the slug from the folder, or the URL from the browser
# tab the discussion happened in — so both resolve.
#
# Resolved BEFORE the default mode runs: a typo fails with nothing refreshed.
DISCUSSION_ROOT="project-documentation/temporary"

# The artifact id is the URL's last path segment; the query, fragment and a
# trailing slash are noise a copied link may carry.
artifact_id_of() {
    local u="$1"
    u="${u%%[?#]*}"
    u="${u%/}"
    printf '%s\n' "${u##*/}"
}

pointer_artifact() {
    awk '/^artifact:/ { sub(/^artifact:[ \t]*/, ""); print; exit }' "$1"
}

list_open_discussions() {
    local p d found=""
    for p in "$DISCUSSION_ROOT"/discussion-*/*-discussion.md; do
        [ -f "$p" ] || continue
        found=1
        d="${p%/*}"
        echo "  ${d##*/discussion-}  $(pointer_artifact "$p")" >&2
    done
    [ -n "$found" ] || echo "  (none — no discussion-*/ folder under $DISCUSSION_ROOT/)" >&2
}

resolve_discussion() {
    local want="$1" p slug id
    if [[ "$want" == *"://"* ]]; then
        id=$(artifact_id_of "$want")
        for p in "$DISCUSSION_ROOT"/discussion-*/*-discussion.md; do
            [ -f "$p" ] || continue
            [ "$(artifact_id_of "$(pointer_artifact "$p")")" = "$id" ] && { dirname "$p"; return 0; }
        done
        return 1
    fi
    slug="${want#discussion-}"
    slug="${slug%/}"
    [ -f "$DISCUSSION_ROOT/discussion-$slug/$slug-discussion.md" ] || return 1
    echo "$DISCUSSION_ROOT/discussion-$slug"
}

mode_discussion() {
    if [ -z "$ARG" ]; then
        echo "work.sh: --discussion requires a slug or the artifact URL" >&2
        exit 2
    fi

    local dir
    if ! dir=$(resolve_discussion "$ARG"); then
        echo "work.sh: no discussion matches '$ARG'. Open discussions:" >&2
        list_open_discussions
        exit 4
    fi

    mode_default

    local slug f
    slug="${dir##*/discussion-}"
    echo "work.sh: discussion '$slug' — $dir/" >&2
    echo "=== DISCUSSION FOLDER: $dir/ ==="
    for f in "$dir"/*; do
        [ -e "$f" ] && echo "  ${f##*/}"
    done
    echo "=== POINTER: $dir/$slug-discussion.md ==="
    cat "$dir/$slug-discussion.md"
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

# ─── Mode: --worktree [<name>|<issue#>] ────────────────────────────────────
# Opt-in isolation: a worktree at <primary>/.claude/worktrees/<label> on a wip/
# branch of its own (the header says why the branch is cut now). The label is the
# name given; for an issue, <N>-<slug of its title>; with neither,
# <login>-<YYYYMMDD-HHMM> in UTC. An existing label is re-entered, never recreated.
#
# stdout carries `WORKTREE: <path>` for work.md's EnterWorktree, and
# `WORKTREE-HANDOFF: <file>` when the worktree's own handoff exists.
WORKTREE_HANDOFF=".claude/worktree-handoff.md"

# The login a label or branch is named for. gh's when it answers, else the OS user —
# a label is a name, not an identity check, so being offline never blocks one.
worktree_login() {
    local login
    if login=$(gh_login); then printf '%s\n' "$login"; return 0; fi
    login=$(id -un)
    echo "work.sh: gh could not say who you are — naming the worktree for '$login'." >&2
    printf '%s\n' "$login"
}

# Symlink the per-machine files a worktree needs from the primary checkout: every
# gitignored .env / .env.* and .claude/settings.local.json. Absolute targets, so a
# change in the primary is a change everywhere. Idempotent: an existing file or link
# is left alone, so re-entry heals only what is missing. node_modules is never
# linked — bundlers resolve a symlinked node_modules to the primary's path and load
# a second copy of every package; the worktree installs its own.
link_worktree_files() {
    local primary="$1" wt="$2" rel listing
    if ! listing=$(git -C "$primary" ls-files --others --ignored --exclude-standard --directory); then
        echo "work.sh: could not list the primary checkout's ignored files — nothing linked." >&2
        return 1
    fi
    while IFS= read -r rel; do
        case "${rel##*/}" in
            .env.example) continue ;;
            .env|.env.*) ;;
            *) [ "$rel" = ".claude/settings.local.json" ] || continue ;;
        esac
        if [ -e "$wt/$rel" ] || [ -L "$wt/$rel" ]; then continue; fi
        mkdir -p "$(dirname "$wt/$rel")"
        ln -s "$primary/$rel" "$wt/$rel"
        echo "work.sh: linked $rel from the primary checkout." >&2
    done <<< "$listing"
}

# Install from the committed lockfile (rules/dependencies.md): never a bare install,
# which may rewrite the lockfile. Returns non-zero when the install failed.
install_worktree_dependencies() {
    local wt="$1" cmd
    if   [ -f "$wt/package-lock.json" ]; then cmd="npm ci --no-audit --no-fund"
    elif [ -f "$wt/pnpm-lock.yaml" ];    then cmd="pnpm install --frozen-lockfile"
    elif [ -f "$wt/yarn.lock" ] && [ -f "$wt/.yarnrc.yml" ]; then cmd="yarn install --immutable"
    elif [ -f "$wt/yarn.lock" ];         then cmd="yarn install --frozen-lockfile"
    elif [ -f "$wt/bun.lock" ] || [ -f "$wt/bun.lockb" ]; then cmd="bun install --frozen-lockfile"
    elif [ -f "$wt/uv.lock" ];           then cmd="uv sync --frozen"
    else
        echo "work.sh: no lockfile in the worktree — no dependencies to install." >&2
        return 0
    fi
    echo "work.sh: installing dependencies in the worktree ($cmd)…" >&2
    # shellcheck disable=SC2086 # $cmd is one of the fixed commands above, split on purpose
    ( cd "$wt" && $cmd ) >&2
}

mode_worktree() {
    local primary label="" issue="" title login="" path branch existing
    if ! primary=$(primary_checkout_root); then
        echo "work.sh: could not find the primary checkout ('git worktree list' failed)." >&2
        exit 3
    fi

    if [[ "$ARG" =~ ^#?[0-9]+$ ]]; then
        issue="${ARG#\#}"
        # An issue's worktree is found by its number, so a retitled issue still re-enters.
        while IFS=$'\t' read -r existing _; do
            case "$existing" in "$issue"-*) label="$existing"; break ;; esac
        done < <(list_open_worktrees "$primary")
        if [ -z "$label" ]; then
            if ! title=$(validate_issue "$issue"); then
                echo "work.sh: issue #$issue inaccessible; no worktree created." >&2
                exit 4
            fi
            label="$issue-$(slugify "$title")"
            label="${label%-}"
        fi
    elif [ -n "$ARG" ]; then
        if ! [[ "$ARG" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo "work.sh: worktree name '$ARG' — use letters, digits, '.', '_' and '-'." >&2
            exit 2
        fi
        label="$ARG"
    else
        login=$(worktree_login)
        label="$login-$(date -u +%Y%m%d-%H%M)"
    fi
    path="$primary/$WORKTREES_SUBDIR/$label"

    if [ -e "$path" ]; then
        local registered
        if ! registered=$(git -C "$primary" worktree list --porcelain); then
            echo "work.sh: 'git worktree list' failed — cannot tell whether $path is a worktree." >&2
            exit 3
        fi
        if ! grep -qxF "worktree $path" <<< "$registered"; then
            echo "work.sh: $path exists but is not a worktree of this repository — move it aside." >&2
            exit 4
        fi
        branch=$(git -C "$path" branch --show-current)
        echo "work.sh: re-entering worktree '$label' (${branch:-detached})." >&2
        link_worktree_files "$primary" "$path" || true
        echo "WORKTREE: $path"
        [ -f "$path/$WORKTREE_HANDOFF" ] && echo "WORKTREE-HANDOFF: $path/$WORKTREE_HANDOFF"
        return 0
    fi

    local fetch_out
    if ! fetch_out=$(git -C "$primary" fetch origin main 2>&1); then
        printf '%s\n' "$fetch_out" >&2
        echo "work.sh: could not fetch origin/main — no worktree created. Check network and 'gh auth status'." >&2
        exit 6
    fi
    [ -n "$login" ] || login=$(worktree_login)
    branch=$(resolve_collision "wip/$login-$label")
    mkdir -p "$primary/$WORKTREES_SUBDIR"
    # --no-track: a branch cut from origin/main must not take origin/main as its upstream.
    if ! git -C "$primary" worktree add --no-track -b "$branch" "$path" origin/main >&2; then
        echo "work.sh: 'git worktree add' failed (git's reason above) — no worktree created." >&2
        exit 9
    fi
    echo "work.sh: created worktree '$label' on $branch, from origin/main." >&2
    link_worktree_files "$primary" "$path" || true
    cd "$path"

    if [ -n "$issue" ]; then
        link_issue_to_branch "$issue" "$branch"
        move_issue_to_in_progress "$issue"
        assign_issue_to_current_user "$issue"
    fi

    local install_rc=0
    install_worktree_dependencies "$path" || install_rc=$?

    echo "WORKTREE: $path"
    [ -n "$issue" ] && dump_issue_context "$issue"
    if [ "$install_rc" -ne 0 ]; then
        echo "work.sh: the worktree is ready, but installing its dependencies FAILED (above)." >&2
        echo "  Fix the cause and run the install inside $path before building or testing." >&2
        exit 11
    fi
}

# In the primary checkout, each open worktree is named with the one question the
# session asks about it. Nothing more: what is in it is that worktree's business.
report_open_worktrees() {
    in_linked_worktree && return 0
    local primary label branch
    primary=$(primary_checkout_root) || return 0
    while IFS=$'\t' read -r label branch; do
        [ -n "$label" ] || continue
        echo "You have an open worktree $label (branch $branch). Work in it, or here?"
    done < <(list_open_worktrees "$primary")
}

# ─── Dispatch ──────────────────────────────────────────────────────────────
case "$MODE" in
    "worktree") mode_worktree; exit 0 ;;
esac
report_open_worktrees
case "$MODE" in
    "")         mode_default ;;
    "issue")
        # One PR on its own is picked up; a PR among issues is refused.
        nums=$(parse_issue_csv "$ARG")
        prs=""
        for n in $nums; do is_pull_request "$n" && prs="${prs:+$prs }$n"; done
        if [ -n "$prs" ]; then
            if [ "$prs" != "$nums" ] || [ "$(wc -w <<< "$prs")" -ne 1 ]; then
                echo "work.sh: $(format_issue_refs "$prs") is a pull request; pick it up on its own (/work <PR#>)." >&2
                exit 2
            fi
            mode_pickup_pr "$prs"
        else
            mode_issue
        fi
        ;;
    "retrieve") mode_retrieve ;;
    "discussion") mode_discussion ;;
    *)
        echo "work.sh: internal error — unknown mode '$MODE'" >&2
        exit 99
        ;;
esac
