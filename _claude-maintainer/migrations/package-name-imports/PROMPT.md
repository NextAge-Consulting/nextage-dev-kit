# Migration: package-name imports, then the knip gate

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has landed the kit version that ships `knip.config.ts`. It works for any kit project, whatever its layout, including one that never used cross-workspace aliases.

---

Migrate this project to the kit's workspace-import standard, then bring it to zero knip findings and turn the knip gate on. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review.

The standard is `.claude/rules/typescript-rules.md`, section "Workspace Imports". Read it before you change anything. The migration tools live in the kit:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MIG="$KIT/_claude-maintainer/migrations/package-name-imports"
```

## 1. Does this project need the import migration?

```bash
node "$MIG/codemod.mjs" . --dry-run
node scripts/check-workspace-tiers.mjs
```

If the codemod would rewrite nothing and leaves nothing for hand review, the tier check passes, and every workspace another one imports has an `exports` map whose targets exist, the imports already meet the standard: go to step 3a. Otherwise, before changing anything, record a baseline of every gate in step 3, so a failure you meet later can be told apart from one that was already there.

## 2. Convert

1. **Rewrite the specifiers.** Run `node "$MIG/codemod.mjs" .` and keep its report. It turns aliases into another workspace, relative paths out of a workspace, and a consumed package's aliases for its own source into package-name imports.
2. **Declare the workspace dependencies** the report lists, each as `"*"`, in that workspace's `dependencies` — `devDependencies` only where tests or build config alone import it. Then run `npm install`.
3. **Write each imported package's `exports` map** so it resolves every subpath the report lists. Point it at TypeScript source. Give each barrel an explicit entry, each `.tsx` folder its own pattern, each `.ts` module inside a `.tsx` folder its own entry, and each imported stylesheet its own entry. Check every listed subpath against the map: one the map does not resolve fails at build time, not at type-check.
4. **Remove the aliases.** Delete every tsconfig `paths` entry that resolves outside its own workspace, and every alias a consumed package keeps for its own source. Keep each app's in-app `@/*`. Delete the `vite.config` and `vitest.config` `resolve.alias` entries the report names. Drop `vite-tsconfig-paths` from any app left with no alias for it to read.
5. **Fix what the report leaves for hand review.** A cross-workspace CSS `@import` becomes the package specifier, for example `@import "@acme/ui/styles.css"`, backed by its `exports` entry. A Tailwind `@source` stays a path. A relative import into a folder no workspace owns moves into a package, or the code moves to the import.
6. **Fix any config module shared across workspaces**, such as a common Vite config factory. It resolves its paths from `import.meta.dirname`, never `__dirname` or `process.cwd()`, and each app imports it by package name.
7. **Point shadcn at the package.** Every `components.json` in a shared UI package names the package in its `aliases` (`"components": "@acme/ui/components"`, `"utils": "@acme/ui/lib/utils"`). An app's own `components.json` keeps `@/`.
8. **Make the vitest config's `setupFiles` and `globalSetup` absolute**, with `resolve(here, "test/…")`, as in the kit's `templates/testing/vitest.config.ts`.
9. **Update the deploy guard.** Where a buildspec derives the `VITE_*` scan scope from tsconfig `paths`, replace that derivation with the workspace-dependency block in `$KIT/project-documentation/infrastructure.md`, "Derive the SCOPE". Run the block for every service and confirm each scope still holds every directory whose `VITE_*` reads that service ships.
10. **Update the project's own words.** Search the docs, `.claude/rules/project/**`, the UI inventory, code comments, READMEs and Dockerfile comments for each alias prefix you removed and for "path alias". Rewrite every mention to the package name, in the present tense, with no note of what used to be there.

## 3. Prove it with the full gate set

From the repository root, run every gate below that this project has, and fix every failure:

- `npm run check-types`
- `npx --no-install @biomejs/biome lint`, plus `npm run lint:tokens` and `npm run lint:design` when `design.md` exists
- `npm test`, with the integration project actually running when the project has one — its per-file output carries `|integration|` labels
- `node scripts/check-workspace-tiers.mjs`, `node scripts/check-stack.mjs` and `node scripts/check-dep-alignment.mjs`
- every workspace's `build` script
- every built server started from its `dist/` through its `server-start.mjs`, with a page that renders shared UI loaded; every headless app started and seen reaching its ready state
- `docker build` for each Dockerfile, with the image run until the service answers — a package that changed workspace must still be installed in the image. `docker run --env-file` takes each value literally, quotes included, so pass values unquoted
- `npx drizzle-kit check` for each Drizzle config

Compare with the baseline. A gate that passed before and fails now is this migration's to fix.

## 3a. Server functions log and redact their failures

Run `npx --no-install @biomejs/biome lint --max-diagnostics=none` — without the flag Biome
prints only the first 20 findings. Any `lint/plugin/server-fn-logging` finding means this
project's server functions are not yet at the kit standard. Read
`.claude/skills/mfing-bible-of-tanstack/references/server-functions.md`, sections "Every
handler logs its own failure and redacts it" and "A server function's error message is never
shown to the user", and follow them exactly:

- the redacting `logFailures` wrapper, in a `.server` file, using the project's pino logger;
- `UserFacingError` with its serialization adapter registered in `src/start.ts`, with the
  CSRF middleware added back;
- every handler wrapped as `.handler(logFailures("<module>.<export>", fn))`;
- every message deliberately meant for the user thrown as `UserFacingError`;
- every screen that renders a server error's message changed to a general statement, unless
  the error is a `UserFacingError`;
- unit tests for the wrapper.

Biome then reports zero plugin findings. Re-run step 3.

## 4. Knip to zero

```bash
npx --yes knip@$(jq -r '.packages.knip.version' .claude/stack-manifest.json) --no-config-hints
```

The configuration is the kit's `knip.config.ts`. Never edit it, and never add an ignore — no `knip.json`, no ignore comment, no project ignore list.

Fix every true finding:

- An unused export: drop the `export`, or delete the code when nothing uses it.
- An unused file: delete it, once you have checked that nothing loads it by path — a script argument, a Dockerfile, a buildspec.
- An unlisted dependency: declare it in the workspace that imports it, at the version every other workspace declares.
- An unused dependency: remove it from that workspace.

A finding that is not dead code — something used in a way knip cannot see — is a gap in the kit's configuration. Leave it in place and collect it: the file, the finding, and how the code is actually used.

Re-run step 3 after the cleanup. Deleting code and moving dependencies is where builds and images break.

## 5. Turn the gate on

Set `KNIP_GATE` to `"true"` in `.claude/sync-substitutions.json` only when knip reports zero findings. While any false positive remains, leave the key as it is and say why.

## Report

- the codemod's counts
- each gate's result, before and after
- knip's counts before the cleanup, by type
- what you deleted, and which dependencies you moved or removed
- every false positive, for the kit
- whether `KNIP_GATE` is on
