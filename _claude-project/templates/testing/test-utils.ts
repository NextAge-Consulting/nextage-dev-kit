// Reference-only — NOT synced by /sync-starter-kit.
// Copy to <test-dir>/test-utils.ts in your project. See ../README.md.
//
// Vitest setup file + shared test utilities. Wired via `setupFiles` in
// vitest.config.ts — anything at module scope here runs once per worker
// before tests execute.

import { beforeAll } from "vitest";
import * as dotenv from "dotenv";
import * as path from "node:path";

// Load .env from the project root into a SANDBOX (processEnv: {}) — does
// NOT mutate process.env. We then promote only an explicit allowlist of
// keys the test environment is allowed to see. DATABASE_URL is deliberately
// NOT on the allowlist: it is set once per run by globalSetup.ts (which
// forks the ephemeral Neon branch and points DATABASE_URL at it before any
// worker spawns). Tests touch the DB only through dbTest() — a rolled-back
// transaction on that branch — never through this file. Keeping DATABASE_URL
// off the allowlist ensures a stray Pool connect fails loud (no DATABASE_URL
// → connect throws) instead of silently hitting a shared dev/prod DB.
//
// Adding a new test-relevant env var? Add it to ALLOWED_TEST_ENV_KEYS
// below — deliberate edit, not accidental leak. Production env vars stay
// in .env for the production app; the test process never sees them.
//
// Adjust the path resolution if this file's location relative to the .env
// differs from the monorepo-shared layout.
const TEST_ENV_PATH = path.resolve(__dirname, "../../../.env");
const ALLOWED_TEST_ENV_KEYS = [
  "NEON_API_KEY",
  "NEON_PROJECT_ID",
  "NEON_DATABASE_NAME",
  "NEON_ROLE_NAME",
  "TZ",
] as const;

const sandbox: Record<string, string> = {};
dotenv.config({ path: TEST_ENV_PATH, processEnv: sandbox });
for (const key of ALLOWED_TEST_ENV_KEYS) {
  const value = sandbox[key];
  if (value !== undefined) {
    process.env[key] = value;
  }
}

// Force a predictable timezone for every test run. Without this, tests
// would pick up the host's TZ and silently diverge between local macOS
// runs and Linux CI runners.
//
// CHOOSE A TZ that matches how your project stores and displays
// timestamps. Defaults below are examples:
//   * If your DB stores in UTC → "UTC"
//   * If your DB stores in local time (e.g. CST per your project's
//     `feedback_db_is_cst`) → that local zone, e.g. "America/Chicago"
//
// The smoke test asserts the pinned TZ; update it to match if you
// change this line.
beforeAll(() => {
  process.env.TZ = "America/Chicago";
});

// -----------------------------------------------------------------------
// Cross-test helpers — keep the surface small; extend as real tests land.
// -----------------------------------------------------------------------
export function uuidv7Like(suffix: string): string {
  // Deterministic stand-in for a UUID v7 primary key in tests. Not
  // cryptographically valid — only the shape matters for exercising the
  // code paths that accept any string PK.
  const padded = suffix.padStart(12, "0").slice(-12);
  return `0191d3c8-0000-7000-8000-${padded}`;
}

export { mockAuthedUser, mockUnauthed } from "./auth-mocks";
