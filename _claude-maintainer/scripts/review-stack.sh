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

set -euo pipefail

CONFIG="$HOME/.claude/dev-kit-config.json"
[ -f "$CONFIG" ] || { echo "review-stack: $CONFIG not found — see kitmaintainer-handbook.md §0.1" >&2; exit 4; }
KIT_PATH=$(jq -r .devKitPath "$CONFIG")
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

    # Releases newer than our pin, so the reviewer reads the actual deltas rather
    # than guessing from version numbers. A monorepo tags `<package>@X.Y.Z`, so
    # only this package's tags count; a single-package repo tags a bare vX.Y.Z.
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
        elif ! raw=$(gh_get "repos/$repo/releases?per_page=100"); then
            note="GitHub releases lookup failed for $repo (rate limit or network)"
            FAILURES+=("$pkg: $note")
        elif ! notes=$(jq -c --arg pkg "$pkg" --arg p "$pinned" '
                def ver: [scan("[0-9]+\\.[0-9]+\\.[0-9]+")][0] // "" | split(".") | map(tonumber? // 0);
                ($p | ver) as $pin
                | [ .[]
                    | select(.tag_name | startswith($pkg + "@") or test("^v?[0-9]"))
                    | select((.tag_name | ver) > $pin)
                    | {tag: .tag_name, date: .published_at[0:10],
                       body: ((.body // "")[0:600])} ]' <<<"$raw" 2>/dev/null); then
            notes="null"
            note="GitHub returned something other than a release list for $repo"
            FAILURES+=("$pkg: $note")
        else
            # A busy monorepo publishes many packages per day; when even the
            # oldest release read is newer than our pin, earlier ones are missing.
            pin_date=$(npm view "$pkg" "time.$pinned" 2>/dev/null) || pin_date=""
            oldest=$(jq -r 'map(.published_at) | min // ""' <<<"$raw")
            if [ -n "$pin_date" ] && [ -n "$oldest" ] && [[ "$oldest" > "$pin_date" ]]; then
                note="the 100 most recent releases of $repo do not reach back to $pinned; older ones are not listed"
            fi
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
