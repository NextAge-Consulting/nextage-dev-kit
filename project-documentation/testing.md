# Testing

The developer reference for tests in a kit-enabled project: the Vitest scaffolding the kit seeds, and `/e2e`. Who runs tests and which tier a test belongs in is the `testing-verification` rule; the model behind it is `pipeline.md` §1.5.

## 1 Vitest scaffolding

Per-app test infrastructure the kit seeds once. The kit provides the starting point and **the project owns every file** — edit them freely; nothing reverts your changes.

**Destination comes from the `SHARED_MODULE_DIR` substitution**, because test layout is project-specific (`apps/shared` in a monorepo, `src` or `.` in a flat repo, `packages/<name>` elsewhere). `vitest.config.ts` lands at `<SHARED_MODULE_DIR>/vitest.config.ts`; every other file at `<SHARED_MODULE_DIR>/test/<name>`. **Empty means the project has no shared test module and the scaffolding is skipped entirely** rather than landing somewhere wrong — so this costs nothing for projects it does not apply to.

**When the kit improves one of these files,** `/sync-dev-kit` shows the change and the project decides; keeping your own version is the normal answer and does not re-prompt until the kit changes the file again.

**What's in the template dir:**

| File | Purpose |
|---|---|
| `vitest.config.ts` | Node env; globals off (explicit imports from `vitest`); two projects — `unit` (parallel, no DB) and `integration` (parallel, present only when Neon creds exist); `globalSetup` → globalSetup.ts; `setupFiles` → test-utils.ts; `root` pinned to the config-file dir so `npm test` from repo root resolves include globs. |
| `globalSetup.ts` | Integration branch lifecycle. Forks the default (production) branch once per run, runs `drizzle-kit migrate` against it, sets `DATABASE_URL` before workers spawn; deletes the branch in `teardown` (`expires_at` 30 min is the crash backstop). Uses `@neondatabase/api-client` — **pin `^2.7.2` or later**: `deleteProjectBranch` takes a single `{ projectId, branchId }` object from 2.7.2, and the older positional form silently requests `/projects/undefined/branches/undefined`, 404s, and leaks a branch per run. Teardown deliberately does not swallow that failure. |
| `integration-helpers.ts` | `dbTest(name, fn)` — the only DB entry point for integration tests. Runs `fn` inside an always-rolled-back Postgres transaction and passes the `tx` handle into the code under test, so parallel tests on the one shared branch stay MVCC-isolated. |
| `auth-mocks.ts` | Typed `MockAuthedUser` + `mockAuthedUser()` / `mockUnauthed()` stubs. |
| `test-utils.ts` | Setup file. Pins `process.env.TZ` (chosen per consumer — UTC for UTC-stored projects, local TZ for projects that store in local time). Exposes a deterministic UUID-v7-like helper. Re-exports auth mocks. |
| `smoke.test.ts` | 4 assertions proving vitest picks up the config, runs the setup file, resolves module imports, runs assertions under node env. |

**Enabling it for a consumer:**

```bash
# 1. Deps. Pin api-client ^2.7.2 or later — see the globalSetup.ts row above.
npm install -D vitest '@neondatabase/api-client@^2.7.2' pg

# 2. Point the substitution at the workspace holding the shared module.
#    "apps/shared" in a monorepo, "src" or "." flat, "" if the project has none.
jq '.SHARED_MODULE_DIR = "apps/shared"' .claude/sync-substitutions.json > tmp && mv tmp .claude/sync-substitutions.json

# 3. /sync-dev-kit — the files arrive as `new-kit` and land at their mapped
#    destinations. Every later kit improvement arrives the same way.

# 4. Wire npm scripts in root package.json:
#      "test":       "vitest run -c <shared-module>/vitest.config.ts"
#      "test:watch": "vitest -c <shared-module>/vitest.config.ts"
```

**Test-dir placement** — tests live at `<shared-module>/test/` (sibling of `src/`), NOT under `src/`. Keeps test code out of the production include glob and avoids special-casing test excludes in builder tooling. Runner defaults are not uniform — Mocha defaults to a `test/` directory; Vitest and Jest discover by filename glob (`.test.` / `.spec.`) and don't mandate a layout — but the sibling-of-`src/` convention is common because it works cleanly under all three when configured. `<shared-module>/tsconfig.json` should explicitly `"include": ["src/**/*", "test/**/*"]` so `check-types` still typechecks test files. Tests inside `src/` was tried and reverted after recognizing the real cost (test code leaking into the production include glob).

**TZ pinning** — consumer MUST choose a TZ that matches how their project stores and displays timestamps. The template ships with `America/Chicago` as the default. If your DB stores in UTC, pin `UTC`. The smoke-test assertion also must match.

**Integration pattern — one branch per run, transaction per test.** Reference templates: `globalSetup.ts` (branch lifecycle) + `integration-helpers.ts` (`dbTest`). Same behavior locally and in CI: `globalSetup.ts` forks the project's default (production) branch **once per test run** (Neon copy-on-write), migrates it, points `DATABASE_URL` at it before any worker spawns, and deletes it in `teardown`. One create + one delete for the whole run → no API rate-limiting, no orphaned branches. Uses `@neondatabase/api-client` directly.

**Vitest "projects" split.** `vitest.config.ts` defines two projects: a `unit` project (parallel, no DB — runs in every context including forks and Dependabot PRs that have no Neon creds) and an `integration` project (also parallel, every worker sharing the one branch). The integration project is present only when `NEON_API_KEY` + `NEON_PROJECT_ID` are set.

**Isolation = transaction-per-test.** `dbTest(name, async (tx) => { … })` is the ONLY way a test touches the DB. It runs the body inside a Postgres transaction that is ALWAYS rolled back, so concurrent tests on the one shared branch are MVCC-isolated and run in **parallel** without colliding — nothing persists between tests. There is no exported pool or committing `db` handle, so a test physically cannot write outside a rolled-back transaction; isolation is enforced by the API, not by author discipline. Every production function takes `db` as a parameter, so `tx` threads straight through into the code under test — sequences, triggers, FK cascades, NOTIFY all behave normally inside the transaction. A global-sweep test (a function that scans a whole table) clears that table at the top of its transaction (rolled back after). Carve-out: a test that takes a SESSION-level advisory lock must release it itself — `ROLLBACK` won't.

**Why no fallback to a shared dev DB.** The "fall back to .env DATABASE_URL when Neon creds are absent" pattern was tried and rejected. It silently couples tests to mutable shared state. Postgres sequences (`SERIAL` / `bigserial`) increment globally and are NOT rolled back by transaction rollback, so any mutation test would leave sequence drift on the shared DB forever. An ephemeral branch that's deleted at the end of the run eliminates that entirely and is cheap (~$0.01/run). Use it.

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

Point it at a different parent only if your project default is not the right reference — change the `createProjectBranch` call in `globalSetup.ts`.

**Migration-during-PR (wired in `globalSetup.ts`).** After forking the branch and setting `DATABASE_URL`, `setup` runs `execSync("npx drizzle-kit migrate")` once against the fresh branch. This is **idempotent**: drizzle tracks applied migrations in `__drizzle_migrations`. The branch forked production, which lacks any migration from THIS PR — so a migration PR applies exactly the new one, and a non-migration PR is a no-op. Either way the pending migration is validated in the same CI pass, same code path as the production deploy step (`npm run db:migrate` post-deploy).

Cost: ~1s per run when a migration is applied (Drizzle is fast on small migration counts). No-op when the branch is already current.

Adopting projects with non-Drizzle migration runners: swap the `execSync` command. The pattern (run-migrations-once-before-tests, in `globalSetup`) is general.

**Required scripts** (root `package.json`):
- `"test": "vitest run -c <vitest-config-path>"` — single command for both the unit and integration projects; the per-run branch + transaction-per-test (`dbTest`) handle isolation.

Integration tests use the `*.integration.test.ts` filename convention as the `integration` project's include glob (the `unit` project excludes it); `npm test` runs both projects in one command.

**Wiring CI** — the kit ships a **stack-detecting** `.github/workflows/ci.yml`. A fast `detect` job checks out and sets `node`/`python` outputs; the rest gate on `needs.detect.outputs.*` (NOT `hashFiles()`, which is empty at job-`if:` time — the workspace isn't checked out yet). Node (root `package.json`) → `dep-alignment`, `workspace-tiers`, `stack-standard`, `check-types`, `biome` (plus `lint:tokens` and `lint:design` when `design.md` exists), `vitest`; Python (any `pyproject.toml`) → a `python` job running `ruff check` + `pytest` via uv in each pyproject dir (monorepo layouts like `services/<x>/` work with zero config), then pyright — or mypy where the project declares only mypy — from the root when a root `pyproject.toml` or `pyrightconfig.json` exists; `semgrep` always runs, and the `project` job runs the repository's own steps from its `project-steps` region. (`dep-alignment` is the cross-workspace dependency-version gate — pipeline.md §3.6 / dependency-management.md.) The Node `vitest` job runs `npm test` — Node projects need a `test` script in root `package.json` pointing at their vitest config (see "Install steps for a consumer" above). Python projects need uv (shop standard) with `ruff`, `pytest` and `pyright` as dev deps — no per-project config. A repo lacking a stack simply skips that stack's jobs; `/merge` self-gates on the check-runs that actually report, so skipped jobs don't block (there are no GitHub-required checks to wait forever on a never-run job).

**No required-status-check promotion.** The pipeline uses no branch protection — `/merge` self-gates by reading the PR's check-runs directly and blocks on any failure, so a job gates merges as soon as it runs on a PR, with nothing to configure on GitHub. New CI jobs are picked up automatically.

Integration tests run in the same `vitest` job (`NEON_API_KEY` + `NEON_PROJECT_ID` secrets via repo Settings — the integration project only activates when both are present). When the repository has `*.integration.test.ts` files and either secret is empty, the job fails rather than passing on unit tests alone; Dependabot PRs, which run without secrets, are exempt.

**Smoke-test latency.** A consumer with only the smoke test takes ~5s in CI; not worth deferring the wiring. Land the workflow with the first real test file or the smoke-test scaffold — either is fine.

**Companion: monorepo-shared workspace wiring (pairs with this scaffolding)**

If your shared module (e.g. `apps/shared/`) is consumed via tsconfig path alias but is NOT a declared npm workspace, the root `npm run check-types --workspaces --if-present` will NOT typecheck it. A real TS error there can ship to main undetected. Close the gap:

1. Create `<shared-module>/package.json` with `private: true`, `"name": "@your-org/shared"`, and `"scripts": {"check-types": "tsc --noEmit"}`.
2. Add `<shared-module>` to the root `package.json` `workspaces` array.
3. If using Vite and `import.meta.env.VITE_*` in shared code, create `<shared-module>/src/vite-env.d.ts` with `/// <reference types="vite/client" />`. This registers `ImportMetaEnv` globally so `import.meta.env.VITE_*` resolves when `tsc` runs standalone in the shared module. Without it, standalone tsc fires TS2339 even though peer workspaces' tsc loads vite types transitively via their own `vite.config.ts`.

**Why this matters** — a shared module that isn't a workspace ships real type errors (TS2339 and friends) invisibly: no CI job type-checks it. Any project with a path-alias-only shared module has this gap until it runs this recipe.

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
