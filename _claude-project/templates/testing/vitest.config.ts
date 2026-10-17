// The shared vitest configuration — the kit's, kept current by /sync-dev-kit. What
// differs between projects is read from test/project.ts (test/define.ts describes it).
//
// Run it from the repository root: `vitest run -c <shared module>/vitest.config.ts`.

import { existsSync, readFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadDotenv } from "dotenv";
import { runnerImport } from "vite";
import { configDefaults, defineConfig, type Plugin } from "vitest/config";
import type { TestProject } from "./test/define.ts";

// This file's folder is the shared module; the repository root is the nearest folder
// above it holding .claude/sync-substitutions.json, wherever the module sits.
const here = fileURLToPath(new URL(".", import.meta.url));
function findRepoRoot(from: string): string {
  for (let dir = from; ; dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".claude/sync-substitutions.json"))) return dir;
    if (dir === dirname(dir)) throw new Error(`vitest.config.ts: no .claude/sync-substitutions.json above ${from}`);
  }
}
const repoRoot = findRepoRoot(here);
const shared = relative(repoRoot, here) || ".";
const inShared = (glob: string) => (shared === "." ? glob : `${shared}/${glob}`);

// The Neon credentials decide at load time whether the integration project exists, so
// they are read here as well as by the tests. CI puts them in process.env; locally they
// live in the repository's .env. Only the NEON_* keys are promoted, from a sandbox, and
// CI's own values win. DATABASE_URL is never promoted: globalSetup.ts sets it per run to
// the branch it creates.
const envSandbox: Record<string, string> = {};
loadDotenv({ path: resolve(repoRoot, ".env"), processEnv: envSandbox, quiet: true });
for (const key of ["NEON_API_KEY", "NEON_PROJECT_ID", "NEON_DATABASE_NAME", "NEON_ROLE_NAME"]) {
  if (envSandbox[key] && !process.env[key]) process.env[key] = envSandbox[key];
}
// The integration tier is per engine: /sync-dev-kit ships the DB_ENGINE's globalSetup.ts
// and integration-helpers.ts. On PostgreSQL it needs a live Neon project; without one (a
// fork, a fresh clone, a Dependabot PR) only the unit tests run, and they stay real signal
// everywhere. On SQL Server it always runs, so globalSetup.ts's checks say what is missing
// — except in CI when INTEGRATION_CI_OFF declares CI cannot reach the database.
const settings = JSON.parse(readFileSync(resolve(repoRoot, ".claude/sync-substitutions.json"), "utf8"));
const dbEngine = settings.DB_ENGINE;
const runsIntegration =
  (dbEngine === "PostgreSQL" && Boolean(process.env.NEON_API_KEY && process.env.NEON_PROJECT_ID)) ||
  (dbEngine === "SQLServer" && !(process.env.CI && settings.INTEGRATION_CI_OFF));

// A test may import an app's own code, which reaches its own files through the app's
// `@/` alias (typescript-rules.md, Workspace Imports). The alias belongs to the importing
// app, so it is resolved per importer, from the `@/*` entry of the nearest tsconfig.json
// above the importing file.
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
const appAliases: Plugin = {
  name: "app-aliases",
  enforce: "pre",
  async resolveId(source, importer) {
    if (!source.startsWith("@/") || !importer) return null;
    const root = aliasRootFor(importer);
    return root ? this.resolve(resolve(root, source.slice(2)), importer, { skipSelf: true }) : null;
  },
};

// test/project.ts is loaded through Vite's module runner, not imported: the project's
// settings import its own code (the schema), and a static import would pull that whole
// graph into the bundled config, where Vite 8 flags every extensionless import in it.
export default defineConfig(async () => {
  const project = (await runnerImport<{ default: TestProject }>(resolve(here, "test/project.ts"))).module.default;

  const integrationInclude = project.integrationInclude ?? [inShared("test/**/*.integration.test.ts")];
  const setupFiles = [resolve(here, "test/test-utils.ts")];

  // Each inline project extends the root config below, which sets only the reporters, and
  // carries its own plugins and root. Its plugins change the Vite config, so it gets its own
  // Vite server rather than sharing the root's.
  const unitProject = {
    plugins: [appAliases],
    test: {
      name: "unit",
      root: repoRoot,
      environment: "node" as const,
      globals: false,
      include: project.unitInclude ?? [inShared("test/**/*.test.ts")],
      exclude: [...configDefaults.exclude, ...integrationInclude, ...(project.unitExclude ?? [])],
      setupFiles,
    },
  };

  // Every test runs in a rolled-back transaction on the run's one database, so the tests
  // run in parallel; the work is I/O-bound, so the worker count does not stop at the CPUs.
  // The group order runs integration after unit, so a unit failure is reported first.
  const integrationProject = {
    plugins: [appAliases],
    test: {
      name: "integration",
      root: repoRoot,
      environment: "node" as const,
      globals: false,
      include: integrationInclude,
      globalSetup: [resolve(here, "test/globalSetup.ts")],
      setupFiles,
      maxWorkers: Math.max(8, availableParallelism()),
      sequence: { groupOrder: 1 },
    },
  };

  return {
    test: {
      reporters: ["default"],
      projects: [
        unitProject,
        ...(runsIntegration ? [integrationProject] : []),
        ...(project.vitestProjects ?? []).map((p) => ({ ...p, plugins: [appAliases, ...(p.plugins ?? [])] })),
      ],
    },
  };
});
