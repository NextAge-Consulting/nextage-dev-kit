#!/usr/bin/env bash
# Regression suite for design-judge.sh. A stub CLI stands in for claude and answers with
# whatever $STUB_MODE selects. The design-system skill is found beside this script in a
# consumer, or in the kit's source when run from the kit's own copy, where the skill is
# template-only.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/design-judge.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../../design-system"
[ -f "$SKILL/scripts/locate.mjs" ] || SKILL="$(git -C "$HERE" rev-parse --show-toplevel)/_claude-project/skills/design-system"
export DESIGN_JUDGE_SKILL="$SKILL"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
echo call >> "$STUB_LOG.calls"
case "$STUB_MODE" in
  yes)   echo '{"is_error":false,"total_cost_usd":0.01,"structured_output":{"answer":"yes","quotes":["rounded-none"]}}' ;;
  no)    echo '{"is_error":false,"total_cost_usd":0.01,"structured_output":{"answer":"no","quotes":["rounded-none"]}}' ;;
  error) echo "boom" >&2; exit 3 ;;
esac
EOF
chmod +x "$tmp/claude"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/.claude/rules/project" "$repo/.claude/skills/ui-patterns/references" "$repo/packages/ui/src/components" "$repo/apps/web/src/routes"
  cat > "$repo/.claude/sync-substitutions.json" <<'EOF'
{"DESIGN_UI_PACKAGE": "packages/ui", "DESIGN_FEED_BARREL": "src/index.ts", "DESIGN_TOKEN_FILES": "src/tokens.css", "DESIGN_TYPE_FILE": "", "DESIGN_STYLES_FILE": "src/styles.css", "DESIGN_VENDORED_DIR": "", "DESIGN_VENDORED_RESTYLED": "", "DESIGN_FIELD_LOOK_CLASSES": "", "DESIGN_EXEMPT_COMPONENTS": ""}
EOF
  printf '{ "workspaces": ["apps/*", "packages/*"] }\n' > "$repo/package.json"
  printf '{ "name": "@acme/ui" }\n' > "$repo/packages/ui/package.json"
  printf '{ "name": "web", "dependencies": { "@acme/ui": "*" } }\n' > "$repo/apps/web/package.json"
  printf ':root {\n  /* a panel corner */\n  --radius-panel: 8px;\n}\n' > "$repo/packages/ui/src/tokens.css"
  printf '@theme inline {\n  --radius-panel: var(--radius-panel);\n}\n' > "$repo/packages/ui/src/styles.css"
  printf '// ui-status: approved\n// ui-block: FieldGroup\nexport function Card({ className, children }: { className?: string; children?: unknown }) {\n  return <div className={cn("rounded-panel border p-4", className)}>{children}</div>\n}\n' > "$repo/packages/ui/src/components/card.tsx"
  printf '// ui-content\nimport { Card } from "@acme/ui/components/card"\nexport const Orders = () => <Card className="mt-4">x</Card>\n' > "$repo/apps/web/src/routes/orders.tsx"
  printf '| Component | Use for | Type | Status |\n|---|---|---|---|\n| `card` | a group | FieldGroup | approved |\n' > "$repo/.claude/rules/project/ui-inventory.md"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" STUB_LOG="$tmp/log" JUDGE_CLAUDE="$tmp/claude" "$S" "${BASE:-HEAD}" 2>"$tmp/err"); echo $?; }
calls(){ if [ -f "$tmp/log.calls" ]; then wc -l <"$tmp/log.calls" | tr -d ' '; else echo 0; fi; }
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }
has(){ grep -q "$1" "$tmp/err" && echo "  ✓ $2" || { echo "  ✗ FAIL — $2: $(cat "$tmp/err")"; fail=1; }; }
repaint(){ printf '// ui-content\nimport { Card } from "@acme/ui/components/card"\nexport const Orders = () => <Card className="mt-4 rounded-none">x</Card>\n' > "$repo/apps/web/src/routes/orders.tsx"; }

echo "DOES NOT APPLY:"
new_repo; printf '{"DESIGN_UI_PACKAGE": ""}\n' > "$repo/.claude/sync-substitutions.json"; repaint; rm -f "$tmp/log.calls"
t 0 "$(gate yes)" 'no UI package: exit 0'
has 'does not apply: this project has no UI package' '…and says why'
[ "$(calls)" = 0 ] && echo "  ✓ …and the judge is never called" || { echo "  ✗ FAIL — judge called"; fail=1; }

echo "NOTHING TO JUDGE:"
new_repo; printf 'x\n' > "$repo/README.md"; rm -f "$tmp/log.calls"
t 0 "$(gate yes)" 'nothing UI changed: exit 0'
has 'nothing in this change to judge' '…and says so'

echo "A YES IS A PENDING ITEM, NEVER A BLOCK:"
new_repo; repaint; rm -f "$tmp/log.calls"
t 0 "$(gate yes)" 'a repaint the judge confirms: exit 0'
[ "$(calls)" = 3 ] && echo "  ✓ asked three times" || { echo "  ✗ FAIL — calls=$(calls): $(cat "$tmp/err")"; fail=1; }
has 'REPAINT' 'the yes is printed'
has 'pending item in .claude/ui-pending.json' '…and named as a pending item for the human'
[ -f "$repo/.claude/ui-pending.json" ] && grep -q '"question": "REPAINT"' "$repo/.claude/ui-pending.json" && echo "  ✓ the ledger holds it" || { echo "  ✗ FAIL — no ledger entry"; fail=1; }
t 0 "$(gate yes)" 'the same change again: exit 0'
[ "$(calls)" = 3 ] && echo "  ✓ …and the judge is not asked again" || { echo "  ✗ FAIL — asked again (calls=$(calls))"; fail=1; }

echo "A NO LEAVES NOTHING PENDING:"
new_repo; repaint; rm -f "$tmp/log.calls"
t 0 "$(gate no)" 'a no: exit 0'
has '0 yes, 1 no' 'the count says so'
[ ! -s "$repo/.claude/ui-pending.json" ] || [ "$(cat "$repo/.claude/ui-pending.json")" = "[]" ] && echo "  ✓ the ledger holds nothing" || { echo "  ✗ FAIL — ledger: $(cat "$repo/.claude/ui-pending.json")"; fail=1; }

echo "CANNOT RUN — ADVISORY:"
new_repo; repaint; rm -f "$tmp/log.calls"
t 0 "$(gate error)" 'the judge CLI fails: exit 0'
has 'could not run' '…and says it could not run'
has 'It is advice, not a gate' '…and that the commit goes ahead'
t 0 "$( (cd "$repo" && JUDGE_CLAUDE="$tmp/no-such-cli" "$S" HEAD 2>"$tmp/err"); echo $?)" 'CLI missing: exit 0'
has 'not on PATH' '…naming why'
t 0 "$( (cd "$repo" && SKIP_DESIGN_JUDGE=1 STUB_MODE=yes STUB_LOG="$tmp/log" JUDGE_CLAUDE="$tmp/claude" "$S" HEAD 2>"$tmp/err"); echo $?)" 'SKIP_DESIGN_JUDGE=1: exit 0'
has 'skipped' '…and says so'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
