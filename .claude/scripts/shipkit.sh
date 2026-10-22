#!/bin/bash
# /shipkit's mechanics.
#
#   shipkit.sh --plan
#       Read-only. Prints JSON for the release about to be made: its version, the base
#       it is measured from (the last release tag, or origin/main before the first), the
#       migrations it adds with each one's Kind, its title, every new migration with no
#       Estimate, and every added line naming a project that syncs this kit on this
#       machine — the kit is public, and those names are not.
#
#   shipkit.sh --release --version <v> --base <ref> --notes-file <path>
#       On main, after /merge: write VERSION, commit `🚀 release: <v>`, push main, tag <v>,
#       push the tag, and create the GitHub release, titled from the migrations the kit
#       added since <base>, with the notes as its body.
#
# Versions are UTC dates, `2026.10.23`, and `2026.10.23.2` for a second release that day.
#
# Exit codes:
#   2  bad arguments
#   3  not run from the kit repository
#   4  a release precondition failed: not on main, uncommitted changes, out of step
#      with origin, or the tag already exists — nothing was written
#   5  pushing the release commit failed: nothing is tagged, the commit is still local
#   6  pushing the tag failed: the release commit is on main
#   7  the GitHub release was not created: the commit and the tag are pushed

set -u

MIGRATIONS_DIR="_claude-maintainer/migrations"

fail() {
    echo "shipkit: $1" >&2
    exit "$2"
}

MODE=""; VERSION=""; BASE=""; NOTES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan) MODE="plan"; shift ;;
        --release) MODE="release"; shift ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --base) BASE="${2:-}"; shift 2 ;;
        --notes-file) NOTES="${2:-}"; shift 2 ;;
        *) fail "unknown argument: $1" 2 ;;
    esac
done
[ -n "$MODE" ] || fail "usage: shipkit.sh --plan | --release --version <v> --base <ref> --notes-file <path>" 2

KIT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not in a git repository." 3
[ -d "$KIT/_claude-project" ] && [ -d "$KIT/$MIGRATIONS_DIR" ] || fail "$KIT is not the dev-kit repository." 3
cd "$KIT" || exit 3

# The newest release tag reachable from HEAD, or empty before the first release.
previous_tag() {
    git describe --tags --abbrev=0 --match '20[0-9][0-9].[0-9][0-9].[0-9][0-9]*' 2>/dev/null || true
}

# Today's version: the UTC date, suffixed .2, .3 … when that date is already released.
next_version() {
    local today n
    today="${SHIPKIT_TODAY:-$(date -u +%Y.%m.%d)}"
    git rev-parse -q --verify "refs/tags/$today" >/dev/null || { echo "$today"; return; }
    n=2
    while git rev-parse -q --verify "refs/tags/$today.$n" >/dev/null; do n=$((n + 1)); done
    echo "$today.$n"
}

# Migration names the release adds: committed since <base>, and — with "tree" — those
# added in the working tree too, oldest first.
migrations_since() {
    local base="$1" scope="${2:-}"
    {
        git log --reverse --diff-filter=A --name-only --format= "${base}..HEAD" -- "$MIGRATIONS_DIR"
        if [ "$scope" = "tree" ]; then
            git diff --name-only --diff-filter=A HEAD -- "$MIGRATIONS_DIR"
            git ls-files --others --exclude-standard -- "$MIGRATIONS_DIR"
        fi
    } | sed -n "s#^${MIGRATIONS_DIR}/\([^/]*\)/PROMPT\.md\$#\1#p" | awk '!seen[$0]++'
}

# A migration's Kind line, without the "Kind: " prefix; empty when it has no Estimate.
kind_of() {
    local f="$MIGRATIONS_DIR/$1/PROMPT.md"
    grep -q '^## Estimate$' "$f" 2>/dev/null || return 0
    sed -n 's/^Kind: //p' "$f" | head -1
}

# "<v> — no migrations", or "<v> — 2 migrations, 1 asks for decisions".
title_for() {
    local version="$1" names="$2" n=0 asks=0 name text
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        n=$((n + 1))
        case "$(kind_of "$name")" in "asks for decisions"*) asks=$((asks + 1)) ;; esac
    done <<<"$names"
    if [ "$n" -eq 0 ]; then
        echo "$version — no migrations"
        return
    fi
    text="$version — $n migration"; [ "$n" -gt 1 ] && text="${text}s"
    if [ "$asks" -eq 1 ]; then
        text="$text, 1 asks for decisions"
    elif [ "$asks" -gt 1 ]; then
        text="$text, $asks ask for decisions"
    fi
    echo "$text"
}

if [ "$MODE" = "plan" ]; then
    git fetch -q origin main 2>/dev/null || echo "shipkit: could not fetch origin; the plan is measured from the local refs." >&2
    PREV=$(previous_tag)
    if [ -n "$PREV" ]; then
        BASE="$PREV"
    else
        BASE=$(git rev-parse origin/main 2>/dev/null) || fail "no release tag and no origin/main to measure the first release from." 3
    fi
    NAMES=$(migrations_since "$BASE" tree)
    NEXT=$(next_version)

    MIGS="[]"; MISSING="[]"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        kind=$(kind_of "$name")
        MIGS=$(jq -c --arg n "$name" --arg k "$kind" '. + [{name: $n, kind: $k}]' <<<"$MIGS")
        [ -n "$kind" ] || MISSING=$(jq -c --arg n "$name" '. + [$n]' <<<"$MISSING")
    done <<<"$NAMES"

    # Projects beside this clone that sync it. Their names, matched as whole words in
    # the lines this release adds, are reported for review: the kit is public.
    NAMES_FILE=$(mktemp); HITS="[]"
    for d in "$(dirname "$KIT")"/*/; do
        [ -f "$d.claude/.kit-sync.json" ] && basename "$d"
    done >"$NAMES_FILE"
    if [ -s "$NAMES_FILE" ]; then
        ADDED=$(mktemp)
        git diff -U0 --no-color "$BASE" -- . | awk '
            /^\+\+\+ b\// { file = substr($0, 7); next }
            /^@@/ { split($3, a, ","); line = substr(a[1], 2) + 0; next }
            /^\+/ && file != "" { print file ":" line ":" substr($0, 2); line++ }
        ' >"$ADDED"
        git ls-files --others --exclude-standard -z | xargs -0 grep -n -H -I '' 2>/dev/null >>"$ADDED"
        while IFS= read -r hit; do
            HITS=$(jq -c --arg h "$hit" '. + [$h]' <<<"$HITS")
        done < <(grep -i -w -F -f "$NAMES_FILE" "$ADDED" | cut -c1-240)
        rm -f "$ADDED"
    fi
    rm -f "$NAMES_FILE"

    jq -n --arg version "$NEXT" --arg base "$BASE" --arg previous "$PREV" \
        --arg title "$(title_for "$NEXT" "$NAMES")" \
        --argjson migrations "$MIGS" --argjson missing "$MISSING" --argjson hits "$HITS" \
        '{version: $version, base: $base, previous_release: $previous, title: $title,
          migrations: $migrations, missing_estimate: $missing, consumer_name_hits: $hits}'
    exit 0
fi

# ─── Release ──────────────────────────────────────────────────────────────
[ -n "$VERSION" ] && [ -n "$BASE" ] && [ -n "$NOTES" ] || fail "--release needs --version, --base and --notes-file." 2
[ -f "$NOTES" ] || fail "the notes file $NOTES does not exist." 2
[[ "$VERSION" =~ ^20[0-9]{2}\.[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$ ]] || fail "version '$VERSION' is not a release date (2026.10.23 or 2026.10.23.2)." 2
git rev-parse -q --verify "$BASE^{commit}" >/dev/null || fail "base '$BASE' is not a commit in this repository." 2

[ "$(git branch --show-current)" = "main" ] || fail "a release is made on main, after /merge. Nothing was written." 4
[ -z "$(git status --porcelain)" ] || fail "there are uncommitted changes; a release commits only VERSION. Nothing was written." 4
FETCH_OUT=$(git fetch origin main --tags 2>&1) || { printf '%s\n' "$FETCH_OUT" >&2; fail "could not fetch origin. Nothing was written." 4; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || fail "local main is not origin/main. Nothing was written." 4
git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null && fail "the tag $VERSION already exists. Nothing was written." 4

printf '%s\n' "$VERSION" > VERSION
git add VERSION
COMMIT_OUT=$(git commit --no-verify -q -m "🚀 release: $VERSION" 2>&1) || { printf '%s\n' "$COMMIT_OUT" >&2; fail "could not commit VERSION." 4; }
if ! git push -q origin main; then
    fail "pushing the release commit to main failed — origin/main moved, or main requires a PR. Nothing is tagged; the release commit is local, one ahead of origin/main." 5
fi
SHA=$(git rev-parse HEAD)

git tag "$VERSION" "$SHA"
git push -q origin "refs/tags/$VERSION" || fail "pushing the tag $VERSION failed. The release commit ${SHA:0:8} is on main; push the tag, then create the release." 6

TITLE=$(title_for "$VERSION" "$(migrations_since "$BASE")")
URL=$(gh release create "$VERSION" --title "$TITLE" --notes-file "$NOTES" 2>&1) \
    || { printf '%s\n' "$URL" >&2; fail "the GitHub release was not created. The commit and tag $VERSION are pushed: gh release create $VERSION --title \"$TITLE\" --notes-file $NOTES" 7; }
echo "shipkit: released $TITLE — $URL" >&2
jq -n --arg version "$VERSION" --arg title "$TITLE" --arg url "$URL" --arg sha "$SHA" \
    '{version: $version, title: $title, url: $url, commit: $sha}'
