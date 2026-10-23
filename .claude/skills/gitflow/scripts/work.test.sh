#!/usr/bin/env bash
# Regression suite for work.sh --discussion.
#
# The human pastes whichever handle is to hand — the folder slug, or the artifact URL
# copied from a browser tab with whatever query or fragment it carried — so both must
# land on the same folder, and a miss must fail before the default mode touches main.
# Runs against a real clone because the default mode reads and refreshes git state.
set -uo pipefail
W="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/work.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# work.sh refuses when a global /work command exists; keep this machine's out of it.
export HOME="$tmp/home"; mkdir -p "$HOME"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
d=project-documentation/temporary/discussion-session-timeout
mkdir -p "$d"
cat > "$d/session-timeout-discussion.md" <<'MD'
---
slug: session-timeout
artifact: https://claude.ai/code/artifact/0b1c2d3e-aaaa-bbbb-cccc-111122223333
published: 2026-09-24
---
# Session Timeout Review

- D1 — Which option?
MD
printf '{}\n' > "$d/session-timeout.json"
printf 'reply\n' > "$d/feedback-product-owner.md"
git add -A; git commit -qm base; git push -q origin main

run() { out=$("$W" "$@" 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err"); }

# A retired global command shadowing the project's copy refuses before anything runs.
for c in work sync-dev-kit; do
    mkdir -p "$HOME/.claude/commands"; printf 'old\n' > "$HOME/.claude/commands/$c.md"
    run
    { [ "$rc" -eq 8 ] && grep -q "retired global /$c command" <<<"$err"; } \
        && ok "a global $c.md refuses /work" || bad "global $c.md (rc=$rc): $err"
    rm "$HOME/.claude/commands/$c.md"
done

run --discussion session-timeout
[ "$rc" -eq 0 ] && ok "slug resolves" || bad "slug resolves (rc=$rc): $err"
grep -q 'D1 — Which option?' <<<"$out" && ok "pointer printed" || bad "pointer printed: $out"
grep -q 'feedback-product-owner.md' <<<"$out" && ok "folder files listed" || bad "folder files listed: $out"
grep -q 'no branch cut' <<<"$err" && ok "default mode ran" || bad "default mode ran: $err"

run --discussion discussion-session-timeout/
[ "$rc" -eq 0 ] && ok "folder name resolves" || bad "folder name resolves (rc=$rc): $err"

run --discussion 'https://claude.ai/code/artifact/0b1c2d3e-aaaa-bbbb-cccc-111122223333/?tab=comments#d1'
[ "$rc" -eq 0 ] && grep -q 'session-timeout-discussion.md' <<<"$out" && ok "URL with query and fragment resolves" || bad "URL resolves (rc=$rc): $err"

# The shape a published artifact link actually takes: a short id, no /code/ segment.
sed -i.bak 's#^artifact: .*#artifact: https://claude.ai/artifact/18Rnsr3c5BD6ZzRmwmVuUY#' "$d/session-timeout-discussion.md" && rm "$d/session-timeout-discussion.md.bak"
run --discussion 'https://claude.ai/artifact/18Rnsr3c5BD6ZzRmwmVuUY'
[ "$rc" -eq 0 ] && ok "short artifact link resolves" || bad "short artifact link resolves (rc=$rc): $err"

before=$(git rev-parse HEAD)
run --discussion https://claude.ai/code/artifact/ffffffff-0000-0000-0000-000000000000
[ "$rc" -eq 4 ] && ok "unknown URL exits 4" || bad "unknown URL exits 4 (rc=$rc)"
grep -q 'session-timeout  https://claude.ai' <<<"$err" && ok "miss lists open discussions" || bad "miss lists open discussions: $err"
grep -q 'no branch cut' <<<"$err" && bad "miss ran the default mode" || ok "miss runs nothing else"
[ "$before" = "$(git rev-parse HEAD)" ] || bad "miss moved HEAD"

run --discussion nope
[ "$rc" -eq 4 ] && ok "unknown slug exits 4" || bad "unknown slug exits 4 (rc=$rc)"

run --discussion
[ "$rc" -eq 2 ] && ok "missing value exits 2" || bad "missing value exits 2 (rc=$rc): $err"

run --discussion session-timeout --retrieve main
[ "$rc" -eq 2 ] && ok "conflicting mode exits 2" || bad "conflicting mode exits 2 (rc=$rc)"


# Started on a stale main with edits already made: /work refreshes main and the edits ride along.
git clone -q "$tmp/origin.git" "$tmp/up" 2>/dev/null
git -C "$tmp/up" config user.email t@example.com; git -C "$tmp/up" config user.name t
push_up(){ printf '%s\n' "$2" > "$tmp/up/$1"; git -C "$tmp/up" add -A; git -C "$tmp/up" commit -qm "up $1"; git -C "$tmp/up" push -q origin main; }
git checkout -q main 2>/dev/null
push_up tracked.txt base
run
push_up upstream.txt new
printf 'started before catching up\n' > tracked.txt
run
{ [ "$rc" -eq 0 ] && [ -f upstream.txt ] && [ "$(cat tracked.txt)" = 'started before catching up' ] \
  && [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] && [ -z "$(git stash list)" ]; } \
    && ok "/work on a stale main with an uncommitted edit refreshes main and keeps the edit" || bad "dirty refresh (rc=$rc): $err"


# /work <N> asks GitHub whether N is a pull request; a PR is picked up by switching to its branch.
git checkout -q main 2>/dev/null; git checkout -q -- . 2>/dev/null; git clean -qfd 2>/dev/null
git -C "$tmp/up" checkout -q -b feat/alice-design
printf 'design\n' > "$tmp/up/design.txt"; git -C "$tmp/up" add -A; git -C "$tmp/up" commit -qm "feat: design"; git -C "$tmp/up" push -q origin feat/alice-design 2>/dev/null
mkdir -p "$tmp/fakegh"
cat > "$tmp/fakegh/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "api repos/{owner}/{repo}/issues/"*) n=${2##*/}; case " $FAKE_PRS " in *" $n "*) echo true ;; *) echo false ;; esac ;;
  "pr view "*) printf '%s\tfeat/alice-design\tfalse\thttps://github.com/acme/app/pull/76\n' "$FAKE_STATE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/fakegh/gh"
runpr(){ out=$(PATH="$tmp/fakegh:$PATH" FAKE_PRS="76" FAKE_STATE="${STATE:-OPEN}" "$W" "$@" 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err"); }

runpr 76
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = feat/alice-design ] && grep -q "picked up PR #76" <<<"$err"; } \
    && ok "/work <PR#> switches to the PR's branch" || bad "pickup (rc=$rc): $err"
git checkout -q main
STATE=MERGED runpr 76
{ [ "$rc" -eq 0 ] && [ "$(git branch --show-current)" = main ] && grep -q "merged — nothing to pick up" <<<"$err"; } \
    && ok "a merged PR says so and switches nothing" || bad "merged (rc=$rc): $err"
runpr 42 76
{ [ "$rc" -eq 2 ] && grep -q "#76 is a pull request" <<<"$err"; } \
    && ok "a PR among issues is refused before anything is linked" || bad "mixed (rc=$rc): $err"
runpr 42
! grep -q "pull request\|picked up" <<<"$err" && ok "an issue number still takes the issue path" || bad "issue path: $err"


# ─── --worktree: opt-in isolation ─────────────────────────────────────────
git -C "$tmp/up" checkout -q main
printf '.env\n.env.*\n!.env.example\n.claude/settings.local.json\n.claude/worktrees/\nnode_modules/\n' > "$tmp/up/.gitignore"
printf '{"lockfileVersion":3}\n' > "$tmp/up/package-lock.json"
git -C "$tmp/up" add -A; git -C "$tmp/up" commit -qm "chore: ignore"; git -C "$tmp/up" push -q origin main
git clone -q "$tmp/origin.git" "$tmp/prim" 2>/dev/null
cd "$tmp/prim" || exit 1
git config user.email t@example.com; git config user.name t
printf 'SECRET=1\n' > .env; mkdir -p .claude apps/web; printf '{}\n' > .claude/settings.local.json; printf 'K=1\n' > apps/web/.env.local
cat > "$tmp/fakegh/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "api user --jq .login") echo alice ;;
  "issue view 42 --json title --jq .title") echo "Fix: the login page!" ;;
  "api repos/{owner}/{repo}/issues/"*) echo false ;;
  "issue view 42 --json number"*) echo "ISSUE 42 BODY" ;;
  *) exit 0 ;;
esac
EOF
cat > "$tmp/fakegh/npm" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$NPM_LOG"
EOF
chmod +x "$tmp/fakegh/npm"
export NPM_LOG="$tmp/npm.log"
runwt(){ : > "$NPM_LOG"; out=$(PATH="$tmp/fakegh:$PATH" "$W" "$@" 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err"); }
P=$(git worktree list --porcelain | sed -n '1s/^worktree //p')

runwt --worktree spike
wt="$P/.claude/worktrees/spike"
{ [ "$rc" -eq 0 ] && grep -qx "WORKTREE: $wt" <<<"$out" && [ "$(git -C "$wt" branch --show-current)" = wip/alice-spike ] \
  && [ "$(git -C "$wt" rev-parse HEAD)" = "$(git rev-parse origin/main)" ]; } \
    && ok "--worktree <name> creates .claude/worktrees/<name> on wip/<login>-<name>, from origin/main" || bad "create (rc=$rc): $err"
! git -C "$wt" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1 \
    && ok "the worktree's branch has no upstream" || bad "upstream: $(git -C "$wt" rev-parse --abbrev-ref '@{u}')"
{ [ "$(readlink "$wt/.env")" = "$P/.env" ] && [ "$(readlink "$wt/.claude/settings.local.json")" = "$P/.claude/settings.local.json" ] \
  && [ "$(readlink "$wt/apps/web/.env.local")" = "$P/apps/web/.env.local" ] && [ ! -e "$wt/node_modules" ]; } \
    && ok "per-machine files are linked from the primary with absolute targets; node_modules is not" || bad "links: $(ls -la "$wt" "$wt/apps/web")"
grep -qx "ci --no-audit --no-fund" "$NPM_LOG" && ok "dependencies install from the lockfile (npm ci)" || bad "install: $(cat "$NPM_LOG")"
[ -z "$(git status --porcelain)" ] && ok "the primary checkout shows nothing new (the worktree is ignored)" || bad "primary dirty: $(git status --porcelain)"

rm "$wt/.env"
runwt --worktree spike
{ [ "$rc" -eq 0 ] && grep -q "re-entering worktree 'spike'" <<<"$err" && [ -L "$wt/.env" ] && [ ! -s "$NPM_LOG" ]; } \
    && ok "re-running re-enters, heals a missing link, installs nothing" || bad "re-enter (rc=$rc): $err"
printf 'Worktree handoff\n' > "$wt/.claude/worktree-handoff.md"
runwt --worktree spike
grep -qx "WORKTREE-HANDOFF: $wt/.claude/worktree-handoff.md" <<<"$out" && ok "re-entry points at the worktree's own handoff" || bad "handoff: $out"

runwt --worktree 42
wt42="$P/.claude/worktrees/42-fix-the-login-page"
{ [ "$rc" -eq 0 ] && [ -d "$wt42" ] && [ "$(git -C "$wt42" branch --show-current)" = wip/alice-42-fix-the-login-page ] \
  && [ "$(git config --get branch.wip/alice-42-fix-the-login-page.gitflow-issues)" = 42 ] && grep -q "ISSUE 42 BODY" <<<"$out"; } \
    && ok "--worktree <issue#> labels it <N>-<title slug>, links the issue, dumps its context" || bad "issue worktree (rc=$rc): $err"
runwt --worktree '#42'
{ [ "$rc" -eq 0 ] && grep -q "re-entering worktree '42-fix-the-login-page'" <<<"$err"; } \
    && ok "the same issue re-enters its worktree by number" || bad "issue re-enter (rc=$rc): $err"

runwt --worktree
lbl=$(grep '^WORKTREE: ' <<<"$out" | sed 's#.*/##')
[[ "$lbl" =~ ^alice-[0-9]{8}-[0-9]{4}$ ]] && ok "a bare --worktree is labelled <login>-<YYYYMMDD-HHMM>" || bad "default label: '$lbl' ($err)"

runwt --worktree 'bad name'
[ "$rc" -eq 2 ] && ok "a name with a space is refused" || bad "bad name (rc=$rc)"

runwt
{ grep -qx "You have an open worktree spike (branch wip/alice-spike). Work in it, or here?" <<<"$out" \
  && grep -q "open worktree 42-fix-the-login-page" <<<"$out"; } \
    && ok "/work in the primary names each open worktree and asks" || bad "primary prompt: $out"
( cd "$wt" && PATH="$tmp/fakegh:$PATH" "$W" >"$tmp/o" 2>"$tmp/err" )
! grep -q "open worktree" "$tmp/o" && grep -q "resuming body of work on 'wip/alice-spike'" "$tmp/err" \
    && ok "/work inside a worktree resumes it and asks nothing" || bad "inside: $(cat "$tmp/o" "$tmp/err")"

exit "$fail"
