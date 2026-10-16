#!/usr/bin/env bash
# Regression suite for deploy.sh's gates: an org repo hands over to deploy-org.sh,
# an app release whose commits name `Needs <org-repo>#N` waits until that org PR is
# merged, and the full test suite passes — integration tests included — before
# anything ships. Runs --check-only under the github backend against a real origin;
# gh and npm are fakes answering from FAKE_*, and deploy-org.sh is a stub.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

bin="$tmp/scripts"; mkdir -p "$bin"
cp "$D/deploy.sh" "$D/issue_helpers.sh" "$D/repo_kind.sh" "$bin/"
printf '#!/bin/bash\necho "deploy-org ran: $*"\n' > "$bin/deploy-org.sh"
chmod +x "$bin"/*.sh

mkdir -p "$tmp/fake"
cat > "$tmp/fake/gh" <<'GH'
#!/bin/bash
case "$*" in
  "api repos/{owner}/{repo}/commits/"*) echo 0 ;;
  "api graphql "*"o=acme -f r=acme-org -F n=12 "*) echo "${FAKE_ORG_STATE:-merged}" ;;
  "api graphql "*) echo "GraphQL: Could not resolve to a Repository" >&2; exit 1 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/fake/gh"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
mkdir -p .claude
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: base"; git tag v1.0.0; git push -q origin main v1.0.0
run(){ PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --check-only >"$tmp/out" 2>&1; echo $?; }
land(){ printf '%s\n' "$RANDOM" > "f$RANDOM.txt"; git add -A; git commit -qm "$1"; git push -q origin main; }

land "✨ feat: uploads

Adds uploads."
[ "$(run)" = 0 ] && grep -q "infrastructure live" "$tmp/out" && ok "a release naming no org PR passes" || bad "no needs: $(cat "$tmp/out")"

land "✨ feat: avatars

Needs acme/acme-org#12"
[ "$(FAKE_ORG_STATE='PR open' run)" = 25 ] && grep -q "needs acme/acme-org#12 (PR open)" "$tmp/out" \
    && ok "an org PR still open stops the release, naming it" || bad "open needs: $(cat "$tmp/out")"
[ "$(FAKE_ORG_STATE='issue open, no merged PR yet' run)" = 25 ] && grep -q "(issue open, no merged PR yet)" "$tmp/out" \
    && ok "an org issue no merged PR closes yet stops the release" || bad "open issue: $(cat "$tmp/out")"
[ "$(FAKE_ORG_STATE=merged run)" = 0 ] && grep -q "needs acme/acme-org#12 — live" "$tmp/out" \
    && ok "once the org change is merged, the release passes" || bad "merged needs: $(cat "$tmp/out")"

land "🐛 fix: x

Needs acme/acme-org#99"
[ "$(run)" = 25 ] && grep -q "could not say whether it is live" "$tmp/out" \
    && ok "an org PR GitHub cannot read stops the release" || bad "unreadable needs: $(cat "$tmp/out")"

# ─── The test precheck: the full suite before anything ships ──────────────
cat > "$tmp/fake/npm" <<'NPM'
#!/bin/bash
echo "npm $*"
printf '%s\n' "${FAKE_NPM_OUT:-}"
exit "${FAKE_NPM_RC:-0}"
NPM
chmod +x "$tmp/fake/npm"
git tag v1.0.1; git push -q origin v1.0.1
land "✨ feat: before tests"
[ "$(run)" = 0 ] && grep -q "declares no test suite" "$tmp/out" && ok "no package.json test script and no pyproject: passes, saying so" || bad "no suite: $(cat "$tmp/out")"
printf '{"name":"app","scripts":{"test":"vitest run"}}\n' > package.json
land "✨ feat: tests"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 0 ] && grep -q "the suite passes" "$tmp/out" \
    && ok "a passing suite passes" || bad "suite passes: $(cat "$tmp/out")"
[ "$(FAKE_NPM_RC=1 FAKE_NPM_OUT='FAIL a.test.ts' run)" = 26 ] && grep -q "FAIL a.test.ts" "$tmp/out" && grep -q "nothing was bumped" "$tmp/out" \
    && ok "a failing suite stops the release with 26, showing the failure" || bad "suite fails: $(cat "$tmp/out")"
mkdir -p test; printf 'x\n' > test/a.integration.test.ts
land "✅ test: integration"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 26 ] && grep -q "integration project did not run" "$tmp/out" \
    && ok "integration tests that did not run stop the release" || bad "integration skipped: $(cat "$tmp/out")"
[ "$(FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 0 ] \
    && ok "integration tests that ran pass" || bad "integration ran: $(cat "$tmp/out")"
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml","DB_ENGINE":"None"}\n' > .claude/sync-substitutions.json
land "🔧 chore: no database"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 0 ] \
    && ok "with DB_ENGINE None, the unit suite alone passes" || bad "no database: $(cat "$tmp/out")"
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml","INTEGRATION_DEPLOY_OFF":"deploys run with no database access"}\n' > .claude/sync-substitutions.json
land "🔧 chore: deploy off"
[ "$(FAKE_NPM_RC=1 run)" = 0 ] && grep -q "declared off at deploy (INTEGRATION_DEPLOY_OFF) — deploys run with no database access" "$tmp/out" \
    && ok "INTEGRATION_DEPLOY_OFF skips the suite, quoting the reason" || bad "deploy off: $(cat "$tmp/out")"
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml"}\n' > .claude/sync-substitutions.json
git rm -q package.json
land "🔧 chore: no test script"
[ "$(run)" = 26 ] && grep -q 'declares no "test" script' "$tmp/out" \
    && ok "integration tests with no test script stop the release" || bad "no test script: $(cat "$tmp/out")"
git rm -rq test; land "🔧 chore: drop tests"

git checkout -q -b infra/x
printf '{"REPO_KIND":"org"}\n' > .claude/sync-substitutions.json
out=$(PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --level patch 2>&1)
[ "$out" = "deploy-org ran: --level patch" ] && ok "an org repo hands /deploy to deploy-org.sh, arguments intact" || bad "org handoff: $out"

# ─── Combo: the branch decides which half /deploy runs ────────────────────
printf '{"REPO_KIND":"combo"}\n' > .claude/sync-substitutions.json
out=$(PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --level patch 2>&1)
[ "$out" = "deploy-org ran: --level patch" ] && ok "combo on a PR branch: /deploy applies the infrastructure (deploy-org.sh)" || bad "combo branch: $out"
git checkout -q -- .claude/sync-substitutions.json 2>/dev/null; git checkout -q main
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml","REPO_KIND":"combo"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: combo"; git tag v1.1.0; git push -q origin main v1.1.0
land "✨ feat: combo app"
[ "$(run)" = 0 ] && ! grep -q "deploy-org ran" "$tmp/out" && grep -q "state gates OK" "$tmp/out" \
    && ok "combo on main: /deploy releases the app, through the app's own gates" || bad "combo main: $(cat "$tmp/out")"

exit "$fail"
