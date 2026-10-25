# Migration: sort the existing integration tests into happy-path, risk and development

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has applied the kit version whose `rules/testing-verification.md` splits integration tests into happy-path, risk and development tests. It does not apply when `DB_ENGINE` is `None`, or when the project has no integration test case to judge — none in any integration test file besides the kit's own `harness.integration.test.ts` and the `*.happy.integration.test.ts` files.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
grep -q 'Happy-path, risk and development tests' "$KIT/_claude-project/rules/testing-verification.md" && echo "kit sorts integration tests into happy-path, risk and development"
jq -r '"DB_ENGINE=\(.DB_ENGINE // "")"' .claude/sync-substitutions.json
FILES=(-- '*.integration.test.ts' ':(exclude).claude/**' ':(exclude)**/harness.integration.test.ts')
CASE='^[[:space:]]*([A-Za-z_$][[:alnum:]_$]*Test|it|test)(\.(each|only|skip|concurrent|sequential|fails|todo)[^(]*)?\('
LIST=$(git ls-files --cached --others --exclude-standard "${FILES[@]}")
echo "integration test files: $(printf '%s\n' "$LIST" | grep -c .) ($(printf '%s\n' "$LIST" | grep -c '\.happy\.integration\.test\.ts$') happy-path, $(printf '%s\n' "$LIST" | grep -c '\.dev\.integration\.test\.ts$') development)"
echo "test cases to judge: $(git grep --untracked -cE "$CASE" "${FILES[@]}" ':(exclude)**/*.happy.integration.test.ts' | awk -F: '{n += $NF} END {print n + 0}')"
echo "units for /happy-path afterwards: $(node "$KIT/_claude-project/skills/happy-path/scripts/drift.mjs" units --repo . | wc -l | tr -d ' ')"
```

`DB_ENGINE=None`, or `test cases to judge: 0`: it does not apply. Otherwise every test case counted is judged, then kept, rewritten, moved or deleted; a case is a `dbTest(…)`, `it(…)`, `test(…)`, or a fixture extended from `dbTest` such as `<name>Test(…)`. Reach is the integration test files, the unit test files cases move into, and the shared module's `test/project.ts`. It runs the test suite three times — before, after, and once for the development tests. The last count is how many `/happy-path` sessions the developer runs afterwards, one per unit; they are not part of this migration.

---

Sort every existing integration test in this project into the kinds the kit now names, and act on each one. Do all of it yourself: there is no list for me to approve, and git is the undo. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

Run every command from the repository root, setting these in each shell:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
S=$(jq -r '.SHARED_MODULE_DIR // ""' .claude/sync-substitutions.json)
```

## Whether it applies

It applies when there is at least one integration test case to judge:

```bash
CASE='^[[:space:]]*([A-Za-z_$][[:alnum:]_$]*Test|it|test)(\.(each|only|skip|concurrent|sequential|fails|todo)[^(]*)?\('
git grep --untracked -cE "$CASE" -- '*.integration.test.ts' ':(exclude).claude/**' ':(exclude)**/harness.integration.test.ts' ':(exclude)**/*.happy.integration.test.ts' | awk -F: '{n += $NF} END {print n + 0}'
```

When `jq -r .DB_ENGINE .claude/sync-substitutions.json` is `None`, or that count is `0`, say so in the report and stop here.

Read `.claude/rules/testing-verification.md` "Which tests a change gets" and "Running the suite", and `.claude/skills/happy-path/SKILL.md`, end to end. They are the criteria; the steps below apply them.

## 1. Record the baseline

Run `NO_COLOR=1 npm test` and keep, per vitest project, the test files, the tests and any failures. Confirm the per-file output carries `|integration|` labels; a run without them did not run integration (the rule's "Confirm the integration project actually ran"). A missing credential is a blocker, not a decision for me: report the run as blocked, naming the missing credential, and stop. On SQL Server the harness does not drop the labels — it fails the run outright, naming the `DB_*` keys to set; that is the same blocker. A test already failing here is fixed in step 5 when the fix is in the test; when the fix is in application code, record it in the report and leave the application code unchanged.

## 2. Judge every test case

Judge every `*.integration.test.ts` outside `node_modules` and `.claude`, except the kit's `harness.integration.test.ts` and any `*.happy.integration.test.ts`, which `/happy-path` owns. Already-named `*.dev.integration.test.ts` files are judged too.

Read each file whole, and the application code each case calls. Put every case in exactly one kind, the first row that fits:

| Kind | The case… | Example | Action |
|---|---|---|---|
| **Re-implements** | imports nothing from the app's source, or runs its own copy of the logic or SQL and asserts on that copy | builds its own `SELECT … WHERE status = 'open'` and asserts on the rows it returns | Rewrite it to call the app's function, then judge it again by the rows below; delete it only when there is no app code for it to call |
| **ORM-only** | only shows a row was saved, or read back what it wrote — nothing the app's code decides | inserts a customer, reads it back by id, asserts the name | Delete |
| **Unit** | needs no database: the answer is in the code — formatting, parsing, validation, a branch, a calculation | asserts `formatInvoiceNumber(42)` returns `INV-00042` | Move to the unit test file for the same subject |
| **Duplicate** | proves what another case you keep already proves, a happy-path case included — a second main success case of the same function is a duplicate, and so is an app case that re-tests a shared-module function through a pass-through wrapper (below) | a second "a valid order saves" beside the one kept | Delete; keep the case that states it most directly |
| **Happy-path** | is exactly the main success case of a function its unit exists to do — the plain call, with valid input, succeeding — whatever the function touches | `createOrder` with a valid cart returns the new order | Move to the unit's `test/happy-path/` |
| **Risk** | asserts money math — an amount the code computes: a sum, a fee rate, rounding, proration, never a zero or a missing amount; dates, time zones or period boundaries; permissions; data integrity — a write that could corrupt, duplicate or orphan data that other code or another application reads: a duplicate where one must be unique, a write left half-done, a write landing on the wrong record, never a function that writes nothing when it refuses or leaves other columns alone; concurrency or locking; a contract with another system — the shape, protocol or encoding it requires, asserted against its real format, never with that system mocked; or code many others depend on — or guards a fixed bug that passes the fixed-bug test below. A filter, a join, an aggregate, a date range or a database quirk alone — collation, trimming, `NULL` handling, a column's type, a fallback that writes nothing — is none of these | an order placed at 23:30 local time lands in that day's report, not the next | Stays a risk test |
| **Kept for coverage** | is the main success case of a function of a risky shape — raw SQL, a join, a filter beyond a lookup by key, an aggregate or grouping, a date range, an upsert, a transaction, more than one write — when no other case of that function is happy-path or risk. At most ONE case per function | `listOpenOrders` returns the open orders, and nothing else of it is risk | Stays a risk test |
| **Development** | anything else: it calls the app's function and checks the function's own logic, so it would catch a wrong change while the code is being worked on — a fixed bug that fails the fixed-bug test, and every further case of a risky-shape function that is not risk, included | `listOpenOrders` leaves out cancelled orders; a lookup that ignores case, or a fallback that writes no row | Move to a `.dev.integration.test.ts` file |

Judge each function's cases against every row above **Kept for coverage** first, then give that row to at most one remaining case of the function — its main success case — and send the function's other remaining cases to **Development**. The shape decides only that the function keeps one test in the full suite, never the kind of its other cases.

**The fixed-bug test, per case.** A case whose name or comment says it guards a fixed bug is risk only when a competent developer making a sensible later change could plausibly bring the bug back — the fix rests on a database quirk, a protocol detail, a boundary or another system's contract. Naming a bug never keeps a case. An empty string reaching a nullable date column stored as `NULL` rather than an epoch, because the driver converts it: risk. A total that once summed `unitPrice` instead of `lineTotal` — a plain mistake, a typo, a misread requirement, a wrong variable: development.

**The pass-through duplicate, per app case.** Shared code is tested once, in the shared module; an app tests only what it adds. For each case in an app whose function under test delegates to a shared-module function — read the app function: its body only forwards the call to the shared function, perhaps reshaping the arguments — open the shared module's tests of that function. A case that asserts nothing those tests do not is a **Duplicate**. Behaviour the app adds on top — its own inputs, checks or output shape — is judged on its own by the table. Compare only these pairs, never every file against every other.

Judge a case by what it asserts, never by its title or a comment. A case asserting a main success case and an edge case together is judged by the edge case.

**Take at most one happy-path case per function**, its main success case. Its unit is the one whose source declares the function it calls — an app or the shared module `$S` — as `node .claude/skills/happy-path/scripts/drift.mjs units` lists them; a function declared outside every unit it lists belongs to the shared module. Which functions are core is the developer's to settle afterwards in `/happy-path`, which keeps, moves to a risk or development test, or deletes each file it finds there.

**Leave a test that reads data the database already holds as it is** — never rewrite it to insert its own rows. Judge its kind like any other and move it unchanged.

Decide every case. When two rows seem to fit, the first one in the table wins.

## 3. Act

- **Delete** each case judged ORM-only or duplicate, and each re-implements case with no app code to call.
- **Re-implements:** rewrite the case to import and call the app's function in place of its own copy, then act on it as the kind it now is.
- **Unit:** move it into `<subject>.test.ts` beside the integration file it came from — the same name without `.integration` — creating that file when it does not exist. Turn `dbTest`, or a fixture extended from it, into `it` from `vitest`, and drop the database fixture and every import it no longer uses.
- **Happy-path:** move it into `<unit>/test/happy-path/<subject>.happy.integration.test.ts`, `<subject>` naming the function or area it covers.
- **Development:** move it into `<subject>.dev.integration.test.ts` beside the file it came from.
- **Risk** and **kept for coverage:** leave it in its `*.integration.test.ts`. Such a case found in a `.dev.integration.test.ts` file moves to `<subject>.integration.test.ts` beside it.

**Split a file holding several kinds into one file per kind beside it**, and delete a file left with no cases. Repoint each moved case's relative imports from its new folder. A setup helper, fixture, constant or `beforeEach` used by cases now in different files moves to `<subject>.helpers.ts` beside them, imported by each — never copied. A `vi.mock` call stays in every test file that needs it: vitest hoists it only within the file that calls it, so one moved into a helpers file mocks nothing and the test reaches the real dependency. The mock's stand-in may live once in the helpers file, which each `vi.mock` factory imports. Never change application code to make a move work.

## 4. Cover the new locations

`integrationInclude` in `$S/test/project.ts` decides which files the integration project runs; unset, it is `$S/test/**/*.integration.test.ts`. When a happy-path file sits outside what it matches — an app's `test/happy-path/` — set it to globs covering every place integration tests now live, the shared module's own glob included, since setting it replaces the default. A development test sits beside the file it came from, so a glob ending in `*.integration.test.ts` already covers it; when a glob names files more narrowly, add one that covers it.

When a moved `<subject>.test.ts` sits outside `unitInclude` (unset, `$S/test/**/*.test.ts`), add its folder there.

**Every test file you create is type-checked.** A unit's `tsconfig.json` often includes only `src/`, which leaves its `test/happy-path/` unchecked by `check-types`. Add the folder to that tsconfig's `include` for each unit that now holds a happy-path file outside it, and run that unit's `check-types`.

## 5. Prove it

Run `NO_COLOR=1 npm test` and fix every failure until it is green with `|integration|` labels in the output, except a failure whose fix is in application code: record it in the report and leave the application code unchanged. Every risk and happy-path case you kept, and every case moved to a unit test file, appears in the run.

Run the development tests, which the full suite leaves out, and fix every failure the same way:

```bash
INTEGRATION_DEV_TESTS=1 NO_COLOR=1 npm test -- --project integration .dev.integration.test
```

Run `node scripts/check-integration-coverage.mjs` and fix what it reports. A test file importing nothing from the app's source is a re-implements case — rewrite it to call the app's function, or delete it when there is no app code for it to call. A function it names with no happy-path or risk test gets its main success case written as a risk test — the one case its risky shape keeps, counted as a risk test until `/happy-path` settles whether the function is core. Then run it with `--report-untested` and keep the count.

Run `npm run check-types` and `npx --no-install @biomejs/biome lint --max-diagnostics=none`, and fix every failure in a file you touched.

## 6. Leave `/happy-path` to the developer

Do not run `/happy-path` here: it settles each unit's core with the developer, one unit per run, and writes the snapshot only after they agree. Name in the report every unit `node .claude/skills/happy-path/scripts/drift.mjs units` lists, with the happy-path files this migration put in it.

## Report

- per kind — re-implements, ORM-only, unit, duplicate, happy-path, risk, kept for coverage, development — how many cases were kept in place, rewritten, moved and deleted;
- each file split and the files it became, and each helpers file created;
- `integrationInclude` and `unitInclude` before and after, or that they did not change, and each tsconfig whose `include` gained a test folder;
- `npm test` before and after, per vitest project, and the development tests' result;
- the coverage check's result, each risk test it led you to write, and the count from `--report-untested`;
- each failure left because its fix is in application code, with the test and what it shows;
- each unit to run `/happy-path <unit>` on, one session each, with the happy-path files it now holds.
