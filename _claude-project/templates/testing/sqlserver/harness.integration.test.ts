// The integration harness's own test on SQL Server — the kit's, kept current by
// /sync-dev-kit. It fails loudly if dbTest stops isolating a test from the code it calls.
// `npm run test:preflight` runs it alone, after globalSetup.ts has checked the database.

import { randomUUID } from "node:crypto";
import { sql } from "drizzle-orm";
import { expect } from "vitest";
import { dbTest, type TestDb } from "./integration-helpers";

// A table this run alone creates, inside the first test's transaction. SQL Server rolls
// DDL back with the transaction, so the second test finding no such table proves the
// rollback took the test's writes with it — without touching any table the project owns.
const PROBE = `kit_harness_probe_${randomUUID().replaceAll("-", "")}`;

async function transactionState(db: TestDb): Promise<{ id: string; depth: number }> {
  // raw-sql: CURRENT_TRANSACTION_ID() and @@TRANCOUNT are server functions with no query-builder form.
  const result = await db.execute<{ id: string; depth: number }>(
    sql`SELECT CAST(CURRENT_TRANSACTION_ID() AS varchar(20)) AS id, @@TRANCOUNT AS depth`,
  );
  const [row] = result.recordset;
  if (!row) throw new Error("the transaction-state query returned no row");
  return row;
}

dbTest("each test runs inside one open transaction", async (db) => {
  expect((await transactionState(db)).depth).toBe(1);
});

dbTest("each test reads under snapshot isolation", async (db) => {
  // raw-sql: sys.dm_exec_sessions is a server view, not part of the schema.
  const result = await db.execute<{ level: number }>(
    sql`SELECT transaction_isolation_level AS level FROM sys.dm_exec_sessions WHERE session_id = @@SPID`,
  );
  // 5 is SNAPSHOT.
  expect(result.recordset[0]?.level).toBe(5);
});

dbTest("a lock wait fails after ten seconds instead of hanging", async (db) => {
  // raw-sql: @@LOCK_TIMEOUT is a server function with no query-builder form.
  const result = await db.execute<{ timeout: number }>(sql`SELECT @@LOCK_TIMEOUT AS timeout`);
  expect(result.recordset[0]?.timeout).toBe(10_000);
});

dbTest("a nested db.transaction stays inside the test's transaction", async (db) => {
  const before = await transactionState(db);
  await db.transaction(async (tx) => {
    // raw-sql: a no-op statement, only so the nested transaction does something.
    await tx.execute(sql`SELECT 1`);
  });
  // A nested commit that ended the test's transaction would put this query in a new one,
  // and everything written before it would have persisted.
  expect(await transactionState(db)).toEqual(before);
});

// The two tests below run in order. If the first one's writes survived its rollback, the
// second would find them.
dbTest("a test writes…", async (db) => {
  // raw-sql: the probe is created and filled inside this test's transaction; it is not part of the schema.
  await db.execute(sql.raw(`CREATE TABLE ${PROBE} (id int NOT NULL)`));
  // raw-sql: the probe is not part of the schema.
  await db.execute(sql.raw(`INSERT INTO ${PROBE} (id) VALUES (1)`));
  // raw-sql: the probe is not part of the schema.
  const result = await db.execute<{ n: number }>(sql.raw(`SELECT COUNT(*) AS n FROM ${PROBE}`));
  expect(result.recordset[0]?.n).toBe(1);
});

dbTest("…and the rollback leaves no trace of them", async (db) => {
  // raw-sql: OBJECT_ID is a server function with no query-builder form.
  const result = await db.execute<{ id: number | null }>(sql`SELECT OBJECT_ID(${PROBE}, N'U') AS id`);
  expect(result.recordset[0]?.id).toBeNull();
});
