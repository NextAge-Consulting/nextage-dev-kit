#!/usr/bin/env bash
# Regression suite for codebuild-suite.sh, the full suite in CodeBuild: a pass is recorded
# against the code fingerprint, an earlier build's pass on the same fingerprint is carried
# forward (never this build's own), a failing suite records nothing, and integration tests
# that must run have run — development tests excepted. aws and npm are fakes answering
# from FAKE_*; the fingerprint is the real one.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$tmp/scripts" "$tmp/fake"
cp "$D/codebuild-suite.sh" "$D/code-fingerprint.mjs" "$tmp/scripts/"
cat > "$tmp/fake/aws" <<'AWS'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  *"list-builds-for-project"*)
    [ -n "${FAKE_LIST_FAIL:-}" ] && { echo "AccessDenied" >&2; exit 1; }
    printf '%s\n' "${FAKE_CB_IDS:-}" ;;
  *"batch-get-builds"*)
    # Only the builds asked for: FAKE_CB_PASSES lines are "<id><TAB><fp>".
    printf '%s\n' "${FAKE_CB_PASSES:-}" | while IFS=$'\t' read -r id fp; do
        case " $* " in *" $id "*) printf '%s\t%s\n' "$id" "$fp" ;; esac
    done ;;
esac
AWS
cat > "$tmp/fake/npm" <<'NPM'
#!/bin/bash
[ "$1" = test ] || exit 1
echo ran >> "$FAKE_LOG.npm"
printf '%s\n' "${FAKE_NPM_OUT:- ✓ |unit| a.test.ts}"
exit "${FAKE_NPM_RC:-0}"
NPM
chmod +x "$tmp/fake/"*
export FAKE_LOG="$tmp/calls" CODEBUILD_BUILD_ID="app-test:self"

git init -q "$tmp/work"; cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
mkdir -p .claude test
printf '{"name":"app","scripts":{"test":"vitest run"}}\n' > package.json
printf '{"DB_ENGINE":"PostgreSQL"}\n' > .claude/sync-substitutions.json
printf 'export const a = 1;\n' > a.ts
git add -A; git commit -qm base
# Under the fakes' PATH, as the script takes it.
fp=$(PATH="$tmp/fake:$PATH" node "$tmp/scripts/code-fingerprint.mjs" --commit HEAD 2>/dev/null)
suite(){ rm -f "$FAKE_LOG" "$FAKE_LOG.npm"; PATH="$tmp/fake:$PATH" bash "$tmp/scripts/codebuild-suite.sh" --out "$tmp/env" >"$tmp/out" 2>&1; echo $?; }
ran(){ [ -f "$FAKE_LOG.npm" ]; }

[ "$(suite)" = 0 ] && ran && grep -qx "FULL_SUITE_FP=$fp" "$tmp/env" && grep -qx "FULL_SUITE_FROM=" "$tmp/env" \
    && ok "no earlier build: the suite runs and the pass is recorded against the fingerprint" || bad "first run: $(cat "$tmp/out")"
[ "$(FAKE_CB_IDS=$'app-test:self\tapp-test:old\tapp-test:pass' FAKE_CB_PASSES=$'app-test:old\t0123456789abcdef0123456789abcdef\napp-test:pass\t'"$fp" suite)" = 0 ] \
    && ! ran && grep -qx "FULL_SUITE_FROM=app-test:pass" "$tmp/env" && grep -q "carried forward" "$tmp/out" \
    && grep -q "list-builds-for-project --project-name app-test" "$FAKE_LOG" \
    && ok "an earlier SUCCEEDED build on the same fingerprint is carried forward — the suite does not run" || bad "carry: $(cat "$tmp/out")"
[ "$(FAKE_CB_IDS=$'app-test:self' FAKE_CB_PASSES=$'app-test:self\t'"$fp" suite)" = 0 ] && ran \
    && ok "this build's own id is never its own earlier pass" || bad "self: $(cat "$tmp/out")"
[ "$(FAKE_LIST_FAIL=1 suite)" = 0 ] && ran && grep -q "could not list this project's builds" "$tmp/out" \
    && ok "builds that cannot be listed: says so, and the suite runs" || bad "list fails: $(cat "$tmp/out")"
[ "$(FAKE_NPM_RC=1 suite)" = 1 ] && grep -q "the full suite failed" "$tmp/out" && [ ! -s "$tmp/env" ] \
    && ok "a failing suite fails the build and records nothing" || bad "failing: $(cat "$tmp/out")"

printf 'x\n' > test/a.dev.integration.test.ts; git add -A; git commit -qm dev
[ "$(suite)" = 0 ] && grep -q "has no integration tests" "$tmp/out" \
    && ok "development integration tests alone: none must run" || bad "dev only: $(cat "$tmp/out")"
printf 'x\n' > test/a.integration.test.ts; git add -A; git commit -qm integration
[ "$(suite)" = 1 ] && grep -q "NEON_API_KEY or NEON_PROJECT_ID is empty in this build" "$tmp/out" && ! ran \
    && ok "PostgreSQL integration tests with no Neon keys in the build fail before the suite runs" || bad "no neon: $(cat "$tmp/out")"
export NEON_API_KEY=k NEON_PROJECT_ID=p
[ "$(suite)" = 1 ] && grep -q "integration project did not run" "$tmp/out" && [ ! -s "$tmp/env" ] \
    && ok "integration tests that did not run fail the build" || bad "not ran: $(cat "$tmp/out")"
[ "$(FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' suite)" = 0 ] && grep -q "The integration project ran." "$tmp/out" \
    && ok "integration tests that ran pass" || bad "ran: $(cat "$tmp/out")"
printf '{"DB_ENGINE":"PostgreSQL","INTEGRATION_CI_OFF":"no database reachable"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm off
[ "$(suite)" = 0 ] && grep -q "declared off in CI (INTEGRATION_CI_OFF): no database reachable" "$tmp/out" \
    && ok "INTEGRATION_CI_OFF stands the requirement down, quoting the reason" || bad "ci off: $(cat "$tmp/out")"
printf '{"name":"app"}\n' > package.json; git add -A; git commit -qm "no test"
[ "$(suite)" = 1 ] && grep -q 'declares no "test" script' "$tmp/out" \
    && ok "no test script: the build fails, saying so" || bad "no test script: $(cat "$tmp/out")"

exit "$fail"
