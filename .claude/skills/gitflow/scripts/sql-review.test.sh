#!/usr/bin/env bash
# Regression suite for sql-review.sh. A stub CLI stands in for claude: it records what it
# was sent and answers with whatever $STUB_MODE selects. A stub lister stands in for the
# coverage check's --sql-templates, answering with whatever $LIST_MODE selects.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sql-review.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
printf '%s\n' "$@" > "$STUB_LOG.args"
pwd > "$STUB_LOG.cwd"
echo call >> "$STUB_LOG.calls"
case "$STUB_MODE" in
  clean)   echo '{"is_error":false,"structured_output":{"findings":[]}}' ;;
  finding) echo '{"is_error":false,"structured_output":{"findings":[{"file":"src/q.ts","line":4,"quote":"invoice.total","finding":"the column is typed as text","fix":"sql`${invoice.total} - 1`"}]}}' ;;
  error)   echo "boom" >&2; exit 3 ;;
  garbage) echo 'not json' ;;
esac
EOF
chmod +x "$tmp/claude"
cat > "$tmp/lister" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_LOG.lister"
case "$LIST_MODE" in
  none)  echo '[]' ;;
  one)   echo '[{"file":"src/q.ts","line":4,"text":"sql`invoice.total - 1`"}]' ;;
  two)   echo '[{"file":"src/q.ts","line":4,"text":"sql`invoice.total - 2`"}]' ;;
  fails) echo "TypeScript not found" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/lister"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/apps/api/src/db" "$repo/node_modules/x"
  printf '{"name":"root","private":true}\n' > "$repo/package.json"
  printf '{"name":"api","dependencies":{"drizzle-orm":"0.45.2"}}\n' > "$repo/apps/api/package.json"
  printf 'export default { schema: "./src/db/schema.ts", casing: "snake_case" }\n' > "$repo/apps/api/drizzle.config.ts"
  printf 'import { pgTable, numeric } from "drizzle-orm/pg-core"\nexport const invoice = pgTable("invoice", { total: numeric("total") })\n' > "$repo/apps/api/src/db/schema.ts"
  printf 'export const q = 1\n' > "$repo/apps/api/src/q.ts"
  printf 'export const t = pgTable("vendored", {})\n' > "$repo/node_modules/x/index.ts"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" LIST_MODE="$2" STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/claude" SQL_REVIEW_LISTER="$tmp/lister" "$S" HEAD 2>"$tmp/err"); echo $?; }
calls(){ if [ -f "$tmp/log.calls" ]; then wc -l <"$tmp/log.calls" | tr -d ' '; else echo 0; fi; }
# A passed review is remembered under the git dir; forgetting it makes the next run ask again.
forget(){ rm -rf "$(git -C "$repo" rev-parse --path-format=absolute --git-path gitflow-review-cache)"; }
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }
has(){ if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }
called(){ [ -f "$tmp/log" ]; }

echo "DOES NOT APPLY:"
new_repo; printf '{"name":"api"}\n' > "$repo/apps/api/package.json"; rm -f "$tmp/log"
t 0 "$(gate finding one)" 'no drizzle-orm: exit 0'
has 'does not apply: no package.json declares drizzle-orm' '…and says why'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }
new_repo; rm -f "$tmp/log"
(cd "$repo" && SKIP_SQL_REVIEW=1 STUB_MODE=finding LIST_MODE=one STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/claude" SQL_REVIEW_LISTER="$tmp/lister" "$S" HEAD 2>"$tmp/err"); t 0 "$?" 'SKIP_SQL_REVIEW=1: exit 0'
has 'SQL review skipped (SKIP_SQL_REVIEW=1)' '…and says so'

echo "NOT REVIEWED:"
new_repo; rm -f "$tmp/log"
t 0 "$(gate finding none)" 'no sql template changed: exit 0'
has 'no sql template changed' '…and says so'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }
grep -qx -- '--sql-templates' "$tmp/log.lister" && grep -qx HEAD "$tmp/log.lister" \
  && echo "  ✓ …asking the lister for the templates changed since the base" || { echo "  ✗ FAIL — lister args: $(cat "$tmp/log.lister")"; fail=1; }

echo "REVIEWED:"
new_repo; rm -f "$tmp/log"
t 0 "$(gate clean one)" 'a clean template: exit 0'
has 'SQL review clean — reviewed 1 sql template(s) against 1 Drizzle schema file(s)' '…counting it and the schema'
grep -qF 'src/q.ts:4' "$tmp/log" && grep -qF 'sql`invoice.total - 1`' "$tmp/log" \
  && echo "  ✓ …sending the template with its file and line" || { echo "  ✗ FAIL — reviewer input: $(cat "$tmp/log")"; fail=1; }
top=$(git -C "$repo" rev-parse --show-toplevel)
grep -qF "Repository root: $top" "$tmp/log" && echo "  ✓ the input names the repository root" || { echo "  ✗ FAIL — no repository root: $(cat "$tmp/log")"; fail=1; }
grep -qF '=== DRIZZLE SCHEMA FILE: apps/api/src/db/schema.ts' "$tmp/log" && grep -qF 'pgTable("invoice"' "$tmp/log" \
  && echo "  ✓ the schema file, found by its table function, is sent" || { echo "  ✗ FAIL — schema not sent: $(cat "$tmp/log")"; fail=1; }
grep -qF '=== DRIZZLE CONFIG: apps/api/drizzle.config.ts' "$tmp/log" && echo "  ✓ …with the drizzle config" || { echo "  ✗ FAIL — config not sent"; fail=1; }
! grep -qF 'node_modules' "$tmp/log" && ! grep -qF 'SCHEMA FILE: apps/api/src/q.ts' "$tmp/log" \
  && echo "  ✓ …and neither node_modules nor a file defining no table" || { echo "  ✗ FAIL — extra files sent: $(cat "$tmp/log")"; fail=1; }
[ "$(grep -xF -A1 -- '--tools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ the reviewer gets only the Read, Grep and Glob tools" || { echo "  ✗ FAIL — --tools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--allowedTools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ …pre-approved" || { echo "  ✗ FAIL — --allowedTools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--add-dir' "$tmp/log.args" | sed -n 2p)" = "$top" ] \
  && echo "  ✓ …with the repository root added by --add-dir" || { echo "  ✗ FAIL — --add-dir: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(cat "$tmp/log.cwd")" != "$top" ] && [ "$(cat "$tmp/log.cwd")" != "$repo" ] \
  && echo "  ✓ …running outside the repository, so its settings and CLAUDE.md do not load" || { echo "  ✗ FAIL — ran in the repo"; fail=1; }
forget; t 1 "$(gate finding one)" 'a typed name: exit 1'
has 'src/q.ts:4' '…naming where'
has 'SKIP_SQL_REVIEW=1' '…and how to skip it'

echo "CANNOT RUN:"
new_repo
t 1 "$(gate clean fails)" 'the lister failing: exit 1'
has 'cannot list the changed sql templates' '…and says so'
t 1 "$(gate error one)" 'the reviewer erroring: exit 1'
has 'could not run (claude exited 3)' '…and says so'
t 1 "$(gate garbage one)" 'an unreadable answer: exit 1'
(cd "$repo" && STUB_MODE=clean LIST_MODE=one STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/nope" SQL_REVIEW_LISTER="$tmp/lister" "$S" HEAD 2>"$tmp/err"); t 1 "$?" 'no claude CLI: exit 1'
has 'needs the Claude Code CLI' '…and says so'
(cd "$repo" && STUB_MODE=clean STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); t 1 "$?" 'the coverage check missing: exit 1'
has 'check-integration-coverage.mjs, which is missing' '…naming it'

echo "SIZE LIMIT:"
sized(){ (cd "$repo" && SQL_REVIEW_MAX_BYTES="$1" STUB_MODE=clean LIST_MODE=one STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/claude" SQL_REVIEW_LISTER="$tmp/lister" "$S" HEAD 2>"$tmp/err"); echo $?; }
new_repo; rm -f "$tmp/log"
t 0 "$(sized 200)" 'the schema over the budget: still reviewed'
grep -qF '=== CHANGED SQL TEMPLATE: src/q.ts:4' "$tmp/log" && echo "  ✓ …the template inlined first" || { echo "  ✗ FAIL — template not inlined: $(cat "$tmp/log")"; fail=1; }
grep -qF 'NOT INLINED — read with the Read tool' "$tmp/log" && grep -qF 'apps/api/src/db/schema.ts (Drizzle schema file)' "$tmp/log" \
  && echo "  ✓ …the schema listed for the reviewer to read" || { echo "  ✗ FAIL — schema not listed: $(cat "$tmp/log")"; fail=1; }
has 'file(s) over the 200-byte inline budget listed for the reviewer to read' '…and the summary says so'
new_repo; rm -f "$tmp/log"
t 0 "$(sized 10)" 'the template itself over the budget: still reviewed, never refused'
called && echo "  ✓ …the reviewer is called" || { echo "  ✗ FAIL — reviewer not called"; fail=1; }
grep -qF 'src/q.ts:4 (changed sql template — read it at that line)' "$tmp/log" && ! grep -qF '=== CHANGED SQL TEMPLATE' "$tmp/log" \
  && echo "  ✓ …the template listed by file and line, not inlined" || { echo "  ✗ FAIL — template not listed: $(cat "$tmp/log")"; fail=1; }
has 'src/q.ts:4 (changed sql template' '…and the gate prints what it listed'

echo "A PASS IS REUSED:"
new_repo; rm -f "$tmp/log.calls"
gate clean one >/dev/null; gate clean one >/dev/null
[ "$(calls)" = 1 ] && grep -q 'reusing the earlier pass' "$tmp/err" && echo "  ✓ the same templates again: no call, and it says it reused the pass" || { echo "  ✗ FAIL — calls=$(calls): $(cat "$tmp/err")"; fail=1; }
gate clean two >/dev/null
[ "$(calls)" = 2 ] && echo "  ✓ a changed template: reviewed again" || { echo "  ✗ FAIL — changed template reused (calls=$(calls))"; fail=1; }
sized 200 >/dev/null; [ "$(calls)" = 3 ] || { echo "  ✗ FAIL — the listed-schema run did not review (calls=$(calls))"; fail=1; }
cp "$tmp/log" "$tmp/log.before"
printf 'export const vendor = pgTable("vendor", {})\n' >> "$repo/apps/api/src/db/schema.ts"
sized 200 >/dev/null
if cmp -s "$tmp/log.before" "$tmp/log"; then same_input=yes; else same_input=no; fi
[ "$(calls)" = 4 ] && [ "$same_input" = yes ] && echo "  ✓ a schema file changed, the input sent unchanged: reviewed again" || { echo "  ✗ FAIL — a schema change reused the pass (calls=$(calls), same input=$same_input)"; fail=1; }
new_repo; rm -f "$tmp/log.calls"
t 1 "$(gate finding one)" 'a finding fails'
t 1 "$(gate finding one)" '…and is not remembered: the same templates fail again'
[ "$(calls)" = 2 ] && echo "  ✓ …asking the reviewer both times" || { echo "  ✗ FAIL — a finding was reused (calls=$(calls))"; fail=1; }
t 1 "$(gate error one)" 'a review that could not run fails'
t 0 "$(gate clean one)" '…and is not remembered: the next run reviews'
[ "$(calls)" = 4 ] && echo "  ✓ …asking the reviewer again" || { echo "  ✗ FAIL — a failed run was reused (calls=$(calls))"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
