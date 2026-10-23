#!/usr/bin/env bash
# Regression suite for bash-edit-diff-check.sh. HOME, the managed-settings directory and
# the project all point at temp fixtures, so each resolution branch is tested alone.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-edit-diff-check.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

setup(){ # $1=user json  $2=managed json  $3=project settings.json  $4=project settings.local.json ("" = absent)
  rm -rf "${tmp:?}/home" "${tmp:?}/managed" "${tmp:?}/proj"
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

echo "WORKTREE — the session's checkout is the payload's cwd, not CLAUDE_PROJECT_DIR:"
# gitflow's worktree mode puts each worktree at <primary>/.claude/worktrees/<label>, and
# Claude Code keeps CLAUDE_PROJECT_DIR at the primary in a worktree session. Only the
# worktree turns the recording off, in its own untracked settings.local.json.
setup '{"bashEditDiffEnabled":true}' '' '' ''
wp="$tmp/wtp"; mkdir -p "$wp/.claude"; printf '{}' > "$wp/.claude/settings.json"
git -C "$wp" init -q; git -C "$wp" config user.email t@example.com; git -C "$wp" config user.name t
git -C "$wp" add -A; git -C "$wp" commit -qm init
git -C "$wp" worktree add -q "$wp/.claude/worktrees/x" -b wt-x 2>/dev/null
ww="$wp/.claude/worktrees/x"
printf '{"bashEditDiffEnabled":false}' > "$ww/.claude/settings.local.json"
in_cwd(){ printf '{"hook_event_name":"SessionStart","cwd":"%s"}' "$1" \
  | env -u CLAUDE_CODE_BASH_EDIT_DIFF HOME="$tmp/home" KIT_MANAGED_SETTINGS_DIR="$tmp/managed" CLAUDE_PROJECT_DIR="$wp" "$H" 2>/dev/null; }
[ -n "$(in_cwd "$ww")" ] && echo "  ✓ a session in the worktree reads the worktree's settings" || { echo "  ✗ FAIL — the worktree's false was not read"; fail=1; }
[ -z "$(in_cwd "$wp")" ] && echo "  ✓ a session in the primary reads the primary's" || { echo "  ✗ FAIL — the primary warned"; fail=1; }

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
