#!/usr/bin/env bash
# Regression suite for commit.sh's branch choice on a branch whose PR was handed off.
#
# A PR assigned to someone other than you is theirs to review: the next commit is
# cut onto a stacked branch, recorded as stacked on it. A PR that is still yours
# (assigned to you, or to nobody) takes the commit, as does any branch when GitHub
# cannot be asked. Runs against a real origin; gh is a fake that answers from FAKE_*.
# Then the five headless reviews: run side by side, and any one failing fails the gate.
# Last, the type-check skipped on code unchanged but for comments and whitespace.
set -uo pipefail
C="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/commit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > a.txt; git add -A; git commit -qm base; git push -q origin main
git checkout -q -b feat/handed
printf 'b\n' > b.txt; git add -A; git commit -qm "feat: handed work"; git push -q -u origin feat/handed 2>/dev/null

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
[ -n "${FAKE_FAIL:-}" ] && exit 1
case "$*" in
  "api user --jq .login") echo alice ;;
  "pr list --head "*"--json assignees"*) printf '%s\n' "${FAKE_ASSIGNEES:-}" ;;
  "pr list"*) echo "" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"
commit(){ PATH="$tmp/bin:$PATH" SKIP_RULE_REVIEW=1 "$C" --message "$1" --skip-typecheck >"$tmp/out" 2>&1; }

printf 'next design\n' > c.txt
FAKE_ASSIGNEES=bob commit "feat: next design"; rc=$?
now=$(git branch --show-current)
{ [ "$rc" -eq 0 ] && [ "$now" = feat/next-design ] && [ "$(git config branch.feat/next-design.gitflow-parent)" = feat/handed ] \
  && [ "$(git rev-parse feat/handed)" = "$(git rev-parse origin/feat/handed)" ] \
  && git ls-remote --exit-code origin feat/next-design >/dev/null; } \
    && ok "a PR handed to someone else: the commit lands on a stacked branch, recorded, pushed; theirs untouched" \
    || bad "stacked commit (rc=$rc, on $now): $(cat "$tmp/out")"
grep -q "PR is with @bob" "$tmp/out" && ok "…and it says who has the PR" || bad "message: $(cat "$tmp/out")"

printf 'review fix\n' > d.txt
FAKE_ASSIGNEES=alice commit "fix: review fix"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = feat/next-design ]; } \
    && ok "a PR assigned to you takes the commit" || bad "own PR (rc=$rc): $(cat "$tmp/out")"

printf 'unassigned\n' > e.txt
FAKE_ASSIGNEES="" commit "fix: unassigned"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = feat/next-design ]; } \
    && ok "an unassigned PR takes the commit" || bad "unassigned (rc=$rc): $(cat "$tmp/out")"

printf 'offline\n' > f.txt
FAKE_FAIL=1 commit "fix: offline"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = feat/next-design ] && grep -q "could not ask GitHub" "$tmp/out"; } \
    && ok "GitHub unreachable: commits here, and says it could not check" || bad "offline (rc=$rc): $(cat "$tmp/out")"

# ─── A worktree's wip/ branch is renamed by its first commit, never after a push ──
git fetch -q origin main
git checkout -q --no-track -b wip/alice-spike origin/main
git config branch.wip/alice-spike.gitflow-issues 42
printf 'wip work\n' > g.txt
commit "feat(auth): Sign in with a passkey"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = feat/sign-in-with-a-passkey ] \
  && ! git show-ref --verify --quiet refs/heads/wip/alice-spike \
  && git ls-remote --exit-code origin feat/sign-in-with-a-passkey >/dev/null \
  && [ "$(git config branch.feat/sign-in-with-a-passkey.gitflow-issues)" = 42 ]; } \
    && ok "an unpushed wip/ branch takes the message's <type>/<slug>, issue links and all" || bad "wip rename (rc=$rc): $(cat "$tmp/out")"

git checkout -q --no-track -b wip/alice-pushed origin/main
printf 'pushed\n' > h.txt; git add -A; git commit -qm "feat: early"; git push -q -u origin wip/alice-pushed 2>/dev/null
printf 'more\n' > i.txt
commit "feat: later work"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = wip/alice-pushed ]; } \
    && ok "a wip/ branch already on origin keeps its name" || bad "pushed wip (rc=$rc): $(cat "$tmp/out")"

# ─── The five headless reviews run side by side, and any one failing fails the gate ──
# A copy of the scripts whose five reviews are fakes: each takes 2 s, prints its name, and
# fails when FAKE_FAIL_REVIEW names it.
kit="$tmp/kit/scripts"; mkdir -p "$kit"
cp "$(dirname "$C")"/*.sh "$(dirname "$C")"/*.mjs "$kit/"
for r in rule-review part-review design-review sql-review test-review; do
    cat > "$kit/$r.sh" <<FAKE
#!/bin/bash
sleep 2
echo "$r ran (skip=\${SKIP_RULE_REVIEW:-})"
[ "\${FAKE_FAIL_REVIEW:-}" = "$r" ] && { echo "$r: a finding"; exit 1; }
exit 0
FAKE
    chmod +x "$kit/$r.sh"
done
kcommit(){ PATH="$tmp/bin:$PATH" SKIP_RULE_REVIEW=1 "$kit/commit.sh" --message "$1" --skip-typecheck >"$tmp/out" 2>&1; }

printf 'parallel\n' > j.txt
start=$(date +%s); kcommit "feat: parallel reviews"; rc=$?; took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 0 ] && [ "$took" -lt 6 ]; } \
    && ok "the five reviews run side by side (${took}s for five 2 s reviews)" || bad "parallel (rc=$rc, ${took}s): $(cat "$tmp/out")"
order=$(grep -o '^[a-z]*-review ran' "$tmp/out" | tr '\n' ' ')
[ "$order" = "rule-review ran part-review ran design-review ran sql-review ran test-review ran " ] \
    && ok "…each review's output is printed whole, in a fixed order" || bad "order: $order"
grep -q 'rule-review ran (skip=1)' "$tmp/out" && ok "…and a SKIP_*_REVIEW override reaches its review" || bad "override: $(cat "$tmp/out")"

printf 'one fails\n' > k.txt
head_before=$(git rev-parse HEAD)
FAKE_FAIL_REVIEW=design-review kcommit "feat: a design finding"; rc=$?
{ [ "$rc" -eq 4 ] && [ "$(git rev-parse HEAD)" = "$head_before" ] && grep -q 'design-review: a finding' "$tmp/out" \
  && grep -q 'headless review failed: design-review' "$tmp/out" && grep -q 'test-review ran' "$tmp/out"; } \
    && ok "one review failing fails the gate (exit 4, nothing committed), its finding shown, the others' output too" \
    || bad "one failing (rc=$rc): $(cat "$tmp/out")"


# ─── No separate preflight: the integration gate's own run is where the database is checked ──
# A repository where the preflight would apply — SQL Server, integration tests, a
# test:preflight script. npm fails and records test:preflight if anything asks for it;
# nothing TypeScript changes, so the integration gate runs no tests and nothing reaches
# the database.
mkdir -p .claude scripts test
printf '{"DB_ENGINE":"SQLServer","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
printf '{"name":"app","scripts":{"test:preflight":"check"}}\n' > package.json
printf 'x\n' > test/a.integration.test.ts
touch scripts/check-integration-coverage.mjs
git add -A; git commit -qm "chore: integration setup"
printf '#!/bin/bash\ncase "$*" in *test:preflight*) echo ran >> "%s/preflight.ran"; exit 1 ;; esac\nexit 0\n' "$tmp" > "$tmp/bin/npm"
printf '#!/bin/bash\necho "check-integration-coverage: 0 changed exported function(s)"\n' > "$tmp/bin/node"
printf '#!/bin/bash\necho npx ran >> "%s/npx.ran"; exit 1\n' "$tmp" > "$tmp/bin/npx"
chmod +x "$tmp/bin/npm" "$tmp/bin/node" "$tmp/bin/npx"
printf 'docs\n' > notes.md
commit "docs: notes"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -f "$tmp/preflight.ran" ] && ! grep -q 'integration preflight' "$tmp/out"; } \
    && ok "/commit runs no integration preflight" || bad "preflight at commit (rc=$rc): $(cat "$tmp/out")"
{ [ ! -f "$tmp/npx.ran" ] && grep -q 'no TypeScript changed' "$tmp/out"; } \
    && ok "…and with no TypeScript changed, no test run touches the database" || bad "npx at commit: $(cat "$tmp/out")"
rm -f "$tmp/bin/npm" "$tmp/bin/node" "$tmp/bin/npx"

# ─── Unchanged code: the type-check runs once per code fingerprint ──────────
# The kit copy's fake reviews, the real fingerprint (TypeScript linked into the repo),
# and an npm that records every check-types run.
TS_DIR="$(npm root -g 2>/dev/null)/typescript"
if [ ! -d "$TS_DIR" ]; then
    bad "the unchanged-code cases need TypeScript installed globally (npm i -g typescript)"
else
    printf 'node_modules/\n' > .gitignore
    mkdir -p node_modules src; ln -s "$TS_DIR" node_modules/typescript
    printf '{"DB_ENGINE":"None","GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
    printf '{"name":"app","scripts":{"check-types":"tsc --noEmit"}}\n' > package.json
    printf '#!/bin/bash\ncase "$*" in "run check-types") echo ran >> "%s/check-types.ran" ;; esac\nexit 0\n' "$tmp" > "$tmp/bin/npm"
    chmod +x "$tmp/bin/npm"
    tcommit(){ rm -f "$tmp/check-types.ran"; PATH="$tmp/bin:$PATH" SKIP_RULE_REVIEW=1 "$kit/commit.sh" --message "$1" >"$tmp/out" 2>&1; }
    printf 'export const a = 1;\n' > src/a.ts
    tcommit "feat: typed"; rc=$?
    { [ "$rc" -eq 0 ] && [ -f "$tmp/check-types.ran" ]; } \
        && ok "/commit type-checks new code" || bad "first typecheck (rc=$rc): $(cat "$tmp/out")"
    printf '// one is the answer\nexport const a =   1;\n' > src/a.ts
    tcommit "docs: explain a"; rc=$?
    { [ "$rc" -eq 0 ] && [ ! -f "$tmp/check-types.ran" ] && grep -q 'typecheck: code unchanged since the last pass (comments and whitespace only) — typecheck skipped' "$tmp/out" \
      && [ -z "$(git status --porcelain)" ]; } \
        && ok "…a comment-only commit skips it, saying so, and still commits" || bad "comment-only (rc=$rc): $(cat "$tmp/out")"
    printf '// one is the answer\nexport const a = 2;\n' > src/a.ts
    tcommit "fix: a is two"; rc=$?
    { [ "$rc" -eq 0 ] && [ -f "$tmp/check-types.ran" ]; } \
        && ok "…a code change type-checks again" || bad "code change (rc=$rc): $(cat "$tmp/out")"
    rm -f "$tmp/bin/npm"
fi

exit "$fail"
