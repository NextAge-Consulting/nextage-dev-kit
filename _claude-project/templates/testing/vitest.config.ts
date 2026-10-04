import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadDotenv } from "dotenv";
import { configDefaults, defineConfig } from "vitest/config";

// Resolve paths relative to this config file, not the repo-root CWD.
// Without this, `npm run test` from the repo root reports "No test files
// found" because include globs resolve against process.cwd().
const here = fileURLToPath(new URL(".", import.meta.url));

// Make the Neon creds visible at config-load so the integration gate behaves
// identically locally and in CI. CI injects NEON_* via the workflow `env:`
// block (present in process.env before vitest starts); locally they live in
// the repo-root .env, which is otherwise only read at test RUNTIME by
// test-utils.ts — too late for the config-load check below. Without this,
// hasNeonCreds was always false locally, so the DB suites NEVER ran on a dev
// machine and only surfaced failures on CI. Promote ONLY the NEON_* keys (read
// into a sandbox, not the whole .env) so the rest of production env stays out
// of the test process. DATABASE_URL is NOT promoted — globalSetup.ts sets it per
// run to the branch it creates. CI's own env vars win (the !process.env guard
// never overrides them).
const envSandbox: Record<string, string> = {};
loadDotenv({ path: resolve(here, "../../.env"), processEnv: envSandbox });
for (const key of [
  "NEON_API_KEY",
  "NEON_PROJECT_ID",
  "NEON_DATABASE_NAME",
  "NEON_ROLE_NAME",
]) {
  if (envSandbox[key] && !process.env[key]) process.env[key] = envSandbox[key];
}

// Integration tests require a live Neon connection (NEON_API_KEY +
// NEON_PROJECT_ID). When those creds are absent, exclude the integration
// suites from the run entirely — gating on the actual prerequisite, not on
// who triggered the run. This keeps the unit tests as real signal in EVERY
// context (your PRs, a fork, a fresh clone with no .env, and Dependabot PRs —
// which GitHub deliberately runs without the Actions secret store) while the
// DB-dependent suites only run where they can actually connect. With the creds
// present, nothing changes: integration tests run and the module-scope guard
// in integration-helpers.ts still fails loud on partial/misconfigured creds.
const hasNeonCreds = Boolean(
  process.env.NEON_API_KEY && process.env.NEON_PROJECT_ID,
);

// A test here may import an app's own code, and that code reaches its own files through
// the app's `@/` alias (typescript-rules.md, Workspace Imports). The alias belongs to the
// importing app, so it is resolved per importer: from the `@/*` entry of the nearest
// tsconfig.json above the file doing the import.
const appAlias = new Map<string, string | null>();
function aliasRootFor(importer: string): string | null {
  for (let dir = dirname(importer); dir !== dirname(dir); dir = dirname(dir)) {
    if (appAlias.has(dir)) return appAlias.get(dir) ?? null;
    const tsconfig = resolve(dir, "tsconfig.json");
    if (!existsSync(tsconfig)) continue;
    const target = readFileSync(tsconfig, "utf8").match(/"@\/\*"\s*:\s*\[\s*"([^"]+)\/\*"/)?.[1];
    const root = target ? resolve(dir, target) : null;
    appAlias.set(dir, root);
    return root;
  }
  return null;
}
const appAliases = {
  name: "app-aliases",
  enforce: "pre" as const,
  async resolveId(this: { resolve: (id: string, importer?: string, opts?: object) => Promise<unknown> }, source: string, importer?: string) {
    if (!source.startsWith("@/") || !importer) return null;
    const root = aliasRootFor(importer);
    return root ? this.resolve(resolve(root, source.slice(2)), importer, { skipSelf: true }) : null;
  },
};

// Two projects:
//   • unit        — no DB, fast; runs everywhere.
//   • integration — runs against ONE Neon branch created per run in
//                   globalSetup.ts (Neon's "one branch per test run"): one
//                   create, one delete, so no API rate-limiting and no orphaned
//                   branches. Tests run in PARALLEL — each in a rolled-back
//                   transaction (dbTest), so they're MVCC-isolated on the shared
//                   branch. Present only when creds exist (forks/Dependabot run
//                   unit-only).
const unitProject = {
  // An inline project does not inherit the root's plugins.
  plugins: [appAliases],
  test: {
    name: "unit",
    root: here,
    environment: "node" as const,
    globals: false,
    include: ["test/**/*.test.ts"],
    exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts"],
    // Absolute: a bare "test/…" reads as a package name
    // to any tool that resolves the config (knip reports it unresolved).
    setupFiles: [resolve(here, "test/test-utils.ts")],
  },
};

const integrationProject = {
  plugins: [appAliases],
  test: {
    name: "integration",
    root: here,
    environment: "node" as const,
    globals: false,
    include: ["test/**/*.integration.test.ts"],
    // PARALLEL: every test runs in a rolled-back transaction (dbTest), so
    // concurrent tests on the one shared branch are MVCC-isolated. No serial
    // penalty, no per-file branch churn.
    globalSetup: [resolve(here, "test/globalSetup.ts")],
    setupFiles: [resolve(here, "test/test-utils.ts")],
  },
};

export default defineConfig({
  test: {
    reporters: ["default"],
    projects: hasNeonCreds ? [unitProject, integrationProject] : [unitProject],
  },
});
