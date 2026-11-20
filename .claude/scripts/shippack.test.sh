#!/usr/bin/env bash
# Regression suite for shippack.sh: the plan's version, counts and private-line checks,
# and the release against a throwaway packs origin. The kit is a throwaway repository
# holding the real `_claude-project`, so the plan's coverage is the real command's.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$D/shippack.sh"
REAL_KIT="$(cd "$D/../.." && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main

ROOT="$tmp/projects"; KIT="$ROOT/kit"; PACKS="$ROOT/packs"; ORIGIN="$tmp/packs-origin.git"
mkdir -p "$KIT" "$ROOT/acme-portal/.claude"
ln -s "$REAL_KIT/_claude-project" "$KIT/_claude-project"
git -C "$KIT" init -q
echo '{}' > "$ROOT/acme-portal/.claude/.kit-sync.json"

git init -q --bare "$ORIGIN"
git clone -q "$ORIGIN" "$PACKS" 2>/dev/null
echo "# Packs" > "$PACKS/README.md"
git -C "$PACKS" add -A; git -C "$PACKS" commit -qm "Initial commit"; git -C "$PACKS" push -q origin main

piece() { # piece <name> <file> <content>
    mkdir -p "$PACKS/pieces/$1/$(dirname "$2")"
    printf '%s\n' "$3" > "$PACKS/pieces/$1/$2"
    printf '{"files":["%s"],"pieces":[],"atoms":[],"roles":[],"packages":{},"imports":{}}\n' "$2" > "$PACKS/pieces/$1/piece.json"
}
piece card packages/ui/src/components/card.tsx 'export const Card = null'
piece page packages/web/src/reference/Page.tsx '// ui-status: pending
// ui-recipe: form.md
export const Page = null'
mkdir -p "$PACKS/packs"; echo '{"pieces":["card","page"]}' > "$PACKS/packs/office.json"

plan() { (cd "$KIT" && SHIPPACK_ANY_ORIGIN=1 SHIPPACK_TODAY="${TODAY:-2026.10.23}" bash "$S" --plan --packs "$PACKS" 2>"$tmp/err"); }
release() { (cd "$KIT" && SHIPPACK_ANY_ORIGIN=1 bash "$S" --release --packs "$PACKS" "$@" >"$tmp/out" 2>"$tmp/err"); echo $?; }
# Record a proof for every piece as it stands, as a successful --prove would.
proved() { node --input-type=module -e "
import fs from 'node:fs'
import { recordProof } from '$REAL_KIT/_claude-project/skills/design-packs/scripts/design-pack.mjs'
for (const n of fs.readdirSync('$PACKS/pieces')) if (fs.existsSync('$PACKS/pieces/' + n + '/piece.json')) recordProof('$PACKS/pieces', n)"; }

P=$(plan)
[ "$(jq -r .version <<<"$P")" = "2026.10.23" ] && [ "$(jq -r .previous_release <<<"$P")" = "" ] && [ "$(jq -r .files_changed <<<"$P")" = "5" ] && [ "$(jq -r .pieces <<<"$P")" = "2" ] \
    && ok "plan: the version is today's date, and every unpublished file is counted" || bad "plan: $P $(cat "$tmp/err")"
[ "$(jq -r '.private_hits | length' <<<"$P")" = "0" ] && jq -r .coverage <<<"$P" | grep -q "1 reference page" \
    && ok "plan: a clean pack has no private lines, and its coverage is reported" || bad "clean plan: $P"

# What must never be published: a project's name, a real address, a cloud resource, a key.
piece leak packages/ui/src/components/leak.tsx '// taken from acme-portal
export const who = "pat@acme.io"
export const sample = "jordan@example.com"
export const where = "arn:aws:s3:::bucket"
export const host = "10.1.2.3"
export const local = "127.0.0.1"
export const scope = "@design-pack/ui"'
P=$(plan)
H=$(jq -r '.private_hits[]' <<<"$P")
{ grep -q "acme-portal" <<<"$H" && grep -q "pat@acme.io" <<<"$H" && grep -q "arn:aws:s3" <<<"$H" && grep -q "10.1.2.3" <<<"$H"; } \
    && ok "plan: a project's name, a real email, a cloud resource name and an address are each reported" || bad "hits: $H"
{ ! grep -q "jordan@example.com" <<<"$H" && ! grep -q "127.0.0.1" <<<"$H" && ! grep -q '"@design-pack/ui"' <<<"$H"; } \
    && ok "plan: an example address, the local address and a package scope are not" || bad "false hits: $H"
rm -rf "$PACKS/pieces/leak"

[ "$(cd "$KIT" && bash "$S" --plan --packs "$PACKS" >/dev/null 2>"$tmp/err"; echo $?)" = 3 ] && grep -q "not of https://" "$tmp/err" \
    && ok "a checkout of another repository is refused (3)" || bad "wrong origin: $(cat "$tmp/err")"
[ "$(cd "$KIT" && SHIPPACK_ANY_ORIGIN=1 bash "$S" --prove --packs "$PACKS" >/dev/null 2>"$tmp/err"; echo $?)" = 2 ] && grep -q "needs --source" "$tmp/err" \
    && ok "prove without the source project stops (2)" || bad "prove no source: $(cat "$tmp/err")"

# The release.
[ "$(release --version 2026.10.23)" = 4 ] && grep -q "no recorded proof of what it is now" "$tmp/err" && grep -q "card, page" "$tmp/err" && [ -z "$(git -C "$PACKS" tag)" ] \
    && ok "release: pieces never proved are refused (4), named, nothing written" || bad "unproved: $(cat "$tmp/err")"
[ "$(jq -r '.to_prove | join(",")' <<<"$(plan)")" = "card,page" ] && ok "plan: the pieces still to prove are listed" || bad "to_prove: $(plan | jq -c .to_prove)"
proved
[ "$(jq -r '.to_prove | length' <<<"$(plan)")" = "0" ] && ok "plan: once each is proved as it stands, none is listed" || bad "to_prove after: $(plan | jq -c .to_prove)"
printf '%s\n' 'export const Card = 2' > "$PACKS/pieces/card/packages/ui/src/components/card.tsx"
[ "$(release --version 2026.10.23)" = 4 ] && grep -q "card" "$tmp/err" && ! grep -q "card, page" "$tmp/err" \
    && ok "release: a piece changed after its proof is refused (4); the unchanged one is not named" || bad "stale proof: $(cat "$tmp/err")"
proved
[ "$(release --version v1)" = 2 ] \
    && ok "release: a version that is not a date is refused (2)" || bad "bad version: $(cat "$tmp/err")"
git -C "$PACKS" checkout -q -b side
[ "$(release --version 2026.10.23)" = 4 ] && grep -q "made on main" "$tmp/err" \
    && ok "release: off main is refused (4)" || bad "off main: $(cat "$tmp/err")"
git -C "$PACKS" checkout -q main
before=$(git -C "$PACKS" rev-parse HEAD)
[ "$(release --version 2026.10.23)" = 0 ] && [ "$(jq -r .version "$tmp/out")" = "2026.10.23" ] \
  && [ "$(git -C "$PACKS" log -1 --format=%s)" = "📦 release: 2026.10.23" ] && [ "$(git -C "$PACKS" rev-parse HEAD)" != "$before" ] \
  && [ "$(git -C "$ORIGIN" rev-parse main)" = "$(git -C "$PACKS" rev-parse HEAD)" ] && git -C "$ORIGIN" rev-parse -q --verify refs/tags/2026.10.23 >/dev/null \
  && [ -z "$(git -C "$PACKS" status --porcelain)" ] \
    && ok "release: everything is committed, main and the tag are pushed, and the tree is clean" || bad "release: $(cat "$tmp/err") $(cat "$tmp/out")"
[ "$(git -C "$PACKS" describe --tags)" = "2026.10.23" ] \
    && ok "release: the checkout describes itself by the version, which is what an install records" || bad "describe: $(git -C "$PACKS" describe --tags 2>&1)"

[ "$(release --version 2026.10.23.2)" = 4 ] && grep -q "nothing has changed since the last release" "$tmp/err" \
    && ok "release: with nothing changed since the last release, it is refused (4)" || bad "nothing changed: $(cat "$tmp/err")"
piece badge packages/ui/src/components/badge.tsx 'export const Badge = null'
P=$(TODAY=2026.10.23 plan)
[ "$(jq -r .version <<<"$P")" = "2026.10.23.2" ] && [ "$(jq -r .previous_release <<<"$P")" = "2026.10.23" ] && [ "$(jq -r .files_changed <<<"$P")" = "2" ] && [ "$(jq -r '.to_prove | join(",")' <<<"$P")" = "badge" ] \
    && ok "plan: a second release on a day is suffixed, counts only what changed since the last, and only the new piece is to prove" || bad "second plan: $P"
proved
[ "$(release --version 2026.10.23)" = 4 ] && grep -q "already exists" "$tmp/err" \
    && ok "release: a version already tagged is refused (4)" || bad "tag exists: $(cat "$tmp/err")"

exit "$fail"
