#!/usr/bin/env bash
# Regression suite for sync-dev-kit.sh.
#
# Builds a throwaway kit and consumer project, points a throwaway HOME's
# dev-kit-config.json at the kit, and drives the real script through every
# per-file state it reports. `gh` is a stub whose answer comes from
# FAKE_ISSUE_STATE, so the patch-register recommendations are tested offline.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$D/sync-dev-kit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

KIT="$tmp/kit"; PROJ="$tmp/proj"; export HOME="$tmp/home"
mkdir -p "$HOME/.claude" "$tmp/bin" "$PROJ"
printf '{"devKitPath":"%s"}\n' "$KIT" > "$HOME/.claude/dev-kit-config.json"
cat > "$tmp/bin/gh" <<'EOF'
#!/bin/sh
# Only `gh issue view N [--repo R] --json state --jq .state` is answered.
[ "$1" = "issue" ] && [ "$2" = "view" ] || exit 1
[ -n "${FAKE_ISSUE_STATE:-}" ] || exit 1
echo "$FAKE_ISSUE_STATE"
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export FAKE_ISSUE_STATE=OPEN

# ─── The fake kit ──────────────────────────────────────────────────────────
mkdir -p "$KIT/_claude-project/rules" "$KIT/_claude-project/templates/testing" \
         "$KIT/_claude-project/templates/design-system" "$KIT/_github-project/workflows"
printf 'rule one\n' > "$KIT/_claude-project/rules/a.md"
printf 'rule two\n' > "$KIT/_claude-project/rules/b.md"
printf '{"_comment":"kit","SHARED_MODULE_DIR":"","DESIGN_UI_PACKAGE":""}\n' > "$KIT/_claude-project/sync-substitutions.json"
printf 'readme\n' > "$KIT/_claude-project/templates/README.md"
printf 'node_modules/\n' > "$KIT/_claude-project/templates/.gitignore-additions"
printf 'nobody maps me\n' > "$KIT/_claude-project/templates/orphan.txt"
printf 'export {}\n' > "$KIT/_claude-project/templates/testing/smoke.test.ts"
printf 'const pkg = "{{DESIGN_UI_PACKAGE}}";\n' > "$KIT/_claude-project/templates/design-system/engine.mjs"
printf '{ "extends": ["./biome.base.json"] }\n' > "$KIT/_claude-project/templates/biome.json"
printf '{ "linter": { "enabled": true } }\n' > "$KIT/_claude-project/templates/biome.base.json"
printf 'export default {};\n' > "$KIT/_claude-project/templates/knip.config.ts"
mkdir -p "$KIT/_claude-project/templates/biome-plugins"
printf 'language js\n' > "$KIT/_claude-project/templates/biome-plugins/kit-check.grit"
cat > "$KIT/_claude-project/templates/ui-inventory.md" <<'EOF'
# Inventory

Kit instruction.

<!-- project:begin components -->
_[seed components]_
<!-- project:end components -->

## Prohibitions

<!-- project:begin prohibitions -->
_[seed prohibitions]_
<!-- project:end prohibitions -->
EOF
cat > "$KIT/_claude-project/templates/.gitattributes" <<'EOF'
* text=auto eol=lf
# project:begin project-attributes
# project:end project-attributes
EOF
cat > "$KIT/_github-project/workflows/ci.yml" <<'EOF'
jobs:
  project:
    steps:
      - uses: actions/checkout@v7
      # project:begin project-steps
      - run: echo seed
      # project:end project-steps
EOF
kit_commit() { (cd "$KIT" && git add -A && git commit -qm "$1"); }
(cd "$KIT" && git init -q -b main . && git config user.email t@example.com && git config user.name t)
kit_commit "kit v1"
(cd "$PROJ" && git init -q -b main .)

run()   { (cd "$PROJ" && /bin/bash "$S" "$@"); }
scan()  { run --scan 2>/dev/null; }
state() { scan | jq -r --arg d "$1" '.files[] | select(.dest_path == $d) | .state'; }
field() { scan | jq -r --arg d "$1" ".files[] | select(.dest_path == \$d) | $2"; }
lock()  { jq -r --arg d "$1" ".files[\$d] | $2" "$PROJ/.claude/.kit-sync.json"; }
sha()   { shasum -a 256 "$1" | awk '{print $1}'; }

INV=".claude/rules/project/ui-inventory.md"
CI=".github/workflows/ci.yml"

# ─── First scan: offers, unmapped templates, unconfigured destinations ─────
out=$(scan)
[ "$(jq -r '.files[] | select(.dest_path == ".claude/rules/a.md") | .state' <<<"$out")" = "new-kit" ] && ok "new kit file is new-kit" || bad "a.md first scan"
jq -e '.unmapped_templates == ["_claude-project/templates/orphan.txt"]' <<<"$out" >/dev/null \
    && ok "unmapped template listed; README and .gitignore-additions are not" || bad "unmapped: $(jq -c .unmapped_templates <<<"$out")"
jq -e '[.skipped_unconfigured[] | .key] | sort == ["DESIGN_UI_PACKAGE","SHARED_MODULE_DIR"]' <<<"$out" >/dev/null \
    && ok "empty destination keys reported, not silent" || bad "unconfigured: $(jq -c .skipped_unconfigured <<<"$out")"
[ "$(jq -r '.files[] | select(.dest_path == "biome.json") | .mode' <<<"$out")" = "template" ] && ok "biome.json is a template seed" || bad "biome.json mode"
[ "$(jq -r '.files[] | select(.dest_path == "biome.base.json") | .mode' <<<"$out")" = "owned" ] && ok "biome.base.json is owned" || bad "biome.base.json mode"
[ "$(jq -r '.files[] | select(.dest_path == "knip.config.ts") | .mode' <<<"$out")" = "owned" ] && ok "knip.config.ts maps to the root, owned" || bad "knip.config.ts mapping"
[ "$(jq -r '.files[] | select(.dest_path == "biome-plugins/kit-check.grit") | .mode' <<<"$out")" = "owned" ] && ok "kit Biome plugin maps to root biome-plugins/, owned" || bad "biome plugin mapping"
[ "$(jq -r '.files[] | select(.dest_path == ".gitattributes") | .mode' <<<"$out")" = "merge" ] && ok ".gitattributes maps to the root, merge" || bad ".gitattributes"
for d in "$INV" "$CI" ; do
    [ "$(jq -r --arg d "$d" '.files[] | select(.dest_path == $d) | .mode' <<<"$out")" = "merge" ] && ok "$d is merge" || bad "$d mode"
done

# ─── First-time states (no baseline) ──────────────────────────────────────
mkdir -p "$PROJ/.claude/rules"
printf 'rule one\n' > "$PROJ/.claude/rules/a.md"
printf 'my own rule two\n' > "$PROJ/.claude/rules/b.md"
[ "$(state .claude/rules/a.md)" = "clean-first" ] && ok "identical first sync is clean-first" || bad "clean-first: $(state .claude/rules/a.md)"
[ "$(state .claude/rules/b.md)" = "conflict-first" ] && ok "differing first sync is conflict-first" || bad "conflict-first: $(state .claude/rules/b.md)"

# ─── merge-unmarked: a project copy that predates the regions ─────────────
mkdir -p "$PROJ/.github/workflows"
printf 'jobs: {}  # hand-written, no markers\n' > "$PROJ/$CI"
before=$(sha "$PROJ/$CI")
[ "$(state "$CI")" = "merge-unmarked" ] && ok "unmarked merge file is merge-unmarked" || bad "merge-unmarked: $(state "$CI")"
run --apply-file _github-project/workflows/ci.yml >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && [ "$(sha "$PROJ/$CI")" = "$before" ] && ok "apply refuses and leaves the file alone" || bad "apply on unmarked (rc=$rc)"
rm "$PROJ/$CI"

# ─── Apply everything, finalize: all clean ────────────────────────────────
for k in $(scan | jq -r '.files[] | select(.state != "clean" and .state != "clean-first") | .kit_path'); do
    run --apply-file "$k" >/dev/null 2>&1 || bad "apply $k"
done
run --finalize >/dev/null 2>&1 || bad "finalize"
nonclean=$(scan | jq -r '[.files[] | select(.state | startswith("clean") | not) | .dest_path] | join(" ")')
[ -z "$nonclean" ] && ok "everything clean after apply + finalize" || bad "not clean: $nonclean"
[ "$(lock "$INV" .sha)" = "$(sha "$PROJ/$INV")" ] && ok "merge baseline is the SHA of what was written" || bad "merge baseline sha"
[ -n "$(lock "$INV" '.skeleton // ""')" ] && ok "merge baseline records a skeleton" || bad "no skeleton"
[ "$(lock "$INV" .mode)" = "merge" ] && ok "lockfile mode is merge" || bad "lockfile mode"

# ─── Owned edit with no register entry → unsanctioned ─────────────────────
printf 'rule one, edited here\n' > "$PROJ/.claude/rules/a.md"
[ "$(state .claude/rules/a.md)" = "unsanctioned" ] && ok "owned edit is unsanctioned" || bad "unsanctioned: $(state .claude/rules/a.md)"

# ─── Register entry → patched, reported with both issues ──────────────────
cat > "$PROJ/.claude/.kit-patches.json" <<'EOF'
{"patches":[{"path":".claude/rules/a.md","kitIssue":"example-org/kit#12","projectIssue":"#34","reason":"needs the fix now"}]}
EOF
reg_sha=$(sha "$PROJ/.claude/.kit-patches.json")
[ "$(state .claude/rules/a.md)" = "patched" ] && ok "registered edit is patched" || bad "patched: $(state .claude/rules/a.md)"
p=$(field .claude/rules/a.md .patch)
jq -e '.kitIssue == "example-org/kit#12" and .projectIssue == "#34" and .kit_issue_state == "OPEN" and .kit_changed == false and .recommendation == "keep"' <<<"$p" >/dev/null \
    && ok "patch carries both issues; open + kit unchanged → keep" || bad "patch: $p"
FAKE_ISSUE_STATE="" p=$(field .claude/rules/a.md .patch)
jq -e '.kit_issue_state == "unknown"' <<<"$p" >/dev/null && ok "unreachable gh reads as unknown, not either answer" || bad "unknown: $p"

# ─── Kit fixes it and the kit issue closes → take-kit ─────────────────────
printf 'rule one, fixed in the kit\n' > "$KIT/_claude-project/rules/a.md"; kit_commit "fix a"
p=$(FAKE_ISSUE_STATE=OPEN field .claude/rules/a.md .patch)
jq -e '.kit_changed == true and .recommendation == "merge-kit-keep-patch"' <<<"$p" >/dev/null \
    && ok "kit changed, issue open → merge kit, keep patch" || bad "open+changed: $p"
p=$(FAKE_ISSUE_STATE=CLOSED field .claude/rules/a.md .patch)
jq -e '.kit_changed == true and .recommendation == "take-kit"' <<<"$p" >/dev/null \
    && ok "kit changed, issue closed → take-kit" || bad "take-kit: $p"
run --apply-file _claude-project/rules/a.md >/dev/null 2>&1
[ "$(state .claude/rules/a.md)" = "clean" ] && ok "taking the kit version is clean" || bad "after take: $(state .claude/rules/a.md)"
[ "$(sha "$PROJ/.claude/.kit-patches.json")" = "$reg_sha" ] && ok "sync never writes the register" || bad "register touched"
stale=$(scan | jq -c '.stale_patches')
jq -e 'length == 1 and .[0].path == ".claude/rules/a.md" and .[0].current_state == "clean"' <<<"$stale" >/dev/null \
    && ok "an entry with nothing to sanction is a stale patch" || bad "stale: $stale"
removed=$(run --remove-patch .claude/rules/a.md 2>/dev/null)
jq -e '.projectIssue == "#34"' <<<"$removed" >/dev/null && ok "--remove-patch prints the removed entry" || bad "remove-patch output: $removed"
jq -e '.patches == []' "$PROJ/.claude/.kit-patches.json" >/dev/null && ok "--remove-patch drops the entry" || bad "register after remove"
run --remove-patch .claude/rules/a.md >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && ok "--remove-patch on a missing entry fails" || bad "remove missing (rc=$rc)"

# ─── Unregistered two-sided divergence stays a conflict ───────────────────
printf 'project b\n' > "$PROJ/.claude/rules/b.md"
printf 'kit b\n' > "$KIT/_claude-project/rules/b.md"; kit_commit "change b"
[ "$(state .claude/rules/b.md)" = "conflict" ] && ok "unregistered conflict is conflict" || bad "conflict: $(state .claude/rules/b.md)"
run --apply-file _claude-project/rules/b.md >/dev/null 2>&1

# ─── Merge: region edits are the project's, kit text always applies ───────
python3 - "$PROJ/$INV" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("_[seed components]_", "- `Button` — every button"))
EOF
[ "$(state "$INV")" = "clean-converged" ] && ok "region-only edit is silent (clean-converged)" || bad "region edit: $(state "$INV")"
python3 - "$KIT/_claude-project/templates/ui-inventory.md" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("Kit instruction.", "Kit instruction, improved."))
EOF
kit_commit "improve inventory text"
[ "$(state "$INV")" = "kit-only" ] && ok "kit text change outside regions is kit-only" || bad "merge kit-only: $(state "$INV")"
run --apply-file _claude-project/templates/ui-inventory.md >/dev/null 2>&1
grep -q 'Kit instruction, improved.' "$PROJ/$INV" && grep -q '`Button` — every button' "$PROJ/$INV" \
    && ok "apply takes kit text and keeps the project region" || bad "merge apply content"
[ "$(state "$INV")" = "clean" ] && ok "clean after merge apply" || bad "after merge apply: $(state "$INV")"

# A region the kit adds arrives with its seed.
printf '\n<!-- project:begin hooks -->\n_[seed hooks]_\n<!-- project:end hooks -->\n' >> "$KIT/_claude-project/templates/ui-inventory.md"; kit_commit "add hooks region"
[ "$(state "$INV")" = "kit-only" ] && ok "a new kit region is kit-only" || bad "new region: $(state "$INV")"
run --apply-file _claude-project/templates/ui-inventory.md >/dev/null 2>&1
grep -q '_\[seed hooks\]_' "$PROJ/$INV" && grep -q '`Button`' "$PROJ/$INV" && ok "new region seeded, old region kept" || bad "seeded region"

# An edit outside the regions is an owned-file edit.
printf 'stray line outside any region\n' >> "$PROJ/$INV"
[ "$(state "$INV")" = "unsanctioned" ] && ok "outside-region edit is unsanctioned" || bad "outside edit: $(state "$INV")"
printf '{"patches":[{"path":"%s","kitIssue":"example-org/kit#40","projectIssue":"#41","reason":"r"}]}\n' "$INV" > "$PROJ/.claude/.kit-patches.json"
[ "$(state "$INV")" = "patched" ] && ok "registered outside-region edit is patched" || bad "merge patched: $(state "$INV")"
run --apply-file _claude-project/templates/ui-inventory.md >/dev/null 2>&1
! grep -q 'stray line' "$PROJ/$INV" && grep -q '`Button`' "$PROJ/$INV" && ok "apply reverts the outside edit, keeps regions" || bad "revert outside edit"
printf '{"patches":[]}\n' > "$PROJ/.claude/.kit-patches.json"

# ─── merge-invalid: malformed markers and orphan regions ──────────────────
cp "$PROJ/$INV" "$tmp/inv.bak"
python3 - "$PROJ/$INV" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("<!-- project:end prohibitions -->\n", "", 1))
EOF
[ "$(state "$INV")" = "merge-invalid" ] && ok "unclosed region is merge-invalid" || bad "unclosed: $(state "$INV")"
field "$INV" .detail | grep -q 'never closed\|opens inside' && ok "merge-invalid names the problem" || bad "detail: $(field "$INV" .detail)"
run --apply-file _claude-project/templates/ui-inventory.md >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && ok "apply refuses a malformed project file" || bad "apply malformed (rc=$rc)"
cp "$tmp/inv.bak" "$PROJ/$INV"
printf '<!-- project:begin mine -->\nonly here\n<!-- project:end mine -->\n' >> "$PROJ/$INV"
[ "$(state "$INV")" = "merge-invalid" ] && ok "a region the kit lacks is merge-invalid" || bad "orphan: $(state "$INV")"
field "$INV" .detail | grep -q 'would be lost' && ok "orphan region detail says content would be lost" || bad "orphan detail"
cp "$tmp/inv.bak" "$PROJ/$INV"

# ─── YAML regions ─────────────────────────────────────────────────────────
python3 - "$PROJ/$CI" <<'EOF'
import sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(s.replace("      - run: echo seed\n", "      - run: node scripts/project-check.mjs\n"))
EOF
printf '# kit comment\n' | cat - "$KIT/_github-project/workflows/ci.yml" > "$tmp/ci" && mv "$tmp/ci" "$KIT/_github-project/workflows/ci.yml"; kit_commit "ci comment"
[ "$(state "$CI")" = "kit-only" ] && ok "yaml merge file: kit change is kit-only" || bad "ci: $(state "$CI")"
run --apply-file _github-project/workflows/ci.yml >/dev/null 2>&1
head -1 "$PROJ/$CI" | grep -q 'kit comment' && grep -q 'project-check.mjs' "$PROJ/$CI" && ! grep -q 'echo seed' "$PROJ/$CI" \
    && ok "yaml region carried across a kit update" || bad "ci content"

# ─── Ack on a merge file ──────────────────────────────────────────────────
printf '# kit v3\n' >> "$KIT/_github-project/workflows/ci.yml"; kit_commit "ci v3"
run --ack-file _github-project/workflows/ci.yml >/dev/null 2>&1
[ -n "$(lock "$CI" '.skeleton // ""')" ] && ok "ack records the kit skeleton" || bad "ack skeleton"

# ─── Destination from a substitution ──────────────────────────────────────
jq '.DESIGN_UI_PACKAGE = "packages/ui"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
d=$(scan | jq -r '.files[] | select(.kit_path == "_claude-project/templates/design-system/engine.mjs") | .dest_path + " " + .mode')
[ "$d" = "packages/ui/design-system/engine.mjs owned" ] && ok "design-system maps into DESIGN_UI_PACKAGE, owned" || bad "design-system dest: $d"
run --apply-file _claude-project/templates/design-system/engine.mjs >/dev/null 2>&1
grep -q 'const pkg = "packages/ui";' "$PROJ/packages/ui/design-system/engine.mjs" && ok "design-system file written with substitutions" || bad "design-system content"
scan | jq -e '[.skipped_unconfigured[] | .key] == ["SHARED_MODULE_DIR"]' >/dev/null && ok "configured key leaves the unconfigured list" || bad "unconfigured after set"
jq '.DESIGN_FEED_BARREL = "" | ._intentionally_empty = ((._intentionally_empty // []) + ["DESIGN_FEED_BARREL"])' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
out=$(scan)
jq -e '[.files[] | select(.kit_path == "_claude-project/templates/design-system/engine.mjs")] == []' <<<"$out" >/dev/null && ok "no Claude Design (feed barrel deliberately empty): engine files skipped" || bad "engine offered with no feed barrel"
jq -e '[.skipped_unconfigured[] | .key] | sort == ["DESIGN_FEED_BARREL","SHARED_MODULE_DIR"]' <<<"$out" >/dev/null && ok "the skip is reported under the feed barrel key" || bad "feed barrel skip: $(jq -c .skipped_unconfigured <<<"$out")"
jq 'del(.DESIGN_FEED_BARREL) | ._intentionally_empty -= ["DESIGN_FEED_BARREL"]' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"

# ─── A template is a seed: offered once, never again ─────────────────────
run --apply-file _claude-project/templates/biome.json >/dev/null 2>&1
printf '{ "extends": ["./biome.base.json"], "plugins": ["./mine.grit"] }\n' > "$PROJ/biome.json"
printf '{ "extends": ["./biome.base.json"], "root": true }\n' > "$KIT/_claude-project/templates/biome.json"; kit_commit "biome seed v2"
st=$(scan | jq -r '.files[] | select(.dest_path == "biome.json") | .state')
[ "$st" = "template-kept" ] && ok "an adapted seed the kit changed is kept, not offered" || bad "adapted seed: $st"
printf '{ "extends": ["./biome.base.json"], "root": true }\n' > "$PROJ/biome.json"; run --apply-file _claude-project/templates/biome.json >/dev/null 2>&1
printf '{ "extends": ["./biome.base.json"], "root": false }\n' > "$KIT/_claude-project/templates/biome.json"; kit_commit "biome seed v3"
st=$(scan | jq -r '.files[] | select(.dest_path == "biome.json") | .state')
[ "$st" = "template-kept" ] && ok "an untouched seed the kit changed is kept, not offered" || bad "untouched seed: $st"
rm "$PROJ/biome.json"
st=$(scan | jq -r '.files[] | select(.dest_path == "biome.json") | .state')
[ "$st" = "template-kept" ] && ok "a deleted seed stays deleted" || bad "deleted seed: $st"
printf 'export {}\n' > "$KIT/_claude-project/templates/testing/project.ts"; kit_commit "project.ts seed"
jq '.SHARED_MODULE_DIR = "apps/shared"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
run --decline-file _claude-project/templates/testing/project.ts >/dev/null 2>&1
printf 'export const v = 2\n' > "$KIT/_claude-project/templates/testing/project.ts"; kit_commit "project.ts seed v2"
st=$(scan | jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/project.ts") | .state')
[ "$st" = "declined" ] && ok "a declined seed stays declined when the kit changes it" || bad "declined seed: $st"
[ "$(scan | jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/smoke.test.ts") | .mode')" = "owned" ] && ok "the test scaffolding is kit-owned" || bad "smoke.test.ts mode"
printf 'import "pg"\n' > "$KIT/_claude-project/templates/testing/integration-helpers.ts"; kit_commit "postgres harness"
jq '.DB_ENGINE = "SQLServer"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
out=$(scan)
jq -e '[.files[] | select(.kit_path == "_claude-project/templates/testing/integration-helpers.ts")] == []' <<<"$out" >/dev/null \
    && jq -e '[.skipped_unconfigured[] | select(.kit_path == "_claude-project/templates/testing/integration-helpers.ts") | .key] == ["DB_ENGINE"]' <<<"$out" >/dev/null \
    && ok "another engine skips the Postgres harness, reported under DB_ENGINE" || bad "non-Postgres harness: $(jq -c .skipped_unconfigured <<<"$out")"
jq -e '[.files[] | select(.kit_path == "_claude-project/templates/testing/smoke.test.ts")] | length == 1' <<<"$out" >/dev/null \
    && ok "another engine still gets the unit scaffolding" || bad "non-Postgres unit scaffolding"
L="$PROJ/.claude/.kit-sync.json"
jq '.files["apps/shared/test/integration-helpers.ts"] = {sha: "x", mode: "template", declined: true} | .files["gone.md"] = {sha: "y", mode: "owned"}' "$L" > "$tmp/l" && mv "$tmp/l" "$L"
printf 'left behind\n' > "$PROJ/gone.md"
out=$(scan)
jq -e '[.files[] | select(.dest_path == "apps/shared/test/integration-helpers.ts")] == []' <<<"$out" >/dev/null \
    && ok "a lockfile entry nothing maps to, for a file the project lacks, is not removed-kit" || bad "phantom removal: $(jq -c '[.files[] | select(.state == "removed-kit")]' <<<"$out")"
[ "$(jq -r '.files[] | select(.dest_path == "gone.md") | .state' <<<"$out")" = "removed-kit" ] \
    && ok "a kit-removed file the project still has is removed-kit" || bad "real removal not reported"
run --finalize >/dev/null 2>&1
jq -e '.files | has("apps/shared/test/integration-helpers.ts") | not' "$L" >/dev/null && jq -e '.files | has("gone.md")' "$L" >/dev/null \
    && ok "finalize drops the entry with no file and keeps the one with a file" || bad "finalize pruning: $(jq -c '.files | keys' "$L")"
rm "$PROJ/gone.md"; jq 'del(.files["gone.md"])' "$L" > "$tmp/l" && mv "$tmp/l" "$L"
jq '.DB_ENGINE = "PostgreSQL"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
[ "$(scan | jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/integration-helpers.ts") | .dest_path')" = "apps/shared/test/integration-helpers.ts" ] \
    && ok "Postgres gets the integration harness" || bad "Postgres harness dest"
jq 'del(.DB_ENGINE)' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
jq '.SHARED_MODULE_DIR = ""' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"

# ─── A broken register fails the scan loudly ──────────────────────────────
printf '{not json' > "$PROJ/.claude/.kit-patches.json"
run --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "invalid register fails the scan" || bad "invalid register (rc=$rc)"

exit "$fail"
