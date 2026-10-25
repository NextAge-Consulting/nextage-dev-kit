#!/usr/bin/env bash
# Test suite for _claude-project/templates/scripts/check-integration-coverage.mjs.
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

# A repository whose base commit holds a database client, its tables and a stub drizzle-orm.
repo() {
    local r="$tmp/$1"
    mkdir -p "$r/src/db" "$r/test" "$r/node_modules/drizzle-orm" "$r/.claude"
    printf '{"DB_ENGINE":"%s"}\n' "${2:-PostgreSQL}" > "$r/.claude/sync-substitutions.json"
    echo '{"name":"drizzle-orm","types":"index.d.ts"}' > "$r/node_modules/drizzle-orm/package.json"
    cat > "$r/node_modules/drizzle-orm/index.d.ts" <<'EOF'
export declare class SQL { readonly brand: "sql" }
export declare function sql(strings: TemplateStringsArray, ...values: unknown[]): SQL;
export declare class PgColumn<T extends { columnType: string; data: unknown }> { readonly columnType: T["columnType"]; readonly data: T["data"] }
export declare class PgTable { readonly name: string }
export declare class PgSelect { from(t: PgTable): PgSelect; where(c: SQL | undefined): PgSelect; innerJoin(t: PgTable, on: SQL): PgSelect; leftJoin(t: PgTable, on: SQL): PgSelect; groupBy(...c: unknown[]): PgSelect; having(c: SQL): PgSelect }
export declare class PgInsert { values(v: unknown): PgInsert; onConflictDoUpdate(c: unknown): PgInsert; onConflictDoNothing(): PgInsert }
export declare class PgUpdate { set(v: unknown): PgUpdate; where(c: SQL | undefined): PgUpdate }
export declare class PgDelete { where(c: SQL | undefined): PgDelete }
export declare class PgTransaction { select(f?: unknown): PgSelect; insert(t: PgTable): PgInsert; update(t: PgTable): PgUpdate; delete(t: PgTable): PgDelete; execute(query: SQL): Promise<unknown> }
export declare class NodePgDatabase<T> { schema: T; select(f?: unknown): PgSelect; insert(t: PgTable): PgInsert; update(t: PgTable): PgUpdate; delete(t: PgTable): PgDelete; execute(query: SQL): Promise<unknown>; transaction<R>(fn: (tx: PgTransaction) => Promise<R>): Promise<R> }
export declare function eq(a: unknown, b: unknown): SQL;
export declare function and(...c: (SQL | undefined)[]): SQL | undefined;
export declare function gte(a: unknown, b: unknown): SQL;
export declare function count(c?: unknown): SQL;
EOF
    echo '{"compilerOptions":{"strict":true,"target":"ES2022","module":"ESNext","moduleResolution":"Bundler","noEmit":true,"skipLibCheck":true}}' > "$r/tsconfig.json"
    printf 'node_modules/\n' > "$r/.gitignore"
    cat > "$r/src/db/client.ts" <<'EOF'
import { NodePgDatabase, PgColumn, PgTable } from "drizzle-orm";
type Int = PgColumn<{ columnType: "PgInteger"; data: number }>;
export type Db = NodePgDatabase<Record<string, never>>;
export declare const db: Db;
export declare const orders: PgTable & { id: Int; customerid: Int; placedat: PgColumn<{ columnType: "PgTimestamp"; data: Date }>; dueon: PgColumn<{ columnType: "PgDateString"; data: string }> };
export declare const customers: PgTable & { id: Int };
EOF
    cat > "$r/src/legacy.ts" <<'EOF'
import { and, eq } from "drizzle-orm";
import { type Db, orders } from "./db/client";
export function legacyRead(db: Db, id: number, customer: number) {
  return db.select().from(orders).where(and(eq(orders.id, id), eq(orders.customerid, customer)));
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

# risky <repo> <name> <body> — writes src/<name>.ts: an exported function <name>(db, since).
risky() {
    cat > "$1/src/$2.ts" <<EOF
import { and, count, eq, gte, sql } from "drizzle-orm";
import { type Db, customers, orders } from "./db/client";
export async function $2(db: Db, since: Date) {
  $3
}
EOF
}

# tested <repo> <test file> <name> — a test under test/ that imports src/<name>.ts and calls it.
tested() {
    cat > "$1/test/$2" <<EOF
import { $3 } from "../src/$3";
import type { Db } from "../src/db/client";
declare const tx: Db;
await $3(tx, new Date());
EOF
}

JOINED='return db.select().from(orders).innerJoin(customers, eq(orders.customerid, customers.id));'

r=$(repo thin)
cat > "$r/src/orders.ts" <<'EOF'
import { eq } from "drizzle-orm";
import { type Db, orders } from "./db/client";
export async function readOrder(db: Db, id: number) {
  return db.select().from(orders).where(eq(orders.id, id));
}
export async function addOrder(db: Db, id: number) {
  return db.insert(orders).values({ id });
}
EOF
expect "thin code — a select by key, a plain insert — needs no test" "$r" 0 "2 query the database, 0 in a risky shape"

r=$(repo join); risky "$r" joined "$JOINED"
expect "a join with no test fails, naming the function and the shape" "$r" 1 "src/joined.ts:3  joined — a join, and no happy-path or risk test calls it"

r=$(repo filter); risky "$r" filtered 'return db.select().from(orders).where(and(eq(orders.id, 1), eq(orders.customerid, 2)));'
expect "a filter beyond a single equality is risky" "$r" 1 "filtered — a filter beyond a lookup by key"

r=$(repo aggregate); risky "$r" totals 'return db.select({ n: count() }).from(orders).groupBy(orders.customerid);'
expect "an aggregate is risky" "$r" 1 "totals — an aggregate"

r=$(repo date); risky "$r" recent 'return db.select().from(orders).where(gte(orders.placedat, since));'
expect "a date comparison is risky" "$r" 1 "a date comparison"

r=$(repo date-column); risky "$r" due 'return db.select().from(orders).where(gte(orders.dueon, "2026-01-01"));'
expect "a comparison on a date column holding strings is a date comparison" "$r" 1 "due — a filter beyond a lookup by key, a date comparison"

r=$(repo number-compare); risky "$r" big 'return db.select().from(orders).where(gte(orders.id, 10));'
expect "a comparison on a number is a filter, not a date comparison" "$r" 1 "big — a filter beyond a lookup by key, and no"

r=$(repo upsert); risky "$r" saved 'return db.insert(orders).values({ id: 1 }).onConflictDoNothing();'
expect "an upsert is risky" "$r" 1 "saved — an upsert"

r=$(repo transaction); risky "$r" moved 'return db.transaction(async (tx) => tx.select());'
expect "a transaction is risky" "$r" 1 "moved — a transaction"

r=$(repo writes); risky "$r" swapped 'await db.delete(orders).where(eq(orders.id, 1)); await db.insert(orders).values({ id: 2 });'
expect "more than one write is risky" "$r" 1 "swapped — more than one write"

r=$(repo raw-template); risky "$r" late 'return db.select().from(orders).where(sql`placedat < now()`);'
expect "a sql template is raw SQL" "$r" 1 "raw SQL, and no happy-path or risk test calls it"

r=$(repo risk-tested); risky "$r" joined "$JOINED"; tested "$r" joined.integration.test.ts joined
expect "a risk test calling it passes" "$r" 0 "1 in a risky shape — 1 called by a happy-path or risk test"

r=$(repo happy-tested); risky "$r" joined "$JOINED"; tested "$r" joined.happy.integration.test.ts joined
expect "a happy-path test calling it passes" "$r" 0 "1 called by a happy-path or risk test"

r=$(repo dev-only); risky "$r" joined "$JOINED"; tested "$r" joined.dev.integration.test.ts joined
expect "a development test alone does not cover it" "$r" 1 "only a development test calls it"

r=$(repo imported-handle)
cat > "$r/src/orders.ts" <<'EOF'
import { count } from "drizzle-orm";
import { db, orders } from "./db/client";
export const countOrders = async () => db.select({ n: count() }).from(orders);
EOF
expect "an imported handle counts, in an exported const arrow function" "$r" 1 "countOrders — an aggregate"

r=$(repo wrapper)
cat > "$r/src/orders.ts" <<'EOF'
import { db } from "./db/client";
import { legacyRead } from "./legacy";
export function getOrders() {
  return legacyRead(db, 1, 2);
}
EOF
expect "a wrapper that only passes the handle along is not judged" "$r" 0 "0 query the database"

r=$(repo fragment)
cat > "$r/src/where.ts" <<'EOF'
import { eq, sql } from "drizzle-orm";
export const byId = (id: number) => eq(sql`id`, id);
EOF
expect "building a SQL fragment is not a query" "$r" 0 "0 query the database"

r=$(repo untouched)
cat > "$r/src/other.ts" <<'EOF'
export const plain = (n: number) => n + 1;
EOF
expect "an untouched untested function is not judged" "$r" 0 "1 changed exported function(s) in 1 changed file(s)"
expect "--report-untested counts it" "$r" 0 "untouched code — 1 exported function(s) query the database in a risky shape" --report-untested

r=$(repo edit-legacy)
sed -i.bak 's/customer)));/customer))); \/\/ edited/' "$r/src/legacy.ts" && rm "$r/src/legacy.ts.bak"
expect "editing an untested risky function requires its test" "$r" 1 "legacyRead — a filter beyond a lookup by key, and no happy-path or risk test calls it"

r=$(repo no-app-code)
cat > "$r/test/copy.integration.test.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "../src/db/client";
declare const tx: Db;
await tx.execute(sql`insert into orders (id) values (1) on conflict do nothing`);
EOF
expect "a test importing nothing from app source fails, naming the file" "$r" 1 "test/copy.integration.test.ts — imports nothing from the app's source"

r=$(repo harness)
cat > "$r/test/harness.integration.test.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "../src/db/client";
declare const tx: Db;
await tx.execute(sql`select 1`);
EOF
expect "the kit's harness test is not judged for app code" "$r" 0 "nothing to judge"

r=$(repo raw-sql)
cat > "$r/src/report.ts" <<'EOF'
import { sql } from "drizzle-orm";
import type { Db } from "./db/client";
export async function report(db: Db) {
  return db.execute(sql`select 1`);
}
EOF
tested "$r" report.integration.test.ts report
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
// raw-sql: recursive CTE over the category tree
export const report = async (db: Db) => db.execute(sql`select 1`);
EOF
tested "$r" report.integration.test.ts report
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
expect "nothing changed says so" "$r" 0 "no TypeScript source or integration test changed"

r="$tmp/no-ts"; mkdir -p "$r/.claude"; echo '{"DB_ENGINE":"PostgreSQL"}' > "$r/.claude/sync-substitutions.json"
git -C "$r" init -q -b main; echo x > "$r/a.md"; git -C "$r" add -A; git -C "$r" -c user.email=a@example.com -c user.name=a commit -qm base
expect "a repository with no TypeScript does not apply" "$r" 0 "the repository has no TypeScript source"

r=$(repo bad-base)
mkdir -p "$r/scripts"; cp "$S" "$r/scripts/"
out=$(cd "$r" && node scripts/check-integration-coverage.mjs --base nope 2>&1); code=$?
if [ "$code" -eq 2 ] && grep -qF "nope: not a commit" <<<"$out"; then ok "an unknown base cannot run"; else bad "an unknown base cannot run (exit $code): $out"; fi

exit $fail
