#!/usr/bin/env bash
# Regression suite for open-pr.sh's PR ownership: who it is assigned to, handing it
# over (--to, GITFLOW_PR_TO), re-assigning an open PR, and a stacked branch opening
# against its parent. Runs against a real origin; gh is a fake that answers from
# FAKE_* and records every call.
set -uo pipefail
# changed-roots.sh sits in the terraform skill beside this one; in the kit's own
# .claude/, which does not carry that skill, it is read from the kit source.
CHANGED_ROOTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../terraform/scripts/changed-roots.sh"
[ -f "$CHANGED_ROOTS" ] || CHANGED_ROOTS="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null)/_claude-project/skills/terraform/scripts/changed-roots.sh"
[ -f "$CHANGED_ROOTS" ] || { echo "FAIL changed-roots.sh not found"; exit 1; }
O="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/open-pr.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
export HOME="$tmp/home"; mkdir -p "$HOME"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > a.txt; git add -A; git commit -qm base; git push -q origin main
printf '{"GEMINI_NOT_INSTALLED":"true"}\n' > "$tmp/subs.json"; mkdir -p .claude; cp "$tmp/subs.json" .claude/sync-substitutions.json
git add -A; git commit -qm subs; git push -q origin main

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$*" in
  "api user --jq .login") echo alice ;;
  "pr list --head "*"--state open --json number"*) printf '%s\n' "${FAKE_EXISTING:-}" ;;
  "pr list --head "*"--state all --json state"*) printf '%s\n' "${FAKE_PARENT_STATE:-}" ;;
  "pr list"*) echo "" ;;
  "pr create"*) echo "https://github.com/acme/app/pull/77" ;;
  "pr view "*"--json author,assignees"*) printf 'alice\t%s\n' "${FAKE_ASSIGNEES:-}" ;;
  "pr comment"*) cat >/dev/null ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export FAKE_LOG="$tmp/gh.log"
branch(){ git checkout -q main; git checkout -q -b "$1"; printf '%s\n' "$1" > "f-${1//\//-}.txt"; git add -A; git commit -qm "feat: $1"; }
open(){ : > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "body" "$@" >"$tmp/out" 2>&1; }
called(){ grep -qx -- "$1" "$FAKE_LOG"; }

branch feat/own
open; rc=$?
{ [ "$rc" -eq 0 ] && called "pr edit 77 --add-assignee alice"; } \
    && ok "a PR opens assigned to its author, no review asked of them" || bad "own PR (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

branch feat/handed
open --to bob; rc=$?
{ [ "$rc" -eq 0 ] && called "pr edit 77 --add-assignee bob --add-reviewer bob" && grep -q "handed to @bob" "$tmp/out"; } \
    && ok "--to hands it over: assigned to the taker, their review requested" || bad "--to (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

branch feat/default
: > "$FAKE_LOG"; GITFLOW_PR_TO=carol PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "body" >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && called "pr edit 77 --add-assignee carol --add-reviewer carol"; } \
    && ok "GITFLOW_PR_TO names the taker when --to is not given" || bad "env default (rc=$rc): $(cat "$FAKE_LOG")"

branch feat/keep
: > "$FAKE_LOG"; GITFLOW_PR_TO=carol PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "body" --to me >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && called "pr edit 77 --add-assignee alice"; } \
    && ok "--to me keeps it, whatever the default says" || bad "--to me (rc=$rc): $(cat "$FAKE_LOG")"

: > "$FAKE_LOG"; GITFLOW_PR_TO=ask PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "body" >"$tmp/out" 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unanswered 'ask' never opens a PR" || bad "ask unresolved (rc=$rc)"

: > "$FAKE_LOG"; FAKE_EXISTING=76 FAKE_ASSIGNEES=alice PATH="$tmp/bin:$PATH" "$O" --to bob >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && called "pr edit 76 --add-assignee bob --remove-assignee alice --add-reviewer bob" && ! grep -q "pr create" "$FAKE_LOG"; } \
    && ok "an already-open PR is re-assigned, nothing else" || bad "re-assign (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"
: > "$FAKE_LOG"; FAKE_EXISTING=76 PATH="$tmp/bin:$PATH" "$O" --title t --body b >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 3 ] && grep -q -- "--to <login>" "$tmp/out"; } \
    && ok "an already-open PR without --to says how to hand it over" || bad "existing, no --to (rc=$rc): $(cat "$tmp/out")"

branch feat/stacked
git config branch.feat/stacked.gitflow-parent feat/handed
FAKE_PARENT_STATE=OPEN open; rc=$?
{ [ "$rc" -eq 0 ] && grep -q -- "pr create .*--base feat/handed" "$FAKE_LOG"; } \
    && ok "a stacked branch opens against its parent while the parent's PR is open" || bad "stacked open parent (rc=$rc): $(cat "$FAKE_LOG")"

branch feat/stacked2
git config branch.feat/stacked2.gitflow-parent feat/handed
FAKE_PARENT_STATE=MERGED open; rc=$?
{ [ "$rc" -eq 0 ] && grep -q -- "pr create .*--base main" "$FAKE_LOG" && [ -z "$(git config branch.feat/stacked2.gitflow-parent)" ]; } \
    && ok "once the parent merged, it opens against main and forgets the parent" || bad "stacked merged parent (rc=$rc): $(cat "$FAKE_LOG")"

# ─── Org repo: a Terraform PR carries a plan for every root it changes ─────
git checkout -q main
mkdir -p .claude/skills/terraform/scripts infra/terraform/shared
cp "$CHANGED_ROOTS" .claude/skills/terraform/scripts/
printf '{"GEMINI_NOT_INSTALLED":"true","REPO_KIND":"org"}\n' > .claude/sync-substitutions.json
printf 'terraform {}\n' > infra/terraform/shared/main.tf; touch infra/terraform/shared/.terraform.lock.hcl
git add -A; git commit -qm org; git push -q origin main
git checkout -q -b infra/bucket
printf 'resource "x" "y" {}\n' >> infra/terraform/shared/main.tf; git add -A; git commit -qm "feat: bucket"
open; rc=$?
{ [ "$rc" -eq 14 ] && grep -q "no plan for: shared" "$tmp/out" && ! grep -q "pr create" "$FAKE_LOG"; } \
    && ok "org repo: a changed root with no plan in the body is refused before the push" || bad "org no plan (rc=$rc): $(cat "$tmp/out")"
: > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "$(printf 'Adds a bucket.\n\n<!-- plan:shared -->\n```text\ncreate x.y\n```\n<!-- /plan:shared -->')" >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr create" "$FAKE_LOG"; } \
    && ok "org repo: with every root's plan in the body, it opens" || bad "org with plan (rc=$rc): $(cat "$tmp/out")"
git checkout -q main; git checkout -q -b infra/audited
printf '{"GEMINI_NOT_INSTALLED":"true","REPO_KIND":"org","ORG_AUDIT":"on"}\n' > .claude/sync-substitutions.json
printf 'resource "x" "z" {}\n' >> infra/terraform/shared/main.tf; git add -A; git commit -qm "feat: audited"
BODY_OK="$(printf 'x\n\n<!-- plan:shared -->\n```text\ncreate x.z\n```\n<!-- /plan:shared -->')"
: > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "$BODY_OK" >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 15 ] && grep -q "must link the issue" "$tmp/out" && ! grep -q "pr create" "$FAKE_LOG"; } \
    && ok "org repo, ORG_AUDIT on: a PR linking no issue is refused before the push" || bad "audit no issue (rc=$rc): $(cat "$tmp/out")"
git config branch.infra/audited.gitflow-issues 9; git config branch.infra/audited.gitflow-complete 9; git config branch.infra/audited.gitflow-noted 9
: > "$FAKE_LOG"; PATH="$tmp/bin:$PATH" "$O" --title "✨ feat: x" --body "$BODY_OK" >"$tmp/out" 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "pr create" "$FAKE_LOG"; } \
    && ok "org repo, ORG_AUDIT on: with its issue linked, it opens" || bad "audit with issue (rc=$rc): $(cat "$tmp/out")"
printf '{"GEMINI_NOT_INSTALLED":"true","REPO_KIND":"org"}\n' > .claude/sync-substitutions.json; git add -A; git commit -qm "chore: audit off"

git checkout -q main; git checkout -q -b docs/overview
printf 'docs\n' > notes.md; git add -A; git commit -qm "docs: notes"
open; rc=$?
[ "$rc" -eq 0 ] && ok "org repo: a branch changing no root needs no plan" || bad "org docs branch (rc=$rc): $(cat "$tmp/out")"

# ─── Part of an issue: advances it without closing it ─────────────────────
git checkout -q main; printf '{"GEMINI_NOT_INSTALLED":"true"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: app again" 2>/dev/null; git push -q origin main 2>/dev/null
branch feat/partial
git config branch.feat/partial.gitflow-issues 9
open; rc=$?
{ [ "$rc" -eq 12 ] && grep -q -- "--part" "$tmp/out"; } \
    && ok "a linked issue neither complete nor part: refused, offering --part" || bad "no part (rc=$rc): $(cat "$tmp/out")"
open --part 9 --complete 9; rc=$?
[ "$rc" -eq 2 ] && ok "an issue named both complete and part: refused" || bad "both (rc=$rc): $(cat "$tmp/out")"
open --part 9; rc=$?
{ [ "$rc" -eq 0 ] && grep -q "Part of #9" "$FAKE_LOG" && ! grep -qi "closes #9" "$FAKE_LOG"; } \
    && ok "--part: the PR opens saying Part of #9, and closes nothing" || bad "part (rc=$rc): $(cat "$tmp/out"; cat "$FAKE_LOG")"

exit "$fail"
