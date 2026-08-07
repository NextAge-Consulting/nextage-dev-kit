---
name: mfing-bible-of-tanstack
description: House rules for TanStack Start, Router, Query, Table and Form — which data layer a screen uses and why, the fresh-by-default Query posture, the per-app form rule, server functions with { data: params }, unified queryOptions, server-paged browses with Table v9, and the routing index into the vendored upstream reference docs. Use when creating routes, server functions, browses or forms, wiring queries or mutations, adding a TanStack dependency, implementing authentication, building webhooks, debugging data fetching, or any TanStack Start/Router/Query/Table/Form work.
---

# The MF'ing Bible of TanStack

House doctrine first, then an index into `references/`. Read the section you need;
do not read the whole file.

## Versions are not listed here

`.claude/tanstack-manifest.json` holds the blessed version of every TanStack
package, and `scripts/check-tanstack.mjs` enforces it in CI. Duplicating the
numbers here would just create a second copy to go stale.

Two things follow from that file and are non-negotiable:

- **Lockstep is absolute.** TanStack publishes no LTS — no `lts` dist-tag, no
  support window, one rolling line per library. The kit *is* the LTS. If a
  project uses a TanStack library it uses the kit's version, declared **exactly**
  (a caret range drifts off the blessed version on a fresh install).
- **Adding or bumping a TanStack package is a kit decision**, made through the
  kit's `/review-tanstack`. Never bump the manifest to make a build pass.

---

## 1. Which data layer? Decide per screen, record the reason

There is no single answer, and picking by habit is the failure mode. Three
legitimate shapes:

| Shape | Use when | Cost of getting it wrong |
|---|---|---|
| **Route loader only** | The screen owns its data, is server-paged, and nothing else on the site shares it | Fine until two screens need the same data, then you refetch twice |
| **TanStack Query** (default for interactive screens) | Anything with mutations, background refresh, optimistic updates, or data shared across screens | — |
| **Loader over a server-side cache** | A large reference set many screens read, where per-screen invalidation would mean an enormous query | Naive Query invalidation here can turn one navigation into a five-figure row scan |

**The default is Query.** The third shape is real and legitimate, but it is a
deliberate choice with a measured reason, not a way to avoid learning Query.

**Whichever you pick, write the reason down where the next person will hit it** —
a comment at the head of the server-function module, not a separate doc. A
loader-only screen that had a good reason and an unconverted screen look
identical from the outside; the comment is the only difference.

## 2. Fresh by default is a posture, not per-screen work

Business screens must show current data without the user reloading. That is
configured **once** on the QueryClient and inherited by every screen — you should
never be adding freshness per browse:

```ts
new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,        // don't refetch on every mount
      refetchOnWindowFocus: true, // returning to the tab shows current data
      retry: 1,
    },
  },
})
```

Then per-screen, only where it genuinely differs:

- **After a mutation** — `invalidateQueries` scoped to the affected key. Never
  `router.invalidate()` as a blanket refresh; that refetches every active loader
  on the page to fix one list.
- **Values that must be exact at the moment of action** (money, stock) —
  `staleTime: 0` on that query specifically.

**Paging without a flash — which mechanism depends on who owns the page number.**

`useSuspenseQuery` does **not** accept `placeholderData`; the option is omitted
from its type, so `keepPreviousData` is not available on the loader-driven path.
That is not a gap:

- **Route-loader-driven paging** (page in the URL, the house default for
  browses). `ensureQueryData` in the loader means Router holds the current page
  rendered until the next page's data is in cache. No flash, nothing to
  configure.
- **Client-driven paging** (page in component state, no route change) — use
  plain `useQuery` with `placeholderData: keepPreviousData`.

Reach for the second only when the page genuinely should not be in the URL. A
browse whose page number is not shareable or bookmarkable is usually a mistake.

## 3. Router + Query wiring — two ways to get this badly wrong

```ts
// src/router.tsx
export function getRouter() {
  // CRITICAL: inside the factory. A module-level QueryClient is shared across
  // SSR requests, which leaks one user's data into another's render. In a
  // multi-tenant app that is a cross-tenant leak, not a caching bug.
  const queryClient = new QueryClient({ /* defaults above */ })

  const router = createRouter({
    routeTree,
    context: { queryClient },
    scrollRestoration: true,
    // CRITICAL: Router's own preload cache defaults to 30s and would override
    // Query's freshness control. 0 hands caching to Query, which is the point.
    defaultPreloadStaleTime: 0,
  })

  setupRouterSsrQueryIntegration({ router, queryClient })
  return router
}
```

`setupRouterSsrQueryIntegration` (from `@tanstack/react-router-ssr-query`) is the
whole SSR story — it wraps the app in `QueryClientProvider` and handles
dehydrate/hydrate/streaming. Do not hand-roll `dehydrate`/`hydrate`/`Wrap`.

## 4. Unified queryOptions — one object, both sides

The loader prefetches, the component reads, and they share **one** definition so
the cache key can never drift:

```ts
// lib/queries/itemQueries.ts
export const itemBrowseQuery = (params: ItemBrowseParams) =>
  queryOptions({
    queryKey: ['item', 'browse', params],
    queryFn: () => getItemBrowse({ data: params }),
  })
```

```tsx
export const Route = createFileRoute('/_authed/accounting/products/')({
  validateSearch: searchSchema,
  loaderDeps: ({ search }) => search,
  loader: ({ context, deps }) =>
    context.queryClient.ensureQueryData(itemBrowseQuery(toParams(deps))),
  component: ProductBrowse,
})

function ProductBrowse() {
  const search = Route.useSearch()
  const { data } = useSuspenseQuery(itemBrowseQuery(toParams(search)))
}
```

- `ensureQueryData` in the loader — no flash of loading, no request waterfall,
  SSR-rendered data.
- `useSuspenseQuery` in the component — reads the warm cache and subscribes.
- **Every server-owned slice belongs in the key.** Page, size, sort, filters. If
  it changes what the server returns, it is part of the key.

## 5. Server functions, API routes, and the production server are three things

Confusing them is the most common orientation mistake.

| Concept | Built with | Bundled? | Purpose |
|---|---|---|---|
| **Server function** | `createServerFn()` | Yes | Internal type-safe RPC — queries, auth, business logic |
| **API route** | `createFileRoute()` + `server.handlers` | Yes | External HTTP — webhooks, third-party callbacks |
| **Production server** | Hono, wrapping the Start fetch handler | **No** — your code | Serves static files, health checks, runs the app |

Server-function shape: `.inputValidator()` then `.handler(async ({ data }) => …)`,
auth first, then the query. Details in `references/start-server-functions.md`;
house auth in `references/authentication.md`.

## 6. Browses use Table v9

Column definitions replace duplicated header/cell markup. The table is headless —
it renders nothing, so the design-system markup, toolbar and footer stay exactly
as they are.

- Features are **opt-in** in v9: `tableFeatures({ rowPaginationFeature, … })`.
  Register only what the browse uses.
- Server-paged browses set `manualPagination: true` and pass the server's
  `rowCount`. Table does not slice the rows; the server already did.
- **Never `legacyCreateColumnHelper`** — it is the v8 compat shim and carries an
  open upstream TypeScript defect.

Full pattern: `references/table-with-query.md`, `references/table-state.md`.

## 7. Forms: TanStack Form, decided per app, all-in within an app

An app either uses `@tanstack/react-form` for **every** form or is listed in
`FORM_LIB_EXEMPT_APPS`. There is no per-screen judgment — a "library when it's
complex" rule produces one inconsistent decision per screen, which is the worst
possible shape for an AI-written codebase. An app in neither state fails the
build, because an unasked question and a deliberate no are not the same thing.

**React Hook Form, `@hookform/resolvers` and Formik are banned.** The live hazard:
`npx shadcn add form` installs react-hook-form as a hard dependency. **Do not use
shadcn's form atom.** Build field components from the plain atoms (`Input`,
`Label`, `Select`) bound to TanStack Form.

Field components that bind to form state are **app-level**, not `packages/ui` —
the design system stays presentational and form-library-agnostic so it keeps
rendering in the design feed.

Server-side validation goes through `@tanstack/react-form-start`:
`formOptions` shares the shape, `createServerValidate` validates inside a normal
server function, and `mergeForm` + `useTransform` merge server field errors back
into client state. Posting to `handleForm.url` with a native `<form>` keeps the
form working without JavaScript.

## 8. Two things AI gets wrong about Router, every time

- **Types are fully inferred. Never cast, never annotate an inferred value.** If
  you are reaching for `as`, the generic parameter is the fix.
- **Router is client-first.** Loaders run on the client by default — they are not
  server-only like Next.js or Remix. Do not import Next.js assumptions.

---

## Reference index

Files under `references/`. Vendored ones are marked ⇩ — they are copied verbatim
from the SKILL.md files TanStack ships inside its npm packages, with a provenance
header. **Do not hand-edit a vendored file**; `/review-tanstack` overwrites it.
House guidance goes here in SKILL.md or in a house reference.

| Task | Reference |
|---|---|
| Loaders, loaderDeps, staleTime/gcTime, beforeLoad, router context, deferred data | ⇩ `router-data-loading.md` |
| Validating, reading and writing search params | ⇩ `router-search-params.md`, ⇩ `router-search-params-validation.md` |
| SSR, streaming, selective SSR (`ssr: true \| 'data-only' \| false`) | ⇩ `router-ssr.md` |
| Route guards, redirects, protected layouts | ⇩ `router-auth-and-guards.md` |
| Type inference, `Register`, why not to cast | ⇩ `router-type-safety.md` |
| Navigation, `Link`, programmatic navigate | ⇩ `router-navigation.md` |
| Path params | ⇩ `router-path-params.md` |
| notFound, error components | ⇩ `router-errors.md` |
| `createServerFn`, input validation, composition | ⇩ `start-server-functions.md` |
| Middleware chains for server fns and routes | ⇩ `start-middleware.md` |
| Server routes / public HTTP endpoints | ⇩ `start-server-routes.md` |
| What runs where — isomorphic vs server-only | ⇩ `start-execution-model.md` |
| Session/auth primitives on the server | ⇩ `start-auth-server-primitives.md` |
| Deployment targets, Nitro/h3 | ⇩ `start-deployment.md` |
| Table setup, column defs, `flexRender` | ⇩ `table-getting-started.md` |
| Table state: sorting, visibility, selection, pagination | ⇩ `table-state.md` |
| **Server-paged browse: Table + Query** | ⇩ `table-with-query.md` |
| TanStack Query patterns, cache keys, mutations, optimistic updates | `tanstack-query.md` |
| House auth: `getServerAuth`, RBAC, Better Auth login | `authentication.md` |
| Webhooks, raw body handling, public API routes | `api-routes-webhooks.md` |
| Loading states, spinners, SWR behaviour | `loading-states.md` |
| Hydration mismatches, CJS/ESM, testing server fns | `debugging.md` |
| Hono production server, Docker, static files, version reading | `production-deployment.md` |
| Code review; known traps (betterAuth factory OOM, authed fns poisoning the cache, `seroval`) | `anti-patterns.md` |
| Dependabot triage, `overrides` safety | `dependency-management.md` |

**`tanstack-query.md` and the Form guidance above have no upstream.** TanStack
ships no Query or Form skills — verified zero across `query-core`, `react-query`,
`form-core`, `react-form` and both repos. They are ours to maintain, and they are
the only content here that cannot be refreshed from a package.

## Something not covered here

The reference set is deliberately curated, not exhaustive. TanStack ships more
skills inside its packages than we carry — **migration guides especially, which
are one-offs we do not keep** (`migrate-from-nextjs`, `migrate-from-react-router`,
`migrate-v8-to-v9`).

When you hit a scenario this skill does not cover:

```bash
ls node_modules/@tanstack/*/skills/           # what this project's versions ship
```

Read the relevant `SKILL.md` there **in the session that needs it** and let it go
afterwards. Do not copy it into `references/` — that is how the kit accumulates
stale content nobody refreshes. If a topic keeps coming up, that is a signal to
add it to the manifest and vendor it properly, which is a kit decision.

Upstream repos, when the installed version does not ship what you need:
`TanStack/router`, `TanStack/table`, `TanStack/db` (skills live under
`packages/*/skills/`). Official docs search without an API key:
`npx @tanstack/cli mcp`.
