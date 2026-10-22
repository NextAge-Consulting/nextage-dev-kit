# Migration: publish: off blocks for the Claude Design publisher

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version that removes `families.skip`. It applies to a project with `<UI package>/design-system/design-system.config.mjs`; any other project has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
node "$KIT/_claude-maintainer/migrations/publish-off/codemod.mjs" . --dry-run
```

It names, per token file, the declarations it wraps, and any one-line block left for hand wrapping. No design-system config, or no `families.skip` in it: it does not apply. Reach is the token stylesheets and the design-system config.

---

Move this project's Claude Design skip list into the token CSS. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MIG="$KIT/_claude-maintainer/migrations/publish-off"
```

## 1. Move the skip list

1. Run `node "$MIG/codemod.mjs" . --dry-run` and read the report. It names, per token file, the declarations the config's `families.skip` pattern matches, and any one-line block it leaves for hand review.
2. Run `node "$MIG/codemod.mjs" .`. Every run of those declarations is now wrapped in a `/* publish: off */` … `/* publish: on */` pair. A pair may also wrap whole blocks, placed between them; tidy the wrapping into fewer, larger pairs where that reads better, keeping every declaration's place.
3. Wrap by hand any one-line block the report lists.
4. Delete the `skip` key from `families` in `design-system/design-system.config.mjs`, and the whole `families` object if nothing is left in it.

## 2. Prove it

- `npm run build:design-system` in the UI package passes. A "no design-system family" problem names a token the old pattern skipped and the codemod could not see; wrap it in a pair.
- `npm run lint:tokens` passes.
- The published colours are unchanged: `git diff` on `dist/design-system/project/tokens.json`, if the project keeps a built copy, shows only the `meta` stamp.

## Report

- the codemod's counts, and what you wrapped by hand;
- each check's result;
- anything you could not resolve.
