#!/bin/bash
# /shippack's mechanics: releasing the Design Packs repository.
#
#   shippack.sh --plan [--packs <dir>]
#       Read-only. Prints JSON for the release about to be made: the packs checkout, the
#       version, how many files changed since its last release, every line naming a
#       project on this machine or carrying an address, a key or an account — the packs
#       repository is public — and each app pack's coverage.
#
#   shippack.sh --prove --source <project> [--packs <dir>] [--all]
#       Proves, against the project they were cut from, the pieces that have changed
#       since their proof was recorded — a piece, or one it depends on — and records each
#       proof in pieces/proved.json. --all proves every piece again.
#
#   shippack.sh --release --version <v> [--packs <dir>]
#       On main: commit everything as `📦 release: <v>`, push main, tag <v>, push the tag.
#       Refuses while any piece has no recorded proof of what it is now.
#
# The packs checkout is --packs, else the folder beside the kit named as the packs
# repository is. Versions are UTC dates, `2026.10.23`, and `2026.10.23.2` for a second
# release that day; an install records the version it took.
#
# Exit codes:
#   2  bad arguments
#   3  not run from the kit repository, or the packs checkout is not found or not the
#      packs repository
#   4  a release precondition failed: not on main, out of step with origin, nothing to
#      release, the tag exists, or a piece has no recorded proof of what it is now —
#      nothing was written
#   5  a piece does not prove
#   6  pushing the release commit failed: nothing is tagged, the commit is local
#   7  pushing the tag failed: the release commit is on main

set -u

fail() {
    echo "shippack: $1" >&2
    exit "$2"
}

MODE=""; PACKS=""; SOURCE=""; VERSION=""; ALL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE="plan"; shift ;;
        --prove) MODE="prove"; shift ;;
        --release) MODE="release"; shift ;;
        --packs) PACKS="${2:-}"; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --all) ALL="--all"; shift ;;
        *) fail "unknown argument: $1" 2 ;;
    esac
done
[ -n "$MODE" ] || fail "usage: shippack.sh --plan | --prove --source <project> [--all] | --release --version <v>" 2

KIT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not in a git repository." 3
CLI="$KIT/_claude-project/skills/design-packs/scripts/design-pack.mjs"
[ -f "$CLI" ] || fail "$KIT is not the dev-kit repository." 3
PACKS_URL=$(sed -n "s/^export const PACKS_REPOSITORY = '\(.*\)'.*/\1/p" "$CLI")
[ -n "$PACKS_URL" ] || fail "the packs repository is not named in $CLI." 3
[ -n "$PACKS" ] || PACKS="$(dirname "$KIT")/$(basename "$PACKS_URL")"
[ -d "$PACKS/.git" ] || fail "no packs checkout at $PACKS — clone $PACKS_URL there, or name it with --packs." 3
PACKS=$(cd "$PACKS" && pwd)
ORIGIN=$(git -C "$PACKS" config --get remote.origin.url 2>/dev/null || true)
norm() { printf '%s' "$1" | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##; s#/$##'; }
[ "$(norm "$ORIGIN")" = "$(norm "$PACKS_URL")" ] || [ -n "${SHIPPACK_ANY_ORIGIN:-}" ] \
    || fail "$PACKS is a checkout of '$ORIGIN', not of $PACKS_URL." 3
[ -d "$PACKS/pieces" ] || fail "$PACKS holds no pieces folder." 3

# The newest release tag reachable from HEAD, or empty before the first release.
previous_tag() {
    git -C "$PACKS" describe --tags --abbrev=0 --match '20[0-9][0-9].[0-9][0-9].[0-9][0-9]*' 2>/dev/null || true
}

# Today's version: the UTC date, suffixed .2, .3 … when that date is already released.
next_version() {
    local today n
    today="${SHIPPACK_TODAY:-$(date -u +%Y.%m.%d)}"
    git -C "$PACKS" rev-parse -q --verify "refs/tags/$today" >/dev/null || { echo "$today"; return; }
    n=2
    while git -C "$PACKS" rev-parse -q --verify "refs/tags/$today.$n" >/dev/null; do n=$((n + 1)); done
    echo "$today.$n"
}

# What a release would publish: every file git sees, tracked or not.
pack_files() {
    git -C "$PACKS" ls-files -z --cached --others --exclude-standard
}

# How many files differ from the last release, or from HEAD before the first.
changed_count() {
    local base
    base=$(previous_tag); [ -n "$base" ] || base="HEAD"
    { git -C "$PACKS" diff --name-only "$base" --; git -C "$PACKS" ls-files --others --exclude-standard; } | awk 'NF && !seen[$0]++' | wc -l | tr -d ' '
}

if [ "$MODE" = "plan" ]; then
    git -C "$PACKS" fetch -q origin 2>/dev/null || echo "shippack: could not fetch the packs repository; the plan is measured from the local refs." >&2
    command -v node >/dev/null 2>&1 || fail "node is required." 3

    # Names that are not the pack's to publish: every project beside the kit that syncs
    # it. Matched as whole words in everything a release would publish.
    NAMES_FILE=$(mktemp)
    for d in "$(dirname "$KIT")"/*/; do
        [ -f "$d.claude/.kit-sync.json" ] && basename "$d"
    done >"$NAMES_FILE"
    ALL=$(mktemp)
    (cd "$PACKS" && pack_files | xargs -0 grep -n -H -I '' 2>/dev/null) >"$ALL"
    # A project's name; an email that is not an example one; a cloud resource name, an
    # access key or an address. One line per hit.
    HITS=$({
        if [ -s "$NAMES_FILE" ]; then grep -i -w -F -f "$NAMES_FILE" "$ALL"; fi
        grep -E -i '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+' "$ALL" | grep -E -v -i '@example\.(com|org|net)|@[0-9]|@design-pack/|@tanstack/|@dnd-kit/|@radix-ui/|@types/|@internationalized/|@fontsource|@tailwindcss/|@vitejs/'
        grep -E 'arn:aws:|AKIA[0-9A-Z]{16}|(^|[^0-9.])(1?[0-9]{1,2}|2[0-4][0-9]|25[0-5])(\.(1?[0-9]{1,2}|2[0-4][0-9]|25[0-5])){3}([^0-9.]|$)' "$ALL" | grep -E -v '(^|[^0-9.])(0\.0\.0\.0|127\.0\.0\.1)([^0-9.]|$)'
    } | cut -c1-240 | jq -R . | jq -c -s .)
    rm -f "$NAMES_FILE" "$ALL"

    COVERAGE=$(node "$CLI" coverage "$PACKS/pieces" 2>&1 | sed -n '1,2p' | tr '\n' ' ')
    # The pieces with no recorded proof of what they are now: what --prove would prove.
    DUE=$(node "$CLI" prove-all "$PACKS/pieces" --check 2>&1 | sed -n 's/.*never proved: \(.*\) — prove them.*/\1/p')
    PIECES=$(find "$PACKS/pieces" -mindepth 2 -maxdepth 2 -name piece.json | wc -l | tr -d ' ')
    BEHIND=false
    LOCAL=$(git -C "$PACKS" rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git -C "$PACKS" rev-parse '@{u}' 2>/dev/null || echo "")
    [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ] && [ "$(git -C "$PACKS" merge-base HEAD '@{u}' 2>/dev/null)" = "$LOCAL" ] && BEHIND=true

    jq -n --arg packs "$PACKS" --arg version "$(next_version)" --arg previous "$(previous_tag)" \
        --arg branch "$(git -C "$PACKS" branch --show-current)" --argjson behind "$BEHIND" \
        --argjson changed "$(changed_count)" --argjson pieces "$PIECES" --arg coverage "$COVERAGE" --argjson hits "$HITS" --arg due "$DUE" \
        '{packs: $packs, version: $version, previous_release: $previous, branch: $branch, behind_origin: $behind,
          files_changed: $changed, pieces: $pieces, to_prove: ($due | split(", ") | map(select(. != ""))), coverage: $coverage, private_hits: $hits}'
    exit 0
fi

if [ "$MODE" = "prove" ]; then
    [ -n "$SOURCE" ] || fail "--prove needs --source <the project the pieces were cut from>." 2
    [ -d "$SOURCE" ] || fail "the source project $SOURCE does not exist." 2
    # shellcheck disable=SC2086 # $ALL is one flag or nothing
    node "$CLI" prove-all "$PACKS/pieces" --repo "$SOURCE" $ALL || fail "a piece does not prove; nothing is released. Fix what it names in the piece's folder and prove again." 5
    exit 0
fi

# ─── Release ──────────────────────────────────────────────────────────────
[ -n "$VERSION" ] || fail "--release needs --version." 2
[[ "$VERSION" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || fail "version '$VERSION' is not a release date (2026.10.23 or 2026.10.23.2)." 2

[ "$(git -C "$PACKS" branch --show-current)" = "main" ] || fail "a pack release is made on main. Nothing was written." 4
FETCH_OUT=$(git -C "$PACKS" fetch origin main --tags 2>&1) || { printf '%s\n' "$FETCH_OUT" >&2; fail "could not fetch the packs repository. Nothing was written." 4; }
[ "$(git -C "$PACKS" rev-parse HEAD)" = "$(git -C "$PACKS" rev-parse origin/main)" ] || fail "the packs checkout's main is not origin/main. Nothing was written." 4
[ "$(changed_count)" -gt 0 ] || fail "nothing has changed since the last release. Nothing was written." 4
git -C "$PACKS" rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && fail "the tag $VERSION already exists. Nothing was written." 4
CHECK_OUT=$(node "$CLI" prove-all "$PACKS/pieces" --check 2>&1) || { printf '%s\n' "$CHECK_OUT" >&2; fail "a piece has no recorded proof of what it is now. Prove the pack (--prove). Nothing was written." 4; }

git -C "$PACKS" add -A
COMMIT_OUT=$(git -C "$PACKS" commit --no-verify -q -m "📦 release: $VERSION" 2>&1) || { printf '%s\n' "$COMMIT_OUT" >&2; fail "could not commit the release." 4; }
git -C "$PACKS" push -q origin main || fail "pushing the release commit failed — origin/main moved, or main requires a PR. Nothing is tagged; the release commit is local, one ahead of origin/main." 6
SHA=$(git -C "$PACKS" rev-parse HEAD)
git -C "$PACKS" tag "$VERSION" "$SHA"
git -C "$PACKS" push -q origin "refs/tags/$VERSION" || fail "pushing the tag $VERSION failed. The release commit ${SHA:0:8} is on main; push the tag: git -C $PACKS push origin refs/tags/$VERSION" 7

echo "shippack: released $VERSION — ${SHA:0:8}" >&2
jq -n --arg version "$VERSION" --arg sha "$SHA" --arg packs "$PACKS" '{version: $version, commit: $sha, packs: $packs}'
