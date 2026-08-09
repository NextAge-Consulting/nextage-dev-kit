// Integration-suite branch lifecycle — ONE ephemeral Neon branch per RUN
// (Neon's guidance: neon.com/branching/ci-preview-workflows). One create, one
// delete: no per-file branch churn, so no API rate-limiting and nothing to
// orphan. `setup` forks the default (production) branch, migrates it once, and
// points DATABASE_URL at it BEFORE any worker spawns. Integration tests run in
// PARALLEL on this one branch — each runs in a rolled-back transaction (dbTest
// in integration-helpers.ts), so concurrent tests are MVCC-isolated and never
// collide. `teardown` deletes the branch; `expires_at` (30 min) is the crash
// backstop.
import { execSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { createApiClient, EndpointType } from "@neondatabase/api-client";

let branchId: string | null = null;

export async function setup(): Promise<void> {
  const apiKey = process.env.NEON_API_KEY;
  const projectId = process.env.NEON_PROJECT_ID;
  if (!apiKey || !projectId) return;

  const api = createApiClient({ apiKey });
  // expires_at: absolute-instant safety-net timestamp (never displayed / never
  // tz-filtered) — constitution §VI audit-field carve-out.
  const expiresAt = new Date(Date.now() + 30 * 60 * 1000).toISOString();
  const { data } = await api.createProjectBranch(projectId, {
    branch: { name: `test/${randomUUID()}`, expires_at: expiresAt },
    endpoints: [{ type: EndpointType.ReadWrite }],
    annotation_value: { "integration-test": "true" },
  });
  branchId = data.branch.id;

  const role =
    process.env.NEON_ROLE_NAME ??
    data.roles?.find((r) => r.name === "neondb_owner")?.name ??
    data.roles?.[0]?.name;
  const database =
    process.env.NEON_DATABASE_NAME ??
    data.databases?.find((d) => d.name === "neondb")?.name ??
    data.databases?.[0]?.name;
  if (!role || !database) throw new Error("Neon branch has no role/database to connect as");

  const { data: uriData } = await api.getConnectionUri({
    projectId,
    branch_id: branchId,
    role_name: role,
    database_name: database,
    pooled: true,
  });
  const url = new URL(uriData.uri);
  url.searchParams.set("sslmode", "verify-full");
  // Set BEFORE workers spawn so every integration worker inherits it.
  process.env.DATABASE_URL = url.toString();

  // Migrate the branch once. It forked production, which lacks any migration
  // from THIS PR; drizzle tracks applied migrations, so this applies exactly the
  // new one during a migration PR and is a no-op otherwise.
  execSync("npx drizzle-kit migrate", {
    stdio: "inherit",
    env: process.env,
    timeout: 55_000,
    killSignal: "SIGTERM",
  });
}

export async function teardown(): Promise<void> {
  const apiKey = process.env.NEON_API_KEY;
  const projectId = process.env.NEON_PROJECT_ID;
  if (!apiKey || !projectId || !branchId) return;
  const api = createApiClient({ apiKey });
  // Object argument, NOT positional. @neondatabase/api-client changed this
  // signature at 2.7.2 — `deleteProjectBranch(projectId, branchId)` compiles
  // against the old typings but sends DELETE /projects/undefined/branches/
  // undefined, which 404s. Pin `@neondatabase/api-client` to ^2.7.2 or later.
  //
  // The failure is NOT swallowed. A failed delete leaves a live branch that
  // costs money, and if the cause is systematic it leaks one on every run —
  // exactly what a `.catch(() => undefined)` here hid until someone happened to
  // look at the branch list. `expires_at` still cleans up; the noise is the
  // point.
  await api.deleteProjectBranch({ projectId, branchId });
  branchId = null;
}
