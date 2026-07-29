// Reference-only — NOT synced by /sync-starter-kit.
// Copy to <test-dir>/auth-mocks.ts in your project. See ../README.md.
//
// Auth context mocks for Vitest tests. Shape-only stubs; real behavior
// arrives alongside the first real server-function tests. The shape
// below is a generic starting point — adapt the user model fields
// (userid → id / user_id / sub, role enum values, etc.) to your
// project's auth layer.

export type MockAuthedUser = {
  userid: string;
  email: string;
  name?: string;
  role: "admin" | "user";
};

export const DEFAULT_MOCK_USER: MockAuthedUser = {
  userid: "0191d3c8-0000-7000-8000-000000000001",
  email: "test-user@example.test",
  name: "Test User",
  role: "user",
};

export function mockAuthedUser(
  overrides: Partial<MockAuthedUser> = {},
): MockAuthedUser {
  return { ...DEFAULT_MOCK_USER, ...overrides };
}

export function mockUnauthed(): null {
  return null;
}
