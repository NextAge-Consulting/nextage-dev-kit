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

# ─── Action pins: the kit's is the floor, a newer one the project's ──────
PT=".github/workflows/pr-title.yml"
pin() {  # file action sha version
    python3 - "$1" "$2" "$3" "$4" <<'EOF'
import re, sys; p, a, s, v = sys.argv[1:]; t = open(p).read()
open(p, "w").write(re.sub(r"(uses: " + re.escape(a) + r")@\S+(\s+# \S+)?", r"\g<1>@" + s + "  # " + v, t))
EOF
}
cat > "$KIT/_github-project/workflows/pr-title.yml" <<'EOF'
jobs:
  title:
    steps:
      - uses: actions/checkout@aaaa  # v7.0.1
      - uses: actions/setup-node@bbbb  # v7.1.0
      - run: echo kit
EOF
kit_commit "pr-title"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1
[ "$(lock "$PT" '.skeletonPins // false')" = "true" ] && ok "pins: a workflow records a skeleton without its action refs" || bad "pins: skeletonPins"

pin "$PROJ/$PT" actions/checkout cccc v7.0.2
[ "$(state "$PT")" = "clean-converged" ] && ok "pins: a newer project pin is not a project edit" || bad "pins: project ahead: $(state "$PT")"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1
grep -q 'actions/checkout@cccc  # v7.0.2' "$PROJ/$PT" && ok "pins: applying keeps the newer project pin" || bad "pins: newer pin reverted"

printf '      - run: echo kit two\n' >> "$KIT/_github-project/workflows/pr-title.yml"; kit_commit "pr-title step"
[ "$(state "$PT")" = "kit-only" ] && ok "pins: a kit change beside a newer project pin is kit-only" || bad "pins: kit change: $(state "$PT")"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1
grep -q 'echo kit two' "$PROJ/$PT" && grep -q 'actions/checkout@cccc  # v7.0.2' "$PROJ/$PT" \
    && ok "pins: the kit change lands and the newer pin stays" || bad "pins: kit change content"

pin "$KIT/_github-project/workflows/pr-title.yml" actions/setup-node dddd v7.2.0; kit_commit "setup-node up"
[ "$(state "$PT")" = "kit-only" ] && ok "pins: a project behind the kit's pin is kit-only" || bad "pins: project behind: $(state "$PT")"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1
grep -q 'actions/setup-node@dddd  # v7.2.0' "$PROJ/$PT" && grep -q 'actions/checkout@cccc  # v7.0.2' "$PROJ/$PT" \
    && ok "pins: applying raises the project to the kit's pin" || bad "pins: floor not applied"
[ "$(state "$PT")" = "clean" ] && ok "pins: clean after apply" || bad "pins: after apply: $(state "$PT")"

pin "$PROJ/$PT" actions/setup-node eeee v7.0.0
[ "$(state "$PT")" = "kit-only" ] && ok "pins: a pin lowered below the kit's is raised again" || bad "pins: lowered: $(state "$PT")"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1
printf '      - run: echo stray\n' >> "$PROJ/$PT"
[ "$(state "$PT")" = "unsanctioned" ] && ok "pins: an edit beyond the pins is still a project edit" || bad "pins: stray edit: $(state "$PT")"
run --apply-file _github-project/workflows/pr-title.yml >/dev/null 2>&1

# A merge workflow carries pins as well as regions.
cat > "$KIT/_github-project/workflows/ci.yml" <<'EOF'
jobs:
  project:
    steps:
      - uses: actions/checkout@aaaa  # v7.0.1
      # project:begin project-steps
      - run: echo seed
      # project:end project-steps
EOF
kit_commit "ci pinned"
run --apply-file _github-project/workflows/ci.yml >/dev/null 2>&1
pin "$PROJ/$CI" actions/checkout ffff v7.1.0
[ "$(state "$CI")" = "clean-converged" ] && ok "pins: a merge workflow's newer pin is not a project edit" || bad "pins: merge ahead: $(state "$CI")"

# A skeleton recorded with the refs in reads as no skeleton, so a project whose
# Dependabot raised a pin under it is matched afresh rather than taken for an edit.
jq --arg d "$CI" '.files[$d] |= del(.skeletonPins)' "$PROJ/.claude/.kit-sync.json" > "$tmp/l" && mv "$tmp/l" "$PROJ/.claude/.kit-sync.json"
[ "$(state "$CI")" = "clean-first" ] && ok "pins: an old skeleton is not compared, so a newer pin is no edit" || bad "pins: legacy skeleton: $(state "$CI")"
pin "$KIT/_github-project/workflows/ci.yml" actions/checkout gggg v7.2.0; kit_commit "ci checkout up"
[ "$(state "$CI")" = "kit-only" ] && ok "pins: under an old skeleton, a kit pin above the project's is kit-only" || bad "pins: legacy floor: $(state "$CI")"
run --apply-file _github-project/workflows/ci.yml >/dev/null 2>&1
grep -q 'actions/checkout@gggg  # v7.2.0' "$PROJ/$CI" && [ "$(lock "$CI" '.skeletonPins // false')" = "true" ] \
    && ok "pins: applying raises the pin and records the new skeleton" || bad "pins: legacy apply"

# An entry recorded before pins were carried: its skeleton is rebuilt from the kit
# file at lastSyncedCommit, so a raised pin and a kit change in one sync is kit-only.
cp "$KIT/_github-project/workflows/pr-title.yml" "$PROJ/$PT"
run --finalize >/dev/null 2>&1
python3 - "$PROJ/.claude/.kit-sync.json" "$PROJ/$CI" "$CI" "$PT" "$PROJ/$PT" <<'EOF'
import hashlib, json, re, sys
lock, ci, ci_key, pt_key, pt = sys.argv[1:]
body, keep = [], True
for line in open(ci).read().splitlines(True):
    if re.match(r"\s*# project:end ", line): keep = True
    if keep: body.append(line)
    if re.match(r"\s*# project:begin ", line): keep = False
d = json.load(open(lock))
d["files"][ci_key] = {"sha": d["files"][ci_key]["sha"], "mode": "merge",
                      "skeleton": hashlib.sha256("".join(body).encode()).hexdigest()}
d["files"][pt_key] = {"sha": hashlib.sha256(open(pt, "rb").read()).hexdigest(), "mode": "owned"}
json.dump(d, open(lock, "w"))
EOF
pin "$PROJ/$CI" actions/checkout hhhh v7.3.0
pin "$PROJ/$PT" actions/checkout iiii v7.3.0
printf '# ci v5\n' >> "$KIT/_github-project/workflows/ci.yml"
printf '      - run: echo kit three\n' >> "$KIT/_github-project/workflows/pr-title.yml"; kit_commit "workflows v5"
[ "$(state "$CI")" = "kit-only" ] && ok "pins: an old merge skeleton is rebuilt — raised pin + kit change is kit-only" || bad "pins: rebuilt merge: $(state "$CI")"
[ "$(state "$PT")" = "kit-only" ] && ok "pins: an old owned entry is rebuilt — raised pin + kit change is kit-only" || bad "pins: rebuilt owned: $(state "$PT")"
printf 'stray: true\n' >> "$PROJ/$PT"
[ "$(state "$PT")" = "unsanctioned" ] && ok "pins: under a rebuilt skeleton a real edit is still an edit" || bad "pins: rebuilt edit: $(state "$PT")"
python3 - "$PROJ/$PT" <<'EOF'
import sys; p = sys.argv[1]; open(p, "w").write(open(p).read().replace("stray: true\n", ""))
EOF
run --apply-file _github-project/workflows/ci.yml >/dev/null 2>&1
grep -q 'actions/checkout@hhhh  # v7.3.0' "$PROJ/$CI" && grep -q 'ci v5' "$PROJ/$CI" \
    && ok "pins: the rebuilt case applies the kit text and keeps the raised pin" || bad "pins: rebuilt apply"

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

# ─── The test buildspec: only for a project whose TEST_RUNNER is aws ──────
mkdir -p "$KIT/_claude-project/templates/codebuild"
printf 'version: 0.2\n' > "$KIT/_claude-project/templates/codebuild/buildspec-test.yml"; kit_commit "test buildspec"
out=$(scan)
jq -e '[.skipped_unconfigured[] | select(.kit_path == "_claude-project/templates/codebuild/buildspec-test.yml") | .key] == ["TEST_RUNNER"]' <<<"$out" >/dev/null \
    && jq -e '[.files[] | select(.kit_path == "_claude-project/templates/codebuild/buildspec-test.yml")] == []' <<<"$out" >/dev/null \
    && ok "test buildspec: skipped under the default runner, reported under TEST_RUNNER" || bad "buildspec skip: $(jq -c .skipped_unconfigured <<<"$out")"
jq '.TEST_RUNNER = "aws"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
d=$(scan | jq -r '.files[] | select(.kit_path == "_claude-project/templates/codebuild/buildspec-test.yml") | .dest_path + " " + .mode')
[ "$d" = "infra/codebuild/buildspec-test.yml owned" ] && ok "test buildspec: TEST_RUNNER aws maps it to infra/codebuild/, owned" || bad "buildspec dest: $d"
jq 'del(.TEST_RUNNER)' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
rm -r "$KIT/_claude-project/templates/codebuild"; kit_commit "drop test buildspec fixture"

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
printf 'import "pg"\n' > "$KIT/_claude-project/templates/testing/integration-helpers.ts"; printf 'import "./integration-helpers"\n' > "$KIT/_claude-project/templates/testing/harness.integration.test.ts"; kit_commit "postgres harness"
jq '.DB_ENGINE = "SQLServer"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
out=$(scan)
jq -e '[.files[] | select(.kit_path == "_claude-project/templates/testing/integration-helpers.ts")] == []' <<<"$out" >/dev/null \
    && jq -e '[.skipped_unconfigured[] | select(.kit_path == "_claude-project/templates/testing/integration-helpers.ts") | .key] == ["DB_ENGINE"]' <<<"$out" >/dev/null \
    && ok "another engine skips the Postgres harness, reported under DB_ENGINE" || bad "non-Postgres harness: $(jq -c .skipped_unconfigured <<<"$out")"
jq -e '[.files[] | select(.kit_path == "_claude-project/templates/testing/harness.integration.test.ts")] == []' <<<"$out" >/dev/null \
    && jq -e '[.skipped_unconfigured[] | select(.kit_path == "_claude-project/templates/testing/harness.integration.test.ts") | .key] == ["DB_ENGINE"]' <<<"$out" >/dev/null \
    && ok "another engine skips the harness's own test, reported under DB_ENGINE" || bad "non-Postgres harness test: $(jq -c .skipped_unconfigured <<<"$out")"
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
mkdir -p "$KIT/_claude-project/templates/testing/sqlserver"
printf 'import "mssql"\n' > "$KIT/_claude-project/templates/testing/sqlserver/integration-helpers.ts"
printf 'export {}\n' > "$KIT/_claude-project/templates/testing/sqlserver/integration-target.ts"; kit_commit "sql server harness"
out=$(scan)
jq -e '[.files[] | select(.kit_path | startswith("_claude-project/templates/testing/sqlserver/"))] == []' <<<"$out" >/dev/null \
    && jq -e '[.skipped_unconfigured[] | select(.kit_path == "_claude-project/templates/testing/sqlserver/integration-target.ts") | .key] == ["DB_ENGINE"]' <<<"$out" >/dev/null \
    && ok "Postgres skips the SQL Server harness, reported under DB_ENGINE" || bad "Postgres took the SQL Server harness: $(jq -c .skipped_unconfigured <<<"$out")"
jq '.DB_ENGINE = "SQLServer"' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
out=$(scan)
[ "$(jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/sqlserver/integration-helpers.ts") | .dest_path' <<<"$out")" = "apps/shared/test/integration-helpers.ts" ] \
    && [ "$(jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/sqlserver/integration-target.ts") | .dest_path' <<<"$out")" = "apps/shared/test/integration-target.ts" ] \
    && ok "SQL Server gets its harness at the scaffolding's test/ names" || bad "SQL Server harness dest: $(jq -c '[.files[] | select(.kit_path | contains("sqlserver"))]' <<<"$out")"
jq -e '[.files[] | select(.dest_path == "apps/shared/test/integration-helpers.ts")] | length == 1' <<<"$out" >/dev/null \
    && [ "$(jq -r '.files[] | select(.kit_path == "_claude-project/templates/testing/sqlserver/integration-helpers.ts") | .mode' <<<"$out")" = "owned" ] \
    && ok "one engine's harness supplies each test/ name, kit-owned" || bad "harness dest collision: $(jq -c '[.files[] | select(.dest_path == "apps/shared/test/integration-helpers.ts")]' <<<"$out")"
jq 'del(.DB_ENGINE)' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"
jq '.SHARED_MODULE_DIR = ""' "$PROJ/.claude/sync-substitutions.json" > "$tmp/s" && mv "$tmp/s" "$PROJ/.claude/sync-substitutions.json"

# ─── REPO_KIND: an org repo skips the application tooling ───────────────
SUBS="$PROJ/.claude/sync-substitutions.json"
setkind() { jq --arg v "$1" '.REPO_KIND = $v' "$SUBS" > "$tmp/s" && mv "$tmp/s" "$SUBS"; }
setkind app
run --apply-file _claude-project/templates/knip.config.ts 2>/dev/null
[ -f "$PROJ/knip.config.ts" ] && ok "app: an application file applies" || bad "app apply knip.config.ts"
setkind org
out=$(scan)
jq -e '.repo_kind == "org" and .skipped_by_repo_kind > 0' <<<"$out" >/dev/null \
    && ok "org: skipped files are counted under skipped_by_repo_kind" || bad "org count: $(jq -c '{repo_kind, skipped_by_repo_kind}' <<<"$out")"
jq -e '[.files[] | select(.dest_path == "biome.json" or .dest_path == ".claude/rules/project/ui-inventory.md") | select(.state != "removed-kit")] == []' <<<"$out" >/dev/null \
    && ok "org: application tooling is never offered, only removed where present" || bad "org offered app files: $(jq -c '[.files[] | select(.dest_path == "biome.json" or .dest_path == ".claude/rules/project/ui-inventory.md") | {dest_path, state}]' <<<"$out")"
jq -e '[.files[] | select(.dest_path == ".claude/rules/a.md")] | length == 1' <<<"$out" >/dev/null \
    && ok "org: the core still syncs" || bad "org lost core"
jq -e '[.skipped_unconfigured[] | select(.key == "REPO_KIND")] == []' <<<"$out" >/dev/null \
    && ok "org: the skipped files are not listed one by one" || bad "org listed skips"
[ "$(jq -r '.files[] | select(.dest_path == "knip.config.ts") | .state' <<<"$out")" = "removed-kit" ] \
    && ok "org: an application file the repo already has is offered for removal" || bad "org removed-kit: $(jq -c '.files[] | select(.dest_path == "knip.config.ts")' <<<"$out")"
run --apply-file _claude-project/templates/knip.config.ts >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 4 ] && grep -q 'REPO_KIND is org' "$tmp/err" && ok "org: applying an application file is refused, naming why" || bad "org apply refused (rc=$rc): $(cat "$tmp/err")"
run --apply-file knip.config.ts 2>/dev/null
[ ! -f "$PROJ/knip.config.ts" ] && ok "org: the removal deletes it by its destination" || bad "org removal"
setkind combo
out=$(scan)
jq -e '.repo_kind == "combo" and .skipped_by_repo_kind == 0' <<<"$out" >/dev/null \
    && ok "combo: nothing is skipped — a combo repo gets the app tooling and the org tooling" || bad "combo skip: $(jq -c '{repo_kind, skipped_by_repo_kind}' <<<"$out")"
setkind bogus
run --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok "an unknown REPO_KIND stops the scan" || bad "bogus REPO_KIND (rc=$rc)"
jq 'del(.REPO_KIND)' "$SUBS" > "$tmp/s" && mv "$tmp/s" "$SUBS"

# ─── .gitignore additions: a covered section leaves no comments behind ────
ADD="$KIT/_claude-project/templates/.gitignore-additions"
cp "$ADD" "$tmp/additions.orig"
cat > "$ADD" <<'EOF'
# Covered header
covered/
# covered trailing note

# Missing header
missing/
# missing inner note
missing-two/
EOF
printf 'covered/\n' > "$PROJ/.gitignore"
run --apply-gitignore 2>/dev/null
printf 'covered/\n# Missing header\nmissing/\n# missing inner note\nmissing-two/\n' > "$tmp/gi.want"
diff -u "$tmp/gi.want" "$PROJ/.gitignore" >/dev/null \
    && ok "gitignore: only the added section's comments are written" || bad "gitignore: $(diff -u "$tmp/gi.want" "$PROJ/.gitignore")"
cp "$tmp/additions.orig" "$ADD"

# ─── Migrations: the ones the kit added since the project's last sync ─────
pending() { scan | jq -c '[.migrations_pending[].name]'; }
L="$PROJ/.claude/.kit-sync.json"
FRESH="$tmp/fresh"; mkdir -p "$FRESH"
add_migration() { mkdir -p "$KIT/_claude-maintainer/migrations/$1"; printf '# %s\n\n---\n\nDo %s.\n' "$1" "$1" > "$KIT/_claude-maintainer/migrations/$1/PROMPT.md"; kit_commit "migration $1"; }
run --finalize >/dev/null 2>&1
[ "$(pending)" = "[]" ] && ok "migrations: none since the last sync, none listed" || bad "migrations at start: $(pending)"
add_migration m-one; add_migration m-two
[ "$(pending)" = '["m-one","m-two"]' ] && ok "migrations: the two added since the last sync, oldest first" || bad "pending: $(pending)"
[ "$(scan | jq -r '.migrations_pending[0].prompt')" = "$KIT/_claude-maintainer/migrations/m-one/PROMPT.md" ] && ok "migrations: each names its prompt" || bad "prompt path"
(cd "$FRESH" && /bin/bash "$S" --scan 2>/dev/null) | jq -e '.migrations_pending == []' >/dev/null && ok "migrations: a first sync runs none" || bad "first sync lists migrations"
run --migration-done m-one >/dev/null 2>&1
[ "$(pending)" = '["m-two"]' ] && ok "migrations: one recorded as run is no longer listed" || bad "after done: $(pending)"
run --finalize >/dev/null 2>&1
jq -e '.pendingMigrations == ["m-two"] and (has("migrationsDone") | not)' "$L" >/dev/null && ok "migrations: finalize carries the one not run, and clears what ran" || bad "finalize carry: $(jq -c '{pendingMigrations, migrationsDone}' "$L")"
add_migration m-three
[ "$(pending)" = '["m-two","m-three"]' ] && ok "migrations: the carried one stays, ahead of one added since" || bad "carried + new: $(pending)"
run --migration-done m-two >/dev/null 2>&1; run --migration-done m-three >/dev/null 2>&1; run --finalize >/dev/null 2>&1
[ "$(pending)" = "[]" ] && ! jq -e 'has("pendingMigrations")' "$L" >/dev/null && ok "migrations: all run, nothing carried" || bad "all run: $(pending)"
mkdir -p "$KIT/_claude-maintainer/migrations/m-draft"; printf '# m-draft\n' > "$KIT/_claude-maintainer/migrations/m-draft/PROMPT.md"
out=$(scan)
jq -e '.migrations_uncommitted == ["m-draft"] and .migrations_pending == []' <<<"$out" >/dev/null \
    && ok "migrations: off a maintainer machine an uncommitted one is named, and not listed to run" || bad "uncommitted: $(jq -c '{migrations_uncommitted, migrations_pending}' <<<"$out")"
rm -rf "$KIT/_claude-maintainer/migrations/m-draft"
scan | jq -e '.migrations_uncommitted == []' >/dev/null && ok "migrations: none uncommitted, none named" || bad "uncommitted after removal"
run --migration-done no-such >/dev/null 2>&1; rc=$?
[ "$rc" -eq 4 ] && ok "migrations: an unknown name is refused" || bad "unknown migration (rc=$rc)"
cp "$L" "$tmp/lock.orig"; jq '.lastSyncedCommit = "0000000000000000000000000000000000000000"' "$tmp/lock.orig" > "$L"
run --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "migrations: a last sync the kit's history does not hold fails the scan" || bad "unknown lastSyncedCommit (rc=$rc)"
cp "$tmp/lock.orig" "$L"

# ─── Migrations on a maintainer machine: uncommitted ones run ahead ───────
MARK="$HOME/.claude/kitmaster"
draft() { mkdir -p "$KIT/_claude-maintainer/migrations/$1"; printf '# %s\n\n---\n\nDo %s.\n' "$1" "$1" > "$KIT/_claude-maintainer/migrations/$1/PROMPT.md"; }
ahead() { jq -c '.migrationsRunAhead // "absent"' "$L"; }
touch "$MARK"
add_migration m-four
draft m-z-draft; draft m-a-draft; touch -t 202001010000 "$KIT/_claude-maintainer/migrations/m-z-draft/PROMPT.md"
out=$(scan)
jq -e '[.migrations_pending[].name] == ["m-four","m-a-draft","m-z-draft"]' <<<"$out" >/dev/null \
    && ok "maintainer: uncommitted migrations are pending after the committed ones, by name" || bad "maintainer pending: $(jq -c '[.migrations_pending[].name]' <<<"$out")"
jq -e '.migrations_uncommitted == ["m-a-draft","m-z-draft"]' <<<"$out" >/dev/null \
    && ok "maintainer: they are still named as uncommitted" || bad "maintainer uncommitted: $(jq -c .migrations_uncommitted <<<"$out")"
[ "$(jq -r '.migrations_pending[] | select(.name == "m-a-draft") | .prompt' <<<"$out")" = "$KIT/_claude-maintainer/migrations/m-a-draft/PROMPT.md" ] \
    && ok "maintainer: an uncommitted migration's prompt is the working-tree file" || bad "draft prompt path"
rm "$MARK"
[ "$(pending)" = '["m-four"]' ] && ok "consumer: the same kit state lists only the committed one" || bad "consumer pending: $(pending)"
touch "$MARK"
(cd "$FRESH" && /bin/bash "$S" --scan 2>/dev/null) | jq -e '.migrations_pending == []' >/dev/null \
    && ok "maintainer: a first sync runs none, uncommitted ones included" || bad "first sync lists drafts"
run --migration-done m-four >/dev/null 2>&1; run --migration-done m-a-draft >/dev/null 2>&1; run --finalize >/dev/null 2>&1
[ "$(ahead)" = '["m-a-draft"]' ] && ok "maintainer: finalize records the uncommitted one run" || bad "run-ahead record: $(ahead)"
jq -e '(has("pendingMigrations") | not) and (has("migrationsDone") | not)' "$L" >/dev/null \
    && ok "maintainer: an uncommitted one not run is not carried" || bad "carried: $(jq -c '{pendingMigrations, migrationsDone}' "$L")"
[ "$(pending)" = '["m-z-draft"]' ] && ok "maintainer: the next sync of the same kit state does not offer it again" || bad "re-offered: $(pending)"
run --migration-done m-z-draft >/dev/null 2>&1; run --finalize >/dev/null 2>&1
[ "$(ahead)" = '["m-a-draft","m-z-draft"]' ] && ok "maintainer: the record keeps earlier entries" || bad "record grows: $(ahead)"
rm -rf "$KIT/_claude-maintainer/migrations/m-z-draft"
run --finalize >/dev/null 2>&1
[ "$(ahead)" = '["m-a-draft"]' ] && ok "maintainer: a recorded draft deleted before commit is pruned" || bad "deleted draft kept: $(ahead)"
kit_commit "ship m-a-draft"
[ "$(pending)" = "[]" ] && ok "maintainer: once the kit commits it, the project is not offered it" || bad "committed draft offered: $(pending)"
rm "$MARK"
[ "$(pending)" = "[]" ] && ok "consumer: the record keeps a committed run-ahead migration from running" || bad "consumer re-runs: $(pending)"
jq '.migrationsRunAhead += ["m-unshipped"]' "$L" > "$tmp/l" && mv "$tmp/l" "$L"
run --finalize >/dev/null 2>&1
[ "$(ahead)" = '["m-unshipped"]' ] && ok "consumer: finalize drops the committed record, keeps one its clone has not received" || bad "consumer prune: $(ahead)"
touch "$MARK"
run --finalize >/dev/null 2>&1
[ "$(ahead)" = '"absent"' ] && ok "maintainer: a record the kit holds nowhere is pruned, and the key goes with it" || bad "record left: $(ahead)"
FRESH3="$tmp/fresh3"; mkdir -p "$FRESH3"; draft m-b-draft
(cd "$FRESH3" && /bin/bash "$S" --finalize >/dev/null 2>&1)
jq -e '.migrationsRunAhead == ["m-b-draft"]' "$FRESH3/.claude/.kit-sync.json" >/dev/null \
    && ok "maintainer: a first sync records the uncommitted ones — the project starts on the working tree" || bad "first-sync record: $(jq -c .migrationsRunAhead "$FRESH3/.claude/.kit-sync.json")"
(cd "$FRESH3" && /bin/bash "$S" --scan 2>/dev/null) | jq -e '.migrations_pending == []' >/dev/null \
    && ok "maintainer: so its next sync does not offer them" || bad "first-sync project offered drafts"
rm -rf "$KIT/_claude-maintainer/migrations/m-b-draft" "$MARK"

# ─── The scan writes nothing; --apply-substitutions writes what it reported ─
FRESH2="$tmp/fresh2"; mkdir -p "$FRESH2"; (cd "$FRESH2" && git init -q -b main .)
out=$( (cd "$FRESH2" && /bin/bash "$S" --scan 2>/dev/null) )
[ ! -e "$FRESH2/.claude/sync-substitutions.json" ] && ok "scan: a first sync's substitutions file is not bootstrapped" || bad "scan bootstrapped the substitutions file"
jq -e '.substitutions_bootstrap == true' <<<"$out" >/dev/null && ok "scan: reports that the file would be bootstrapped" || bad "bootstrap flag: $(jq -c .substitutions_bootstrap <<<"$out")"
jq -e '[.files[] | select(.dest_path == ".claude/rules/a.md") | .state] == ["new-kit"]' <<<"$out" >/dev/null \
    && ok "scan: a first sync's files are read against the kit template's values" || bad "first-sync files: $(jq -c '[.files[] | {dest_path, state}]' <<<"$out")"
jq -e '.substitutions_undecided | index("SHARED_MODULE_DIR") != null' <<<"$out" >/dev/null \
    && ok "scan: names the substitution keys the walkthrough will ask about" || bad "undecided: $(jq -c .substitutions_undecided <<<"$out")"
(cd "$FRESH2" && /bin/bash "$S" --apply-substitutions >/dev/null 2>&1)
[ -f "$FRESH2/.claude/sync-substitutions.json" ] && ok "apply-substitutions: bootstraps the file" || bad "apply-substitutions did not bootstrap"
printf '{"SHARED_MODULE_DIR":""}\n' > "$FRESH2/.claude/sync-substitutions.json"
before=$(sha "$FRESH2/.claude/sync-substitutions.json")
out=$( (cd "$FRESH2" && /bin/bash "$S" --scan 2>/dev/null) )
[ "$(sha "$FRESH2/.claude/sync-substitutions.json")" = "$before" ] && ok "scan: new kit keys are not merged into the file" || bad "scan rewrote the substitutions file"
jq -e '.substitutions_new_keys == ["DESIGN_UI_PACKAGE"] and .substitutions_bootstrap == false' <<<"$out" >/dev/null \
    && ok "scan: reports the new kit keys a merge would add" || bad "new keys: $(jq -c '{substitutions_new_keys, substitutions_bootstrap}' <<<"$out")"
(cd "$FRESH2" && /bin/bash "$S" --apply-substitutions >/dev/null 2>&1)
jq -e 'has("DESIGN_UI_PACKAGE")' "$FRESH2/.claude/sync-substitutions.json" >/dev/null && ok "apply-substitutions: merges the new kit keys" || bad "apply-substitutions did not merge"

# ─── The project's own hooks, composed into settings.json ─────────────────
SCP="$tmp/sidecar"; mkdir -p "$SCP"; (cd "$SCP" && git init -q -b main .)
srun() { (cd "$SCP" && /bin/bash "$S" "$@"); }
sstate() { srun --scan 2>/dev/null | jq -r '.files[] | select(.dest_path == ".claude/settings.json") | .state'; }
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"kit.sh"}]}]}}\n' > "$KIT/_claude-project/settings.json"
srun --apply-file _claude-project/settings.json >/dev/null 2>&1
[ "$(sstate)" = "clean" ] && ok "sidecar: none, settings.json is the kit's" || bad "no sidecar: $(sstate)"
printf '{"hooks":{"PreToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"proj.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"prompt.sh"}]}]}}\n' > "$SCP/.claude/settings.project.json"
[ "$(sstate)" = "kit-only" ] && ok "sidecar: a project hook makes settings.json kit-only" || bad "sidecar added: $(sstate)"
srun --apply-file _claude-project/settings.json >/dev/null 2>&1
jq -e '[.hooks.PreToolUse[].hooks[0].command] == ["kit.sh","proj.sh"] and .hooks.UserPromptSubmit[0].hooks[0].command == "prompt.sh"' "$SCP/.claude/settings.json" >/dev/null \
    && ok "sidecar: applied after the kit's entries, and a new event added" || bad "composed: $(jq -c .hooks "$SCP/.claude/settings.json")"
[ "$(sstate)" = "clean" ] && ok "sidecar: clean once applied" || bad "after compose: $(sstate)"
rm "$SCP/.claude/settings.project.json"
[ "$(sstate)" = "kit-only" ] && ok "sidecar: removing it makes settings.json kit-only" || bad "sidecar removed: $(sstate)"
srun --apply-file _claude-project/settings.json >/dev/null 2>&1
jq -e '[.hooks.PreToolUse[].hooks[0].command] == ["kit.sh"] and (.hooks | has("UserPromptSubmit") | not)' "$SCP/.claude/settings.json" >/dev/null \
    && ok "sidecar: its hooks leave with it" || bad "after removal: $(jq -c .hooks "$SCP/.claude/settings.json")"
printf '{"hooks":{},"permissions":{"allow":["Bash(*)"]}}\n' > "$SCP/.claude/settings.project.json"
srun --scan >/dev/null 2>"$tmp/err"; rc=$?
[ "$rc" -eq 5 ] && grep -q "settings.project.json is not valid" "$tmp/err" && ok "sidecar: anything but hooks stops the scan" || bad "extra key (rc=$rc)"
printf '{not json' > "$SCP/.claude/settings.project.json"
srun --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "sidecar: invalid JSON stops the scan" || bad "invalid sidecar (rc=$rc)"
rm "$SCP/.claude/settings.project.json" "$KIT/_claude-project/settings.json"

# ─── A broken register fails the scan loudly ──────────────────────────────
printf '{not json' > "$PROJ/.claude/.kit-patches.json"
run --scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "invalid register fails the scan" || bad "invalid register (rc=$rc)"

exit "$fail"
