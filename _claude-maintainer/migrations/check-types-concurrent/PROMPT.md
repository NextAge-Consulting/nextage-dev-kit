# Migration: root check-types runs the workspaces concurrently

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version that ships `scripts/check-types.mjs`. It applies to a repository whose root `package.json` declares `workspaces` and whose root `check-types` script is not already `node scripts/check-types.mjs`. A single-package repository, with no `workspaces`, has nothing to do: its root `check-types` stays its own `tsc`.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
test -f "$KIT/_claude-project/templates/scripts/check-types.mjs" && echo "kit ships scripts/check-types.mjs"
jq -r '"workspaces: " + (if (.workspaces | type) == "array" or (.workspaces.packages? | type) == "array" then "declared" else "none" end),
       "root check-types: " + (.scripts["check-types"] // "(none)")' package.json
jq -e 'has("workspaces")' package.json >/dev/null \
  && npm pkg get scripts.check-types --workspaces --json \
     | jq -r '"workspaces with a check-types script: \([.[] | if type == "object" then .[] else . end | strings] | length)"'
```

`workspaces: none`, or a root `check-types` that already reads `node scripts/check-types.mjs`: it does not apply. Otherwise it touches one line of the root `package.json`, and the count is how many workspaces the root script will check at once.

---

Point this repository's root `check-types` at the kit's concurrent runner. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Check it applies

Read the root `package.json`. Stop and report "does not apply" when it declares no `workspaces` (neither an array nor `{ "packages": [...] }`), or when `scripts["check-types"]` is already exactly `node scripts/check-types.mjs`.

Confirm `scripts/check-types.mjs` is present at the repository root; the sync that ran this migration delivered it. If it is missing, stop and report that.

## 2. Rewire the root script

Look at the current root `check-types`:

- **Absent, or only delegating to the workspaces** — `npm run check-types --workspaces --if-present`, or the same with `--ws` or `-ws`, with or without `--if-present`: set it to `node scripts/check-types.mjs` with `npm pkg set scripts.check-types="node scripts/check-types.mjs"`.
- **Anything else** — a root `tsc`, a project-reference build, a chain with `&&`: leave it unchanged. Replacing it would drop whatever it checks besides the workspaces. Report the command as it stands.

## 3. Prove it

- Every workspace with TypeScript sources declares its own `check-types` script; the root runner checks only those. Name any workspace with `.ts` / `.tsx` files and no script.
- `npm run check-types` passes and its last line names how many workspaces it checked. A failure prints the failing workspace's output whole: if the same failure shows under the old command, it was already there — report it rather than changing code.

## Report

- the root `check-types` before and after, or why it was left;
- the workspace count from the run, and any TypeScript workspace without a `check-types` script;
- the result of `npm run check-types`.
