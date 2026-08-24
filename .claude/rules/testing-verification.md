# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how the session was launched. A background job with a human watching is still interactive.

## Interactive sessions

The human drives testing. Run agent-browser, e2e flows, or any manual verification pass only when they explicitly ask ("test this", "verify it"). Announcing that you are about to verify is not permission, and the human starting a dev server is not an invitation to test against it.

Your job ends at build and static verification — typecheck, lint, build. Then hand off: state what is ready and exactly what a verification would need.

## Autonomous sessions

`autonomous-sessions.md` defines the mode. It is asserted by the human or by an unattended launch, never inferred.

In an autonomous session, verify your own work — drive agent-browser and the relevant e2e flows to completion. There is no one to defer to.

## Running the suite

These apply whenever you DO run tests, on either path above. They do not authorize a run.

**Run `npm test` from the repository root.** The standard shape is a root `test` script delegating to the shared vitest config, with `npm test -- --project unit` when you want unit only. Config, fixtures and tooling paths resolve relative to the root — notably the Drizzle config file, which the integration `globalSetup` shells out to. Run `npx vitest` from inside a workspace and it dies in setup hunting a config that is not at that path, which looks like a broken suite when it is only mis-invoked.

A project on a different stack runs whatever its own `package.json` or Makefile declares. The root-invocation rule never changes.

**Before calling a suite blocked, run it the canonical way, read the actual error, quote it to the human, and name the specific cause.** A failure in global or session setup is a mis-invocation until proven otherwise. An inferred blocker is a fabricated one.

**Confirm the integration project actually ran.** The vitest config drops it silently when `NEON_API_KEY` or `NEON_PROJECT_ID` is missing from `.env`, and `npm test` still exits green. Read the summary for `|integration|` labels in the per-file output, and for a duration in tens of seconds rather than about one. A short run with no labels means integration did not run — say so and name the missing credential rather than reporting a pass.

**Run the integration suite. It cannot touch production.** Each run provisions its own throwaway Neon branch, migrates it, points `DATABASE_URL` at that branch before any worker spawns, and deletes it in teardown. Every test runs inside a rolled-back transaction. It costs about a cent a run.

The branch is forked from production, which is why the data is real — but every write lands on the disposable copy, and the fork is a read. The DB guard covers migration commands invoked from the shell, not the migrate inside the harness, so it is not a reason to skip either.

**Never skip or stall a test run over doubt about which database you are on.** That doubt has cost whole sessions. Tests provision their own branch, so the question does not arise; and where you genuinely need the answer, `node scripts/db-branch.mjs` gives it in one API call rather than an assumption.
