#!/bin/bash
# gitflow open-pr: push current branch, create a PR.
# Usage: open-pr.sh --title "<PR title>" --body "<PR body>" \
#                   [--base main] [--draft]
#
# Changelog: NOT touched here. Single-writer model — `/deploy` is the sole
# author of changelog.md (deploy.sh inserts the consolidated release entry
# under today's date header at version-bump time). open-pr previously also
# wrote a per-PR entry; that produced duplicate bullets in main's changelog
# (one from open-pr's feature-branch commit + one from deploy's release-
# branch commit). The duplicate was structural: both scripts read the same
# --changelog-file content, both wrote under the same date header, neither
# deduped. Removed entirely rather than patched.
#
# Transport detection (for PR creation):
#   - If `gh` is available (local), uses gh pr create
#   - Else (cloud containers), uses GitHub REST API via curl + $GITHUB_TOKEN
#
# Cloud Claude sessions receive $GITHUB_TOKEN automatically via the GitHub proxy.
# Local Claude sessions must have `gh auth login` completed, or set $GITHUB_TOKEN manually.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"
# shellcheck source=_claude-project/skills/gitflow/scripts/branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"

TITLE=""
BODY=""
BASE="main"
DRAFT=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --title)            TITLE="$2"; shift 2 ;;
        --body)             BODY="$2"; shift 2 ;;
        --base)             BASE="$2"; shift 2 ;;
        --draft)            DRAFT="--draft"; shift 1 ;;
        *) echo "open-pr.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$TITLE" ]; then
    echo "open-pr.sh: --title is required" >&2
    exit 2
fi
if [ -z "$BODY" ]; then
    echo "open-pr.sh: --body is required" >&2
    exit 2
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" = "$BASE" ]; then
    echo "open-pr.sh: current branch is $BASE — cannot open PR against itself." >&2
    exit 3
fi

# Working tree must be clean (caller should have committed first).
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "open-pr.sh: working tree has uncommitted changes. /commit or /checkpoint first." >&2
    exit 3
fi

# ─── Inject Closes #N from branch-scoped linked issues ────────────────────
# Issues linked via /work <issue#> or /link are stored in git config
# (branch.<name>.gitflow-issues). Prepend a `Closes #N, #M ...` line to the
# PR body so GitHub's native auto-close fires on merge — without requiring
# a human to remember the syntax. Idempotent: if the body already starts
# with Closes, we don't double-prepend.
LINKED_ISSUES=$(read_branch_linked_issues "$CURRENT_BRANCH")
if [ -n "$LINKED_ISSUES" ]; then
    CLOSES_LINE="Closes"
    for num in $LINKED_ISSUES; do
        CLOSES_LINE="${CLOSES_LINE} #${num},"
    done
    CLOSES_LINE="${CLOSES_LINE%,}"
    if ! printf '%s' "$BODY" | head -n 1 | grep -qE '^Closes\s+#[0-9]'; then
        BODY="${CLOSES_LINE}

${BODY}"
        echo "gitflow: prepended '$CLOSES_LINE' to PR body (from branch-linked issues)." >&2
    fi
fi

# ─── Push and create PR ────────────────────────────────────────────────────

# Push branch via safe_push — handles missing-upstream AND wrong-upstream
# (e.g. origin/main inherited from the branch's start-point).
# shellcheck disable=SC2119 # safe_push takes no args by design (reads current branch + upstream from git state)
safe_push

# Create PR
PR_NUMBER=""
if command -v gh >/dev/null 2>&1; then
    echo "gitflow: creating PR via gh..." >&2
    PR_URL=$(gh pr create --title "$TITLE" --body "$BODY" --base "$BASE" $DRAFT)
    echo "$PR_URL"
    PR_NUMBER=$(basename "$PR_URL")
elif [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "gitflow: creating PR via GitHub REST API (gh not available)..." >&2

    # Derive owner/repo from origin URL
    REMOTE_URL=$(git config --get remote.origin.url)
    # Handles https://github.com/OWNER/REPO.git and git@github.com:OWNER/REPO.git
    REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's#(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#')
    if [ -z "$REPO_SLUG" ]; then
        echo "open-pr.sh: could not parse owner/repo from $REMOTE_URL" >&2
        exit 6
    fi

    DRAFT_JSON="false"
    [ -n "$DRAFT" ] && DRAFT_JSON="true"
    PAYLOAD=$(jq -n \
        --arg title "$TITLE" \
        --arg body  "$BODY" \
        --arg head  "$CURRENT_BRANCH" \
        --arg base  "$BASE" \
        --argjson draft "$DRAFT_JSON" \
        '{title: $title, body: $body, head: $head, base: $base, draft: $draft}')

    RESPONSE=$(curl -sS -X POST \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO_SLUG}/pulls" \
        -d "$PAYLOAD")

    PR_URL=$(echo "$RESPONSE" | jq -r '.html_url // empty')
    if [ -z "$PR_URL" ]; then
        echo "open-pr.sh: PR creation failed." >&2
        echo "$RESPONSE" | jq -r '.message // .' >&2
        exit 7
    fi
    PR_NUMBER=$(echo "$RESPONSE" | jq -r '.number // empty')
    echo "gitflow: PR opened: $PR_URL" >&2
else
    echo "open-pr.sh: neither gh CLI nor \$GITHUB_TOKEN available. Cannot create PR." >&2
    exit 8
fi

# ─── Trigger Gemini review explicitly ──────────────────────────────────────
# Gemini Code Assist's auto-review on PR open is disabled in
# _gemini-project/config.yaml (pull_request_opened.code_review: false).
# Trigger the first review here so /triage has something to walk and
# wait-for-pr-ready.sh sees a posted trigger (it gates on the presence
# of a `/gemini review` comment scoped to the current HEAD).
#
# Skipped when:
#   - GEMINI_NOT_INSTALLED="true" in .claude/sync-substitutions.json
#     (this repo genuinely has no Gemini App installed)
#   - $DRAFT is set (draft PRs honor include_drafts: false)
#
# Fail-loud on post failure: if the trigger isn't posted, the wait gate
# downstream will proceed CI-only on this HEAD and the user will silently
# lose Gemini coverage on the initial review. Surface it now so the user
# can decide (retry the comment, set GEMINI_NOT_INSTALLED, or accept).
if [ -n "$PR_NUMBER" ] && [ -z "$DRAFT" ]; then
    PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    SUBS_FILE="${PROJECT_ROOT}/.claude/sync-substitutions.json"
    GEMINI_SKIP=""
    if [ -n "$PROJECT_ROOT" ] && [ -f "$SUBS_FILE" ] && command -v jq >/dev/null 2>&1; then
        GEMINI_SKIP=$(jq -r '.GEMINI_NOT_INSTALLED // ""' "$SUBS_FILE" 2>/dev/null || echo "")
    fi
    if [ "$GEMINI_SKIP" != "true" ]; then
        if command -v gh >/dev/null 2>&1; then
            if gh pr comment "$PR_NUMBER" --body "/gemini review" >/dev/null 2>&1; then
                echo "gitflow: posted /gemini review on PR #$PR_NUMBER — Gemini will review within ~5 min" >&2
            else
                echo "open-pr.sh: failed to post /gemini review on PR #$PR_NUMBER." >&2
                echo "  PR is open. Post the comment manually or re-run with gh authenticated." >&2
                exit 9
            fi
        elif [ -n "${GITHUB_TOKEN:-}" ]; then
            if ! RESPONSE=$(curl -sS -X POST \
                -H "Authorization: Bearer $GITHUB_TOKEN" \
                -H "Accept: application/vnd.github+json" \
                -H "X-GitHub-Api-Version: 2022-11-28" \
                "https://api.github.com/repos/${REPO_SLUG}/issues/${PR_NUMBER}/comments" \
                -d '{"body": "/gemini review"}' 2>/dev/null); then
                echo "open-pr.sh: curl command failed to post /gemini review." >&2
                exit 9
            fi
            if echo "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
                echo "gitflow: posted /gemini review on PR #$PR_NUMBER — Gemini will review within ~5 min" >&2
            else
                echo "open-pr.sh: failed to post /gemini review on PR #$PR_NUMBER via GitHub API." >&2
                echo "$RESPONSE" | jq -r '.message // .' >&2
                exit 9
            fi
        else
            echo "open-pr.sh: neither gh CLI nor \$GITHUB_TOKEN available — cannot post /gemini review trigger." >&2
            echo "  PR is open (#$PR_NUMBER). Post '/gemini review' as a PR comment manually," >&2
            echo "  or set GEMINI_NOT_INSTALLED=\"true\" in .claude/sync-substitutions.json if Gemini is absent." >&2
            exit 9
        fi
    fi
fi

# ─── Transition linked issues to Staged on the project board ──────────────
# PR open = code-complete signal, entering CI/review pipeline. Reuses the
# branch-linked issue list already injected as Closes #N above. Helper
# fail-loud propagates: if PROJECT_ID is set but STAGED_ID is empty or the
# board misconfigured or scope missing, the script exits non-zero. The PR
# is already open at this point — re-run after fixing the cause; the
# transition is idempotent so re-running won't double-write.
if [ -n "$LINKED_ISSUES" ]; then
    for num in $LINKED_ISSUES; do
        move_issue_to_staged "$num"
    done
fi

echo "gitflow: PR open complete." >&2
