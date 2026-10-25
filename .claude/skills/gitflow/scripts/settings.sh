#!/bin/bash
# The kit's layered settings, for the gitflow scripts and CI. Each setting has a kit
# default; a project value in .claude/sync-substitutions.json overrides it, and where the
# setting allows it, a developer's own value in .env overrides that — the most specific
# wins. A value outside the setting's allowed set fails loud, naming the key and the file
# it came from. test/settings.ts is the same model for the test harness's settings;
# pipeline.md §1.6 describes both settings below.
#
#   TEST_RUNNER       github | aws      default github   project, then .env
#                     Where the full test suite runs: GitHub Actions (ci.yml's vitest job),
#                     or a CodeBuild project in the project's own AWS account.
#   ASSURANCE_LEVEL   assist | strict   default assist   project only
#                     How much the gates refuse rather than warn.
#
# Sourced:  source settings.sh; value=$(kit_setting TEST_RUNNER) || exit 2
# Run:      bash settings.sh <KEY> [--no-env]
#           --no-env reads the project value only — CI, which has no .env, passes it.
# Prints the resolved value. Exit 2 on an invalid value or an unknown key.

# kit_setting <KEY> [--no-env] — prints the value <KEY> resolves to here.
kit_setting() {
    local key="$1" no_env="${2:-}" default allowed env_layer value from subs=".claude/sync-substitutions.json"
    case "$key" in
        TEST_RUNNER)     default="github"; allowed="github aws";     env_layer=1 ;;
        ASSURANCE_LEVEL) default="assist"; allowed="assist strict";  env_layer=0 ;;
        *) echo "settings.sh: unknown setting '$key'" >&2; return 2 ;;
    esac
    [ "$no_env" = "--no-env" ] && env_layer=0
    value="$default"; from="the kit default"
    if [ -f "$subs" ]; then
        local project
        if ! project=$(jq -r --arg k "$key" '.[$k] // "" | strings' "$subs" 2>/dev/null); then
            echo "settings.sh: $subs could not be read as JSON, so $key cannot be resolved." >&2
            return 2
        fi
        if [ -n "$project" ]; then value="$project"; from="$subs"; fi
    fi
    if [ "$env_layer" -eq 1 ] && [ -f .env ]; then
        local mine
        mine=$(grep "^${key}=" .env 2>/dev/null | tail -n 1 | cut -d'=' -f2- | cut -d'#' -f1 | xargs || true)
        if [ -n "$mine" ]; then value="$mine"; from=".env"; fi
    fi
    case " $allowed " in
        *" $value "*) printf '%s\n' "$value" ;;
        *)
            echo "settings.sh: $key is '$value' in $from — it must be one of: ${allowed// /, }." >&2
            return 2 ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    [ $# -ge 1 ] || { echo "usage: settings.sh <KEY> [--no-env]" >&2; exit 2; }
    kit_setting "$@"
fi
