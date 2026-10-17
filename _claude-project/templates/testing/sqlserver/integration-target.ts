// Whether the SQL Server database the integration tests are about to use is one they may
// use — the kit's, kept current by /sync-dev-kit (sqlserver-drizzle.md §V). globalSetup.ts
// runs it before any test connects, and `npm run test:preflight` runs it first in /commit,
// /ship-main and /deploy.
//
// Every refusal says what is wrong and what to do about it, in words a developer who has
// never seen this file can act on.

import { existsSync, readdirSync } from "node:fs";
import { resolve } from "node:path";
import sql from "mssql";
import type { IntegrationDatabase } from "./define";
import { connectionStringFromEnv } from "./mssql-connection";

/** The extended property on a server's `master` database that marks it as a test target. */
export const TEST_TARGET_MARK = "integration_test_target";

/** Where drizzle-kit records the migrations it applied, when a chain names no other table. */
const DEFAULT_MIGRATIONS_TABLE = "drizzle.__drizzle_migrations";

/** A refusal: printed as it reads, with no stack, because the message is the whole point. */
class NotReady extends Error {
  constructor(message: string) {
    super(message);
    this.name = "Integration tests' database not ready";
    this.stack = `${this.name}\n\n${message}`;
  }
}

async function open(connection: string, server: string): Promise<sql.ConnectionPool> {
  try {
    return await new sql.ConnectionPool(connection).connect();
  } catch (error) {
    throw new NotReady(
      `Couldn't connect to the SQL Server at ${server} (DB_SERVER in .env): ${(error as Error).message}\n` +
        "Check that the server is running and that this machine can reach it.",
    );
  }
}

/** The migration folders drizzle-kit wrote, in the order it applies them. */
function localMigrations(folder: string): string[] {
  if (!existsSync(folder)) throw new NotReady(`The migrations folder ${folder} (test/project.ts, integrationDatabase) does not exist.`);
  return readdirSync(folder, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && existsSync(resolve(folder, entry.name, "migration.sql")))
    .map((entry) => entry.name)
    .sort();
}

/** `schema.table` as a bracketed identifier, from text test/project.ts wrote. */
function quoted(table: string): string {
  const parts = table.split(".");
  if (parts.length !== 2 || parts.some((p) => !/^[A-Za-z_][A-Za-z0-9_]*$/.test(p))) {
    throw new NotReady(`The migrations table "${table}" (test/project.ts, integrationDatabase) is not a schema.table name.`);
  }
  return parts.map((p) => `[${p}]`).join(".");
}

/**
 * Checks the database `env`'s `DB_*` keys name, and returns its connection string for the
 * tests. Throws, saying what to do, when the tests may not or cannot use it.
 */
export async function checkIntegrationTarget(
  env: Record<string, string | undefined>,
  target: IntegrationDatabase | undefined,
  repoRoot: string,
): Promise<string> {
  if (!target) {
    throw new NotReady(
      "test/project.ts declares no integrationDatabase: where a developer reads how to set up a development " +
        "database, and the project's migration folders with the command that applies each (test/define.ts).",
    );
  }
  const server = env.DB_SERVER;
  const database = env.DB_DATABASE;
  if (!server || !database || !env.DB_USER || !env.DB_PASSWORD) {
    throw new NotReady(
      "The integration tests need a development SQL Server, and .env does not name one: " +
        "DB_SERVER, DB_DATABASE, DB_USER and DB_PASSWORD must all be set.\n" +
        `How to set one up: ${target.setupDoc}`,
    );
  }

  const master = await open(connectionStringFromEnv({ ...env, DB_DATABASE: "master" }), server);
  try {
    const mark = await master
      .request()
      .input("mark", sql.NVarChar, TEST_TARGET_MARK)
      .query<{ marked: number }>("SELECT COUNT(*) AS marked FROM sys.extended_properties WHERE class = 0 AND name = @mark");
    if (!mark.recordset[0]?.marked) {
      throw new NotReady(
        `${server} isn't set up as a development database for integration tests, so they did not run.\n` +
          "Integration tests write to the database they run against — every write is rolled back — so they run " +
          "only on a SQL Server that has been marked as safe for that: a development or local copy, never one " +
          "holding data anyone needs. If .env points somewhere else for now, point it back at your development " +
          "database.\n" +
          `How to set one up, or mark this one: ${target.setupDoc}`,
      );
    }

    const state = await master
      .request()
      .input("name", sql.NVarChar, database)
      .query<{ state: string; snapshot: string }>(
        "SELECT state_desc AS state, snapshot_isolation_state_desc AS snapshot FROM sys.databases WHERE name = @name",
      );
    const row = state.recordset[0];
    if (!row) {
      throw new NotReady(`${server} has no database named ${database} (DB_DATABASE in .env).\nHow to set one up: ${target.setupDoc}`);
    }
    if (row.state !== "ONLINE") {
      throw new NotReady(
        `${database} on ${server} is ${row.state}, not ONLINE — a restore replacing it keeps it offline until it ` +
          "finishes. Run this again once it is back.",
      );
    }
    if (row.snapshot !== "ON") {
      throw new NotReady(
        `${database} on ${server} does not allow snapshot isolation, which the integration tests read under ` +
          `so they can run at the same time. To allow it:\n  ALTER DATABASE [${database}] SET ALLOW_SNAPSHOT_ISOLATION ON\n` +
          "A restore brings back the source database's setting, so set it again after each one.\n" +
          `How to set up a development database: ${target.setupDoc}`,
      );
    }
  } finally {
    await master.close();
  }

  const connection = connectionStringFromEnv(env);
  const pool = await open(connection, server);
  try {
    for (const chain of target.migrations) {
      const table = chain.table ?? DEFAULT_MIGRATIONS_TABLE;
      const recorded = await pool
        .request()
        .input("table", sql.NVarChar, table)
        .query<{ name: string }>(
          `IF OBJECT_ID(@table, N'U') IS NOT NULL SELECT CAST(name AS nvarchar(400)) AS name FROM ${quoted(table)}`,
        );
      const applied = new Set((recorded.recordset ?? []).map((r) => r.name));
      const missing = localMigrations(resolve(repoRoot, chain.folder)).filter((name) => !applied.has(name));
      if (missing.length > 0) {
        throw new NotReady(
          `${database} on ${server} is missing migrations this branch adds, so the integration tests would run ` +
            `against the wrong schema:\n${missing.map((name) => `  - ${name}`).join("\n")}\n` +
            "Applying them changes that database, so it needs your go-ahead. To apply them:\n" +
            `  ${chain.apply}\n` +
            "A restore brings back the source database's schema, so a migration not yet deployed there needs " +
            "applying again after each one.",
        );
      }
    }
  } finally {
    await pool.close();
  }
  return connection;
}
