#!/usr/bin/env bash
# Regression suite for _claude-project/templates/scripts/check-stack.mjs — the
# design-wiring check (section 5), CI-installed pins, lockfile copies and whenResolved.
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
        '{name:"@acme/ui",scripts:{"build:design-system":$b,"check:design-system":$c}}' > "$1/packages/ui/package.json"
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
expect "no UI package (key intentionally empty): lint scripts checked, engine scripts not required" "$r" 0 "2 design script(s) checked (no UI package: DESIGN_UI_PACKAGE is intentionally empty)"

r=$(repo unlisted "$TOKENS" "")
expect "DESIGN_UI_PACKAGE empty but not in _intentionally_empty fails naming both choices" "$r" 1 "DESIGN_UI_PACKAGE is empty and not listed in _intentionally_empty"

r=$(repo unset "$TOKENS" UNSET)
expect "DESIGN_UI_PACKAGE missing fails naming both choices" "$r" 1 "DESIGN_UI_PACKAGE is not set — design.md exists, so set it to the UI package"

r=$(repo off-unwired "" OFF); echo '# Design' > "$r/design.md"
expect "no UI package still needs lint:tokens wired, so it can say why" "$r" 1 "no \"lint:tokens\" script"

r=$(repo wrong-tokens "node scripts/check-design-tokens.mjs" OFF)
expect "lint:tokens pointing at another script fails" "$r" 1 "\"lint:tokens\" is \"node scripts/check-design-tokens.mjs\""

r=$(repo no-design "" UNSET)
expect "no design.md: the design check does not apply" "$r" 0 "no design.md"

# node <repo> <nvmrc-or-empty> <engines-or-empty> — pins Node 24 in the manifest, with a
# Dockerfile and a workflow already on it.
node_repo() {
    local r; r=$(repo "$1" "" UNSET)
    jq '.node = {major: 24}' "$r/.claude/stack-manifest.json" > "$r/m.json" && mv "$r/m.json" "$r/.claude/stack-manifest.json"
    [ -n "$2" ] && echo "$2" > "$r/.nvmrc"
    [ -n "$3" ] && jq --arg e "$3" '.engines = {node: $e}' "$r/package.json" > "$r/p.json" && mv "$r/p.json" "$r/package.json"
    printf 'FROM public.ecr.aws/docker/library/node:24-bookworm-slim AS base\n' > "$r/Dockerfile"
    mkdir -p "$r/.github/workflows"
    printf "jobs:\n  a:\n    steps:\n      - uses: actions/setup-node@v4\n        with:\n          node-version: '24'\n" > "$r/.github/workflows/ci.yml"
    echo "$r"
}

r=$(node_repo node-ok 24.18.0 ">=24.18.0 <25")
expect "Node pinned and everything on its major passes" "$r" 0 "Node 24 in .nvmrc, engines, 1 Dockerfile(s) and 1 workflow(s)"

r=$(node_repo node-nvmrc 22.22.1 ">=24")
expect "an .nvmrc on another major fails" "$r" 1 '.nvmrc: "22.22.1"'

r=$(node_repo node-no-nvmrc "" ">=24")
expect "no .nvmrc fails" "$r" 1 ".nvmrc: missing"

r=$(node_repo node-engines 24.18.0 ">=22.12")
expect "an engines floor below the major fails" "$r" 1 'engines.node is ">=22.12"'

r=$(node_repo node-no-engines 24.18.0 "")
expect "no engines.node fails" "$r" 1 "no engines.node"

r=$(node_repo node-docker 24.18.0 ">=24"); mkdir -p "$r/apps/web"; printf 'FROM node:22-alpine\n' > "$r/apps/web/Dockerfile.web"
expect "a Dockerfile on another major fails, found below the root" "$r" 1 "apps/web/Dockerfile.web: FROM node:22-alpine"

r=$(node_repo node-ci 24.18.0 ">=24"); printf "      - with:\n          node-version: 22\n" >> "$r/.github/workflows/ci.yml"
expect "a workflow on another major fails" "$r" 1 ".github/workflows/ci.yml: node-version 22"

r=$(repo ui-right "$TOKENS" "packages/ui"); ui "$r" "$BUILD"
expect "UI package with the kit build:design-system passes" "$r" 0 "4 design script(s) checked"

r=$(repo ui-wrong "$TOKENS" "packages/ui"); ui "$r" "node scripts/build.mjs design-system/design-system.config.mjs"
expect "UI package with build:design-system pointing elsewhere fails" "$r" 1 "packages/ui/package.json: \"build:design-system\""

r=$(repo ui-wrong-arg "$TOKENS" "packages/ui"); ui "$r" "node ../../.claude/skills/claude-design/scripts/build.mjs other.config.mjs"
expect "UI package with build:design-system on the wrong config fails" "$r" 1 "packages/ui/package.json: \"build:design-system\""

# ci <name> <workflow line> — a repo whose pyrightconfig.json makes the CI-installed
# pyright pin apply, with .github/workflows/ci.yml carrying <workflow line>.
ci() {
    local r
    r=$(repo "$1" "" OFF)
    jq '.packages.pyright = {version:"1.1.409",applies:{whenFile:["pyrightconfig.json"]},severity:"required",installedBy:"ci",ciWorkflow:".github/workflows/ci.yml"}' \
        "$r/.claude/stack-manifest.json" > "$r/m.json" && mv "$r/m.json" "$r/.claude/stack-manifest.json"
    echo '{}' > "$r/pyrightconfig.json"
    mkdir -p "$r/.github/workflows"
    printf '%s\n' "$2" > "$r/.github/workflows/ci.yml"
    echo "$r"
}

r=$(ci pip-pin 'uv run --with pyright==1.1.409 pyright --stats')
expect "a CI-installed tool pinned the pip way (name==version) passes" "$r" 0 "✓"

r=$(ci npm-pin 'npx --yes pyright@1.1.409')
expect "a CI-installed tool pinned the npm way (name@version) passes" "$r" 0 "✓"

r=$(ci unpinned 'uv run --with pyright pyright --stats')
expect "a CI-installed tool the workflow does not pin fails" "$r" 1 "installs pyright without the blessed version 1.1.409"

r=$(ci other-pin 'uv run --with pyright==1.1.400 pyright --stats')
expect "a CI-installed tool pinned at another version fails" "$r" 1 "installs pyright without the blessed version 1.1.409"

# lockrepo <name> <nested version or empty> — packages/ui declares esbuild at the blessed
# version; the lockfile holds another dependency's 0.25.12 at the root, and the
# workspace's own copy when <nested version> is given.
lockrepo() {
    local r; r=$(repo "$1" "" UNSET)
    jq '.packages.esbuild = {version:"0.28.2",applies:"whenDeclared",severity:"required"}' \
        "$r/.claude/stack-manifest.json" > "$r/m.json" && mv "$r/m.json" "$r/.claude/stack-manifest.json"
    mkdir -p "$r/packages/ui"
    echo '{"name":"@acme/ui","devDependencies":{"esbuild":"0.28.2"}}' > "$r/packages/ui/package.json"
    jq -n --arg v "$2" '{lockfileVersion:3,packages:({"node_modules/esbuild":{version:"0.25.12"}}
        + (if $v == "" then {} else {"packages/ui/node_modules/esbuild":{version:$v}} end))}' > "$r/package-lock.json"
    echo "$r"
}

r=$(lockrepo nested 0.28.2)
expect "a workspace's own blessed copy passes though another dependency holds an older one at the root" "$r" 0 "✓"

r=$(lockrepo hoisted "")
expect "a workspace that resolves the root's older copy fails" "$r" 1 "esbuild resolves to 0.25.12, blessed is 0.28.2"

r=$(lockrepo nested-old 0.27.0)
expect "a workspace's own older copy fails, naming the workspace" "$r" 1 "esbuild resolves to 0.27.0 for packages/ui, blessed is 0.28.2"

# pinrepo <name> <DESIGN_UI_PACKAGE value> — the manifest pins esbuild whenever the UI
# package's design-system config exists, with the key read when the check runs; the config
# exists under packages/ui and esbuild is declared nowhere.
pinrepo() {
    local r; r=$(repo "$1" "" "$2")
    jq '.packages.esbuild = {version:"0.28.2",applies:{whenFile:["$DESIGN_UI_PACKAGE/design-system/design-system.config.mjs"]},severity:"required",installedBy:"project"}' \
        "$r/.claude/stack-manifest.json" > "$r/m.json" && mv "$r/m.json" "$r/.claude/stack-manifest.json"
    mkdir -p "$r/packages/ui/design-system"
    echo 'export default {}' > "$r/packages/ui/design-system/design-system.config.mjs"
    echo '{"name":"@acme/ui"}' > "$r/packages/ui/package.json"
    echo "$r"
}

r=$(pinrepo key-set packages/ui)
expect "a whenFile trigger reads DESIGN_UI_PACKAGE when the check runs, so a key set after sync applies the pin" "$r" 1 "is present but \"esbuild\" is declared nowhere"

r=$(pinrepo key-off OFF)
expect "a whenFile trigger whose key is deliberately empty names no file, so the pin does not apply" "$r" 0 "✓"

# resolvedrepo <name> <declared range or empty> <lockfile entries as JSON> — the manifest
# requires zod v4 anywhere in the tree; packages/app declares <declared range> when given.
resolvedrepo() {
    local r; r=$(repo "$1" "" UNSET)
    jq '.packages.zod = {version:"4",applies:"whenResolved",severity:"required"}' \
        "$r/.claude/stack-manifest.json" > "$r/m.json" && mv "$r/m.json" "$r/.claude/stack-manifest.json"
    mkdir -p "$r/packages/app"
    if [ -n "$2" ]; then
        jq -n --arg v "$2" '{name:"@acme/app",dependencies:{zod:$v}}' > "$r/packages/app/package.json"
    else
        echo '{"name":"@acme/app"}' > "$r/packages/app/package.json"
    fi
    jq -n --argjson p "$3" '{lockfileVersion:3,packages:$p}' > "$r/package-lock.json"
    echo "$r"
}

r=$(resolvedrepo one-major "^4.4.3" '{"node_modules/zod":{"version":"4.5.4"},"packages/app/node_modules/zod":{"version":"4.4.3"}}')
expect "whenResolved: every copy on the required major passes, a range included" "$r" 0 "1 of 1 blessed package(s) apply here"

r=$(resolvedrepo nested-loser "" '{"node_modules/zod":{"version":"4.5.4"},"node_modules/shadcn/node_modules/zod":{"version":"3.25.76"}}')
expect "whenResolved: a nested transitive copy on another major fails, naming it" "$r" 1 "node_modules/shadcn/node_modules/zod is 3.25.76 — the whole tree must resolve zod v4"

r=$(resolvedrepo declared-wrong "^3.23.8" '{"node_modules/zod":{"version":"3.25.76"}}')
expect "whenResolved: a declaration on another major fails" "$r" 1 "packages/app/package.json: zod is \"^3.23.8\" — the kit requires v4 across the tree"

r=$(resolvedrepo absent "" '{}')
expect "whenResolved: a package nowhere in the tree does not apply" "$r" 0 "0 of 1 blessed package(s) apply here"

exit $fail
