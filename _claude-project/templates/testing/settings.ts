// Test settings that layer — the kit's, kept current by /sync-dev-kit. Each setting has a
// kit default, a value test/project.ts may set, and a key the developer's .env may set; the
// most specific one set wins: .env over test/project.ts over the kit. vitest.config.ts
// resolves every one before any worker spawns.
//
// A value that is set but is not a valid one fails the run, naming the key and where it was
// set; it never falls back to a less specific layer.

/** What a setting's values are: the words a failure uses, and how each layer's value is read. */
export type SettingKind<T> = {
  /** What a valid value is, as a failure message says it. */
  expected: string;
  /** The value as test/project.ts holds it, or undefined when it is not a valid one. */
  fromProject: (value: unknown) => T | undefined;
  /** The value as .env spells it, or undefined when it is not a valid one. */
  fromEnv: (raw: string) => T | undefined;
};

/** A whole number, 1 or more. */
export const positiveInteger: SettingKind<number> = {
  expected: "a whole number, 1 or more",
  fromProject: (value) => (typeof value === "number" && Number.isSafeInteger(value) && value >= 1 ? value : undefined),
  fromEnv: (raw) => (/^[1-9][0-9]*$/.test(raw) && Number.isSafeInteger(Number(raw)) ? Number(raw) : undefined),
};

/** One layered setting: its kit default, its key in test/project.ts, and its key in .env. */
export type LayeredSetting<T> = {
  kind: SettingKind<T>;
  kitDefault: T;
  projectKey: string;
  envKey: string;
};

/**
 * The setting's value: `env[envKey]` when .env sets it, else `project[projectKey]` when
 * test/project.ts sets it, else the kit default. `env` is the developer's .env as read, never
 * process.env. A set value that is not valid throws.
 */
export function resolveSetting<T>(setting: LayeredSetting<T>, project: object, env: Readonly<Record<string, string | undefined>>): T {
  const raw = env[setting.envKey];
  if (raw !== undefined) {
    const value = setting.kind.fromEnv(raw);
    if (value === undefined) {
      throw new Error(`${setting.envKey} in .env is ${JSON.stringify(raw)}: it must be ${setting.kind.expected}. Correct it, or remove the line to use test/project.ts's ${setting.projectKey} or the kit's default.`);
    }
    return value;
  }
  const written = (project as Record<string, unknown>)[setting.projectKey];
  if (written !== undefined) {
    const value = setting.kind.fromProject(written);
    if (value === undefined) {
      throw new Error(`${setting.projectKey} in test/project.ts is ${JSON.stringify(written)}: it must be ${setting.kind.expected}. Correct it, or remove it to use the kit's default.`);
    }
    return value;
  }
  return setting.kitDefault;
}
