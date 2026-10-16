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
  fails) echo "TypeScript not found" >&2; exit 2 ;;
esac
EOF
chmod +x "$tmp/lister"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/apps/api"
  printf '{"name":"root","private":true}\n' > "$repo/package.json"
  printf '{"name":"api","dependencies":{"drizzle-orm":"0.45.2"}}\n' > "$repo/apps/api/package.json"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" LIST_MODE="$2" STUB_LOG="$tmp/log" SQL_REVIEW_CLAUDE="$tmp/claude" SQL_REVIEW_LISTER="$tmp/lister" "$S" HEAD 2>"$tmp/err"); echo $?; }
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
has 'SQL review clean — 1 sql template(s) reviewed' '…counting it'
grep -qF 'src/q.ts:4' "$tmp/log" && grep -qF 'sql`invoice.total - 1`' "$tmp/log" \
  && echo "  ✓ …sending the template with its file and line" || { echo "  ✗ FAIL — reviewer input: $(cat "$tmp/log")"; fail=1; }
t 1 "$(gate finding one)" 'a typed name: exit 1'
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

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
