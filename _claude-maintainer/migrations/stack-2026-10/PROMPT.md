# Migration: TanStack Start 1.0, Vite 8, vitest 5 and the October pins

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the stack manifest blessed 2026-10-16 and the TanStack bible that goes with it. A section whose package or pattern the project does not have is skipped, and named as skipped in the report; a section that partly applies is done for the part that does.

---

Move this project onto the kit's October stack and the patterns its TanStack bible teaches. Work through every section to the end. Make no git commits — leave everything uncommitted for me to review. Never apply a database migration: generate it and list it in the report.

Run every command from the repository root, setting these in each shell:

```bash
M=.claude/stack-manifest.json
B=.claude/skills/mfing-bible-of-tanstack/references
```

If `$M` has no `"blessed_at": "2026-10-16"`, stop: the sync has not landed this kit version.

Read `$B/data-loading.md`, `$B/search-params.md`, `$B/server-functions.md`, `$B/queries-and-mutations.md`, `$B/browse-tables.md`, `$B/forms.md`, `$B/deployment.md` and `$B/auth.md` first. Where a section below names one of them, the code it shows is the target shape.

An "app" is each workspace that builds a TanStack Start application — each `package.json` declaring `@tanstack/react-start`.

## Baseline

Run `npm run check-types`, `npx biome lint`, `npm test`, and each app's `build` script. Keep each result, including the test count per vitest project and whether `|integration|` ran. A check that already fails here is fixed in this migration too.

## Node

Set every Node version that names or allows a version below 22.12 — `.nvmrc`, CI's `node-version`, Dockerfile base images, deploy config — to 24, and every `engines.node` range to `>=22.12`. Run the remaining sections on Node 24.

## Versions

In every `package.json`, set each package the manifest lists to its manifest version, written without a range, in whichever of `dependencies` or `devDependencies` already declares it. A listed package the project does not declare stays undeclared.

```bash
jq -r '.packages | to_entries[] | "\(.key) \(.value.version)"' "$M"
```

The manifest does not pin the packages below; move each to the newest version whose peer range accepts the manifest's Vite, written without a range:

- `@vitejs/plugin-react`. On 6.x, a Babel plugin passed through its `babel` option — React Compiler included — moves to `@rolldown/plugin-babel`, per that package's README.
- `@tailwindcss/vite`, `vite-tsconfig-paths` and every other package in a Vite config's `plugins` that the manifest does not list.
- `nitro`, when the next section replaces `@tanstack/nitro-v2-vite-plugin` with it.

Move every `@vitest/*` package to the vitest version exactly. Run `npm install`, then `node scripts/check-stack.mjs` and `node scripts/check-dep-alignment.mjs`, and make both pass before going on.

## Vite 8 and Start 1.0

- Rename `build.rollupOptions` to `build.rolldownOptions` in every Vite config.
- Replace `@tanstack/nitro-v2-vite-plugin` with `nitro()` from `nitro/vite`.
- Rename `.inputValidator(` to `.validator(` on server functions and middleware.
- Replace each `setResponseHeader('set-cookie', …)`: a cookie the code builds from a name and value becomes `setCookie(name, value, options)`; a ready `Set-Cookie` string becomes `appendResponseHeader('set-cookie', value)`. Both import from `@tanstack/react-start/server`.
- Remove `transferResponseBodyOwnership` and return the response it wrapped.
- Where code reads `sendContext` as an object, guard it: it is `undefined` when nothing sent context. Where code tests a request header against `undefined`, also handle `''`: a present, empty header now returns `''`.
- Replace a `useSession` imported from `@tanstack/react-start` with the auth client's session hook (`$B/auth.md`).
- Narrow each `errorComponent` / `onCatch` error the type-check reports as `unknown` with `instanceof` before reading it.

## Server entry

Give each app the `src/server.ts` that `$B/deployment.md` shows, logging through the app's pino logger. An app that already has a `src/server.ts` moves its own logic inside that shape.

Bring each app's `src/start.ts` to the shape `$B/server-functions.md` shows:

- the CSRF middleware's `filter` covers server functions and every state-changing server route except the webhooks;
- the `noStore` request middleware is registered;
- every request middleware has the failure handling shown there, so it throws only a `Response`, a `redirect()` or a `UserFacingError`.

Give every server route the app's own pages call the shape that reference's server-routes section shows: `requireSession()` first, and every other outcome a returned `Response`. A route under `/api/webhooks/` follows `$B/webhooks.md` instead.

## Validators

Add `validateInput` from `$B/server-functions.md` to the app's `log-failures.server.ts` — creating the file as that reference shows when it is absent — and route every `.validator(…)` through it. The lint is done when `npx biome lint` reports no `server-fn-logging` finding.

## Loaders

These apply to every call on a QueryClient, however the code reaches it — route context, `useQueryClient()`, an import — in loaders, `beforeLoad` and components alike:

- Replace `ensureQueryData(opts)` with `query({ ...opts, staleTime: 'static' })`.
- Replace `prefetchQuery(opts)` with `query({ ...opts, staleTime: 'static' }).catch(() => {})`, awaited where the original was awaited, and `fetchQuery(opts)` with `query(opts)`.
- Make every error component that calls `reset()` from `useQueryErrorResetBoundary` also call `router.invalidate()`.

## `loaderDeps`

Apply `$B/data-loading.md`'s shape to every route with `loaderDeps`: `loaderDeps` returns the route's params function applied to the search, the loader passes `deps` to its query options, and the component builds its key with the same function.

- Where no params function exists, write one as that reference shows, and make the route's query options take its result. When the loader runs several queries, the one function returns the inputs of all of them.
- Never pick fields into `loaderDeps` by hand.
- Keep every search key the loader never reads out of the params, and list those keys per route.

## Query and mutation redirects

Remove the redirect handling from every `QueryCache` / `MutationCache` `onError` — the code that detects a redirect and navigates — keeping the rest of that `onError`, and remove every `handleRedirects: false`.

## Browses

For every `useTable` / `useAppTable` call, trace `data` and `columns` back through every hook to where each is built, and memoise each one built fresh on every render at the place that builds it, per `$B/browse-tables.md`. These are the forms to look for:

- a page sliced, mapped or filtered inline from a larger array;
- `rows ?? []`, or a `.map` over query rows, in the render;
- a column list derived with `.filter` / `.map` from saved settings, a layout or a view;
- a `useMemo` whose dependency is itself rebuilt every render — memoise that dependency where it is built.

Memoise inside a hook that returns a derived list, so every caller is fixed at once. List every site you changed.

## Forms

Replace `useStore(form.store, …)` with `useSelector(form.store, …)`, importing `useSelector` from `@tanstack/react-form`.

## Better Auth

In each app that configures Better Auth:

1. Run the read-only schema check at the pinned version, against the app's auth config, and keep its output. It compares the configured Drizzle schema, so a fix in the schema passes it without the migration being applied.

   ```bash
   npx --yes auth@$(jq -r '.packages["better-auth"].version' "$M") check schema --cwd <app dir> --config <path to the auth config>
   ```

2. If the auth schema declares `issuer` on the account table:
   1. Run, read-only, against the database the app's `.env` reaches, `SELECT providerid, accountid, count(*) FROM <account table> GROUP BY providerid, accountid HAVING count(*) > 1`, using the table's and columns' real names. On any row, leave `issuer` in place, report the rows, and go on to step 3.
   2. Remove `issuer` and every index naming it from the Drizzle schema, and generate the migration with `drizzle-kit generate` (`drizzle.md`). In the generated SQL, the index drop comes before the column drop; reorder the statements in the generated file if it does not.
   3. Remove every write of `issuer` from the project's code and seed data, and every test assertion on it.
3. Fix every other finding in the schema: add each column Better Auth expects; make each required column it never writes nullable. Generate the migration the same way.
4. Run the check again until it passes, or until only the `issuer` finding from step 2 remains.

## Prove it

Fix every failure in the code; never suppress one (constitution §XIII).

- `npm run check-types` passes.
- `npx biome lint` passes.
- When `.claude/sync-substitutions.json` has `KNIP_GATE` set to `"true"`, `npx --yes knip@$(jq -r '.packages.knip.version' "$M")` passes. Remove what it reports as unused; report any finding that is in use.
- `npm test` passes, with `|integration|` present whenever the baseline had it. Fix tests that relied on mocks persisting between tests, on an unawaited `resolves` / `rejects`, or on `vi.mock` in a nested scope; update a snapshot only after reading its diff.
- `node scripts/check-stack.mjs` passes.
- Each app's `build` script succeeds.
- Compare `git status` with the files you edited: report each new untracked path you did not create, and leave `.gitignore` alone.

## Report

- each section: what you changed, or why it did not apply;
- each `loaderDeps` route and the search keys kept out of its params;
- each browse site memoised;
- the generated database migrations, unapplied, and the schema check's output before and after;
- every check's result against the baseline;
- for me to verify in the running app: an expired session on an open screen returns to sign-in; a new user signs up and an existing one signs in; a browse's paging, sorting and filters respond at once;
- anything you could not resolve.
