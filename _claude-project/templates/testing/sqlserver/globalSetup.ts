// Integration-test setup on SQL Server — the kit's, kept current by /sync-dev-kit
// (sqlserver-drizzle.md §V). There is no per-run copy of the database to create: the
// tests run on the project's development database, every test in a transaction that is
// always rolled back (integration-helpers.ts).
//
// Before any worker spawns it checks that database may be used (integration-target.ts),
// then points DATABASE_URL at it — the one variable the tests connect with. The DB_* keys
// are read from .env into a sandbox and never reach the test process, so code under test
// that builds its own connection fails instead of committing.

import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config } from "dotenv";
import { checkIntegrationTarget } from "./integration-target";
import project from "./project";

function findRepoRoot(from: string): string {
  for (let dir = from; ; dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".claude/sync-substitutions.json"))) return dir;
    if (dir === dirname(dir)) throw new Error(`globalSetup: no .claude/sync-substitutions.json above ${from}`);
  }
}

export async function setup(): Promise<void> {
  const repoRoot = findRepoRoot(fileURLToPath(new URL(".", import.meta.url)));
  const env: Record<string, string> = {};
  config({ path: resolve(repoRoot, ".env"), processEnv: env, quiet: true });
  // CI supplies the keys as its own environment rather than a .env file. They are taken
  // into the sandbox and removed before any worker spawns, so no test sees them there either.
  for (const key of ["DB_SERVER", "DB_PORT", "DB_DATABASE", "DB_USER", "DB_PASSWORD", "DB_ENCRYPT", "DB_TRUST_SERVER_CERTIFICATE"]) {
    const value = process.env[key];
    if (value && !env[key]) env[key] = value;
    delete process.env[key];
  }
  process.env.DATABASE_URL = await checkIntegrationTarget(env, project.integrationDatabase, repoRoot);
}
