#!/usr/bin/env bash
# Regression suite for changed-roots.sh, in a throwaway git repo.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }
has(){ if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }
run(){ bash "$D/changed-roots.sh" "$@" >"$tmp/out" 2>"$tmp/err"; echo $?; }

cd "$tmp" || exit 1
git init -q -b main; git config user.email t@example.com; git config user.name t
mkdir -p infra/terraform/shared infra/terraform/projects/web/prod infra/terraform/projects/web/test infra/terraform/modules/env
for r in shared projects/web/prod projects/web/test; do
  printf 'terraform {}\n' > "infra/terraform/$r/main.tf"; touch "infra/terraform/$r/.terraform.lock.hcl"
done
printf 'variable "x" {}\n' > infra/terraform/modules/env/main.tf
printf 'readme\n' > README.md
git add -A; git commit -qm init

echo "changed-roots.sh:"
t 2 "$(run)" 'no base: usage'
git checkout -qb work
t 0 "$(run main)" 'nothing changed: passes'
t "" "$(cat "$tmp/out")" '…printing no root'
has 'no Terraform root changed' '…and says so'

printf 'resource "x" "y" {}\n' >> infra/terraform/projects/web/prod/main.tf
printf 'docs\n' >> README.md
t 0 "$(run main)" 'an uncommitted change in one root'
t "projects/web/prod" "$(cat "$tmp/out")" '…reports that root only, not the docs change'
git add -A; git commit -qm one
printf 'a = 1\n' > infra/terraform/shared/shared.tfvars
t "projects/web/prod
shared" "$(run main >/dev/null; cat "$tmp/out")" 'committed and untracked changes both count'
has '2 root(s) changed' '…counting them'
git add -A; git commit -qm two

git checkout -q main; git checkout -qb modules
printf 'variable "y" {}\n' >> infra/terraform/modules/env/main.tf
run main >/dev/null
t "projects/web/prod
projects/web/test
shared" "$(cat "$tmp/out")" 'a module change reports every root'

git checkout -q -- .; git checkout -q main; git checkout -qb gone
git rm -rq infra/terraform/projects/web/test
t 3 "$(run main)" 'a deleted root fails'
has 'infra/terraform/projects/web/test was deleted' '…naming it'
has 'deploy that first' '…and what to do instead'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
