# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how the session was launched. A background job with a human watching is still interactive.

## Interactive sessions

The human drives testing. Run agent-browser, e2e flows, or any manual verification pass only when they explicitly ask ("test this", "verify it"). Announcing that you are about to verify is not permission, and the human starting a dev server is not an invitation to test against it.

Your job ends at build and static verification — typecheck, lint, build. Then hand off: state what is ready and exactly what a verification would need.

## Autonomous sessions

`autonomous-sessions.md` defines the mode. It is asserted by the human or by an unattended launch, never inferred.

In an autonomous session, verify your own work — drive agent-browser and the relevant e2e flows to completion. There is no one to defer to.

## Which tier a test belongs in

**The test is written in the same change as the code it covers**, unit and integration
alike. Not afterwards, not in a follow-up.

**A tier with no tests in it yet is not a reason to skip.** The first test in a project
establishes the pattern; writing it is ordinary work, not a decision needing sign-off.
"There is no precedent, so I won't invent one" is avoidance wearing the clothes of
prudence — see `working-discipline.md`.

### The bar

**Would a mock have to invent the answer?**

- **No — the answer is in the code.** Unit test. Formatting, parsing, validation, a
  branch, a calculation, which of two paths a value takes.
- **Yes — the answer comes from the database.** Integration test. Collation, column
  types and widths, `NULL` against empty string, defaults, unique and foreign-key
  constraints, generated ids, what a real join returns over real data shapes, what a
  stored timezone does.

**"It saved the row" and "it read back what I wrote" are the ORM working.** Neither is a
test of your code, and asserting them costs a database round trip to learn nothing. If you
cannot name what would be WRONG without the test, delete it.

Worked examples of a test that earns its place, each a real defect it would have caught:

- A lookup by one spelling finds a row the other application stored in another case —
  because the column collates case-insensitively.
- A missing setting returns its fallback **without writing a row** — because the system it
  replaced wrote one, and that is how the table filled with rows nobody configured.
- An empty date reaches the column as `NULL` rather than an epoch.
- A value written into a legacy fixed-width column comes back trimmed.
- A timestamp is stored in the zone every other row uses, not the server's.

### The integration tier is required

**Every exported function whose body queries the database has an integration test that
calls it,** whenever `DB_ENGINE` is anything but `None`, undeclared included, unless every
gate below is declared off. A body queries when it reads a property of a
database handle — `db.select`, `tx.execute`, `pool.query` — whether the handle is a
parameter, an import or a call's result. A function that only passes a handle along does
not query.

An integration test:

- runs inside a transaction the harness always rolls back (`dbTest`);
- inserts the rows it needs, with ids reserved for tests, and never relies on existing data;
- calls the real function, handing it the test's transaction;
- runs on a throwaway database per run where the engine allows one, else on the source the
  engine rule names.

**A function no integration test can call carries `// integration-exempt: <reason>`
directly above it.** A function that resolves its own connection is not that case: give it
the connection as a parameter (below) and test it.

**Only new and changed functions are judged** — changed means any line of its
declaration. `scripts/check-integration-coverage.mjs` measures from where the branch left
`main`; editing an untested function means writing its
test in the same change. Untouched code is counted, never failed.

**The gates:** `/commit` and `/ship-main` run the coverage check and the integration tests
whose imports reach the change (`vitest related`). CI runs the full suite and fails when
integration tests exist and did not run. `/deploy` runs the full suite before it bumps.

**Turning a gate off is the project owner's decision, declared with its reason** —
`INTEGRATION_COMMIT_OFF`, `INTEGRATION_CI_OFF` or `INTEGRATION_DEPLOY_OFF` in
`.claude/sync-substitutions.json`, where the value is the reason. A gate still on still
requires the tests. Never set one on your own judgment; ask.

**The coverage check reads TypeScript only.** In a Python project the rule above still
applies; CI's pytest and `/deploy`'s `uv run pytest` run its tests.

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
