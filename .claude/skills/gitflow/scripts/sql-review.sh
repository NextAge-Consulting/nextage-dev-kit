#!/bin/bash
# sql-review.sh <base-ref> — the SQL review gate for /commit and /ship-main.
#
# Every Drizzle `sql` template on a line changed since <base-ref> — committed checkpoints,
# the working tree and untracked files alike — is reviewed by a headless Claude for a table
# or column typed as text where the schema's object belongs (drizzle.md §I). The templates
# come from scripts/check-integration-coverage.mjs --sql-templates, which reads the source
# with TypeScript, so only a real `sql` tag from drizzle-orm is sent. Too many names in SQL
# are not schema names — aliases, CTEs, functions — for a pattern to decide it, so a
# reviewer does.
#
# The reviewer's input opens with the repository root, then inlines, in this order until
# MAX_BYTES is spent: each changed template, headed by its file and line; the project's
# drizzle configs; and its Drizzle schema files. The schema files are found by content —
# every TypeScript or JavaScript file outside node_modules that defines a table with a
# Drizzle table function (`pgTable(`, `mssqlTable(`, `someSchema.table("…"` and the rest)
# — not from a config's `schema`, because tables pulled only for queries sit outside every
# config (drizzle.md §III). Whatever does not fit is listed by path under "NOT INLINED —
# read with the Read tool"; no change is too big to review. The reviewer can read the
# repository — Read, Grep and Glob only, pre-approved, the repository added with
# --add-dir — and reports a name only once the schema confirms it is a table or column.
# It runs from a temp dir with no settings sources, so no project CLAUDE.md or settings
# load, and reports nothing it is unsure of. A finding fails the gate, and the developer
# decides each one: fix it, or commit anyway with SKIP_SQL_REVIEW=1.
#
# Because the reviewer can read any schema file, a remembered pass is keyed on the path
# and content hash of every drizzle config and schema file as well as the input sent.
#
# Exit 0: nothing to review, does not apply, or clean. Exit 1: findings, or the gate could
# not run. Local only — CI does not run it.
#
# SQL_REVIEW_CLAUDE names the CLI to run (default `claude`); SQL_REVIEW_LISTER names the
# command that prints the templates (default: node on the coverage check);
# SQL_REVIEW_MAX_BYTES the inline budget (default 300000). The suite sets all three.

set -uo pipefail

BASE="${1:-HEAD}"
MAX_BYTES="${SQL_REVIEW_MAX_BYTES:-300000}"

if [ "${SKIP_SQL_REVIEW:-}" = "1" ]; then
    echo "gitflow: SQL review skipped (SKIP_SQL_REVIEW=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: SQL review: not in a git repository." >&2; exit 1; }
CACHE_LIB="$(dirname "${BASH_SOURCE[0]}")/review-cache.sh"
if [ ! -f "$CACHE_LIB" ]; then
    echo "gitflow: the SQL review cannot run — review-cache.sh is missing beside it. Run /sync-dev-kit." >&2
    exit 1
fi
# shellcheck source=./review-cache.sh
source "$CACHE_LIB"

# Drizzle in use: a package.json outside node_modules declares drizzle-orm.
uses_drizzle() {
    local f
    while IFS= read -r f; do
        case "$f" in node_modules/*|*/node_modules/*) continue ;; esac
        jq -e '[.dependencies, .devDependencies, .peerDependencies] | map(. // {} | has("drizzle-orm")) | any' "$ROOT/$f" >/dev/null 2>&1 && return 0
    done < <(cd "$ROOT" && git ls-files --cached --others --exclude-standard -- 'package.json' '*/package.json')
    return 1
}
if ! uses_drizzle; then
    echo "gitflow: SQL review does not apply: no package.json declares drizzle-orm." >&2
    exit 0
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if [ -n "${SQL_REVIEW_LISTER:-}" ]; then
    LISTER=("$SQL_REVIEW_LISTER")
else
    if [ ! -f "$ROOT/scripts/check-integration-coverage.mjs" ]; then
        echo "gitflow: the SQL review needs scripts/check-integration-coverage.mjs, which is missing. Run /sync-dev-kit." >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        exit 1
    fi
    LISTER=(node "$ROOT/scripts/check-integration-coverage.mjs")
fi
if ! TEMPLATES=$(cd "$ROOT" && "${LISTER[@]}" --sql-templates --base "$BASE" 2>"$WORK/err") \
    || ! COUNT=$(printf '%s' "$TEMPLATES" | jq 'if type == "array" then length else error("not a list") end' 2>/dev/null); then
    echo "gitflow: the SQL review cannot list the changed sql templates:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
if [ "$COUNT" -eq 0 ]; then
    echo "gitflow: SQL review: no sql template changed." >&2
    exit 0
fi

# The reviewer's answer is parsed by python3. Without a working one every answer would
# read as "no findings" — so a missing python3 fails here, before the review is paid for.
if [ "$(python3 -c 'print(1)' 2>/dev/null)" != "1" ]; then
    echo "gitflow: $COUNT sql template(s) changed, and the SQL review needs a working python3, which is missing or not a real interpreter." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

CLAUDE_BIN="${SQL_REVIEW_CLAUDE:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "gitflow: $COUNT sql template(s) changed, and the SQL review needs the Claude Code CLI, which is not on PATH." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

printf '%s' "$TEMPLATES" >"$WORK/templates.json"

# Every TypeScript, JavaScript and JSON file in the repository, to find the schema and the
# drizzle configs in.
if ! (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.mjs' '*.cjs' '*.json') >"$WORK/all" 2>"$WORK/err"; then
    echo "gitflow: the SQL review cannot list the repository's files:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

# Builds the reviewer's input, and the schema manifest the pass cache keys on. Its output
# is "<templates inlined> <schema files found> <configs and schema files inlined> <listed>".
python3 - "$ROOT" "$WORK" "$MAX_BYTES" >"$WORK/stats" 2>"$WORK/err" <<'PY'
import hashlib, json, os, re, sys

root, work, cap = sys.argv[1], sys.argv[2], int(sys.argv[3])

with open(os.path.join(work, "templates.json"), encoding="utf-8") as fh:
    templates = json.load(fh)
with open(os.path.join(work, "all"), "rb") as fh:
    files = sorted({p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p})

def read(path):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()

CONFIG = re.compile(r"^drizzle(\.[\w-]+)?\.config\.(ts|mts|cts|js|mjs|cjs|json)$")
TABLE = re.compile(r"\b(?:pg|mysql|sqlite|mssql|singlestore|gel)(?:Table|View|MaterializedView)\s*(?:<[^>]*>)?\s*\(|\.(?:table|view|materializedView)\s*\(\s*[\"'`]")

configs, schema = [], []
for p in files:
    parts = p.split("/")
    if "node_modules" in parts or p.endswith(".d.ts") or not os.path.isfile(os.path.join(root, p)):
        continue
    if CONFIG.match(parts[-1]):
        configs.append(p)
    elif not p.endswith(".json") and not re.search(r"\.(test|spec)\.[cm]?[jt]sx?$", p) and TABLE.search(read(p)):
        schema.append(p)

# Inlined in priority order — the templates, the configs, the schema files — while the
# budget lasts. A block that does not fit is listed for the reviewer to read, and a
# smaller one after it may still be inlined.
candidates = []  # (group, block, listed-label)
for t in templates:
    candidates.append(("template", "=== CHANGED SQL TEMPLATE: %s:%s ===\n%s\n" % (t["file"], t["line"], t["text"]),
        "%s:%s (changed sql template — read it at that line)" % (t["file"], t["line"])))
for p in configs:
    candidates.append(("reference", "=== DRIZZLE CONFIG: %s ===\n%s\n" % (p, read(p).rstrip("\n")), "%s (drizzle config)" % p))
for p in schema:
    candidates.append(("reference", "=== DRIZZLE SCHEMA FILE: %s ===\n%s\n" % (p, read(p).rstrip("\n")), "%s (Drizzle schema file)" % p))

inlined, listed, counts, budget = [], [], {"template": 0, "reference": 0}, cap
for group, block, label in candidates:
    n = len(block.encode("utf-8"))
    if n <= budget:
        inlined.append(block); budget -= n; counts[group] += 1
    else:
        listed.append(label)

with open(os.path.join(work, "input"), "w", encoding="utf-8") as out:
    out.write("Repository root: %s\n" % root)
    if not schema:
        out.write("Scanning for Drizzle table functions found no schema file; search the repository with Grep before judging any name.\n")
    out.write("\n" + "\n".join(inlined))
    if listed:
        out.write("\n=== NOT INLINED — read with the Read tool (paths relative to the repository root) ===\n")
        out.write("\n".join(listed) + "\n")
with open(os.path.join(work, "listed"), "w", encoding="utf-8") as out:
    out.write("".join("  " + l + "\n" for l in listed))

# Every config and schema file the reviewer could read, by path and content hash, for the
# pass cache.
with open(os.path.join(work, "schema-manifest"), "w", encoding="utf-8") as out:
    for p in configs + schema:
        with open(os.path.join(root, p), "rb") as fh:
            out.write("%s\t%s\n" % (p, hashlib.sha256(fh.read()).hexdigest()))
print("%d %d %d %d" % (counts["template"], len(schema), counts["reference"], len(listed)))
PY
BUILD=$?

if [ "$BUILD" -ne 0 ] || ! read -r IN_TEMPLATES SCHEMA_FILES IN_REFS LISTED <"$WORK/stats"; then
    echo "gitflow: the SQL review cannot read the changed templates or the schema:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
SENT="$COUNT sql template(s) against $SCHEMA_FILES Drizzle schema file(s)"
if [ "$LISTED" -gt 0 ]; then
    SENT="$SENT; inlined $IN_TEMPLATES template(s) and $IN_REFS config or schema file(s); $LISTED file(s) over the $MAX_BYTES-byte inline budget listed for the reviewer to read"
fi

read -r -d '' SYSTEM <<'EOF'
You review Drizzle ORM `sql` tagged templates from a TypeScript codebase. The input opens with the repository root. It inlines, as far as its size allows, each changed template headed by its file and line, then the project's drizzle configs and the files that define its Drizzle tables. Anything that did not fit is listed under "NOT INLINED", by path relative to the repository root: read every file listed there with the Read tool before judging. You can read the whole repository with Read, Grep and Glob, and nothing else; you change nothing.

Inside a template, `${…}` interpolates a TypeScript value: a schema object such as `${invoice.total}` or `${invoice}` renders as the quoted column or table name and is checked by the compiler; any other `${…}` is a bound parameter.

Report a finding only for a clear case of a database TABLE or COLUMN name written as literal text in the template — `invoice.total`, `from invoice`, `where status = …` — where the schema's object belongs, because a rename would compile clean and break at runtime.

Before reporting a name, confirm the schema defines it. A table's database name is the first argument of its table function (`pgTable("invoice", …)`, `mssqlTable(…)`, `someSchema.table("invoice", …)`); a column's is the string given to its column builder, or its property key when none is given — in snake_case when a drizzle config sets `casing: "snake_case"`. When a name is in none of the schema files given, search the repository with Grep for it before deciding; a name no schema file defines is not reported.

Never report: SQL keywords, functions and types (`coalesce`, `now()`, `count(*)`, `::int`); aliases the template itself defines (`as total`, a CTE name, a subquery alias) and their uses; `excluded.` in an upsert; system catalogs and schemas (`information_schema`, `pg_catalog`, `sys.`); anything inside `${…}`; anything you are unsure is a table or column.

A clean set returns {"findings": []}.
For each finding give the file, the line, the exact text quoted, one sentence on what is wrong, and the fix as the template rewritten with the schema object interpolated under the name its schema file exports.
EOF

SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"quote":{"type":"string"},"finding":{"type":"string"},"fix":{"type":"string"}},"required":["file","line","quote","finding","fix"]}}},"required":["findings"]}'

# The key covers the input sent and, since the reviewer can read any schema file, the
# path and content hash of every drizzle config and schema file: a table or column renamed
# in the schema re-asks the review.
if cat "$WORK/input" "$WORK/schema-manifest" >"$WORK/keyed" 2>/dev/null \
    && CACHE_KEY=$(review_cache_key "$WORK" "${BASH_SOURCE[0]}" "$SYSTEM" "$SCHEMA" "$WORK/keyed"); then
    :
else
    CACHE_KEY=""
fi
if review_cache_hit "$ROOT" sql-review "$CACHE_KEY"; then
    echo "gitflow: SQL review — reusing the earlier pass: the same $COUNT sql template(s) and the same schema, unchanged since it was reviewed." >&2
    exit 0
fi

echo "gitflow: reviewing $COUNT changed sql template(s) for names typed as text..." >&2
if [ "$LISTED" -gt 0 ]; then
    echo "  over the $MAX_BYTES-byte inline budget, listed for the reviewer to read:" >&2
    cat "$WORK/listed" >&2
fi

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
    findings = d["structured_output"]["findings"]
except Exception:
    print("ERROR"); sys.exit(0)
print("PARSED")
for i, f in enumerate(findings, 1):
    print("  %d. %s:%s" % (i, f["file"], f["line"]))
    print("     \"" + f["quote"].strip() + "\"")
    print("     why: " + f["finding"].strip())
    print("     fix: " + f["fix"].strip())
' 2>/dev/null)

# The first line is PARSED only when python3 read a well-formed answer; anything else —
# ERROR, or nothing at all — is a review that did not happen.
if [ "$STATUS" -ne 0 ] || [ "$(printf '%s\n' "$REPORT" | head -1)" != "PARSED" ]; then
    echo "gitflow: the SQL review could not run (claude exited $STATUS)." >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

REPORT=$(printf '%s\n' "$REPORT" | sed '1d')
if [ -n "$REPORT" ]; then
    echo "gitflow: SQL review — a table or column is typed as text where the schema's object belongs (drizzle.md §I; $SENT):" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  Put each finding to the developer with the fix, and ask: fix it, or skip it." >&2
    echo "  Fix: make the change, then commit again. Skip all that remain: commit again with SKIP_SQL_REVIEW=1." >&2
    exit 1
fi

review_cache_store "$ROOT" sql-review "$CACHE_KEY"
echo "gitflow: SQL review clean — reviewed $SENT." >&2
exit 0
