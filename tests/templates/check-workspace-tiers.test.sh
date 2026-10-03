#!/usr/bin/env bash
# Regression suite for _claude-project/templates/scripts/check-workspace-tiers.mjs.
#
# Lives outside every synced source directory, so it never reaches a consumer.
# Each case builds a throwaway monorepo, installs the real script at scripts/ as
# sync does (it resolves the repo root from its own location), runs it, and
# asserts the exit code and the line that names the violation.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$KIT/_claude-project/templates/scripts/check-workspace-tiers.mjs"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# A repo with all three package tiers, each holding one clean file.
tiered() {
    local r="$tmp/$1"
    mkdir -p "$r/packages/web/src" "$r/packages/ui/src" "$r/packages/shared/src"
    echo '{"name":"@acme/web"}' > "$r/packages/web/package.json"
    echo '{"name":"@acme/ui","dependencies":{"react":"19"}}' > "$r/packages/ui/package.json"
    echo '{"name":"@acme/shared"}' > "$r/packages/shared/package.json"
    echo 'export const s = 1;' > "$r/packages/shared/src/a.ts"
    echo 'export const u = 1;' > "$r/packages/ui/src/a.ts"
    echo 'export const w = 1;' > "$r/packages/web/src/a.ts"
    echo "$r"
}

# expect <name> <repo> <exit> [pattern the output must contain]
expect() {
    local out code
    mkdir -p "$2/scripts"; cp "$S" "$2/scripts/"
    out=$(node "$2/scripts/check-workspace-tiers.mjs" 2>&1); code=$?
    if [ "$code" -ne "$3" ]; then bad "$1 (exit $code, wanted $3): $out"; return; fi
    if [ -n "${4:-}" ] && ! grep -qF -- "$4" <<<"$out"; then bad "$1 (missing \"$4\"): $out"; return; fi
    ok "$1"
}

r=$(tiered web-own-server)
printf 'export const logFailures = 1;\n' > "$r/packages/web/src/log-failures.server.ts"
printf 'import { logFailures } from "./log-failures.server";\nexport const x = logFailures;\n' > "$r/packages/web/src/fn.ts"
expect "web tier may import its own .server module" "$r" 0 "packages/web is database-free"

r=$(tiered web-own-server-name)
mkdir -p "$r/packages/web/src/serverFn"
printf 'export const logFailures = 1;\n' > "$r/packages/web/src/serverFn/log.server.ts"
printf 'import { logFailures } from "@acme/web/serverFn/log.server";\nimport { a } from "../serverFn/log.server";\nexport const x = [logFailures, a];\n' > "$r/packages/web/src/serverFn/fn.ts"
expect "web tier may reach its own .server module by its package name or a parent path" "$r" 0 "packages/web is database-free"

r=$(tiered web-shared-server-name)
printf 'import { db } from "@acme/shared/db/client.server";\nexport const x = db;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing a server-shared .server module by package name fails" "$r" 1 'web tier imports "@acme/shared/db/client.server", a .server module outside packages/web'

r=$(tiered web-shared-server-relative)
printf 'import { db } from "../../shared/src/db/client.server";\nexport const x = db;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing a server-shared .server module by relative path fails" "$r" 1 'web tier imports "../../shared/src/db/client.server", a .server module outside packages/web'
expect "a relative import into another workspace fails, naming the package" "$r" 1 '"../../shared/src/db/client.server" reaches into packages/shared by relative path — import it by its package name "@acme/shared"'

r=$(tiered web-ui-server)
printf 'import { a } from "@acme/ui/thing.server";\nexport const x = a;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing another workspace's .server module fails" "$r" 1 'web tier imports "@acme/ui/thing.server", a .server module outside packages/web'

r=$(tiered web-driver)
printf 'import { sql } from "drizzle-orm";\nexport const q = sql;\n' > "$r/packages/web/src/db.ts"
expect "web tier importing a driver fails" "$r" 1 'web tier imports database code "drizzle-orm"'

r=$(tiered ui-server-only)
printf 'import { a } from "./thing.server";\nexport const b = a;\n' > "$r/packages/ui/src/c.ts"
expect "ui tier importing a .server module fails" "$r" 1 'ui tier imports server code "./thing.server"'

r=$(tiered ui-own-server)
printf 'export const a = 1;\n' > "$r/packages/ui/src/thing.server.ts"
printf 'import { a } from "@acme/ui/thing.server";\nexport const b = a;\n' > "$r/packages/ui/src/c.ts"
expect "ui tier importing its own .server module by package name fails" "$r" 1 'ui tier imports server code "@acme/ui/thing.server"'

r=$(tiered shared-ui-runtime)
printf 'import { Button } from "@acme/ui/components/button";\nexport const b = Button;\n' > "$r/packages/shared/src/b.ts"
expect "server-shared tier importing the ui tier at runtime fails" "$r" 1 'runtime ui-tier import in the server-shared tier ("@acme/ui/components/button")'

r=$(tiered shared-ui-contract-type)
printf 'import type { Row } from "@acme/ui/contracts/row";\nexport type R = Row;\n' > "$r/packages/shared/src/b.ts"
expect "server-shared tier may type-import the ui tier's contracts" "$r" 0 "packages/shared is browser-free"

r=$(tiered cross-workspace-alias)
mkdir -p "$r/apps/site/src"
echo '{"name":"@acme/site"}' > "$r/apps/site/package.json"
printf '{\n  // comments are allowed\n  "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./src/*"], "@ui/*": ["../../packages/ui/src/*"], }, },\n}\n' > "$r/apps/site/tsconfig.json"
echo 'export const a = 1;' > "$r/apps/site/src/a.ts"
expect "a tsconfig paths alias resolving outside its workspace fails" "$r" 1 'apps/site/tsconfig.json: paths alias "@ui/*" resolves to packages/ui/src, outside apps/site'

r=$(tiered comma-in-string)
mkdir -p "$r/apps/site/src"
echo '{"name":"@acme/site"}' > "$r/apps/site/package.json"
printf '{ "compilerOptions": { "paths": { "@ui, }/*": ["../../packages/ui/src/*"], }, },\n}\n' > "$r/apps/site/tsconfig.json"
echo 'export const a = 1;' > "$r/apps/site/src/a.ts"
expect "a comma and bracket inside a tsconfig string survive parsing" "$r" 1 'paths alias "@ui, }/*" resolves to packages/ui/src'

r=$(tiered root-alias)
echo '{"compilerOptions":{"paths":{"@ui/*":["./packages/ui/src/*"]}}}' > "$r/tsconfig.base.json"
expect "a root tsconfig paths alias landing inside a workspace fails" "$r" 1 'tsconfig.base.json: paths alias "@ui/*" resolves to packages/ui/src, inside packages/ui'

r=$(tiered in-app-alias)
mkdir -p "$r/apps/site/src"
echo '{"name":"@acme/site","dependencies":{"@acme/ui":"*","react":"19"}}' > "$r/apps/site/package.json"
echo '{ "compilerOptions": { "paths": { "@/*": ["./src/*"] } } }' > "$r/apps/site/tsconfig.json"
printf 'import { u } from "@acme/ui/a";\nimport { b } from "@/b";\nexport const a = [u, b];\n' > "$r/apps/site/src/a.ts"
echo 'export const b = 1;' > "$r/apps/site/src/b.ts"
expect "an in-app alias and package-name imports pass" "$r" 0 "workspaces reach each other by package name only"

r=$(tiered unnamed-tier)
echo '{}' > "$r/packages/ui/package.json"
expect "a shared tier without a package name fails" "$r" 1 "packages/ui: no package.json name"

r=$(tiered ui-driver)
printf 'import pg from "pg";\nexport const c = pg;\n' > "$r/packages/ui/src/d.ts"
expect "ui tier importing a driver fails" "$r" 1 'ui tier imports server code "pg"'

r="$tmp/untiered"; mkdir -p "$r/src"; echo 'export const a = 1;' > "$r/src/a.ts"
expect "repo with no tiered workspaces passes, saying so" "$r" 0 "no tiered workspaces detected"

exit $fail
