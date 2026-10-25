#!/usr/bin/env bash
# Regression suite for settings.sh: each setting resolves kit default → project value →
# the developer's .env, most specific wins; ASSURANCE_LEVEL has no .env layer; --no-env
# reads the project only; an invalid value fails naming the key and the file it came from.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
cd "$tmp" || exit 1
get(){ bash "$D/settings.sh" "$@" 2>"$tmp/err"; }

[ "$(get TEST_RUNNER)" = github ] && ok "TEST_RUNNER: no project file, no .env → the kit default, github" || bad "default runner: $(cat err)"
[ "$(get ASSURANCE_LEVEL)" = assist ] && ok "ASSURANCE_LEVEL: the kit default is assist" || bad "default level: $(cat err)"
mkdir -p .claude
printf '{"TEST_RUNNER":"","ASSURANCE_LEVEL":""}\n' > .claude/sync-substitutions.json
[ "$(get TEST_RUNNER)" = github ] && [ "$(get ASSURANCE_LEVEL)" = assist ] \
    && ok "an empty project value is the kit default" || bad "empty: $(cat err)"
printf '{"TEST_RUNNER":"aws","ASSURANCE_LEVEL":"strict"}\n' > .claude/sync-substitutions.json
[ "$(get TEST_RUNNER)" = aws ] && [ "$(get ASSURANCE_LEVEL)" = strict ] \
    && ok "a project value overrides the kit default" || bad "project: $(cat err)"
printf 'OTHER=1\nTEST_RUNNER=github # on the train\nASSURANCE_LEVEL=assist\n' > .env
[ "$(get TEST_RUNNER)" = github ] && ok "TEST_RUNNER in .env overrides the project, comment stripped" || bad "env over project: $(cat err)"
[ "$(get ASSURANCE_LEVEL)" = strict ] && ok "ASSURANCE_LEVEL has no .env layer: the project value stands" || bad "level env: $(cat err)"
[ "$(get TEST_RUNNER --no-env)" = aws ] && ok "--no-env reads the project value only" || bad "--no-env: $(cat err)"
printf 'TEST_RUNNER=gitlab\n' > .env
out=$(get TEST_RUNNER); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -q "TEST_RUNNER is 'gitlab' in .env — it must be one of: github, aws" "$tmp/err" \
    && ok "an invalid .env value fails (2), naming the key, the value and .env" || bad "invalid env (rc=$rc): $(cat err)"
rm .env
printf '{"ASSURANCE_LEVEL":"Strict"}\n' > .claude/sync-substitutions.json
get ASSURANCE_LEVEL >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q "ASSURANCE_LEVEL is 'Strict' in .claude/sync-substitutions.json — it must be one of: assist, strict" "$tmp/err" \
    && ok "values are matched exactly: Strict fails, naming the project file" || bad "case (rc=$rc): $(cat err)"
printf '{not json\n' > .claude/sync-substitutions.json
get TEST_RUNNER >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q "could not be read as JSON" "$tmp/err" && ok "an unreadable project file fails loud" || bad "bad json (rc=$rc): $(cat err)"
get NOT_A_SETTING >/dev/null; rc=$?
[ "$rc" = 2 ] && grep -q "unknown setting 'NOT_A_SETTING'" "$tmp/err" && ok "an unknown key fails loud" || bad "unknown (rc=$rc): $(cat err)"
printf '{"TEST_RUNNER":"aws"}\n' > .claude/sync-substitutions.json
# shellcheck source=_claude-project/skills/gitflow/scripts/settings.sh
v=$(source "$D/settings.sh"; kit_setting TEST_RUNNER) && [ "$v" = aws ] \
    && ok "sourced, kit_setting resolves the same" || bad "sourced: $v"

exit "$fail"
