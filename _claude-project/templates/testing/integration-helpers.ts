// Integration-test wiring — transaction-per-test isolation on the RUN's shared
// Neon branch.
//
// The branch is created ONCE per run in globalSetup.ts (Neon's "one branch per
// test run") — one create, one delete: no per-file branch churn, no rate
// limiting, nothing to orphan. Tests run in PARALLEL on that one branch because
// each test runs inside its own transaction that is ALWAYS rolled back —
// Postgres MVCC isolates concurrent transactions, so no two tests can see or
// clobber each other's writes, and nothing persists between tests.
//
// `dbTest` is the ONLY way to get a DB handle in a test. There is no exported
// pool or committing `db`, so a test physically cannot write outside a
// rolled-back transaction — isolation is enforced by the API, not by discipline.
//
// Carve-out: code that takes a SESSION-level advisory lock (the worker reaper)
// won't release it on ROLLBACK. Such a test must release its own lock or use a
// transaction-scoped lock; see requestReaper's suite.

import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import { it } from "vitest";
import * as schema from "../src/db/schema";

export type TestDb = NodePgDatabase<typeof schema>;

// One pool per worker (from globalSetup's DATABASE_URL), reused across the
// files that worker runs. `max` covers a worker's concurrent test transactions.
let pool: Pool | null = null;
function getPool(): Pool {
  if (!process.env.DATABASE_URL) {
    throw new Error(
      "DATABASE_URL not set — the integration branch (globalSetup.ts) did not initialize. Ensure NEON_API_KEY + NEON_PROJECT_ID are set.",
    );
  }
  if (!pool) pool = new Pool({ connectionString: process.env.DATABASE_URL, max: 8 });
  return pool;
}

/**
 * Run `fn` inside a transaction that is ALWAYS rolled back. Pass the provided
 * `tx` straight into the code under test (every ingest/pricing/device fn takes
 * `db` as a parameter, so its writes ride this transaction and vanish on
 * rollback). This is the ONLY DB entry point for integration tests.
 */
export function dbTest(
  name: string,
  fn: (tx: TestDb) => Promise<void>,
  timeout = 30_000,
): void {
  it(
    name,
    async () => {
      const client = await getPool().connect();
      await client.query("BEGIN");
      try {
        await fn(drizzle(client, { schema }));
      } finally {
        await client.query("ROLLBACK");
        client.release();
      }
    },
    timeout,
  );
}
