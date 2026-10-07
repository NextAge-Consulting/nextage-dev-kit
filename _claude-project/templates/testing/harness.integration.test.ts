// The integration harness's own test — the kit's, kept current by /sync-dev-kit. It fails
// loudly if dbTest stops isolating a test from the code it calls.

import { sql } from "drizzle-orm";
import { expect } from "vitest";
import { dbTest, type TestDb } from "./integration-helpers";

async function transactionId(db: TestDb): Promise<string> {
  const result = await db.execute<{ id: string }>(sql`select txid_current()::text as id`);
  const [row] = result.rows;
  if (!row) throw new Error("txid_current() returned no row");
  return row.id;
}

dbTest("a nested db.transaction stays inside the test's transaction", async (db) => {
  const before = await transactionId(db);
  await db.transaction(async (tx) => {
    await tx.execute(sql`select 1`);
  });
  // A nested commit that ended the test's transaction would put this query in a new one,
  // and everything written before it would have persisted.
  expect(await transactionId(db)).toBe(before);
});
