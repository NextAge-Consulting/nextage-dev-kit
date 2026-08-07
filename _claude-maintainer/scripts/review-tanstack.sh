#!/bin/bash
# review-tanstack.sh — gathers the raw material for a TanStack version review.
#
# MAINTAINER-ONLY. Ships via _claude-maintainer/, installed to ~/.claude/scripts/
# by `/install-kit --maintainer`. A consumer machine never receives it.
#
# THE QUESTION THIS SERVES: what has changed between the versions we pin and
# what is published now, does any of it affect how WE use TanStack, and if we
# take a bump, which of our references has to change.
#
# It does NOT compare our files to upstream files. Our references are DISTILLED —
# our subset in our words — so there is nothing to diff. Staleness is judged by
# reading what changed upstream against what we wrote, which is /review-tanstack's
# job, not this script's.
#
# Output: JSON on stdout — pinned vs latest, the release notes in between, the
# open-issue picture for what we use, and the manifest's watch entries. Progress
# on stderr.

set -euo pipefail

CONFIG="$HOME/.claude/dev-kit-config.json"
[ -f "$CONFIG" ] || { echo "review-tanstack: $CONFIG not found — run /install-kit --maintainer" >&2; exit 4; }
KIT_PATH=$(jq -r .devKitPath "$CONFIG")
[ -d "$KIT_PATH" ] || { echo "review-tanstack: kit path '$KIT_PATH' does not exist" >&2; exit 4; }
MANIFEST="$KIT_PATH/_claude-project/tanstack-manifest.json"
[ -f "$MANIFEST" ] || { echo "review-tanstack: manifest not found at $MANIFEST" >&2; exit 4; }

# Which GitHub repo publishes releases for a package.
repo_for() {
    case "$1" in
        *react-table*|*table-core*) echo "TanStack/table" ;;
        *react-query*|*query-core*) echo "TanStack/query" ;;
        *react-form*|*form-core*)   echo "TanStack/form" ;;
        *)                          echo "TanStack/router" ;;   # router, start, ssr-query
    esac
}

echo "review-tanstack: manifest blessed $(jq -r .blessed_at "$MANIFEST")" >&2

versions="[]"
while IFS=$'\t' read -r pkg pinned; do
    echo "review-tanstack: $pkg" >&2
    latest=$(npm view "$pkg" version 2>/dev/null || echo "")
    status="current"; [ -n "$latest" ] && [ "$latest" != "$pinned" ] && status="behind"
    [ -z "$latest" ] && status="unknown"

    # Releases newer than our pin, so the reviewer reads the actual deltas rather
    # than guessing from version numbers. Tag shapes vary per repo, so match on
    # the package name appearing in the tag OR a bare vX.Y.Z.
    notes="[]"
    if [ "$status" = "behind" ]; then
        repo=$(repo_for "$pkg")
        short="${pkg##*/}"
        notes=$(curl -s "https://api.github.com/repos/$repo/releases?per_page=40" \
          | jq --arg p "$pinned" --arg s "$short" '
              [ .[]
                | select(.tag_name | test($s) or test("^v?[0-9]"))
                | {tag: .tag_name, date: .published_at[0:10],
                   body: ((.body // "")[0:600])} ]' 2>/dev/null || echo "[]")
    fi

    versions=$(jq --arg p "$pkg" --arg v "$pinned" --arg l "$latest" --arg s "$status" \
        --argjson n "$notes" \
        '. + [{package:$p, pinned:$v, latest:$l, status:$s, releases_since:$n}]' <<<"$versions")
done < <(jq -r '.packages | to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST")

# Open issues touching what we actually use. Not exhaustive — a prompt for the
# reviewer to look, not a verdict.
echo "review-tanstack: scanning open issues" >&2
issues="[]"
for q in "repo:TanStack/router+is:issue+is:open+middleware" \
         "repo:TanStack/router+is:issue+is:open+loader" \
         "repo:TanStack/table+is:issue+is:open+manualPagination" \
         "repo:TanStack/form+is:issue+is:open+validation"; do
    got=$(curl -s "https://api.github.com/search/issues?q=$q&sort=created&order=desc&per_page=5" \
      | jq '[ .items[]? | {number, title, created: .created_at[0:10], url: .html_url} ]' 2>/dev/null || echo "[]")
    issues=$(jq --argjson g "$got" '. + $g' <<<"$issues")
done
issues=$(jq 'unique_by(.number)' <<<"$issues")

jq -n --arg blessed "$(jq -r .blessed_at "$MANIFEST")" \
      --arg kit "$KIT_PATH" \
      --argjson versions "$versions" \
      --argjson issues "$issues" \
      --argjson watch "$(jq '.watch // {}' "$MANIFEST")" \
      --argjson refs "$(jq '.references' "$MANIFEST")" \
      '{blessed_at:$blessed, kit_path:$kit, versions:$versions,
        open_issues:$issues, watch:$watch, references:$refs}'
