#!/usr/bin/env bash
# Regression suite for ship-main.sh's org-repo rule: a Terraform change that would change
# AWS, or cannot be planned, is refused before anything is committed; one that plans no
# changes ships, and so does a docs change. Last, the type-check skipped on code unchanged
# but for comments and whitespace, and the strict assurance level's docs-only rule. A stand-in tf.sh returns the plan's exit code
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

# ─── Combo: the same Terraform rule as an org repo ───────────────────────
printf '{"REPO_KIND":"combo","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: combo"; git push -q origin main; before=$(git rev-parse HEAD)
printf 'resource "x" "z" {}\n' >> infra/terraform/shared/main.tf
rc=$(FAKE_PLAN_RC=2 ship "✨ feat: bucket")
{ [ "$rc" = 14 ] && [ "$(git rev-parse HEAD)" = "$before" ]; } \
    && ok "combo: a Terraform change that changes AWS is refused" || bad "combo terraform (rc=$rc): $(cat "$tmp/out")"
git checkout -q -- infra/terraform/shared/main.tf


# ─── No separate preflight: the integration gate's own run is where the database is checked ──
printf '{"REPO_KIND":"app","DB_ENGINE":"SQLServer","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
printf '{"name":"app","scripts":{"check-types":"tsc --noEmit","test:preflight":"check"}}\n' > package.json
mkdir -p scripts test; printf 'x\n' > test/a.integration.test.ts; touch scripts/check-integration-coverage.mjs
git add -A; git commit -qm "chore: integration setup"; git push -q origin main; before=$(git rev-parse HEAD)
printf '#!/bin/bash\ncase "$*" in *test:preflight*) echo ran >> "%s/preflight.ran"; exit 1 ;; esac\nexit 0\n' "$tmp" > "$tmp/bin/npm"
printf '#!/bin/bash\necho "check-integration-coverage: 0 changed exported function(s)"\n' > "$tmp/bin/node"
chmod +x "$tmp/bin/npm" "$tmp/bin/node"
printf 'more notes\n' >> notes.md
rc=$(ship "📚 docs: more notes")
{ [ "$rc" = 0 ] && [ ! -f "$tmp/preflight.ran" ] && ! grep -q 'integration preflight' "$tmp/out" && [ "$(git rev-parse origin/main)" != "$before" ]; } \
    && ok "/ship-main runs no integration preflight" || bad "preflight at ship-main (rc=$rc): $(cat "$tmp/out")"

# ─── Unchanged code: the type-check runs once per code fingerprint ──────────
# The real fingerprint (TypeScript linked into the repo) and an npm that records every
# check-types run. No database, so the integration gate stands down.
TS_DIR="$(npm root -g 2>/dev/null)/typescript"
rm -f "$tmp/bin/node"
if [ ! -d "$TS_DIR" ]; then
    bad "the unchanged-code cases need TypeScript installed globally (npm i -g typescript)"
else
    printf 'node_modules/\n' > .gitignore
    mkdir -p node_modules src; ln -s "$TS_DIR" node_modules/typescript
    printf '{"REPO_KIND":"app","DB_ENGINE":"None","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
    printf '#!/bin/bash\ncase "$*" in "run check-types") echo ran >> "%s/check-types.ran" ;; esac\nexit 0\n' "$tmp" > "$tmp/bin/npm"
    tship(){ rm -f "$tmp/check-types.ran"; SKIP_TEST_REVIEW=1 ship "$1"; }
    printf 'export const a = 1;\n' > src/a.ts
    rc=$(tship "✨ feat: typed")
    { [ "$rc" = 0 ] && [ -f "$tmp/check-types.ran" ]; } \
        && ok "/ship-main type-checks new code" || bad "first typecheck (rc=$rc): $(cat "$tmp/out")"
    printf '/* one */\nexport const a =\n  1;\n' > src/a.ts
    before=$(git rev-parse HEAD)
    rc=$(tship "📚 docs: explain a")
    { [ "$rc" = 0 ] && [ ! -f "$tmp/check-types.ran" ] && [ "$(git rev-parse origin/main)" != "$before" ] \
      && grep -q 'typecheck: code unchanged since the last pass (comments and whitespace only) — typecheck skipped' "$tmp/out"; } \
        && ok "…a comment-only change skips it, saying so, and ships" || bad "comment-only (rc=$rc): $(cat "$tmp/out")"
    printf 'export const a = 2;\n' > src/a.ts
    rc=$(tship "🐛 fix: a is two")
    { [ "$rc" = 0 ] && [ -f "$tmp/check-types.ran" ]; } \
        && ok "…a code change type-checks again" || bad "code change (rc=$rc): $(cat "$tmp/out")"
fi

# ─── Strict: only docs go straight to main ─────────────────────────────────
printf '{"REPO_KIND":"app","DB_ENGINE":"None","GEMINI_NOT_INSTALLED":"true","ASSURANCE_LEVEL":"strict"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: strict"; git push -q origin main; before=$(git rev-parse HEAD)
mkdir -p src; printf 'export const s = 1;\n' > src/strict.ts; printf 'why\n' >> notes.md
rc=$(SKIP_TEST_REVIEW=1 ship "✨ feat: strict code")
{ [ "$rc" = 16 ] && grep -q "ships docs only" "$tmp/out" && grep -q "  src/strict.ts" "$tmp/out" && ! grep -q "  notes.md" "$tmp/out" \
  && [ "$(git rev-parse HEAD)" = "$before" ] && [ "$(git rev-parse origin/main)" = "$before" ]; } \
    && ok "strict: a change touching code is refused (16), naming the files, nothing committed" || bad "strict code (rc=$rc): $(cat "$tmp/out")"
rm -f src/strict.ts
mkdir -p project-documentation; printf 'diagram\n' > project-documentation/flow.txt
rc=$(SKIP_TEST_REVIEW=1 ship "📚 docs: strict notes")
{ [ "$rc" = 0 ] && grep -q "docs only, as strict allows" "$tmp/out" && [ "$(git rev-parse origin/main)" != "$before" ]; } \
    && ok "strict: Markdown and project-documentation/ ship" || bad "strict docs (rc=$rc): $(cat "$tmp/out")"
printf '{"REPO_KIND":"app","DB_ENGINE":"None","GEMINI_NOT_INSTALLED":"true","ASSURANCE_LEVEL":"Strict"}\n' > .claude/sync-substitutions.json
before=$(git rev-parse HEAD)
rc=$(ship "🔧 chore: typo")
{ [ "$rc" = 2 ] && grep -q "ASSURANCE_LEVEL is 'Strict' in .claude/sync-substitutions.json" "$tmp/out" && [ "$(git rev-parse HEAD)" = "$before" ]; } \
    && ok "an invalid ASSURANCE_LEVEL fails loud (2), naming the key and the file" || bad "invalid level (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
