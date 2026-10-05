#!/usr/bin/env bash
# Regression suite for merge.sh's PR-ownership behaviour: a stacked PR whose parent
# has not merged is refused, and merging someone else's PR records an approval first.
# Runs with --force-unchecked (no CI wait, no build) against a real origin; gh is a
# fake that answers from FAKE_* and records every call.
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

exit "$fail"
