# Vitest scaffolding — kit templates

These files sync to consumer projects in **`template` mode**: the kit ships the
starting point, the **project owns the file**. A consumer may edit any of them
freely and `/sync-dev-kit` will never revert the edit.

Their destination comes from the `SHARED_MODULE_DIR` substitution, because test
layout is project-specific (`apps/shared` in a monorepo, `src` or `.` in a flat
repo, `packages/<name>` elsewhere):

| Kit file | Lands at |
|---|---|
| `vitest.config.ts` | `<SHARED_MODULE_DIR>/vitest.config.ts` |
| everything else | `<SHARED_MODULE_DIR>/test/<name>` |

A project with `SHARED_MODULE_DIR` empty has no shared test module, and these
files are skipped entirely rather than landing somewhere wrong.

**This README is kit-internal** — it is in `SKIP_LIST`, so it explains the
templates to someone reading the kit and never lands in a consumer's test
directory.

## How updates reach a project

| Project's copy | State on sync | What happens |
|---|---|---|
| untouched | `kit-only` | offered as a normal update |
| adapted | `template-drift` | the kit's delta is shown; the project decides |

A drift the user declines must be acknowledged with
`sync-dev-kit.sh --ack-file <kit-path>`, which advances the baseline without
writing the file. Without that, the same drift re-reports on every sync forever.
Ack is not permanent: the next kit change to that file surfaces again.

Full pattern, install steps and the integration model: HANDBOOK §11.13.

## What's in this directory

| File | Purpose |
|---|---|
| `vitest.config.ts` | Two projects — `unit` (parallel, no DB) and `integration` (present only when Neon credentials exist). Pins `root` to the config-file directory so `npm test` from the repo root resolves the include globs. |
| `globalSetup.ts` | Integration branch lifecycle. Forks the default (production) branch once per run, migrates it, sets `DATABASE_URL` before workers spawn, deletes it in teardown. Requires `@neondatabase/api-client` `^2.7.2` or later. |
| `integration-helpers.ts` | `dbTest(name, fn)` — the only database entry point for integration tests. Runs the body in an always-rolled-back transaction, so parallel tests on the one shared branch stay MVCC-isolated. |
| `auth-mocks.ts` | Typed `MockAuthedUser` plus `mockAuthedUser()` / `mockUnauthed()` stubs. |
| `test-utils.ts` | Setup file. Pins `process.env.TZ` (chosen per consumer) and exposes a deterministic UUID-v7-like helper. |
| `smoke.test.ts` | Four assertions proving vitest picks up the config, runs the setup file, resolves imports, and runs under the node environment. |

TypeScript diagnostics on these files inside the kit repo are expected — the kit
has no npm dependencies, so `vitest`, `process` and `@neondatabase/api-client`
do not resolve here. They resolve in the consumer, which is the only place these
files are meant to compile.
