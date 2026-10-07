// Integration-test wiring — the kit's, kept current by /sync-dev-kit.
//
// Transaction-per-test isolation on the run's one Neon branch (globalSetup.ts creates it).
// Each test runs inside a transaction that is ALWAYS rolled back, so tests run in parallel
// on the shared branch — Postgres MVCC keeps concurrent transactions apart — and nothing
// persists between them.
//
// `dbTest` (and `dbTestOn`, for a database beyond the main one) is the only way a test gets
// a database handle. There is no exported pool or committing handle, so a test cannot
// write outside a rolled-back transaction: the API enforces it.
//
// The test receives a drizzle TRANSACTION, not a plain client, so code under test that calls
// `db.transaction(...)` itself gets a savepoint. On a plain client drizzle would send its own
// BEGIN/COMMIT, and that COMMIT ends the test's transaction and persists its writes.
//
// Code that takes a SESSION-level advisory lock is not released by ROLLBACK: its test
// releases the lock itself, or the code uses a transaction-scoped lock.

import { TransactionRollbackError } from "drizzle-orm/errors";
import { drizzle, type NodePgDatabase } from "drizzle-orm/node-postgres";
import { Pool } from "pg";
import { it } from "vitest";
import project from "./project";

export type TestDb = NodePgDatabase<typeof project.schema>;

// One pool per database per worker, from the URLs globalSetup set, reused across the files
// that worker runs. `max` covers a worker's concurrent test transactions.
const pools = new Map<string, Pool>();
function poolFor(envVar: string): Pool {
  const url = process.env[envVar];
  if (!url) {
    throw new Error(
      `${envVar} is not set — the integration branch (globalSetup.ts) did not initialize. Set NEON_API_KEY and NEON_PROJECT_ID.`,
    );
  }
  let pool = pools.get(envVar);
  if (!pool) {
    pool = new Pool({ connectionString: url, max: 8 });
    pools.set(envVar, pool);
  }
  return pool;
}

function transactionTest<S extends Record<string, unknown>>(envVar: string, schema: S) {
  return (name: string, fn: (tx: NodePgDatabase<S>) => Promise<void>, timeout = 30_000): void => {
    it(
      name,
      async () => {
        const client = await poolFor(envVar).connect();
        let finished = false;
        try {
          await drizzle(client, { schema }).transaction(async (tx) => {
            // A transaction has no `$client`; data functions take the schema-typed database
            // without it, and every query method they call is present on `tx`.
            await fn(tx as unknown as NodePgDatabase<S>);
            finished = true;
            tx.rollback();
          });
        } catch (error) {
          // Only the harness's own rollback, after the body finished, is a pass. A rollback
          // the code under test raised mid-body is the test's failure.
          if (!(finished && error instanceof TransactionRollbackError)) throw error;
        } finally {
          client.release();
        }
      },
      timeout,
    );
  };
}

/**
 * Run `fn` inside a transaction on the main database that is ALWAYS rolled back. Pass the
 * `tx` straight into the code under test — a data function takes its connection as a
 * parameter — so its writes ride this transaction and vanish on rollback.
 */
export const dbTest = transactionTest("DATABASE_URL", project.schema);

/**
 * The same, on a database beyond the main one, named by the variable test/project.ts
 * gives it: `export const auditTest = dbTestOn("AUDIT_DATABASE_URL")` in a helper of the project's.
 */
export function dbTestOn(envVar: string) {
  const extra = project.extraDatabases?.find((d) => d.envVar === envVar);
  if (!extra) throw new Error(`dbTestOn: test/project.ts declares no extra database "${envVar}"`);
  return transactionTest(envVar, extra.schema);
}
