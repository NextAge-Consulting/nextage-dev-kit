#!/usr/bin/env bash
# Regression suite for _claude-project/templates/scripts/check-integration-coverage.mjs.
#
# Lives outside every synced source directory, so it never reaches a consumer.
# Each case builds a throwaway git repository with a stub drizzle-orm type package,
# commits a base, changes something, installs the real script at scripts/ as sync
# does, and asserts the exit code and a line of the output. TypeScript comes from
# the global npm root, as it does in a project that has not installed it.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$KIT/_claude-project/templates/scripts/check-integration-coverage.mjs"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# A repository whose base commit holds a database client and a stub drizzle-orm.
repo() {
    local r="$tmp/$1"
    mkdir -p "$r/src/db" "$r/test" "$r/node_modules/drizzle-orm" "$r/.claude"
    printf '{"DB_ENGINE":"%s"}\n' "${2:-PostgreSQL}" > "$r/.claude/sync-substitutions.json"
    echo '{"name":"drizzle-orm","types":"index.d.ts"}' > "$r/node_modules/drizzle-orm/package.json"
    cat > "$r/node_modules/drizzle-orm/index.d.ts" <<'EOF'
export declare class SQL { readonly brand: "sql" }
export declare function sql(strings: TemplateStringsArray, ...values: unknown[]): SQL;
export declare class PgTable { readonly name: string }
export declare class PgTransaction { select(): unknown[]; execute(query: SQL): Promise<unknown> }
export declare class NodePgDatabase<T> { schema: T; select(): unknown[]; execute(query: SQL): Promise<unknown>; transaction<R>(fn: (tx: PgTransaction) => Promise<R>): Promise<R> }
export declare function eq(a: unknown, b: unknown): SQL;
EOF
    echo '{"compilerOptions":{"strict":true,"target":"ES2022","module":"ESNext","moduleResolution":"Bundler","noEmit":true,"skipLibCheck":true}}' > "$r/tsconfig.json"
    printf 'node_modules/\n' > "$r/.gitignore"
    cat > "$r/src/db/client.ts" <<'EOF'
import { NodePgDatabase } from "drizzle-orm";
export type Db = NodePgDatabase<Record<string, never>>;
export declare const db: Db;
EOF
    cat > "$r/src/legacy.ts" <<'EOF'
import type { Db } from "./db/client";
export function legacyRead(db: Db) {
  return db.select();
}
EOF
    git -C "$r" init -q -b main
    git -C "$r" -c user.email=a@example.com -c user.name=a add -A
    git -C "$r" -c user.email=a@example.com -c user.name=a commit -qm base
    echo "$r"
}

# expect <name> <repo> <exit> <pattern the output must contain> [script args…]
expect() {
    local name="$1" r="$2" want="$3" pat="$4" out code
    shift 4
    mkdir -p "$r/scripts"; cp "$S" "$r/scripts/"
    out=$(cd "$r" && node scripts/check-integration-coverage.mjs --base main "$@" 2>&1); code=$?
    if [ "$code" -ne "$want" ]; then bad "$name (exit $code, wanted $want): $out"; return; fi
    if ! grep -qF -- "$pat" <<<"$out"; then bad "$name (missing \"$pat\"): $out"; return; fi
    ok "$name"
}

r=$(repo untested)
cat > "$r/src/orders.ts" <<'EOF'
import type { Db } from "./db/client";
export async function readOrders(db: Db) {
  return db.select();
}
EOF
expect "a new function that queries a handle parameter, with no test, fails" "$r" 1 "src/orders.ts:2  readOrders — queries the database and no integration test calls it"

r=$(repo tested)
cat > "$r/src/orders.ts" <<'EOF'
import type { Db } from "./db/client";
export async function readOrders(db: Db) {
  return db.select();
}
EOF
cat > "$r/test/orders.integration.test.ts" <<'EOF'
import { readOrders } from "../src/orders";
import type { Db } from "../src/db/client";
declare const tx: Db;
await readOrders(tx);
EOF
expect "an integration test calling it passes" "$r" 0 "1 query the database — 1 called by an integration test"

r=$(repo imported-handle)
cat > "$r/src/orders.ts" <<'EOF'
import { db } from "./db/client";
export const countOrders = async () => db.select().length;
EOF
expect "an imported handle counts, in an exported const arrow function" "$r" 1 "countOrders — queries the database"

r=$(repo transaction)
cat > "$r/src/orders.ts" <<'EOF'
import type { PgTransaction } from "drizzle-orm";
export function inTx(tx: PgTransaction) {
  return tx.select();
}
EOF
expect "a transaction handle counts" "$r" 1 "inTx — queries the database"

r=$(repo wrapper)
cat > "$r/src/orders.ts" <<'EOF'
import { db } from "./db/client";
import { legacyRead } from "./legacy";
export function getOrders() {
  return legacyRead(db);
}
EOF
expect "a wrapper that only passes the handle along is not judged" "$r" 0 "0 query the database"

r=$(repo fragment)
cat > "$r/src/where.ts" <<'EOF'
import { eq, sql } from "drizzle-orm";
export const byId = (id: number) => eq(sql`id`, id);
EOF
expect "building a SQL fragment is not a query" "$r" 0 "0 query the database"

r=$(repo exempt)
cat > "$r/src/orders.ts" <<'EOF'
import type { Db } from "./db/client";
// integration-exempt: reads a view the test database does not carry
export function readView(db: Db) {
  return db.select();
}
EOF
expect "integration-exempt with a reason passes" "$r" 0 "1 exempt"

r=$(repo exempt-empty)
cat > "$r/src/orders.ts" <<'EOF'
import type { Db } from "./db/client";
// integration-exempt:
export function readView(db: Db) {
  return db.select();
}
EOF
expect "integration-exempt with no reason fails" "$r" 1 "readView — \`integration-exempt:\` gives no reason"

r=$(repo untouched)
cat > "$r/src/other.ts" <<'EOF'
export const plain = (n: number) => n + 1;
EOF
expect "an untouched untested function is not judged" "$r" 0 "1 changed exported function(s) in 1 changed file(s)"
expect "--report-untested counts it" "$r" 0 "untouched code — 1 exported function(s) query the database" --report-untested

r=$(repo edit-legacy)
printf '\n// touched\n' >> "$r/src/legacy.ts"
sed -i.bak 's/return db.select();/return db.select(); \/\/ edited/' "$r/src/legacy.ts" && rm "$r/src/legacy.ts.bak"
git -C "$r" add -A
expect "editing an untested function requires its test" "$r" 1 "legacyRead — queries the database and no integration test calls it"

r=$(repo raw-sql)
cat > "$r/src/report.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "./db/client";
export async function report(db: Db) {
  return db.execute(sql`select 1`);
}
EOF
cat > "$r/test/report.integration.test.ts" <<'EOF'
import { report } from "../src/report";
import type { Db } from "../src/db/client";
declare const tx: Db;
await report(tx);
EOF
expect "db.execute with no raw-sql reason fails" "$r" 1 "src/report.ts:4  report — a whole query through .execute() with no reason"

r=$(repo raw-sql-reason)
cat > "$r/src/report.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "./db/client";
export async function report(db: Db) {
  // raw-sql: recursive CTE over the category tree
  return db.execute(sql`select 1`);
}
EOF
cat > "$r/test/report.integration.test.ts" <<'EOF'
import * as reports from "../src/report";
import type { Db } from "../src/db/client";
declare const tx: Db;
await reports.report(tx);
EOF
expect "db.execute with a raw-sql reason passes, and a namespace call counts" "$r" 0 "1 changed .execute() call(s)"

r=$(repo raw-sql-line-above)
cat > "$r/src/report.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "./db/client";
// integration-exempt: covered by the reporting suite
// raw-sql: recursive CTE over the category tree
export const report = async (db: Db) => db.execute(sql`select 1`);
EOF
expect "a raw-sql reason on the line above a one-line function counts" "$r" 0 "1 changed .execute() call(s)"

r=$(repo sql-templates)
cat > "$r/src/where.ts" <<'EOF'
import { sql } from "drizzle-orm";
export const late = sql`invoice.due < now()`;
EOF
expect "--sql-templates lists a changed sql template" "$r" 0 '"text": "sql`invoice.due < now()`"' --sql-templates

r=$(repo no-db None)
echo 'export const x = 1;' > "$r/src/x.ts"
expect "DB_ENGINE None does not apply" "$r" 0 "does not apply — DB_ENGINE is None"

r=$(repo nothing-changed)
expect "nothing changed says so" "$r" 0 "no TypeScript source changed"

r="$tmp/no-ts"; mkdir -p "$r/.claude"; echo '{"DB_ENGINE":"PostgreSQL"}' > "$r/.claude/sync-substitutions.json"
git -C "$r" init -q -b main; echo x > "$r/a.md"; git -C "$r" add -A; git -C "$r" -c user.email=a@example.com -c user.name=a commit -qm base
expect "a repository with no TypeScript does not apply" "$r" 0 "the repository has no TypeScript source"

r=$(repo bad-base)
mkdir -p "$r/scripts"; cp "$S" "$r/scripts/"
out=$(cd "$r" && node scripts/check-integration-coverage.mjs --base nope 2>&1); code=$?
if [ "$code" -eq 2 ] && grep -qF "nope: not a commit" <<<"$out"; then ok "an unknown base cannot run"; else bad "an unknown base cannot run (exit $code): $out"; fi

exit $fail
