#!/usr/bin/env bash
# Regression suite for _claude-project/templates/scripts/check-stack.mjs — the
# design-wiring check (section 5).
#
# Lives outside every synced source directory, so it never reaches a consumer.
# Each case builds a throwaway repo, installs the real script at scripts/ as sync
# does (it resolves the repo root from its own location) beside a minimal
# .claude/stack-manifest.json and .claude/sync-substitutions.json, runs it, and
# asserts the exit code and the line that names the result.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$KIT/_claude-project/templates/scripts/check-stack.mjs"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

TOKENS="node .claude/skills/design-system/scripts/check-design-tokens.mjs"
LINT="design.md lint design.md"
BUILD="node ../../.claude/skills/claude-design/scripts/build.mjs design-system/design-system.config.mjs"
CHECK="node ../../.claude/skills/claude-design/scripts/render-check.mjs design-system/design-system.config.mjs"

# repo <name> <lint:tokens> <ui-package-or-empty> — prints the repo path.
# An empty <lint:tokens> leaves design.md out entirely.
repo() {
    local r="$tmp/$1"
    mkdir -p "$r/scripts" "$r/.claude"
    cp "$S" "$r/scripts/"
    echo '{"packages":{},"banned":{},"references":[],"blessed_at":"test"}' > "$r/.claude/stack-manifest.json"
    # <ui-package>: a path; "OFF" = "" listed in _intentionally_empty; "UNSET" = key absent; "" = empty, unlisted.
    case "$3" in
        OFF)   echo '{"DESIGN_UI_PACKAGE":"","_intentionally_empty":["DESIGN_UI_PACKAGE"]}' ;;
        UNSET) echo '{}' ;;
        *)     printf '{"DESIGN_UI_PACKAGE":"%s"}\n' "$3" ;;
    esac > "$r/.claude/sync-substitutions.json"
    if [ -n "$2" ]; then
        echo '# Design' > "$r/design.md"
        jq -n --arg t "$2" --arg l "$LINT" \
            '{name:"root",private:true,workspaces:["packages/*"],scripts:{"lint:tokens":$t,"lint:design":$l}}' > "$r/package.json"
    else
        echo '{"name":"root","private":true,"workspaces":["packages/*"]}' > "$r/package.json"
    fi
    echo "$r"
}

# ui <repo> <build:design-system> — adds packages/ui holding the design-system config.
ui() {
    mkdir -p "$1/packages/ui/design-system"
    echo 'export default {}' > "$1/packages/ui/design-system/design-system.config.mjs"
    jq -n --arg b "$2" --arg c "$CHECK" \
        '{name:"@ui/kit",scripts:{"build:design-system":$b,"check:design-system":$c}}' > "$1/packages/ui/package.json"
}

# expect <name> <repo> <exit> <text the output must contain>
expect() {
    local out code
    out=$(node "$2/scripts/check-stack.mjs" 2>&1); code=$?
    if [ "$code" -ne "$3" ]; then bad "$1 (exit $code, wanted $3): $out"; return; fi
    if ! grep -qF -- "$4" <<<"$out"; then bad "$1 (missing \"$4\"): $out"; return; fi
    ok "$1"
}

r=$(repo exact "$TOKENS" OFF)
expect "design system not set up (key intentionally empty): lint scripts checked, engine scripts not required" "$r" 0 "2 design script(s) checked (design system not set up: DESIGN_UI_PACKAGE is intentionally empty)"

r=$(repo unlisted "$TOKENS" "")
expect "DESIGN_UI_PACKAGE empty but not in _intentionally_empty fails naming both choices" "$r" 1 "DESIGN_UI_PACKAGE is empty and not listed in _intentionally_empty"

r=$(repo unset "$TOKENS" UNSET)
expect "DESIGN_UI_PACKAGE missing fails naming both choices" "$r" 1 "DESIGN_UI_PACKAGE is not set — design.md exists, so set it to the UI package"

r=$(repo off-unwired "" OFF); echo '# Design' > "$r/design.md"
expect "not set up still needs lint:tokens wired, so it can say why" "$r" 1 "no \"lint:tokens\" script"

r=$(repo wrong-tokens "node scripts/check-design-tokens.mjs" OFF)
expect "lint:tokens pointing at another script fails" "$r" 1 "\"lint:tokens\" is \"node scripts/check-design-tokens.mjs\""

r=$(repo no-design "" UNSET)
expect "no design.md: the design check does not apply" "$r" 0 "no design.md"

r=$(repo ui-right "$TOKENS" "packages/ui"); ui "$r" "$BUILD"
expect "UI package with the kit build:design-system passes" "$r" 0 "4 design script(s) checked"

r=$(repo ui-wrong "$TOKENS" "packages/ui"); ui "$r" "node scripts/build.mjs design-system/design-system.config.mjs"
expect "UI package with build:design-system pointing elsewhere fails" "$r" 1 "packages/ui/package.json: \"build:design-system\""

r=$(repo ui-wrong-arg "$TOKENS" "packages/ui"); ui "$r" "node ../../.claude/skills/claude-design/scripts/build.mjs other.config.mjs"
expect "UI package with build:design-system on the wrong config fails" "$r" 1 "packages/ui/package.json: \"build:design-system\""

exit $fail
