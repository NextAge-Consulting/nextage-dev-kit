---
name: primary-route-tests
description: Where an app's primary-route tests live, what one tests, and the snapshot that measures how far the app has moved since its primary routes were chosen. Use when writing, moving or deleting a `*.primary.integration.test.ts`, when running `/primary-route-audit`, or when `/open-pr` warns that an app has no primary-route tests or has drifted.
user-invocable: false
---

# Primary-Route Tests

**A primary-route test is a sanity test of one of an app's primary routes, from the backend** —
the e2e suite's idea without the browser. Risk tests cover what is risky; primary-route tests
cover the gaps that leave, by proving the app's main jobs still work.

**A primary route is tested through the server functions it calls.** Each of those gets one
primary-route test asserting its main success case, whatever it touches — a money function's
asserts the plain amount. Nothing else goes in a primary-route file: an edge case, a boundary
or a denial that touches the risk list is a risk test; any other is a development test
(`testing-verification.md`). A function of a risky shape that `/primary-route-audit` has not yet
looked at may hold its main success case in a risk test, as the one case that shape keeps;
once a primary route is found to call it, that case moves here.

**The primary routes are agreed with the developer in `/primary-route-audit`, never picked by you
alone.** Nothing records them as a list: the primary-route tests are the outcome. Write a
primary-route test only inside that command. The one exception is the `integration-test-kinds`
migration's first sort of existing tests, which `/primary-route-audit` then keeps, moves to risk or
development tests, or deletes.

**Staleness is measured from the snapshot, not the tests.** The snapshot is the app's
routes, server functions and tables at the moment its primary routes were agreed. Once a
quarter of them are new or gone, `/open-pr` says it is time to agree them again.

## Where they live

- **An app's** go in `<app>/test/primary-routes/`; which folders are units is what
  `drift.mjs units` lists.
- **The shared module's** go in `<SHARED_MODULE_DIR>/test/primary-routes/` — a function in the
  shared module is tested there once, never from each app that calls it.
- **Each file is named `<subject>.primary.integration.test.ts`** and is an integration test
  like any other: `dbTest`, inserting the rows its assertions depend on — it may read
  stable reference data — and the real function handed the test's transaction
  (`testing-verification.md`).
- **`snapshot.json` sits beside them**, written by the script below and tracked in git. Never
  edit it by hand.

## The script

`node .claude/skills/primary-route-tests/scripts/drift.mjs` — its header documents every mode:

- `units` — every app and the shared module.
- `inventory <unit>` — the unit's routes, server functions and tables, each with the files
  using it, the foreign keys pointing at a table, and the fix commits that touched it.
- `snapshot <unit>` — writes `test/primary-routes/snapshot.json`.
- `check [<unit>…]` — each unit's standing: `ok`, `none`, `unsnapshotted`, `drifted`,
  `unreadable` or `unmeasured` — a unit with nothing the script recognises, whose staleness
  it cannot measure. `/open-pr` runs it on the units a PR touches.
