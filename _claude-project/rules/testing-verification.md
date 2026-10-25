# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how the session was launched. A background job with a human watching is still interactive.

## Interactive sessions

The human drives testing. Run agent-browser, e2e flows, or any manual verification pass only when they explicitly ask ("test this", "verify it"). Announcing that you are about to verify is not permission, and the human starting a dev server is not an invitation to test against it.

Your job ends at build and static verification — typecheck, lint, build. Then hand off: state what is ready and exactly what a verification would need.

## Autonomous sessions

`autonomous-sessions.md` defines the mode. It is asserted by the human or by an unattended launch, never inferred.

In an autonomous session, verify your own work — drive agent-browser and the relevant e2e flows to completion. There is no one to defer to.

## Which tests a change gets

**The test is written in the same change as the code it covers**, unit and integration
alike. Not afterwards, not in a follow-up.

**A tier with no tests in it yet is not a reason to skip.** The first test in a project
establishes the pattern; writing it is ordinary work, not a decision needing sign-off.
"There is no precedent, so I won't invent one" is avoidance wearing the clothes of
prudence — see `working-discipline.md`.

### Unit or integration

**Would a mock have to invent the answer?** This decides whether a test is a unit or an
integration test, never whether one is kept.

- **No — the answer is in the code.** Unit test. Formatting, parsing, validation, a
  branch, a calculation, which of two paths a value takes.
- **Yes — the answer comes from the database.** Integration test. Collation, column
  types and widths, `NULL` against empty string, defaults, unique and foreign-key
  constraints, generated ids, what a real join returns over real data shapes, what a
  stored timezone does.

**"It saved the row" and "it read back what I wrote" are the ORM working.** Neither is a
test of your code, and asserting them costs a database round trip to learn nothing. If you
cannot name what would be WRONG without the test, delete it.

Worked examples of a test that belongs in the integration tier rather than the unit tier —
each a defect only a real database shows. Which kind it is still follows the risk list: a
database quirk on its own (collation, trimming, `NULL` handling, a column's type, a fallback
that writes nothing) is a development test, unless a fixed bug rests on it.

- A lookup by one spelling finds a row the other application stored in another case —
  because the column collates case-insensitively.
- A missing setting returns its fallback **without writing a row** — because the system it
  replaced wrote one, and that is how the table filled with rows nobody configured.
- An empty date reaches the column as `NULL` rather than an epoch.
- A value written into a legacy fixed-width column comes back trimmed.
- A timestamp is stored in the zone every other row uses, not the server's.

### Happy-path, risk and development tests

**In a TypeScript project, every integration test is a happy-path, risk or development
test, named by its file:**

- **`*.happy.integration.test.ts` — a happy-path test:** the main success case of a core
  function, whatever it touches — a money function's happy-path test asserts the plain
  amount. The happy-path audit (`/happy-path`) decides which functions are core and writes
  these.
- **`*.integration.test.ts` — a risk test:** a case that touches the risk list below — one
  a sensible later change could break without anyone noticing — and the one main success
  case a function of a risky shape keeps when none of its other cases is a risk test (below).
- **`*.dev.integration.test.ts` — a development test:** checks the function's own logic, so
  it catches a wrong change while the code is being worked on. It runs while its code
  changes, never in the full suite. It lives beside the integration test file it came from,
  where the project's integration tests already live — never beside the source it tests.

**A Python project keeps one integration tier**, every test in it judged by the same
criteria as below.

**The full suite is the happy-path tests and the risk tests.** CI runs it on every PR —
on GitHub Actions, or in the project's CodeBuild test project when `TEST_RUNNER` is `aws` —
and `/deploy` on `main`, each skipping when the code has the same fingerprint as at a pass.
A development test runs at `/commit` when the change reaches it. Run one by name with
`INTEGRATION_DEV_TESTS=1 npm test -- --project integration <file or pattern>`.

**Write a risk test for each case that touches the risk list,** one per distinct risky
behaviour, not one per conceivable input:

- **Money math** — an amount the code computes: a sum, a fee rate, rounding, proration. A
  zero or a missing amount is not money math.
- **Dates, time zones or period boundaries.**
- **Permissions.**
- **Data integrity** — a write that could corrupt, duplicate or orphan data that other code
  or another application reads: a duplicate where one must be unique, a write left
  half-done, a write landing on the wrong record. A function that writes nothing when it
  refuses, or leaves other columns alone, is checking its own logic: a development test.
- **Concurrency or locking.**
- **A contract with another system** — the shape, protocol or encoding the other system
  requires, asserted against its real format. A case where that system is mocked tests a
  branch.
- **Code many others depend on.**
- **A fixed bug**, under the line below.

A filter, a join, an aggregate or a date range alone puts nothing on the list — a case
that asserts a period boundary itself is on it. Every other integration test written
outside `/happy-path` is a development test, except the one main success case below.

**A fixed bug gets a risk test only when a competent developer making a sensible later
change could plausibly bring it back** — the fix rests on a database quirk, a protocol
detail, a boundary or another system's contract. A plain mistake — a typo, a misread
requirement, the wrong variable — gets a development test.

**Shared code is tested once, in the shared module; an app tests only what it adds.** An
app test of an app function that only passes the call through to a shared-module function —
forwarding it, perhaps reshaping the arguments — that asserts nothing the shared module's
own test of that function does not, is a duplicate: delete it. What the app adds on top —
its own inputs, checks or output shape — is judged on its own.

**Unit tests are not sorted into kinds;** every unit test runs in every run.

### Which database code needs a test

**Database code of a risky shape needs at least one happy-path or risk test that calls
it,** whenever `DB_ENGINE` is anything but `None`, undeclared included, unless every gate
below is declared off. The risky shapes: raw SQL, a join, a filter beyond a lookup by key, an
aggregate or grouping, a date range, an upsert, a transaction, more than one write. Thin
code — a plain insert, a select by key — needs none. A development test does not count:
it is not in the full suite.

**The shape decides only that one test is kept, never the kind of any other case.** When no
happy-path test calls a risky-shape function and none of its cases touches the risk list,
its main success case is that test:
filed as a risk test, it counts as one until `/happy-path` decides whether the function is
core. One case per function, no more — the function's other cases follow the risk list.

**A test calls the app's code.** It imports the function it tests from the app's source and
calls it. A test that imports nothing from the app's source, or runs its own copy of the
logic it claims to test, is rewritten to call the app's function — the case was worth
testing, the test was wrong. Delete it only when there is no app code for it to call.

An integration test:

- runs inside a transaction the harness always rolls back (`dbTest`);
- inserts the rows its assertions depend on, with ids reserved for tests, except stable
  reference data it reads;
- calls the real function, handing it the test's transaction;
- runs on a throwaway database per run where the engine allows one, else on the source the
  engine rule names.

**Stable reference data** is what the business does not edit: a catalog's structure, a
device's capabilities, a legacy code table. **Never assert a value the business changes day
to day** — a price, a whole-table count, a record users edit: insert
that row yourself, or assert a property of it rather than an exact figure.

**Only new and changed code is judged** — a function when any line of its declaration
changed, a test file when it changed. `scripts/check-integration-coverage.mjs` measures
from where the branch left `main`; editing an untested risky function means writing its
test in the same change. Untouched code is counted, never failed.

**Who checks what:**

- `scripts/check-integration-coverage.mjs`, at `/commit` and `/ship-main`: a changed
  function of a risky shape that no happy-path or risk test calls, and a changed
  integration test file that imports nothing from the app's source.
- The test judge — a headless review `/commit` and `/ship-main` run (`test-review.sh`),
  not you. Its findings stop the commit, and the developer acts on each by its kind:
  - `missing` — a risky case no test proves: write the test.
  - `reimplements` — a test that imports nothing from the app or runs its own copy of the
    logic: rewrite it to call the app's function.
  - `superfluous` — the ORM working, or a duplicate of another test, a shared function
    re-tested through a pass-through wrapper included: delete it, never rename it a
    development test.
  - `misnamed` — a test of the wrong kind for its file name: rename or move it as the
    fix says.
- The happy-path audit: which tests are happy path.

**The gates:** `/commit` and `/ship-main` run the coverage check and the integration tests
whose imports reach the change (`vitest related`), development tests included. CI runs
the full suite and fails when integration tests exist and did not run — development tests
do not count as existing for that check. `/deploy` runs the full suite before it bumps, where
`TEST_RUNNER` points. Under `ASSURANCE_LEVEL` `strict` it never runs the suite on the
deploying machine: with `TEST_RUNNER` `github` and no recorded pass it refuses; with `aws`
it starts a CodeBuild run on `main`'s HEAD, whose pass is a trusted record. Under `strict`,
`INTEGRATION_DEPLOY_OFF` excuses nothing.
Each gate skips when the code has the same fingerprint as at a pass — identical apart from
comments and whitespace, tool-directive comments counting as code — and says so.

**Turning a gate off is the project owner's decision, declared with its reason** —
`INTEGRATION_COMMIT_OFF`, `INTEGRATION_CI_OFF` or `INTEGRATION_DEPLOY_OFF` in
`.claude/sync-substitutions.json`, where the value is the reason. A gate still on still
requires the tests. Never set one on your own judgment; ask.

**`TEST_RUNNER` and `ASSURANCE_LEVEL` in `.claude/sync-substitutions.json` are the project
owner's decision too** — never set either on your own judgment. A developer's own
`TEST_RUNNER=` line in `.env` overrides the project's for them, on their machine: kit
default, then the project, then `.env`. `ASSURANCE_LEVEL` is the project's alone; `.env`
does not change it.

**The coverage check reads TypeScript only.** In a Python project the rules above still
apply to its one integration tier; CI's pytest and `/deploy`'s `uv run pytest` run its tests.

### It changes how the code is shaped

**A data function takes its connection as a parameter.** The harness runs each test inside
a transaction it always rolls back and hands that transaction in; a function that resolves
its own connection cannot ride it, so it cannot be tested at all and nothing will say so
until someone tries.

```ts
// Testable: the caller supplies the connection.
export function readThing(db: Db, id: number) { … }

// The request-bound wrapper. The auth boundary lives HERE, never in the query —
// a boundary is about the request, and a query has no request.
export async function getThing(id: number) {
  await requireSession();
  return readThing(connectionForRequest(), id);
}
```

Discovering this at test-writing time means a refactor. Write it this way first.

## Running the suite

These apply whenever you DO run tests, on either path above. They do not authorize a run.

**Run `npm test` from the repository root.** The standard shape is a root `test` script delegating to the shared vitest config, with `npm test -- --project unit` when you want unit only. Config, fixtures and tooling paths resolve relative to the root — notably the Drizzle config file, which the integration `globalSetup` shells out to. Run `npx vitest` from inside a workspace and it dies in setup hunting a config that is not at that path, which looks like a broken suite when it is only mis-invoked.

A project on a different stack runs whatever its own `package.json` or Makefile declares. The root-invocation rule never changes.

**Before calling a suite blocked, run it the canonical way, read the actual error, quote it to the human, and name the specific cause.** A failure in global or session setup is a mis-invocation until proven otherwise. An inferred blocker is a fabricated one.

### Running the integration suite

**The engine rule names the integration tests' database** — `postgres-drizzle.md` or
`sqlserver-drizzle.md`; on `Other`, the project's `rules/project/`. Check the engine first:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

**Confirm the integration project actually ran.** On PostgreSQL it is dropped when it
cannot reach its database — when `NEON_API_KEY` or `NEON_PROJECT_ID` is missing from `.env`
— and `npm test` still exits green. On SQL Server it is dropped only in CI with
`INTEGRATION_CI_OFF` declared: a missing `DB_*` key makes the harness refuse and the run
fail, saying which keys to set. Run it as `NO_COLOR=1 npm test` and read the per-file
output for `|integration|` labels — with colour on, vitest prints each label as a badge
with no `|` around it. A run with none means integration did not run — say so and name
the missing credential rather than reporting a pass.

**On PostgreSQL, run the integration suite: it cannot touch production.** Each run
provisions its own throwaway Neon branch forked from production, migrates it, points
`DATABASE_URL` at that branch before any worker spawns, and deletes it in teardown. Every
write lands on the disposable copy; the fork is a read. The DB guard covers migration
commands invoked from the shell, not the migrate inside the harness.

**On SQL Server, run the integration suite: it refuses any server not marked as a test
target.** Every test runs in a snapshot transaction on the development database that is
always rolled back. When the harness refuses — unmarked, offline, snapshot isolation off, a
migration missing — quote its message to the human; it names the fix, and applying a
migration is theirs to approve (`sqlserver-drizzle.md` §V).

**Never skip or stall a test run over doubt about which database you are on.** On
PostgreSQL tests provision their own branch, and on SQL Server the harness checks the
server's mark, so the question does not arise; on PostgreSQL, `node scripts/db-branch.mjs`
gives the answer in one API call.
