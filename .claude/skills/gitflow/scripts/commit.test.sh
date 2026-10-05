#!/usr/bin/env bash
# Regression suite for commit.sh's branch choice on a branch whose PR was handed off.
#
# A PR assigned to someone other than you is theirs to review: the next commit is
# cut onto a stacked branch, recorded as stacked on it. A PR that is still yours
# (assigned to you, or to nobody) takes the commit, as does any branch when GitHub
# cannot be asked. Runs against a real origin; gh is a fake that answers from FAKE_*.
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

exit "$fail"
