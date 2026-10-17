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
| `vitestProjects` | Further vitest projects beside `unit` and `integration` — a UI package with its own environment. |
| `envKeys` | `.env` keys the tests may read beyond `NEON_*` and `TZ`. |
| `integrationDatabase` | SQL Server: the doc a developer follows to set up and mark a development database, and each migration folder with the command that applies it. The harness refuses to run without it. |
| `extraDatabases` | PostgreSQL: databases beyond the main one on the integration branch — each one's URL variable, name, drizzle-kit config and schema. |
| `afterMigrate` | PostgreSQL: runs once after every database is migrated, given each URL — for what a fork of production needs before tests. |
| `roles` | The roles a test user may hold, and the default `mockAuthedUser` gives. |

**A project's own helpers go in files of their own beside `project.ts`** — domain fakes, a second database's test function (`export const auditTest = dbTestOn("AUDIT_DATABASE_URL")`), a stub server. A kit file is never edited to hold them.

**The files:**

| File | Purpose |
|---|---|
| `define.ts` | The contract `project.ts` is written against. |
| `project.ts` | The project's settings. Seeded once; the project's from then on. |
| `vitest.config.ts` | Node env; globals off; a `unit` project (parallel, no DB) and an `integration` project (parallel — on PostgreSQL when Neon creds exist; on SQL Server always, except in CI with `INTEGRATION_CI_OFF` declared), plus `project.ts`'s own. Resolves the repository root from `.claude/sync-substitutions.json`, and each app's `@/` alias from the nearest `tsconfig.json` above the importing file. |
| `globalSetup.ts` | PostgreSQL: integration branch lifecycle. Forks the default (production) branch once per run, runs `drizzle-kit migrate` for every database on it, runs `afterMigrate`, sets the URLs before workers spawn, and deletes the branch in `teardown` (`expires_at` 30 min is the crash backstop). Teardown does not swallow a failed delete. |
| `integration-helpers.ts` | PostgreSQL: `dbTest(name, fn)` and `dbTestOn(envVar)` — the only DB entry points. Each runs `fn` inside an always-rolled-back Postgres transaction and passes the `tx` handle into the code under test. |
| `globalSetup.ts` (SQL Server) | Reads `.env`'s `DB_*` keys into a sandbox, runs `integration-target.ts`'s checks, and points `DATABASE_URL` at the development database before workers spawn. No `DB_*` key reaches a worker, so code that builds its own connection fails instead of committing. |
| `integration-target.ts` (SQL Server) | The checks before any test connects: the server carries the test-target mark, the database is `ONLINE` and allows snapshot isolation, and every migration folder the branch holds is recorded. Each refusal names the fix. |
| `integration-helpers.ts` (SQL Server) | `dbTest(name, fn)` — a snapshot transaction, always rolled back; `LOCK_TIMEOUT` 10 s sent as a batch; a deadlock victim retried up to three times, judged on the error the test body raised. |
| `mssql-connection.ts` (SQL Server) | The ADO connection string from `DB_*`, every value braced (`sqlserver-drizzle.md` §II), and string parameters bound as `varchar`. Its unit test, `mssql-connection.test.ts`, parses the string back through the driver. |
| `harness.integration.test.ts` | The harness's own test. On SQL Server it proves one open transaction, snapshot isolation, the lock timeout, a nested `db.transaction` staying inside, and a rollback leaving no trace — and `test:preflight` runs it alone. |
| `auth-mocks.ts` | Typed `MockAuthedUser` + `mockAuthedUser()` / `mockUnauthed()` stubs, roles from `project.ts`. |
| `test-utils.ts` | Setup file. Loads the allowed `.env` keys, pins `process.env.TZ` to `project.timezone`, exposes a deterministic UUID-v7-like helper, re-exports the auth mocks. |
| `smoke.test.ts` | Proves vitest picks up the config, runs the setup file, resolves module imports, and runs in the project's timezone. |

**Enabling it for a consumer:**

```bash
# 1. Deps, at the versions stack-manifest.json pins — check-stack fails any other.
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

**Integration pattern on SQL Server — one development database, snapshot transaction per test.** SQL Server has no instant copy, so every run uses the development database `.env` names and every test's writes are rolled back. `globalSetup.ts` checks the database first and refuses, naming the fix, unless the server is marked as a test target, the database is `ONLINE` and allows snapshot isolation, and the branch's migrations are recorded; it never applies one. Tests run in parallel because each reads under snapshot isolation and so never waits on another's uncommitted rows. Identity values are not rolled back and the data drifts between refreshes, so a test inserts its own rows with invented keys.

**Vitest "projects" split.** `vitest.config.ts` defines two projects: a `unit` project (parallel, no DB — runs in every context including forks and Dependabot PRs that have no credentials) and an `integration` project (also parallel, every worker sharing the one database). On PostgreSQL the integration project is present only when `NEON_API_KEY` + `NEON_PROJECT_ID` are set; on SQL Server it is always present, except in CI with `INTEGRATION_CI_OFF` declared, so a missing `DB_*` key is a refusal that says so rather than a silently skipped tier.

**Isolation = transaction-per-test.** `dbTest(name, async (tx) => { … })` is the ONLY way a test touches the DB. It runs the body inside a Postgres transaction that is ALWAYS rolled back, so concurrent tests on the one shared branch are MVCC-isolated and run in **parallel** without colliding — nothing persists between tests. There is no exported pool or committing `db` handle, so a test physically cannot write outside a rolled-back transaction; isolation is enforced by the API, not by author discipline. Every production function takes `db` as a parameter, so `tx` threads straight through into the code under test — sequences, triggers, FK cascades, NOTIFY all behave normally inside the transaction. `tx` is a drizzle transaction, so code under test that opens its own `db.transaction(...)` gets a savepoint, and its writes still roll back with the test. A global-sweep test (a function that scans a whole table) clears that table at the top of its transaction (rolled back after). Carve-out: a test that takes a SESSION-level advisory lock must release it itself — `ROLLBACK` won't.

**Why PostgreSQL has no fallback to a shared dev DB.** The "fall back to .env DATABASE_URL when Neon creds are absent" pattern was tried and rejected. It silently couples tests to mutable shared state. Postgres sequences (`SERIAL` / `bigserial`) increment globally and are NOT rolled back by transaction rollback, so any mutation test would leave sequence drift on the shared DB forever. An ephemeral branch that's deleted at the end of the run eliminates that entirely and is cheap (~$0.01/run). Use it.

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

Integration tests use the `*.integration.test.ts` filename convention as the `integration` project's include glob (the `unit` project excludes it); `npm test` runs both projects in one command.

**Wiring CI** — the kit ships a **stack-detecting** `.github/workflows/ci.yml`. A fast `detect` job checks out and sets `node`/`python`/`terraform`/`project` outputs; the rest gate on `needs.detect.outputs.*` (NOT `hashFiles()`, which is empty at job-`if:` time — the workspace isn't checked out yet). Node (root `package.json`) → a `node-checks` job running `dep-alignment`, `workspace-tiers`, `stack-standard`, `check-types`, `biome` (plus `lint:tokens` and `lint:design` when `design.md` exists) and `knip` (gated by `KNIP_GATE`, pipeline.md §3.9) as steps, and a `vitest` job; Python (any `pyproject.toml`) → a `python` job running `ruff check` + `pytest` via uv in each pyproject dir (monorepo layouts like `services/<x>/` work with zero config), then pyright at the stack manifest's pin — or mypy where the project declares only mypy — from the root when a root `pyproject.toml` or `pyrightconfig.json` exists; `semgrep` always runs, and the `project` job runs the repository's own steps from its `project-steps` region, skipped while that region holds only the kit's placeholder step. (`dep-alignment` is the cross-workspace dependency-version gate — pipeline.md §3.6 / dependency-management.md.) The Node `vitest` job runs `npm test` — Node projects with tests need a `test` script in root `package.json` pointing at their vitest config (see "Install steps for a consumer" above); a repository with no `test` script, no vitest config and no test files of its own passes the job saying it does not apply (pipeline.md §1.4). Python projects need uv (shop standard) with `ruff`, `pytest` and `pyright` as dev deps, pyright at the stack manifest's version — no per-project config. A repo lacking a stack simply skips that stack's jobs; `/merge` self-gates on the check-runs that actually report, so skipped jobs don't block (there are no GitHub-required checks to wait forever on a never-run job).

**No required-status-check promotion.** The pipeline uses no branch protection — `/merge` self-gates by reading the PR's check-runs directly and blocks on any failure, so a job gates merges as soon as it runs on a PR, with nothing to configure on GitHub. New CI jobs are picked up automatically.

Integration tests run in the same `vitest` job (`NEON_API_KEY` + `NEON_PROJECT_ID` secrets via repo Settings — on PostgreSQL the integration project only activates when both are present). When the repository has `*.integration.test.ts` files, the job fails unless the integration project ran — §3 has the rule and how a project declares CI unable to run them.

**Smoke-test latency.** A consumer with only the smoke test takes ~5s in CI; not worth deferring the wiring. Land the workflow with the first real test file or the smoke-test scaffold — either is fine.

**Companion: the shared module is a workspace package (pairs with this scaffolding)**

The shared module is a declared npm workspace with its own name, and every consumer imports it by that name (`typescript-rules.md`, Workspace Imports). That is also what puts it under `npm run check-types --workspaces --if-present` — a shared folder reached only through a path alias is type-checked by nobody, and real errors in it ship.

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

**Every exported function that queries the database has an integration test that calls it**, in any project whose `DB_ENGINE` is not `None`. "Queries" means the function's body uses a database handle — `db.select`, `tx.execute`, `pool.query` — whether the handle is a parameter, an import or a call's result. A function that only passes the handle on to another one is not judged; the one that receives it is. `testing-verification.md` holds the rule and the shape of a test.

**The ratchet.** `scripts/check-integration-coverage.mjs` judges only exported functions that are new or changed since the branch left `main`. Touch an untested function and it needs its test in the same change; leave it alone and it is only counted (CI prints the count). Nobody is asked to backfill the codebase.

**What the check reads.** TypeScript, through the compiler, so it recognises a handle by its type — a Drizzle database or transaction, or a driver's pool, client, connection or request — wherever it came from. It also fails a changed `.execute()` with no `// raw-sql: <reason>` comment (`drizzle.md` §I). A function no integration test can call carries `// integration-exempt: <reason>` above it.

**The gates.**

| Where | What runs | Fails when |
|---|---|---|
| `/commit`, `/ship-main`, `/deploy` — first, before every other gate | The project's `test:preflight`, when it declares one: whether the integration tests' database is ready | The database is not set up for tests, cannot be reached, or lacks a migration the branch adds — asked while the developer is still there |
| `/commit`, `/ship-main` | The coverage check, then `vitest related --project integration` on the changed files: only the integration tests whose imports reach the change | A changed function lacks its test; a reached test fails; integration tests exist but no integration project runs here |
| CI (`node-checks`, `vitest`) | The coverage check with the untouched count, then the full suite | The coverage check fails; integration tests exist and the `integration` project did not run |
| `/deploy` | The full suite, before any bump, build or migration (exit 26) | It fails, cannot run, or runs without the integration tests the repository has |

The SQL review rides the same commit: a headless reviewer reads every changed Drizzle `sql` template for a table or column typed as text, and the developer fixes it or skips with `SKIP_SQL_REVIEW=1`.

**Turning one off.** The project owner declares it in `.claude/sync-substitutions.json`, and the value is the reason every check prints when it stands down:

| Key | Turns off |
|---|---|
| `INTEGRATION_COMMIT_OFF` | The gate at `/commit` and `/ship-main`: the coverage check and the tests the change reaches — e.g. developers cannot reach the test database |
| `INTEGRATION_CI_OFF` | The gate in CI: the coverage check and the requirement that the integration tests ran — e.g. CI cannot reach the non-production SQL Server |
| `INTEGRATION_DEPLOY_OFF` | `/deploy`'s test run — e.g. deploys run from a machine with no database access |

Empty is on, and any gate still on requires the tests. With all three set, the project does not require integration tests. Listing a key in `_intentionally_empty` confirms it stays on, and `/sync-dev-kit` stops asking. `DB_ENGINE` = `None` stands every gate down without them.

**Python.** The coverage check reads TypeScript only, so a Python project has no ratchet yet; its gates still run its tests — CI's pytest and `/deploy`'s `uv run pytest`.

