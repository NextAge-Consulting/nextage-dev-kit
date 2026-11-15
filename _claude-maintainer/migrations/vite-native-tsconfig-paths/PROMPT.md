# Migration: Vite resolves tsconfig paths itself

`/sync-dev-kit` runs everything below the line in the consumer project's session. It applies to a repository whose apps declare Vite 8 or later and that still declares `vite-tsconfig-paths`. A repository that does not declare the plugin, or has no Vite, has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
npm ls vite 2>/dev/null | grep -o ' vite@[0-9][0-9.]*' | sort -u
git grep -l 'vite-tsconfig-paths' -- '*.json' '*.ts' '*.mts' '*.js' '*.mjs' ':!*package-lock.json'
```

The first command prints the Vite each workspace declares: all below 8, it does not apply. The second lists every file that names the plugin — each `package.json` that declares it and each config that calls it. No files: it does not apply.

---

Replace the `vite-tsconfig-paths` plugin with Vite's own tsconfig path resolution. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Check it applies

Run the Estimate's commands. Stop and report "does not apply" when every declared Vite is below 8, or when no file names `vite-tsconfig-paths`.

## 2. Move each config onto the built-in option

For every Vite or Vitest config, and every shared config module they import, that calls the plugin:

- remove the plugin's import and its call from `plugins`;
- set `resolve.tsconfigPaths` to `true` in that same config, beside whatever `resolve` already holds.

Leave every `resolve.alias` entry and every tsconfig `paths` entry as it is.

## 3. Remove the dependency

Delete `vite-tsconfig-paths` from every `package.json` that declares it, then run `npm install` from the repository root.

## 4. Prove it

Build every app the way CI builds it, then run `npm run check-types` and `npm test`, and fix every failure. An import that resolved through the plugin and no longer resolves is an alias the app's own tsconfig does not declare: declare it there, or bring it to me when it is not clear which tsconfig should hold it.

## Report

- each config changed, and each `package.json` the dependency left
- the build's, the type check's and the tests' results
- any import that needed its alias declared, and where
