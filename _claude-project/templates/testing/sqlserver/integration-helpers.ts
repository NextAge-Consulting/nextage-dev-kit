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
// under snapshot isolation, so a read never waits on another running test's uncommitted
// rows. A write still takes locks: an UPDATE or DELETE of a row another running test wrote,
// or an insert of a key it holds, waits for that test to finish. A lock wait fails the test
// after the lock-wait limit — ten seconds unless test/project.ts's lockTimeoutMs or .env's
// INTEGRATION_LOCK_TIMEOUT_MS sets another — rather than hanging it, and a test SQL Server
// picks as a deadlock victim runs again.

import { TransactionRollbackError } from "drizzle-orm/errors";
import { drizzle, type NodeMsSqlDatabase } from "drizzle-orm/node-mssql";
import mssql from "mssql";
import { inject, it } from "vitest";
import { testPoolConfig } from "./mssql-connection";
import project from "./project";

export type TestDb = NodeMsSqlDatabase<typeof project.schema>;

// One handle per worker, reused across the files that worker runs. A connect that fails is
// not kept, so the next test tries again and reports its own failure.
let handle: Promise<TestDb> | undefined;
function database(): Promise<TestDb> {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set — the integration setup (globalSetup.ts) did not run.");
  handle ??= new mssql.ConnectionPool(testPoolConfig(url))
    .connect()
    .then((pool) => drizzle({ client: pool, schema: project.schema }))
    .catch((error: unknown) => {
      handle = undefined;
      throw new Error(`dbTest: couldn't connect to the integration tests' SQL Server: ${(error as Error).message}`, { cause: error });
    });
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

/** The lock-wait limit vitest.config.ts resolved (test/settings.ts), checked before it reaches SQL. */
function lockTimeoutMs(): number {
  const ms = inject("lockTimeoutMs");
  if (!Number.isSafeInteger(ms) || ms < 1) {
    throw new Error(`integration-helpers: the lock-wait limit vitest.config.ts provides is ${JSON.stringify(ms)}, not a whole number of milliseconds`);
  }
  return ms;
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
          await (await database()).transaction(
            async (tx) => {
              // A SET sent through drizzle runs inside sp_executesql and reverts when it
              // returns; sent as a batch it holds for the connection, so for this transaction.
              await new mssql.Request(connectionOf(tx)).batch(`SET LOCK_TIMEOUT ${lockTimeoutMs()}`);
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
            // Snapshot reads take no shared locks, so a read never waits on another running
            // test's uncommitted rows; writes still lock, and wait on rows another test wrote.
            // Only a transaction that asks for it reads this way; every other session on the
            // database keeps its own isolation level.
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
