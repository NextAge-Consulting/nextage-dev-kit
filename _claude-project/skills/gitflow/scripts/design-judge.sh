#!/bin/bash
# design-judge.sh <base-ref> — the design judge, run by /commit and /ship-main.
#
# Code locates every candidate in the change since <base-ref> (the design-system skill's
# locate.mjs: a class added at a call site, a new block, a changed screen against the rules
# that govern it, …) and a cold judge answers one yes/no question per candidate
# (judge.mjs, references/judge-questions.md), three answers and the majority wins. Every
# yes is written to .claude/ui-pending.json as a pending item for the human's
# walk-through, which check-ui-status.mjs reads and /deploy refuses on. Nothing here
# stops a commit: the judge is advisory, and this script exits 0 once it has run, with
# yeses or without. A judge that cannot run says so and exits 0 too — it is advice, not a
# gate, and the status check still holds whatever the ledger already carries.
#
# A run over the same candidates as the last one is not asked again (review-cache.sh).
#
# JUDGE_CLAUDE names the CLI judge.mjs runs (default `claude`); the suite points it at a
# stub. SKIP_DESIGN_JUDGE=1 skips the run.

set -uo pipefail

BASE="${1:-HEAD}"

if [ "${SKIP_DESIGN_JUDGE:-}" = "1" ]; then
    echo "gitflow: design judge skipped (SKIP_DESIGN_JUDGE=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: design judge: not in a git repository." >&2; exit 0; }
CACHE_LIB="$(dirname "${BASH_SOURCE[0]}")/review-cache.sh"
SUBS="$ROOT/.claude/sync-substitutions.json"
# The design-system skill ships beside this script: .claude/skills/gitflow/scripts → .claude/skills/design-system.
SKILL="${DESIGN_JUDGE_SKILL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/design-system}"
LOCATE="$SKILL/scripts/locate.mjs"
JUDGE="$SKILL/scripts/judge.mjs"
LEDGER=".claude/ui-pending.json"

key() { jq -r --arg k "$1" '.[$k] // ""' "$SUBS" 2>/dev/null; }

if [ ! -f "$SUBS" ] || [ -z "$(key DESIGN_UI_PACKAGE)" ]; then
    echo "gitflow: design judge does not apply: this project has no UI package (DESIGN_UI_PACKAGE is empty)." >&2
    exit 0
fi
if [ ! -f "$LOCATE" ] || [ ! -f "$JUDGE" ]; then
    echo "gitflow: design judge does not apply: the design-system skill is not installed here." >&2
    exit 0
fi

advisory() {
    echo "gitflow: the design judge could not run — $1" >&2
    echo "  It is advice, not a gate: the commit goes ahead, and what the ledger already holds still waits for the human." >&2
    exit 0
}

command -v node >/dev/null 2>&1 || advisory "node is not installed."
JUDGE_BIN="${JUDGE_CLAUDE:-claude}"
command -v "$JUDGE_BIN" >/dev/null 2>&1 || advisory "the Claude Code CLI is not on PATH."

WORK=$(mktemp -d) || advisory "no temporary directory."
trap 'rm -rf "$WORK"' EXIT

if ! node "$LOCATE" --repo "$ROOT" --base "$BASE" >"$WORK/candidates" 2>"$WORK/err"; then
    sed 's/^/  /' "$WORK/err" >&2
    advisory "the locator failed (output above)."
fi
COUNT=$(grep -c . "$WORK/candidates" 2>/dev/null || true)
COUNT="${COUNT:-0}"
if [ "$COUNT" -eq 0 ]; then
    echo "gitflow: design judge: nothing in this change to judge." >&2
    exit 0
fi

CACHE_KEY=""
if [ -f "$CACHE_LIB" ]; then
    # shellcheck source=./review-cache.sh
    source "$CACHE_LIB"
    CACHE_KEY=$(review_cache_key "$WORK" "${BASH_SOURCE[0]}" "$(cat "$JUDGE")" "" "$WORK/candidates") || CACHE_KEY=""
    if review_cache_hit "$ROOT" design-judge "$CACHE_KEY"; then
        echo "gitflow: design judge — the same $COUNT candidate(s) as the last run, already judged; the ledger stands." >&2
        exit 0
    fi
fi

echo "gitflow: design judge — asking about $COUNT candidate(s) in this change..." >&2
if ! (cd "$ROOT" && JUDGE_CLAUDE="$JUDGE_BIN" node "$JUDGE" --candidates "$WORK/candidates" --ledger "$LEDGER" --repo "$ROOT") >"$WORK/out" 2>"$WORK/err"; then
    cat "$WORK/out" >&2
    sed 's/^/  /' "$WORK/err" >&2
    advisory "the judge failed (output above)."
fi
cat "$WORK/out" >&2
if grep -q '^  ✗' "$WORK/out"; then
    echo "  Each ✗ is a pending item in $LEDGER for the human's walk-through; /deploy waits for it. The commit goes ahead." >&2
fi
[ -n "$CACHE_KEY" ] && [ -f "$CACHE_LIB" ] && review_cache_store "$ROOT" design-judge "$CACHE_KEY"
exit 0
