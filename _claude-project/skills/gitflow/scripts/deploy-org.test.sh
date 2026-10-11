#!/usr/bin/env bash
# Regression suite for deploy-org.sh. The real changed-roots.sh and plan-summary.sh
# run; tf.sh, gen-reference.sh, wait-for-pr-ready.sh, merge.sh, gh and terraform are
# stubs, so nothing reaches AWS or GitHub. The contract: nothing is applied unless
# CI is green and every root's fresh plan matches the PR's, and nothing is merged
# unless every apply succeeded.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFS="$D/../../terraform/scripts"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

bin="$tmp/scripts"; mkdir -p "$bin"
cp "$D/deploy-org.sh" "$D/repo_kind.sh" "$bin/"
printf '#!/bin/bash\necho wait >> "%s/calls"; exit "${FAKE_CI:-0}"\n' "$tmp" > "$bin/wait-for-pr-ready.sh"
# merge.sh stub: a successful merge leaves the checkout on main at origin's tip, as
# merge.sh does; where it stood is saved so back() can undo the run.
cat > "$bin/merge.sh" <<STUB
#!/bin/bash
echo "merge GITFLOW_ORG_DEPLOY=\$GITFLOW_ORG_DEPLOY \$*" >> "$tmp/calls"
[ "\${FAKE_MERGE:-0}" = 0 ] || exit "\$FAKE_MERGE"
git branch --show-current > "$tmp/was.branch"; git rev-parse origin/main > "$tmp/was.main"
git checkout -q main && git merge -q --ff-only origin/main
STUB
printf '#!/bin/bash\necho "release $*" >> "%s/calls"\n' "$tmp" > "$bin/deploy.sh"
printf 'move_issue_to_deployed() { echo "board deployed $1" >> "%s/calls"; }\n' "$tmp" > "$bin/issue_helpers.sh"
chmod +x "$bin"/*.sh

mkdir -p "$tmp/fake"
printf '#!/bin/bash\nexit 0\n' > "$tmp/fake/terraform"
printf '#!/bin/bash\nexit 0\n' > "$tmp/fake/dot"
cat > "$tmp/fake/gh" <<'GH'
#!/bin/bash
case "$*" in
  "pr list --head "*) [ -n "${FAKE_NO_PR:-}" ] && exit 0; jq -nc --rawfile b "$FAKE_BODY" '{number: 5, body: $b, baseRefName: "main"}' ;;
  "pr view 5 --json reviewDecision"*) echo "${FAKE_REVIEW:-}" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/fake/terraform" "$tmp/fake/dot" "$tmp/fake/gh"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
mkdir -p .claude/skills/terraform/scripts infra/terraform/shared infra/terraform/projects/web/prod
cp "$TFS/changed-roots.sh" "$TFS/plan-summary.sh" .claude/skills/terraform/scripts/
# tf.sh stub: a plan's resource changes come from $FAKE_PLAN_<root with / as _>.
cat > .claude/skills/terraform/scripts/tf.sh <<STUB
#!/bin/bash
root="\$1"; shift; key="\${root//\//_}"
case "\$1" in
  init) exit 0 ;;
  plan) echo "plan \$root" >> "$tmp/calls"; exit 0 ;;
  show) var="FAKE_PLAN_\$key"; printf '{"resource_changes":%s}' "\${!var:-[]}" ;;
  apply) echo "apply \$root" >> "$tmp/calls"; [ "\$root" = "\${FAKE_FAIL_APPLY:-}" ] && exit 1; exit 0 ;;
esac
STUB
printf '#!/bin/bash\n[ -n "${FAKE_REF_FAIL:-}" ] && exit 1\nmkdir -p project-documentation; echo $RANDOM$RANDOM > project-documentation/infrastructure-reference.md\n' > .claude/skills/terraform/scripts/gen-reference.sh
chmod +x .claude/skills/terraform/scripts/*.sh
for r in shared projects/web/prod; do printf 'terraform {}\n' > "infra/terraform/$r/main.tf"; touch "infra/terraform/$r/.terraform.lock.hcl"; done
printf '*.tfplan\n' > .gitignore
printf '{"REPO_KIND":"org"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm base; git push -q origin main
git checkout -q -b infra/bucket
printf 'resource "aws_s3_bucket" "b" {}\n' >> infra/terraform/projects/web/prod/main.tf
git add -A; git commit -qm "feat: bucket"; git push -q -u origin infra/bucket 2>/dev/null

export FAKE_BODY="$tmp/body.md"
printf 'Closes #7\n\nAdds a bucket.\n\n<!-- plan:projects/web/prod -->\n```text\ncreate aws_s3_bucket.b\n```\n<!-- /plan:projects/web/prod -->\n' > "$FAKE_BODY"
export FAKE_PLAN_projects_web_prod='[{"address":"aws_s3_bucket.b","change":{"actions":["create"]}}]'
run(){ : > "$tmp/calls"; PATH="$tmp/fake:$PATH" bash "$bin/deploy-org.sh" "$@" >"$tmp/out" 2>&1; echo $?; }
called(){ grep -qx -- "$1" "$tmp/calls"; }
# Undo a run that merged: origin's main and the checkout go back to where they were.
back(){ git push -qf origin "$(cat "$tmp/was.main"):main"; git checkout -q "$(cat "$tmp/was.branch")"; git branch -qf main "$(cat "$tmp/was.main")"; }

[ "$(FAKE_NO_PR=1 run)" = 9 ] && ok "no open PR: refused" || bad "no PR: $(cat "$tmp/out")"
[ "$(FAKE_CI=2 run)" = 11 ] && ! grep -q '^plan' "$tmp/calls" && ok "CI not green: refused before any plan" || bad "CI red: $(cat "$tmp/calls"; cat "$tmp/out")"

[ "$(FAKE_PLAN_projects_web_prod='[{"address":"aws_s3_bucket.b","change":{"actions":["create"]}},{"address":"aws_instance.s","change":{"actions":["delete"]}}]' run)" = 26 ] \
    && ! grep -q '^apply' "$tmp/calls" && grep -q "plan now:  delete aws_instance.s" "$tmp/out" \
    && ok "a fresh plan doing more than the PR shows: refused, nothing applied, the difference named" || bad "mismatch: $(cat "$tmp/out")"

rc=$(run)
{ [ "$rc" = 0 ] && called "plan projects/web/prod" && called "apply projects/web/prod" && ! grep -q "apply shared" "$tmp/calls" \
  && called "merge GITFLOW_ORG_DEPLOY=1 --pr 5 --base main"; } \
    && ok "a matching plan: only the changed root applied, then merged through /deploy's door" || bad "happy path (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
called "board deployed 7" && ok "…and the issue it closes moves to the deploy status" || bad "board move: $(cat "$tmp/calls")"
git fetch -q origin
{ git log -1 --pretty=%s origin/main | grep -q "regenerate the infrastructure reference" \
  && ! git log -1 --pretty=%s origin/infra/bucket | grep -q "regenerate"; } \
    && ok "…the regenerated reference committed straight to main after the merge, not onto the branch" || bad "reference commit: $(git log -1 --pretty=%s origin/main)"
back
[ ! -f infra/terraform/projects/web/prod/deploy.tfplan ] && ok "…and no plan file left behind" || bad "plan file left"

FAKE_PLAN_projects_web_prod='[]' rc=$(FAKE_MERGE=0 run)
{ [ "$rc" = 0 ] && ! called "apply projects/web/prod" && called "merge GITFLOW_ORG_DEPLOY=1 --pr 5 --base main" && grep -q "already live" "$tmp/out"; } \
    && ok "a re-run after the apply: the root plans to nothing, is not re-applied, and the PR merges" || bad "already live (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
back
rc=$(FAKE_REF_FAIL=1 run)
{ [ "$rc" = 29 ] && called "board deployed 7" && grep -q "gen-reference.sh and /ship-main" "$tmp/out"; } \
    && ok "the reference cannot be regenerated after the merge: the board still moves, exit 29 names how to finish" || bad "reference fails (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
back
rc=$(FAKE_MERGE=23 run)
{ [ "$rc" = 23 ] && grep -q "run /deploy again" "$tmp/out" && ! called "board deployed 7"; } \
    && ok "a merge that fails after the apply: its exit code, how to finish, and no board move" || bad "merge fails (rc=$rc): $(cat "$tmp/out")"

printf 'variable "v" {}\n' >> infra/terraform/shared/main.tf; git add -A; git commit -qm "feat: shared"; git push -q origin infra/bucket
printf '\n<!-- plan:shared -->\n```text\nno changes\n```\n<!-- /plan:shared -->\n' >> "$FAKE_BODY"
rc=$(FAKE_FAIL_APPLY=shared run)
{ [ "$rc" = 28 ] && ! grep -q '^merge' "$tmp/calls" && grep -q "Already live: projects/web/prod" "$tmp/out"; } \
    && ok "an apply that fails: nothing merged, and what is already live is named" || bad "apply failure (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"

# ─── Audit gates ───────────────────────────────────────────────────────────
git checkout -q main; git checkout -q -b infra/audit
printf 'resource "aws_s3_bucket" "c" {}\n' >> infra/terraform/shared/main.tf
printf '{"REPO_KIND":"org","ORG_AUDIT":"on"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "feat: audited"; git push -q -u origin infra/audit 2>/dev/null
printf 'Closes #9\n\n<!-- plan:shared -->\n```text\ncreate aws_s3_bucket.c\n```\n<!-- /plan:shared -->\n' > "$FAKE_BODY"
export FAKE_PLAN_shared='[{"address":"aws_s3_bucket.c","change":{"actions":["create"]}}]'
rc=$(run)
{ [ "$rc" = 32 ] && ! grep -q '^plan' "$tmp/calls"; } && ok "ORG_AUDIT on, no access-and-change procedure: refused before any plan" || bad "audit no doc (rc=$rc): $(cat "$tmp/out")"
mkdir -p project-documentation; printf 'procedure\n' > project-documentation/infrastructure-access-and-change.md
printf '{"REPO_KIND":"org","ORG_AUDIT":"on","ORG_DEPLOY_APPROVAL":"required"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "docs: procedure"; git push -q origin infra/audit
rc=$(FAKE_REVIEW=REVIEW_REQUIRED run)
{ [ "$rc" = 33 ] && ! grep -q '^plan' "$tmp/calls" && grep -q "REVIEW_REQUIRED" "$tmp/out"; } \
    && ok "approval required and not given: refused before any plan, naming the review state" || bad "approval missing (rc=$rc): $(cat "$tmp/out")"
rc=$(FAKE_REVIEW=APPROVED run --level patch)
{ [ "$rc" = 0 ] && called "apply shared"; } && ok "approved by another reviewer: applied and merged" || bad "approved (rc=$rc): $(cat "$tmp/out")"
back
! grep -q '^release' "$tmp/calls" && ok "…and an org repo never cuts an app release" || bad "org released: $(cat "$tmp/calls")"
unset FAKE_PLAN_shared

git checkout -q main; printf 'm\n' > moved.txt; git add -A; git commit -qm "chore: main moves"; git push -q origin main
git checkout -q infra/bucket
rc=$(run)
{ [ "$rc" = 31 ] && ! grep -q '^plan' "$tmp/calls" && grep -q "/catchup" "$tmp/out"; } \
    && ok "main moved since the branch: refused before any plan, pointing to /catchup" || bad "behind main (rc=$rc): $(cat "$tmp/out")"
sed -i.bak 's/baseRefName: "main"/baseRefName: "infra\/parent"/' "$tmp/fake/gh" && rm -f "$tmp/fake/gh.bak"
rc=$(run)
{ [ "$rc" = 30 ] && ! grep -q '^plan' "$tmp/calls"; } && ok "a PR stacked on another branch: refused before any plan" || bad "stacked (rc=$rc): $(cat "$tmp/out")"
sed -i.bak 's/baseRefName: "infra\/parent"/baseRefName: "main"/' "$tmp/fake/gh" && rm -f "$tmp/fake/gh.bak"

git checkout -q main; git checkout -q -b docs/notes
printf 'n\n' > notes.md; git add -A; git commit -qm "docs: notes"; git push -q -u origin docs/notes 2>/dev/null
rc=$(run)
[ "$rc" = 2 ] && grep -q "/ship-main" "$tmp/out" && ok "a PR changing no root: refused, pointing to /ship-main" || bad "docs PR (rc=$rc): $(cat "$tmp/out")"
printf '{"REPO_KIND":"combo"}\n' > .claude/sync-substitutions.json; git add -A; git commit -qm "chore: combo"; git push -q origin docs/notes
rc=$(run)
[ "$rc" = 2 ] && grep -q "land it with /merge" "$tmp/out" && ok "combo: a PR changing no root points to /merge instead" || bad "combo docs PR (rc=$rc): $(cat "$tmp/out")"

printf 'dirty\n' >> notes.md
[ "$(run)" = 4 ] && ok "uncommitted work: refused" || bad "dirty: $(cat "$tmp/out")"
git checkout -q -- notes.md
git checkout -q main
[ "$(run)" = 3 ] && ok "on main: refused" || bad "on main: $(cat "$tmp/out")"

# ─── Combo: a PR that also changes the app is released after the merge ──────
git checkout -q -b feat/app-and-bucket
printf '{"REPO_KIND":"combo"}\n' > .claude/sync-substitutions.json
printf 'resource "aws_s3_bucket" "d" {}\n' >> infra/terraform/projects/web/prod/main.tf
mkdir -p src; printf 'app\n' > src/app.ts
git add -A; git commit -qm "feat: app and bucket"; git push -q -u origin feat/app-and-bucket 2>/dev/null
printf 'Closes #12\n\n<!-- plan:projects/web/prod -->\n```text\ncreate aws_s3_bucket.d\n```\n<!-- /plan:projects/web/prod -->\n' > "$FAKE_BODY"
export FAKE_PLAN_projects_web_prod='[{"address":"aws_s3_bucket.d","change":{"actions":["create"]}}]'
rc=$(run --check-only)
{ [ "$rc" = 2 ] && ! grep -q '^plan' "$tmp/calls" && ! grep -q '^merge' "$tmp/calls"; } \
    && ok "combo, --check-only on a PR branch: refused before any plan, nothing applied" || bad "check-only (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
rc=$(run --level minor --changelog-file "$tmp/missing.md")
{ [ "$rc" = 2 ] && ! grep -q '^plan' "$tmp/calls" && grep -q "not found" "$tmp/out"; } \
    && ok "combo, a changelog file that does not exist: refused before any plan" || bad "missing changelog (rc=$rc): $(cat "$tmp/out")"
printf -- '- entry\n' > "$tmp/cl.md"
rc=$(run --level minor --changelog-file "$tmp/cl.md")
{ [ "$rc" = 0 ] && called "apply projects/web/prod" && called "release --level minor --changelog-file $tmp/cl.md" \
  && [ "$(grep -n '^merge' "$tmp/calls" | cut -d: -f1)" -lt "$(grep -n '^release' "$tmp/calls" | cut -d: -f1)" ]; } \
    && ok "combo, app and Terraform: applied, merged, then released with the arguments given" || bad "combo release (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
! called "board deployed 12" && ok "…the board move left to the release" || bad "combo board moved twice: $(cat "$tmp/calls")"
back
rc=$(FAKE_REF_FAIL=1 run --level minor --changelog-file "$tmp/cl.md")
{ [ "$rc" = 29 ] && ! grep -q '^release' "$tmp/calls" && grep -q "release it with /deploy on main once the reference is on main" "$tmp/out"; } \
    && ok "combo, the reference fails after the merge: no release, and how to finish named" || bad "combo ref fail (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
back
rc=$(run)
{ [ "$rc" = 0 ] && ! grep -q '^release' "$tmp/calls" && grep -q "release it with /deploy on main" "$tmp/out"; } \
    && ok "combo, app change, no release arguments: stops after the merge and says to /deploy on main" || bad "combo no args (rc=$rc): $(cat "$tmp/out")"
back
rc=$(FAKE_FAIL_APPLY=projects/web/prod run --level minor)
{ [ "$rc" = 28 ] && ! grep -q '^merge' "$tmp/calls" && ! grep -q '^release' "$tmp/calls"; } \
    && ok "combo, apply fails: nothing merged and nothing released" || bad "combo apply fail (rc=$rc): $(cat "$tmp/calls")"
rc=$(FAKE_MERGE=23 run --level minor)
{ [ "$rc" = 23 ] && ! grep -q '^release' "$tmp/calls"; } && ok "combo, merge fails: nothing released" || bad "combo merge fail (rc=$rc): $(cat "$tmp/calls")"
git rm -q src/app.ts; printf 'doc\n' > README.md; git add -A; git commit -qm "docs: readme"; git push -q origin feat/app-and-bucket
rc=$(run --level minor)
{ [ "$rc" = 0 ] && ! grep -q '^release' "$tmp/calls" && called "board deployed 12"; } \
    && ok "combo, Terraform and docs only: no release, and the issue moves" || bad "combo tf-only (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"

exit "$fail"
