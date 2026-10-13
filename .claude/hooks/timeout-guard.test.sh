#!/usr/bin/env bash
# Regression suite for timeout-guard.sh.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/timeout-guard.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

decision(){
  printf '{"tool_name":"%s","tool_input":{"command":%s}}' "${2:-Bash}" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("allow")
'
}
t(){ d=$(decision "$2" "${4:-Bash}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL ($d, want $1) — $3"; fail=1; fi; }

echo "MUST ALLOW — no local timeout command:"
t allow 'semgrep scan --config auto --error'           'a plain command'
t allow 'curl --timeout 30 https://example.com'        'a --timeout flag'
t allow 'npx vitest --testTimeout=5000'                'a timeout option value'
t allow 'echo "timeout 30 is not on macOS"'            'timeout inside a quoted string'
t allow "ssh host 'timeout 30 ./check.sh'"             'timeout run on the remote machine over ssh'
t allow 'grep -n timeout src/*.ts | head'              'timeout as an argument'
t allow $'python3 - <<\'EOF\'\ntimeout 5 x\nimport os\nEOF' 'timeout inside a heredoc body'
t allow 'git log -1 --format=%s'                       'an unrelated command'

echo "MUST DENY — a local timeout or gtimeout:"
t deny  'timeout 180 semgrep scan | tail -5'           'timeout at the start, behind a pipe'
t deny  'gtimeout 60 npm test'                         'gtimeout'
t deny  'cd app && timeout 30 npm run lint'            'timeout later in a chain'
t deny  'FOO=1 timeout 5 cmd 2>/dev/null'              'after a VAR=value prefix'
t deny  'sudo timeout 5 cmd'                           'after sudo'
t deny  '/usr/bin/sudo timeout 5 cmd'                  'after a wrapper written with its path'
t deny  '/usr/bin/env FOO=1 timeout 5 cmd'             'after env written with its path'
t deny  'echo x; /usr/bin/timeout 5 cmd'               'by path, after ;'
t deny  '(timeout 5 cmd) > out.txt 2>&1'               'in a subshell with a redirect'
t deny  $'echo a\ntimeout 5 cmd'                       'on a later line'
t deny  'find . -name x | xargs timeout 5 rm'          'run by xargs'

echo "OVERRIDE AND SCOPE:"
t allow 'SKIP_TIMEOUT_GUARD=1 timeout 5 cmd'           'documented command-prefix override'
t allow 'timeout 5 cmd'                                'non-Bash tool is out of scope' Read

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Bash"}' '{"tool_name":"Bash","tool_input":{}}' '{"tool_name":"Bash","tool_input":{"command":null}}' '{"tool_name":"Bash","tool_input":{"command":"echo \"unbalanced"}}'; do
  printf '%s' "$p" | "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

echo "DENY PAYLOAD MUST BE VALID JSON:"
out=$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' 'timeout 5 echo "a \"quoted\" b"')" | "$H" 2>/dev/null)
if [ -n "$out" ] && printf '%s' "$out" | python3 -c 'import json,sys;json.load(sys.stdin)' 2>/dev/null; then echo "  ✓ parses with quotes in the command"
else echo "  ✗ FAIL — deny missing or malformed"; fail=1; fi

echo "TOOL MISSING — the guard refuses, naming the tool, never allows:"
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"
pl='{"tool_name":"Bash","tool_input":{"command":"echo hi"}}'
assert_refuses_without "$H" deny "$(path_without jq)" jq "$pl" 'no jq on PATH'
assert_refuses_without "$H" deny "$(path_with_store_python)" python3 "$pl" 'python3 is the Windows Store stub'
assert_refuses_without "$H" deny "$(path_without python3)" python3 "$pl" 'no python3 on PATH'

exit "$fail"
