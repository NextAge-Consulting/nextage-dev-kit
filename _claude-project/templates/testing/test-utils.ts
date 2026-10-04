// Vitest setup file and shared test utilities — the kit's, kept current by /sync-dev-kit.
// Wired through `setupFiles` in vitest.config.ts: module scope here runs once per worker,
// before any test.

import { existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import * as dotenv from "dotenv";
import { beforeAll } from "vitest";
import project from "./project";

// The repository's .env is read into a SANDBOX, never into process.env, and only an
// allowlist is promoted: the NEON_* keys, TZ, and the keys test/project.ts adds. A
// production variable stays out of the test process. DATABASE_URL is deliberately never
// promoted — globalSetup.ts points it at the run's branch — so a stray connection with
// no branch fails loudly instead of reaching a shared database.
function findRepoRoot(from: string): string {
  for (let dir = from; ; dir = dirname(dir)) {
    if (existsSync(resolve(dir, ".claude/sync-substitutions.json"))) return dir;
    if (dir === dirname(dir)) throw new Error(`test-utils.ts: no .claude/sync-substitutions.json above ${from}`);
  }
}
const ALLOWED_TEST_ENV_KEYS = ["NEON_API_KEY", "NEON_PROJECT_ID", "NEON_DATABASE_NAME", "NEON_ROLE_NAME", "TZ", ...(project.envKeys ?? [])];

const sandbox: Record<string, string> = {};
dotenv.config({ path: resolve(findRepoRoot(fileURLToPath(new URL(".", import.meta.url))), ".env"), processEnv: sandbox, quiet: true });
for (const key of ALLOWED_TEST_ENV_KEYS) {
  const value = sandbox[key];
  if (value !== undefined) process.env[key] = value;
}

// Every test runs in the zone the project stores and shows time in (test/project.ts), so a
// run on a developer's machine and on a CI runner agree.
beforeAll(() => {
  process.env.TZ = project.timezone;
});

/** A deterministic stand-in for a UUID v7 primary key: the shape is valid, the value is not random. */
export function uuidv7Like(suffix: string): string {
  const padded = suffix.padStart(12, "0").slice(-12);
  return `0191d3c8-0000-7000-8000-${padded}`;
}

export { mockAuthedUser, mockUnauthed } from "./auth-mocks";
