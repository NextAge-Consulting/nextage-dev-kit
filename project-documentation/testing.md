# Testing

The developer reference for tests in a kit-enabled project: the Vitest scaffolding the kit ships, `/e2e`, and the integration tier's gates. Who runs tests and which tier a test belongs in is the `testing-verification` rule; the model behind it is `pipeline.md` §1.5.

## 1 Vitest scaffolding

Per-app test infrastructure the kit owns. `/sync-dev-kit` keeps every file identical to the kit's, so a fix to the harness reaches every project — except `test/project.ts`, which is the project's: the kit seeds it once and never offers it again.

**Destination comes from the `SHARED_MODULE_DIR` substitution**, because test layout is project-specific (`apps/shared` in a monorepo, `src` or `.` in a flat repo, `packages/<name>` elsewhere). `vitest.config.ts` lands at `<SHARED_MODULE_DIR>/vitest.config.ts`; every other file at `<SHARED_MODULE_DIR>/test/<name>`. **Empty means the project has no shared test module and the scaffolding is skipped entirely** — so this costs nothing for projects it does not apply to.

**The kit ships the integration harness for PostgreSQL and SQL Server.** `globalSetup.ts`, `integration-helpers.ts` and `harness.integration.test.ts` sync from the kit's PostgreSQL files when `DB_ENGINE` is `PostgreSQL`, and from `templates/testing/sqlserver/` — with `integration-target.ts` and `mssql-connection.ts` beside them — when it is `SQLServer`. `vitest.config.ts` registers the `integration` project for either. A project on `Other` writes its own `dbTest` with the same shape — a rolled-back transaction per test, the `tx` handed to the code under test — registers it in `project.ts`'s `vitestProjects` under the name `integration`, which every gate runs, and records its database in `rules/project/`.

**What differs between projects goes in `test/project.ts`**, typed by `test/define.ts`:

| Setting | What it sets |
|---|---|
| `timezone` | The IANA zone every test runs in — the zone the project stores and shows time in (constitution §VI). The smoke test asserts it. |
| `schema` | The main database's Drizzle schema; `dbTest`'s handle is typed and built with it. |
| `unitInclude`, `unitExclude`, `integrationInclude` | Test file globs from the repository root, when the defaults under the shared module's `test/` do not fit. |
| `integrationWorkers` | How many integration test files run at once — what the database can serve. Default: the CPU count, at least 8. `.env`: `INTEGRATION_WORKERS`. |
| `lockTimeoutMs` | SQL Server: how long, in milliseconds, a test waits on a lock another running test holds before it fails. Default: 10000. `.env`: `INTEGRATION_LOCK_TIMEOUT_MS`. |
| `vitestProjects` | Further vitest projects beside `unit` and `integration` — a UI package with its own environment. |
| `envKeys` | `.env` keys the tests may read beyond `NEON_*` and `TZ`. |
| `integrationDatabase` | SQL Server: the doc a developer follows to set up and mark a development database, and each migration folder with the command that applies it. The harness refuses to run without it. |
| `extraDatabases` | PostgreSQL: databases beyond the main one on the integration branch — each one's URL variable, name, drizzle-kit config and schema. |
| `afterMigrate` | PostgreSQL: runs once after every database is migrated, given each URL — for what a fork of production needs before tests. |
| `roles` | The roles a test user may hold, and the default `mockAuthedUser` gives. |

**`integrationWorkers` and `lockTimeoutMs` layer: the kit's default, then `test/project.ts`, then the developer's `.env` — the most specific one set wins.** A project sets what suits its database; a developer on a slower connection overrides it for their own runs with one line in the repository's `.env` (`INTEGRATION_WORKERS=4`), which reaches nobody else. Only the `.env` file counts, not the shell's environment. `vitest.config.ts` resolves both before any worker spawns, through `test/settings.ts`, and a value that is set but is not a whole number of at least 1 fails the run, naming the key and the file it was set in — it never falls back to a less specific layer.

**A project's own helpers go in files of their own beside `project.ts`** — domain fakes, a second database's test function (`export const auditTest = dbTestOn("AUDIT_DATABASE_URL")`), a stub server. A kit file is never edited to hold them.

**The files:**

| File | Purpose |
|---|---|
| `define.ts` | The contract `project.ts` is written against. |
| `project.ts` | The project's settings. Seeded once; the project's from then on. |
| `settings.ts` | The layered settings resolver: kit default, then `project.ts`, then `.env`, most specific wins; an invalid set value throws naming its key and file. |
| `vitest.config.ts` | Node env; globals off; a `unit` project (parallel, no DB) and an `integration` project (parallel — on PostgreSQL when Neon creds exist; on SQL Server always, except in CI with `INTEGRATION_CI_OFF` declared), plus `project.ts`'s own. Resolves the repository root from `.claude/sync-substitutions.json`, and each app's `@/` alias from the nearest `tsconfig.json` above the importing file. Resolves the layered settings, sets the integration worker count, and on SQL Server provides the lock-wait limit to every worker. |
| `globalSetup.ts` | PostgreSQL: integration branch lifecycle. Forks the default (production) branch once per run, runs `drizzle-kit migrate` for every database on it, runs `afterMigrate`, sets the URLs before workers spawn, and deletes the branch in `teardown` (`expires_at` 30 min is the crash backstop). Teardown does not swallow a failed delete. |
| `integration-helpers.ts` | PostgreSQL: `dbTest(name, fn)` and `dbTestOn(envVar)` — the only DB entry points. Each runs `fn` inside an always-rolled-back Postgres transaction and passes the `tx` handle into the code under test. |
| `globalSetup.ts` (SQL Server) | Reads `.env`'s `DB_*` keys into a sandbox, runs `integration-target.ts`'s checks, and points `DATABASE_URL` at the development database before workers spawn. No `DB_*` key reaches a worker, so code that builds its own connection fails instead of committing. |
| `integration-target.ts` (SQL Server) | The checks before any test connects: the server carries the test-target mark, the database is `ONLINE` and allows snapshot isolation, and every migration folder the branch holds is recorded. Each refusal names the fix. |
| `integration-helpers.ts` (SQL Server) | `dbTest(name, fn)` — a snapshot transaction, always rolled back, on one pool per worker built from `DATABASE_URL`; `LOCK_TIMEOUT` set to the lock-wait limit (`lockTimeoutMs`, 10 s by default) and sent as a batch; a deadlock victim retried up to three times, judged on the error the test body raised. |
| `mssql-connection.ts` (SQL Server) | The ADO connection string from `DB_*`, every value braced (`sqlserver-drizzle.md` §II); the tests' pool settings, which lend a connection without `mssql`'s per-borrow `SELECT 1` (`validateConnection: false`); and string parameters bound as `varchar`. Its unit test, `mssql-connection.test.ts`, parses the string back through the driver and checks the pool resolves with the check off. |
| `harness.integration.test.ts` | The harness's own test. On SQL Server it proves one open transaction, snapshot isolation, the lock timeout the run resolved, a nested `db.transaction` staying inside, and a rollback leaving no trace — and `test:preflight` runs it alone. |
| `auth-mocks.ts` | Typed `MockAuthedUser` + `mockAuthedUser()` / `mockUnauthed()` stubs, roles from `project.ts`. |
| `test-utils.ts` | Setup file. Loads the allowed `.env` keys, pins `process.env.TZ` to `project.timezone`, exposes a deterministic UUID-v7-like helper, re-exports the auth mocks. |
| `smoke.test.ts` | Proves vitest picks up the config, runs the setup file, resolves module imports, and runs in the project's timezone. |

**Enabling it for a consumer:**

```bash
# 1. Deps, at the versions stack-manifest.json pins or newer — check-stack fails anything older.
npm install -D --save-exact vitest@5.0.5 vite@8.3.4 @neondatabase/api-client@2.7.3 pg@8.23.1

# 2. Point the substitution at the workspace holding the shared module.
#    "apps/shared" in a monorepo, "src" or "." flat, "" if the project has none.
jq '.SHARED_MODULE_DIR = "apps/shared"' .claude/sync-substitutions.json > tmp && mv tmp .claude/sync-substitutions.json

# 3. /sync-dev-kit — the files arrive as `new-kit`. Then set test/project.ts:
#    the timezone, and the schema import if it is not ../src/db/schema.

# 4. Wire npm scripts in root package.json:
#      "test":       "vitest run -c <shared-module>/vitest.config.ts"
#      "test:watch": "vitest -c <shared-module>/vitest.config.ts"
```

**On SQL Server**, step 1 installs `mssql` and the exact `drizzle-orm` 1.0 release candidate in place of `@neondatabase/api-client` and `pg` (`sqlserver-drizzle.md` §I), and the project adds:

- `.env`'s `DB_SERVER`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD` (and `DB_PORT`, `DB_ENCRYPT`, `DB_TRUST_SERVER_CERTIFICATE` when they differ from 1433, `true`, `true`), naming the development database;
- `integrationDatabase` in `test/project.ts`;
- the development database marked as a test target and allowing snapshot isolation, and the root script `"test:preflight": "vitest run -c <shared-module>/vitest.config.ts --project integration <shared-module>/test/harness.integration.test.ts"` (`sqlserver-drizzle.md` §V).

**Test-dir placement** — tests live at `<shared-module>/test/` (sibling of `src/`), NOT under `src/`. Keeps test code out of the production include glob and avoids special-casing test excludes in builder tooling. `<shared-module>/tsconfig.json` should explicitly `"include": ["src/**/*", "test/**/*"]` so `check-types` still typechecks test files.

**Integration pattern on PostgreSQL — one branch per run, transaction per test.** Files: `globalSetup.ts` (branch lifecycle) + `integration-helpers.ts` (`dbTest`). Same behavior locally and in CI: `globalSetup.ts` forks the project's default (production) branch **once per test run** (Neon copy-on-write), migrates it, points `DATABASE_URL` at it before any worker spawns, and deletes it in `teardown`. One create + one delete for the whole run → no API rate-limiting, no orphaned branches. Uses `@neondatabase/api-client` directly.

**Integration pattern on SQL Server — one development database, snapshot transaction per test.** SQL Server has no instant copy, so every run uses the development database `.env` names and every test's writes are rolled back. `globalSetup.ts` checks the database first and refuses, naming the fix, unless the server is marked as a test target, the database is `ONLINE` and allows snapshot isolation, and the branch's migrations are recorded; it never applies one. Tests run in parallel: each reads under snapshot isolation, so a read never waits on another test's uncommitted rows. A write still takes locks — an `UPDATE` or `DELETE` of a row another running test wrote, or an insert of a key it holds, waits until that test rolls back, and fails after the lock-wait limit (`lockTimeoutMs`, 10 s by default) rather than hanging. Identity values are not rolled back and the data drifts between refreshes, so a test inserts its own rows with invented keys. Each worker opens one pool, and the pool lends a connection without first running `SELECT 1` on it — that check would cost a round trip on every test; a connection already known closed or errored is still discarded, and one that died unnoticed fails the test at its transaction's first statement with the driver's connection error.

**Vitest "projects" split.** `vitest.config.ts` defines two projects: a `unit` project (parallel, no DB — runs in every context including forks and Dependabot PRs that have no credentials) and an `integration` project (also parallel, every worker sharing the one database). On PostgreSQL the integration project is present only when `NEON_API_KEY` + `NEON_PROJECT_ID` are set; on SQL Server it is always present, except in CI with `INTEGRATION_CI_OFF` declared, so a missing `DB_*` key is a refusal that says so rather than a silently skipped tier.

**Isolation = transaction-per-test.** `dbTest(name, async (tx) => { … })` is the ONLY way a test touches the DB. It runs the body inside a Postgres transaction that is ALWAYS rolled back, so concurrent tests on the one shared branch are MVCC-isolated and run in **parallel** without colliding — nothing persists between tests. There is no exported pool or committing `db` handle, so a test physically cannot write outside a rolled-back transaction; isolation is enforced by the API, not by author discipline. Every production function takes `db` as a parameter, so `tx` threads straight through into the code under test — sequences, triggers, FK cascades, NOTIFY all behave normally inside the transaction. `tx` is a drizzle transaction, so code under test that opens its own `db.transaction(...)` gets a savepoint, and its writes still roll back with the test. A global-sweep test (a function that scans a whole table) clears that table at the top of its transaction (rolled back after). Carve-out: a test that takes a SESSION-level advisory lock must release it itself — `ROLLBACK` won't.

**PostgreSQL never falls back to a shared dev DB** when the Neon credentials are absent: that would couple tests to mutable shared state. Postgres sequences (`SERIAL` / `bigserial`) increment globally and are NOT rolled back by transaction rollback, so any mutation test would leave sequence drift on the shared DB forever. An ephemeral branch that's deleted at the end of the run eliminates that entirely and is cheap (~$0.01/run). Use it.

**Required env vars** (set in `.env` locally and as repo Secrets in CI — see "Single-tab Secrets" below):
- `NEON_API_KEY` — personal-scope key, each developer generates their own at `console.neon.tech` → avatar → Account settings → API keys. CI uses the project owner's key. Each dev needs collaborator access to the shared project (Neon UI: "Projects shared with me").
- `NEON_PROJECT_ID` — the shared project ID (e.g. `quiet-river-12345678`). Same value for every dev + CI.

**Optional env vars** (project-specific, omit when Neon defaults work):
- `NEON_DATABASE_NAME` — Neon auto-creates a `neondb` database on project creation. If your app's schema lives in a different database (very common), set this so test branches connect to the right DB. Without it, tests get "relation 'product' does not exist" errors.
- `NEON_ROLE_NAME` — defaults to project owner role; set when your app's schema is owned by a non-default role (typical when `NEON_DATABASE_NAME` is also non-default — same name pattern usually).

**Single-tab Secrets.** All four go in repo Secrets (not split between Secrets and Variables). Only `NEON_API_KEY` is technically sensitive; the other three are identifiers. Splitting buys log-visibility but costs a dual-prefix mental model on every workflow edit forever — recoverable any time with one `run: echo "project=$NEON_PROJECT_ID"` step. Single mental model wins for small shops.

**Parent branch.** `globalSetup.ts` forks the project's default (production) branch. Fork-from-production is the canonical answer because:
- prod is the only authoritative reference for "what schema is actually live"
- forking from `dev` risks testing against schema that may never reach prod (devs can leave migrations applied to dev that they later drop from a PR)
- privacy is small concern for shops with shared prod access already

**Migration-during-PR (wired in `globalSetup.ts`).** After forking the branch and setting `DATABASE_URL`, `setup` runs `npx drizzle-kit migrate` once against the fresh branch, and once per `extraDatabases` entry with its own config. This is **idempotent**: drizzle tracks applied migrations in `__drizzle_migrations`. The branch forked production, which lacks any migration from THIS PR — so a migration PR applies exactly the new one, and a non-migration PR is a no-op. Either way the pending migration is validated in the same CI pass, same code path as the production deploy step (`npm run db:migrate` post-deploy).

Cost: ~1s per run when a migration is applied (Drizzle is fast on small migration counts). No-op when the branch is already current.

**Required scripts** (root `package.json`):
- `"test": "vitest run -c <vitest-config-path>"` — single command for both the unit and integration projects; the per-run branch + transaction-per-test (`dbTest`) handle isolation.

Integration tests use the `*.integration.test.ts` filename convention as the `integration` project's include glob (the `unit` project excludes it); `npm test` runs both projects in one command. That glob covers all three kinds — happy-path (`*.happy.integration.test.ts`), risk (`*.integration.test.ts`) and development (`*.dev.integration.test.ts`) — and the integration project leaves the development tests out unless `INTEGRATION_DEV_TESTS=1` is set. A project's own `integrationInclude` gets the same exclusion. To run one development test by hand: `INTEGRATION_DEV_TESTS=1 npm test -- --project integration <file>`.

**Wiring CI** — the kit ships a **stack-detecting** `.github/workflows/ci.yml`. A fast `detect` job checks out and sets `node`/`python`/`terraform`/`project` outputs; the rest gate on `needs.detect.outputs.*` (NOT `hashFiles()`, which is empty at job-`if:` time — the workspace isn't checked out yet). Node (root `package.json`) → a `node-checks` job running `dep-alignment`, `workspace-tiers`, `stack-standard`, `check-types`, `biome` (plus `lint:tokens` and `lint:design` when `design.md` exists) and `knip` (gated by `KNIP_GATE`, pipeline.md §3.9) as steps, and a `vitest` job; Python (any `pyproject.toml`) → a `python` job running `ruff check` + `pytest` via uv in each pyproject dir (monorepo layouts like `services/<x>/` work with zero config), then pyright at the stack manifest's pin — or mypy where the project declares only mypy — from the root when a root `pyproject.toml` or `pyrightconfig.json` exists; `semgrep` always runs, and the `project` job runs the repository's own steps from its `project-steps` region, skipped while that region holds only the kit's placeholder step. (`dep-alignment` is the cross-workspace dependency-version gate — pipeline.md §3.6 / dependency-management.md.) The Node `vitest` job runs `npm test` — Node projects with tests need a `test` script in root `package.json` pointing at their vitest config (see "Install steps for a consumer" above); a repository with no `test` script, no vitest config and no test files of its own passes the job saying it does not apply (pipeline.md §1.4). Python projects need uv (shop standard) with `ruff`, `pytest` and `pyright` as dev deps, pyright at the stack manifest's version — no per-project config. A repo lacking a stack simply skips that stack's jobs; `/merge` self-gates on the check-runs that actually report, so skipped jobs don't block (there are no GitHub-required checks to wait forever on a never-run job).

**No required-status-check promotion.** The pipeline uses no branch protection — `/merge` self-gates by reading the PR's check-runs directly and blocks on any failure, so a job gates merges as soon as it runs on a PR, with nothing to configure on GitHub. New CI jobs are picked up automatically.

Integration tests run in the same `vitest` job (`NEON_API_KEY` + `NEON_PROJECT_ID` secrets via repo Settings — on PostgreSQL the integration project only activates when both are present). When the repository has happy-path or risk integration tests — development tests (`*.dev.integration.test.ts`) do not count, since the full suite leaves them out — the job fails unless the integration project ran; §3 has the rule and how a project declares CI unable to run them. Under `TEST_RUNNER` `aws` the job runs the unit tests only and the CodeBuild test project carries this rule instead.

**Smoke-test latency.** A consumer with only the smoke test takes ~5s in CI; not worth deferring the wiring. Land the workflow with the first real test file or the smoke-test scaffold — either is fine.

**Companion: the shared module is a workspace package (pairs with this scaffolding)**

The shared module is a declared npm workspace with its own name, and every consumer imports it by that name (`typescript-rules.md`, Workspace Imports). That is also what puts it under the root `check-types`, which runs every workspace's own `check-types` script (`scripts/check-types.mjs`) — a shared folder reached only through a path alias is type-checked by nobody, and real errors in it ship.

1. `<shared-module>/package.json` has `private: true`, a name (`"@acme/shared"`), `"scripts": {"check-types": "tsc --noEmit"}`, and an `exports` map pointing at its TypeScript source.
2. `<shared-module>` is in the root `package.json` `workspaces` array, and each consumer lists `"@acme/shared": "*"` in its dependencies.
3. If shared code reads `import.meta.env.VITE_*`, `<shared-module>/src/vite-env.d.ts` holds `/// <reference types="vite/client" />` and the module declares `vite` as a devDependency. Without the reference, standalone `tsc` fires TS2339 on `import.meta.env`.

## 2 `/e2e` skill (Claude-as-intelligent-tester)

**What this is.** A Skill that implements the locked E2E testing model (kit `pipeline.md` §1.5): Claude drives `agent-browser` through plain-English flow files, detects failure behaviorally, reports pass/fail. **Not a scripted test suite. Not Playwright. Not Stagehand.**

**Components ship:**
- `.claude/skills/e2e/SKILL.md` — the skill protocol (discovery, scoping via PR diff, server startup per dev-server.md, execution, reporting)
- `.claude/lib/gen-report.mjs` — the shared data-driven HTML generator (theme + true CSS lightbox baked in), also used by the `analysis` skill; the run writes `logs/e2e/results.json`, this renders `logs/e2e/<project>-e2e-<YYYYMMDD>.html`
- `.claude/skills/e2e/example-flow.md` — copy-paste template to fill in with your own flows

**Report.** A run produces a self-contained HTML report — per-step ✅/❌ with inline (base64) screenshots — so a run can be fired off and reviewed async; the screenshots are the audit trail behind each pass, not a substitute for the behavioral judgment.

**Authoring companion — `e2e-author` skill.** Writing and maintaining flow files is its own skill (`.claude/skills/e2e-author/`), sibling to the runner. It carries the flow-file format, the frontmatter spec, and a recipe library for the recurring agent-browser gotchas (off-screen click won't fire, env values with spaces truncate, mouse-move arg split, viewport, OTP-from-DB), plus a dry-run-before-done rule so new flows can't rot unrun. `/e2e` runs flows; `/e2e-author` writes them.

**Consumer setup:**
1. The skill arrives with the kit at `.claude/skills/e2e/`.
2. Create flow files at `apps/shared/test/e2e/*.md` (monorepo layout) or `test/e2e/*.md` (flat layout). Copy `example-flow.md` as a starting point.
3. Each flow declares `triggers:` — glob patterns for the files it covers. The skill computes the diff∩triggers intersection **only when the user picks the diff-scoped scope option** (see below).

**Invocation modes (documented in SKILL.md):**
- `/e2e all` — force-run every flow regardless of diff (no question)
- `/e2e <flow-name>` — run a single flow by `name:` frontmatter value (no question)
- `/e2e` with no arg — ask the **scope question** (one `AskUserQuestion`): diff-scoped (fires the diff logic) / all flows / select specific (a second `multiSelect` question listing discovered flows).

`/e2e` is a standalone command. It runs only when the user invokes it — `/merge` does not call it and asks nothing about E2E.

**Separation of concerns.** Skill = orchestration + scope selection; flow files = test definitions with their own triggers. Each concern has one home.

**What the skill does NOT do:**
- No scripted assertions / `expect()` calls — failure is behavioral
- No retries or flake-tolerance — a step failing is a real signal
- No browser fleet / parallelism — single `agent-browser` session per flow

**Failure handling.** `/e2e` reports pass/fail — any ❌ is a real signal. Decide per-case whether it's a real bug (fix) or flow-definition drift (update the flow file in the same PR). Don't bypass a red flow.

**Known open work (deferred).** One loose end worth capturing for future iteration:

1. **Substantive behavioral assertions.** MVP flows are render-checks ("homepage loads", "form renders"). Real-value accretion is flow-specific business logic — validate price math on product detail, cart total recalculates when shipping address changes, Stripe elements actually mount and accept input, post-login dealer pricelist reflects the correct tier. Accretion-on-demand per flow when a specific bug class starts slipping through.

## 3 The integration tier and its gates

**The full suite is the happy-path tests and the risk tests.** A happy-path test proves the main success case of a core function, and the happy-path audit, run with the developer, decides which functions are core. A risk test covers a case a sensible later change could break unnoticed — money math, dates and period boundaries, permissions, data integrity, concurrency, another system's contract, code many others depend on, or a fixed bug that a competent developer making a sensible change could plausibly bring back (one resting on a database quirk, a protocol detail, a boundary or an external contract; a plain mistake gets a development test). Three of those are narrower than they sound. **Money math** is an amount the code computes — a sum, a fee rate, rounding, proration; a zero or a missing amount is not money math. **Data integrity** is a write that could corrupt, duplicate or orphan data that other code or another application reads — a duplicate where one must be unique, a write left half-done, a write landing on the wrong record; a function that writes nothing when it refuses, or leaves other columns alone, is checking its own logic, a development test. **Another system's contract** is the shape, protocol or encoding that system requires, asserted against its real format; a case where that system is mocked tests a branch. A filter, join, aggregate or date range on its own is none of those, and neither is a database quirk on its own — collation, trimming, `NULL` handling, a column's type, a fallback that writes nothing — unless a fixed bug rests on it: it belongs in the integration tier, as a development test. Every other test is a development test, kept beside the integration test file it came from: it runs at `/commit` while its code changes and never in the full suite, so the suite grows with the risk in the code rather than with the number of functions. `testing-verification.md` holds the rule and the shape of a test.

**Shared code is tested once, in the shared module; an app tests only what it adds.** An app test of an app function that only passes the call through to a shared-module function, asserting nothing the shared module's own test of it does not, is a duplicate and is deleted. What the app adds on top — its own inputs, checks or output shape — is tested on its own.

**The happy path is `/happy-path <app>`.** Claude ranks what the app's core is — by reach, money, access and where fixes have landed, never by navigation — you correct the list, and it writes the missing happy-path tests and retires the ones that no longer cover anything core. An app's live in `<app>/test/happy-path/`, the shared module's in its own; a snapshot of the app's routes, server functions and tables is saved beside them. `/open-pr` warns, and still opens the PR, when an app it touches has no happy path or has moved more than a quarter of that snapshot since.

**Database code of a risky shape needs at least one happy-path or risk test that calls it**, in any project whose `DB_ENGINE` is not `None`. The shapes are raw SQL, a join, a filter beyond a lookup by key, an aggregate or grouping, a date comparison, an upsert, a transaction, and more than one write. Thin code — a plain insert, a select by key — needs none: a test of it would only prove the ORM works. A development test does not count, because it is not in the full suite. The shape decides only that one test is kept: when none of the function's cases is a risk test on its own merits, its main success case is filed as one, and counts until `/happy-path` decides whether the function is core — so new code always has a test it can be given at `/commit`. Only that one case; the function's other cases are risk or development tests by the criteria above.

**A test calls the app's code.** An integration test file that imports nothing from the app's source — only the harness, test helpers and libraries — is refused; it tests the database, not the app, and is rewritten to call the app's function. The kit's own `harness.integration.test.ts` is the one exception, since the harness is what it tests. Whether a test runs its own copy of the logic instead of calling it is for the test judge, which also flags a risky case with no test and a test that is superfluous.

**Reference data.** A test may read stable reference data the database already holds — a catalog's structure, a legacy code table — rather than rebuild it. It never asserts a value the business changes day to day, such as a price, a whole-table count or a record users edit; for those it inserts its own row or asserts a property rather than an exact figure. Nothing checks this: a wrong choice shows up as a test that starts failing.

**The ratchet.** `scripts/check-integration-coverage.mjs` judges only exported functions and test files that are new or changed since the branch left `main`. Touch an untested risky function and it needs its test in the same change; leave it alone and it is only counted (CI prints the count). Nobody is asked to backfill the codebase.

**What the check reads.** TypeScript, through the compiler, so it recognises a handle by its type — a Drizzle database or transaction, or a driver's pool, client, connection or request — wherever it came from, and a query builder's joins, filters, aggregates and upserts by the database library that declares them. "Queries" means the function's body uses a handle — `db.select`, `tx.execute`, `pool.query` — whether the handle is a parameter, an import or a call's result; a function that only passes the handle on is not judged, the one that receives it is. It also fails a changed `.execute()` with no `// raw-sql: <reason>` comment (`drizzle.md` §I).

**The gates.**

| Where | What runs | Fails when |
|---|---|---|
| `/commit`, `/ship-main` | The coverage check, then `vitest related --project integration` on the changed files with `INTEGRATION_DEV_TESTS=1`: only the integration tests whose imports reach the change, development tests included. With none reached, nothing touches the database | A changed risky function lacks a happy-path or risk test; a changed test imports no app code; a reached test fails; the harness refuses the database — not set up for tests, unreachable, or lacking a migration the branch adds; integration tests exist but no integration project runs here |
| CI (`node-checks`, `vitest`) | The coverage check with the untouched count, then the full suite — happy-path and risk tests — unless an earlier commit of the PR passed it on the same code fingerprint, whose pass is carried forward. Every run records the `full-suite` status. Under `TEST_RUNNER` `aws` the `vitest` job runs the unit tests only, and the full suite runs in the project's CodeBuild test project instead (below) | The coverage check fails; integration tests exist and the `integration` project did not run |
| CodeBuild test project — under `TEST_RUNNER` `aws` only | On every PR, the full suite (`infra/codebuild/buildspec-test.yml`, `codebuild-suite.sh`), unless an earlier build of the project passed on the same code fingerprint. The project reports `full-suite` to the PR; the fingerprint is the build's `FULL_SUITE_FP` | The suite fails; integration tests exist and the `integration` project did not run |
| `/deploy` — first, before every other gate | The project's `test:preflight`, when it declares one: whether the integration tests' database is ready | The database is not set up for tests, cannot be reached, or lacks a migration the branch adds — asked before the release work starts |
| `/deploy` | The full suite, before any bump, build or migration (exit 26) — only when the exact code on `main` has no pass recorded; with one, it names the pass it trusts and runs neither the suite nor the preflight. Without one it runs the suite where `TEST_RUNNER` points: on the deploying machine, or a CodeBuild test build on `HEAD` it waits for. Under `ASSURANCE_LEVEL` `strict` it never runs the suite on the deploying machine | It fails, cannot run, or runs without the integration tests the repository has; under `strict`, no pass is recorded and the suite would run on the deploying machine |

**Unchanged code is not tested twice.** A gate that passes records the code fingerprint it passed on (`.claude/skills/gitflow/scripts/code-fingerprint.mjs`): one hash of the tree, TypeScript and JavaScript read by TypeScript's parser with comments and whitespace left out, every other file byte for byte. A comment carrying a tool directive — `@ts-ignore`, `biome-ignore`, `nosemgrep`, `#__PURE__`, a triple-slash reference, `@jsx` and the others the script lists — counts as code, and so does a JSDoc block in a JavaScript file. Locally, `/commit`'s and `/ship-main`'s typecheck and integration run, and `/merge`'s build, skip on the fingerprint of their last pass, kept under the git dir, and say so. For the full suite on GitHub Actions the record is a commit status, so CI and `/deploy` share it: `full-suite`, `success`, described `fp <fingerprint>` or `carried forward from <sha> · fp <fingerprint>`. The name and that format are defined once, as `FULL_SUITE` in `code-fingerprint.mjs`; CI posts the status (`--status-context`, `--status-description`), and `/deploy` reads it back (`--status-fp`). Under `TEST_RUNNER` `aws` the record is the CodeBuild test build itself: a `SUCCEEDED` build whose exported `FULL_SUITE_FP` is the fingerprint, which the next build and `/deploy` read from the project's builds. A failure is never recorded as a pass. Without TypeScript the script hashes every file byte for byte, so a comment change counts as a change and nothing is wrongly skipped.

The test judge rides the same commit: a headless reviewer reads the changed TypeScript and the tests that cover it — searching the whole repository's tests before it calls a test missing or a duplicate, and judging a change of any size — and stops the commit when a risky case has no test, a test is superfluous — the ORM working, a duplicate, a shared function re-tested through an app's pass-through wrapper — a test runs its own copy of the logic instead of calling the app's code, or a test is filed as the wrong kind for its name. The developer writes the missing test, rewrites the copy to call the app, deletes the superfluous test and renames the misnamed one, or skips with `SKIP_TEST_REVIEW=1`. The SQL review rides the same commit too: a headless reviewer reads every changed Drizzle `sql` template for a table or column typed as text — checking each name against the project's Drizzle schema files before it reports one, and judging a change of any size — and the developer fixes it or skips with `SKIP_SQL_REVIEW=1`.

**Turning one off.** The project owner declares it in `.claude/sync-substitutions.json`, and the value is the reason every check prints when it stands down:

| Key | Turns off |
|---|---|
| `INTEGRATION_COMMIT_OFF` | The gate at `/commit` and `/ship-main`: the coverage check and the tests the change reaches — e.g. developers cannot reach the test database |
| `INTEGRATION_CI_OFF` | The gate in CI: the coverage check and the requirement that the integration tests ran, on GitHub Actions or in the CodeBuild test build — e.g. CI cannot reach the non-production SQL Server |
| `INTEGRATION_DEPLOY_OFF` | `/deploy`'s test run — e.g. deploys run from a machine with no database access. Under `ASSURANCE_LEVEL` `strict` it excuses nothing: a recorded pass is still required |

Empty is on, and any gate still on requires the tests. With all three set, the project does not require integration tests. Listing a key in `_intentionally_empty` confirms it stays on, and `/sync-dev-kit` stops asking. `DB_ENGINE` = `None` stands every gate down without them.

**Python.** The coverage check reads TypeScript only, so a Python project has no ratchet yet; its gates still run its tests — CI's pytest and `/deploy`'s `uv run pytest`.

