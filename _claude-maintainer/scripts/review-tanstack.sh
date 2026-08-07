#!/bin/bash
# review-tanstack.sh — data gathering for the kit's TanStack review.
#
# MAINTAINER-ONLY. Ships via _claude-maintainer/, installed to ~/.claude/scripts/
# by `/install-kit --maintainer`. A consumer machine never receives it.
#
# WHAT IT DOES NOT DO: decide anything. It emits JSON describing (a) how the
# kit's blessed versions compare to what npm currently publishes, (b) whether our
# vendored reference docs still match their upstream source at the blessed
# version, (c) upstream skills we are NOT vendoring, and (d) the state of the
# manifest's `watch` entries. The judgment — is this bump worth taking, does this
# upstream change need a house note — belongs to /review-tanstack, which reads
# this output.
#
# WHY npm pack RATHER THAN node_modules: the kit has no package.json, and a
# consumer's node_modules only holds the version that consumer installed. Packing
# lets us inspect any version — blessed or latest — from anywhere.
#
# Modes:
#   --check-updates   versions + watch only. Fast, no tarball downloads of
#                     blessed versions. This is the "what's new since we pinned"
#                     pass.
#   (default)         the above plus vendored-doc drift and unvendored-skill
#                     detection. Downloads one tarball per blessed package.
#
# Output: JSON on stdout. Progress/errors on stderr.

set -euo pipefail

MODE="full"
[ "${1:-}" = "--check-updates" ] && MODE="updates"

CONFIG="$HOME/.claude/dev-kit-config.json"
[ -f "$CONFIG" ] || { echo "review-tanstack: $CONFIG not found — run /install-kit --maintainer" >&2; exit 4; }
KIT_PATH=$(jq -r .devKitPath "$CONFIG")
[ -d "$KIT_PATH" ] || { echo "review-tanstack: kit path '$KIT_PATH' does not exist" >&2; exit 4; }

MANIFEST="$KIT_PATH/_claude-project/tanstack-manifest.json"
REFDIR="$KIT_PATH/_claude-project/skills/mfing-bible-of-tanstack/references"
[ -f "$MANIFEST" ] || { echo "review-tanstack: manifest not found at $MANIFEST" >&2; exit 4; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

npm_latest() { npm view "$1" version 2>/dev/null || echo ""; }

# Unpack <pkg>@<version> into $WORK/<safe-name>/package, echo that path.
# Echoes nothing when the package or version does not exist.
fetch_pkg() {
    local pkg="$1" ver="$2"
    local safe="${pkg//\//_}@${ver}"
    local dest="$WORK/$safe"
    if [ -d "$dest/package" ]; then echo "$dest/package"; return; fi
    mkdir -p "$dest"
    ( cd "$dest" && npm pack "${pkg}@${ver}" --silent >/dev/null 2>&1 ) || { echo ""; return; }
    local tgz
    tgz=$(find "$dest" -maxdepth 1 -name '*.tgz' | head -1)
    [ -n "$tgz" ] || { echo ""; return; }
    tar -xzf "$tgz" -C "$dest" 2>/dev/null || { echo ""; return; }
    echo "$dest/package"
}

echo "review-tanstack: reading manifest ($(jq -r .blessed_at "$MANIFEST"))" >&2

# ---- versions -------------------------------------------------------------
versions_json="[]"
while IFS=$'\t' read -r pkg blessed; do
    echo "review-tanstack: checking $pkg" >&2
    latest=$(npm_latest "$pkg")
    behind="unknown"
    if [ -n "$latest" ]; then
        if [ "$latest" = "$blessed" ]; then behind="current"; else behind="behind"; fi
    fi
    versions_json=$(jq --arg p "$pkg" --arg b "$blessed" --arg l "$latest" --arg s "$behind" \
        '. + [{package:$p, blessed:$b, latest:$l, status:$s}]' <<<"$versions_json")
done < <(jq -r '.packages | to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST")

# ---- watch entries --------------------------------------------------------
watch_json="[]"
while IFS= read -r pkg; do
    [ -n "$pkg" ] || continue
    latest=$(npm_latest "$pkg")
    exists=$([ -n "$latest" ] && echo true || echo false)
    watch_json=$(jq --arg p "$pkg" --arg l "$latest" --argjson e "$exists" \
        '. + [{package:$p, published:$e, latest:$l}]' <<<"$watch_json")
done < <(jq -r '(.watch // {}) | keys[]' "$MANIFEST")

drift_json="[]"
unvendored_json="[]"

if [ "$MODE" = "full" ]; then
    # ---- vendored-doc drift ------------------------------------------------
    # Compare our vendored copy (header stripped) against the same file inside
    # the tarball of the BLESSED version. A difference means someone hand-edited
    # a vendored file, or the package republished content under the same version.
    while IFS=$'\t' read -r file pkg skill sub; do
        [ "$sub" = "null" ] && sub="SKILL.md"
        local_file="$REFDIR/$file"
        # Which version to compare against? NOT the blessed list — several
        # references come from packages we never declare directly (router-core,
        # start-client-core arrive transitively, and pinning a transitive dep
        # would be wrong). The vendored file's own provenance header records the
        # exact package@version it came from, so it is self-describing. Fall back
        # to the blessed version when the reference does come from a pinned
        # package, and skip when we can determine neither.
        ver=$(awk -F'@' '/^     source:/ {n=split($0,a,"@"); v=a[n]; sub(/ .*/,"",v); print v; exit}' "$local_file" 2>/dev/null || echo "")
        [ -n "$ver" ] || ver=$(jq -r --arg p "$pkg" '.packages[$p] // ""' "$MANIFEST")
        [ -n "$ver" ] || continue
        root=$(fetch_pkg "$pkg" "$ver")
        if [ -z "$root" ] || [ ! -f "$root/skills/$skill/$sub" ]; then
            drift_json=$(jq --arg f "$file" --arg s "missing-upstream" \
                '. + [{file:$f, status:$s}]' <<<"$drift_json")
            continue
        fi
        [ -f "$local_file" ] || {
            drift_json=$(jq --arg f "$file" --arg s "missing-local" \
                '. + [{file:$f, status:$s}]' <<<"$drift_json"); continue; }
        # Strip our provenance header (through the first '-->' plus the blank
        # line after it) so the comparison is content-to-content.
        # awk, not sed: BSD sed (macOS) rejects GNU's `1{/a/,/b/d}` block form.
        awk '
            NR==1 && /^<!-- VENDORED/ { inhdr = 1 }
            inhdr      { if (/-->/) { inhdr = 0; skipblank = 1 } ; next }
            skipblank  { skipblank = 0; if ($0 == "") next }
                       { print }
        ' "$local_file" > "$WORK/local.md"
        # Apply the manifest's link rewrites to the UPSTREAM copy before diffing.
        # Vendoring flattens the skill tree, so those links legitimately differ;
        # without this every rewritten link reports as drift on every review, and
        # permanent noise is how a real hand-edit gets ignored.
        cp "$root/skills/$skill/$sub" "$WORK/upstream.md"
        while IFS=$'\t' read -r from to; do
            [ -n "$from" ] || continue
            python3 - "$WORK/upstream.md" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read().replace(f"]({a})", f"]({b})")
open(p, "w").write(s)
PY
        done < <(jq -r '(.link_rewrites // {}) | to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST")
        if diff -q "$WORK/local.md" "$WORK/upstream.md" >/dev/null 2>&1; then
            drift_json=$(jq --arg f "$file" --arg s "clean" '. + [{file:$f, status:$s}]' <<<"$drift_json")
        else
            n=$(diff "$WORK/local.md" "$WORK/upstream.md" | grep -c '^[<>]' || true)
            drift_json=$(jq --arg f "$file" --arg s "drift" --argjson n "${n:-0}" \
                '. + [{file:$f, status:$s, changed_lines:$n}]' <<<"$drift_json")
        fi
    done < <(jq -r '.references[] | "\(.file)\t\(.package)\t\(.skill)\t\(.sub // "null")"' "$MANIFEST")

    # ---- upstream skills we do NOT vendor ----------------------------------
    # Deliberate omissions (migrate-*) are expected — /review-tanstack knows to
    # ignore them. Anything else is a candidate we should consciously accept or
    # reject, so it never silently goes unnoticed.
    while IFS= read -r pkg; do
        blessed=$(jq -r --arg p "$pkg" '.packages[$p]' "$MANIFEST")
        root=$(fetch_pkg "$pkg" "$blessed")
        [ -n "$root" ] || continue
        [ -d "$root/skills" ] || continue
        while IFS= read -r sk; do
            rel="${sk#"$root/skills/"}"; rel="${rel%/SKILL.md}"
            have=$(jq -r --arg p "$pkg" --arg s "$rel" \
                '[.references[] | select(.package==$p and .skill==$s)] | length' "$MANIFEST")
            [ "$have" != "0" ] && continue
            unvendored_json=$(jq --arg p "$pkg" --arg s "$rel" \
                '. + [{package:$p, skill:$s}]' <<<"$unvendored_json")
        done < <(find "$root/skills" -name SKILL.md 2>/dev/null)
    done < <(jq -r '.packages | keys[]' "$MANIFEST")
fi

jq -n \
    --arg mode "$MODE" \
    --arg blessed_at "$(jq -r .blessed_at "$MANIFEST")" \
    --arg kit "$KIT_PATH" \
    --argjson versions "$versions_json" \
    --argjson watch "$watch_json" \
    --argjson drift "$drift_json" \
    --argjson unvendored "$unvendored_json" \
    '{mode:$mode, blessed_at:$blessed_at, kit_path:$kit,
      versions:$versions, watch:$watch, vendored_drift:$drift, unvendored_skills:$unvendored}'
