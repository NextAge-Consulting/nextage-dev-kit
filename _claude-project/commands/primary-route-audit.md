---
description: Hand-run, with the developer — agree one app's primary routes, give each a primary-route sanity test from the backend, and write the snapshot that tells /open-pr when to ask again. Never a gate.
argument-hint: "<app folder | shared module folder>"
---

# /primary-route-audit

$ARGUMENTS

Run only when the human asks for it, or answers yes after `/open-pr` warned about the app.
The conventions — where the tests live, what one tests, the script — are the
`primary-route-tests` skill (`.claude/skills/primary-route-tests/SKILL.md`); read it first.

**Give each of the unit's primary routes — the jobs it exists to do — a sanity test from the
backend, covering the gaps the risk tests leave.**

**One unit per run.** With no argument, list the units and ask which:

```bash
node .claude/skills/primary-route-tests/scripts/drift.mjs units
```

## 1. Find the primary routes

```bash
node .claude/skills/primary-route-tests/scripts/drift.mjs inventory <unit>
```

Read the code behind every route, server function and table it lists, then propose the
routes this unit exists to serve. Weigh:

- **Reach** — `usedIn` and `foreignKeys`: what the most code and the most tables depend on.
- **Money** — anything that charges, prices, invoices, pays or refunds.
- **Access** — sign-in, sessions, roles and permissions.
- **Bug history** — `fixCommits`: where fixes keep landing.

**Navigation is never a signal** — how often a screen is visited or linked says nothing
about what breaks the business. Usage telemetry counts only when the developer offers it in
this session; never go looking for it.

For the shared module, propose the shared functions the apps' primary routes depend on.

## 2. Agree them with the developer

Present the proposed primary routes in plain words — what each does for the people using
the app and why it is on the list, never a file path alone — with the server functions each
calls, and the existing primary-route tests under the unit's `test/primary-routes/`, each marked
with the primary route it covers, or none.
Ask for corrections in prose and wait (`asking-questions.md`). What they agree is what gets
tested; keep no list of it.

## 3. Write the sanity tests

- **Every server function a primary route calls, without a primary-route test, gets one**: its
  main success case, and only that. A function in the shared module is tested in the
  shared module's folder, once.
- **A function whose main success case sits in a risk test** — the one case its risky shape
  keeps (`testing-verification.md`, "Which database code needs a test") — has that case
  moved into `test/primary-routes/` as its primary-route test, never copied.
- **A function that needs no database gets no primary-route file** — its unit tests run in
  every run.
- **A function that resolves its own connection is reshaped first** to take its connection
  as a parameter (`testing-verification.md`, "It changes how the code is shaped"), as
  ordinary work in this run, then gets its primary-route test.
- **Every file you leave runs in the integration project.** `integrationInclude` in
  `<SHARED_MODULE_DIR>/test/project.ts` decides it; unset, it is the kit default
  `<SHARED_MODULE_DIR>/test/**/*.integration.test.ts`, and setting it replaces that default,
  so keep that glob in the list you set. Its globs must cover
  `<app>/test/primary-routes/*.primary.integration.test.ts`; add one when they do not. A
  development test beside the unit's other integration tests is already covered.
- **Every file you leave is type-checked.** When the unit's `tsconfig.json` does not
  include `test/primary-routes/` — an app's often includes only `src/` — add the folder to its
  `include`, and run the unit's `check-types`.
- **A `vi.mock` call stays in each test file that needs it.** Vitest hoists it only within
  its own file; one placed in a shared helpers file mocks nothing, and the test reaches the
  real dependency. The stand-in itself may live once in a helpers file the factory imports.

### A primary-route test no primary route needs any more

Each primary-route test that covers nothing on the agreed routes:

- **Of a function of a risky shape that no risk test calls** — moves to
  `<subject>.integration.test.ts` beside the unit's other integration tests: it is the one
  case the shape keeps.
- **Any other** — kept as a development test only when it checks the function's own logic —
  it would catch a wrong change while the code is being worked on — and deleted otherwise.
  A kept one moves out of `test/primary-routes/` to `<subject>.dev.integration.test.ts` beside
  the unit's other integration tests, never beside the source it tests. Say which, per file.

Run the tests you wrote and fix them until they pass (`testing-verification.md`, "Running
the suite").

## 4. Write the snapshot

```bash
node .claude/skills/primary-route-tests/scripts/drift.mjs snapshot <unit>
```

Last, after the tests pass. It records the unit's routes, server functions and tables as
they are now, and `/open-pr` measures staleness from it.

## Report

The primary routes as agreed, each function reshaped, each test written, moved to a risk
or development test or deleted, `integrationInclude` before and after, each tsconfig whose
`include` gained the folder, the test run's result, and the snapshot's path.
