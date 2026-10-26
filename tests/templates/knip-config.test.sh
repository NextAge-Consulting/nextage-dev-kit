#!/usr/bin/env bash
# Regression suite for _claude-project/templates/knip.config.ts — the icon module a
# Claude Design config names is in use, whatever its extension.
#
# Lives outside every synced source directory, so it never reaches a consumer.
# Each case builds a throwaway monorepo with the real config at its root, a UI package
# holding design-system/design-system.config.mjs, and runs the knip version the kit's
# stack manifest pins (fetched by npx, as the kit gate's replay does).
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$KIT/_claude-project/templates/knip.config.ts"
KNIP=$(jq -r '.packages.knip.version' "$KIT/_claude-project/stack-manifest.json")
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# repo <name> <icons file name> — prints the repo path.
repo() {
    local r="$tmp/$1"
    mkdir -p "$r/.claude" "$r/packages/ui/src" "$r/packages/ui/design-system"
    cp "$CONFIG" "$r/knip.config.ts"
    echo '{"DESIGN_UI_PACKAGE":"packages/ui"}' > "$r/.claude/sync-substitutions.json"
    echo '{"name":"root","private":true,"workspaces":["packages/*"]}' > "$r/package.json"
    echo '{"name":"ui","private":true,"exports":{".":"./src/index.ts"},"dependencies":{"react":"*"}}' > "$r/packages/ui/package.json"
    echo 'export const x = 1;' > "$r/packages/ui/src/index.ts"
    printf "export default {\n  name: 'UI',\n  icons: './%s',\n}\n" "$2" > "$r/packages/ui/design-system/design-system.config.mjs"
    printf "import * as React from 'react';\nexport const icons = { Dot: () => React.createElement('span') };\n" > "$r/packages/ui/design-system/$2"
    echo '{"compilerOptions":{"jsx":"react-jsx","module":"esnext","moduleResolution":"bundler"}}' > "$r/tsconfig.json"
    git -C "$r" init -q && git -C "$r" add -A
    echo "$r"
}

# expect_used <name> <icons file name> — knip names neither the icon module nor react.
expect_used() {
    local r report
    r=$(repo "$1" "$2")
    if ! report=$(cd "$r" && npx --yes "knip@$KNIP" --no-progress --no-config-hints --reporter json 2>&1); then
        # knip exits 1 when it reports anything; the JSON still names what it found.
        :
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$report"; then bad "$1: knip printed no report: $(head -3 <<<"$report")"; return; fi
    if grep -q "design-system/$2" <<<"$report"; then bad "$1: the icon module is reported: $report"; return; fi
    if jq -e '[.. | objects | select(.name? == "react")] | length > 0' >/dev/null <<<"$report"; then bad "$1: react is reported unused: $report"; return; fi
    ok "$1"
}

expect_used "an icons.tsx the design-system config names is in use, and so is what it imports" icons.tsx
expect_used "an icons.ts the design-system config names is in use" icons.ts

exit "$fail"
