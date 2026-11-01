# Migration: rename happy-path tests to primary-route tests

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version that ships the `primary-route-tests` skill and the `/primary-route-audit` command. It applies to a project holding any `*.happy.integration.test.ts` file or `test/happy-path/` folder; any other project has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
find . -path ./node_modules -prune -o \( -name '*.happy.integration.test.ts' -o -name '*.happy.integration.test.tsx' -o -type d -name happy-path -path '*/test/*' \) -print | grep -v node_modules
rg -l --hidden --glob '!node_modules' --glob '!.git' --glob '!.claude/**' 'test/happy-path|\.happy\.integration' .
```

The first command lists the test files and folders it renames; the second, the project files that name them. Both empty: it does not apply.

---

Rename this project's happy-path tests to primary-route tests. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Record the suite before

Run `NO_COLOR=1 npm test` from the repository root and keep the number of test files and tests it reports, and the `|integration|` file count. A run that fails before anything is renamed is reported as it stands; carry on, and compare against it.

## 2. Rename

1. For each `test/happy-path/` folder, move it to `test/primary-routes/` beside it, `snapshot.json` included.
2. Rename every `<subject>.happy.integration.test.ts` (or `.tsx`) to `<subject>.primary.integration.test.ts`, wherever it sits.
3. In every project file the Estimate's second command names — `integrationInclude` in the shared module's `test/project.ts`, a tsconfig `include`, a doc, a script — replace `test/happy-path` with `test/primary-routes` and `.happy.integration` with `.primary.integration`. Leave `.claude/**` alone: the sync wrote it.
4. In the project's own documentation, call these tests primary-route tests and the command `/primary-route-audit`. A "happy path" that means an e2e flow stays.

## 3. Prove it

- `NO_COLOR=1 npm test` reports the same test files, tests and `|integration|` file count as step 1, with the same result.
- `node .claude/skills/primary-route-tests/scripts/drift.mjs check` reports each unit as before: a unit that had a snapshot is not `unsnapshotted`, and one that had tests is not `none`.
- Each unit whose tsconfig gained the folder passes its `check-types`.
- The Estimate's commands print nothing.

## Report

- each folder moved and file renamed;
- each project file edited;
- the suite counts before and after, and the drift check's output;
- anything you could not resolve.
