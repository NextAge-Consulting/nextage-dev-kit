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

import { execFileSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createApiClient, EndpointType } from "@neondatabase/api-client";
import project from "./project";

// drizzle-kit resolves a config's paths from the working directory, so it runs from the
// folder holding the project's drizzle config: the shared module, or else the repository
// root (the nearest folder above holding .claude/sync-substitutions.json).
const sharedModule = fileURLToPath(new URL("..", import.meta.url));
function findRepoRoot(from: string): string {
  for (let dir = from; ; dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".claude/sync-substitutions.json"))) return dir;
    if (dir === dirname(dir)) throw new Error(`globalSetup: no .claude/sync-substitutions.json above ${from}`);
  }
}
function drizzleDir(): string {
  const configs = ["drizzle.config.ts", "drizzle.config.mts", "drizzle.config.js", "drizzle.config.mjs", "drizzle.config.json"];
  for (const dir of [sharedModule, findRepoRoot(sharedModule)]) {
    if (configs.some((c) => existsSync(resolve(dir, c)))) return dir;
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

// drizzle-kit's own entry script, run by this Node: no npx and no shell, so it runs the
// same on Windows, where npx is a batch file a shell-less spawn cannot start.
function drizzleKit(cwd: string): string {
  const main = createRequire(resolve(cwd, "package.json")).resolve("drizzle-kit");
  return resolve(dirname(main), "bin.cjs");
}

function migrate(cwd: string, label: string, url: string, args: string[]): void {
  try {
    execFileSync(process.execPath, [drizzleKit(cwd), "migrate", ...args], {
      cwd,
      stdio: "inherit",
      env: { ...process.env, DATABASE_URL: url },
      timeout: 55_000,
      killSignal: "SIGTERM",
    });
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
  const cwd = drizzleDir();
  migrate(cwd, "main", main, []);
  for (const { extra, url: extraUrl } of extras) migrate(cwd, extra.envVar, extraUrl, ["--config", extra.drizzleConfig]);

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
