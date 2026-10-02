#!/usr/bin/env bash
# Regression suite for rule-review.sh. A stub CLI stands in for claude: it records the
# diff it was sent and answers with whatever $STUB_MODE selects.
set -uo pipefail
S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rule-review.sh"
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../hooks" && pwd)/rule-prose.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/claude" <<'EOF'
#!/bin/bash
cat > "$STUB_LOG"
case "$STUB_MODE" in
  clean)    echo '{"is_error":false,"structured_output":{"findings":[]}}' ;;
  findings) echo '{"is_error":false,"structured_output":{"findings":[{"file":".claude/rules/a.md","quote":"written after the \"incident\"","category":"HISTORY","fix":"delete"}]}}' ;;
  error)    echo "boom" >&2; exit 3 ;;
  garbage)  echo 'not json' ;;
esac
EOF
chmod +x "$tmp/claude"

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo/.claude/hooks" "$repo/.claude/rules" "$repo/src"
  cp "$LIB" "$repo/.claude/hooks/rule-prose.sh"
  printf 'rule\n' > "$repo/.claude/rules/a.md"; printf 'x\n' > "$repo/src/app.ts"
  git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
  git -C "$repo" add -A; git -C "$repo" commit -qm init
}
gate(){ # $1=mode, rest=env; runs in $repo, base HEAD unless BASE set
  (cd "$repo" && STUB_MODE="$1" STUB_LOG="$tmp/log" RULE_REVIEW_CLAUDE="$tmp/claude" "$S" "${BASE:-HEAD}" 2>"$tmp/err"); echo $?
}
t(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $2, want $1) — $3"; fail=1; fi; }

echo "PASSES:"
new_repo; printf 'y\n' >> "$repo/src/app.ts"; rm -f "$tmp/log"
t 0 "$(gate findings)" 'no rule-prose change: exit 0'
[ ! -f "$tmp/log" ] && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called with nothing to review"; fail=1; }
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"
t 0 "$(gate clean)" 'clean review: exit 0'
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"
t 0 "$( (cd "$repo" && SKIP_RULE_REVIEW=1 STUB_MODE=findings STUB_LOG="$tmp/log" RULE_REVIEW_CLAUDE="$tmp/claude" "$S" HEAD 2>/dev/null); echo $?)" 'SKIP_RULE_REVIEW=1: exit 0'
new_repo; git -C "$repo" rm -q .claude/rules/a.md; rm -f "$tmp/log"
t 0 "$(gate findings)" 'a deleted rule file is not reviewed'
new_repo; printf 'kit rule\n' > "$repo/.claude/rules/a.md"; rm -f "$tmp/log"
printf '{"files":{".claude/rules/a.md":{"sha":"%s","mode":"owned"}}}' "$(shasum -a 256 "$repo/.claude/rules/a.md" | cut -d' ' -f1)" > "$repo/.claude/.kit-sync.json"
t 0 "$(gate findings)" 'a rule file exactly as /sync-dev-kit delivered it is not reviewed'
[ ! -f "$tmp/log" ] && echo "  ✓ …and the reviewer is never called" || { echo "  ✗ FAIL — reviewer called for kit-delivered content"; fail=1; }

echo "FAILS:"
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"
t 1 "$(gate findings)" 'findings: exit 1'
grep -q 'written after the "incident"' "$tmp/err" && echo "  ✓ …and the finding is printed" || { echo "  ✗ FAIL — finding not printed"; fail=1; }
t 1 "$(gate error)" 'reviewer exits non-zero: exit 1 (a gate that cannot run fails)'
t 1 "$(gate garbage)" 'reviewer returns unparseable output: exit 1'
new_repo; printf 'kit rule\n' > "$repo/.claude/rules/a.md"
printf '{"files":{".claude/rules/a.md":{"sha":"%s","mode":"owned"}}}' "$(shasum -a 256 "$repo/.claude/rules/a.md" | cut -d' ' -f1)" > "$repo/.claude/.kit-sync.json"
printf 'edited here\n' >> "$repo/.claude/rules/a.md"
t 1 "$(gate findings)" 'a kit-delivered rule file edited after delivery is reviewed'
t 1 "$( (cd "$repo" && RULE_REVIEW_CLAUDE="$tmp/no-such-cli" "$S" HEAD 2>/dev/null); echo $?)" 'CLI missing: exit 1'
mkdir -p "$tmp/lone/scripts" && cp "$S" "$tmp/lone/scripts/rule-review.sh"
t 1 "$( (cd "$repo" && STUB_MODE=clean STUB_LOG="$tmp/log" RULE_REVIEW_CLAUDE="$tmp/claude" "$tmp/lone/scripts/rule-review.sh" HEAD 2>/dev/null); echo $?)" 'classifier missing beside the script: exit 1'
new_repo; rm -rf "$repo/.claude/hooks"; printf 'y\n' >> "$repo/src/app.ts"
t 0 "$(gate clean)" 'a repo without .claude/hooks still passes when no rule prose changed'
# python3 parses the reviewer's answer. Without a working one, every answer used to
# read as "no findings".
mkdir -p "$tmp/nopy" "$tmp/stubpy"
printf '#!/bin/sh\nexit 127\n' > "$tmp/nopy/python3"
printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store" >&2\nexit 9009\n' > "$tmp/stubpy/python3"
chmod +x "$tmp/nopy/python3" "$tmp/stubpy/python3"
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"; rm -f "$tmp/log"
t 1 "$(PATH="$tmp/nopy:$PATH" gate findings)" 'python3 missing: exit 1, not clean'
grep -q 'python3' "$tmp/err" && echo "  ✓ …and the failure names python3" || { echo "  ✗ FAIL — python3 not named"; fail=1; }
[ ! -f "$tmp/log" ] && echo "  ✓ …and the reviewer is never paid for" || { echo "  ✗ FAIL — reviewer called without a parser"; fail=1; }
t 1 "$(PATH="$tmp/stubpy:$PATH" gate findings)" 'python3 present but not a real interpreter: exit 1'
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"
t 1 "$(BASE=no-such-ref gate clean)" 'a base git cannot diff against: exit 1, not "nothing changed"'
grep -q 'no-such-ref' "$tmp/err" && echo "  ✓ …and the failure names the base" || { echo "  ✗ FAIL — base not named"; fail=1; }

echo "SAYS WHAT IT LOOKED AT:"
new_repo; printf 'y\n' >> "$repo/src/app.ts"
gate clean >/dev/null
grep -q 'no rule-prose files changed' "$tmp/err" && echo "  ✓ nothing to review is said, not silent" || { echo "  ✗ FAIL — silent pass"; fail=1; }
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"
gate clean >/dev/null
grep -q 'clean — 1 rule-prose file(s) reviewed' "$tmp/err" && echo "  ✓ a clean review counts what it reviewed" || { echo "  ✗ FAIL — no count: $(cat "$tmp/err")"; fail=1; }
new_repo; printf 'n\n' > "$repo/.claude/rules/sp ace.md"; rm -f "$tmp/log"
gate clean >/dev/null
grep -q 'sp ace.md' "$tmp/log" && echo "  ✓ a path with a space is reviewed" || { echo "  ✗ FAIL — spaced path dropped"; fail=1; }

echo "WHAT THE REVIEWER IS SENT:"
new_repo; printf 'more\n' >> "$repo/.claude/rules/a.md"; printf 'y\n' >> "$repo/src/app.ts"; printf 'n\n' > "$repo/.claude/rules/new.md"
gate clean >/dev/null
grep -q '+more' "$tmp/log" && echo "  ✓ a tracked rule's diff" || { echo "  ✗ FAIL — tracked diff missing"; fail=1; }
grep -q 'new.md' "$tmp/log" && echo "  ✓ an untracked rule file" || { echo "  ✗ FAIL — untracked file missing"; fail=1; }
! grep -q 'app.ts' "$tmp/log" && echo "  ✓ never a non-prose file" || { echo "  ✗ FAIL — non-prose file sent"; fail=1; }
new_repo; base=$(git -C "$repo" rev-parse HEAD); printf 'cp\n' >> "$repo/.claude/rules/a.md"
git -C "$repo" commit -qam checkpoint
BASE="$base" gate clean >/dev/null
grep -q '+cp' "$tmp/log" && echo "  ✓ content already in a checkpoint since the base" || { echo "  ✗ FAIL — checkpointed change missing"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
