#!/usr/bin/env bash
# Regression suite for block-console-log.sh.
#
# The guard is CONDITIONAL: it only engages in a project that actually depends on
# pino, and it resolves package.json from the project dir (CLAUDE_PROJECT_DIR, else its
# working directory). So each case points both at a purpose-built temp project — a suite
# that ran from the repo root would silently test only whichever world that root is.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-console-log.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

mkdir -p "$tmp/pino" "$tmp/nopino" "$tmp/mono/packages/shared" "$tmp/nopkg" \
         "$tmp/wsobj/services/api" "$tmp/pnpm/libs/log" "$tmp/nested/tools/cli"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/pino/package.json"
printf '{"dependencies":{"zod":"^3.0.0"}}'   > "$tmp/nopino/package.json"
printf '{"workspaces":["packages/*"],"dependencies":{"zod":"^3.0.0"}}' > "$tmp/mono/package.json"
printf '{"workspaces":{"packages":["services/*"]}}' > "$tmp/wsobj/package.json"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/wsobj/services/api/package.json"
printf '{"name":"root"}'                      > "$tmp/pnpm/package.json"
printf 'packages:\n  - "libs/*"\n'          > "$tmp/pnpm/pnpm-workspace.yaml"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/pnpm/libs/log/package.json"
printf '{"name":"root"}'                      > "$tmp/nested/package.json"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/nested/tools/cli/package.json"
printf '{"dependencies":{"pino":"^9.0.0"}}'  > "$tmp/mono/packages/shared/package.json"

decision(){  # $1 cwd  $2 file_path  $3 content  $4 tool
  # CONTENT rides stdin, not an argv — the large-file case below is precisely a payload
  # too big for ARG_MAX, and a harness that cannot build it cannot test it.
  printf '%s' "$3" | python3 -c '
import json, sys
print(json.dumps({"tool_name": sys.argv[1],
                  "tool_input": {"file_path": sys.argv[2], "content": sys.stdin.read()}}))
' "${4:-Write}" "$2" \
  | (cd "$1" && CLAUDE_PROJECT_DIR="$PWD" "$H" 2>/dev/null) | python3 -c '
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

echo "MONOREPO — pino declared in any workspace engages:"
t deny  "$tmp/mono"   'src/a.ts' 'console.log("hi")'          'pino via packages/shared (workspaces array)'
t deny  "$tmp/wsobj"  'src/a.ts' 'console.log("hi")'          'pino via services/api (workspaces.packages)'
t deny  "$tmp/pnpm"   'src/a.ts' 'console.log("hi")'          'pino via libs/log (pnpm-workspace.yaml)'
t deny  "$tmp/nested" 'tools/cli/src/a.ts' 'console.log("hi")' 'pino in the manifest nearest the edited file'
t allow "$tmp/nested" 'src/a.ts' 'console.log("hi")'          'a sibling outside that workspace stays free'

echo "WINDOWS-STYLE PATH — the separators do not hide the extension or the workspace:"
winp=$(cd "$tmp/nested" && pwd -P); winp="${winp//\//\\}\\tools\\cli\\src\\a.ts"
t deny  "$tmp/nested" "$winp" 'console.log("hi")'            'backslash path into the pino workspace'

echo "MULTIEDIT — content lives in edits[].new_string, not new_string/content:"
# Built separately because MultiEdit's payload shape differs. Before the guard learned
# it, every case here returned allow — invoked, matching nothing, indistinguishable
# from a pass.
medit(){  # $1 cwd  $2 file_path  $3..$N edit strings
  local cwd="$1" fp="$2"; shift 2
  python3 -c '
import json, sys
fp = sys.argv[1]
edits = [{"old_string": "x", "new_string": e} for e in sys.argv[2:]]
print(json.dumps({"tool_name": "MultiEdit",
                  "tool_input": {"file_path": fp, "edits": edits}}))
' "$fp" "$@" | (cd "$cwd" && CLAUDE_PROJECT_DIR="$PWD" "$H" 2>/dev/null) | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
mt(){ local want="$1" desc="$2"; shift 2; d=$(medit "$@"); d=${d:-allow}
      if [ "$d" = "$want" ]; then echo "  ✓ $desc"; else echo "  ✗ FAIL ($d, want $want) — $desc"; fail=1; fi; }

mt deny  'console.log in the first edit'  "$tmp/pino" 'src/a.ts' 'console.log("hi")' 'const ok = 1'
mt deny  'console.error in a later edit'  "$tmp/pino" 'src/a.ts' 'const ok = 1' 'console.error(err)'
mt allow 'clean edits'                    "$tmp/pino" 'src/a.ts' 'logger.info("hi")' 'const ok = 1'
mt allow 'non-TS file'                    "$tmp/pino" 'README.md' 'console.log("in a doc")'
mt allow 'no pino dependency'             "$tmp/nopino" 'src/a.ts' 'console.log("fine here")'

echo "DENY PAYLOAD MUST BE VALID JSON (a malformed deny is silently discarded):"
tmpout=$(mktemp)
jsonok(){
  printf '{"tool_name":"Write","tool_input":{"file_path":"src/a.ts","content":%s}}' \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | (cd "$tmp/pino" && CLAUDE_PROJECT_DIR="$PWD" "$H" 2>/dev/null) > "$tmpout"
  if [ ! -s "$tmpout" ]; then echo "  ✗ FAIL — expected a deny, got allow: $1"; fail=1; return; fi
  if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmpout" 2>/dev/null
    then echo "  ✓ parses: $1"
    else echo "  ✗ FAIL — MALFORMED deny payload: $1"; fail=1; fi; }
jsonok 'console.log("hi")'
jsonok 'console.log("she said \"hello\" loudly")'
jsonok 'console.log(`a backtick ${x}`)'
rm -f "$tmpout"

echo "LARGE CONTENT (the guard must not fail OPEN on a big file):"
# A Write carries the WHOLE FILE. Passing that as an argv is bounded by ARG_MAX, and the
# failure mode is an ALLOW: python3 dies with E2BIG, prints nothing, and the script falls
# through to exit 0. ~2MB is comfortably past macOS's limit and cheap to build.
big=$(python3 -c 'print("const x = 1;\n" * 120000 + "console.log(\"deep in a big file\")")')
t deny "$tmp/pino" 'src/big.ts' "$big" 'console.log at the end of a ~2MB file'

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Write"}' '{"tool_name":"Write","tool_input":{}}'; do
  printf '%s' "$p" | (cd "$tmp/pino" && CLAUDE_PROJECT_DIR="$PWD" "$H" >/dev/null 2>&1)
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

echo "TOOL MISSING — the guard refuses, naming the tool, never allows:"
pl='{"tool_name":"Write","tool_input":{"file_path":"src/a.ts","content":"const ok = 1"}}'
assert_refuses_without "$H" deny "$(path_without jq)" jq "$pl" 'no jq on PATH'
assert_refuses_without "$H" deny "$(path_with_store_python)" python3 "$pl" 'python3 is the Windows Store stub'

exit "$fail"
