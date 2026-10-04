# Migration: kit-owned test scaffolding

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has scanned the kit version that ships `templates/testing/define.ts`. A project with `SHARED_MODULE_DIR` empty has no test scaffolding and needs none of it.

---

Bring this project's tests onto the kit's test scaffolding. The shared module's `vitest.config.ts` and every file in its `test/` that the kit ships are now the kit's; what differs about this project goes in `test/project.ts`, and the project's own helpers go in files of their own. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review.

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
T="$KIT/_claude-project/templates/testing"
S=$(jq -r .SHARED_MODULE_DIR .claude/sync-substitutions.json)
```

Read `$KIT/project-documentation/testing.md` §1 and `$T/define.ts` first.

## 1. Record the baseline

Run `npm test` from the repository root and keep the result: test files and tests per vitest project, and any failures. Step 6 must match it.

## 2. List every way this project's files differ from the kit's

```bash
diff "$T/vitest.config.ts" "$S/vitest.config.ts"
for f in globalSetup.ts integration-helpers.ts test-utils.ts auth-mocks.ts smoke.test.ts; do diff "$T/$f" "$S/test/$f"; done
```

Also find every other vitest config the project runs — a root `vitest.config.ts`, a workspace file, a `test` script pointing anywhere but `$S/vitest.config.ts`.

## 3. Move each difference to where it now lives

| The difference is… | It goes to |
|---|---|
| The timezone tests run in | `timezone` in `project.ts` |
| The schema import | `schema` |
| Test files outside the shared module's `test/`, or files kept out of the unit run | `unitInclude`, `unitExclude`, `integrationInclude` |
| A further vitest project — a UI package with its own environment | `vitestProjects` |
| An extra `.env` key the tests read | `envKeys` |
| A second database on the integration branch | `extraDatabases`, plus `export const <name>Test = dbTestOn("<ENV_VAR>")` in a helper file of the project's |
| Setup a fork of production needs before tests, such as re-keying data encrypted under a secret the tests lack | `afterMigrate` |
| The roles a test user holds, and the default | `roles` |
| Domain fakes, builders, a stub server, any helper the kit's files lack | A file of the project's own beside `project.ts`, e.g. `test/project-helpers.ts`; repoint the imports that used it |
| A fix to the harness itself, which every project would want | Stop and tell me — it goes into the kit |

A difference that fits no row goes to me, never back into a kit file.

## 4. Take the kit's files

```bash
for f in vitest.config.ts define.ts project.ts globalSetup.ts integration-helpers.ts test-utils.ts auth-mocks.ts smoke.test.ts; do
  bash ~/.claude/scripts/sync-dev-kit.sh --apply-file "_claude-project/templates/testing/$f"
done
```

Then write this project's settings into `test/project.ts`. Delete every other vitest config step 2 found, and point the root scripts at the kit's:

```
"test":       "vitest run -c <SHARED_MODULE_DIR>/vitest.config.ts"
"test:watch": "vitest -c <SHARED_MODULE_DIR>/vitest.config.ts"
```

## 5. Pin the versions the kit blesses

Run `node scripts/check-stack.mjs`. Wherever it names `vitest` or `@neondatabase/api-client`, install the blessed version exactly — `npm install -D --save-exact <name>@<version>` in the workspace that declares it — and run it again until it passes. A vitest major step can change test behaviour: read each failure before changing a test.

## 6. Prove it

Run `npm test` from the repository root. The per-file output carries `|integration|` labels and the run takes tens of seconds; a short run without them means integration did not run — name the missing credential. Test files and tests match step 1, project by project. Then run `npm run check-types` and `npx --no-install @biomejs/biome lint --max-diagnostics=none`, and fix every failure.

## Report

- every difference from step 2, and where it went
- the project's own helper files
- what went to me instead, and why
- the version changes check-stack required
- `npm test` before and after, per vitest project
- each check's result
