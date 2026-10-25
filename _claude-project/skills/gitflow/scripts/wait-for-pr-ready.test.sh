#!/usr/bin/env bash
# Test suite for wait-for-pr-ready.sh's full-suite requirement: under TEST_RUNNER=aws the
# PR is not ready until CodeBuild's `full-suite` status exists on it and has passed, even
# when every GitHub check is green. With --timeout-min 0 the wait polls once and then
# times out (exit 3), which is how "still pending" shows here. gh is a fake answering the
# PR's check rollup from FAKE_ROLLUP.
set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wait-for-pr-ready.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q -b main "$tmp/repo"
cd "$tmp/repo" || exit 1
mkdir -p .claude

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  "repo view"*) echo acme/app ;;
  *"--json headRefOid"*) echo 0123456789abcdef0123456789abcdef01234567 ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$FAKE_ROLLUP" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"

subs(){ printf '%s\n' "$1" > .claude/sync-substitutions.json; }
wait_pr(){ PATH="$tmp/bin:$PATH" FAKE_ROLLUP="$1" "$W" --pr 7 --timeout-min 0 --poll-sec 1 >"$tmp/out" 2>&1; }

GREEN_CI='[{"__typename":"CheckRun","name":"node-checks","status":"COMPLETED","conclusion":"SUCCESS"}]'
WITH_SUITE='[{"__typename":"CheckRun","name":"node-checks","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"full-suite","state":"SUCCESS"}]'
SUITE_PENDING='[{"__typename":"CheckRun","name":"node-checks","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"StatusContext","context":"full-suite","state":"PENDING"}]'

subs '{"GEMINI_NOT_INSTALLED":"true","TEST_RUNNER":"aws"}'
wait_pr "$GREEN_CI"; rc=$?
[ "$rc" -eq 3 ] && ok "aws: green GitHub checks without the full-suite status are not ready" || bad "aws no status (rc=$rc): $(cat "$tmp/out")"
wait_pr "$WITH_SUITE"; rc=$?
[ "$rc" -eq 0 ] && ok "aws: the full-suite status passed — ready" || bad "aws with status (rc=$rc): $(cat "$tmp/out")"
wait_pr "$SUITE_PENDING"; rc=$?
[ "$rc" -eq 3 ] && ok "aws: a pending full-suite status is not ready" || bad "aws pending (rc=$rc): $(cat "$tmp/out")"
wait_pr '[]'; rc=$?
[ "$rc" -eq 3 ] && ok "aws: no checks at all is not ready" || bad "aws empty (rc=$rc): $(cat "$tmp/out")"

subs '{"GEMINI_NOT_INSTALLED":"true"}'
wait_pr "$GREEN_CI"; rc=$?
[ "$rc" -eq 0 ] && ok "github (default): green checks are ready without a separate status" || bad "github (rc=$rc): $(cat "$tmp/out")"

subs '{"GEMINI_NOT_INSTALLED":"true","TEST_RUNNER":"codebuild"}'
wait_pr "$WITH_SUITE"; rc=$?
{ [ "$rc" -eq 4 ] && grep -q "TEST_RUNNER" "$tmp/out"; } \
    && ok "an invalid TEST_RUNNER stops the wait, naming it" || bad "invalid runner (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
