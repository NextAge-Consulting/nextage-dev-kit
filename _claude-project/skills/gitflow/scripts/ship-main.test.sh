#!/usr/bin/env bash
# Regression suite for ship-main.sh's org-repo rule: a Terraform change that would change
# AWS, or cannot be planned, is refused before anything is committed; one that plans no
# changes ships, and so does a docs change. A stand-in tf.sh returns the plan's exit code
# from FAKE_PLAN_RC. Runs against
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
printf '#!/bin/bash\ncase "$2" in plan) exit "${FAKE_PLAN_RC:-0}" ;; esac\nexit 0\n' > .claude/skills/terraform/scripts/tf.sh
chmod +x .claude/skills/terraform/scripts/tf.sh
printf '{"REPO_KIND":"org","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
printf 'terraform {}\n' > infra/terraform/shared/main.tf; touch infra/terraform/shared/.terraform.lock.hcl
git add -A; git commit -qm "chore: base"; git push -q origin main
mkdir -p "$tmp/bin"; printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
ship(){ PATH="$tmp/bin:$PATH" bash "$D/ship-main.sh" --message "$1" >"$tmp/out" 2>&1; echo $?; }
before=$(git rev-parse HEAD)

printf 'resource "x" "y" {}\n' >> infra/terraform/shared/main.tf
rc=$(FAKE_PLAN_RC=2 ship "✨ feat: bucket")
{ [ "$rc" = 14 ] && grep -q "goes through /open-pr and /deploy" "$tmp/out" && grep -q "shared" "$tmp/out" && [ "$(git rev-parse HEAD)" = "$before" ]; } \
    && ok "org repo: a Terraform change that changes AWS is refused, nothing committed" || bad "terraform refused (rc=$rc): $(cat "$tmp/out")"
rc=$(FAKE_PLAN_RC=1 ship "✨ feat: bucket")
{ [ "$rc" = 14 ] && [ "$(git rev-parse HEAD)" = "$before" ]; } \
    && ok "org repo: a Terraform change that cannot be planned is refused" || bad "plan error (rc=$rc): $(cat "$tmp/out")"
git checkout -q -- infra/terraform/shared/main.tf

printf '# a note\n' >> infra/terraform/shared/main.tf
rc=$(FAKE_PLAN_RC=0 ship "🧹 chore: note")
{ [ "$rc" = 0 ] && [ "$(git rev-parse origin/main)" != "$before" ]; } \
    && ok "org repo: a Terraform change that plans no changes ships" || bad "no-op terraform (rc=$rc): $(cat "$tmp/out")"
before=$(git rev-parse HEAD)

printf 'notes\n' > notes.md
rc=$(ship "📚 docs: notes")
{ [ "$rc" = 0 ] && [ "$(git rev-parse origin/main)" != "$before" ]; } \
    && ok "org repo: a docs change ships to main" || bad "docs ship (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
