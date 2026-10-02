#!/usr/bin/env bash
# Regression suite for block-drizzle-handroll.sh.
#
# The subtle contract is the journal test: a .sql in a drizzle migrations dir that the
# journal does not list is hand-created and blocked (it arrived without its snapshot +
# journal entry), whichever tool wrote it — bash-edit-guard.sh replays a shell-created
# file as an Edit. A .sql the journal lists was generated, and filling in its body is
# the correct workflow, so it must stay open. A guard that blocks both makes
# db:generate useless, so both halves are pinned here.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-drizzle-handroll.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

# A real drizzle dir (has meta/_journal.json) and a look-alike that is not drizzle.
mkdir -p "$tmp/drizzle/migrations/meta" "$tmp/plain/migrations"
printf '{"entries":[{"idx":0,"tag":"0031_generated"}]}' > "$tmp/drizzle/migrations/meta/_journal.json"

decision(){
  printf '{"tool_name":"%s","tool_input":{"file_path":%s}}' "$2" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "$3"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $4"; else echo "  ✗ FAIL ($d, want $1) — $4"; fail=1; fi; }

echo "MUST DENY — drizzle bookkeeping, on Write AND Edit:"
t deny "$tmp/drizzle/migrations/meta/_journal.json"        Write 'journal, Write'
t deny "$tmp/drizzle/migrations/meta/_journal.json"        Edit  'journal, Edit'
t deny "$tmp/drizzle/migrations/meta/0001_snapshot.json"   Write 'snapshot, Write'
t deny "$tmp/drizzle/migrations/meta/0001_snapshot.json"   Edit  'snapshot, Edit'

echo "MUST DENY — a .sql in a real drizzle dir that the journal does not list:"
t deny "$tmp/drizzle/migrations/0032_thing.sql"            Write 'new .sql via Write'
t deny "$tmp/drizzle/migrations/0032_thing.sql"            Edit  'shell-created .sql, replayed as an Edit'
t deny "$tmp/drizzle/migrations/0032_thing.sql"            MultiEdit 'unlisted .sql via MultiEdit'

echo "MUST ALLOW — the correct workflow (fill in the generated .sql body):"
t allow "$tmp/drizzle/migrations/0031_generated.sql"       Edit  'Edit a journaled .sql'
t allow "$tmp/drizzle/migrations/0031_generated.sql"       Write 'Write over a journaled .sql'

echo "MUST ALLOW — not a drizzle dir (no meta/_journal.json sibling):"
t allow "$tmp/plain/migrations/001_init.sql"               Write 'hand-written .sql elsewhere'

echo "MULTIEDIT — same contract as Edit (it can only touch an existing file):"
t deny  "$tmp/drizzle/migrations/meta/_journal.json"      MultiEdit 'journal via MultiEdit'
t deny  "$tmp/drizzle/migrations/meta/0001_snapshot.json" MultiEdit 'snapshot via MultiEdit'
t allow "$tmp/drizzle/migrations/0031_generated.sql"      MultiEdit 'edit a journaled .sql via MultiEdit'

echo "WINDOWS-STYLE PATH — backslashes do not hide the migrations dir:"
wd=$(cd "$tmp/drizzle/migrations" && pwd -P); wd="${wd//\//\\}"
t deny  "$wd\\meta\\_journal.json"                        Edit  'journal, backslash path'
t deny  "$wd\\0032_thing.sql"                              Write 'unlisted .sql, backslash path'
t allow "$wd\\0031_generated.sql"                          Edit  'journaled .sql, backslash path'

echo "MUST ALLOW — ordinary files:"
t allow "$tmp/drizzle/migrations/README.md"                Write 'a README beside migrations'
t allow "apps/shared/src/db/schema/user.ts"                Write 'a schema source file'
t allow "$tmp/drizzle/migrations/meta/_journal.json"       Bash  'non-Edit/Write tool is out of scope'

echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
tmpout=$(mktemp)
jsonok(){
  printf '{"tool_name":"%s","tool_input":{"file_path":%s}}' "$2" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null
    then echo "  ✓ parses: $(basename "$1")"
    else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
jsonok "$tmp/drizzle/migrations/meta/_journal.json" Write
jsonok "$tmp/drizzle/migrations/0032_thing.sql"     Write
mkdir -p "$tmp/q\"uote/migrations/meta"; cp "$tmp/drizzle/migrations/meta/_journal.json" "$tmp/q\"uote/migrations/meta/"
jsonok "$tmp/q\"uote/migrations/0032_thing.sql"     Write
rm -f "$tmpout"

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Write"}' '{"tool_name":"Write","tool_input":{}}'; do
  printf '%s' "$p" | "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

echo "TOOL MISSING — the guard refuses, naming the tool, never allows:"
assert_refuses_without "$H" deny "$(path_without jq)" jq \
  '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' 'no jq on PATH'

exit "$fail"
