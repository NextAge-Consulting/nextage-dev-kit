#!/usr/bin/env bash
# Regression suite for catchup.sh on a stacked branch — one /commit cut from a
# handed-off PR. While the parent's PR is open it catches up from the parent; once
# the parent merged, its own PR is re-pointed at main and it catches up from main.
# Runs against a real origin; gh is a fake that answers from FAKE_* and records calls.
set -uo pipefail
U="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/catchup.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
for c in work bob; do git clone -q "$tmp/origin.git" "$tmp/$c" 2>/dev/null; git -C "$tmp/$c" config user.email t@example.com; git -C "$tmp/$c" config user.name t; done
cd "$tmp/work" || exit 1
printf 'a\n' > a.txt; git add -A; git commit -qm base; git push -q origin main
git checkout -q -b feat/handed; printf 'design 1\n' > design.txt; git add -A; git commit -qm "feat: design 1"; git push -q -u origin feat/handed 2>/dev/null
git checkout -q -b feat/next; printf 'design 2\n' > next.txt; git add -A; git commit -qm "feat: design 2"; git push -q -u origin feat/next 2>/dev/null
git config branch.feat/next.gitflow-parent feat/handed

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "pr list --head feat/handed --state all"*) echo "$FAKE_PARENT_STATE" ;;
  "pr list --head feat/next --state open --json number"*) echo 78 ;;
  "pr view 78 --json baseRefName"*) echo feat/handed ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export FAKE_LOG="$tmp/gh.log"
catchup(){ : > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$U" >"$tmp/out" 2>&1; }

# Bob pushes a review fix to the handed-off PR.
git -C "$tmp/bob" fetch -q origin feat/handed && git -C "$tmp/bob" checkout -q -b feat/handed origin/feat/handed
printf 'review fix\n' > "$tmp/bob/fix.txt"; git -C "$tmp/bob" add -A; git -C "$tmp/bob" commit -qm "fix: review"; git -C "$tmp/bob" push -q origin feat/handed

FAKE_PARENT_STATE=OPEN catchup; rc=$?
{ [ "$rc" -eq 0 ] && [ -f fix.txt ] && grep -q "stacked on feat/handed" "$tmp/out"; } \
    && ok "parent PR still open: the stacked branch catches up from it (the reviewer's fix comes in)" || bad "open parent (rc=$rc): $(cat "$tmp/out")"

# The parent merges: squashed onto main, its branch deleted.
git -C "$tmp/bob" fetch -q origin main && git -C "$tmp/bob" checkout -q -B main origin/main
git -C "$tmp/bob" merge -q --squash feat/handed >/dev/null && git -C "$tmp/bob" commit -qm "feat: design 1 (#76)" && git -C "$tmp/bob" push -q origin main
git -C "$tmp/bob" push -q origin --delete feat/handed

FAKE_PARENT_STATE=MERGED catchup; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "pr edit 78 --base main" "$FAKE_LOG" && [ -z "$(git config branch.feat/next.gitflow-parent)" ] \
  && git merge-base --is-ancestor origin/main HEAD; } \
    && ok "parent merged: its PR re-pointed at main, the parent forgotten, main merged in cleanly" || bad "merged parent (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"
[ -z "$(git diff --name-only origin/main HEAD -- design.txt fix.txt)" ] \
    && ok "…and against main the branch carries only its own change" || bad "diff vs main: $(git diff --stat origin/main HEAD)"

exit "$fail"
