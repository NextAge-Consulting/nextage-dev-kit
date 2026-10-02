#!/usr/bin/env bash
# Regression suite for rule-authoring-guard.sh.
#
# The guard denies ONCE per file per session and allows everything after, so every case here
# runs under its own session id. A shared id would make case order decide the result,
# which is the bug most likely to hide a real regression.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rule-authoring-guard.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

n=0
raw(){ # $1=file_path $2=session_id $3=tool_name
  printf '{"tool_name":"%s","tool_input":{"file_path":%s},"session_id":"%s","cwd":"/repo"}' \
    "$3" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" "$2" \
  | "$H" 2>/dev/null
}
decision(){
  raw "$@" | python3 -c '
import json,sys
s=sys.stdin.read().strip()
if not s: print("allow"); raise SystemExit
try: print((json.loads(s).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("BADJSON")
'
}
t(){ n=$((n+1)); d=$(decision "$2" "s$n-$RANDOM" "${4:-Write}")
     if [ "$d" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $d, want $1) — $3"; fail=1; fi; }

echo "MUST ALLOW — surfaces the skill has nothing to say about:"
t allow "/repo/.claude/skills/gitflow/scripts/commit.sh" 'shell script inside a skill dir'
t allow "/repo/.claude/hooks/git-guard.sh"               'a hook'
t allow "/repo/project-documentation/kitmaintainer-handbook.md"        'ordinary project doc'
t allow "/repo/README.md"                                'repo README'
t allow "/repo/src/rules/pricing.md"                     'app dir that merely contains "rules"'
t allow "/repo/.claude/settings.json"                    'settings json'
t allow "/repo/.claude/rules/constitution.md" 'non-edit tool (Bash)' Bash
t allow "/repo/.claude/rules/constitution.md" 'non-edit tool (Read)' Read

echo "MUST DENY — authored-prose surfaces:"
t deny "/repo/.claude/rules/constitution.md"          'a rule'
t deny "/repo/.claude/rules/project/ui-inventory.md"  'a project-owned rule'
t deny "/repo/.claude/skills/research/SKILL.md"       'a skill'
t deny "/repo/.claude/skills/e2e/references/flow.md"  'a skill reference file'
t deny "/repo/.claude/output-styles/house.md"         'an output style'
t deny "/repo/CLAUDE.md"                              'root CLAUDE.md'
t deny "/repo/.claude/CLAUDE.md"                      'nested CLAUDE.md'
t deny "/repo/_claude-project/rules/git.md"           'kit source rule'
t deny "/repo/_claude-project/skills/gitflow/SKILL.md" 'kit source skill'
t deny "/repo/.claude/commands/commit.md"             'a command'
t deny "/repo/.claude/agents/reviewer.md"             'an agent'
t deny "/repo/_claude-project/commands/commit.md"     'kit source command'
t deny "/repo/_claude-project/templates/ui-inventory.md" 'kit inventory template'
t deny "/repo/_claude-maintainer/kit-maintainer.md"   'kit maintainer surface'
t deny ".claude/rules/git.md"                         'relative path'
t deny "/repo/.claude/rules/constitution.md" 'Edit tool'      Edit
t deny "/repo/.claude/rules/constitution.md" 'MultiEdit tool' MultiEdit

echo "ONCE PER FILE PER SESSION — the cap that stops it looping:"
S="repeat-$RANDOM"
d1=$(decision "/repo/.claude/rules/git.md" "$S" Write)
d2=$(decision "/repo/.claude/rules/git.md" "$S" Edit)
d3=$(decision "/repo/.claude/skills/research/SKILL.md" "$S" Write)
d4=$(decision "/repo/.claude/skills/research/SKILL.md" "$S" Write)
if [ "$d1" = "deny" ] && [ "$d2" = "allow" ] && [ "$d3" = "deny" ] && [ "$d4" = "allow" ]; then
  echo "  ✓ each file denied once, then allowed, within one session"
else
  echo "  ✗ FAIL (got $d1/$d2/$d3/$d4, want deny/allow/deny/allow) — per-file cap"; fail=1
fi
d4=$(decision "/repo/.claude/rules/git.md" "other-$RANDOM" Write)
if [ "$d4" = "deny" ]; then echo "  ✓ a different session is nudged independently"
else echo "  ✗ FAIL (got $d4, want deny) — per-session isolation"; fail=1; fi

echo "OVERRIDE:"
if [ "$(SKIP_RULE_AUTHORING=1 decision "/repo/.claude/rules/git.md" "ov-$RANDOM" Write)" = "allow" ]; then
  echo "  ✓ SKIP_RULE_AUTHORING=1 allows"
else echo "  ✗ FAIL — override did not allow"; fail=1; fi

echo "DENY PAYLOAD MUST BE VALID JSON:"
for p in "/repo/.claude/rules/it's \"quoted\" \\ weird.md" "/repo/.claude/skills/a b/SKILL.md" "/repo/.claude/rules/naïve—dash.md"; do
  out=$(raw "$p" "j$RANDOM" Write)
  if printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["hookSpecificOutput"]["permissionDecision"]=="deny"' 2>/dev/null; then
    echo "  ✓ valid deny JSON: ${p##*/}"
  else
    echo "  ✗ FAIL — unparseable or non-deny payload: ${p##*/}"; fail=1
  fi
done

echo "DENY REASON CARRIES THE RULES:"
reason=$(raw "/repo/.claude/rules/git.md" "r$RANDOM" Write | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null)
if printf '%s' "$reason" | grep -q "A rule is an instruction" && ! printf '%s' "$reason" | grep -q "^name: rule-authoring"; then
  echo "  ✓ the skill body is in the reason, frontmatter stripped"
else
  echo "  ✗ FAIL — reason does not carry the rule-authoring text"; fail=1
fi

echo "FULL TEXT ONCE PER SESSION, AGAIN AFTER COMPACTION:"
reason_of(){ raw "$1" "$2" Write | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])' 2>/dev/null; }
S="full-$RANDOM"
r1=$(reason_of "/repo/.claude/rules/a.md" "$S"); r2=$(reason_of "/repo/.claude/rules/b.md" "$S")
printf '{"hook_event_name":"PostCompact","session_id":"%s"}' "$S" | "$H" >/dev/null 2>&1
r3=$(reason_of "/repo/.claude/rules/c.md" "$S")
if printf '%s' "$r1" | grep -q "A rule is an instruction" \
   && ! printf '%s' "$r2" | grep -q "A rule is an instruction" && printf '%s' "$r2" | grep -q "given in full earlier" \
   && printf '%s' "$r3" | grep -q "A rule is an instruction"; then
  echo "  ✓ full / reminder / full after PostCompact"
else
  echo "  ✗ FAIL — full-text cadence wrong"; fail=1
fi

echo "WINDOWS-STYLE PATH — the separators do not hide rule prose:"
t deny 'C:\repo\.claude\rules\constitution.md' 'backslash path to a rule'
t deny 'c:/repo/.claude/skills/x/SKILL.md'      'forward-slash drive path to a skill'
t deny '/c/repo/CLAUDE.md'                      'Git Bash drive path to CLAUDE.md'
t allow 'C:\repo\src\rules\pricing.md'        'backslash path to an app dir that merely contains "rules"'
S="win-$RANDOM"
d1=$(decision 'C:\repo\.claude\rules\a.md' "$S" Write); d2=$(decision '/c/repo/.claude/rules/a.md' "$S" Write)
if [ "$d1/$d2" = "deny/allow" ]; then echo "  ✓ C:\\ and /c/ spellings share one per-file marker"
else echo "  ✗ FAIL (got $d1/$d2, want deny/allow) — spellings counted as different files"; fail=1; fi

echo "TOOL MISSING — the guard refuses, naming the tool, never allows:"
pl='{"tool_name":"Write","tool_input":{"file_path":"/repo/src/a.ts"},"session_id":"miss"}'
assert_refuses_without "$H" deny "$(path_without jq)" jq "$pl" 'no jq on PATH'
assert_refuses_without "$H" deny "$(path_with_store_python)" python3 "$pl" 'python3 is the Windows Store stub'
out=$(printf '{"hook_event_name":"PostCompact","session_id":"x"}' | PATH="$(path_without jq)" "$H" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "  ✓ PostCompact without jq exits cleanly"
else echo "  ✗ FAIL (rc $rc, out $out) — PostCompact without jq"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
