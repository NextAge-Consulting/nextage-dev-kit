# Testing & Verification

Who runs tests depends on whether a human is available to hand off to — not how
the session was launched (a background job with a human watching is still
interactive).

## Interactive sessions — the human drives testing

- Do NOT run agent-browser, e2e flows, or any manual verification pass unless the
  human explicitly asks ("test this", "verify it"). Announcing that you're about
  to verify is NOT permission — wait for the ask.
- Your job ends at build + static verification (typecheck, lint, build). Then
  hand off: state what's ready and exactly what a verification would need, and
  let the human run it.
- The human starting a dev server is not an invitation to test against it.

## Autonomous sessions — the AI must self-verify

- **`autonomous-sessions.md` defines the mode**, and it is asserted by the human
  or by an unattended launch — never inferred from silence or from the size of
  the task. Do not decide it here.
- In an autonomous session the AI MUST verify its own work — drive agent-browser
  and the relevant e2e flows to completion. The interactive restriction above
  does not apply; there is no one to defer to.

## Running the suite (Zero Tolerance)

These apply whenever you DO run tests, on either path above.

### `npm test`, from the repo root. Never `npx vitest` from a workspace.

The standard shape is a root `test` script delegating to the shared vitest
config, e.g. `"test": "vitest run -c apps/shared/vitest.config.ts"`, with
`npm test -- --project unit` when you deliberately want unit only.

Run it from the **repository root**, always. Config, fixtures and tooling paths
resolve relative to the root — notably `drizzle.config.ts`, which the integration
`globalSetup` shells out to. `cd` into a workspace and run `npx vitest` there and
it dies in setup hunting a config that isn't at that path, which looks exactly
like a broken suite when it is only mis-invoked.

A project on a different stack runs whatever its own `package.json` / Makefile
declares — the root-invocation rule is the part that never changes.

### Never report a suite as "blocked" without quoting the error

A failure in global/session setup is **you invoked it wrong** until proven
otherwise. Before telling the human a suite cannot run:

1. Run it the canonical way, from the repo root.
2. Read the actual error text. Quote it to the human.
3. Name the specific cause.

**An inferred blocker is a fabricated one.** "That suite is gated behind <hook /
policy / credential> so I skipped it" — where the thing was never actually
checked — reads as diligence while silently dropping coverage. If a suite truly
cannot run, the reason is a quotable error message, never an inference.

### Confirm the integration project actually RAN — it drops SILENTLY

The vitest config gates the integration project on the Neon credentials:

```ts
projects: hasNeonCreds ? [unitProject, integrationProject] : [unitProject]
```

When `NEON_API_KEY` or `NEON_PROJECT_ID` is absent from `.env`, **the integration
project is dropped from the run and `npm test` still exits green.** Nothing warns
you. A passing run is NOT evidence that integration tests ran.

So read the summary before claiming the suite passed. The tells:

- **`|integration|` labels** in the per-file output. No labels, no integration.
- **Duration.** Unit-only finishes in about a second; a run that provisions a
  database branch takes tens of seconds.

Short run → say so plainly and name the missing credential. Do not report it as
a pass.

A project without Neon simply has no integration project to drop, and this
section costs it nothing.

### The integration suite is SAFE — run it

`test/globalSetup.ts` forks ONE ephemeral Neon branch from production per run,
migrates it, points `DATABASE_URL` at it before any worker spawns, and deletes it
in teardown — with a short `expires_at` as the crash backstop. Each test runs in
a rolled-back transaction, so parallel tests are MVCC-isolated. Production is
never written. It costs about a cent a run.

**The DB guard does not apply, and is not a reason to skip it.**
`block-db-commands.sh` guards `drizzle-kit` invoked as a *Bash command* — schema
changes run on the AI's judgment against a real database. The migrate inside
`globalSetup` is an `execSync` within the harness against a throwaway branch. The
hook never sees it and shouldn't. Constitution §V governs changing the real
schema, not running tests.

Because the branch forks production, this suite sees REAL data — which makes it
the only place a whole class of defect is reachable at all: a lookup or reference
table drifting from what the field actually reports, a catalog missing a row a
live device depends on. A fixture-based unit test asserts against a copy, so it
can only ever prove the copy is self-consistent. Skipping integration skips
exactly the coverage nothing else provides.
