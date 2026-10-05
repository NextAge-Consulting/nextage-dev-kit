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

exit "$fail"
