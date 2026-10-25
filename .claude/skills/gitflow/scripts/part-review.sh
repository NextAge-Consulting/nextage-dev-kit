#!/bin/bash
# part-review.sh <base-ref> — the new-part review gate for /commit and /ship-main.
#
# Every part added since <base-ref> — a .tsx under a `components/` folder outside
# `features/` and the vendored atoms, new in this change rather than moved — is reviewed by
# a headless Claude against the project's UI inventory: does a part that already exists
# draw this same kind of thing? A suspected duplicate fails the gate, and the human
# decides. Same thing: the new part folds into the existing one. Different: their reason
# goes on the new part's inventory line, where the next review reads it.
#
# The reviewer's input opens with the repository root, then the inventory, the block-type
# list, each new part's code and the path of every component source file — every .tsx
# under a `components/` folder outside node_modules, tests and stories. The inventory can
# be stale, so the reviewer reads the component source — Read, Grep and Glob only,
# pre-approved, the repository added with --add-dir — and reports a duplicate only of a
# component that exists in source. It runs from a temp dir with no settings sources, so
# no project CLAUDE.md or settings load, and reports nothing it is unsure of.
#
# Because the reviewer can read any component, a remembered pass is keyed on the path and
# content hash of every component source file as well as the input sent.
#
# Exit 0: no new part, or no duplicate. Exit 1: a suspected duplicate, or the gate could
# not run.
#
# PART_REVIEW_CLAUDE names the CLI to run (default `claude`); the suite points it at a stub.

set -uo pipefail

BASE="${1:-HEAD}"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: part review: not in a git repository." >&2; exit 1; }
CACHE_LIB="$(dirname "${BASH_SOURCE[0]}")/review-cache.sh"
if [ ! -f "$CACHE_LIB" ]; then
    echo "gitflow: the part review cannot run — review-cache.sh is missing beside it. Run /sync-dev-kit." >&2
    exit 1
fi
# shellcheck source=./review-cache.sh
source "$CACHE_LIB"
INVENTORY="$ROOT/.claude/rules/project/ui-inventory.md"
BLOCK_TYPES="$ROOT/.claude/skills/design-system/references/block-types.md"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A failing diff — a base that does not resolve — fails the gate rather than reading as
# "nothing added".
if ! (cd "$ROOT" && git diff -z -M --name-only --diff-filter=A "$BASE" -- '*.tsx' && git ls-files -z --others --exclude-standard -- '*.tsx') >"$WORK/added" 2>"$WORK/err" \
    || ! (cd "$ROOT" && git diff -z -M --name-only --diff-filter=D "$BASE" -- '*.tsx') >"$WORK/deleted" 2>>"$WORK/err"; then
    echo "gitflow: part review cannot list the added files (git diff against $BASE failed):" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

VENDORED=""
[ -f "$ROOT/.claude/sync-substitutions.json" ] && VENDORED=$(jq -r '.DESIGN_VENDORED_DIR // ""' "$ROOT/.claude/sync-substitutions.json" 2>/dev/null)
VENDORED="${VENDORED%/}"

DELETED_NAMES=$(tr '\0' '\n' <"$WORK/deleted" | sed 's#.*/##')

is_new_part() {
    local f="$1"
    case "$f" in
        *.test.tsx|*.spec.tsx|*.stories.tsx) return 1 ;;
        */features/*|features/*) return 1 ;;
        */components/*|components/*) ;;
        *) return 1 ;;
    esac
    if [ -n "$VENDORED" ]; then
        case "$f" in "$VENDORED"/*) return 1 ;; esac
    else
        case "$f" in */components/ui/*|components/ui/*) return 1 ;; esac
    fi
    # Moved, not new: an uncommitted move pairs with the deleted file of its name.
    printf '%s\n' "$DELETED_NAMES" | grep -qxF -- "${f##*/}" && return 1
    return 0
}

FILES=()
while IFS= read -r -d '' f; do
    [ -n "$f" ] && is_new_part "$f" && FILES+=("$f")
done < <(sort -zu "$WORK/added")

if [ ${#FILES[@]} -eq 0 ]; then
    echo "gitflow: part review: no new part added." >&2
    exit 0
fi

if [ ! -f "$INVENTORY" ]; then
    echo "gitflow: ${#FILES[@]} new part(s) added, and the part review needs .claude/rules/project/ui-inventory.md, which is missing." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

if [ "$(python3 -c 'print(1)' 2>/dev/null)" != "1" ]; then
    echo "gitflow: ${#FILES[@]} new part(s) added, and the part review needs a working python3, which is missing or not a real interpreter." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

CLAUDE_BIN="${PART_REVIEW_CLAUDE:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "gitflow: ${#FILES[@]} new part(s) added, and the part review needs the Claude Code CLI, which is not on PATH." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

# Every component source file the reviewer may read, by path, and by path and content hash
# for the pass cache.
if ! (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- '*.tsx') >"$WORK/all" 2>"$WORK/err" \
    || ! python3 - "$ROOT" "$WORK" 2>"$WORK/err" <<'PY'
import hashlib, os, re, sys
root, work = sys.argv[1], sys.argv[2]
with open(os.path.join(work, "all"), "rb") as fh:
    files = sorted({p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p})
found = [p for p in files
         if "components" in p.split("/")[:-1] and "node_modules" not in p.split("/")
         and not re.search(r"\.(test|spec|stories)\.tsx$", p) and os.path.isfile(os.path.join(root, p))]
with open(os.path.join(work, "components"), "w", encoding="utf-8") as out:
    out.write("".join(p + "\n" for p in found))
with open(os.path.join(work, "component-manifest"), "w", encoding="utf-8") as out:
    for p in found:
        with open(os.path.join(root, p), "rb") as fh:
            out.write("%s\t%s\n" % (p, hashlib.sha256(fh.read()).hexdigest()))
PY
then
    echo "gitflow: the part review cannot list the component source:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
COMPONENTS=$(wc -l <"$WORK/components" | tr -d ' ')

{
    echo "Repository root: $ROOT"
    echo
    echo "=== THE PROJECT'S UI INVENTORY ==="
    cat "$INVENTORY"
    if [ -f "$BLOCK_TYPES" ]; then
        echo
        echo "=== THE BLOCK-TYPE LIST ==="
        cat "$BLOCK_TYPES"
    fi
    for f in "${FILES[@]}"; do
        echo
        echo "=== NEW PART: $f ==="
        cat "$ROOT/$f"
    done
    echo
    echo "=== COMPONENT SOURCE FILES — read with the Read tool (paths relative to the repository root) ==="
    cat "$WORK/components"
} >"$WORK/input"

read -r -d '' SYSTEM <<'EOF'
You review new UI parts — reusable building blocks — added to an application. The input opens with the repository root. You are given the application's UI inventory (every part it lists, one line each, with what it is for and its block type), the list of block types, the code of each new part, and the path of every component source file in the repository. You can read the whole repository with Read, Grep and Glob, and nothing else; you change nothing.

For each new part, decide one thing: does a part that already exists draw this same kind of thing — the same block type, playing the same role — so that the new part is a second version of an existing one? Two parts of one type with genuinely different roles are not duplicates. An inventory line that records why a part differs from another of its type settles it: never report that pair.

The inventory can be stale: a part it lists may have been removed or changed, and a part in the source may be missing from it. Back every duplicate with the source: Grep for the existing part and Read its file, and report a duplicate only of a component that exists in source and draws what the new part draws. A part the inventory lists but no source file defines is never reported.

Report only clear duplicates. When unsure, do not report. No duplicate returns {"duplicates": []}.
For each duplicate give the new part's file, the existing part's name — as the inventory writes it, or as its source file exports it when the inventory does not list it — and one sentence on why they are the same thing.
EOF

SCHEMA='{"type":"object","properties":{"duplicates":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"existing":{"type":"string"},"why":{"type":"string"}},"required":["file","existing","why"]}}},"required":["duplicates"]}'

# The key covers the input sent and, since the reviewer can read any component, the path
# and content hash of every component source file: a part changed anywhere re-asks the
# review.
if cat "$WORK/input" "$WORK/component-manifest" >"$WORK/keyed" 2>/dev/null \
    && CACHE_KEY=$(review_cache_key "$WORK" "${BASH_SOURCE[0]}" "$SYSTEM" "$SCHEMA" "$WORK/keyed"); then
    :
else
    CACHE_KEY=""
fi
if review_cache_hit "$ROOT" part-review "$CACHE_KEY"; then
    echo "gitflow: part review — reusing the earlier pass: the same ${#FILES[@]} new part(s), the same inventory and the same component source, unchanged since it was reviewed." >&2
    exit 0
fi

echo "gitflow: reviewing ${#FILES[@]} new part(s) against the parts that already exist..." >&2

# Runs from $WORK, so no project CLAUDE.md or settings load; the repository is reachable
# only through --add-dir, and only by the three read-only tools, pre-approved.
OUT=$(cd "$WORK" && "$CLAUDE_BIN" -p \
    --model sonnet --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" --add-dir "$ROOT" \
    --system-prompt "$SYSTEM" --json-schema "$SCHEMA" \
    --output-format json --no-session-persistence --disable-slash-commands \
    --strict-mcp-config --setting-sources "" <"$WORK/input" 2>"$WORK/err")
STATUS=$?

REPORT=$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("is_error"):
        raise ValueError
    dups = d["structured_output"]["duplicates"]
except Exception:
    print("ERROR"); sys.exit(0)
print("PARSED")
for x in dups:
    print("  " + x["file"] + " — already drawn by " + x["existing"])
    print("    " + x["why"].strip())
' 2>/dev/null)

if [ "$STATUS" -ne 0 ] || [ "$(printf '%s\n' "$REPORT" | head -1)" != "PARSED" ]; then
    echo "gitflow: the part review could not run (claude exited $STATUS)." >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

REPORT=$(printf '%s\n' "$REPORT" | sed '1d')
if [ -n "$REPORT" ]; then
    echo "gitflow: part review — a new part may duplicate one that already exists:" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  Ask the human whether each is the same thing as the existing part." >&2
    echo "  Same: use the existing part and remove the new one. Different: write the human's reason on the new part's inventory line." >&2
    echo "  Then commit again." >&2
    exit 1
fi

review_cache_store "$ROOT" part-review "$CACHE_KEY"
echo "gitflow: part review clean — ${#FILES[@]} new part(s) reviewed against $COMPONENTS component source file(s)." >&2
exit 0
