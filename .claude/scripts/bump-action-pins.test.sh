#!/usr/bin/env bash
# Regression suite for bump-action-pins.sh: which release each pin moves to, what it
# refuses to take, and that a failed read writes nothing. `gh` is a stub serving fixed
# releases, so the suite runs offline.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$D/bump-action-pins.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# `gh api repos/<o>/<r>/releases?…` prints $GH_DIR/<o>_<r>.json; `gh api
# repos/<o>/<r>/commits/<tag> --jq .sha` prints a SHA made from the tag.
mkdir -p "$tmp/bin" "$tmp/gh"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
[ "$1" = "api" ] || exit 1
[ -n "${GH_FAIL:-}" ] && { echo "gh: HTTP 502" >&2; exit 1; }
path="${2%%\?*}"
repo=$(echo "$path" | cut -d/ -f2-3 | tr / _)
case "$path" in
    */releases) cat "$GH_DIR/$repo.json" ;;
    */commits/*) echo "sha-$repo-${path##*/}" ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" GH_DIR="$tmp/gh"

# 2026-10-31 00:00 UTC; the cooldown cutoff is 2026-10-24.
export BUMP_NOW=1793404800
rel() { printf '{"tag_name":"%s","published_at":"%s","draft":false,"prerelease":%s}' "$1" "$2" "${3:-false}"; }
cat > "$tmp/gh/actions_checkout.json" <<EOF
[$(rel v8.0.0 2026-10-01T00:00:00Z), $(rel v7.0.3 2026-10-29T00:00:00Z), $(rel v7.1.0-beta 2026-10-01T00:00:00Z true),
 $(rel v7.0.2 2026-10-10T00:00:00Z), $(rel v7.0.1 2026-07-20T00:00:00Z), $(rel v6.9.0 2026-09-01T00:00:00Z)]
EOF
cat > "$tmp/gh/actions_setup-node.json" <<EOF
[$(rel v7.1.0 2026-07-20T00:00:00Z)]
EOF

KIT="$tmp/kit"
mkdir -p "$KIT/_claude-project" "$KIT/_github-project/workflows" "$KIT/.github/workflows"
(cd "$KIT" && git init -q .)
cat > "$KIT/_github-project/workflows/ci.yml" <<'EOF'
jobs:
  a:
    steps:
      - uses: actions/checkout@old1  # v7.0.1
      - uses: actions/setup-node@node1  # v7.1.0
      - uses: ./.github/actions/local
      - uses: acme/no-comment@abcd
EOF
cat > "$KIT/.github/workflows/watch.yml" <<'EOF'
jobs:
  w:
    steps:
      - uses: actions/checkout@old0  # v6.4.0
EOF
cp "$KIT/_github-project/workflows/ci.yml" "$tmp/ci.before"
cp "$KIT/.github/workflows/watch.yml" "$tmp/watch.before"

run() { (cd "$KIT" && bash "$S" "$@"); }

# ─── A failed read writes nothing ─────────────────────────────────────────
out=$(GH_FAIL=1 run 2>&1); rc=$?
[ "$rc" -eq 5 ] && ok "a release read that fails exits 5" || bad "gh failure (rc=$rc)"
cmp -s "$tmp/ci.before" "$KIT/_github-project/workflows/ci.yml" && cmp -s "$tmp/watch.before" "$KIT/.github/workflows/watch.yml" \
    && ok "and writes nothing" || bad "gh failure wrote files"
printf '%s\n' "$out" | grep -q 'HTTP 502' && ok "and shows gh's error" || bad "gh error not shown: $out"

# ─── The bump ─────────────────────────────────────────────────────────────
out=$(run 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "the bump exits 0" || bad "bump (rc=$rc): $out"
grep -q 'actions/checkout@sha-actions_checkout-v7.0.2  # v7.0.2' "$KIT/_github-project/workflows/ci.yml" \
    && ok "moves to the newest release in its major at least seven days old" || bad "checkout v7: $(grep checkout "$KIT/_github-project/workflows/ci.yml")"
! grep -q 'v7.0.3\|v7.1.0-beta\|v8.0.0' "$KIT/_github-project/workflows/ci.yml" \
    && ok "skips a release too new, a prerelease and a new major" || bad "took a release it should not"
grep -q 'actions/checkout@sha-actions_checkout-v6.9.0  # v6.9.0' "$KIT/.github/workflows/watch.yml" \
    && ok "each major moves within itself, the kit's own workflows included" || bad "checkout v6: $(cat "$KIT/.github/workflows/watch.yml")"
grep -q 'actions/setup-node@node1  # v7.1.0' "$KIT/_github-project/workflows/ci.yml" \
    && ok "a pin already current is untouched" || bad "setup-node changed"
grep -q 'acme/no-comment@abcd$' "$KIT/_github-project/workflows/ci.yml" && grep -q 'uses: ./.github/actions/local' "$KIT/_github-project/workflows/ci.yml" \
    && ok "a pin with no version comment and a local action are left alone" || bad "touched an unversioned line"
printf '%s\n' "$out" | grep -q 'acme/no-comment: no version comment' && ok "the unversioned pin is named" || bad "unversioned not named: $out"
printf '%s\n' "$out" | grep -q 'actions/checkout: v8.0.0 is out, a new major' && ok "a newer major is named, not taken" || bad "major not named: $out"
printf '%s\n' "$out" | grep -q 'moved 2' && ok "it says how much it checked and moved" || bad "count: $out"

# ─── Run again: nothing left to move ──────────────────────────────────────
cp "$KIT/_github-project/workflows/ci.yml" "$tmp/ci.after"
out=$(run 2>&1)
cmp -s "$tmp/ci.after" "$KIT/_github-project/workflows/ci.yml" && printf '%s\n' "$out" | grep -q 'moved 0' \
    && ok "a second run moves nothing" || bad "second run: $out"

# ─── --major takes a new major for the action it names ────────────────────
out=$(run --major actions/checkout 2>&1)
grep -q 'actions/checkout@sha-actions_checkout-v8.0.0  # v8.0.0' "$KIT/_github-project/workflows/ci.yml" \
    && grep -q 'actions/checkout@sha-actions_checkout-v8.0.0  # v8.0.0' "$KIT/.github/workflows/watch.yml" \
    && ok "--major moves every pin of that action to its newest release" || bad "--major: $out"
grep -q 'actions/setup-node@node1  # v7.1.0' "$KIT/_github-project/workflows/ci.yml" \
    && ok "--major leaves every other action in its major" || bad "--major moved another action"
run --major >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "--major with no action is refused" || bad "--major empty (rc=$rc)"

(cd "$tmp" && bash "$S" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "outside the kit it refuses" || bad "outside kit (rc=$rc)"

exit $fail
