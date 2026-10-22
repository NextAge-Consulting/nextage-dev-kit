#!/usr/bin/env bash
# Regression suite for shipkit.sh: the plan's version, migrations, title and checks, and
# the release against a throwaway origin with a stub `gh`.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$D/shipkit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

export HOME="$tmp/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main

# `gh release create <tag> --title <t> --notes-file <f>` records its arguments.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
[ "$1 $2" = "release create" ] || exit 1
[ -n "${GH_FAIL:-}" ] && { echo "gh: failed" >&2; exit 1; }
printf '%s\n' "$@" > "$GH_LOG"
echo "https://github.com/example/kit/releases/tag/$3"
EOF
chmod +x "$tmp/bin/gh"; export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log"

ROOT="$tmp/projects"; KIT="$ROOT/kit"; ORIGIN="$tmp/origin.git"
mkdir -p "$KIT/_claude-project" "$KIT/_claude-maintainer/migrations"
printf 'rule\n' > "$KIT/_claude-project/rule.md"
git init -q --bare "$ORIGIN"
(cd "$KIT" && git init -q . && git add -A && git commit -qm base && git remote add origin "$ORIGIN" && git push -q -u origin main)

# A project beside the kit that syncs it, and one that does not.
mkdir -p "$ROOT/acmeapp/.claude" "$ROOT/notakit"
printf '{}\n' > "$ROOT/acmeapp/.claude/.kit-sync.json"

plan() { (cd "$KIT" && SHIPKIT_TODAY=2026.10.23 bash "$S" --plan 2>/dev/null); }
migration() {  # name kind|"" — kind empty writes no Estimate
    mkdir -p "$KIT/_claude-maintainer/migrations/$1"
    if [ -n "$2" ]; then
        printf '# Migration: %s\n\nIntro.\n\n## Estimate\n\nKind: %s\nYour time: none.\n\n---\n\nDo it.\n' "$1" "$2"
    else
        printf '# Migration: %s\n\nIntro.\n\n---\n\nDo it.\n' "$1"
    fi > "$KIT/_claude-maintainer/migrations/$1/PROMPT.md"
}
ship() { (cd "$KIT" && git add -A && git commit -qm "$1" && git push -q origin main); }

# ─── The first release ────────────────────────────────────────────────────
out=$(plan)
jq -e '.version == "2026.10.23" and .previous_release == "" and .title == "2026.10.23 — no migrations"' <<<"$out" >/dev/null \
    && ok "plan: the first release is today's date, with no migrations" || bad "first plan: $out"
jq -e --arg b "$(git -C "$KIT" rev-parse origin/main)" '.base == $b' <<<"$out" >/dev/null && ok "plan: the first release is measured from origin/main" || bad "first base: $(jq -r .base <<<"$out")"

migration m-mech "mechanical"
migration m-asks "asks for decisions — which blocks are the same"
out=$(plan)
jq -e '[.migrations[].name] == ["m-asks","m-mech"] or [.migrations[].name] == ["m-mech","m-asks"]' <<<"$out" >/dev/null \
    && ok "plan: migrations added in the working tree are in the release" || bad "tree migrations: $(jq -c .migrations <<<"$out")"
[ "$(jq -r .title <<<"$out")" = "2026.10.23 — 2 migrations, 1 asks for decisions" ] && ok "plan: the title counts migrations and those asking for decisions" || bad "title: $(jq -r .title <<<"$out")"
jq -e '.missing_estimate == []' <<<"$out" >/dev/null && ok "plan: no migration missing its Estimate" || bad "missing: $(jq -c .missing_estimate <<<"$out")"

migration m-bare ""
out=$(plan)
jq -e '.missing_estimate == ["m-bare"]' <<<"$out" >/dev/null && ok "plan: a migration with no Estimate is named" || bad "missing bare: $(jq -c .missing_estimate <<<"$out")"
rm -rf "$KIT/_claude-maintainer/migrations/m-bare"

printf 'Tested against AcmeApp before shipping.\n' > "$KIT/notes.md"
printf 'nothing to see in notakit\n' >> "$KIT/_claude-project/rule.md"
out=$(plan)
jq -e '[.consumer_name_hits[] | select(test("notes.md:1:.*AcmeApp"))] | length == 1' <<<"$out" >/dev/null \
    && ok "plan: a project that syncs the kit, named in an added line, is reported" || bad "name hits: $(jq -c .consumer_name_hits <<<"$out")"
jq -e '[.consumer_name_hits[] | select(test("notakit"))] | length == 0' <<<"$out" >/dev/null \
    && ok "plan: a folder that does not sync the kit is not a project name" || bad "non-consumer flagged"
rm "$KIT/notes.md"; git -C "$KIT" checkout -q -- _claude-project/rule.md

BASE=$(jq -r .base <<<"$(plan)")
ship "add migrations"
printf 'notes\n' > "$tmp/notes.md"

# ─── Release preconditions ────────────────────────────────────────────────
printf 'dirty\n' >> "$KIT/_claude-project/rule.md"
(cd "$KIT" && bash "$S" --release --version 2026.10.23 --base "$BASE" --notes-file "$tmp/notes.md" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 4 ] && ok "release: uncommitted changes refuse, writing nothing" || bad "dirty release (rc=$rc)"
git -C "$KIT" checkout -q -- _claude-project/rule.md
(cd "$KIT" && bash "$S" --release --version 23-10-2026 --base "$BASE" --notes-file "$tmp/notes.md" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 2 ] && ok "release: a version that is not a date refuses" || bad "bad version (rc=$rc)"
git -C "$KIT" checkout -q -b side
(cd "$KIT" && bash "$S" --release --version 2026.10.23 --base "$BASE" --notes-file "$tmp/notes.md" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 4 ] && ok "release: off main refuses" || bad "off main (rc=$rc)"
git -C "$KIT" checkout -q main

# ─── The release ──────────────────────────────────────────────────────────
out=$( (cd "$KIT" && bash "$S" --release --version 2026.10.23 --base "$BASE" --notes-file "$tmp/notes.md" 2>/dev/null) ); rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$KIT/VERSION")" = "2026.10.23" ] && ok "release: VERSION holds the version" || bad "release (rc=$rc): $out"
[ "$(git -C "$KIT" log -1 --format=%s)" = "🚀 release: 2026.10.23" ] && ok "release: the release commit" || bad "release subject: $(git -C "$KIT" log -1 --format=%s)"
[ "$(git -C "$ORIGIN" rev-parse main)" = "$(git -C "$KIT" rev-parse HEAD)" ] && ok "release: main is pushed" || bad "main not pushed"
git -C "$ORIGIN" rev-parse -q --verify refs/tags/2026.10.23 >/dev/null && ok "release: the tag is pushed" || bad "tag not pushed"
sed -n 5p "$GH_LOG" | grep -qx "2026.10.23 — 2 migrations, 1 asks for decisions" && ok "release: the GitHub release carries the title" || bad "gh args: $(tr '\n' '|' < "$GH_LOG")"

# ─── A second release the same day ────────────────────────────────────────
printf 'more\n' >> "$KIT/_claude-project/rule.md"; ship "more"
out=$(plan)
jq -e '.version == "2026.10.23.2" and .previous_release == "2026.10.23" and .title == "2026.10.23.2 — no migrations"' <<<"$out" >/dev/null \
    && ok "plan: a second release that day is .2, measured from the first" || bad "second plan: $out"
(cd "$KIT" && bash "$S" --release --version 2026.10.23 --base 2026.10.23 --notes-file "$tmp/notes.md" >/dev/null 2>&1); rc=$?
[ "$rc" -eq 4 ] && ok "release: an existing tag refuses" || bad "existing tag (rc=$rc)"
GH_FAIL=1 bash -c "cd '$KIT' && bash '$S' --release --version 2026.10.23.2 --base 2026.10.23 --notes-file '$tmp/notes.md'" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 7 ] && git -C "$ORIGIN" rev-parse -q --verify refs/tags/2026.10.23.2 >/dev/null && ok "release: a failed GitHub release exits 7, the tag already pushed" || bad "gh failure (rc=$rc)"

exit "$fail"
