#!/bin/bash
# design-review.sh <base-ref> — the design review gate for /commit and /ship-main.
#
# The lines added or changed since <base-ref> — committed checkpoints, the working tree
# and untracked files alike — in the project's UI source (.tsx in the UI package and every
# workspace depending on it, found by the design-system skill's ui-sources.mjs), its
# token, type and styles stylesheets, design.md and its UI pattern references are reviewed
# by a headless Claude against the design checks (the design-system skill's
# references/design-checks.md) — the same checks /design-audit applies to everything.
# The token checker (check-design-tokens.mjs) decides the mechanical rules; the reviewer
# never repeats them.
#
# The reviewer sees only the numbered diff, the design checks, the project's roles and what
# each is for, its UI inventory, its patterns, the block-type list and the kit's design
# opinions: no tools, no settings, no CLAUDE.md. It reports nothing it is unsure of. A
# finding fails the gate, and the developer decides each one: fix it, mark the line
# design-accepted with a reason, or commit anyway with SKIP_DESIGN_REVIEW=1.
#
# Exit 0: nothing to review, does not apply, or clean. Exit 1: findings, or the gate could
# not run. Local only — CI does not run it.
#
# DESIGN_REVIEW_CLAUDE names the CLI to run (default `claude`); the suite points it at a stub.
# DESIGN_REVIEW_CHECKER names the token checker (default: the one beside this script); the
# suite points it at the kit's source where the design-system skill is not installed.

set -uo pipefail

BASE="${1:-HEAD}"

if [ "${SKIP_DESIGN_REVIEW:-}" = "1" ]; then
    echo "gitflow: design review skipped (SKIP_DESIGN_REVIEW=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: design review: not in a git repository." >&2; exit 1; }
SUBS="$ROOT/.claude/sync-substitutions.json"
INVENTORY="$ROOT/.claude/rules/project/ui-inventory.md"
BLOCK_TYPES="$ROOT/.claude/skills/design-system/references/block-types.md"
PATTERNS_DIR=".claude/skills/ui-patterns/references"
# The checker ships beside this script: .claude/skills/gitflow/scripts → .claude/skills/design-system.
CHECKER="${DESIGN_REVIEW_CHECKER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/design-system/scripts/check-design-tokens.mjs}"
# The kit's design opinions and the design checks ship beside the checker, in the
# design-system skill's references.
OPINIONS="$(dirname "$CHECKER")/../references/design-opinion.md"
CHECKS="$(dirname "$CHECKER")/../references/design-checks.md"

key() { jq -r --arg k "$1" '.[$k] // ""' "$SUBS" 2>/dev/null; }

if [ ! -f "$SUBS" ] || [ -z "$(key DESIGN_UI_PACKAGE)" ]; then
    echo "gitflow: design review does not apply: this project has no UI package (DESIGN_UI_PACKAGE is empty)." >&2
    exit 0
fi
if [ ! -f "$ROOT/design.md" ]; then
    echo "gitflow: design review does not apply: there is no design.md at the repository root." >&2
    exit 0
fi

PKG=$(key DESIGN_UI_PACKAGE); PKG="${PKG%/}"
# A UI package at the repository root ("." or "./") prefixes nothing: git lists `src/x`, not `./src/x`.
case "$PKG" in .|./) PREFIX="" ;; *) PREFIX="$PKG/" ;; esac
VENDORED=$(key DESIGN_VENDORED_DIR); VENDORED="${VENDORED%/}"
RESTYLED=$(key DESIGN_VENDORED_RESTYLED)
STYLESHEETS=()
for f in $(key DESIGN_TOKEN_FILES) $(key DESIGN_TYPE_FILE) $(key DESIGN_STYLES_FILE); do STYLESHEETS+=("$PREFIX$f"); done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The folders come from the workspace graph, never a list: an app added to the repository
# is reviewed from its first commit. A discovery that fails cannot say what to review.
if ! SOURCE_LIST=$(node "$(dirname "$CHECKER")/ui-sources.mjs" --repo "$ROOT" 2>"$WORK/err"); then
    echo "gitflow: design review cannot find the project's UI source:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
SOURCE_DIRS=()
while IFS= read -r d; do [ -n "$d" ] && SOURCE_DIRS+=("$d"); done <<<"$SOURCE_LIST"

# NUL-separated, so a path git would quote is read as itself. A failing diff — a base
# that does not resolve — fails the gate rather than reading as "nothing changed".
if ! (cd "$ROOT" && git diff -z --name-only --diff-filter=d "$BASE" && git ls-files -z --others --exclude-standard) >"$WORK/changed" 2>"$WORK/err"; then
    echo "gitflow: design review cannot list the changed files (git diff against $BASE failed):" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

is_reviewed() {
    local f="$1" d s
    [ "$f" = "design.md" ] && return 0
    case "$f" in
        "$PATTERNS_DIR"/README.md) return 1 ;;
        "$PATTERNS_DIR"/*.md) return 0 ;;
    esac
    for s in ${STYLESHEETS[@]+"${STYLESHEETS[@]}"}; do [ "$f" = "$s" ] && return 0; done
    case "$f" in
        *.test.tsx|*.spec.tsx|*.stories.tsx) return 1 ;;
        *.tsx) ;;
        *) return 1 ;;
    esac
    if [ -n "$VENDORED" ] && [ "$RESTYLED" != "true" ]; then
        case "$f" in "$VENDORED"/*) return 1 ;; esac
    fi
    for d in ${SOURCE_DIRS[@]+"${SOURCE_DIRS[@]}"}; do
        d="${d%/}"
        case "$d" in .|"") return 0 ;; esac
        case "$f" in "$d"/*) return 0 ;; esac
    done
    return 1
}

FILES=()
while IFS= read -r -d '' f; do
    [ -n "$f" ] && is_reviewed "$f" && FILES+=("$f")
done < <(sort -zu "$WORK/changed")

if [ ${#FILES[@]} -eq 0 ]; then
    echo "gitflow: design review: no UI source, stylesheet, pattern or design.md changed." >&2
    exit 0
fi

# The reviewer's answer is parsed by python3. Without a working one every answer would
# read as "no findings" — so a missing python3 fails here, before the review is paid for.
if [ "$(python3 -c 'print(1)' 2>/dev/null)" != "1" ]; then
    echo "gitflow: ${#FILES[@]} UI file(s) changed, and the design review needs a working python3, which is missing or not a real interpreter." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

CLAUDE_BIN="${DESIGN_REVIEW_CLAUDE:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "gitflow: ${#FILES[@]} UI file(s) changed, and the design review needs the Claude Code CLI, which is not on PATH." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

if ! ROLES=$(node "$CHECKER" --roles --repo "$ROOT" 2>"$WORK/err") \
    || ! PURPOSES=$(node "$CHECKER" --purposes --repo "$ROOT" 2>"$WORK/err"); then
    echo "gitflow: ${#FILES[@]} UI file(s) changed, and the design review cannot read the project's roles:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
# The checks a review of one change can judge: every one not marked *Whole layer*.
if [ ! -f "$CHECKS" ] || ! CHECK_NAMES=$(node "$(dirname "$CHECKER")/design-checks.mjs" --names --review 2>"$WORK/err"); then
    echo "gitflow: ${#FILES[@]} UI file(s) changed, and the design review cannot read the design checks:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

: >"$WORK/raw"
for f in "${FILES[@]}"; do
    if (cd "$ROOT" && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1); then
        (cd "$ROOT" && git diff -U8 "$BASE" -- "$f") >>"$WORK/raw" 2>"$WORK/err"; rc=$?
    else
        # --no-index exits 1 when the files differ, which a new file always does.
        (cd "$ROOT" && git diff -U8 --no-index -- /dev/null "$f") >>"$WORK/raw" 2>"$WORK/err"; rc=$?
        [ "$rc" -eq 1 ] && rc=0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "gitflow: design review cannot diff $f against $BASE:" >&2
        sed 's/^/  /' "$WORK/err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        exit 1
    fi
done

# Each diff line carries its line number in the new file, so a finding names the right line.
python3 -c '
import re, sys
n = None
for line in sys.stdin.read().split("\n"):
    m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)", line)
    if m:
        n = int(m.group(1)); print(line); continue
    if n is None or line.startswith(("+++", "---", "diff ", "index ", "new file", "deleted file", "similarity", "rename ")):
        print(line); continue
    if line.startswith("-"):
        print("      " + line); continue
    if line.startswith(("+", " ")):
        print("%5d %s" % (n, line)); n += 1; continue
    print(line)
' <"$WORK/raw" >"$WORK/diff"

{
    echo "=== THE ROLES ==="
    printf '%s\n' "$ROLES"
    echo
    echo "=== WHAT EACH ROLE IS FOR ==="
    printf '%s\n' "$PURPOSES"
    echo
    echo "=== THE UI INVENTORY ==="
    if [ -f "$INVENTORY" ]; then cat "$INVENTORY"; else echo "(the project has no UI inventory yet)"; fi
    if [ -f "$BLOCK_TYPES" ]; then
        echo
        echo "=== THE BLOCK-TYPE LIST ==="
        cat "$BLOCK_TYPES"
    fi
    echo
    echo "=== THE PATTERNS ==="
    found=0
    for ref in "$ROOT/$PATTERNS_DIR"/*.md; do
        [ -f "$ref" ] && [ "$(basename "$ref")" != "README.md" ] || continue
        found=1
        echo "--- ${ref#"$ROOT"/} ---"
        cat "$ref"
    done
    [ "$found" -eq 1 ] || echo "(the project has no pattern references yet)"
    if [ -f "$OPINIONS" ]; then
        echo
        echo "=== THE KIT'S DESIGN OPINIONS ==="
        cat "$OPINIONS"
    fi
    echo
    echo "=== THE DIFF (each line numbered as it is in the new file) ==="
    cat "$WORK/diff"
} >"$WORK/input"

echo "gitflow: reviewing ${#FILES[@]} UI file(s) against the design system..." >&2

read -r -d '' PREAMBLE <<'EOF'
You review one change to a business application's UI: its stylesheets, design.md, parts, UI pattern references and screens. Apply the design checks below to the lines the diff adds and to nothing else — lines whose code starts with "+" (not the "+++" header). Each diff line is prefixed with its line number in the new file; report that number. Judge each changed file at its own layer, held to the material for the layers beneath it: the roles and what each is for, the UI inventory, the patterns, the block-type list and the kit's design opinions. Nothing else exists for you; do not assume a role, part or pattern that is not given. Leave out every check marked *Whole layer*. Report each finding under its check's name as the rule. A clean diff returns {"findings": []}.
For each finding give the file, the line number in the new file, the rule, the exact added text quoted, one sentence on what is wrong, a concrete fix, and your confidence: "high" only when the finding is unambiguous from the material given.
EOF
SYSTEM="$PREAMBLE

$(cat "$CHECKS")"

RULES=$(printf '%s\n' "$CHECK_NAMES" | jq -R -s -c '[split("\n")[] | select(. != "")]')
SCHEMA=$(jq -n -c --argjson rules "$RULES" '{type: "object", properties: {findings: {type: "array", items: {type: "object", properties: {file: {type: "string"}, line: {type: "integer"}, rule: {type: "string", enum: $rules}, quote: {type: "string"}, finding: {type: "string"}, fix: {type: "string"}, confidence: {type: "string", enum: ["high", "medium"]}}, required: ["file", "line", "rule", "quote", "finding", "fix", "confidence"]}}}, required: ["findings"]}')

OUT=$(cd "$WORK" && "$CLAUDE_BIN" -p \
    --model sonnet --tools "" --system-prompt "$SYSTEM" --json-schema "$SCHEMA" \
    --output-format json --no-session-persistence --disable-slash-commands \
    --strict-mcp-config --setting-sources "" <"$WORK/input" 2>"$WORK/err")
STATUS=$?

REPORT=$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("is_error"):
        raise ValueError
    findings = d["structured_output"]["findings"]
except Exception:
    print("ERROR"); sys.exit(0)
print("PARSED")
for i, f in enumerate(findings, 1):
    print("  %d. %s:%s — %s (%s)" % (i, f["file"], f["line"], f["rule"], f["confidence"]))
    print("     \"" + f["quote"].strip() + "\"")
    print("     why: " + f["finding"].strip())
    print("     fix: " + f["fix"].strip())
' 2>/dev/null)

# The first line is PARSED only when python3 read a well-formed answer; anything else —
# ERROR, or nothing at all — is a review that did not happen.
if [ "$STATUS" -ne 0 ] || [ "$(printf '%s\n' "$REPORT" | head -1)" != "PARSED" ]; then
    echo "gitflow: the design review could not run (claude exited $STATUS)." >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

REPORT=$(printf '%s\n' "$REPORT" | sed '1d')
if [ -n "$REPORT" ]; then
    echo "gitflow: design review — the change breaks the design system here:" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  Put each finding to the developer with why and the fix, and ask: fix it, or skip it." >&2
    echo "  Fix: make the change, then commit again. Skip all that remain: commit again with SKIP_DESIGN_REVIEW=1." >&2
    exit 1
fi

echo "gitflow: design review clean — ${#FILES[@]} UI file(s) reviewed." >&2
exit 0
