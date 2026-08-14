#!/usr/bin/env bash
# Regression suite for block-console-log.sh.
#
# The guard is CONDITIONAL: it only engages in a project that actually depends on
# pino, and it resolves package.json from its own working directory. So each case
# runs with the cwd pointed at a purpose-built temp project — a suite that ran from
# the repo root would silently test only whichever world that root happens to be.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-console-log.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/pino" "$tmp/nopino" "$tmp/mono/packages/shared" "$tmp/nopkg"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/pino/package.json"
printf '{"dependencies":{"zod":"^3.0.0"}}'   > "$tmp/nopino/package.json"
printf '{"dependencies":{"zod":"^3.0.0"}}'   > "$tmp/mono/package.json"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/mono/packages/shared/package.json"

decision(){  # $1 cwd  $2 file_path  $3 content  $4 tool
  printf '{"tool_name":"%s","tool_input":{"file_path":%s,"content":%s}}' "${4:-Write}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$2")" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$3")" \
  | (cd "$1" && "$H" 2>/dev/null) | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "$3" "$4" "${6:-Write}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $5"; else echo "  ✗ FAIL ($d, want $1) — $5"; fail=1; fi; }

echo "PINO PROJECT — console.* must be denied:"
t deny "$tmp/pino" 'src/a.ts'  'console.log("hi")'            'console.log in .ts'
t deny "$tmp/pino" 'src/a.tsx' 'console.error(err)'           'console.error in .tsx'
t deny "$tmp/pino" 'src/a.js'  'console.warn("x")'            'console.warn in .js'
t deny "$tmp/pino" 'src/a.ts'  'console.debug({a:1})'         'console.debug'
t deny "$tmp/pino" 'src/a.ts'  'const x=1;\nconsole.info("y")' 'console on a later line'

echo "PINO PROJECT — legitimate code must pass:"
t allow "$tmp/pino" 'src/a.ts'   'logger.info("hi")'          'pino logger call'
t allow "$tmp/pino" 'src/a.ts'   'const consoleWidth = 80'    'a variable merely named console-ish'
t allow "$tmp/pino" 'README.md'  'console.log("in a doc")'    'non-TS/JS file'
t allow "$tmp/pino" 'src/a.css'  'console.log(1)'             'stylesheet'
t allow "$tmp/pino" 'src/a.ts'   'console.log(1)' 'non-Edit/Write tool is out of scope' Bash

echo "NON-PINO PROJECT — the guard must stay out of the way:"
t allow "$tmp/nopino" 'src/a.ts' 'console.log("fine here")'   'no pino dependency'
t allow "$tmp/nopkg"  'src/a.ts' 'console.log("fine here")'   'no package.json at all'

echo "MONOREPO — pino declared in packages/shared still engages:"
t deny  "$tmp/mono"   'src/a.ts' 'console.log("hi")'          'pino via packages/shared'

echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
tmpout=$(mktemp)
jsonok(){
  printf '{"tool_name":"Write","tool_input":{"file_path":"src/a.ts","content":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | (cd "$tmp/pino" && "$H" 2>/dev/null) > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null
    then echo "  ✓ parses: $1"
    else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
jsonok 'console.log("hi")'
jsonok 'console.log("she said \"hello\" loudly")'
jsonok 'console.log(`a backtick ${x}`)'
rm -f "$tmpout"

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Write"}' '{"tool_name":"Write","tool_input":{}}'; do
  printf '%s' "$p" | (cd "$tmp/pino" && "$H" >/dev/null 2>&1)
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

exit "$fail"
