// Integration-suite branch lifecycle — the kit's, kept current by /sync-dev-kit.
//
// ONE ephemeral Neon branch per RUN (neon.com/branching/ci-preview-workflows): one
// create, one delete, so nothing to rate-limit or orphan. `setup` forks the default
// (production) branch, migrates every database on it once, and sets each database's URL
// BEFORE any worker spawns. Tests run in parallel on the one branch, each in a rolled-back
// transaction (integration-helpers.ts). `teardown` deletes the branch; `expires_at`
// (30 min) is the crash backstop.
//
// Databases beyond the main one, and fixups the fork needs, come from test/project.ts.

import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createApiClient, EndpointType } from "@neondatabase/api-client";
import { drizzle } from "drizzle-orm/node-postgres";
import { migrate } from "drizzle-orm/node-postgres/migrator";
import { Pool } from "pg";
import project from "./project";

// A drizzle config's paths are relative to the folder holding it: the shared module, or
// else the repository root (the nearest folder above holding .claude/sync-substitutions.json).
const sharedModule = fileURLToPath(new URL("..", import.meta.url));
function findRepoRoot(from: string): string {
  for (let dir = from; ; dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".claude/sync-substitutions.json"))) return dir;
    if (dir === dirname(dir)) throw new Error(`globalSetup: no .claude/sync-substitutions.json above ${from}`);
  }
}
const CONFIGS = ["drizzle.config.ts", "drizzle.config.mts", "drizzle.config.js", "drizzle.config.mjs"];
function drizzleConfigFile(): { dir: string; file: string } {
  for (const dir of [sharedModule, findRepoRoot(sharedModule)]) {
    const file = CONFIGS.find((c) => existsSync(resolve(dir, c)));
    if (file) return { dir, file };
  }
  throw new Error(`globalSetup: no drizzle config in ${sharedModule} or the repository root`);
}

let branchId: string | null = null;

/** The one role or database to connect as: the named one, or the only one the branch has. */
function pick(kind: string, named: string | undefined, names: string[]): string {
  if (named) {
    if (!names.includes(named)) throw new Error(`globalSetup: the branch has no ${kind} "${named}" (it has: ${names.join(", ")})`);
    return named;
  }
  const [only] = names;
  if (names.length === 1 && only) return only;
  throw new Error(
    `globalSetup: the branch has ${names.length ? `several ${kind}s (${names.join(", ")})` : `no ${kind}`} — set NEON_${kind.toUpperCase()}_NAME in .env to the one the tests use`,
  );
}

/**
 * Applies a drizzle config's migrations to the test branch, and ONLY to it.
 *
 * The config is read for where its migrations are, never for where to connect: a config
 * reads its connection from whatever variable its project chose (an owner-role URL beside
 * the runtime one, say), and `drizzle-kit migrate` with only `DATABASE_URL` overridden
 * follows that variable to the developer's own database. So the migrations are applied
 * here, by drizzle's own migrator — the one `drizzle-kit migrate` runs — on a connection
 * to the branch this setup created.
 */
async function migrateBranch(dir: string, file: string, label: string, url: string): Promise<void> {
  try {
    const config = (await import(pathToFileURL(resolve(dir, file)).href)).default as {
      dialect?: string;
      out?: string;
      migrations?: { table?: string; schema?: string };
    };
    if (config.dialect !== "postgresql") throw new Error(`${file}: dialect is ${config.dialect}, not postgresql`);
    if (!config.out) throw new Error(`${file}: no \`out\` folder of migrations`);
    const pool = new Pool({ connectionString: url, max: 1 });
    try {
      await migrate(drizzle(pool), {
        migrationsFolder: resolve(dir, config.out),
        migrationsTable: config.migrations?.table,
        migrationsSchema: config.migrations?.schema,
      });
    } finally {
      await pool.end();
    }
  } catch (err) {
    throw new Error(`globalSetup: migrating the ${label} database on the test branch failed`, { cause: err });
  }
}

export async function setup(): Promise<void> {
  const apiKey = process.env.NEON_API_KEY;
  const projectId = process.env.NEON_PROJECT_ID;
  if (!apiKey || !projectId) return;

  const api = createApiClient({ apiKey });
  // expires_at: an absolute-instant safety net, never displayed or filtered by a local
  // boundary — constitution §VI's audit-field carve-out.
  const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
  const { data } = await api.createProjectBranch(projectId, {
    branch: { name: `test/${randomUUID()}`, expires_at: expiresAt },
    endpoints: [{ type: EndpointType.ReadWrite }],
    annotation_value: { "integration-test": "true" },
  });
  branchId = data.branch.id;

  const role = pick("role", process.env.NEON_ROLE_NAME, (data.roles ?? []).map((r) => r.name));
  const database = pick(
    "database",
    process.env.NEON_DATABASE_NAME,
    (data.databases ?? []).map((d) => d.name).filter((n) => !project.extraDatabases?.some((x) => x.database === n)),
  );
  const { data: uriData } = await api.getConnectionUri({
    projectId,
    branch_id: branchId,
    role_name: role,
    database_name: database,
    pooled: true,
  });
  const url = new URL(uriData.uri);
  url.searchParams.set("sslmode", "verify-full");

  // Set BEFORE workers spawn, so every integration worker inherits them.
  const main = url.toString();
  const urls: Record<string, string> = { DATABASE_URL: main };
  const extras = (project.extraDatabases ?? []).map((extra) => {
    const other = new URL(url);
    other.pathname = `/${extra.database}`;
    urls[extra.envVar] = other.toString();
    return { extra, url: other.toString() };
  });
  Object.assign(process.env, urls);

  // The branch forked production, which lacks any migration this change adds; drizzle
  // records what it applied, so this applies exactly the new ones and is otherwise a no-op.
  const { dir, file } = drizzleConfigFile();
  await migrateBranch(dir, file, "main", main);
  for (const { extra, url: extraUrl } of extras) await migrateBranch(dir, extra.drizzleConfig, extra.envVar, extraUrl);

  await project.afterMigrate?.(urls);
}

export async function teardown(): Promise<void> {
  const apiKey = process.env.NEON_API_KEY;
  const projectId = process.env.NEON_PROJECT_ID;
  if (!apiKey || !projectId || !branchId) return;
  const api = createApiClient({ apiKey });
  // Object argument: @neondatabase/api-client 2.7.2 changed the signature, and the old
  // positional call still compiles but deletes /projects/undefined/branches/undefined.
  //
  // A failed delete is not swallowed: it leaves a branch that costs money, and a
  // systematic cause leaks one on every run. expires_at still cleans up; the error is
  // what makes it seen.
  await api.deleteProjectBranch({ projectId, branchId });
  branchId = null;
}
