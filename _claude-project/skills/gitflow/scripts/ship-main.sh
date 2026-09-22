#!/bin/bash
# gitflow ship-main: direct conventional commit straight to main — no branch,
# no PR, no CI. THE CONSCIOUS EXCEPTION for quick infra / emergency work.
#
# Usage: ship-main.sh --message "<conventional message>" [--model "<name>"] [--skip-typecheck]
#
# How it differs from /commit: default /commit on main AUTO-CREATES a feature
# branch (the safety for accidental-on-main). /ship-main does the opposite ON
# PURPOSE — it commits on main and pushes directly. You only get here by
# explicitly asking ("ship to main", "infra commit",
# "emergency to main"); it is NEVER inferred from being on main.
#
# Guardrails:
#   - Refuses unless on main/master (a body of work in progress is on its own
#     branch, so it can't trip this by accident).
#   - Runs the same typecheck + biome lint as /commit (the assist worth keeping);
#     --skip-typecheck for a true emergency.
#   - Commits with a CONVENTIONAL message so the next /deploy classifies it for
#     bump-level + changelog exactly like a merged-PR squash commit.
#   - Pushes straight to main; rebases the commit onto origin/main if it advanced.
#
# Requires main to NOT require a PR — the default; the pipeline uses no branch
# protection (see pipeline.md §1.1). A direct push to main triggers NO workflows
# (CI is pull_request-only; deploys are workflow_dispatch-only), so it lands
# silently and instantly. CI is intentionally skipped — this is the exception
# path; the local typecheck above is the safety net.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./branch_helpers.sh
source "$SCRIPT_DIR/branch_helpers.sh"
# shellcheck source=./issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

MESSAGE=""
MODEL_NAME="Claude"
SKIP_TYPECHECK=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --message)         MESSAGE="$2"; shift 2 ;;
        --model)           MODEL_NAME="$2"; shift 2 ;;
        --skip-typecheck)  SKIP_TYPECHECK=1; shift 1 ;;
        *) echo "ship-main.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MESSAGE" ]; then
    echo "ship-main.sh: --message is required" >&2
    exit 2
fi

# --- Guardrail: must be on main/master ------------------------------------
CURRENT_BRANCH=$(git branch --show-current)
if ! is_protected_branch "$CURRENT_BRANCH"; then
    echo "ship-main.sh: refusing — /ship-main only runs on main (you are on '$CURRENT_BRANCH')." >&2
    echo "  /ship-main is the deliberate direct-to-main exception for infra/emergency work." >&2
    echo "  For feature work on a branch, use /commit." >&2
    exit 3
fi

# --- Validation (the assist that stays; --skip-typecheck for emergencies) --
if [ "$SKIP_TYPECHECK" -eq 0 ]; then
    if [ -f "package.json" ] && grep -q '"check-types"' package.json 2>/dev/null; then
        echo "gitflow: running npm run check-types..." >&2
        if ! npm run check-types >/dev/null 2>&1; then
            echo "" >&2
            echo "gitflow: TypeScript errors detected. Fix before shipping to main (or --skip-typecheck for a true emergency)." >&2
            echo "  Run: npm run check-types" >&2
            exit 4
        fi
    elif [ -f "pyproject.toml" ]; then
        if command -v pyright >/dev/null 2>&1; then
            echo "gitflow: running pyright..." >&2
            if ! pyright >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before shipping (run: pyright), or --skip-typecheck." >&2
                exit 4
            fi
        elif command -v mypy >/dev/null 2>&1; then
            echo "gitflow: running mypy..." >&2
            if ! mypy . >/dev/null 2>&1; then
                echo "gitflow: Python type errors. Fix before shipping (run: mypy .), or --skip-typecheck." >&2
                exit 4
            fi
        fi
    fi
fi

# ALWAYS `@biomejs/biome`, NEVER a bare `biome`, and always `--no-install` —
# see the note on the same gate in commit.sh. A bare `npx biome` runs an
# unrelated package that exits 0, so this gate passed without linting.
if [ -f "biome.json" ] || [ -f "biome.jsonc" ]; then
    echo "gitflow: running biome lint..." >&2
    if ! npx --no-install @biomejs/biome --version >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: biome.json is present but @biomejs/biome is not installed." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: npm i -D @biomejs/biome@<the version biome.json's \$schema names>" >&2
        exit 4
    fi
    if ! npx --no-install @biomejs/biome lint >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: Biome lint errors detected. Fix before shipping to main." >&2
        echo "  Run: npx --no-install @biomejs/biome lint" >&2
        exit 4
    fi
fi

# Semgrep (mirrors the CI `semgrep` job), scoped to the files this commit touches.
# Identical in intent and shape to the gate in commit.sh — read the long note
# there for why it is scoped to changed files and why a missing semgrep fails.
#
# It matters MORE here than on the /commit path, not less: this commits straight
# to main, so a finding that slips through does not sit on a branch waiting for
# review — it lands on the default branch and breaks CI for everyone. That
# `/sync-dev-kit` recommends /ship-main for landing kit updates is exactly the
# route by which an unscanned change would arrive there.
if [ -f ".github/workflows/ci.yml" ] && grep -qE '^[[:space:]]*semgrep:[[:space:]]*$' .github/workflows/ci.yml 2>/dev/null; then
    if ! command -v semgrep >/dev/null 2>&1; then
        echo "" >&2
        echo "gitflow: CI runs semgrep, but semgrep is not installed here." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        echo "  Fix: brew install semgrep   (or: pipx install semgrep)" >&2
        exit 4
    fi

    # Tracked modifications plus untracked additions, minus deletions. `mapfile`
    # is deliberately not used: macOS ships bash 3.2 as /bin/bash and does not
    # have it, so this script would die on the shebang platform it most often
    # runs on.
    SEMGREP_FILES=()
    while IFS= read -r semgrep_f; do
        [ -n "$semgrep_f" ] && [ -f "$semgrep_f" ] && SEMGREP_FILES+=("$semgrep_f")
    done < <(
        {
            git diff --name-only --diff-filter=d HEAD 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | sort -u
    )

    if [ ${#SEMGREP_FILES[@]} -gt 0 ]; then
        echo "gitflow: running semgrep on ${#SEMGREP_FILES[@]} changed file(s)..." >&2
        # Output is captured and REPLAYED on failure rather than suppressed with
        # a "run it yourself" hint. A semgrep scan is tens of seconds; telling
        # the user to pay that twice to find out what was wrong is the kind of
        # small tax that gets a gate disabled.
        if ! SEMGREP_OUT=$(semgrep scan --config auto --error "${SEMGREP_FILES[@]}" 2>&1); then
            echo "" >&2
            echo "gitflow: Semgrep findings in the files this commit touches. Fix before shipping to main." >&2
            echo "" >&2
            printf '%s\n' "$SEMGREP_OUT" >&2
            exit 4
        fi
    fi
fi

# --- Stage + commit directly on main --------------------------------------
git add -A
if git diff --cached --quiet; then
    echo "gitflow: nothing to commit." >&2
    exit 5
fi

# --- Close any linked issues via the commit itself -------------------------
# /work <issue#> parks its link here rather than cutting a branch, so ship-main
# is the path that consumes it. GitHub honours a `Closes #N` keyword in a commit
# pushed to the default branch, so the issue closes with no PR involved. Board
# status is deliberately left alone, matching /merge, which also does not
# transition — only /deploy marks Done.
SHIP_LINKED_ISSUES=$(read_branch_linked_issues "$CURRENT_BRANCH")
SHIP_CLOSES_LINE=$(closes_line_for_issues "$SHIP_LINKED_ISSUES")
if [ -n "$SHIP_CLOSES_LINE" ]; then
    MESSAGE="$MESSAGE

$SHIP_CLOSES_LINE"
    echo "gitflow: adding '$SHIP_CLOSES_LINE' from branch-linked issues." >&2
fi

echo "gitflow: ship-main — committing directly on $CURRENT_BRANCH: $MESSAGE" >&2
git commit --no-verify -m "$MESSAGE

Co-Authored-By: $MODEL_NAME <noreply@anthropic.com>"

# --- Push to main; rebase onto origin/main if it advanced -----------------
PUSH_ERR=$(mktemp)
if git push origin "$CURRENT_BRANCH" 2>"$PUSH_ERR"; then
    rm -f "$PUSH_ERR"
    echo "gitflow: pushed directly to $CURRENT_BRANCH." >&2
else
    if grep -qiE "non-fast-forward|fetch first|behind|rejected" "$PUSH_ERR"; then
        rm -f "$PUSH_ERR"
        echo "gitflow: origin/$CURRENT_BRANCH advanced — rebasing the ship-main commit onto it..." >&2
        if ! git pull --rebase origin "$CURRENT_BRANCH" >&2; then
            echo "ship-main.sh: rebase hit conflicts. Resolve them, then: git push origin $CURRENT_BRANCH" >&2
            exit 6
        fi
        if ! git push origin "$CURRENT_BRANCH" >&2; then
            echo "ship-main.sh: push failed after rebase — resolve manually." >&2
            exit 6
        fi
        echo "gitflow: pushed directly to $CURRENT_BRANCH (after rebase)." >&2
    else
        cat "$PUSH_ERR" >&2
        rm -f "$PUSH_ERR"
        echo "ship-main.sh: push to $CURRENT_BRANCH failed (see above)." >&2
        exit 6
    fi
fi

# Consumed: the Closes keyword now sits on a commit on the default branch, so
# GitHub will close the issue. Clearing stops it re-attaching to unrelated later
# work. Placed after BOTH push paths — every failing path above exits, so
# reaching here means the push landed. Written as `if`, not `[ … ] && …`: under
# `set -e` a false test as the last statement of the block aborts the script
# (bash-rules.md §III).
if [ -n "$SHIP_CLOSES_LINE" ]; then
    clear_branch_linked_issues "$CURRENT_BRANCH"
fi

echo "gitflow: ship-main complete — live on $CURRENT_BRANCH. (No PR, no CI — it's an exception commit.)" >&2
