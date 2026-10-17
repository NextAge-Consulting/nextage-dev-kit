#!/bin/bash
# review-stack.sh — gathers the raw material for a TanStack version review.
#
# MAINTAINER-ONLY. Ships via _claude-maintainer/, installed to ~/.claude/scripts/
# on a maintainer machine only (kitmaintainer-handbook.md §0.1). A consumer machine never receives it.
#
# THE QUESTION THIS SERVES: what has changed between the versions we pin and
# what is published now, does any of it affect how WE use TanStack, and if we
# take a bump, which of our references has to change.
#
# It does NOT compare our files to upstream files. Our references are DISTILLED —
# our subset in our words — so there is nothing to diff. Staleness is judged by
# reading what changed upstream against what we wrote, which is /review-stack's
# job, not this script's.
#
# Output: JSON on stdout — pinned vs latest, the release notes in between, the
# open-issue picture for what we use, and the manifest's watch entries. Progress
# on stderr. Exit 6 when any lookup failed: the JSON is still printed, with the
# failed parts marked `unknown` / `null` and named on stderr.

#
# Usage: review-stack.sh [--kit <path>]
#   --kit names the kit checkout directly. Without it the kit is `devKitPath` in
#   ~/.claude/dev-kit-config.json. The kit repo's scheduled stack-watch workflow
#   passes --kit, since a CI runner has no ~/.claude.

set -euo pipefail

KIT_PATH=""
while [ $# -gt 0 ]; do
    case "$1" in
        --kit) KIT_PATH="${2:-}"; shift 2 ;;
        *) echo "review-stack: unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$KIT_PATH" ]; then
    CONFIG="$HOME/.claude/dev-kit-config.json"
    [ -f "$CONFIG" ] || { echo "review-stack: $CONFIG not found — see kitmaintainer-handbook.md §0.1, or pass --kit" >&2; exit 4; }
    KIT_PATH=$(jq -r .devKitPath "$CONFIG")
fi
[ -d "$KIT_PATH" ] || { echo "review-stack: kit path '$KIT_PATH' does not exist" >&2; exit 4; }
MANIFEST="$KIT_PATH/_claude-project/stack-manifest.json"
[ -f "$MANIFEST" ] || { echo "review-stack: manifest not found at $MANIFEST" >&2; exit 4; }

# Which GitHub repo publishes a package's releases: its own npm `repository`
# field, so every package in the manifest maps to where it actually lives.
# Empty when the field names no GitHub repo.
repo_for() {
    local url
    url=$(npm view "$1" repository.url 2>/dev/null) || url=""
    if [[ "$url" =~ github\.com[/:]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
        echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
    fi
}

# GET a GitHub API path. Authenticated through gh when it is logged in (5000
# requests an hour rather than 60). Non-zero on any HTTP error, rate limit
# included, so a failed lookup can never read as "nothing new".
gh_get() {
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh api "$1" 2>/dev/null
    else
        curl -sSf "https://api.github.com/$1" 2>/dev/null
    fi
}

# The releases of $pkg in $repo published after $pinned, up to and including
# $latest, newest first, each with its full notes. A repository tags a release
# one of four ways: `<package>@X.Y.Z` (a monorepo — TanStack, Biome), the
# unscoped name `<name>@X.Y.Z` (knip), `vX.Y.Z`, or a bare `X.Y.Z` (pyright).
# Any other tag — another package's, a dated release tag — is not this package.
# Prereleases are skipped. Pages are read newest first until one reaches back
# past the pin's publish date: nothing older can be newer than the pin. A busy
# monorepo publishes thousands of releases, so paging stops at MAX_PAGES and
# says so in RELEASES_NOTE. Non-zero when a page cannot be read.
MAX_PAGES=60
RELEASES_NOTE=""
releases_between() {
    local repo="$1" pkg="$2" pinned="$3" latest="$4" pin_date page raw got all="[]"
    RELEASES_NOTE=""
    pin_date=$(npm view "$pkg" "time.$pinned" 2>/dev/null) || pin_date=""
    for ((page = 1; page <= MAX_PAGES; page++)); do
        raw=$(gh_get "repos/$repo/releases?per_page=100&page=$page") || return 1
        got=$(jq -c --arg pkg "$pkg" --arg name "${pkg##*/}" --arg p "$pinned" --arg l "$latest" '
            def ver: split(".") | map(tonumber);
            ($p | ver) as $pin | ($l | ver) as $top
            | [ .[]
                | select(.prerelease | not)
                | . as $r
                | (.tag_name
                    | if startswith($pkg + "@") then .[($pkg | length) + 1:]
                      elif startswith($name + "@") then .[($name | length) + 1:]
                      elif test("^v[0-9]") then .[1:]
                      else . end) as $v
                | select($v | test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
                | select(($v | ver) > $pin and ($v | ver) <= $top)
                | {tag: $r.tag_name, date: $r.published_at[0:10], body: ($r.body // "")} ]' <<<"$raw") || return 1
        all=$(jq -c --argjson g "$got" '. + $g' <<<"$all")
        [ "$(jq 'length' <<<"$raw")" -lt 100 ] && break
        if [ -n "$pin_date" ] && [[ "$(jq -r 'map(.published_at) | min // ""' <<<"$raw")" < "$pin_date" ]]; then
            break
        fi
        if [ "$page" -eq "$MAX_PAGES" ]; then
            RELEASES_NOTE="read the $((MAX_PAGES * 100)) most recent releases of $repo without reaching back to $pinned; older ones are not listed"
        fi
    done
    jq -c 'unique_by(.tag) | sort_by(.date) | reverse' <<<"$all"
}

FAILURES=()

echo "review-stack: manifest blessed $(jq -r .blessed_at "$MANIFEST")" >&2

versions="[]"
while IFS=$'\t' read -r pkg pinned; do
    echo "review-stack: $pkg" >&2
    latest=$(npm view "$pkg" version 2>/dev/null) || latest=""
    if [ -z "$latest" ]; then
        status="unknown"
        FAILURES+=("$pkg: npm view failed")
    elif [ "$latest" = "$pinned" ]; then
        status="current"
    else
        status="behind"
    fi

    # Every release between our pin and latest, with its full notes, so the
    # reviewer reads the actual deltas rather than guessing from version numbers.
    # `null` with a `releases_note` means they could not be read — never an
    # empty list.
    notes="null"
    note=""
    repo=""
    if [ "$status" = "behind" ]; then
        repo=$(repo_for "$pkg")
        if [ -z "$repo" ]; then
            note="no GitHub repository in the package's npm metadata"
            FAILURES+=("$pkg: $note")
        elif ! notes=$(releases_between "$repo" "$pkg" "$pinned" "$latest"); then
            notes="null"
            note="GitHub releases lookup failed for $repo (rate limit or network)"
            FAILURES+=("$pkg: $note")
        elif [ -n "$RELEASES_NOTE" ]; then
            note="$RELEASES_NOTE"
        fi
    fi

    versions=$(jq --arg p "$pkg" --arg v "$pinned" --arg l "$latest" --arg s "$status" \
        --arg r "$repo" --arg note "$note" --argjson n "$notes" \
        '. + [{package:$p, pinned:$v, latest:$l, status:$s, repo:$r, releases_since:$n}
              + (if $note == "" then {} else {releases_note:$note} end)]' <<<"$versions")
done < <(jq -r '.packages | to_entries[] | "\(.key)\t\(.value.version // .value)"' "$MANIFEST")

# Open issues touching what we actually use. Not exhaustive — a prompt for the
# reviewer to look, not a verdict. A failed search is recorded, not dropped.
echo "review-stack: scanning open issues" >&2
issues="[]"
issue_failures="[]"
for q in "repo:TanStack/router+is:issue+is:open+middleware" \
         "repo:TanStack/router+is:issue+is:open+loader" \
         "repo:TanStack/table+is:issue+is:open+manualPagination" \
         "repo:TanStack/form+is:issue+is:open+validation"; do
    if raw=$(gh_get "search/issues?q=$q&sort=created&order=desc&per_page=5") \
       && got=$(jq -c '[ .items[] | {number, title, created: .created_at[0:10], url: .html_url} ]' <<<"$raw" 2>/dev/null); then
        issues=$(jq --argjson g "$got" '. + $g' <<<"$issues")
    else
        issue_failures=$(jq --arg q "$q" '. + [$q]' <<<"$issue_failures")
        FAILURES+=("issue search failed: $q")
    fi
done
issues=$(jq 'unique_by(.number)' <<<"$issues")

jq -n --arg blessed "$(jq -r .blessed_at "$MANIFEST")" \
      --arg kit "$KIT_PATH" \
      --argjson versions "$versions" \
      --argjson issues "$issues" \
      --argjson issue_failures "$issue_failures" \
      --argjson watch "$(jq '.watch // {}' "$MANIFEST")" \
      --argjson refs "$(jq '.references' "$MANIFEST")" \
      '{blessed_at:$blessed, kit_path:$kit, versions:$versions,
        open_issues:$issues, open_issue_searches_failed:$issue_failures,
        watch:$watch, references:$refs}'

# The JSON above is complete either way; a lookup that failed is marked in it.
# Exit non-zero so nobody reads a partial review as a clean one.
if [ ${#FAILURES[@]} -gt 0 ]; then
    echo "review-stack: ${#FAILURES[@]} lookup(s) failed — the review is incomplete:" >&2
    printf '  %s\n' "${FAILURES[@]}" >&2
    exit 6
fi
