#!/bin/bash
# stack-watch.sh — the kit repo's scheduled watch on its own pins.
#
# The kit has no package.json, so Dependabot never sees the versions in
# _claude-project/stack-manifest.json. This script is how the kit hears about them.
# It decides nothing: it files an issue, and the issue is the cue for the
# maintainer to run /review-stack (kitmaintainer-handbook.md §9.13).
#
# Usage: stack-watch.sh <pins|advisories> [--dry-run]
#
#   pins        Pinned vs latest for every manifest package, with the release
#               count in between (review-stack.sh's gather). One open issue
#               labelled `stack-review`, rewritten on each run.
#   advisories  Every pinned version checked against the GitHub Advisory
#               Database. One open issue labelled `stack-advisory`, rewritten on
#               each run while any pin is affected.
#   --dry-run   Print the issue title and body; file nothing.
#
# Run by .github/workflows/stack-watch.yml. GH_TOKEN must be set (the workflow's
# token). STACK_WATCH_PROJECT_TOKEN, when set, also puts a new issue on the
# kit's project board — the workflow's own token cannot write an organization's
# project.
#
# Exit 0 when the run completed — whether or not it filed anything. Exit 1 when a
# lookup failed or the issue could not be filed; a pins run whose gather was
# partial still files, listing what is missing, and then exits 1.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MANIFEST="$ROOT/_claude-project/stack-manifest.json"
MODE="${1:-}"
DRY=0
[ "${2:-}" = "--dry-run" ] && DRY=1
case "$MODE" in
    pins|advisories) ;;
    *) echo "usage: stack-watch.sh <pins|advisories> [--dry-run]" >&2; exit 2 ;;
esac
[ -f "$MANIFEST" ] || { echo "stack-watch: no manifest at $MANIFEST" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BODY="$TMP/body.md"
STATUS=0

# File the issue, or rewrite the one already open under this label. Prints the URL.
file_or_update() {
    local label="$1" title="$2" color="$3" description="$4" number url
    if [ "$DRY" -eq 1 ]; then
        printf '=== %s\n[%s]\n\n' "$title" "$label"
        cat "$BODY"
        return 0
    fi
    gh label create "$label" --color "$color" --description "$description" --force >/dev/null
    number=$(gh issue list --label "$label" --state open --limit 1 --json number --jq '.[0].number // empty')
    if [ -n "$number" ]; then
        gh issue edit "$number" --title "$title" --body-file "$BODY" >/dev/null
        gh issue comment "$number" --body "Refreshed by the scheduled stack watch on $(date -u +%F)." >/dev/null
        echo "stack-watch: rewrote open issue #$number." >&2
        return 0
    fi
    url=$(gh issue create --title "$title" --label "$label" --body-file "$BODY")
    echo "stack-watch: filed $url" >&2
    add_to_board "$url"
}

# Put a new issue on the kit's board, the one .claude/gitflow-project.conf names.
add_to_board() {
    local url="$1" project node
    if [ -z "${STACK_WATCH_PROJECT_TOKEN:-}" ]; then
        echo "stack-watch: $url is not on the project board — STACK_WATCH_PROJECT_TOKEN is not set, so only the board's own auto-add can place it." >&2
        return 0
    fi
    project=$(sed -n 's/^GITFLOW_PROJECT_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$ROOT/.claude/gitflow-project.conf")
    [ -n "$project" ] || { echo "stack-watch: no GITFLOW_PROJECT_ID in .claude/gitflow-project.conf; $url is not on the board." >&2; STATUS=1; return 0; }
    node=$(gh issue view "$url" --json id --jq .id)
    # shellcheck disable=SC2016  # $p and $c are GraphQL variables, not shell expansions
    if GH_TOKEN="$STACK_WATCH_PROJECT_TOKEN" gh api graphql \
        -f query='mutation($p:ID!,$c:ID!){addProjectV2ItemById(input:{projectId:$p,contentId:$c}){item{id}}}' \
        -f p="$project" -f c="$node" >/dev/null; then
        echo "stack-watch: put $url on the project board." >&2
    else
        echo "stack-watch: $url was filed but could not be put on the project board." >&2
        STATUS=1
    fi
}

if [ "$MODE" = "pins" ]; then
    GATHER="$TMP/gather.json"
    rc=0
    bash "$ROOT/_claude-maintainer/scripts/review-stack.sh" --kit "$ROOT" >"$GATHER" 2>"$TMP/gather.err" || rc=$?
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 6 ]; then
        cat "$TMP/gather.err" >&2
        echo "stack-watch: review-stack.sh failed (exit $rc)." >&2
        exit 1
    fi
    total=$(jq '.versions | length' "$GATHER")
    behind=$(jq '[.versions[] | select(.status == "behind")] | length' "$GATHER")
    echo "stack-watch: inspected $total pinned package(s); $behind behind." >&2
    [ "$total" -gt 0 ] || { echo "stack-watch: the manifest lists no packages — nothing was inspected." >&2; exit 1; }

    {
        echo "The scheduled stack watch found pinned versions behind the latest release. Run \`/review-stack\` to decide which to take — this issue makes no recommendation."
        echo
        echo "Manifest blessed $(jq -r .blessed_at "$GATHER"); $total packages inspected, $behind behind."
        echo
        echo "| Package | Pinned | Latest | Releases since the pin |"
        echo "|---|---|---|---|"
        jq -r '.versions[] | select(.status == "behind")
            | "| `\(.package)` | \(.pinned) | \(.latest) | "
              + (if .releases_since == null then "could not be read"
                 else "\(.releases_since | length)" + (if .repo != "" then " ([releases](https://github.com/\(.repo)/releases))" else "" end) end)
              + (if .releases_note then " — \(.releases_note)" else "" end) + " |"' "$GATHER"
        if [ "$rc" -eq 6 ]; then
            echo
            echo "**The gather was incomplete** — these lookups failed, so the table above may be missing deltas:"
            echo
            sed -n 's/^  /- /p' "$TMP/gather.err"
        fi
    } >"$BODY"

    if [ "$behind" -eq 0 ]; then
        echo "stack-watch: every pin is current — nothing to file." >&2
    else
        file_or_update stack-review "Stack review: $behind pinned version(s) behind ($(date -u +%Y-%m))" \
            "1d76db" "Pinned versions behind latest — run /review-stack"
    fi
    [ "$rc" -eq 6 ] && STATUS=1
    exit "$STATUS"
fi

# advisories
FOUND="$TMP/found.json"
echo "[]" >"$FOUND"
count=0
while IFS=$'\t' read -r pkg version; do
    count=$((count + 1))
    affects=$(jq -rn --arg v "$pkg@$version" '$v | @uri')
    if ! raw=$(gh api "/advisories?ecosystem=npm&affects=$affects&per_page=100" 2>"$TMP/err"); then
        cat "$TMP/err" >&2
        echo "stack-watch: the advisory lookup for $pkg@$version failed." >&2
        exit 1
    fi
    hits=$(jq -c --arg pkg "$pkg" '[.[] | {ghsa: .ghsa_id, severity, summary, url: .html_url,
          range: ([.vulnerabilities[] | select(.package.name == $pkg) | .vulnerable_version_range] | join(", ")),
          patched: ([.vulnerabilities[] | select(.package.name == $pkg) | .first_patched_version // empty] | join(", "))}]' <<<"$raw")

    # A maintainer can publish an advisory on their own repository before — or
    # without — it reaching the global database, which is how better-auth
    # publishes. Read those too and judge the range against the pin here.
    url=$(npm view "$pkg" repository.url 2>/dev/null) || url=""
    if [[ "$url" =~ github\.com[/:]([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
        if ! raw=$(gh api "/repos/$repo/security-advisories?state=published&per_page=100" 2>"$TMP/err"); then
            cat "$TMP/err" >&2
            echo "stack-watch: the repository advisory lookup for $pkg ($repo) failed." >&2
            exit 1
        fi
        # A range is comparators joined by commas or spaces, alternatives by ||.
        # A prerelease sorts below its release, and the pin is always a release.
        # A bare version in patched_versions means "this and later". The pin is
        # affected when it satisfies the vulnerable range and not the patched one:
        # some advisories leave the vulnerable range open-ended and carry the fix
        # only in patched_versions.
        more=$(jq -c --arg pkg "$pkg" --arg v "$version" '
            def ver: capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(?<pre>-.+)?$")
                | [(.a | tonumber), (.b | tonumber), (.c | tonumber), (if .pre then 0 else 1 end)];
            def holds($op; $b): ($v | ver) as $a | ($b | ver) as $b
                | if $op == ">=" then $a >= $b elif $op == ">" then $a > $b
                  elif $op == "<=" then $a <= $b elif $op == "<" then $a < $b
                  else $a == $b end;
            def satisfies($r; $bare):
                ($r | split("||"))
                | any([scan("(>=|<=|>|<|=)?\\s*v?([0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?)")]
                      | length > 0 and all(holds(if .[0] == null then $bare else .[0] end; .[1])));
            [ .[] | . as $adv
              | .vulnerabilities[]? | select(.package.ecosystem == "npm" and .package.name == $pkg)
              | select(.vulnerable_version_range != null and satisfies(.vulnerable_version_range; "="))
              | select(((.patched_versions // "") == "") or (satisfies(.patched_versions; ">=") | not))
              | {ghsa: $adv.ghsa_id, severity: $adv.severity, summary: $adv.summary, url: $adv.html_url,
                 range: .vulnerable_version_range, patched: (.patched_versions // "")} ]' <<<"$raw")
        hits=$(jq -c --argjson m "$more" '. + $m | unique_by(.ghsa)' <<<"$hits")
    fi
    jq --arg p "$pkg" --arg v "$version" --argjson h "$hits" '. + [$h[] | . + {package: $p, pinned: $v}]' "$FOUND" >"$TMP/next" && mv "$TMP/next" "$FOUND"
done < <(jq -r '.packages | to_entries[] | "\(.key)\t\(.value.version // .value)"' "$MANIFEST")
affected=$(jq 'length' "$FOUND")
echo "stack-watch: checked $count pinned version(s) against the GitHub Advisory Database; $affected advisory hit(s)." >&2
[ "$count" -gt 0 ] || { echo "stack-watch: the manifest lists no packages — nothing was checked." >&2; exit 1; }

if [ "$affected" -eq 0 ]; then
    echo "stack-watch: no pinned version is affected — nothing to file." >&2
    exit 0
fi
{
    echo "A pinned version in \`_claude-project/stack-manifest.json\` is affected by a published advisory. Consumers cannot take the fix until the kit moves the pin. Run \`/review-stack\`."
    echo
    echo "| Package | Pinned | Advisory | Severity | Affected | Patched in |"
    echo "|---|---|---|---|---|---|"
    jq -r '.[] | "| `\(.package)` | \(.pinned) | [\(.ghsa)](\(.url)) \(.summary | gsub("\\|"; "/")) | \(.severity) | \(.range) | \(if .patched == "" then "no fix yet" else .patched end) |"' "$FOUND"
} >"$BODY"
file_or_update stack-advisory "Security advisory on $(jq -r '[.[].package] | unique | join(", ")' "$FOUND") at the pinned version" \
    "d73a4a" "A pinned version is affected by a published advisory"
exit "$STATUS"
