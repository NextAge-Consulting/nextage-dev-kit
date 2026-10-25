---
name: happy-path
description: Where an app's happy-path tests live, what one tests, and the snapshot that measures how far the app has moved since its core was chosen. Use when writing, moving or deleting a `*.happy.integration.test.ts`, when running `/happy-path`, or when `/open-pr` warns that an app has no happy path or has drifted.
user-invocable: false
---

# Happy Path

**A happy-path test calls one core function of an app and asserts its main success case,**
whatever the function touches — a money function's asserts the plain amount. Nothing else
goes in a happy-path file: an edge case, a boundary or a denial that touches the risk list
is a risk test; any other is a development test (`testing-verification.md`). Until
`/happy-path` settles a function of a risky shape as core, its main success case may sit in
a risk test as the one case that shape keeps; settled core, it moves here.

**What is core is decided with the developer by `/happy-path`, never by you alone.** Write a
happy-path test only inside that command. The one exception is the `integration-test-kinds`
migration's first sort of existing tests, which `/happy-path` then keeps, moves to risk or development tests, or deletes.

## Where they live

- **An app's** go in `<app>/test/happy-path/`; which folders are units is what
  `drift.mjs units` lists.
- **The shared module's** go in `<SHARED_MODULE_DIR>/test/happy-path/` — a function in the
  shared module is tested there once, never from each app that calls it.
- **Each file is named `<subject>.happy.integration.test.ts`** and is an integration test
  like any other: `dbTest`, inserting the rows its assertions depend on — it may read
  stable reference data — and the real function handed the test's transaction
  (`testing-verification.md`).
- **`snapshot.json` sits beside them**, written by the script below and tracked in git. Never
  edit it by hand.

## The script

`node .claude/skills/happy-path/scripts/drift.mjs` — its header documents every mode:

- `units` — every app and the shared module.
- `inventory <unit>` — the unit's routes, server functions and tables, each with the files
  using it, the foreign keys pointing at a table, and the fix commits that touched it.
- `snapshot <unit>` — writes `test/happy-path/snapshot.json`.
- `check [<unit>…]` — each unit's standing: `ok`, `none`, `unsnapshotted`, `drifted` or
  `unreadable`. `/open-pr` runs it on the units a PR touches.
