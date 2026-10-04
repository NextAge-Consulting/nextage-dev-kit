// The contract between the kit's test files and this project's test/project.ts.
//
// Every file in this directory except project.ts is the kit's, kept current by
// /sync-dev-kit. What differs between projects lives in project.ts, as the settings
// below; a project's own helpers live in files of its own beside it.

import type { TestProjectInlineConfiguration } from "vitest/config";

/** A database beyond the main one, created on the same integration branch. */
export type ExtraDatabase = {
  /** The variable the run sets to this database's URL on the branch, e.g. "AUDIT_DATABASE_URL". */
  envVar: string;
  /** The database's name on the Neon branch. */
  database: string;
  /** The drizzle-kit config that migrates it, from the shared module, e.g. "drizzle.audit.config.ts". */
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
  /** Further vitest projects, run beside unit and integration: a UI package with its own environment. */
  vitestProjects?: TestProjectInlineConfiguration[];
  /** .env keys the tests may read beyond the NEON_* keys and TZ, which are always allowed. */
  envKeys?: string[];
  /** Databases beyond the main one on the integration branch. */
  extraDatabases?: ExtraDatabase[];
  /**
   * Runs once after every database on the branch is migrated, given each URL by its
   * variable name: for what a fork of production needs before tests (keys production
   * encrypted under a secret the tests do not have).
   */
  afterMigrate?: (urls: Record<string, string>) => Promise<void>;
  /** The roles a test user may hold, and the one mockAuthedUser gives by default. */
  roles?: { all: readonly string[]; default: string };
};

/** The project's settings, typed as written (its roles stay literal) and as the full contract. */
export function defineTestProject<const T extends TestProject>(project: T): T & TestProject {
  return project;
}
