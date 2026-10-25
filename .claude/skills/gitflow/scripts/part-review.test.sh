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
printf '%s\n' "$@" > "$STUB_LOG.args"
pwd > "$STUB_LOG.cwd"
echo call >> "$STUB_LOG.calls"
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
calls(){ if [ -f "$tmp/log.calls" ]; then wc -l <"$tmp/log.calls" | tr -d ' '; else echo 0; fi; }
# A passed review is remembered under the git dir; forgetting it makes the next run ask again.
forget(){ rm -rf "$(git -C "$repo" rev-parse --path-format=absolute --git-path gitflow-review-cache)"; }
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
grep -q 'part review clean — 1 new part(s) reviewed against 2 component source file(s)' "$tmp/err" && echo "  ✓ a clean review counts what it reviewed" || { echo "  ✗ FAIL — no count: $(cat "$tmp/err")"; fail=1; }
top=$(git -C "$repo" rev-parse --show-toplevel)
grep -qF "Repository root: $top" "$tmp/log" && echo "  ✓ the input names the repository root" || { echo "  ✗ FAIL — no repository root"; fail=1; }
grep -qxF 'src/components/alert.tsx' "$tmp/log" && ! grep -qxF 'src/routes/orders.tsx' "$tmp/log" \
  && echo "  ✓ …and lists the component source files, not other .tsx" || { echo "  ✗ FAIL — component list: $(cat "$tmp/log")"; fail=1; }
[ "$(grep -xF -A1 -- '--tools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ the reviewer gets only the Read, Grep and Glob tools" || { echo "  ✗ FAIL — --tools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--allowedTools' "$tmp/log.args" | sed -n 2p)" = 'Read,Grep,Glob' ] \
  && echo "  ✓ …pre-approved" || { echo "  ✗ FAIL — --allowedTools: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(grep -xF -A1 -- '--add-dir' "$tmp/log.args" | sed -n 2p)" = "$top" ] \
  && echo "  ✓ …with the repository root added by --add-dir" || { echo "  ✗ FAIL — --add-dir: $(tr '\n' ' ' <"$tmp/log.args")"; fail=1; }
[ "$(cat "$tmp/log.cwd")" != "$top" ] && [ "$(cat "$tmp/log.cwd")" != "$repo" ] \
  && echo "  ✓ …running outside the repository, so its settings and CLAUDE.md do not load" || { echo "  ✗ FAIL — ran in the repo"; fail=1; }
forget; t 1 "$(gate duplicate)" 'a suspected duplicate: exit 1'
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

echo "A PASS IS REUSED:"
new_repo; printf 'export const NoticeBox = () => null\n' > "$repo/src/components/notice-box.tsx"; rm -f "$tmp/log.calls"
gate clean >/dev/null; gate clean >/dev/null
[ "$(calls)" = 1 ] && grep -q 'reusing the earlier pass' "$tmp/err" && echo "  ✓ the same input again: no call, and it says it reused the pass" || { echo "  ✗ FAIL — calls=$(calls): $(cat "$tmp/err")"; fail=1; }
[ -d "$(git -C "$repo" rev-parse --path-format=absolute --git-path gitflow-review-cache)" ] && ! git -C "$repo" status --porcelain --ignored | grep -q gitflow-review-cache && echo "  ✓ …recorded under the git dir, never in the tree" || { echo "  ✗ FAIL — the record is not under the git dir"; fail=1; }
printf '// v2\n' >> "$repo/src/components/notice-box.tsx"; gate clean >/dev/null
[ "$(calls)" = 2 ] && echo "  ✓ changed content: reviewed again" || { echo "  ✗ FAIL — changed content reused (calls=$(calls))"; fail=1; }
printf '| `Card` | a panel | Panel | approved |\n' >> "$repo/.claude/rules/project/ui-inventory.md"; gate clean >/dev/null
[ "$(calls)" = 3 ] && echo "  ✓ a changed inventory: reviewed again" || { echo "  ✗ FAIL — changed reference reused (calls=$(calls))"; fail=1; }
cp "$tmp/log" "$tmp/log.before"
printf 'export const Alert = () => "notice"\n' > "$repo/src/components/alert.tsx"
git -C "$repo" commit -qam 'an existing part changed'
gate clean >/dev/null
if cmp -s "$tmp/log.before" "$tmp/log"; then same_input=yes; else same_input=no; fi
[ "$(calls)" = 4 ] && [ "$same_input" = yes ] && echo "  ✓ an existing component changed, the input sent unchanged: reviewed again" || { echo "  ✗ FAIL — a component change reused the pass (calls=$(calls), same input=$same_input)"; fail=1; }
new_repo; printf 'export const NoticeBox = () => null\n' > "$repo/src/components/notice-box.tsx"; rm -f "$tmp/log.calls"
t 1 "$(gate duplicate)" 'a finding fails'
t 1 "$(gate duplicate)" '…and is not remembered: the same input fails again'
[ "$(calls)" = 2 ] && echo "  ✓ …asking the reviewer both times" || { echo "  ✗ FAIL — a finding was reused (calls=$(calls))"; fail=1; }
t 1 "$(gate error)" 'a review that could not run fails'
t 0 "$(gate clean)" '…and is not remembered: the next run reviews'
[ "$(calls)" = 4 ] && echo "  ✓ …asking the reviewer again" || { echo "  ✗ FAIL — a failed run was reused (calls=$(calls))"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
