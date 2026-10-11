#!/usr/bin/env bash
# Regression suite for file-issue.sh: an issue filed here lands on the configured
# board in the same step, one filed under another owner does not, and a board
# failure is loud while still naming the issue that exists. gh is a stub.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" | head -c 200 >> "$GH_LOG"; echo >> "$GH_LOG"
q=""; for a in "$@"; do case "$a" in query=*) q="$a";; esac; done
case "$1 $2" in
  "issue create")
    [ "${GH_MODE:-}" = create-fails ] && { echo "HTTP 404: Not Found" >&2; exit 1; }
    repo=""; while [ $# -gt 0 ]; do [ "$1" = --repo ] && repo="$2"; shift; done
    echo "https://github.com/$repo/issues/12"; exit 0 ;;
esac
case "$q" in
  *addProjectV2ItemById*)
    [ "${GH_MODE:-}" = add-fails ] && { echo "Resource not accessible by integration" >&2; exit 1; }
    echo '{"data":{"addProjectV2ItemById":{"item":{"id":"ITEM_NEW"}}}}' ;;
  *projectItems*)
    echo '{"data":{"repository":{"issue":{"id":"ISSUE_12","projectItems":{"nodes":[]}}}}}' ;;
esac
STUB
chmod +x "$tmp/bin/gh"

cd "$tmp" || exit 1
git init -q; git remote add origin https://github.com/acme/app.git
mkdir -p .claude; printf 'GITFLOW_PROJECT_ID=PROJ\n' > .claude/gitflow-project.conf
printf 'Body.\n' > body.md
run(){ : > "$tmp/gh.log"; PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" bash "$D/file-issue.sh" "$@" >"$tmp/out" 2>"$tmp/err"; echo $?; }

rc=$(run --title "Need a bucket" --body-file body.md --repo acme/acme-org)
{ [ "$rc" = 0 ] && [ "$(cat "$tmp/out")" = "https://github.com/acme/acme-org/issues/12" ] && grep -q addProjectV2ItemById "$tmp/gh.log"; } \
    && ok "filed in a repo of the same owner: created and put on the board, URL printed" || bad "same owner (rc=$rc): $(cat "$tmp/err")"

rc=$(run --title "x" --body-file body.md)
{ [ "$rc" = 0 ] && grep -q "issue create --repo acme/app" "$tmp/gh.log"; } \
    && ok "no --repo: filed in this repository" || bad "default repo (rc=$rc): $(cat "$tmp/gh.log")"

rc=$(run --title "x" --body-file body.md --repo kitowner/kit)
{ [ "$rc" = 0 ] && ! grep -q addProjectV2ItemById "$tmp/gh.log" && grep -q "another owner" "$tmp/err"; } \
    && ok "another owner's repo: created, not put on this board, and said so" || bad "other owner (rc=$rc): $(cat "$tmp/err")"

rc=$(GH_MODE=add-fails run --title "x" --body-file body.md --repo acme/acme-org)
{ [ "$rc" = 11 ] && grep -q "https://github.com/acme/acme-org/issues/12 was created but is not on the board" "$tmp/err"; } \
    && ok "board add fails: exit 11, naming the issue that exists" || bad "add fails (rc=$rc): $(cat "$tmp/err")"

rc=$(GH_MODE=create-fails run --title "x" --body-file body.md)
[ "$rc" = 9 ] && ok "creation fails: exit 9" || bad "create fails (rc=$rc)"

rm .claude/gitflow-project.conf
rc=$(run --title "x" --body-file body.md)
{ [ "$rc" = 0 ] && ! grep -q graphql "$tmp/gh.log" && grep -q "no project board configured" "$tmp/err"; } \
    && ok "no board configured: created, and said so" || bad "no board (rc=$rc): $(cat "$tmp/err")"

[ "$(run --title "x")" = 2 ] && ok "missing body: usage" || bad "usage"

exit "$fail"
