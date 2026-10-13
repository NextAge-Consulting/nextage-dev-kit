# Migration: build the design-system feed stylesheet with Vite

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has landed `<UI package>/design-system/vite.feed.config.ts`. It applies to a project whose design-system config's `css.build` runs the Tailwind CLI; any other project has nothing to do.

---

Switch this project's design-system feed stylesheet from the Tailwind CLI to Vite, and remove `@tailwindcss/cli`. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Switch the build

1. In the UI package's `devDependencies`, declare `vite` and `@tailwindcss/vite` at the exact versions the app already declares, unless the UI package already has them.
2. The Vite config builds `design-system/feed.css`. When the feed stylesheet lives elsewhere, create `design-system/feed.css` holding one `@import` of it (`@import "../src/feed.css";`), so anything else that builds the original keeps working.
3. In `design-system/design-system.config.mjs`, set `css.build` to `'npx vite build --config design-system/vite.feed.config.ts'` and `css.file` to `'dist/design-system-feed/feed.css'`.
4. Delete the package script the old `css.build` ran (for example `build:css`), once nothing else calls it.
5. Remove `@tailwindcss/cli` from every `package.json` that declares it, then run `npm install`.

## 2. Prove it

- `npm run build:design-system` and `npm run check:design-system` in the UI package pass. A class the system promises but the Vite build leaves out fails the build by name: add it to `design-system/feed.css`'s sources.
- `node scripts/check-stack.mjs`, `node scripts/check-dep-alignment.mjs` and `npm run lint:tokens` pass.
- `npm audit` no longer reports `braces`.

## Report

- what you changed and removed;
- each check's result;
- anything you could not resolve.
