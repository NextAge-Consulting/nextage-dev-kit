#!/usr/bin/env bash
# Regression suite for two of deploy.sh's gates: an org repo hands over to
# deploy-org.sh, and an app release whose commits name `Needs <org-repo>#N` waits
# until that org PR is merged. Runs --check-only under the github backend against a
# real origin; gh is a fake answering from FAKE_*, and deploy-org.sh is a stub.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

bin="$tmp/scripts"; mkdir -p "$bin"
cp "$D/deploy.sh" "$D/issue_helpers.sh" "$bin/"
printf '#!/bin/bash\necho "deploy-org ran: $*"\n' > "$bin/deploy-org.sh"
chmod +x "$bin"/*.sh

mkdir -p "$tmp/fake"
cat > "$tmp/fake/gh" <<'GH'
#!/bin/bash
case "$*" in
  "api repos/{owner}/{repo}/commits/"*) echo 0 ;;
  "api graphql "*"o=acme -f r=acme-org -F n=12 "*) echo "${FAKE_ORG_STATE:-merged}" ;;
  "api graphql "*) echo "GraphQL: Could not resolve to a Repository" >&2; exit 1 ;;
  *) exit 0 ;;
esac
GH
chmod +x "$tmp/fake/gh"

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@example.com; git config user.name t
mkdir -p .claude
printf '{"DEPLOY_BACKEND":"github","DEPLOY_WORKFLOWS":"deploy.yml"}\n' > .claude/sync-substitutions.json
git add -A; git commit -qm "chore: base"; git tag v1.0.0; git push -q origin main v1.0.0
run(){ PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --check-only >"$tmp/out" 2>&1; echo $?; }
land(){ printf '%s\n' "$RANDOM" > "f$RANDOM.txt"; git add -A; git commit -qm "$1"; git push -q origin main; }

land "✨ feat: uploads

Adds uploads."
[ "$(run)" = 0 ] && grep -q "infrastructure live" "$tmp/out" && ok "a release naming no org PR passes" || bad "no needs: $(cat "$tmp/out")"

land "✨ feat: avatars

Needs acme/acme-org#12"
[ "$(FAKE_ORG_STATE='PR open' run)" = 25 ] && grep -q "needs acme/acme-org#12 (PR open)" "$tmp/out" \
    && ok "an org PR still open stops the release, naming it" || bad "open needs: $(cat "$tmp/out")"
[ "$(FAKE_ORG_STATE='issue open, no merged PR yet' run)" = 25 ] && grep -q "(issue open, no merged PR yet)" "$tmp/out" \
    && ok "an org issue no merged PR closes yet stops the release" || bad "open issue: $(cat "$tmp/out")"
[ "$(FAKE_ORG_STATE=merged run)" = 0 ] && grep -q "needs acme/acme-org#12 — live" "$tmp/out" \
    && ok "once the org change is merged, the release passes" || bad "merged needs: $(cat "$tmp/out")"

land "🐛 fix: x

Needs acme/acme-org#99"
[ "$(run)" = 25 ] && grep -q "could not say whether it is live" "$tmp/out" \
    && ok "an org PR GitHub cannot read stops the release" || bad "unreadable needs: $(cat "$tmp/out")"

git checkout -q -b infra/x
printf '{"REPO_KIND":"org"}\n' > .claude/sync-substitutions.json
out=$(PATH="$tmp/fake:$PATH" bash "$bin/deploy.sh" --level patch 2>&1)
[ "$out" = "deploy-org ran: --level patch" ] && ok "an org repo hands /deploy to deploy-org.sh, arguments intact" || bad "org handoff: $out"

exit "$fail"
