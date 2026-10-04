// Auth context mocks for Vitest — the kit's, kept current by /sync-dev-kit. The roles a
// test user may hold come from test/project.ts.

import project from "./project";

type Roles = typeof project extends { roles: { all: readonly (infer R)[] } } ? R : "admin" | "user";

export type MockAuthedUser = {
  userid: string;
  email: string;
  name?: string;
  role: Roles;
};

export const DEFAULT_MOCK_USER: MockAuthedUser = {
  userid: "0191d3c8-0000-7000-8000-000000000001",
  email: "test-user@example.test",
  name: "Test User",
  role: (project.roles?.default ?? "user") as Roles,
};

export function mockAuthedUser(overrides: Partial<MockAuthedUser> = {}): MockAuthedUser {
  return { ...DEFAULT_MOCK_USER, ...overrides };
}

export function mockUnauthed(): null {
  return null;
}
