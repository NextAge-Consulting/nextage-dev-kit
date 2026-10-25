#!/usr/bin/env bash
# Regression suite for test-review.sh. A stub CLI stands in for claude: it records what it
# was sent and answers with whatever $STUB_MODE selects.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-review.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
printf '%s\n' "$@" > "$STUB_LOG.args"
pwd > "$STUB_LOG.cwd"
echo call >> "$STUB_LOG.calls"
case "$STUB_MODE" in
  clean)        echo '{"is_error":false,"structured_output":{"findings":[]}}' ;;
  missing)      echo '{"is_error":false,"structured_output":{"findings":[{"kind":"missing","file":"src/billing.ts","function":"monthTotal","why":"the last day of the month is a period boundary","fix":"test an invoice dated on the last day"}]}}' ;;
  reimplements) echo '{"is_error":false,"structured_output":{"findings":[{"kind":"reimplements","file":"src/billing.integration.test.ts","test":"totals","why":"runs its own copy of the sum","fix":"call monthTotal"}]}}' ;;
  superfluous)  echo '{"is_error":false,"structured_output":{"findings":[{"kind":"superfluous","file":"src/billing.integration.test.ts","test":"saves a row","why":"only shows the ORM saved the row","fix":"delete it"}]}}' ;;
  misnamed)     echo '{"is_error":false,"structured_output":{"findings":[{"kind":"misnamed","file":"src/billing.integration.test.ts","why":"tests nothing risky","fix":"rename to billing.dev.integration.test.ts"}]}}' ;;
  badkind)      echo '{"is_error":false,"structured_output":{"findings":[{"kind":"other","file":"x","why":"y","fix":"z"}]}}' ;;
  error)        echo "boom" >&2; exit 3 ;;
  garbage)      echo 'not json' ;;
esac
EOF
chmod +x "$tmp/claude"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/src/lib" "$repo/test" "$repo/.claude/hooks"
  printf 'export function monthTotal(rows: number[]) {\n  return rows.reduce((a, b) => a + b, 0)\n}\n\nexport const other = 1\n' > "$repo/src/billing.ts"
  printf 'export const fmt = (n: number) => String(n)\n' > "$repo/src/lib/format.ts"
  printf "import { monthTotal } from './billing'\nimport { dbTest } from '../test/define'\ndbTest('totals', () => monthTotal([1]))\n" > "$repo/src/billing.integration.test.ts"
  printf "import { fmt } from '@/lib/format.js'\ntest('fmt', () => fmt(1))\n" > "$repo/src/format.test.ts"
  printf "import { monthTotal } from './billing'\ntest('happy', () => monthTotal([2]))\n" > "$repo/src/billing.happy.integration.test.ts"
  printf 'export const dbTest = () => null\n' > "$repo/test/define.ts"
  printf '# notes\n' > "$repo/README.md"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" STUB_LOG="$tmp/log" TEST_REVIEW_CLAUDE="$tmp/claude" "$S" "${BASE:-HEAD}" 2>"$tmp/err"); echo $?; }
calls(){ if [ -f "$tmp/log.calls" ]; then wc -l <"$tmp/log.calls" | tr -d ' '; else echo 0; fi; }
forget(){ rm -rf "$(git -C "$repo" rev-parse --path-format=absolute --git-path gitflow-review-cache)"; }
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }
has(){ if grep -qF -- "$2" "$1"; then echo "  ✓ $3"; else echo "  ✗ FAIL — $3: $(cat "$1")"; fail=1; fi; }
hasnt(){ if grep -qF -- "$2" "$1"; then echo "  ✗ FAIL — $3"; fail=1; else echo "  ✓ $3"; fi; }
called(){ [ -f "$tmp/log" ]; }

echo "NOT REVIEWED:"
new_repo; printf 'more\n' >> "$repo/README.md"; rm -f "$tmp/log"
t 0 "$(gate missing)" 'nothing TypeScript changed: exit 0'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }
has "$tmp/err" 'no TypeScript source or test file changed' '…saying so'
new_repo; printf 'export const x = 2\n' >> "$repo/test/define.ts"; mkdir -p "$repo/.claude/hooks" "$repo/node_modules/p"
printf 'x\n' > "$repo/.claude/hooks/a.ts"; printf 'x\n' > "$repo/src/env.d.ts"; rm -f "$tmp/log"
t 0 "$(gate missing)" 'test support, .claude, a .d.ts and node_modules are not reviewed'
new_repo; rm -f "$tmp/log"
t 0 "$( (cd "$repo" && SKIP_TEST_REVIEW=1 STUB_MODE=missing STUB_LOG="$tmp/log" TEST_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); echo $?)" 'SKIP_TEST_REVIEW=1: exit 0'
printf 'x\n' >> "$repo/src/billing.ts"
t 0 "$( (cd "$repo" && SKIP_TEST_REVIEW=1 STUB_MODE=missing STUB_LOG="$tmp/log" TEST_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); echo $?)" '…even with source changed'
has "$tmp/err" 'test review skipped (SKIP_TEST_REVIEW=1)' '…saying it was skipped'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }

echo "REVIEWED:"
new_repo; sed -i.bak 's/a + b/a + b + 0/' "$repo/src/billing.ts"; rm -f "$repo/src/billing.ts.bak"
t 0 "$(gate clean)" 'a changed source file, clean: exit 0'
has "$tmp/log" '=== CHANGED SOURCE: src/billing.ts' "the source file's diff is sent"
has "$tmp/log" 'export function monthTotal' '…with the declaration the change touches'
has "$tmp/log" '    1  export function monthTotal' '…numbered as in the file'
hasnt "$tmp/log" '    5  export const other' '…and not a declaration it does not touch'
has "$tmp/log" '(risk test): src/billing.integration.test.ts' 'a risk test importing it is sent, labelled'
has "$tmp/log" '(happy-path test): src/billing.happy.integration.test.ts' 'a happy-path test importing it is sent, labelled'
hasnt "$tmp/log" 'src/format.test.ts' 'a test that does not import it is not sent'
has "$tmp/err" 'test review clean — reviewed 1 changed source file(s) and 0 changed test file(s), 2 test file(s) importing a changed file' 'a clean review counts what it reviewed'
top=$(git -C "$repo" rev-parse --show-toplevel)
has "$tmp/log" "Repository root: $top" 'the input names the repository root'
grep -qxF -A1 -- '--tools' "$tmp/log.args" && [ "$(grep -xF -A1 -- '--tools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ the reviewer gets only the Read, Grep and Glob tools" || { echo "  ✗ FAIL — --tools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--allowedTools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ …pre-approved" || { echo "  ✗ FAIL — --allowedTools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--add-dir' "$tmp/log.args" | sed -n 2p)" = "$top" ] \
  && echo "  ✓ …with the repository root added by --add-dir" || { echo "  ✗ FAIL — --add-dir: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(cat "$tmp/log.cwd")" != "$top" ] && [ "$(cat "$tmp/log.cwd")" != "$repo" ] \
  && echo "  ✓ …running outside the repository, so its settings and CLAUDE.md do not load" || { echo "  ✗ FAIL — ran in the repo"; fail=1; }
new_repo; printf 'export const fmt2 = 1\n' >> "$repo/src/lib/format.ts"
gate clean >/dev/null; has "$tmp/log" '(unit test): src/format.test.ts' 'an alias import (@/lib/format.js) finds its test'
new_repo; printf "test('more', () => 1)\n" >> "$repo/src/format.test.ts"
gate clean >/dev/null
has "$tmp/log" '=== CHANGED TEST (unit test): src/format.test.ts' 'a changed test alone is reviewed'
has "$tmp/log" 'APPLICATION CODE A CHANGED TEST IMPORTS (unchanged, for context): src/lib/format.ts' '…with the application code it imports'
new_repo; printf "test('d', () => 1)\n" > "$repo/src/billing.dev.integration.test.ts"
gate clean >/dev/null; has "$tmp/log" '(development test): src/billing.dev.integration.test.ts' 'a new development test is labelled'
new_repo; base=$(git -C "$repo" rev-parse HEAD); printf 'export const y = 1\n' >> "$repo/src/billing.ts"; git -C "$repo" commit -qam cp
BASE="$base" gate clean >/dev/null; has "$tmp/log" 'CHANGED SOURCE: src/billing.ts' 'a change already in a checkpoint since the base'

echo "FINDINGS BLOCK:"
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"
for k in missing reimplements superfluous misnamed; do
  forget; t 1 "$(gate "$k")" "a $k finding: exit 1"
  has "$tmp/err" "1. $k: " "…naming its kind"
done
forget; gate missing >/dev/null
has "$tmp/err" 'src/billing.ts — monthTotal' 'a missing finding names the file and the function'
has "$tmp/err" '(write the test)' '…and what to do'
has "$tmp/err" 'SKIP_TEST_REVIEW=1' '…and the override'
gate superfluous >/dev/null; has "$tmp/err" '(delete it)' 'a superfluous finding says delete it'
gate reimplements >/dev/null; has "$tmp/err" '(rewrite it to call the function it tests)' 'a reimplements finding says call the function it tests'

echo "CANNOT RUN — FAILS:"
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"
t 1 "$(gate error)" 'reviewer exits non-zero: exit 1'
t 1 "$(gate garbage)" 'reviewer returns unparseable output: exit 1'
t 1 "$(gate badkind)" 'reviewer returns a kind outside the schema: exit 1'
t 1 "$( (cd "$repo" && TEST_REVIEW_CLAUDE="$tmp/no-such-cli" "$S" HEAD 2>/dev/null); echo $?)" 'CLI missing: exit 1'
t 1 "$(BASE=no-such-ref gate clean)" 'a base git cannot diff against: exit 1'

echo "SIZE LIMIT:"
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"
t 0 "$( (cd "$repo" && TEST_REVIEW_MAX_BYTES=500 STUB_MODE=clean STUB_LOG="$tmp/log" TEST_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); echo $?)" 'covering tests over the budget: still reviewed'
has "$tmp/log" '=== CHANGED SOURCE: src/billing.ts' '…the change itself inlined first'
has "$tmp/log" 'NOT INLINED — read with the Read tool' '…the rest listed for the reviewer to read'
has "$tmp/log" 'src/billing.integration.test.ts (risk test that imports a changed file)' '…by path and kind'
has "$tmp/err" '2 file(s) over the 500-byte inline budget listed for the reviewer to read' '…and the summary says so'
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"; rm -f "$tmp/log"
t 0 "$( (cd "$repo" && TEST_REVIEW_MAX_BYTES=100 STUB_MODE=clean STUB_LOG="$tmp/log" TEST_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); echo $?)" 'the change itself over the budget: still reviewed, never refused'
called && echo "  ✓ …the reviewer is called" || { echo "  ✗ FAIL — reviewer not called"; fail=1; }
has "$tmp/log" 'src/billing.ts (changed source; its diff against HEAD was not inlined — read the file)' '…the changed source listed for reading'
hasnt "$tmp/log" '=== CHANGED SOURCE:' '…and not inlined'
has "$tmp/err" 'src/billing.ts (changed source' '…and the gate prints what it listed'

echo "A PASS IS REUSED:"
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"; rm -f "$tmp/log.calls"
gate clean >/dev/null; gate clean >/dev/null
[ "$(calls)" = 1 ] && grep -q 'reusing the earlier pass' "$tmp/err" && echo "  ✓ the same input again: no call, and it says it reused the pass" || { echo "  ✗ FAIL — calls=$(calls): $(cat "$tmp/err")"; fail=1; }
printf 'export const w = 1\n' >> "$repo/src/billing.ts"; gate clean >/dev/null
[ "$(calls)" = 2 ] && echo "  ✓ changed source: reviewed again" || { echo "  ✗ FAIL — changed source reused (calls=$(calls))"; fail=1; }
printf "test('x', () => 1)\n" >> "$repo/src/billing.happy.integration.test.ts"; gate clean >/dev/null
[ "$(calls)" = 3 ] && echo "  ✓ a changed covering test: reviewed again" || { echo "  ✗ FAIL — changed test reused (calls=$(calls))"; fail=1; }
gate clean >/dev/null; [ "$(calls)" = 3 ] || { echo "  ✗ FAIL — not reused before the unrelated test change (calls=$(calls))"; fail=1; }
cp "$tmp/log" "$tmp/log.before"
printf "test('y', () => 1)\n" >> "$repo/src/format.test.ts"
git -C "$repo" add src/format.test.ts; git -C "$repo" commit -qm 'a test elsewhere'
gate clean >/dev/null
if cmp -s "$tmp/log.before" "$tmp/log"; then same_input=yes; else same_input=no; fi
[ "$(calls)" = 4 ] && [ "$same_input" = yes ] && echo "  ✓ a test elsewhere changed, the input sent unchanged: reviewed again" || { echo "  ✗ FAIL — a test change elsewhere reused the pass (calls=$(calls), same input=$same_input)"; fail=1; }
new_repo; printf 'export const z = 1\n' >> "$repo/src/billing.ts"; rm -f "$tmp/log.calls"
t 1 "$(gate missing)" 'a finding fails'
t 1 "$(gate missing)" '…and is not remembered: the same input fails again'
[ "$(calls)" = 2 ] && echo "  ✓ …asking the reviewer both times" || { echo "  ✗ FAIL — a finding was reused (calls=$(calls))"; fail=1; }

echo "A TEST IN ANOTHER EXTENSION:"
new_repo; mkdir -p "$repo/tests"
printf "import { monthTotal } from '../src/billing.ts'\ntest('node test', () => monthTotal([3]))\n" > "$repo/tests/billing.test.mjs"
git -C "$repo" add -A; git -C "$repo" commit -qm "node test"
sed -i.bak 's/a + b/a + b + 0/' "$repo/src/billing.ts"; rm -f "$repo/src/billing.ts.bak"
t 0 "$(gate clean)" 'a changed source covered by a .test.mjs: reviewed'
has "$tmp/log" 'tests/billing.test.mjs' 'a .test.mjs importing the changed source is sent as a covering test'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
