#!/usr/bin/env bash
# Regression suite for bash-edit-diff-check.sh. HOME, the managed-settings directory and
# the project all point at temp fixtures, so each resolution branch is tested alone.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-edit-diff-check.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

setup(){ # $1=user json  $2=managed json  $3=project settings.json  $4=project settings.local.json ("" = absent)
  rm -rf "$tmp/home" "$tmp/managed" "$tmp/proj"
  mkdir -p "$tmp/home/.claude" "$tmp/managed/managed-settings.d" "$tmp/proj/.claude"
  [ -n "$1" ] && printf '%s' "$1" > "$tmp/home/.claude/settings.json"
  [ -n "$2" ] && printf '%s' "$2" > "$tmp/managed/managed-settings.json"
  [ -n "$3" ] && printf '%s' "$3" > "$tmp/proj/.claude/settings.json"
  [ -n "$4" ] && printf '%s' "$4" > "$tmp/proj/.claude/settings.local.json"
  return 0
}
run(){ # extra env as args
  printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$tmp/proj" \
  | env -u CLAUDE_CODE_BASH_EDIT_DIFF HOME="$tmp/home" KIT_MANAGED_SETTINGS_DIR="$tmp/managed" CLAUDE_PROJECT_DIR="$tmp/proj" "$@" "$H" 2>/dev/null
}
verdict(){ out=$(run "$@"); if [ -z "$out" ]; then echo silent; else
  printf '%s' "$out" | python3 -c '
import json,sys
d=json.load(sys.stdin)
ok = "bashEditDiffEnabled" in d["systemMessage"] and "Edit and Write" in d["hookSpecificOutput"]["additionalContext"] and d["hookSpecificOutput"]["hookEventName"]=="SessionStart"
print("warn" if ok else "BADPAYLOAD")' 2>/dev/null || echo BADJSON; fi; }
t(){ got=$(verdict "${@:3}"); if [ "$got" = "$1" ]; then echo "  ✓ $2"; else echo "  ✗ FAIL (got $got, want $1) — $2"; fail=1; fi; }

echo "SILENT — recording is on:"
setup '{"bashEditDiffEnabled":true}' '' '' '';                   t silent 'user settings true'
setup '' '{"bashEditDiffEnabled":true}' '' '';                   t silent 'managed settings true'
setup '' '' '' '';  printf '{"bashEditDiffEnabled":true}' > "$tmp/managed/managed-settings.d/10-kit.json"
                                                                 t silent 'managed drop-in true'
setup '' '' '' '';                                               t silent 'env 1' CLAUDE_CODE_BASH_EDIT_DIFF=1
setup '{"bashEditDiffEnabled":true}' '' '{"bashEditDiffEnabled":true}' ''; t silent 'a project true is harmless alongside user true'

echo "WARN — recording is not on:"
setup '' '' '' '';                                               t warn 'nothing set anywhere'
setup '{"theme":"dark"}' '' '' '';                               t warn 'user settings without the key'
setup '{"bashEditDiffEnabled":false}' '' '' '';                  t warn 'user settings false'
setup '{"bashEditDiffEnabled":true}' '' '' '';                   t warn 'env 0 beats user true' CLAUDE_CODE_BASH_EDIT_DIFF=0
setup '{"bashEditDiffEnabled":true}' '{"bashEditDiffEnabled":false}' '' ''; t warn 'managed false beats user true'
setup '{"bashEditDiffEnabled":true}' '' '{"bashEditDiffEnabled":false}' ''; t warn 'project false beats user true'
setup '{"bashEditDiffEnabled":true}' '' '' '{"bashEditDiffEnabled":false}'; t warn 'project-local false beats user true'
setup '' '' '{"bashEditDiffEnabled":true}' '';                   t warn 'a project true alone cannot turn it on'
setup '{"bashEditDiffEnabled":"yes"}' '' '' '';                  t warn 'a non-boolean value is not on'

echo "DEGENERATE INPUT:"
setup 'not json' '' '' '';                                       t warn 'malformed user settings'
setup '' 'not json' '' '';                                       t warn 'malformed managed settings'
for p in '' 'not json' 'null'; do
  out=$(printf '%s' "$p" | env -u CLAUDE_CODE_BASH_EDIT_DIFF HOME="$tmp/home" KIT_MANAGED_SETTINGS_DIR="$tmp/managed" CLAUDE_PROJECT_DIR= "$H" 2>/dev/null); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    echo "  ✓ exits clean with valid JSON: ${p:-<empty>}"
  else echo "  ✗ FAIL (rc=$rc) — ${p:-<empty>}"; fail=1; fi
done

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
