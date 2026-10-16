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
# The reviewer sees only the templates and the criteria below: no tools, no settings, no
# CLAUDE.md. It reports nothing it is unsure of. A finding fails the gate, and the developer
# decides each one: fix it, or commit anyway with SKIP_SQL_REVIEW=1.
#
# Exit 0: nothing to review, does not apply, or clean. Exit 1: findings, or the gate could
# not run. Local only — CI does not run it.
#
# SQL_REVIEW_CLAUDE names the CLI to run (default `claude`); SQL_REVIEW_LISTER names the
# command that prints the templates (default: node on the coverage check). The suite points
# both at stubs.

set -uo pipefail

BASE="${1:-HEAD}"

if [ "${SKIP_SQL_REVIEW:-}" = "1" ]; then
    echo "gitflow: SQL review skipped (SKIP_SQL_REVIEW=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: SQL review: not in a git repository." >&2; exit 1; }

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

printf '%s\n' "$TEMPLATES" | jq -r '.[] | "=== \(.file):\(.line) ===\n\(.text)\n"' >"$WORK/input"

echo "gitflow: reviewing $COUNT changed sql template(s) for names typed as text..." >&2

read -r -d '' SYSTEM <<'EOF'
You review Drizzle ORM `sql` tagged templates from a TypeScript codebase. Each is headed by its file and line. Inside a template, `${…}` interpolates a TypeScript value: a schema object such as `${invoice.total}` or `${invoice}` renders as the quoted column or table name and is checked by the compiler; any other `${…}` is a bound parameter.

Report a finding only for a clear case of a database TABLE or COLUMN name written as literal text in the template — `invoice.total`, `from invoice`, `where status = …` — where the schema's object belongs, because a rename would compile clean and break at runtime.

Never report: SQL keywords, functions and types (`coalesce`, `now()`, `count(*)`, `::int`); aliases the template itself defines (`as total`, a CTE name, a subquery alias) and their uses; `excluded.` in an upsert; system catalogs and schemas (`information_schema`, `pg_catalog`, `sys.`); anything inside `${…}`; anything you are unsure is a table or column.

A clean set returns {"findings": []}.
For each finding give the file, the line, the exact text quoted, one sentence on what is wrong, and the fix as the template rewritten with the schema object interpolated.
EOF

SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"quote":{"type":"string"},"finding":{"type":"string"},"fix":{"type":"string"}},"required":["file","line","quote","finding","fix"]}}},"required":["findings"]}'

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
    echo "gitflow: SQL review — a table or column is typed as text where the schema's object belongs (drizzle.md §I):" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  Put each finding to the developer with the fix, and ask: fix it, or skip it." >&2
    echo "  Fix: make the change, then commit again. Skip all that remain: commit again with SKIP_SQL_REVIEW=1." >&2
    exit 1
fi

echo "gitflow: SQL review clean — $COUNT sql template(s) reviewed." >&2
exit 0
