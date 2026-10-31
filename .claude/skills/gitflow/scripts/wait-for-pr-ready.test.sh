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

# ─── A CI failure forks off the review cycle; --review-only rejoins it ────
# This gh answers the Gemini lookups from fixture files, applying the --jq the script
# passes, so the review states are the real filters' answers.
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$tmp/bin2" "$tmp/fx"
cat > "$tmp/bin2/gh" <<'GH'
#!/bin/bash
q=""; prev=""; for a in "$@"; do [ "$prev" = "--jq" ] && q="$a"; prev="$a"; done
case "$*" in
  "repo view"*) echo acme/app; exit 0 ;;
  *"--json headRefOid"*) echo "$HEAD_SHA"; exit 0 ;;
  *"--json statusCheckRollup"*) printf '%s\n' "$FAKE_ROLLUP"; exit 0 ;;
  "api repos/acme/app/commits/"*) f="$FX/commit.json" ;;
  "api repos/acme/app/issues/7/comments"*) f="$FX/issue-comments.json" ;;
  "api repos/acme/app/pulls/7/reviews"*) f="$FX/reviews.json" ;;
  "api repos/acme/app/pulls/7/comments"*) f="$FX/inline.json" ;;
  *) exit 0 ;;
esac
if [ -n "$q" ]; then jq -r "$q" "$f"; else cat "$f"; fi
GH
chmod +x "$tmp/bin2/gh"
printf '{"commit":{"committer":{"date":"2026-10-30T10:00:00Z"}}}\n' > "$tmp/fx/commit.json"
TRIGGER='[{"body":"/gemini review","created_at":"2026-10-30T10:05:00Z","user":{"login":"dev"}}]'
REVIEWED="[{\"user\":{\"login\":\"gemini-code-assist[bot]\"},\"commit_id\":\"$HEAD_SHA\"}]"
TWO_FINDINGS="[{\"user\":{\"login\":\"gemini-code-assist[bot]\"},\"original_commit_id\":\"$HEAD_SHA\"},{\"user\":{\"login\":\"gemini-code-assist[bot]\"},\"original_commit_id\":\"$HEAD_SHA\"}]"
RED_CI='[{"__typename":"CheckRun","name":"node-checks","status":"COMPLETED","conclusion":"FAILURE"}]'
fx(){ printf '%s\n' "$1" > "$tmp/fx/issue-comments.json"; printf '%s\n' "$2" > "$tmp/fx/reviews.json"; printf '%s\n' "$3" > "$tmp/fx/inline.json"; }
wait2(){ PATH="$tmp/bin2:$PATH" FX="$tmp/fx" HEAD_SHA="$HEAD_SHA" FAKE_ROLLUP="$1" "$W" --pr 7 --timeout-min 0 --poll-sec 1 "${@:2}" >"$tmp/out" 2>&1; }

subs '{}'
fx "$TRIGGER" '[]' '[]'
wait2 "$RED_CI"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'still due' "$tmp/out" && grep -q -- '--review-only' "$tmp/out"; } \
    && ok "CI failed, review still due: exits at once and names the way back" || bad "fork (rc=$rc): $(cat "$tmp/out")"
fx "$TRIGGER" "$REVIEWED" "$TWO_FINDINGS"
wait2 "$RED_CI"; rc=$?
{ [ "$rc" -eq 2 ] && grep -q 'Run /triage' "$tmp/out"; } \
    && ok "CI failed, review in: points at /triage for both" || bad "fork review in (rc=$rc): $(cat "$tmp/out")"
fx '[]' '[]' '[]'
wait2 "$RED_CI"; rc=$?
{ [ "$rc" -eq 2 ] && ! grep -q 'Gemini' "$tmp/out"; } \
    && ok "CI failed, no review asked for: the failure alone" || bad "no trigger (rc=$rc): $(cat "$tmp/out")"

fx "$TRIGGER" '[]' '[]'
wait2 "$RED_CI" --review-only; rc=$?
[ "$rc" -eq 3 ] && ok "--review-only: ignores the red CI and keeps waiting for the review" || bad "rejoin pending (rc=$rc): $(cat "$tmp/out")"
fx "$TRIGGER" "$REVIEWED" "$TWO_FINDINGS"
wait2 "$RED_CI" --review-only; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'findings=2' "$tmp/out" && grep -q 'carries the fix in the tree' "$tmp/out"; } \
    && ok "--review-only: review in with findings hands to /triage" || bad "rejoin findings (rc=$rc): $(cat "$tmp/out")"
fx "$TRIGGER" "$REVIEWED" '[]'
wait2 "$RED_CI" --review-only; rc=$?
{ [ "$rc" -eq 0 ] && grep -q 'Commit the fix' "$tmp/out"; } \
    && ok "--review-only: a clean review hands to /commit" || bad "rejoin clean (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
