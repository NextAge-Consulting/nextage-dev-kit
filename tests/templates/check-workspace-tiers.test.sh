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
    echo '{"name":"@web/app"}' > "$r/packages/web/package.json"
    echo '{"name":"@ui/kit","dependencies":{"react":"19"}}' > "$r/packages/ui/package.json"
    echo '{"name":"@shared/core"}' > "$r/packages/shared/package.json"
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

r=$(tiered web-own-server-alias)
mkdir -p "$r/packages/web/src/serverFn"
printf 'export const logFailures = 1;\n' > "$r/packages/web/src/serverFn/log.server.ts"
printf 'import { logFailures } from "@web/serverFn/log.server";\nimport { a } from "../serverFn/log.server";\nexport const x = [logFailures, a];\n' > "$r/packages/web/src/serverFn/fn.ts"
expect "web tier may reach its own .server module by its alias or a parent path" "$r" 0 "packages/web is database-free"

r=$(tiered web-shared-server-alias)
printf 'import { db } from "@shared/db/client.server";\nexport const x = db;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing a server-shared .server module by alias fails" "$r" 1 'web tier imports "@shared/db/client.server", a .server module outside packages/web'

r=$(tiered web-shared-server-relative)
printf 'import { db } from "../../shared/src/db/client.server";\nexport const x = db;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing a server-shared .server module by relative path fails" "$r" 1 'web tier imports "../../shared/src/db/client.server", a .server module outside packages/web'

r=$(tiered web-ui-server)
printf 'import { a } from "@ui/thing.server";\nexport const x = a;\n' > "$r/packages/web/src/fn.ts"
expect "web tier importing another workspace's .server module fails" "$r" 1 'web tier imports "@ui/thing.server", a .server module outside packages/web'

r=$(tiered web-driver)
printf 'import { sql } from "drizzle-orm";\nexport const q = sql;\n' > "$r/packages/web/src/db.ts"
expect "web tier importing a driver fails" "$r" 1 'web tier imports database code "drizzle-orm"'

r=$(tiered ui-server-only)
printf 'import { a } from "./thing.server";\nexport const b = a;\n' > "$r/packages/ui/src/c.ts"
expect "ui tier importing a .server module fails" "$r" 1 'ui tier imports server code "./thing.server"'

r=$(tiered ui-own-server)
printf 'export const a = 1;\n' > "$r/packages/ui/src/thing.server.ts"
printf 'import { a } from "@ui/thing.server";\nexport const b = a;\n' > "$r/packages/ui/src/c.ts"
expect "ui tier importing its own .server module by alias fails" "$r" 1 'ui tier imports server code "@ui/thing.server"'

r=$(tiered ui-driver)
printf 'import pg from "pg";\nexport const c = pg;\n' > "$r/packages/ui/src/d.ts"
expect "ui tier importing a driver fails" "$r" 1 'ui tier imports server code "pg"'

r="$tmp/untiered"; mkdir -p "$r/src"; echo 'export const a = 1;' > "$r/src/a.ts"
expect "repo with no tiered workspaces passes, saying so" "$r" 0 "no tiered workspaces detected"

exit $fail
