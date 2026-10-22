# Migration: UI source found, not listed

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version that ships `.claude/skills/design-system/scripts/ui-sources.mjs`. A project whose `DESIGN_UI_PACKAGE` is intentionally empty needs none of it.

## Estimate

Kind: asks for decisions — each new part built for a newly checked app, which waits for your approval
Your time: about 2 minutes for each new part; none when the newly checked folders already pass the token check.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
jq -r '.DESIGN_SOURCE_DIRS // "(not set)"' .claude/sync-substitutions.json
node "$KIT/_claude-project/skills/design-system/scripts/ui-sources.mjs" --repo .
```

Each folder the second command prints that the first does not hold is newly checked. Its findings, and the parts they need, are known only once the new checks run; the size of each new folder is the order of magnitude. `DESIGN_UI_PACKAGE` intentionally empty: it does not apply.

---

The token check, the commit design review and `/design-audit` read the UI package and every workspace whose `package.json` depends on it by name. Bring this project onto that. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Remove the folder list

Delete `DESIGN_SOURCE_DIRS` from `.claude/sync-substitutions.json`, and from its `_intentionally_empty` list when it is there.

## 2. Confirm what is found

Run `node .claude/skills/design-system/scripts/ui-sources.mjs`. It prints one folder per line.

- Every app that renders the design system is listed. One that is missing does not declare the UI package in its `package.json`; declare it there.
- In a monorepo, the command fails when the UI package's `package.json` has no `name`. Give it one, and import the package by that name.
- Tell me which folders are new against the deleted list.

## 3. Fix what the newly checked apps hold

Run `npm run lint:tokens`. Every finding in a folder the old list left out is existing code meeting the checks for the first time. Fix each one with the `design-system` skill, the same as any other token-check finding: a call site repainting a part gets the variant it needs on the part; a frame atom used on a screen gets this app's part of that block type, built pending when there is none. Run it until it passes.

## Report

- the folders now checked that were not before;
- each finding and how it was fixed, and each part or variant built pending;
- the final `npm run lint:tokens` counts.
