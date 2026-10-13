#!/bin/bash
# design-review.sh <base-ref> — the design review gate for /commit and /ship-main.
#
# The lines added or changed since <base-ref> — committed checkpoints, the working tree
# and untracked files alike — in the project's UI source (.tsx under DESIGN_SOURCE_DIRS),
# its token, type and styles stylesheets, and design.md are reviewed by a headless Claude
# for the design judgements a pattern cannot make: a call site repainting a part, a
# screen drawing a frame a part owns, a role or size named by magnitude, an incomplete
# variant, design.md prose contradicting the roles. The token checker
# (check-design-tokens.mjs) decides the mechanical rules; the reviewer never repeats them.
#
# The reviewer sees only the numbered diff, the project's role list, its UI inventory,
# the block-type list and the kit's design opinions: no tools, no settings, no CLAUDE.md. It reports nothing it is
# unsure of. A finding fails the gate, and the developer decides each one: fix it, or
# commit anyway with SKIP_DESIGN_REVIEW=1.
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
# The checker ships beside this script: .claude/skills/gitflow/scripts → .claude/skills/design-system.
CHECKER="${DESIGN_REVIEW_CHECKER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/design-system/scripts/check-design-tokens.mjs}"
# The kit's design opinions ship beside the checker, in the design-system skill's references.
OPINIONS="$(dirname "$CHECKER")/../references/design-opinion.md"

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
read -r -a SOURCE_DIRS <<<"$(key DESIGN_SOURCE_DIRS)"
STYLESHEETS=()
for f in $(key DESIGN_TOKEN_FILES) $(key DESIGN_TYPE_FILE) $(key DESIGN_STYLES_FILE); do STYLESHEETS+=("$PREFIX$f"); done

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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
    echo "gitflow: design review: no UI source, stylesheet or design.md changed." >&2
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

if ! ROLES=$(node "$CHECKER" --roles --repo "$ROOT" 2>"$WORK/err"); then
    echo "gitflow: ${#FILES[@]} UI file(s) changed, and the design review cannot read the project's roles:" >&2
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
    echo "=== THE UI INVENTORY ==="
    if [ -f "$INVENTORY" ]; then cat "$INVENTORY"; else echo "(the project has no UI inventory yet)"; fi
    if [ -f "$BLOCK_TYPES" ]; then
        echo
        echo "=== THE BLOCK-TYPE LIST ==="
        cat "$BLOCK_TYPES"
    fi
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

read -r -d '' SYSTEM <<'EOF'
You review a diff of a business application's UI code and its design spec. The application has a design system: every visual value comes from a named ROLE (listed under "THE ROLES"), reusable building blocks are PARTS (listed under "THE UI INVENTORY", each with a block type), and screens are assembled from parts. A part is a .tsx file under a components/ folder outside features/; a screen is a route, or any file under features/. You are given the diff, the roles, the inventory, the block-type list and the kit's design opinions. Nothing else exists for you; do not assume a role or part that is not listed.

Judge ONLY the lines the diff adds — lines whose code starts with "+" (not the "+++" header). Each diff line is prefixed with its line number in the new file; report that number. Report only a clear case of one of these:

1. ROLE-NAME — a role added in a stylesheet (a --radius-*, --font-weight-*, --shadow-*, --spacing-*, --leading-*, --tracking-* token, or a type-* utility) whose name describes how big, heavy or wide it is rather than what element it is for: "small", "big", "large", "heavy", "base", "wide", "loose", "micro", "label" used as a size. A name that answers "which element or use is this for?" passes. T-shirt suffixes (sm, md, lg, xs, xl, 2xl) are already caught elsewhere — do not report them. Report a role once, where its value is defined — not again where an @theme block re-exports it as var() of itself.
2. CALL-SITE-REPAINT — where a SCREEN uses a part from the inventory (or a component imported from a components/ folder), its className changes how the part LOOKS — colour, background, border, radius, shadow, padding, type — instead of where it sits (margin, width, a bounded height, flex/grid slot, position, alignment, visibility). A class the part exists to receive — gap or columns on a layout part — is not a repaint. Several look-changing classes on one use usually mean a variant is missing; name the variant.
3. SCREEN-BOX — a screen draws by hand, with its own background, border, radius, shadow or padding, a frame that a block type in the list names — a dialog, panel, header, toolbar, card, notice, banner, button — instead of using that type's part. Name the block type and the inventory part (or say none exists yet).
4. SIZE-PROP — a component's size or variant prop value that names a magnitude ("small", "large", "compact" used as a size, "tiny", "big") rather than what the thing is. Literal sm/md/lg/xl are already caught elsewhere — do not report them.
5. VARIANT — inside a part: a variant left incomplete for callers to finish; a state (selected, active, disabled, read-only) of another part painted through its className instead of keyed inside that part's variant; or a look already exported by another part copied by hand. A part restyling another part is always VARIANT, never CALL-SITE-REPAINT.
6. DESIGN-PROSE — a sentence added to design.md that states a design value or rule contradicting THE ROLES (names a role that does not exist, or a value no role has).
7. DUPLICATE-ROLE — a role added in a stylesheet whose job a role already in THE ROLES does under another name. Name the existing role.
8. OPINION — an added role, token, part or design.md rule that contradicts THE KIT'S DESIGN OPINIONS — a side marked "(the kit's side)", or the shape every value family takes — with no comment on or beside that line giving the project's reason. Name the opinion it contradicts.

Never report:
- Anything a lint already decides: arbitrary values like text-[13px] or p-[10px], a class that is not a role, dark: variants, bare overflow-auto, an unresolved var(), a t-shirt-size name, a fixed height at a call site, a colour role painted on a part at a call site (text-primary on a Button), a faded colour (text-x/50).
- Text a screen styles from roles: a type role, a weight, a semantic text colour. Screens style their own text.
- Layout a screen writes: flex, grid, gap, alignment, margin, width, height bounds, space-*, overflow-hidden, container, order.
- Styling on table cells, list items, rows or dividers that are the content a screen lays out rather than a frame around it — padding on a <td>, a border-t between list items, divide-y on a list.
- Focus rings and outlines, skip links, sr-only content, and icons or glyphs coloured by their caller.
- Strings that are not class lists: import paths, URLs, logger names, SVG attributes, test ids, prop values that are not classes.
- Headless primitives (Radix triggers, anchors, collapsible parts), vendored atoms' own source, tests and stories.
- A px value in design.md prose that is a breakpoint, a device or viewport width, a hairline, or quoted as an example of what not to do.
- Lines the diff does not add, removed lines, naming taste beyond rule 1, and whether the design is good.

When unsure, do not report. A clean diff returns {"findings": []}.
For each finding give the file, the line number in the new file, the rule, the exact added text quoted, one sentence on what is wrong, a concrete fix (the role, part or variant to use or create), and your confidence: "high" only when the finding is unambiguous from the material given.
EOF

SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"rule":{"type":"string","enum":["ROLE-NAME","CALL-SITE-REPAINT","SCREEN-BOX","SIZE-PROP","VARIANT","DESIGN-PROSE","DUPLICATE-ROLE","OPINION"]},"quote":{"type":"string"},"finding":{"type":"string"},"fix":{"type":"string"},"confidence":{"type":"string","enum":["high","medium"]}},"required":["file","line","rule","quote","finding","fix","confidence"]}}},"required":["findings"]}'

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
