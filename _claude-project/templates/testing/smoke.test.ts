// The test scaffolding's own smoke test — the kit's, kept current by /sync-dev-kit. It fails
// loudly if the scaffolding rots: vitest reads the config, the setup file runs, imports
// resolve, and assertions run under node.

import { describe, expect, it } from "vitest";
import project from "./project";
import { mockAuthedUser, uuidv7Like } from "./test-utils";

describe("vitest scaffolding smoke", () => {
  it("runs assertions in the node environment", () => {
    expect(1 + 1).toBe(2);
  });

  it("the setup file pinned the project's timezone", () => {
    expect(process.env.TZ).toBe(project.timezone);
  });

  it("re-exports the auth mocks from test-utils", () => {
    const user = mockAuthedUser({ email: "someone@example.test" });
    expect(user.email).toBe("someone@example.test");
    expect(user.userid).toMatch(/^0191d3c8-/);
  });

  it("produces deterministic uuidv7-like test ids", () => {
    expect(uuidv7Like("42")).toBe("0191d3c8-0000-7000-8000-000000000042");
  });
});
