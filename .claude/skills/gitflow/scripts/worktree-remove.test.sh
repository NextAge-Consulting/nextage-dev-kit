#!/usr/bin/env bash
# Regression suite for worktree-remove.sh: a finished worktree goes, with its local
# branch, only when its work is merged and nothing uncommitted is in it; never from
# inside it, never with --force, never any worktree but the one named. Re-running
# after a partial cleanup finishes it. gh is a fake answering the PR state.
set -uo pipefail
R="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/worktree-remove.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/prim" 2>/dev/null
cd "$tmp/prim" || exit 1
git config user.email t@example.com; git config user.name t
printf '.claude/worktrees/\nnode_modules/\n.env\n.claude/worktree-handoff.md\n' > .gitignore
printf 'a\n' > a.txt; git add -A; git commit -qm base; git push -q origin main
printf 'SECRET=1\n' > .env
P=$(git worktree list --porcelain | sed -n '1s/^worktree //p')

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
case "$*" in
  "pr list --head "*"--state all --json state"*) echo "${FAKE_STATE:-}" ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"
rmwt(){ PATH="$tmp/bin:$PATH" "$R" "$@" >"$tmp/out" 2>&1; }
mkwt(){ git worktree add -q -b "$2" "$P/.claude/worktrees/$1" origin/main
        mkdir -p "$P/.claude/worktrees/$1/node_modules/pkg" "$P/.claude/worktrees/$1/.claude"
        printf 'x\n' > "$P/.claude/worktrees/$1/node_modules/pkg/i.js"
        printf 'h\n' > "$P/.claude/worktrees/$1/.claude/worktree-handoff.md"
        ln -s "$P/.env" "$P/.claude/worktrees/$1/.env"; }

mkwt "done" feat/done
mkwt other feat/other

( cd "$P/.claude/worktrees/done" && FAKE_STATE=MERGED PATH="$tmp/bin:$PATH" "$R" "$P/.claude/worktrees/done" >"$tmp/out" 2>&1 ); rc=$?
{ [ "$rc" -eq 3 ] && [ -d "$P/.claude/worktrees/done" ]; } && ok "run from inside the worktree: refused" || bad "inside (rc=$rc): $(cat "$tmp/out")"

FAKE_STATE=OPEN rmwt "$P/.claude/worktrees/done"; rc=$?
{ [ "$rc" -eq 4 ] && [ -d "$P/.claude/worktrees/done" ] && grep -q "is not merged (its PR is open)" "$tmp/out"; } \
    && ok "an unmerged PR: refused, nothing removed" || bad "unmerged (rc=$rc): $(cat "$tmp/out")"

FAKE_STATE="" rmwt "$P/.claude/worktrees/done"; rc=$?
{ [ "$rc" -eq 7 ] && [ -d "$P/.claude/worktrees/done" ]; } && ok "GitHub cannot say: refused, nothing removed" || bad "unknown (rc=$rc): $(cat "$tmp/out")"

printf 'half done\n' > "$P/.claude/worktrees/done/new.txt"
FAKE_STATE=MERGED rmwt "$P/.claude/worktrees/done"; rc=$?
{ [ "$rc" -eq 5 ] && [ -f "$P/.claude/worktrees/done/new.txt" ] && grep -q "new.txt" "$tmp/out"; } \
    && ok "an untracked file: refused and listed, nothing removed" || bad "dirty (rc=$rc): $(cat "$tmp/out")"
rm "$P/.claude/worktrees/done/new.txt"

FAKE_STATE=MERGED rmwt "$P/.claude/worktrees/done"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -e "$P/.claude/worktrees/done" ] && ! git show-ref --verify --quiet refs/heads/feat/done \
  && [ "$(cat "$P/.env")" = SECRET=1 ] && [ -d "$P/.claude/worktrees/other" ] && git show-ref --verify --quiet refs/heads/feat/other \
  && grep -q "removed worktree" "$tmp/out" && grep -q "deleted local branch feat/done" "$tmp/out"; } \
    && ok "merged and clean: removed with its ignored files and branch; the primary's .env and other worktrees untouched" \
    || bad "remove (rc=$rc): $(cat "$tmp/out")"

FAKE_STATE=MERGED rmwt "$P/.claude/worktrees/done" --branch feat/done; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "already gone" "$tmp/out"; } && ok "re-run on a removed worktree: pruned, branch skipped" || bad "rerun (rc=$rc): $(cat "$tmp/out")"

git worktree add -q -b feat/half "$P/.claude/worktrees/half" origin/main
rm -rf "$P/.claude/worktrees/half"
FAKE_STATE=MERGED rmwt "$P/.claude/worktrees/half" --branch feat/half; rc=$?
{ [ "$rc" -eq 0 ] && ! git show-ref --verify --quiet refs/heads/feat/half && ! git worktree list | grep -q half; } \
    && ok "a folder already gone: pruned, and its named branch deleted once merged" || bad "half (rc=$rc): $(cat "$tmp/out")"

git worktree add -q --detach "$P/.claude/worktrees/deployed" origin/main
FAKE_STATE="" rmwt "$P/.claude/worktrees/deployed"; rc=$?
{ [ "$rc" -eq 0 ] && [ ! -e "$P/.claude/worktrees/deployed" ]; } \
    && ok "detached at origin/main (deployed from): removed" || bad "detached (rc=$rc): $(cat "$tmp/out")"

git worktree add -q --detach "$P/.claude/worktrees/stray" origin/main
( cd "$P/.claude/worktrees/stray" && printf 's\n' > s.txt && git add -A && git commit -qm "local only" )
FAKE_STATE="" rmwt "$P/.claude/worktrees/stray"; rc=$?
{ [ "$rc" -eq 4 ] && [ -d "$P/.claude/worktrees/stray" ]; } \
    && ok "detached at a commit origin/main lacks: refused" || bad "stray (rc=$rc): $(cat "$tmp/out")"

rmwt "$P"; rc=$?
{ [ "$rc" -eq 6 ] && [ -d "$P/.git" ]; } && ok "the primary checkout is never removed" || bad "primary (rc=$rc): $(cat "$tmp/out")"

exit "$fail"
