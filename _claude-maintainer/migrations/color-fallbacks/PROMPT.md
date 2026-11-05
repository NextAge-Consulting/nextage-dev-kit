# Migration: give the design tokens plain-colour fallbacks at build time

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed `colorFallbacks.ts` and its test beside the shared module (`SHARED_MODULE_DIR`). It applies to a project whose CSS defines a token with `oklch()`, `oklab()` or `color-mix()`; a project with no shared module, or whose tokens are all hex or `rgb()`, has nothing to do.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
SHARED=$(jq -r '.SHARED_MODULE_DIR // ""' .claude/sync-substitutions.json)
echo "shared module: ${SHARED:-none}"
git ls-files '*vite.config.*' '*viteApp*' | grep -v '/design-system/'
git grep -lE -- '--[a-z0-9-]+:[[:space:]]*(oklch|oklab|color-mix)\(' -- '*.css' | grep -v node_modules
```

No shared module, or no CSS file listed by the last command, means it does not apply. Otherwise reach is each Vite config listed (or the one base config they share), the shared module's `package.json` and `tsconfig.json`, and the lockfile.

---

Wire the kit's colour-token fallbacks into this project's build. A browser that cannot read `oklch()`, `oklab()` or `color-mix()` drops a token written in one, and whatever it colours draws with no colour — a dropdown goes see-through. `colorFallbacks.ts` is a PostCSS plugin that adds each such token in hex, inside an `@supports` block only those browsers apply. Work through every step to the end. Make no git commits — leave everything uncommitted for me to review.

## 1. Make the plugin importable

1. Declare `postcss` as a dev dependency of the shared module, at the exact version `package-lock.json` already resolves for it (Vite depends on it): `npm install -D postcss@<that version> -w <shared module>`.
2. When the shared module's `package.json` has an `exports` map, add `"./colorFallbacks": "./colorFallbacks.ts"` to it, beside its other root-level build files.
3. When the shared module's `tsconfig.json` lists its files in `include`, add `colorFallbacks.ts` and `colorFallbacks.test.ts`.

## 2. Wire it into the build

In the Vite config that builds the apps' CSS, add the plugin to `css.postcss.plugins`, importing it from the shared module by its package name (`<shared package>/colorFallbacks`):

```ts
css: { postcss: { plugins: [colorFallbacks()] } },
```

- When the apps share one base config, add it there once. Otherwise add it to each app's `vite.config.ts`.
- Keep any `css.postcss` plugins the config already has, and add this one after them.
- Leave the design-system feed config (`<UI package>/design-system/vite.feed.config.ts`) alone: the feed goes to the design tool, which reads the tokens as written.

## 3. Prove it

- Build every app. Each app's built CSS contains `@supports not ((color:oklch(0 0 0))` — one block for each rule that defines tokens — and the build log has no `no plain-colour fallback for` line. A token named there could not be resolved: report it.
- `npm run check-types` and the unit tests pass, `colorFallbacks.test.ts` among them.

## Report

- what you changed;
- each app's count of fallback blocks, and any token the build could not resolve;
- each check's result.
