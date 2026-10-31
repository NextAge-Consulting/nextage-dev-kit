#!/bin/bash
# /shipkit's action-pin step. Moves every GitHub action the kit's workflows pin to the
# newest release in its major version that is at least seven days old, written as the
# exact commit SHA with the release's tag beside it:
#
#   uses: actions/checkout@<commit sha>  # v7.0.2
#
#   bump-action-pins.sh [--major <action>]...
#
# Reads `_github-project/workflows/` (what syncs to projects) and `.github/workflows/`
# (the kit's own). A pin is read from the `# vX.Y.Z` comment beside its SHA; one without
# that comment is left alone and named. The seven days match the cooldown projects'
# Dependabot keeps, so a hijacked release has had time to be caught. A newer major can
# change an action's inputs, so it is printed rather than taken, and taken only for an
# action named with `--major` — once its release notes show nothing the kit's workflows
# use has changed.
#
# Prints one line per pin moved, per newer major, and per pin it could not read. Writes
# nothing unless every action's releases were read.
#
# Exit codes:
#   2  bad arguments
#   3  not run from the kit repository
#   5  an action's releases or a tag's commit could not be read — nothing was written

set -u

COOLDOWN_DAYS=7

fail() {
    echo "bump-action-pins: $1" >&2
    exit "$2"
}

MAJORS=" "
while [ $# -gt 0 ]; do
    case "$1" in
        --major)
            [ -n "${2:-}" ] || fail "--major needs an action, e.g. --major actions/checkout" 2
            MAJORS="$MAJORS$2 "; shift 2 ;;
        *) fail "usage: bump-action-pins.sh [--major <action>]..." 2 ;;
    esac
done

KIT=$(git rev-parse --show-toplevel 2>/dev/null) || fail "not in a git repository." 3
[ -d "$KIT/_claude-project" ] && [ -d "$KIT/_github-project" ] || fail "$KIT is not the dev-kit repository." 3
cd "$KIT" || exit 3

FILES=$(find _github-project/workflows .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
[ -n "$FILES" ] || { echo "bump-action-pins: no workflow files found — nothing to check."; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# One `name<TAB>version` line per pinned `uses:`, version empty when it has no
# `# vX.Y.Z` comment. Local actions and docker images carry no `@` and are skipped.
pins_in() {
    awk '
        $0 ~ /^[ \t]*(-[ \t]+)?uses:[ \t]*[^@ \t.][^@ \t]*@/ {
            line = $0
            sub(/^.*uses:[ \t]*/, "", line)
            name = substr(line, 1, index(line, "@") - 1)
            v = ""
            if (match(line, /#[ \t]*v?[0-9]+(\.[0-9]+)*/)) {
                v = substr(line, RSTART, RLENGTH)
                sub(/^#[ \t]*v?/, "", v)
            }
            print name "\t" v
        }
    ' "$@"
}

# Is version a newer than version b? Missing parts count as 0.
ver_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        nx = split(a, x, "."); ny = split(b, y, ".")
        for (i = 1; i <= 3; i++) {
            xa = (i <= nx) ? x[i] + 0 : 0; yb = (i <= ny) ? y[i] + 0 : 0
            if (xa != yb) exit !(xa > yb)
        }
        exit 1
    }'
}

# shellcheck disable=SC2086 # FILES is newline-separated paths with no spaces
pins_in $FILES | sort -u > "$tmp/pins"

now="${BUMP_NOW:-$(date -u +%s)}"
cutoff=$((now - COOLDOWN_DAYS * 86400))
: > "$tmp/map"
: > "$tmp/report"

while IFS=$'\t' read -r name ver; do
    [ -n "$name" ] || continue
    if [ -z "$ver" ]; then
        echo "  $name: no version comment beside its SHA — left as it is" >> "$tmp/report"
        continue
    fi
    repo=$(printf '%s' "$name" | cut -d/ -f1-2)
    major="${ver%%.*}"
    if [ ! -f "$tmp/rel-${repo//\//_}" ]; then
        if ! gh api "repos/$repo/releases?per_page=100" > "$tmp/rel-${repo//\//_}" 2> "$tmp/err"; then
            cat "$tmp/err" >&2
            fail "could not read the releases of $repo — nothing was written." 5
        fi
    fi
    # The released tags old enough to take, newest version first.
    tags=$(jq -r --argjson cutoff "$cutoff" '
        [ .[] | select((.draft | not) and (.prerelease | not))
          | select((.published_at // "" | if . == "" then 0 else fromdateiso8601 end) <= $cutoff)
          | .tag_name | select(test("^v?[0-9]+(\\.[0-9]+)*$")) ]
        | sort_by(ltrimstr("v") | split(".") | map(tonumber)) | reverse | .[]
    ' "$tmp/rel-${repo//\//_}") || fail "could not read the releases of $repo — nothing was written." 5
    in_major=$(printf '%s\n' "$tags" | awk -v m="$major" '{ t = $0; sub(/^v/, "", t); split(t, p, "."); if (p[1] + 0 == m + 0) { print; exit } }')
    newest=$(printf '%s\n' "$tags" | head -1)
    newest_major="${newest#v}"; newest_major="${newest_major%%.*}"
    if [ -n "$newest" ] && [ "$newest_major" -gt "$major" ] 2>/dev/null; then
        case "$MAJORS" in
            *" $name "*) in_major="$newest" ;;
            *) echo "  $name: $newest is out, a new major — not taken; read its release notes, then --major $name" >> "$tmp/report" ;;
        esac
    fi
    [ -n "$in_major" ] || continue
    ver_gt "${in_major#v}" "$ver" || continue
    if ! sha=$(gh api "repos/$repo/commits/$in_major" --jq .sha 2> "$tmp/err") || [ -z "$sha" ]; then
        cat "$tmp/err" >&2
        fail "could not read the commit $repo $in_major points at — nothing was written." 5
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$major" "$in_major" "$sha" >> "$tmp/map"
    echo "  $name: v$ver → $in_major" >> "$tmp/report"
done < "$tmp/pins"

# Rewrite each pin the map moves: same action, same major, an older version.
if [ -s "$tmp/map" ]; then
    # shellcheck disable=SC2086 # as above
    for f in $FILES; do
        awk -v mapfile="$tmp/map" '
            function newer(a, b,    x, y, nx, ny, i, xa, yb) {
                nx = split(a, x, "."); ny = split(b, y, ".")
                for (i = 1; i <= 3; i++) {
                    xa = (i <= nx) ? x[i] + 0 : 0
                    yb = (i <= ny) ? y[i] + 0 : 0
                    if (xa != yb) return xa > yb
                }
                return 0
            }
            BEGIN {
                while ((getline line < mapfile) > 0) {
                    split(line, f, "\t")
                    tag[f[1] SUBSEP f[2]] = f[3]; sha[f[1] SUBSEP f[2]] = f[4]
                }
                close(mapfile)
            }
            {
                if ($0 !~ /^[ \t]*(-[ \t]+)?uses:[ \t]*[^@ \t]+@/ || !match($0, /#[ \t]*v?[0-9]+(\.[0-9]+)*/)) { print; next }
                v = substr($0, RSTART, RLENGTH); sub(/^#[ \t]*v?/, "", v)
                at = index($0, "@")
                head = substr($0, 1, at)
                name = head; sub(/^.*uses:[ \t]*/, "", name); sub(/@$/, "", name)
                m = v; sub(/\..*/, "", m)
                k = name SUBSEP m
                t = tag[k]; sub(/^v/, "", t)
                if ((k in tag) && newer(t, v)) print head sha[k] "  # " tag[k]
                else print
            }
        ' "$f" > "$tmp/out" || fail "could not rewrite $f — it is left as it was." 5
        cat "$tmp/out" > "$f"
    done
fi

moved=$(wc -l < "$tmp/map" | tr -d ' ')
total=$(wc -l < "$tmp/pins" | tr -d ' ')
echo "bump-action-pins: checked $total pinned action version(s) across $(printf '%s\n' "$FILES" | wc -l | tr -d ' ') workflow file(s); moved $moved."
[ -s "$tmp/report" ] && cat "$tmp/report"
exit 0
