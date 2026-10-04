# Vitest scaffolding — kit-owned, with one project seed

Every file here is **`owned`**: `/sync-dev-kit` keeps each consumer's copy identical to
the kit's. The one exception is `project.ts`, a **`template`** seed — the project's own
from the moment it lands, offered once and never again.

What differs between projects goes in `project.ts`, typed by `define.ts`: the timezone,
the schema, extra databases, extra vitest projects and include globs, extra `.env` keys,
an after-migrate hook, and the test user's roles. A project's own helpers live in files
of their own beside it, never in a kit file.

Their destination comes from the `SHARED_MODULE_DIR` substitution:

| Kit file | Lands at |
|---|---|
| `vitest.config.ts` | `<SHARED_MODULE_DIR>/vitest.config.ts` |
| everything else | `<SHARED_MODULE_DIR>/test/<name>` |

A project with `SHARED_MODULE_DIR` empty has no shared test module, and these files are
skipped entirely.

**This README is kit-internal** — it is in `SKIP_LIST` and never lands in a consumer.

Full pattern, install steps and the integration model: testing.md §1.

## What's in this directory

| File | Purpose |
|---|---|
| `define.ts` | The contract: `TestProject`, `ExtraDatabase`, and `defineTestProject()`. |
| `project.ts` | The seed. The project's settings, read by every other file here. |
| `vitest.config.ts` | Finds the repository root, then runs `unit` and — only when Neon credentials exist — `integration`, plus any projects `project.ts` adds. Resolves each app's `@/` alias per importing file. |
| `globalSetup.ts` | Integration branch lifecycle: forks the default branch once per run, migrates every database on it, runs `afterMigrate`, sets the URLs before workers spawn, deletes the branch in teardown. |
| `integration-helpers.ts` | `dbTest(name, fn)` and `dbTestOn(envVar)` — the only database entry points. Each runs its body in an always-rolled-back transaction. |
| `auth-mocks.ts` | Typed `MockAuthedUser` plus `mockAuthedUser()` / `mockUnauthed()`, with roles from `project.ts`. |
| `test-utils.ts` | Setup file. Loads the allowed `.env` keys, pins `TZ` to `project.timezone`, and exposes a deterministic UUID-v7-like helper. |
| `smoke.test.ts` | Proves vitest picks up the config, runs the setup file, resolves imports, and runs in the project's timezone. |

TypeScript diagnostics on these files inside the kit repo are expected — the kit has no
npm dependencies and no `src/db/schema`, so the imports do not resolve here. They resolve
in the consumer, the only place these files compile.
