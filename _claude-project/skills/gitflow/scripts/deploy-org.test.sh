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
cp "$D/deploy-org.sh" "$bin/"
printf '#!/bin/bash\necho wait >> "%s/calls"; exit "${FAKE_CI:-0}"\n' "$tmp" > "$bin/wait-for-pr-ready.sh"
printf '#!/bin/bash\necho "merge GITFLOW_ORG_DEPLOY=$GITFLOW_ORG_DEPLOY $*" >> "%s/calls"\n' "$tmp" > "$bin/merge.sh"
chmod +x "$bin"/*.sh

mkdir -p "$tmp/fake"
printf '#!/bin/bash\nexit 0\n' > "$tmp/fake/terraform"
cat > "$tmp/fake/gh" <<'GH'
#!/bin/bash
case "$*" in
  "pr list --head "*) [ -n "${FAKE_NO_PR:-}" ] && exit 0; jq -nc --rawfile b "$FAKE_BODY" '{number: 5, body: $b, baseRefName: "main"}' ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/fake/terraform" "$tmp/fake/gh"

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
printf '#!/bin/bash\nmkdir -p project-documentation; date > project-documentation/infrastructure-reference.md\n' > .claude/skills/terraform/scripts/gen-reference.sh
chmod +x .claude/skills/terraform/scripts/*.sh
for r in shared projects/web/prod; do printf 'terraform {}\n' > "infra/terraform/$r/main.tf"; touch "infra/terraform/$r/.terraform.lock.hcl"; done
printf '*.tfplan\n' > .gitignore
git add -A; git commit -qm base; git push -q origin main
git checkout -q -b infra/bucket
printf 'resource "aws_s3_bucket" "b" {}\n' >> infra/terraform/projects/web/prod/main.tf
git add -A; git commit -qm "feat: bucket"; git push -q -u origin infra/bucket 2>/dev/null

export FAKE_BODY="$tmp/body.md"
printf 'Adds a bucket.\n\n<!-- plan:projects/web/prod -->\n```text\ncreate aws_s3_bucket.b\n```\n<!-- /plan:projects/web/prod -->\n' > "$FAKE_BODY"
export FAKE_PLAN_projects_web_prod='[{"address":"aws_s3_bucket.b","change":{"actions":["create"]}}]'
run(){ : > "$tmp/calls"; PATH="$tmp/fake:$PATH" bash "$bin/deploy-org.sh" >"$tmp/out" 2>&1; echo $?; }
called(){ grep -qx -- "$1" "$tmp/calls"; }

[ "$(FAKE_NO_PR=1 run)" = 9 ] && ok "no open PR: refused" || bad "no PR: $(cat "$tmp/out")"
[ "$(FAKE_CI=2 run)" = 11 ] && ! grep -q '^plan' "$tmp/calls" && ok "CI not green: refused before any plan" || bad "CI red: $(cat "$tmp/calls"; cat "$tmp/out")"

[ "$(FAKE_PLAN_projects_web_prod='[{"address":"aws_s3_bucket.b","change":{"actions":["create"]}},{"address":"aws_instance.s","change":{"actions":["delete"]}}]' run)" = 26 ] \
    && ! grep -q '^apply' "$tmp/calls" && grep -q "plan now:  delete aws_instance.s" "$tmp/out" \
    && ok "a fresh plan doing more than the PR shows: refused, nothing applied, the difference named" || bad "mismatch: $(cat "$tmp/out")"

rc=$(run)
{ [ "$rc" = 0 ] && called "plan projects/web/prod" && called "apply projects/web/prod" && ! grep -q "apply shared" "$tmp/calls" \
  && called "merge GITFLOW_ORG_DEPLOY=1 --pr 5 --base main"; } \
    && ok "a matching plan: only the changed root applied, then merged through /deploy's door" || bad "happy path (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"
git log -1 --pretty=%s | grep -q "regenerate the infrastructure reference" && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/infra/bucket)" ] \
    && ok "…the regenerated reference committed onto the PR's branch and pushed" || bad "reference commit: $(git log -1 --pretty=%s)"
[ ! -f infra/terraform/projects/web/prod/deploy.tfplan ] && ok "…and no plan file left behind" || bad "plan file left"

printf 'variable "v" {}\n' >> infra/terraform/shared/main.tf; git add -A; git commit -qm "feat: shared"; git push -q origin infra/bucket
printf '\n<!-- plan:shared -->\n```text\nno changes\n```\n<!-- /plan:shared -->\n' >> "$FAKE_BODY"
rc=$(FAKE_FAIL_APPLY=shared run)
{ [ "$rc" = 28 ] && ! grep -q '^merge' "$tmp/calls" && grep -q "Already live: projects/web/prod" "$tmp/out"; } \
    && ok "an apply that fails: nothing merged, and what is already live is named" || bad "apply failure (rc=$rc): $(cat "$tmp/calls"; cat "$tmp/out")"

git checkout -q main; git checkout -q -b docs/notes
printf 'n\n' > notes.md; git add -A; git commit -qm "docs: notes"; git push -q -u origin docs/notes 2>/dev/null
rc=$(run)
[ "$rc" = 2 ] && grep -q "/ship-main" "$tmp/out" && ok "a PR changing no root: refused, pointing to /ship-main" || bad "docs PR (rc=$rc): $(cat "$tmp/out")"

printf 'dirty\n' >> notes.md
[ "$(run)" = 4 ] && ok "uncommitted work: refused" || bad "dirty: $(cat "$tmp/out")"
git checkout -q -- notes.md
git checkout -q main
[ "$(run)" = 3 ] && ok "on main: refused" || bad "on main: $(cat "$tmp/out")"

exit "$fail"
