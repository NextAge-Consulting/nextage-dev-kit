#!/usr/bin/env bash
# Regression suite for part-review.sh. A stub CLI stands in for claude: it records what it
# was sent and answers with whatever $STUB_MODE selects.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/part-review.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
case "$STUB_MODE" in
  clean)     echo '{"is_error":false,"structured_output":{"duplicates":[]}}' ;;
  duplicate) echo '{"is_error":false,"structured_output":{"duplicates":[{"file":"src/components/notice-box.tsx","existing":"Alert","why":"both are an inline notice"}]}}' ;;
  error)     echo "boom" >&2; exit 3 ;;
  garbage)   echo 'not json' ;;
esac
EOF
chmod +x "$tmp/claude"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/.claude/rules/project" "$repo/src/components/ui" "$repo/src/routes"
  printf '| Component | Use for | Type | Status |\n|---|---|---|---|\n| `Alert` | inline notice | PageBanner | approved |\n' > "$repo/.claude/rules/project/ui-inventory.md"
  printf 'export const Alert = () => null\n' > "$repo/src/components/alert.tsx"
  printf 'export const S = () => null\n' > "$repo/src/routes/orders.tsx"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ (cd "$repo" && STUB_MODE="$1" STUB_LOG="$tmp/log" PART_REVIEW_CLAUDE="$tmp/claude" "$S" "${BASE:-HEAD}" 2>"$tmp/err"); echo $?; }
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }
called(){ [ -f "$tmp/log" ]; }

echo "NOT REVIEWED:"
new_repo; printf 'x\n' >> "$repo/src/routes/orders.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'no new part: exit 0'
! called && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called"; fail=1; }
new_repo; printf 'x\n' > "$repo/src/components/alert.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'an edited existing part is not new'
new_repo; mkdir -p "$repo/src/features/orders/components"; printf 'x\n' > "$repo/src/features/orders/body.tsx"; printf 'x\n' > "$repo/src/features/orders/components/n.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'a feature file, even in a components/ folder inside it, is not a part'
new_repo; printf 'x\n' > "$repo/src/components/ui/badge.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'a vendored atom is not reviewed'
new_repo; printf 'x\n' > "$repo/src/components/n.test.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'a test file is not reviewed'
new_repo; mkdir -p "$repo/src/components/shared"; git -C "$repo" rm -q src/components/alert.tsx; printf 'export const Alert = () => null\n' > "$repo/src/components/shared/alert.tsx"; rm -f "$tmp/log"
t 0 "$(gate duplicate)" 'a part moved to another folder is not new'

echo "REVIEWED:"
new_repo; printf 'export const NoticeBox = () => null\n' > "$repo/src/components/notice-box.tsx"
t 0 "$(gate clean)" 'a new part, no duplicate: exit 0'
grep -q '=== NEW PART: src/components/notice-box.tsx' "$tmp/log" && echo "  ✓ the new part's code is sent" || { echo "  ✗ FAIL — new part not sent"; fail=1; }
grep -q '`Alert`' "$tmp/log" && echo "  ✓ the inventory is sent" || { echo "  ✗ FAIL — inventory not sent"; fail=1; }
grep -q 'part review clean — 1 new part' "$tmp/err" && echo "  ✓ a clean review counts what it reviewed" || { echo "  ✗ FAIL — no count"; fail=1; }
t 1 "$(gate duplicate)" 'a suspected duplicate: exit 1'
grep -q 'already drawn by Alert' "$tmp/err" && grep -q 'Ask the human' "$tmp/err" && echo "  ✓ …naming the existing part, and sending the question to the human" || { echo "  ✗ FAIL — message incomplete"; fail=1; }
new_repo; base=$(git -C "$repo" rev-parse HEAD); printf 'export const N = () => null\n' > "$repo/src/components/n.tsx"; git -C "$repo" add -A; git -C "$repo" commit -qm cp
BASE="$base" gate clean >/dev/null; grep -q 'NEW PART: src/components/n.tsx' "$tmp/log" && echo "  ✓ a part already in a checkpoint since the base" || { echo "  ✗ FAIL — checkpointed part missed"; fail=1; }

echo "CANNOT RUN — FAILS:"
new_repo; printf 'x\n' > "$repo/src/components/n.tsx"
t 1 "$(gate error)" 'reviewer exits non-zero: exit 1'
t 1 "$(gate garbage)" 'reviewer returns unparseable output: exit 1'
t 1 "$( (cd "$repo" && PART_REVIEW_CLAUDE="$tmp/no-such-cli" "$S" HEAD 2>/dev/null); echo $?)" 'CLI missing: exit 1'
rm "$repo/.claude/rules/project/ui-inventory.md"
t 1 "$(gate clean)" 'inventory missing: exit 1'
new_repo; printf 'x\n' > "$repo/src/components/n.tsx"
t 1 "$(BASE=no-such-ref gate clean)" 'a base git cannot diff against: exit 1'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
