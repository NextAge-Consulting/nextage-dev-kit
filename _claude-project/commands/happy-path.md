---
description: Hand-run audit, with the developer, of what one app's core is — then the happy-path tests that cover it and the snapshot that tells /open-pr when to ask again. Never a gate.
argument-hint: "<app folder | shared module folder>"
---

# /happy-path

$ARGUMENTS

Run only when the human asks for it, or answers yes after `/open-pr` warned about the app.
The conventions — where the tests live, what one tests, the script — are the `happy-path`
skill (`.claude/skills/happy-path/SKILL.md`); read it first.

**One unit per run.** With no argument, list the units and ask which:

```bash
node .claude/skills/happy-path/scripts/drift.mjs units
```

## 1. Rank the core

```bash
node .claude/skills/happy-path/scripts/drift.mjs inventory <unit>
```

Read the code behind every server function and table it lists, then rank what this unit
exists to do. Weigh:

- **Reach** — `usedIn` and `foreignKeys`: what the most code and the most tables depend on.
- **Money** — anything that charges, prices, invoices, pays or refunds.
- **Access** — sign-in, sessions, roles and permissions.
- **Bug history** — `fixCommits`: where fixes keep landing.

**Navigation is never a signal** — how often a screen is visited or linked says nothing
about what breaks the business. Usage telemetry counts only when the developer offers it in
this session; never go looking for it.

A route is core only through what it calls. For the shared module, rank by what the apps
depend on.

## 2. Settle it with the developer

Present the ranked core in plain words — what each function does for the people using the
app and why it ranks there, never its file path alone — and the existing happy-path tests
under the unit's `test/happy-path/`, each marked as covering a function in the proposed core
or not.
Ask for corrections in prose and wait (`asking-questions.md`). Their list is the core.

## 3. Bring the tests into line

- **Every core function without one gets a happy-path test**: its main success case, and
  only that. A function in the shared module is tested in the shared module's folder.
- **A core function whose main success case sits in a risk test** — the one case its risky
  shape keeps (`testing-verification.md`, "Which database code needs a test") — has that
  case moved into `test/happy-path/` as its happy-path test, never copied.
- **A core table or route is covered through the server functions that read or write it** —
  each of those gets the happy-path test.
- **A core function that needs no database gets no happy-path file** — its unit tests run in
  every run.
- **A core function that resolves its own connection is reshaped first** to take its
  connection as a parameter (`testing-verification.md`, "It changes how the code is
  shaped"), as ordinary work in this run, then gets its happy-path test.
- **A happy-path test of a function of a risky shape that is no longer core**, when no risk
  test calls the function, moves to `<subject>.integration.test.ts` beside the unit's other
  integration tests: it is the one case the shape keeps.
- **Any other happy-path test of something no longer core** is kept as a development test only when
  it checks the function's own logic — it would catch a wrong change while the code is being
  worked on — and deleted otherwise. A kept one moves out of `test/happy-path/` to
  `<subject>.dev.integration.test.ts` beside the unit's other integration tests, never
  beside the source it tests. Say which, per file.
- **Every file you leave runs in the integration project.** `integrationInclude` in
  `<SHARED_MODULE_DIR>/test/project.ts` decides it; unset, it is the kit default
  `<SHARED_MODULE_DIR>/test/**/*.integration.test.ts`, and setting it replaces that default,
  so keep that glob in the list you set. Its globs must cover
  `<app>/test/happy-path/*.happy.integration.test.ts`; add one when they do not. A
  development test beside the unit's other integration tests is already covered.
- **Every file you leave is type-checked.** When the unit's `tsconfig.json` does not
  include `test/happy-path/` — an app's often includes only `src/` — add the folder to its
  `include`, and run the unit's `check-types`.
- **A `vi.mock` call stays in each test file that needs it.** Vitest hoists it only within
  its own file; one placed in a shared helpers file mocks nothing, and the test reaches the
  real dependency. The stand-in itself may live once in a helpers file the factory imports.

Run the tests you wrote and fix them until they pass (`testing-verification.md`, "Running
the suite").

## 4. Write the snapshot

```bash
node .claude/skills/happy-path/scripts/drift.mjs snapshot <unit>
```

Last, after the tests pass — it is the record `/open-pr` measures drift from.

## Report

The core as agreed, each function reshaped, each test written, moved to a development test
or deleted, `integrationInclude` before and after, each tsconfig whose `include` gained the
folder, the test run's result, and the
snapshot's path.
