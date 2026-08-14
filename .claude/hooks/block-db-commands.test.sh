#!/usr/bin/env bash
# Regression suite for block-db-commands.sh — constitution §V, schema changes never
# run on Claude's own judgment.
#
# This guard is default-DENY, so the cases that matter most are the ALLOWS: a false
# block here stops ordinary `npm test` / `npm run build` work dead.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-db-commands.sh"
fail=0
tmpout=$(mktemp); trap 'rm -f "$tmpout"' EXIT

decision(){
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "${2:-Bash}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "${4:-Bash}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL ($d, want $1) — $3"; fail=1; fi; }

echo "MUST DENY — schema commands without approval:"
t deny 'npm run db:generate'          'db:generate'
t deny 'npm run db:migrate'           'db:migrate'
t deny 'npm run db:push'              'db:push (never allowed at all)'
t deny 'npx drizzle-kit generate'     'drizzle-kit direct'
t deny 'npx drizzle-kit push'         'drizzle-kit push'
t deny 'cd apps/shared && npm run db:migrate' 'chained after cd'

echo "MUST ALLOW — approved runs:"
t allow 'SKIP_DB_GUARD=1 npm run db:generate' 'approved db:generate'
t allow 'SKIP_DB_GUARD=1 npm run db:migrate'  'approved db:migrate'

echo "MUST ALLOW — ordinary work (a false block here stops everything):"
t allow 'npm test'                    'npm test'
t allow 'npm run build'               'npm run build'
t allow 'npm ci'                      'npm ci'
t allow 'psql "$DATABASE_URL" -c "SELECT 1"' 'a read-only psql query'
t allow 'git status'                  'git status'
t allow 'npm run db:generate' 'non-Bash tool is out of scope' Read

echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
jsonok(){
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null
    then echo "  ✓ parses: $1"
    else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
jsonok 'npm run db:generate'
jsonok 'npm run db:generate -- --name="add user table"'

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}'; do
  printf '%s' "$p" | "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

exit "$fail"
