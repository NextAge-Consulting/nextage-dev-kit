#!/usr/bin/env bash
# Regression suite for test-on-edit.sh — the hook that runs a file's tests on edit.
#
# Testing the tester is not ceremony. This hook is the thing that makes every OTHER
# suite in the kit load-bearing; if it silently stops firing, all of them quietly
# stop mattering and nothing anywhere goes red to say so.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-on-edit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

# A subject file with a PASSING suite, and one with a FAILING suite.
printf 'ok\n'                          > "$tmp/good.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/good.test.sh"
printf 'bad\n'                         > "$tmp/bad.sh"
printf '#!/usr/bin/env bash\necho "  x case-42 blew up" >&2\nexit 1\n' > "$tmp/bad.test.sh"
printf 'lonely\n'                      > "$tmp/untested.sh"
chmod +x "$tmp"/*.test.sh
# node:test suites beside .mjs subjects, and a vitest-style one that is not ours to run.
printf 'export const x = 1;\n'  > "$tmp/goodm.mjs"
printf "import { test } from 'node:test';\ntest('ok', () => {});\n" > "$tmp/goodm.test.mjs"
printf 'export const y = 1;\n'  > "$tmp/badm.mjs"
printf "import test from 'node:test';\nimport assert from 'node:assert';\ntest('case-77', () => { assert.equal(1, 2); });\n" > "$tmp/badm.test.mjs"
printf 'export const z = 1;\n'  > "$tmp/vit.mjs"
printf "import { test } from 'vitest';\ntest('x', () => { throw new Error('ran'); });\n" > "$tmp/vit.test.mjs"

run(){ printf '{"tool_input":{"file_path":"%s"}}' "$1" | "$H" >/dev/null 2>&1; }
t(){ run "$2"; r=$?; if [ "$r" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (exit $r, want $1) — $3"; fail=1; fi; }

echo "MUST PASS (exit 0 — nothing to report):"
t 0 "$tmp/good.sh"       'subject whose suite passes'
t 0 "$tmp/good.test.sh"  'the passing suite itself'
t 0 "$tmp/untested.sh"   'subject with no suite — silent, not an error'
t 0 "$tmp/missing.sh"    'file that does not exist'

echo "MUST BLOCK (exit 2 — edit broke a suite):"
t 2 "$tmp/bad.sh"        'subject whose suite fails'
t 2 "$tmp/bad.test.sh"   'the failing suite itself'

echo "NODE:TEST SUITES (.test.mjs that imports node:test):"
t 0 "$tmp/goodm.mjs"      'subject whose node:test suite passes'
t 0 "$tmp/goodm.test.mjs" 'the passing node:test suite itself'
t 2 "$tmp/badm.mjs"       'subject whose node:test suite fails'
t 2 "$tmp/badm.test.mjs"  'the failing node:test suite itself'
t 0 "$tmp/vit.mjs"        'a .test.mjs for another runner is left alone'
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/badm.mjs" | "$H" 2>&1 >/dev/null)
case "$out" in *case-77*) echo "  ✓ node:test failure names the case" ;;
               *) echo "  ✗ FAIL — node:test failure output missing the case"; fail=1 ;; esac

echo "WINDOWS-STYLE PATH — backslashes still find the sibling suite:"
phys=$(cd "$tmp" && pwd -P)
t 2 "${phys//\//\\\\}\\\\bad.sh"  'backslash path to a subject whose suite fails'

echo "FAILURE OUTPUT reaches Claude:"
out=$(printf '{"tool_input":{"file_path":"%s"}}' "$tmp/bad.sh" | "$H" 2>&1 >/dev/null)
for want in 'case-42' 'bad.test.sh' 'Do not leave it red'; do
  case "$out" in *"$want"*) echo "  ✓ stderr carries: $want" ;;
                 *) echo "  ✗ FAIL — stderr missing: $want"; fail=1 ;; esac
done

echo "DEGENERATE INPUT (never wedge the session):"
deg(){ printf '%s' "$2" | "$H" >/dev/null 2>&1; r=$?; if [ "$r" = 0 ]; then echo "  ✓ $1"; else echo "  ✗ FAIL (exit $r) — $1"; fail=1; fi; }
deg 'malformed json'      'not json at all'
deg 'empty payload'       ''
deg 'no file_path key'    '{"tool_input":{}}'
deg 'null tool_input'     '{"tool_input":null}'

echo "ESCAPE HATCH:"
TEST_ON_EDIT=off run "$tmp/bad.sh"; r=$?
if [ "$r" = 0 ]; then echo "  ✓ TEST_ON_EDIT=off skips a failing suite"; else echo "  ✗ FAIL (exit $r) — escape hatch"; fail=1; fi

echo "TOOL MISSING — python3 that does not run is reported, never a silent pass:"
assert_refuses_without "$H" block "$(path_with_store_python)" python3 \
  "{\"tool_input\":{\"file_path\":\"$tmp/bad.sh\"}}" 'python3 is the Windows Store stub'
assert_refuses_without "$H" block "$(path_without python3)" python3 \
  "{\"tool_input\":{\"file_path\":\"$tmp/bad.sh\"}}" 'no python3 on PATH'

exit "$fail"
