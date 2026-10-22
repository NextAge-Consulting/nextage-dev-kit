# Migration: the kit's SQL Server integration harness

`/sync-dev-kit` runs everything below the line in the consumer project's session, after it has applied the kit version that ships `templates/testing/sqlserver/`.

## Estimate

Kind: asks for decisions — each database setting or migration the harness asks for, which you apply yourself
Your time: about 5 minutes for each; none when the development database is already set up and marked.

Blast radius:

```bash
jq -r '"DB_ENGINE=\(.DB_ENGINE // "") SHARED_MODULE_DIR=\(.SHARED_MODULE_DIR // "")"' .claude/sync-substitutions.json
S=$(jq -r '.SHARED_MODULE_DIR // ""' .claude/sync-substitutions.json)
git ls-files "$S/test"
```

Any `DB_ENGINE` but `SQLServer`, or an empty `SHARED_MODULE_DIR`: it does not apply. Otherwise each file listed that the kit's harness does not ship is the project's own, and is either kept as a helper or replaced by the kit's. Reach is the shared module's `test/` folder and the root `package.json`.

---

Move this project's SQL Server integration tests onto the kit's harness. Work through every section to the end. Make no git commits — leave everything uncommitted for me to review. Never apply a database migration and never change a database's settings: put each one the harness asks for to me.

Run every command from the repository root, setting these in each shell:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
S=$(jq -r .SHARED_MODULE_DIR .claude/sync-substitutions.json)
FILES="globalSetup.ts integration-helpers.ts harness.integration.test.ts integration-target.ts mssql-connection.ts mssql-connection.test.ts"
```

## Whether it applies

When `jq -r .DB_ENGINE .claude/sync-substitutions.json` is not `SQLServer`, or `$S` is empty, say so in the report and stop here.

Read `$KIT/project-documentation/testing.md` §1, `.claude/rules/sqlserver-drizzle.md` §V and `$S/test/define.ts`.

## Baseline

Check out the last commit's tests into a scratch worktree and run them there, so the baseline is the project before this sync:

```bash
git worktree add --detach "$(mktemp -d)/baseline" HEAD
```

In it, run `npm ci` and `npm test`, and keep the test files and tests per vitest project, and whether `|integration|` ran. Remove the worktree with `git worktree remove` when done.

## Recover what this project built itself

The sync has already applied, or offered, the kit's files in `$S/test/`. The project's own versions are in the last commit. For each kit file name, and for every other file in `$S/test/` and the root `package.json`:

```bash
for f in $FILES; do git show "HEAD:$S/test/$f" > /dev/null 2>&1 && git diff HEAD -- "$S/test/$f"; done
git diff HEAD -- "$S/test/project.ts" package.json
```

Also find, in the last commit, the project's own versions under other names: a module checking the database before tests run, a connection-string builder or `varchar` registration the test files import, an `integration` project in `test/project.ts`'s `vitestProjects`, and the `test:preflight` script. A file of the project's that is in neither the last commit nor on disk is lost: report it.

## Move every difference out, before taking the kit's files

Write each difference into its home now. Nothing below this section starts until every one has a home or a line in the report.

| The difference is… | It goes to |
|---|---|
| Where a developer reads how to set up and mark the development database | `integrationDatabase.setupDoc` in `test/project.ts` |
| A migration folder and the command that applies it | `integrationDatabase.migrations`, one entry per folder; `table` when its migrations are recorded somewhere other than `drizzle.__drizzle_migrations` |
| Integration test files outside the shared module's `test/` | `integrationInclude` |
| A further `.env` key the tests read | `envKeys` |
| An `integration` project in `vitestProjects`, and the code deciding when it runs | Removed — the kit's `vitest.config.ts` registers it, and leaves it out of CI when `INTEGRATION_CI_OFF` is declared |
| A helper of the project's own in its `integration-helpers.ts` or harness test — a domain fake, a test on its own tables | A file of its own beside `test/project.ts`, importing the kit's `dbTest` |
| Connection keys named other than `DB_SERVER`, `DB_PORT`, `DB_DATABASE`, `DB_USER`, `DB_PASSWORD`, `DB_ENCRYPT`, `DB_TRUST_SERVER_CERTIFICATE` | Rename them in `.env` and wherever the project reads them; when the app must keep its names, report it as a kit gap |
| A login method other than SQL user and password, a check before tests the kit's `integration-target.ts` lacks, extra logic in the old `test:preflight`, or any other fix to the harness itself | A kit gap: leave the kit's file as it is, list the difference in the report with the code it came from, and carry on |

The project's own connection-string builder and `varchar` registration under `src/` stay: the app's handles use them (`sqlserver-drizzle.md` §II).

## Take the kit's files

Apply every one the sync's offer left out; applying one already in place changes nothing:

```bash
for f in $FILES; do bash .claude/scripts/sync-dev-kit.sh --apply-file "_claude-project/templates/testing/sqlserver/$f"; done
```

Then:

- delete the project's own files the recovery found that the kit's now replace, and repoint every import that used them at the kit's names;
- remove the integration entry from `test/project.ts`'s `vitestProjects`, with whatever only that entry used;
- set the root `package.json`'s `test:preflight` to `vitest run -c <SHARED_MODULE_DIR>/vitest.config.ts --project integration <SHARED_MODULE_DIR>/test/harness.integration.test.ts`.

## Prove it

Run `npm run test:preflight`. When it refuses, follow `sqlserver-drizzle.md` §V for what it names: a database setting or a migration to apply goes to me with the exact statement or command, and you run it again once I have done it. When `|integration|` did not run at baseline, this is the step that unblocks it.

Then run `npm test`, `npm run check-types` and `npx biome lint`, and fix every failure, including one the baseline already had. Every baseline test still runs — under its new file where it moved — and the kit's harness and connection-string tests are added.

## Report

- whether the migration applied, and if not, why;
- every difference found, and where it went;
- every kit gap, with the code it came from;
- the files deleted, and the imports repointed;
- each refusal `test:preflight` gave, and what it needed from me;
- `npm test` at baseline and after, per vitest project, with each moved test's new file;
- each check's result;
- anything you could not resolve.
