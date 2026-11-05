# Migration: a root `test:related` script beside `test`

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose integration gate runs `npm run test:related`. It applies to a repository whose root `package.json` has a `test` script running `vitest run` and no `test:related` script. A repository with no root `package.json`, no vitest in its `test` script, or a `test:related` already declared has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
if [ -f package.json ]; then
  jq -r '"test: " + (.scripts.test // "(none)"),
         "test:related: " + (.scripts["test:related"] // "(none)")' package.json
  echo "integration test files: $(git ls-files -- '*.integration.test.ts' '*.integration.test.tsx' '*.integration.test.mts' | grep -vc '/node_modules/')"
else
  echo "no root package.json"
fi
```

A `test` without `vitest run`, or a `test:related` that is not `(none)`: it does not apply. Otherwise it adds one line to the root `package.json`. The count is the integration test files `/commit` runs through the new script; at zero, nothing runs through it yet.

---

Add a `test:related` script to this repository's root `package.json`, built from its `test` script, so `/commit` and `/ship-main` run the integration tests a change reaches the same way `npm test` runs the suite. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Check it applies

Read the root `package.json`. Stop and report "does not apply" when there is none, when `scripts["test:related"]` is already declared, or when `scripts.test` does not contain `vitest run`.

## 2. Add the script

Take `scripts.test` as it stands and replace `vitest run` with `vitest related`, keeping everything else — a loader in front of vitest (`op run --`, `doppler run --`, a project script), the `-c` config path, and the other flags:

```
"test":         "op run --env-file=.env.op -- vitest run -c apps/shared/vitest.config.ts"
"test:related": "op run --env-file=.env.op -- vitest related -c apps/shared/vitest.config.ts"
```

Set it with `npm pkg set scripts.test:related="<the result>"`.

When `vitest run` appears more than once, or `test` chains other commands with `&&` or `;`, write nothing: report the `test` script as it stands, and the `test:related` line it calls for — the loader and config of its vitest part, `vitest related` in place of `vitest run`, nothing else.

## 3. Prove it

Run `npm run test:related -- --run --project unit <SHARED_MODULE_DIR>/test/smoke.test.ts`, with `SHARED_MODULE_DIR` from `.claude/sync-substitutions.json` (`.` or empty: `test/smoke.test.ts`). It runs the kit's smoke test alone and passes, reporting 1 affected test file; the unit project touches no database. A startup error means the config path or the loader is wrong: fix the line and run it again.

## Report

- the `test` script, and the `test:related` line added — or, for a `test` this did not rewrite, the line it calls for;
- the result of the step 3 run.
