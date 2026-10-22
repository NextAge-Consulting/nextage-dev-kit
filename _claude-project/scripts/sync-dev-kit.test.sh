#!/usr/bin/env bash
# Regression suite for the /sync-dev-kit launcher, sync-dev-kit.sh.
#
# Builds a throwaway kit origin, a clone of it, and a throwaway HOME pointing at the
# clone, then drives the launcher on a syncer's machine and on a maintainer's.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$D/sync-dev-kit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

export HOME="$tmp/home"; mkdir -p "$HOME/.claude"
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main

ORIGIN="$tmp/origin"; KIT="$tmp/kit"; PROJ="$tmp/proj"; mkdir -p "$PROJ"
mkdir -p "$ORIGIN/_claude-project" "$ORIGIN/_claude-maintainer/sync"
printf 'rule\n' > "$ORIGIN/_claude-project/rule.md"
# The engine stand-in prints the arguments it was given.
printf '#!/bin/bash\necho "engine $*"\n' > "$ORIGIN/_claude-maintainer/sync/sync-dev-kit.sh"
printf '# procedure\n' > "$ORIGIN/_claude-maintainer/sync/procedure.md"
printf '2026.10.01\n' > "$ORIGIN/VERSION"
(cd "$ORIGIN" && git init -q . && git add -A && git commit -qm v1)
git clone -q "$ORIGIN" "$KIT"

run() { (cd "$PROJ" && /bin/bash "$S" "$@"); }
release_on_origin() { (cd "$ORIGIN" && printf '%s\n' "$1" > VERSION && git commit -qam "release $1"); }

# ─── The clone cannot be found ────────────────────────────────────────────
run --prepare >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 3 ] && grep -q "kit-sync-cheatsheet.md" "$tmp/err" && ok "no config: refuses, pointing at the setup" || bad "no config (rc=$rc)"
printf '{"devKitPath":"%s"}\n' "$tmp/nowhere" > "$HOME/.claude/dev-kit-config.json"
run --prepare >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "devKitPath not a kit: refuses" || bad "bad devKitPath (rc=$rc)"
printf '{"devKitPath":"%s"}\n' "$KIT" > "$HOME/.claude/dev-kit-config.json"

# ─── A syncer's machine: latest main, or nothing ──────────────────────────
out=$(run --prepare 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && jq -e --arg k "$KIT" '.role == "syncer" and .kit_path == $k and .release == "2026.10.01"' <<<"$out" >/dev/null \
    && ok "syncer: a clean clone on main prepares" || bad "syncer prepare (rc=$rc): $out"
jq -e --arg p "$KIT/_claude-maintainer/sync/procedure.md" '.procedure == $p' <<<"$out" >/dev/null && ok "syncer: names the clone's procedure" || bad "procedure path"

release_on_origin 2026.10.02
out=$(run --prepare 2>/dev/null)
[ "$(jq -r .release <<<"$out")" = "2026.10.02" ] && [ "$(git -C "$KIT" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse HEAD)" ] \
    && ok "syncer: the clone is brought to the kit's latest main" || bad "syncer fast-forward: $out"

printf 'edit\n' >> "$KIT/_claude-project/rule.md"
run --prepare >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 6 ] && grep -q "local changes" "$tmp/err" && ok "syncer: local changes in the clone refuse" || bad "dirty clone (rc=$rc)"
git -C "$KIT" checkout -q -- _claude-project/rule.md

git -C "$KIT" checkout -q -b side
run --prepare >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 6 ] && grep -q "'side', not main" "$tmp/err" && ok "syncer: a clone off main refuses" || bad "off main (rc=$rc)"
git -C "$KIT" checkout -q main

(cd "$KIT" && printf 'local\n' > local.txt && git add local.txt && git commit -qm local)
release_on_origin 2026.10.03
run --prepare >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 6 ] && grep -q "commits origin does not" "$tmp/err" && ok "syncer: a diverged main refuses" || bad "diverged (rc=$rc)"
[ "$(git -C "$KIT" log -1 --format=%s)" = "local" ] && ok "syncer: a refusal leaves the clone as it was" || bad "diverged clone changed"

# ─── A maintainer's machine: the working tree as it stands ────────────────
touch "$HOME/.claude/kitmaster"
printf 'wip\n' >> "$KIT/_claude-project/rule.md"
out=$(run --prepare 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ "$(jq -r .role <<<"$out")" = "maintainer" ] && ok "maintainer: a dirty, diverged clone still prepares" || bad "maintainer prepare (rc=$rc): $out"
[ "$(git -C "$KIT" log -1 --format=%s)" = "local" ] && ok "maintainer: nothing is pulled" || bad "maintainer clone moved"
rm "$HOME/.claude/kitmaster"

# ─── Every other mode runs the clone's engine ─────────────────────────────
[ "$(run --apply-file "_claude-project/rule.md" 2>/dev/null)" = "engine --apply-file _claude-project/rule.md" ] \
    && ok "pass-through: the engine gets the arguments unchanged" || bad "pass-through: $(run --apply-file x 2>&1)"
rm "$KIT/_claude-maintainer/sync/sync-dev-kit.sh"
run --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 3 ] && ok "pass-through: a clone with no engine refuses" || bad "missing engine (rc=$rc)"

exit "$fail"
