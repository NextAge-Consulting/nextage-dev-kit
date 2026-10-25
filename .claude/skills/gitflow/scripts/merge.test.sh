#!/usr/bin/env bash
# Regression suite for merge.sh's PR-ownership behaviour: a stacked PR whose parent
# has not merged is refused, and merging someone else's PR records an approval first.
# Also the uncommitted-changes gate and the worktree tail.
# Runs with --force-unchecked (no CI wait, no build) against a real origin; gh is a
# fake that answers from FAKE_* and records every call. Last, the build running while the
# readiness wait polls, against a fake wait and a fake npm, and skipped on code it built.
set -uo pipefail
M="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/merge.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > a.txt; git add -A; git commit -qm base; git push -q origin main

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "api user --jq .login") echo "$FAKE_ME" ;;
  "pr list --head "*"--json number,title,url"*) echo '[{"number":77,"title":"t","url":"u"}]' ;;
  "pr list --head "*"--json number"*) echo 76 ;;
  "pr view 77 --json author,baseRefName"*) printf '%s\t%s\n' "$FAKE_AUTHOR" "$FAKE_BASE" ;;
  "repo view"*) echo acme/app ;;
  *"pr view 77 --json title"*) echo "✨ feat: x" ;;
  *"pr view 77 --json body"*) echo "body" ;;
  *"pr list --base "*) printf '%s\n' ${FAKE_STACKED:-} ;;
  "api repos/acme/app/git/ref/heads/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export FAKE_LOG="$tmp/gh.log"
merge(){ : > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$M" --force-unchecked >"$tmp/out" 2>&1; }
branch(){ git checkout -q main; git checkout -q -b "$1"; printf '%s\n' "$1" > "f-${1//\//-}.txt"; git add -A; git commit -qm "feat: $1"; git push -q -u origin "$1" 2>/dev/null; }

branch feat/stacked
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=feat/handed merge; rc=$?
{ [ "$rc" -eq 24 ] && ! grep -q "pr merge" "$FAKE_LOG" && grep -q "stacked on 'feat/handed' (PR #76)" "$tmp/out"; } \
    && ok "a stacked PR whose parent is not merged is refused, nothing merged" || bad "stacked (rc=$rc): $(cat "$tmp/out")"

branch feat/theirs
FAKE_ME=bob FAKE_AUTHOR=alice FAKE_BASE=main merge; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "\-R acme/app pr review 77 --approve --body Reviewed and merged by @bob." "$FAKE_LOG" \
  && [ "$(grep -n "pr review" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n "pr merge" "$FAKE_LOG" | cut -d: -f1)" ]; } \
    && ok "merging someone else's PR approves it first, as the person merging" || bad "approval (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

branch feat/parent
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main FAKE_STACKED=78 merge; rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "\-R acme/app pr edit 78 --base main" "$FAKE_LOG" \
  && [ "$(grep -n "pr edit 78" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n "X DELETE" "$FAKE_LOG" | cut -d: -f1)" ]; } \
    && ok "a PR stacked on the merged branch is re-pointed at main before the branch is deleted" || bad "stacked re-point (rc=$rc): $(cat "$FAKE_LOG")"
grep -qx "api -X DELETE repos/acme/app/git/refs/heads/feat/parent" "$FAKE_LOG" && ! grep -q "did not take\|could not confirm" "$tmp/out" \
    && ok "the merged branch is deleted on origin, and its absence confirmed" || bad "delete: $(cat "$FAKE_LOG"; cat "$tmp/out")"

branch feat/mine
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main merge; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q "pr review" "$FAKE_LOG" && grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "merging your own PR records no approval" || bad "own merge (rc=$rc): $(cat "$tmp/out")"

# ─── Org repo: /deploy lands the PR, /merge does not ──────────────────────
branch feat/org
mkdir -p .claude; printf '{"REPO_KIND":"org"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: org"; git push -q origin feat/org 2>/dev/null
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main merge; rc=$?
{ [ "$rc" -eq 25 ] && grep -q "/deploy applies the PR and merges it" "$tmp/out" && ! grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "org repo: /merge refuses and points to /deploy" || bad "org refuse (rc=$rc): $(cat "$tmp/out")"
: > "$FAKE_LOG"; FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main GITFLOW_ORG_DEPLOY=1 PATH="$tmp/bin:$PATH" "$M" --force-unchecked >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "org repo: /deploy's call merges" || bad "org deploy merge (rc=$rc): $(cat "$tmp/out")"

# ─── Combo: only a PR that changes Terraform must go through /deploy ──────
git checkout -q main
mkdir -p .claude/skills/terraform/scripts infra/terraform/shared
cp "$(dirname "$M")/../../terraform/scripts/changed-roots.sh" .claude/skills/terraform/scripts/ 2>/dev/null \
  || cp "$(git -C "$(dirname "$M")" rev-parse --show-toplevel)/_claude-project/skills/terraform/scripts/changed-roots.sh" .claude/skills/terraform/scripts/
printf '{"REPO_KIND":"combo"}\n' > .claude/sync-substitutions.json
printf 'terraform {}\n' > infra/terraform/shared/main.tf; touch infra/terraform/shared/.terraform.lock.hcl
git add -A; git commit -qm "chore: combo"; git push -q origin main
branch feat/combo-app
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main merge; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "combo: a PR with no Terraform merges as usual" || bad "combo app merge (rc=$rc): $(cat "$tmp/out")"
branch feat/combo-infra
printf 'resource "x" "y" {}\n' >> infra/terraform/shared/main.tf; git add -A; git commit -qm "feat: infra"; git push -q origin feat/combo-infra 2>/dev/null
FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main merge; rc=$?
{ [ "$rc" -eq 25 ] && grep -q "this PR changes Terraform (shared" "$tmp/out" && ! grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "combo: a PR that changes Terraform is refused, pointing to /deploy" || bad "combo infra merge (rc=$rc): $(cat "$tmp/out")"

# ─── Uncommitted changes: refused before anything reaches GitHub ──────────
git checkout -q main
printf '{}\n' > .claude/sync-substitutions.json; printf '.claude/worktrees/\n' > .gitignore
git add -A; git commit -qm "chore: app"; git push -q origin main
merge_with(){ : > "$FAKE_LOG"; FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main PATH="$tmp/bin:$PATH" "$M" --force-unchecked "$@" >"$tmp/out" 2>&1; }

branch feat/dirty-other
printf 'scratch\n' > notes.txt
merge_with; rc=$?
{ [ "$rc" -eq 26 ] && grep -q "^  notes.txt$" "$tmp/out" && grep -qx "CARRY: offered" "$tmp/out" && [ ! -s "$FAKE_LOG" ]; } \
    && ok "an untracked file outside the PR: exit 26, listed, carry offered, nothing sent to GitHub" || bad "dirty other (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

printf 'edited\n' > f-feat-dirty-other.txt
merge_with --carry-uncommitted; rc=$?
{ [ "$rc" -eq 26 ] && grep -q "f-feat-dirty-other.txt   (this PR changes it too)" "$tmp/out" \
  && grep -qx "CARRY: not offered — this PR changes some of them too" "$tmp/out" && ! grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "an edit to a file the PR changes: marked, carry refused even when asked, nothing merged" || bad "dirty overlap (rc=$rc): $(cat "$tmp/out")"
git checkout -q -- f-feat-dirty-other.txt

merge_with --carry-uncommitted; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr merge" "$FAKE_LOG" && [ "$(git branch --show-current)" = main ] \
  && [ "$(cat notes.txt)" = scratch ] && [ -z "$(git stash list)" ]; } \
    && ok "--carry-uncommitted merges and the edits land on main" || bad "carry (rc=$rc): $(cat "$tmp/out")"
rm notes.txt

# ─── A worktree: merged on GitHub only, then handed to cleanup ────────────
P=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
git checkout -q main
git worktree add -q -b feat/in-wt "$P/.claude/worktrees/wt1" origin/main
( cd "$P/.claude/worktrees/wt1" && printf 'wt\n' > wt.txt && git add -A && git commit -qm "feat: wt" && git push -q -u origin feat/in-wt 2>/dev/null )
( cd "$P/.claude/worktrees/wt1" && merge_with ); rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr merge" "$FAKE_LOG" && grep -qx "WORKTREE-REMOVE: $P/.claude/worktrees/wt1" "$tmp/out" \
  && grep -qx "WORKTREE-BRANCH: feat/in-wt" "$tmp/out" && [ "$(git -C "$P/.claude/worktrees/wt1" branch --show-current)" = feat/in-wt ] \
  && [ "$(git branch --show-current)" = main ] && git show-ref --verify --quiet refs/heads/feat/in-wt; } \
    && ok "in a worktree: merges on GitHub, changes nothing local, names the worktree for cleanup" || bad "worktree tail (rc=$rc): $(cat "$tmp/out")"

printf 'loose\n' > "$P/.claude/worktrees/wt1/loose.txt"
( cd "$P/.claude/worktrees/wt1" && merge_with --carry-uncommitted ); rc=$?
{ [ "$rc" -eq 26 ] && grep -q "CARRY: not offered — this is a worktree" "$tmp/out"; } \
    && ok "in a worktree, carrying uncommitted edits is never offered" || bad "worktree carry (rc=$rc): $(cat "$tmp/out")"
rm "$P/.claude/worktrees/wt1/loose.txt"

( cd "$P/.claude/worktrees/wt1" && merge_with --deploy-from-worktree ); rc=$?
{ [ "$rc" -eq 0 ] && grep -qx "WORKTREE-DEPLOY: $P/.claude/worktrees/wt1" "$tmp/out" \
  && [ -z "$(git -C "$P/.claude/worktrees/wt1" branch --show-current)" ] \
  && [ "$(git -C "$P/.claude/worktrees/wt1" rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  && ! git show-ref --verify --quiet refs/heads/feat/in-wt; } \
    && ok "--deploy-from-worktree detaches it at origin/main and drops the merged branch" || bad "deploy from worktree (rc=$rc): $(cat "$tmp/out")"

branch feat/primary-deploy
merge_with --deploy-from-worktree; rc=$?
{ [ "$rc" -eq 2 ] && [ ! -s "$FAKE_LOG" ]; } \
    && ok "--deploy-from-worktree outside a worktree is refused" || bad "primary deploy flag (rc=$rc): $(cat "$tmp/out")"

# ─── The build runs while the readiness wait polls ────────────────────────
# A copy of the scripts whose readiness wait is a fake that takes FAKE_WAIT_SEC and exits
# FAKE_WAIT_EXIT; npm is a fake whose build takes FAKE_BUILD_SEC and exits FAKE_BUILD_EXIT.
kit="$tmp/kit/scripts"; mkdir -p "$kit"
cp "$(dirname "$M")"/*.sh "$(dirname "$M")"/*.mjs "$kit/"
cat > "$kit/wait-for-pr-ready.sh" <<'WAIT'
#!/bin/bash
echo "wait started" >> "$FAKE_LOG"
sleep "${FAKE_WAIT_SEC:-0}"
echo "wait finished" >> "$FAKE_LOG"
exit "${FAKE_WAIT_EXIT:-0}"
WAIT
chmod +x "$kit/wait-for-pr-ready.sh"
cat > "$tmp/bin/npm" <<'NPM'
#!/bin/bash
[ "$1 $2" = "run build" ] || exit 0
echo "build started" >> "$FAKE_LOG"
echo $$ > "$FAKE_LOG.npm-pid"
sleep "${FAKE_BUILD_SEC:-0}"
echo "BUILD OUTPUT LINE"
[ "${FAKE_BUILD_EXIT:-0}" -eq 0 ] || { echo "BUILD ERROR LINE" >&2; exit "$FAKE_BUILD_EXIT"; }
echo "build finished" >> "$FAKE_LOG"
NPM
chmod +x "$tmp/bin/npm"
git checkout -q main
printf '{"name":"app","private":true,"scripts":{"build":"vite build"}}\n' > package.json
git add -A; git commit -qm "chore: build"; git push -q origin main
checked(){ : > "$FAKE_LOG"; FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main PATH="$tmp/bin:$PATH" "$kit/merge.sh" >"$tmp/out" 2>&1; }

branch feat/build-fails
start=$(date +%s); FAKE_BUILD_EXIT=1 FAKE_BUILD_SEC=0 FAKE_WAIT_SEC=30 checked; rc=$?; took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 15 ] && ! grep -q "pr merge" "$FAKE_LOG" && [ "$took" -lt 10 ] && ! grep -q "wait finished" "$FAKE_LOG" \
  && grep -q "BUILD ERROR LINE" "$tmp/out" && grep -q "production build FAILED" "$tmp/out" && grep -q "readiness wait stopped" "$tmp/out"; } \
    && ok "a failing build stops the merge with 15, stops the wait, shows the build's output, no pr merge (${took}s)" \
    || bad "build fails (rc=$rc, ${took}s): $(cat "$tmp/out"; cat "$FAKE_LOG")"

branch feat/build-overlaps
start=$(date +%s); FAKE_BUILD_SEC=3 FAKE_WAIT_SEC=3 checked; rc=$?; took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 0 ] && grep -q "pr merge" "$FAKE_LOG" && [ "$took" -lt 6 ] \
  && [ "$(grep -n "build started" "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n "wait finished" "$FAKE_LOG" | cut -d: -f1)" ]; } \
    && ok "a 3 s build and a 3 s wait overlap: ${took}s, not 6, then it merges" || bad "overlap (rc=$rc, ${took}s): $(cat "$tmp/out"; cat "$FAKE_LOG")"
out_lines=$(grep -c "BUILD OUTPUT LINE" "$tmp/out")
[ "$out_lines" = 1 ] && grep -B1 -A1 "BUILD OUTPUT LINE" "$tmp/out" | grep -q "running production build" \
    && ok "…the build's output is printed whole, in one block" || bad "build output: $(cat "$tmp/out")"

branch feat/wait-fails
start=$(date +%s); FAKE_BUILD_SEC=30 FAKE_WAIT_SEC=0 FAKE_WAIT_EXIT=2 checked; rc=$?; took=$(( $(date +%s) - start ))
{ [ "$rc" -eq 11 ] && ! grep -q "pr merge" "$FAKE_LOG" && [ "$took" -lt 10 ] && grep -q "CI failed on PR" "$tmp/out" \
  && grep -q "production build stopped" "$tmp/out" && ! grep -q "build finished" "$FAKE_LOG"; } \
    && ok "a failing wait exits 11 and stops the build still running (${took}s)" || bad "wait fails (rc=$rc, ${took}s): $(cat "$tmp/out"; cat "$FAKE_LOG")"
sleep 1; if kill -0 "$(cat "$FAKE_LOG.npm-pid")" 2>/dev/null; then bad "…the build's npm outlived the stop"; else ok "…and the build's own processes are stopped too"; fi

branch feat/wait-fails-late
FAKE_BUILD_SEC=0 FAKE_WAIT_SEC=2 FAKE_WAIT_EXIT=3 checked; rc=$?
{ [ "$rc" -eq 11 ] && ! grep -q "pr merge" "$FAKE_LOG" && grep -q "production build OK" "$tmp/out"; } \
    && ok "a wait that fails after the build passed exits 11, the build's pass shown" || bad "wait fails late (rc=$rc): $(cat "$tmp/out")"

branch feat/interrupted
: > "$FAKE_LOG"; FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main FAKE_BUILD_SEC=30 FAKE_WAIT_SEC=30 PATH="$tmp/bin:$PATH" "$kit/merge.sh" >"$tmp/out" 2>&1 &
mpid=$!; sleep 2; kill -TERM "$mpid"; wait "$mpid"; rc=$?; sleep 1
{ [ "$rc" -eq 11 ] && grep -q "interrupted — the readiness wait and the build were stopped" "$tmp/out" \
  && ! kill -0 "$(cat "$FAKE_LOG.npm-pid")" 2>/dev/null && ! grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "interrupted while waiting: exit 11, the build and the wait both stopped, nothing merged" || bad "interrupt (rc=$rc): $(cat "$tmp/out")"

branch feat/forced
: > "$FAKE_LOG"; FAKE_ME=alice FAKE_AUTHOR=alice FAKE_BASE=main FAKE_BUILD_EXIT=1 FAKE_WAIT_EXIT=2 PATH="$tmp/bin:$PATH" "$kit/merge.sh" --force-unchecked >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q "build started\|wait started" "$FAKE_LOG" && grep -q "pr merge" "$FAKE_LOG"; } \
    && ok "--force-unchecked skips both the build and the wait" || bad "forced (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

# ─── The build is skipped on code it already built ────────────────────────
branch feat/built-once
FAKE_BUILD_SEC=0 FAKE_WAIT_SEC=1 FAKE_WAIT_EXIT=3 checked; rc=$?
{ [ "$rc" -eq 11 ] && grep -q "production build OK" "$tmp/out"; } \
    && ok "a build passes and the wait fails: nothing merged" || bad "built once (rc=$rc): $(cat "$tmp/out")"
FAKE_BUILD_SEC=0 FAKE_WAIT_SEC=0 checked; rc=$?
{ [ "$rc" -eq 0 ] && ! grep -q "build started" "$FAKE_LOG" && grep -q "pr merge" "$FAKE_LOG" \
  && grep -q "production build: code unchanged since the last pass (comments and whitespace only) — production build skipped" "$tmp/out"; } \
    && ok "…the retry on the same code skips the build, saying so, and merges" || bad "retry build (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"
branch feat/built-failed
FAKE_BUILD_EXIT=1 FAKE_WAIT_SEC=0 checked; rc=$?
FAKE_BUILD_SEC=0 FAKE_WAIT_SEC=0 checked; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "build started" "$FAKE_LOG"; } \
    && ok "a failed build is never recorded: the retry builds again" || bad "retry after failure (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

exit "$fail"
