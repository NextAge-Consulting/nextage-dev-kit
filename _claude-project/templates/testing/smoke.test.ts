// Reference-only — NOT synced by /sync-starter-kit.
// Copy to <test-dir>/smoke.test.ts in your project. See ../README.md.
//
// Phase 5 smoke test — proves the Vitest pipeline runs end-to-end:
//   * vitest picks up the config
//   * the setupFile (test-utils.ts) executes (TZ is pinned)
//   * test-utils re-exports from auth-mocks (module resolution works)
//   * assertions run under the node environment
//
// Real tests will exercise server functions, domain math, etc. This file
// exists only to fail loudly if the scaffolding ever rots.
//
// CHOOSE TZ: update the expected TZ assertion to match the pin in
// test-utils.ts. Defaults to "America/Chicago".

import { describe, expect, it } from "vitest";
import { mockAuthedUser, uuidv7Like } from "./test-utils";

describe("vitest scaffolding smoke", () => {
  it("runs assertions in node environment", () => {
    expect(1 + 1).toBe(2);
  });

  it("setup file pinned the process TZ", () => {
    expect(process.env.TZ).toBe("America/Chicago");
  });

  it("re-exports auth mock helpers from test-utils", () => {
    const user = mockAuthedUser({ role: "admin" });
    expect(user.role).toBe("admin");
    expect(user.userid).toMatch(/^0191d3c8-/);
  });

  it("produces deterministic uuidv7-like test ids", () => {
    expect(uuidv7Like("42")).toBe("0191d3c8-0000-7000-8000-000000000042");
  });
});
