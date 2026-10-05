#!/usr/bin/env bash
# Regression suite for the main-drift helpers in branch_helpers.sh.
#
# main_drift_report and main_merge_conflicts decide whether /work, /commit and
# /open-pr warn that main has moved and whether /merge refuses before its build.
# They run against a real origin and clone rather than a mock, because what they
# read IS git's ref and merge state.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/branch_helpers.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
printf 'a\n' > shared.txt; printf 'x\n' > mine.txt
git add -A; git commit -qm base; git push -q origin main

# shellcheck source=./branch_helpers.sh
source "$S"

# Up to date: silent, 0.
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && ok "up to date is silent" || bad "up to date is silent (rc=$rc out=$out)"

# Someone else lands a commit touching shared.txt.
git clone -q "$tmp/origin.git" "$tmp/other" 2>/dev/null
( cd "$tmp/other" && git config user.email o@example.com && git config user.name o \
  && printf 'theirs\n' > shared.txt && git commit -qam "their change" && git push -q origin main )

# On a stale main with an uncommitted edit to the same file: reports drift AND the overlap.
printf 'ours\n' > shared.txt
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 10 ] && ok "stale main returns 10" || bad "stale main returns 10 (rc=$rc)"
grep -q '1 commit(s) behind' <<<"$out" && ok "counts commits behind" || bad "counts commits behind: $out"
grep -q 'their change' <<<"$out" && ok "lists incoming commits" || bad "lists incoming commits: $out"
grep -q '    shared.txt' <<<"$out" && ok "uncommitted overlap reported on main" || bad "uncommitted overlap: $out"
grep -q 'fast-forward main' <<<"$out" && ok "main gets the fast-forward advice" || bad "main advice: $out"

# The same work committed on a feature branch: overlap still reported, branch advice.
git switch -qc feat/x; git commit -qam "our change"
out=$(main_drift_report main t 2>&1); rc=$?
[ "$rc" -eq 10 ] && grep -q '    shared.txt' <<<"$out" && ok "committed overlap reported on a branch" || bad "branch overlap (rc=$rc): $out"
grep -q 'merge main into this branch' <<<"$out" && ok "branch gets the merge advice" || bad "branch advice: $out"
grep -q 'mine.txt' <<<"$out" && bad "untouched file listed as overlap" || ok "only files changed on both sides"

# Trial merge: shared.txt changed differently on both sides → conflict, tree untouched.
before=$(git status --porcelain; git rev-parse HEAD)
out=$(main_merge_conflicts main 2>&1); rc=$?
[ "$rc" -eq 1 ] && grep -q '    shared.txt' <<<"$out" && ok "conflict detected and named" || bad "conflict (rc=$rc): $out"
[ "$before" = "$(git status --porcelain; git rev-parse HEAD)" ] && ok "trial merge touches nothing" || bad "trial merge changed the checkout"

# Safe inside a set -e caller: a conflict must be reported, not end the caller.
out=$(bash -c "set -eo pipefail; source '$S'; main_merge_conflicts main || echo rc=\$?; echo survived" 2>&1)
grep -q 'survived' <<<"$out" && grep -q 'rc=1' <<<"$out" && ok "safe under set -e" || bad "set -e caller: $out"

# A branch that does not overlap merges cleanly.
git switch -q main; git reset -q --hard origin/main 2>/dev/null || git reset -q --hard "origin/main"
git switch -qc feat/y; printf 'y\n' > mine.txt; git commit -qam "unrelated"
( cd "$tmp/other" && printf 'more\n' >> shared.txt && git commit -qam "more of theirs" && git push -q origin main )
git fetch -q origin main
main_merge_conflicts main 2>/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "non-overlapping drift merges cleanly" || bad "clean merge (rc=$rc)"


# post_gemini_review — the trigger reaches gh as stdin, and no argument starts with "/"
# (Git Bash would rewrite one into a Windows path before gh saw it).
mkdir -p "$tmp/stub"
cat > "$tmp/stub/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$GH_ARGS"
cat > "$GH_STDIN"
exit "${GH_EXIT:-0}"
EOF
chmod +x "$tmp/stub/gh"
export GH_ARGS="$tmp/gh.args" GH_STDIN="$tmp/gh.stdin"
PATH="$tmp/stub:$PATH" post_gemini_review 76; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$GH_STDIN")" = "/gemini review" ] \
    && ok "post_gemini_review sends the trigger on stdin" || bad "trigger body (rc=$rc, stdin=$(cat "$GH_STDIN"))"
if grep -q '^/' "$GH_ARGS"; then bad "an argument to gh starts with /: $(tr '\n' ' ' < "$GH_ARGS")"
else ok "no argument to gh starts with /"; fi
[ "$(tr '\n' ' ' < "$GH_ARGS")" = "pr comment 76 --body-file - " ] && ok "gh is asked to comment on the named PR" \
    || bad "gh args: $(tr '\n' ' ' < "$GH_ARGS")"
GH_EXIT=1 PATH="$tmp/stub:$PATH" post_gemini_review 76; rc=$?
[ "$rc" -ne 0 ] && ok "a gh failure is the helper's failure" || bad "gh failure swallowed"


# fast_forward_local_main on a main with uncommitted changes: they ride across the
# fast-forward (git's --autostash), the usual case being work started before catching up.
git init -q --bare -b main "$tmp/ff-origin.git"
git clone -q "$tmp/ff-origin.git" "$tmp/ff-up" 2>/dev/null
git clone -q "$tmp/ff-origin.git" "$tmp/ff-dev" 2>/dev/null
for c in ff-up ff-dev; do git -C "$tmp/$c" config user.email t@example.com; git -C "$tmp/$c" config user.name t; done
printf 'a\n' > "$tmp/ff-up/a.txt"; printf 'b\n' > "$tmp/ff-up/b.txt"
git -C "$tmp/ff-up" add -A; git -C "$tmp/ff-up" commit -qm base; git -C "$tmp/ff-up" push -q origin main
git -C "$tmp/ff-dev" pull -q origin main 2>/dev/null
upstream(){ printf '%s\n' "$2" > "$tmp/ff-up/$1"; git -C "$tmp/ff-up" add -A; git -C "$tmp/ff-up" commit -qm "up $1"; git -C "$tmp/ff-up" push -q origin main; }
# shellcheck source=./branch_helpers.sh
ffm(){ (cd "$tmp/ff-dev" && source "$S" && fast_forward_local_main) 2>"$tmp/ff.err"; }
stashes(){ git -C "$tmp/ff-dev" stash list | wc -l | tr -d ' '; }
at_origin(){ [ "$(git -C "$tmp/ff-dev" rev-parse HEAD)" = "$(git -C "$tmp/ff-dev" rev-parse origin/main)" ]; }

printf 'mine\n' > "$tmp/ff-dev/a.txt"
ffm; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(stashes)" = 0 ] && [ "$(cat "$tmp/ff-dev/a.txt")" = mine ]; } \
    && ok "dirty main, nothing new: nothing stashed, the edit untouched" || bad "nothing new (rc=$rc, stashes=$(stashes))"

upstream b.txt theirs
printf 'staged\n' > "$tmp/ff-dev/c.txt"; git -C "$tmp/ff-dev" add c.txt
ffm; rc=$?
{ [ "$rc" -eq 0 ] && at_origin && [ "$(cat "$tmp/ff-dev/b.txt")" = theirs ] && [ "$(cat "$tmp/ff-dev/a.txt")" = mine ] \
  && [ "$(cat "$tmp/ff-dev/c.txt")" = staged ] && [ "$(stashes)" = 0 ]; } \
    && ok "dirty main: fast-forwarded, every uncommitted change (staged too) carried across, no stash left" \
    || bad "carry (rc=$rc, stashes=$(stashes)): $(cat "$tmp/ff.err")"
grep -q "back in place" "$tmp/ff.err" && ok "…and it says the changes are back" || bad "carry message: $(cat "$tmp/ff.err")"

upstream a.txt upstream-a
ffm; rc=$?
{ [ "$rc" -eq 8 ] && at_origin && [ "$(stashes)" = 1 ] && grep -q "conflicted: a.txt" "$tmp/ff.err"; } \
    && ok "an edit to the same lines: main moves, exit 8, the changes kept in the stash, the file named" \
    || bad "conflict (rc=$rc, stashes=$(stashes)): $(cat "$tmp/ff.err")"
git -C "$tmp/ff-dev" stash show -p 'stash@{0}' | grep -q '^+mine' && ok "…and the stash holds the edit" || bad "stash content"
grep -q '^<<<<<<<' "$tmp/ff-dev/a.txt" && ok "…and the file holds conflict markers to resolve" || bad "no markers in a.txt: $(cat "$tmp/ff-dev/a.txt")"
git -C "$tmp/ff-dev" checkout -q -- . 2>/dev/null; git -C "$tmp/ff-dev" reset -q; git -C "$tmp/ff-dev" stash drop -q
git -C "$tmp/ff-dev" clean -qfd

printf 'mine\n' > "$tmp/ff-dev/z.txt"; printf 'edit\n' > "$tmp/ff-dev/b.txt"
upstream z.txt theirs-z
before=$(git -C "$tmp/ff-dev" rev-parse HEAD)
ffm; rc=$?
{ [ "$rc" -eq 5 ] && [ "$(git -C "$tmp/ff-dev" rev-parse HEAD)" = "$before" ] && [ "$(cat "$tmp/ff-dev/z.txt")" = mine ] \
  && [ "$(cat "$tmp/ff-dev/b.txt")" = edit ] && [ "$(stashes)" = 0 ]; } \
    && ok "an untracked file the pull would overwrite: exit 5, main and every change left as they were" \
    || bad "untracked clash (rc=$rc, stashes=$(stashes)): $(cat "$tmp/ff.err")"
rm -f "$tmp/ff-dev/z.txt"; git -C "$tmp/ff-dev" checkout -q -- b.txt
git -C "$tmp/ff-dev" pull -q origin main 2>/dev/null

printf 'c\n' > "$tmp/ff-dev/cp.txt"; git -C "$tmp/ff-dev" add cp.txt
# shellcheck source=./branch_helpers.sh
git -C "$tmp/ff-dev" commit -qm "$(cd "$tmp/ff-dev" && source "$S" && printf '%s' "$CHECKPOINT_PREFIX") local"
upstream b.txt again
printf 'mine\n' > "$tmp/ff-dev/a.txt"
ffm; rc=$?
{ [ "$rc" -eq 7 ] && [ "$(stashes)" = 0 ] && [ "$(cat "$tmp/ff-dev/a.txt")" = mine ]; } \
    && ok "a local checkpoint refuses before anything is stashed" || bad "checkpoint (rc=$rc, stashes=$(stashes)): $(cat "$tmp/ff.err")"


# PR hand-off helpers, against a fake gh that answers from FAKE_* and records each call.
mkdir -p "$tmp/fakegh"
cat > "$tmp/fakegh/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_LOG"
[ -n "${FAKE_FAIL:-}" ] && exit 1
case "$*" in
  "api user --jq .login") printf '%s\n' "$FAKE_ME" ;;
  "pr list --head "*"--state open --json assignees"*) printf '%s\n' "${FAKE_ASSIGNEES:-}" ;;
  "pr list --head "*"--state open --json number"*) printf '%s\n' "${FAKE_PR:-}" ;;
  "pr list --head "*"--state all --json state"*) printf '%s\n' "${FAKE_STATE:-}" ;;
  "api repos/{owner}/{repo}/collaborators"*) printf '%s\n' $FAKE_COLLABS ;;
  "pr view "*"--json author,assignees"*) printf '%s\t%s\n' "$FAKE_AUTHOR" "${FAKE_ASSIGNEES:-}" ;;
  "pr edit "*) ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "$tmp/fakegh/gh"
export FAKE_LOG="$tmp/fakegh.log" FAKE_ME=alice
fg(){ : > "$FAKE_LOG"; PATH="$tmp/fakegh:$PATH" "$@"; }

FAKE_ASSIGNEES="bob" fg pr_handed_off feat/a >/dev/null; rc=$?
[ "$rc" -eq 0 ] && ok "a PR assigned to someone else is handed off" || bad "assigned elsewhere (rc=$rc)"
out=$(FAKE_ASSIGNEES="bob carol" fg pr_handed_off feat/a)
[ "$out" = "bob carol" ] && ok "…and it names who has it" || bad "holder: $out"
FAKE_ASSIGNEES="alice" fg pr_handed_off feat/a; rc=$?
[ "$rc" -eq 1 ] && ok "a PR assigned to you is still yours" || bad "assigned to me (rc=$rc)"
FAKE_ASSIGNEES="bob alice" fg pr_handed_off feat/a >/dev/null; rc=$?
[ "$rc" -eq 1 ] && ok "a PR shared with you is still yours" || bad "shared (rc=$rc)"
FAKE_ASSIGNEES="" fg pr_handed_off feat/a; rc=$?
[ "$rc" -eq 1 ] && ok "an unassigned PR, or none at all, is still yours" || bad "unassigned (rc=$rc)"
FAKE_FAIL=1 fg pr_handed_off feat/a; rc=$?
[ "$rc" -eq 2 ] && ok "gh unable to answer is its own answer, never 'handed off'" || bad "gh failure (rc=$rc)"

out=$(FAKE_COLLABS="bob alice carol" fg list_collaborators | tr '\n' ' ')
[ "$out" = "bob carol " ] && ok "collaborators are listed without you" || bad "collaborators: $out"

FAKE_AUTHOR=alice FAKE_ASSIGNEES="alice" fg hand_pr_to 76 bob; rc=$?
grep -qx "pr edit 76 --add-assignee bob --remove-assignee alice --add-reviewer bob" "$FAKE_LOG" && [ "$rc" -eq 0 ] \
    && ok "handing a PR over makes the taker its only assignee and asks for their review" || bad "hand-off call: $(cat "$FAKE_LOG")"
FAKE_AUTHOR=alice FAKE_ASSIGNEES="bob" fg hand_pr_to 76 alice
grep -qx "pr edit 76 --add-assignee alice --remove-assignee bob" "$FAKE_LOG" \
    && ok "taking it back asks no review of its own author" || bad "take back: $(cat "$FAKE_LOG")"
FAKE_AUTHOR=alice FAKE_ASSIGNEES="" fg hand_pr_to 76 carol
grep -qx "pr edit 76 --add-assignee carol --add-reviewer carol" "$FAKE_LOG" \
    && ok "an unassigned PR just gains the taker" || bad "unassigned hand-off: $(cat "$FAKE_LOG")"

# shellcheck source=./branch_helpers.sh
(cd "$tmp/ff-dev" && source "$S" && set_branch_parent feat/b feat/a && [ "$(branch_parent feat/b)" = feat/a ] \
    && clear_branch_parent feat/b && [ -z "$(branch_parent feat/b)" ]) \
    && ok "a stacked branch's parent is recorded, read and cleared" || bad "parent record"

# shellcheck source=./branch_helpers.sh
# shellcheck source=./issue_helpers.sh
(cd "$tmp/ff-dev" && source "$(dirname "$S")/issue_helpers.sh" && source "$S" \
    && link_issue_to_branch 10 feat/a && link_issue_to_branch 11 feat/a && mark_issue_complete 10 feat/a \
    && link_issue_to_branch 12 feat/a && carry_incomplete_issues feat/a feat/b 2>/dev/null \
    && [ "$(read_branch_linked_issues feat/a)" = 10 ] && [ "$(read_branch_complete_issues feat/a)" = 10 ] \
    && [ "$(read_branch_linked_issues feat/b)" = "11 12" ]) \
    && ok "only the issues not yet complete follow the stacked branch" || bad "carry incomplete"

exit "$fail"
