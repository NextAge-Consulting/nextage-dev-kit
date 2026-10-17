// Integration-test wiring on SQL Server — the kit's, kept current by /sync-dev-kit
// (sqlserver-drizzle.md §V). The same test-facing shape as the PostgreSQL harness.
//
// Each test runs inside a transaction that is ALWAYS rolled back, on the development
// database globalSetup.ts checked. `dbTest` is the only way a test gets a database handle:
// there is no exported pool or committing handle, so a test cannot write outside a
// rolled-back transaction.
//
// The test receives a drizzle TRANSACTION, so code under test that calls
// `db.transaction(...)` itself gets a savepoint (`save transaction`), not a commit.
//
// The database is shared — with other developers' runs and anything else on it — so a
// test inserts its own rows with invented keys and never relies on existing ones. It reads
// under snapshot isolation, so tests running at once do not block on each other's
// uncommitted rows; a lock wait that does happen fails the test after ten seconds rather
// than hanging it, and a test SQL Server picks as a deadlock victim runs again.

import "./mssql-connection";
import { TransactionRollbackError } from "drizzle-orm/errors";
import { drizzle, type NodeMsSqlDatabase } from "drizzle-orm/node-mssql";
import mssql from "mssql";
import { it } from "vitest";
import project from "./project";

export type TestDb = NodeMsSqlDatabase<typeof project.schema>;

// One handle per worker, reused across the files that worker runs.
let handle: TestDb | undefined;
function database(): TestDb {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set — the integration setup (globalSetup.ts) did not run.");
  handle ??= drizzle(url, { schema: project.schema });
  return handle;
}

/** The `mssql` transaction a drizzle transaction runs on — drizzle keeps it as its session's client. */
function connectionOf(tx: unknown): mssql.Transaction {
  const client = (tx as { session?: { client?: unknown } }).session?.client;
  if (!(client instanceof mssql.Transaction)) {
    throw new Error("integration-helpers: drizzle's transaction no longer exposes its mssql transaction as session.client");
  }
  return client;
}

/** SQL Server's error number on an error or anything it was caused by. */
function serverErrorNumber(error: unknown): number | undefined {
  for (let e: unknown = error; e; e = (e as { cause?: unknown }).cause) {
    const err = e as { number?: number; originalError?: { info?: { number?: number } } };
    const found = err.number ?? err.originalError?.info?.number;
    if (found !== undefined) return found;
  }
  return undefined;
}

/** SQL Server chose this test's transaction as a deadlock victim. */
const DEADLOCK_VICTIM = 1205;

/** A deadlock victim is rolled back whole, so running the test again is safe; this many runs at most. */
const ATTEMPTS = 3;

/**
 * Run `fn` inside a transaction that is ALWAYS rolled back. Pass the `tx` straight into
 * the code under test — a data function takes its connection as a parameter — so its
 * writes ride this transaction and vanish on rollback.
 */
export function dbTest(name: string, fn: (tx: TestDb) => Promise<void>, timeout = 60_000): void {
  it(
    name,
    async () => {
      for (let attempt = 1; ; attempt++) {
        let finished = false;
        // What the test body raised. When a statement fails, drizzle's rollback of the
        // transaction can fail in turn ("Transaction has been aborted") and replace it, so
        // the body's own error is kept here and classified instead.
        let raised: unknown;
        try {
          await database().transaction(
            async (tx) => {
              // A SET sent through drizzle runs inside sp_executesql and reverts when it
              // returns; sent as a batch it holds for the connection, so for this transaction.
              await new mssql.Request(connectionOf(tx)).batch("SET LOCK_TIMEOUT 10000");
              // A transaction has no `$client`; data functions take the database without it,
              // and every query method they call is present on `tx`.
              try {
                await fn(tx as unknown as TestDb);
              } catch (error) {
                raised = error;
                throw error;
              }
              finished = true;
              tx.rollback();
            },
            // Snapshot reads take no shared locks, so tests running at once never wait on
            // each other's uncommitted rows. Only a transaction that asks for it reads this
            // way; every other session on the database keeps its own isolation level.
            { isolationLevel: "snapshot" },
          );
        } catch (error) {
          // Only the harness's own rollback, after the body finished, is a pass. A rollback
          // the code under test raised mid-body is the test's failure.
          if (finished && error instanceof TransactionRollbackError) return;
          if (attempt < ATTEMPTS && serverErrorNumber(raised ?? error) === DEADLOCK_VICTIM) {
            console.warn(`dbTest: "${name}" was chosen as a deadlock victim; running it again (${attempt + 1} of ${ATTEMPTS})`);
            continue;
          }
          throw raised ?? error;
        }
        throw new Error("dbTest: the transaction ended without the harness's rollback");
      }
    },
    timeout,
  );
}
