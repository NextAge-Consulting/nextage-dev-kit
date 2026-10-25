# Vitest scaffolding — kit-owned, with one project seed

Every file here is **`owned`**: `/sync-dev-kit` keeps each consumer's copy identical to
the kit's. The one exception is `project.ts`, a **`template`** seed — the project's own
from the moment it lands, offered once and never again.

What differs between projects goes in `project.ts`, typed by `define.ts`: the timezone,
the schema, extra databases, extra vitest projects and include globs, extra `.env` keys,
an after-migrate hook, the test user's roles, and the integration worker count and SQL
Server lock-wait limit — those two layered by `settings.ts`, a developer's `.env` overriding
the project's value, which overrides the kit's. A project's own helpers live in files
of their own beside it, never in a kit file.

Their destination comes from the `SHARED_MODULE_DIR` substitution:

| Kit file | Lands at |
|---|---|
| `vitest.config.ts` | `<SHARED_MODULE_DIR>/vitest.config.ts` |
| everything else | `<SHARED_MODULE_DIR>/test/<name>` |

A project with `SHARED_MODULE_DIR` empty has no shared test module, and these files are
skipped entirely. The integration harness is per engine. `globalSetup.ts`,
`integration-helpers.ts` and `harness.integration.test.ts` here are PostgreSQL's and sync
only when `DB_ENGINE` is `PostgreSQL`; `sqlserver/` holds SQL Server's, which sync only when
it is `SQLServer` and land at `<SHARED_MODULE_DIR>/test/<name>` like the rest.

**This README is kit-internal** — it is in `SKIP_LIST` and never lands in a consumer.

Full pattern, install steps and the integration model: testing.md §1.

## What's in this directory

| File | Purpose |
|---|---|
| `define.ts` | The contract: `TestProject`, `ExtraDatabase`, and `defineTestProject()`. |
| `project.ts` | The seed. The project's settings, read by every other file here. |
| `settings.ts` | The layered settings resolver: kit default, then `project.ts`, then `.env`, most specific wins; an invalid set value throws naming its key and file. |
| `vitest.config.ts` | Finds the repository root, then runs `unit` and `integration` — on PostgreSQL with Neon credentials; on SQL Server always, except in CI with `INTEGRATION_CI_OFF` — plus any projects `project.ts` adds. The integration project runs happy-path and risk tests and leaves development tests (`*.dev.integration.test.ts`) out unless `INTEGRATION_DEV_TESTS=1`, as `/commit`'s integration gate sets it; its worker count is the layered `integrationWorkers`. Resolves each app's `@/` alias per importing file. Resolves the layered settings before any worker spawns, and on SQL Server provides the lock-wait limit to the workers. |
| `globalSetup.ts` | PostgreSQL: integration branch lifecycle — forks the default branch once per run, migrates every database on it, runs `afterMigrate`, sets the URLs before workers spawn, deletes the branch in teardown. |
| `integration-helpers.ts` | PostgreSQL: `dbTest(name, fn)` and `dbTestOn(envVar)` — the only database entry points. Each runs its body in an always-rolled-back drizzle transaction, so a nested `db.transaction` is a savepoint. |
| `sqlserver/globalSetup.ts` | SQL Server: reads `.env`'s `DB_*` keys into a sandbox, checks the database (`integration-target.ts`), points `DATABASE_URL` at it before workers spawn. No `DB_*` key reaches a worker. |
| `sqlserver/integration-target.ts` | SQL Server: the checks before any test connects — the server's test-target mark, the database `ONLINE` and allowing snapshot isolation, every branch migration recorded. Each refusal says what to do. |
| `sqlserver/integration-helpers.ts` | SQL Server: `dbTest(name, fn)` on one pool per worker that lends connections without a `SELECT 1` check — a snapshot transaction, always rolled back, `LOCK_TIMEOUT` at the resolved lock-wait limit (10 s by default) sent as a batch, a deadlock victim retried. |
| `sqlserver/mssql-connection.ts` | SQL Server: the connection string from `DB_*` (sqlserver-drizzle.md §II), the tests' pool settings with the per-borrow check off, and strings bound as `varchar`. |
| `sqlserver/mssql-connection.test.ts` | SQL Server: proves the connection string keeps every value whole — `;`, `=`, braces, quotes, edge spaces — as the driver parses it — and that the tests' pool resolves with `validateConnection` off. |
| `auth-mocks.ts` | Typed `MockAuthedUser` plus `mockAuthedUser()` / `mockUnauthed()`, with roles from `project.ts`. |
| `test-utils.ts` | Setup file. Loads the allowed `.env` keys, pins `TZ` to `project.timezone`, and exposes a deterministic UUID-v7-like helper. |
| `smoke.test.ts` | Proves vitest picks up the config, runs the setup file, resolves imports, and runs in the project's timezone. |
| `harness.integration.test.ts` | PostgreSQL: proves `dbTest` keeps a test's writes in its rolled-back transaction when the code under test opens its own `db.transaction`. |
| `sqlserver/harness.integration.test.ts` | SQL Server: proves one open transaction, snapshot isolation, the resolved lock timeout, a nested `db.transaction` staying inside, and a rollback leaving no trace. `test:preflight` runs it alone. |

TypeScript diagnostics on these files inside the kit repo are expected — the kit has no
npm dependencies and no `src/db/schema`, so the imports do not resolve here. They resolve
in the consumer, the only place these files compile.
