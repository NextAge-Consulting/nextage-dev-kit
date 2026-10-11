#!/usr/bin/env bash
# Regression suite for ship-main.sh's org-repo rule: a change touching Terraform is
# refused before anything is committed, and a docs change still ships. Runs against
# a real origin with no package.json and no CI file, so every gate reports that it
# does not apply.
set -uo pipefail
# changed-roots.sh sits in the terraform skill beside this one; in the kit's own
# .claude/, which does not carry that skill, it is read from the kit source.
CHANGED_ROOTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../terraform/scripts/changed-roots.sh"
[ -f "$CHANGED_ROOTS" ] || CHANGED_ROOTS="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)/_claude-project/skills/terraform/scripts/changed-roots.sh"
[ -f "$CHANGED_ROOTS" ] || { echo "FAIL changed-roots.sh not found"; exit 1; }
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
mkdir -p .claude/skills/terraform/scripts infra/terraform/shared
cp "$CHANGED_ROOTS" .claude/skills/terraform/scripts/
printf '{"REPO_KIND":"org","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
printf 'terraform {}\n' > infra/terraform/shared/main.tf; touch infra/terraform/shared/.terraform.lock.hcl
git add -A; git commit -qm "chore: base"; git push -q origin main
mkdir -p "$tmp/bin"; printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
ship(){ PATH="$tmp/bin:$PATH" bash "$D/ship-main.sh" --message "$1" >"$tmp/out" 2>&1; echo $?; }
before=$(git rev-parse HEAD)

printf 'resource "x" "y" {}\n' >> infra/terraform/shared/main.tf
rc=$(ship "✨ feat: bucket")
{ [ "$rc" = 14 ] && grep -q "goes through /open-pr and /deploy" "$tmp/out" && [ "$(git rev-parse HEAD)" = "$before" ]; } \
    && ok "org repo: a Terraform change is refused, nothing committed" || bad "terraform refused (rc=$rc): $(cat "$tmp/out")"
git checkout -q -- infra/terraform/shared/main.tf

printf 'notes\n' > notes.md
rc=$(ship "📚 docs: notes")
{ [ "$rc" = 0 ] && [ "$(git rev-parse origin/main)" != "$before" ]; } \
    && ok "org repo: a docs change ships to main" || bad "docs ship (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
