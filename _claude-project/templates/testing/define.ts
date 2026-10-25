// The contract between the kit's test files and this project's test/project.ts.
//
// Every file in this directory except project.ts is the kit's, kept current by
// /sync-dev-kit. What differs between projects lives in project.ts, as the settings
// below; a project's own helpers live in files of its own beside it.

import type { TestProjectInlineConfiguration } from "vitest/config";

/** SQL Server: the development database the integration tests check before they run. */
export type IntegrationDatabase = {
  /** Where a developer reads how to set up and mark a development database, from the repository root. */
  setupDoc: string;
  /**
   * Each migration chain: the folder drizzle-kit writes, the command that applies it, and
   * the table its applied migrations are recorded in when not drizzle.__drizzle_migrations.
   */
  migrations: { folder: string; apply: string; table?: string }[];
};

/** PostgreSQL: a database beyond the main one, created on the same integration branch. */
export type ExtraDatabase = {
  /** The variable the run sets to this database's URL on the branch, e.g. "AUDIT_DATABASE_URL". */
  envVar: string;
  /** The database's name on the Neon branch. */
  database: string;
  /** The drizzle-kit config that migrates it, from the folder holding the main drizzle config, e.g. "drizzle.audit.config.ts". */
  drizzleConfig: string;
  /** Its Drizzle schema, which dbTestOn's handle is typed and built with. */
  schema: Record<string, unknown>;
};

export type TestProject = {
  /** The IANA zone every test runs in: the zone the project stores and shows time in (constitution §VI). */
  timezone: string;
  /** The main database's Drizzle schema, which dbTest's handle is typed and built with. */
  schema: Record<string, unknown>;
  /** Unit test files, as globs from the repository root. Default: the shared module's test/**\/*.test.ts. */
  unitInclude?: string[];
  /** Files kept out of the unit run, as globs from the repository root, beside the integration tests. */
  unitExclude?: string[];
  /** Integration test files, as globs from the repository root. Default: the shared module's test/**\/*.integration.test.ts. */
  integrationInclude?: string[];
  /**
   * How many integration test files run at once. The work waits on the database, not the
   * CPU, so the ceiling is what the database can serve: raise it while the suite stays
   * green, lower it when queries start timing out. Default: the CPU count, at least 8.
   * A developer's .env overrides it with INTEGRATION_WORKERS.
   */
  integrationWorkers?: number;
  /**
   * SQL Server: how long, in milliseconds, a test waits on a lock another running test holds
   * before it fails rather than hanging. Default: 10000. A developer's .env overrides it with
   * INTEGRATION_LOCK_TIMEOUT_MS.
   */
  lockTimeoutMs?: number;
  /** Further vitest projects, run beside unit and integration: a UI package with its own environment. */
  vitestProjects?: TestProjectInlineConfiguration[];
  /** .env keys the tests may read beyond the NEON_* keys and TZ, which are always allowed. */
  envKeys?: string[];
  /** SQL Server: the development database's setup doc and migration chains. Required for the integration tier there. */
  integrationDatabase?: IntegrationDatabase;
  /** PostgreSQL: databases beyond the main one on the integration branch. */
  extraDatabases?: ExtraDatabase[];
  /**
   * PostgreSQL: runs once after every database on the branch is migrated, given each URL
   * by its variable name: for what a fork of production needs before tests (keys
   * production encrypted under a secret the tests do not have).
   */
  afterMigrate?: (urls: Record<string, string>) => Promise<void>;
  /** The roles a test user may hold, and the one mockAuthedUser gives by default. */
  roles?: { all: readonly string[]; default: string };
};

// The values vitest.config.ts resolves (settings.ts) and hands every worker, read there
// with vitest's inject().
declare module "vitest" {
  export interface ProvidedContext {
    /** SQL Server: the lock-wait limit each test's transaction sets, in milliseconds. */
    lockTimeoutMs: number;
  }
}

/** The project's settings, typed as written (its roles stay literal) and as the full contract. */
export function defineTestProject<const T extends TestProject>(project: T): T & TestProject {
  return project;
}
