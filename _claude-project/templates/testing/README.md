# Vitest scaffolding — reference files

**NOT synced by `/sync-dev-kit`.** These files live under
`_claude-project/templates/testing/` intentionally so the `_claude-project/templates/*)
echo ""` fallthrough in `dest_for_kit_path()` skips them. Consumer projects
copy and adapt manually because test-directory layout is project-specific
(monorepo with `apps/shared/`, flat `src/`, `packages/<name>/`, etc.).

The pattern is documented at https://github.com/NextAge-Consulting/nextage-dev-kit/blob/main/project-documentation/HANDBOOK.md#1113-vitest-scaffolding-pattern--reference-files. These files are the reference
implementation.

## What's in this directory

| File | What it is | Where it lands in a consumer |
|---|---|---|
| `vitest.config.ts` | Node-env config; globals off; setupFiles wired; root pinned to config-file dir so `npm test` resolves include globs from repo root | Next to your test tree — `apps/shared/vitest.config.ts` for monorepos; `<module>/vitest.config.ts` for flat projects |
| `auth-mocks.ts` | Typed `MockAuthedUser` shape + `mockAuthedUser()` / `mockUnauthed()` stubs | `<test-dir>/auth-mocks.ts` |
| `test-utils.ts` | setupFile. Pins `process.env.TZ` (see constitution §VI + `feedback_db_is_cst` on projects that store in CST) — tune the TZ for your project. Exposes a deterministic UUID-v7-like helper. Re-exports auth mocks. | `<test-dir>/test-utils.ts` |
| `smoke.test.ts` | 4 assertions proving vitest picks up the config, runs the setup file, resolves module imports, runs assertions under node env | `<test-dir>/smoke.test.ts` |
| `globalSetup.ts` | Integration branch lifecycle. Forks the default (production) branch once per run, runs `drizzle-kit migrate` against it, sets `DATABASE_URL` before workers spawn; deletes the branch in `teardown`. Uses `@neondatabase/api-client`. | `<test-dir>/globalSetup.ts` |
| `integration-helpers.ts` | `dbTest(name, fn)` — the only DB entry point for integration tests. Runs `fn` in an always-rolled-back Postgres transaction on the run's shared branch, so parallel tests stay MVCC-isolated. Active only when `NEON_API_KEY` + `NEON_PROJECT_ID` are set (the `integration` project is absent otherwise). | `<test-dir>/integration-helpers.ts` |

## Copy-paste install

```bash
# 1. Install dependencies
npm install -D vitest @neondatabase/api-client pg

# 2. Create your test directory (path will vary per project)
mkdir -p apps/shared/test

# 3. Copy reference files. Substitute destination paths for flat projects.
#    Tests live at <shared-module>/test/ — SIBLING of src/, never under src/.
#    (See https://github.com/NextAge-Consulting/nextage-dev-kit/blob/main/project-documentation/HANDBOOK.md#1113-vitest-scaffolding-pattern--reference-files placement rationale.)
KIT=~/projects/nextage-dev-kit
cp "$KIT"/_claude-project/templates/testing/vitest.config.ts apps/shared/
cp "$KIT"/_claude-project/templates/testing/*.ts apps/shared/test/

# 4. Wire npm scripts (root package.json):
#    "test":       "vitest run -c apps/shared/vitest.config.ts"
#    "test:watch": "vitest -c apps/shared/vitest.config.ts"

# 5. Run
npm test   # expect 4 passing tests
```

## Monorepo-shared workspace wiring (pairs with this scaffolding)

If your shared module (e.g. `apps/shared/`) is consumed via tsconfig path
alias but is NOT a declared npm workspace, the root `npm run check-types
--workspaces --if-present` will NOT typecheck it. A real TS error there
can ship to main undetected. Close the gap:

1. Create `apps/shared/package.json`:
   ```json
   {
     "name": "@your-org/shared",
     "version": "0.0.0",
     "private": true,
     "type": "module",
     "scripts": { "check-types": "tsc --noEmit" }
   }
   ```
2. Add `"apps/shared"` to the root `package.json` `workspaces` array.
3. If using Vite and `import.meta.env.VITE_*` in shared code, create
   `apps/shared/src/vite-env.d.ts`:
   ```ts
   /// <reference types="vite/client" />
   ```
   This registers `ImportMetaEnv` globally so `import.meta.env.VITE_*`
   resolves when `tsc` runs standalone in `apps/shared`. Without it,
   standalone tsc fires TS2339 even though shop/dealer tsc loads vite
   types transitively via their own `vite.config.ts`.

See https://github.com/NextAge-Consulting/nextage-dev-kit/blob/main/project-documentation/HANDBOOK.md#1113-vitest-scaffolding-pattern--reference-files for full context.
