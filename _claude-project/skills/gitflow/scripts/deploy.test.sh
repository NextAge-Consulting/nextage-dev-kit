#!/usr/bin/env bash
# Regression suite for deploy.sh's gates: an org repo hands over to deploy-org.sh,
# an app release whose commits name `Needs <org-repo>#N` waits until that org PR is
# merged, the integration preflight passes first, and the full test suite passes —
# integration tests included — before anything ships, unless that exact code already
# has a full-suite pass recorded — on GitHub, or in CodeBuild under TEST_RUNNER=aws, where
# the suite also runs when there is none — and the strict assurance level refuses without
# one. Runs --check-only under the github backend against a real origin;
# gh, npm and aws are fakes answering from FAKE_*, and deploy-org.sh is a stub.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

bin="$tmp/scripts"; mkdir -p "$bin"
cp "$D/deploy.sh" "$D/issue_helpers.sh" "$D/repo_kind.sh" "$D/gates.sh" "$D/code-fingerprint.mjs" "$D/settings.sh" "$bin/"
printf '#!/bin/bash\necho "deploy-org ran: $*"\n' > "$bin/deploy-org.sh"
chmod +x "$bin"/*.sh

mkdir -p "$tmp/fake"
cat > "$tmp/fake/gh" <<'GH'
#!/bin/bash
# A commit's statuses: FAKE_STATUS_DESC is the full-suite success on FAKE_STATUS_SHA.
# A commit's merged PRs: FAKE_PR_HEAD is the head of the PR that FAKE_PR_FOR merged.
sha=${2#repos/\{owner\}/\{repo\}/commits/}; sha=${sha%%/*}
case "$*" in
  "api repos/{owner}/{repo}/commits/"*"/status "*)
    [ -n "${FAKE_STATUS_FAIL:-}" ] && { echo "HTTP 502" >&2; exit 1; }
    [ "$sha" = "${FAKE_STATUS_SHA:-}" ] && printf '%s\n' "$FAKE_STATUS_DESC"
    exit 0 ;;
  "api repos/{owner}/{repo}/commits/"*"/pulls "*)
    [ "$sha" = "${FAKE_PR_FOR:-}" ] && printf '%s\n' "$FAKE_PR_HEAD"
    exit 0 ;;
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
# Like vitest, the fake prints each project label as a coloured badge unless NO_COLOR is
# set — a captured run is coloured too, whatever FORCE_COLOR says.
cat > "$tmp/fake/npm" <<'NPM'
#!/bin/bash
echo "npm $*"
case "$*" in *test:preflight*) printf '%s\n' "${FAKE_PREFLIGHT_OUT:-}"; exit "${FAKE_PREFLIGHT_RC:-0}" ;; esac
if [ -n "${NO_COLOR+set}" ]; then
    printf '%s\n' "${FAKE_NPM_OUT:-}"
else
    printf '%s\n' "${FAKE_NPM_OUT:-}" | sed -E $'s/\\|([a-z]+)\\|/\033[45m \\1 \033[49m/g'
fi
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
mkdir -p test; printf 'x\n' > test/a.dev.integration.test.ts
land "✅ test: a development test"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 0 ] \
    && ok "development integration tests alone are not in the full suite, so none must run" || bad "dev only: $(cat "$tmp/out")"
git rm -q test/a.dev.integration.test.ts; mkdir -p test; printf 'x\n' > test/a.integration.test.ts
land "✅ test: integration"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 26 ] && grep -q "integration project did not run" "$tmp/out" \
    && ok "integration tests that did not run stop the release" || bad "integration skipped: $(cat "$tmp/out")"
[ "$(FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 0 ] \
    && ok "integration tests that ran pass" || bad "integration ran: $(cat "$tmp/out")"
[ "$(FORCE_COLOR=3 FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 0 ] \
    && ok "integration tests that ran pass under FORCE_COLOR, as in a Claude Code session" || bad "integration under FORCE_COLOR: $(cat "$tmp/out")"
printf '{"name":"app","scripts":{"test":"vitest run","test:preflight":"check"}}\n' > package.json
land "✅ test: preflight"
[ "$(FAKE_PREFLIGHT_RC=1 FAKE_PREFLIGHT_OUT='the database lacks migration 0007_add_notes' run)" = 26 ] \
    && grep -q "lacks migration 0007_add_notes" "$tmp/out" && grep -q "database is not ready. Fix before deploying" "$tmp/out" \
    && ! grep -q "running npm test" "$tmp/out" \
    && ok "a failing preflight stops the release with 26 before the suite runs, showing why" || bad "preflight fails: $(cat "$tmp/out")"
[ "$(FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 0 ] && grep -q "integration tests' database is ready" "$tmp/out" \
    && ok "a passing preflight passes" || bad "preflight passes: $(cat "$tmp/out")"

# ─── The full suite already passed on this exact code ─────────────────────
# npm test and the preflight both fail if they run, so a pass shows neither ran. The
# fingerprint is taken as deploy.sh takes it, under the same PATH.
head=$(git rev-parse HEAD)
fpof(){ PATH="$tmp/fake:$PATH" node "$bin/code-fingerprint.mjs" --commit HEAD 2>/dev/null; }
fp=$(fpof)
[ "$(FAKE_STATUS_SHA=$head FAKE_STATUS_DESC="fp $fp" FAKE_NPM_RC=1 FAKE_PREFLIGHT_RC=1 run)" = 0 ] \
    && grep -q "trusting $head (fp $fp); not run again" "$tmp/out" && ! grep -q "running npm test" "$tmp/out" \
    && grep -q "preflight: not needed" "$tmp/out" \
    && ok "a full-suite pass on HEAD's exact code: neither the suite nor the preflight runs, and it names the commit" || bad "pass on HEAD: $(cat "$tmp/out")"
[ "$(FAKE_STATUS_SHA=$head FAKE_STATUS_DESC="fp 0123456789abcdef0123456789abcdef" FAKE_NPM_RC=1 run)" = 26 ] \
    && grep -q "running npm test" "$tmp/out" && grep -q "no pass on this exact code" "$tmp/out" \
    && ok "a pass on other code: the suite runs" || bad "other fingerprint: $(cat "$tmp/out")"
[ "$(FAKE_STATUS_SHA=$head FAKE_STATUS_DESC="carried forward from abc · fp $fp" FAKE_NPM_RC=1 run)" = 0 ] \
    && ok "a carried-forward pass is a pass" || bad "carried forward: $(cat "$tmp/out")"
# TypeScript linked into the repository, so the fingerprint reads code and leaves comments out.
prhead=1111111111111111111111111111111111111111
TS_DIR="$(npm root -g 2>/dev/null)/typescript"
[ -d "$TS_DIR" ] || bad "this case needs TypeScript installed globally (npm i -g typescript)"
printf 'node_modules/\n' > .gitignore; mkdir -p node_modules; ln -s "$TS_DIR" node_modules/typescript
printf '// a comment only\nexport const z = 1;\n' > z.ts; git add -A; git commit -qm "✨ feat: z"; git push -q origin main
fp_z=$(fpof)
merged=$(git rev-parse HEAD)
printf '// a reworded comment\nexport const z =   1;\n' > z.ts; git add -A; git commit -qm "📚 docs: z"; git push -q origin main
[ "$(FAKE_PR_FOR=$merged FAKE_PR_HEAD=$prhead FAKE_STATUS_SHA=$prhead FAKE_STATUS_DESC="fp $fp_z" FAKE_NPM_RC=1 FAKE_PREFLIGHT_RC=1 run)" = 0 ] \
    && grep -q "trusting $prhead (fp $fp_z)" "$tmp/out" \
    && ok "a pass on the head of a PR merged since the release, whose code main still has but for comments, is trusted" \
    || bad "PR head pass: $(cat "$tmp/out")"
[ "$(FAKE_STATUS_FAIL=1 FAKE_STATUS_SHA=$head FAKE_STATUS_DESC="fp $fp" FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 0 ] \
    && grep -q "could not read the statuses" "$tmp/out" && grep -q "running npm test" "$tmp/out" \
    && ok "GitHub unreadable: says so, and the suite runs" || bad "statuses unreadable: $(cat "$tmp/out")"

# ─── ASSURANCE_LEVEL=strict: a recorded pass, or no deploy ────────────────
subs(){ printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml"%s}\n' "$1" > .claude/sync-substitutions.json; land "🔧 chore: settings"; }
subs ',"ASSURANCE_LEVEL":"strict"'
head=$(git rev-parse HEAD); fp=$(fpof)
[ "$(FAKE_NPM_OUT=' ✓ |integration| test/a.integration.test.ts' run)" = 26 ] && grep -q "does not run the suite on this machine" "$tmp/out" \
    && ! grep -q "running npm test" "$tmp/out" && ! grep -q "npm run" "$tmp/out" \
    && ok "strict: no recorded pass refuses (26) — no local run, no preflight" || bad "strict no pass: $(cat "$tmp/out")"
[ "$(FAKE_STATUS_SHA=$head FAKE_STATUS_DESC="fp $fp" FAKE_NPM_RC=1 run)" = 0 ] && grep -q "trusting $head" "$tmp/out" \
    && ok "strict: a recorded pass on this exact code deploys" || bad "strict pass: $(cat "$tmp/out")"
subs ',"ASSURANCE_LEVEL":"strict","INTEGRATION_DEPLOY_OFF":"no database here"'
[ "$(run)" = 26 ] && grep -q "does not run the suite on this machine" "$tmp/out" \
    && ok "strict: INTEGRATION_DEPLOY_OFF does not excuse the missing record" || bad "strict deploy off: $(cat "$tmp/out")"
subs ',"ASSURANCE_LEVEL":"high"'
[ "$(run)" = 2 ] && grep -q "ASSURANCE_LEVEL is 'high' in .claude/sync-substitutions.json" "$tmp/out" \
    && ok "an invalid ASSURANCE_LEVEL stops /deploy (2), naming the key and the file" || bad "invalid level: $(cat "$tmp/out")"

# ─── TEST_RUNNER=aws: the full suite in CodeBuild ─────────────────────────
# aws is a fake answering from FAKE_CB_*: the test project's builds (ids, then the
# successful ones with their FULL_SUITE_FP), a started build and its result.
cat > "$tmp/fake/aws" <<'AWS'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_AWS_LOG"
case "$*" in
  *"sts get-caller-identity"*) exit 0 ;;
  *"codebuild list-builds-for-project"*) printf '%s\n' "${FAKE_CB_IDS:-}" ;;
  *"codebuild batch-get-builds"*FULL_SUITE_FP*) printf '%s\n' "${FAKE_CB_PASSES:-}" ;;
  *"codebuild batch-get-builds"*) printf 'app-deploy-test:new\t%s\n' "${FAKE_CB_RESULT:-SUCCEEDED}" ;;
  *"codebuild start-build"*) echo "app-deploy-test:new" ;;
  *) exit 0 ;;
esac
AWS
chmod +x "$tmp/fake/aws"
export FAKE_AWS_LOG="$tmp/aws.log"
printf 'node_modules/\n.env\n' > .gitignore
aws_subs=',"TEST_RUNNER":"aws","CODEBUILD_PROJECT_PREFIX":"app-deploy-","AWS_REGION":"us-east-1"'
subs "$aws_subs"
head=$(git rev-parse HEAD); fp=$(fpof)
[ "$(run)" = 21 ] && grep -q "DEPLOY_AWS_ACCESS_KEY_ID / DEPLOY_AWS_SECRET_ACCESS_KEY not set in .env (TEST_RUNNER=aws)" "$tmp/out" \
    && ok "aws: without the deploy key in .env, /deploy stops (21)" || bad "aws no key: $(cat "$tmp/out")"
printf 'DEPLOY_AWS_ACCESS_KEY_ID=test-key-id\nDEPLOY_AWS_SECRET_ACCESS_KEY=test-secret\n' > .env
: > "$FAKE_AWS_LOG"
[ "$(FAKE_CB_IDS=$'app-deploy-test:old\tapp-deploy-test:pass' FAKE_CB_PASSES=$'app-deploy-test:pass\t'"$fp" FAKE_NPM_RC=1 FAKE_PREFLIGHT_RC=1 run)" = 0 ] \
    && grep -q "trusting CodeBuild app-deploy-test:pass (fp $fp)" "$tmp/out" && ! grep -q "start-build" "$FAKE_AWS_LOG" \
    && grep -q "list-builds-for-project --project-name app-deploy-test" "$FAKE_AWS_LOG" \
    && ok "aws: a successful test build carrying HEAD's fingerprint is trusted — nothing runs" || bad "aws pass: $(cat "$tmp/out"; cat "$FAKE_AWS_LOG")"
: > "$FAKE_AWS_LOG"
[ "$(FAKE_CB_IDS=app-deploy-test:old FAKE_CB_PASSES=$'app-deploy-test:old\t0123456789abcdef0123456789abcdef' FAKE_NPM_RC=1 FAKE_PREFLIGHT_RC=1 run)" = 0 ] \
    && grep -q "start-build --project-name app-deploy-test --source-version $head" "$FAKE_AWS_LOG" \
    && grep -q "the suite passes in CodeBuild (app-deploy-test:new)" "$tmp/out" && ! grep -q "running npm test" "$tmp/out" \
    && grep -q "preflight: not needed — the full suite runs in CodeBuild" "$tmp/out" \
    && ok "aws: no pass on this code starts the test project on HEAD and waits — no local run, no preflight" || bad "aws run: $(cat "$tmp/out"; cat "$FAKE_AWS_LOG")"
[ "$(FAKE_CB_RESULT=FAILED run)" = 26 ] && grep -q "did not pass in CodeBuild (app-deploy-test:new: FAILED)" "$tmp/out" \
    && ok "aws: a failed test build stops the release (26)" || bad "aws failed: $(cat "$tmp/out")"
subs "$aws_subs"',"ASSURANCE_LEVEL":"strict"'
: > "$FAKE_AWS_LOG"
[ "$(FAKE_NPM_RC=1 run)" = 0 ] && grep -q "start-build" "$FAKE_AWS_LOG" \
    && ok "aws, strict: with no record, CodeBuild records one on HEAD and the release goes on" || bad "aws strict: $(cat "$tmp/out")"
subs "$aws_subs"',"INTEGRATION_DEPLOY_OFF":"deploys cannot reach the database"'
: > "$FAKE_AWS_LOG"
[ "$(FAKE_NPM_RC=1 run)" = 0 ] && grep -q "declared off at deploy (INTEGRATION_DEPLOY_OFF)" "$tmp/out" && ! grep -q "start-build" "$FAKE_AWS_LOG" \
    && ok "aws, assist: INTEGRATION_DEPLOY_OFF still turns the run off" || bad "aws deploy off: $(cat "$tmp/out")"
subs ',"TEST_RUNNER":"aws","AWS_REGION":"us-east-1"'
[ "$(run)" = 2 ] && grep -q "TEST_RUNNER=aws requires CODEBUILD_PROJECT_PREFIX and AWS_REGION" "$tmp/out" \
    && ok "aws without CODEBUILD_PROJECT_PREFIX stops /deploy (2)" || bad "aws no prefix: $(cat "$tmp/out")"
# The developer's .env overrides the project, and an invalid value names .env.
subs ',"CODEBUILD_PROJECT_PREFIX":"app-deploy-","AWS_REGION":"us-east-1"'
printf 'TEST_RUNNER=aws\n' >> .env
: > "$FAKE_AWS_LOG"
[ "$(FAKE_NPM_RC=1 run)" = 0 ] && grep -q "start-build --project-name app-deploy-test" "$FAKE_AWS_LOG" \
    && ok "TEST_RUNNER=aws in .env sends the suite to CodeBuild for this developer" || bad "env layer: $(cat "$tmp/out")"
printf 'TEST_RUNNER=cloud\n' >> .env
[ "$(run)" = 2 ] && grep -q "TEST_RUNNER is 'cloud' in .env" "$tmp/out" \
    && ok "an invalid TEST_RUNNER in .env stops /deploy (2), naming the key and .env" || bad "env invalid: $(cat "$tmp/out")"
rm -f .env; printf 'node_modules/\n' > .gitignore
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml","DB_ENGINE":"None"}\n' > .claude/sync-substitutions.json
land "🔧 chore: no database"
[ "$(FAKE_NPM_OUT=' ✓ |unit| a.test.ts' run)" = 0 ] \
    && ok "with DB_ENGINE None, the unit suite alone passes" || bad "no database: $(cat "$tmp/out")"
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml","INTEGRATION_DEPLOY_OFF":"deploys run with no database access"}\n' > .claude/sync-substitutions.json
land "🔧 chore: deploy off"
[ "$(FAKE_NPM_RC=1 FAKE_PREFLIGHT_RC=1 run)" = 0 ] && grep -q "declared off at deploy (INTEGRATION_DEPLOY_OFF) — deploys run with no database access" "$tmp/out" \
    && grep -q "preflight: declared off (INTEGRATION_DEPLOY_OFF)" "$tmp/out" \
    && ok "INTEGRATION_DEPLOY_OFF skips the preflight and the suite, quoting the reason" || bad "deploy off: $(cat "$tmp/out")"
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

# ─── A worktree kept to deploy from: detached exactly at origin/main ──────
git checkout -q --detach origin/main
[ "$(run)" = 0 ] && ! grep -q "deploy-org ran" "$tmp/out" && grep -q "state gates OK" "$tmp/out" \
    && ok "detached at origin/main passes the gates as main (combo: the app half)" || bad "detached at origin/main: $(cat "$tmp/out")"
git checkout -q main
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml"}\n' > .claude/sync-substitutions.json
printf '{"name":"app","version":"3.0.0"}\n' > package.json
land "🔧 chore: app only"
land "✨ feat: one more"
git checkout -q --detach HEAD~1
[ "$(run)" = 3 ] && grep -q "detached HEAD that is not origin/main" "$tmp/out" \
    && ok "detached anywhere but origin/main stops at the branch gate (3)" || bad "detached elsewhere: $(cat "$tmp/out")"
git checkout -q --detach origin/main
printf '### Added\n- a thing\n' > "$tmp/notes.md"
PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --level patch --changelog-file "$tmp/notes.md" --no-watch >"$tmp/out" 2>&1; rc=$?
rel=$(git log -1 --format=%s origin/main)
{ [ "$rc" -eq 0 ] && [ "$(git rev-parse origin/main)" = "$(git rev-parse HEAD)" ] && [ "${rel#🚀 release: v}" != "$rel" ] \
  && git ls-remote --exit-code --tags origin "${rel#🚀 release: }" >/dev/null; } \
    && ok "a release from detached origin/main pushes the bump to main, and its tag" || bad "detached release (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
