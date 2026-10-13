#!/usr/bin/env bash
# Regression suite for design-review.sh. A stub CLI stands in for claude: it records what it
# was sent and answers with whatever $STUB_MODE selects.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/design-review.sh"
# The token checker: beside this script in a consumer, in the kit's source when run from the
# kit's own copy, where the design-system skill is template-only. An org repo has neither —
# it receives no design-system skill — so only the cases that stop before the checker run.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="$HERE/../../design-system/scripts/check-design-tokens.mjs"
[ -f "$CHECKER" ] || CHECKER="$(git -C "$HERE" rev-parse --show-toplevel)/_claude-project/skills/design-system/scripts/check-design-tokens.mjs"
export DESIGN_REVIEW_CHECKER="$CHECKER"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
case "$STUB_MODE" in
  clean)   echo '{"is_error":false,"structured_output":{"findings":[]}}' ;;
  finding) echo '{"is_error":false,"structured_output":{"findings":[{"file":"src/routes/orders.tsx","line":2,"rule":"CALL-SITE-REPAINT","quote":"<Button className=\"bg-surface\">","finding":"the call site repaints the button","fix":"add a surface variant to Button","confidence":"high"}]}}' ;;
  error)   echo "boom" >&2; exit 3 ;;
  garbage) echo 'not json' ;;
esac
EOF
chmod +x "$tmp/claude"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/.claude/rules/project" "$repo/src/components/ui" "$repo/src/routes" "$repo/src/styles"
  cat > "$repo/.claude/sync-substitutions.json" <<'EOF'
{"DESIGN_UI_PACKAGE": "src", "DESIGN_TOKEN_FILES": "styles/tokens.css", "DESIGN_TYPE_FILE": "", "DESIGN_STYLES_FILE": "", "DESIGN_SOURCE_DIRS": "src", "DESIGN_VENDORED_DIR": "src/components/ui", "DESIGN_VENDORED_RESTYLED": "", "DESIGN_FIELD_LOOK_CLASSES": "", "DESIGN_EXEMPT_COMPONENTS": ""}
EOF
  printf ':root {\n  --color-surface: #fff;\n  --radius-panel: 8px;\n}\n' > "$repo/src/styles/tokens.css"
  printf -- '---\nname: Fixture\n---\n\n# Fixture\n' > "$repo/design.md"
  printf '| Component | Use for | Type | Status |\n|---|---|---|---|\n| `Button` | an action | Button | approved |\n' > "$repo/.claude/rules/project/ui-inventory.md"
  printf 'export const S = () => null\n' > "$repo/src/routes/orders.tsx"
  printf 'export const B = () => null\n' > "$repo/src/components/ui/badge.tsx"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" STUB_LOG="$tmp/log" DESIGN_REVIEW_CLAUDE="$tmp/claude" "$S" "${BASE:-HEAD}" 2>"$tmp/err"); echo $?; }
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }
called(){ [ -f "$tmp/log" ]; }

echo "DOES NOT APPLY:"
new_repo; printf '{"DESIGN_UI_PACKAGE": ""}\n' > "$repo/.claude/sync-substitutions.json"; printf 'x\n' >> "$repo/src/routes/orders.tsx"; rm -f "$tmp/log"
t 0 "$(gate finding)" 'no UI package: exit 0'
grep -q 'does not apply: this project has no UI package' "$tmp/err" && ! called && echo "  ✓ …says why, and the reviewer is never called" || { echo "  ✗ FAIL — no reason, or reviewer called"; fail=1; }
new_repo; rm "$repo/design.md"; printf 'x\n' >> "$repo/src/routes/orders.tsx"; rm -f "$tmp/log"
t 0 "$(gate finding)" 'no design.md: exit 0'
grep -q 'does not apply: there is no design.md' "$tmp/err" && echo "  ✓ …and says so" || { echo "  ✗ FAIL — no reason"; fail=1; }

echo "NOT REVIEWED:"
new_repo; printf 'x\n' > "$repo/README.md"; rm -f "$tmp/log"
t 0 "$(gate finding)" 'nothing UI changed: exit 0'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }
new_repo; printf 'x\n' >> "$repo/src/components/ui/badge.tsx"; rm -f "$tmp/log"
t 0 "$(gate finding)" 'a vendored atom, not restyled, is not reviewed'
new_repo; printf 'x\n' > "$repo/src/routes/orders.test.tsx"; rm -f "$tmp/log"
t 0 "$(gate finding)" 'a test file is not reviewed'

if [ ! -f "$CHECKER" ]; then
  echo "REVIEWED, CANNOT RUN: do not apply — the design-system skill is not installed, so this repo has no UI to review."
  [ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
  exit "$fail"
fi

echo "REVIEWED:"
new_repo; printf 'export const S = () => <Button className="bg-surface" />\n' > "$repo/src/routes/orders.tsx"
t 0 "$(gate clean)" 'a changed screen, clean: exit 0'
grep -q '=== THE DIFF' "$tmp/log" && grep -q 'src/routes/orders.tsx' "$tmp/log" && echo "  ✓ the diff is sent" || { echo "  ✗ FAIL — diff not sent"; fail=1; }
grep -Eq '^ +1 \+export const S' "$tmp/log" && echo "  ✓ …each line numbered as in the new file" || { echo "  ✗ FAIL — lines not numbered"; fail=1; }
grep -q '^radius: rounded-panel' "$tmp/log" && echo "  ✓ the project's roles are sent" || { echo "  ✗ FAIL — roles not sent"; fail=1; }
grep -q '`Button`' "$tmp/log" && echo "  ✓ the inventory is sent" || { echo "  ✗ FAIL — inventory not sent"; fail=1; }
grep -q "=== THE KIT'S DESIGN OPINIONS" "$tmp/log" && grep -q '^# Design opinions' "$tmp/log" && echo "  ✓ the kit's design opinions are sent" || { echo "  ✗ FAIL — design opinions not sent"; fail=1; }
grep -q 'design review clean — 1 UI file' "$tmp/err" && echo "  ✓ a clean review counts what it reviewed" || { echo "  ✗ FAIL — no count"; fail=1; }
t 1 "$(gate finding)" 'a finding: exit 1'
grep -q 'src/routes/orders.tsx:2 — CALL-SITE-REPAINT' "$tmp/err" && grep -q 'fix: add a surface variant' "$tmp/err" && grep -q 'fix it, or skip it' "$tmp/err" && echo "  ✓ …naming the place, why, the fix, and asking fix or skip" || { echo "  ✗ FAIL — message incomplete"; fail=1; }
t 0 "$( (cd "$repo" && SKIP_DESIGN_REVIEW=1 STUB_MODE=finding STUB_LOG="$tmp/log" DESIGN_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>/dev/null); echo $?)" 'SKIP_DESIGN_REVIEW=1: the developer skips, exit 0'
new_repo; printf ':root {\n  --color-surface: #fff;\n  --radius-big: 8px;\n}\n' > "$repo/src/styles/tokens.css"
gate clean >/dev/null; grep -q 'src/styles/tokens.css' "$tmp/log" && echo "  ✓ a token stylesheet is reviewed" || { echo "  ✗ FAIL — stylesheet missed"; fail=1; }
new_repo; printf 'Body text is 15px.\n' >> "$repo/design.md"
gate clean >/dev/null; grep -q 'Body text is 15px' "$tmp/log" && echo "  ✓ design.md is reviewed" || { echo "  ✗ FAIL — design.md missed"; fail=1; }
new_repo; jq '.DESIGN_UI_PACKAGE = "." | .DESIGN_TOKEN_FILES = "src/styles/tokens.css"' "$repo/.claude/sync-substitutions.json" > "$tmp/s.json" && mv "$tmp/s.json" "$repo/.claude/sync-substitutions.json"
git -C "$repo" add -A; git -C "$repo" commit -qm root
printf ':root {\n  --color-surface: #fff;\n  --radius-big: 8px;\n}\n' > "$repo/src/styles/tokens.css"
gate clean >/dev/null; grep -q 'src/styles/tokens.css' "$tmp/log" && echo "  ✓ a UI package at the repository root: its stylesheet is reviewed" || { echo "  ✗ FAIL — root package stylesheet missed"; fail=1; }
new_repo; base=$(git -C "$repo" rev-parse HEAD); printf 'export const N = () => <div />\n' > "$repo/src/routes/new.tsx"; git -C "$repo" add -A; git -C "$repo" commit -qm cp
BASE="$base" gate clean >/dev/null; grep -q 'src/routes/new.tsx' "$tmp/log" && echo "  ✓ a file already in a checkpoint since the base" || { echo "  ✗ FAIL — checkpointed file missed"; fail=1; }
new_repo; printf 'export const U = () => <div />\n' > "$repo/src/routes/untracked.tsx"
gate clean >/dev/null; grep -q 'src/routes/untracked.tsx' "$tmp/log" && echo "  ✓ an untracked file" || { echo "  ✗ FAIL — untracked file missed"; fail=1; }

echo "CANNOT RUN — FAILS:"
new_repo; printf 'x\n' >> "$repo/src/routes/orders.tsx"
t 1 "$(gate error)" 'reviewer exits non-zero: exit 1'
t 1 "$(gate garbage)" 'reviewer returns unparseable output: exit 1'
t 1 "$( (cd "$repo" && DESIGN_REVIEW_CLAUDE="$tmp/no-such-cli" "$S" HEAD 2>/dev/null); echo $?)" 'CLI missing: exit 1'
t 1 "$(BASE=no-such-ref gate clean)" 'a base git cannot diff against: exit 1'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
