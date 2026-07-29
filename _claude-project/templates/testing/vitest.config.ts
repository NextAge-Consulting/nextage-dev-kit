import { resolve } from "node:path";
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
  test: {
    name: "unit",
    root: here,
    environment: "node" as const,
    globals: false,
    include: ["test/**/*.test.ts"],
    exclude: [...configDefaults.exclude, "test/**/*.integration.test.ts"],
    setupFiles: ["test/test-utils.ts"],
  },
};

const integrationProject = {
  test: {
    name: "integration",
    root: here,
    environment: "node" as const,
    globals: false,
    include: ["test/**/*.integration.test.ts"],
    // PARALLEL: every test runs in a rolled-back transaction (dbTest), so
    // concurrent tests on the one shared branch are MVCC-isolated. No serial
    // penalty, no per-file branch churn.
    globalSetup: ["test/globalSetup.ts"],
    setupFiles: ["test/test-utils.ts"],
  },
};

export default defineConfig({
  test: {
    reporters: ["default"],
    projects: hasNeonCreds ? [unitProject, integrationProject] : [unitProject],
  },
});
