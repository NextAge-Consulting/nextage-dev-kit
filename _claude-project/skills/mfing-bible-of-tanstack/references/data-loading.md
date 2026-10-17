# Route data loading

Distilled from `@tanstack/router-core` skills `router-core/data-loading` and
`router-core/ssr`, plus our decisions. Router coordinates *when* data loads;
Query owns caching. This file is the seam between them.

## The standard route

```tsx
export const Route = createFileRoute('/_authed/accounting/products/')({
  validateSearch: searchSchema,
  loaderDeps: ({ search }) => toParams(search),
  loader: async ({ context, deps }) => {
    await context.queryClient.query({ ...itemBrowseQuery(deps), staleTime: 'static' })
  },
  component: ProductBrowse,
})

function ProductBrowse() {
  const search = Route.useSearch()
  const { data } = useSuspenseQuery(itemBrowseQuery(toParams(search)))
}
```

`toParams` turns the validated search (`search-params.md`) into the query's
params: it fills every default, drops what is unset, and returns the params type
the server function takes. The defaults have one home, a constant beside the
schema that `toParams` and the route's `stripSearchParams` both read:

```ts
export const ITEM_BROWSE_DEFAULTS = { page: 1, size: 25, sort: 'name', dir: 'asc' } as const

export function toParams(search: ItemBrowseSearch): ItemBrowseParams {
  return {
    q: search.q?.trim() || undefined,
    page: search.page ?? ITEM_BROWSE_DEFAULTS.page,
    size: search.size ?? ITEM_BROWSE_DEFAULTS.size,
    sort: search.sort ?? ITEM_BROWSE_DEFAULTS.sort,
    dir: search.dir ?? ITEM_BROWSE_DEFAULTS.dir,
  }
}
```

These are load-bearing:

- **`loaderDeps`** — without it the loader does not re-run when a search param
  changes, so filtering and paging silently do nothing. Path params are already
  dependencies; **search params are not**, and that asymmetry is the single most
  common data-loading bug.
- **`loaderDeps` returns the params function's result, and the loader uses
  `deps` as the query's params.** The loader then cannot read anything the deps
  leave out. Never hand-pick fields into `loaderDeps`: dropping an optional
  filter key still type-checks, and the loader warms one cache key while the
  component reads another.
- **`query({ …, staleTime: 'static' })`** — prefetch into the same cache the
  component reads. Cached data, of any age, returns at once; only a key with no
  data fetches. No flash of loading, no request waterfall, and the data is in the
  SSR payload. Freshness is the component's job: its `useSuspenseQuery` judges
  staleness by its own `staleTime` — the QueryClient's 30 seconds, not the
  loader's `'static'` — and refetches an older entry in the background on mount,
  on a key change and on window focus (`query-core` `queryObserver.js`,
  `isStale` and `shouldFetchOn`). Without `'static'`, `query()` refetches a stale
  entry *before the navigation commits*, so a click waits on the network.
- **One params function** — the loader and the component must produce an
  identical key. Derive it once, use it twice. It must be pure: its result is
  hashed on the server and on the client, and the hashes must agree.

**A search key the query ignores stays out of the deps**, so changing it keeps the
match and skips the loader (`router-core` `router.js`, `matchRoutesInternal`: the
deps hash is part of the match id).

`queryClient.query()` is Query 5.102 or later; it is the loader call upstream's
Router integration documents (`docs/router/integrations/query.md`).

## Router settings that make Query the cache

```ts
createRouter({ routeTree, context: { queryClient }, defaultPreloadStaleTime: 0 })
setupRouterSsrQueryIntegration({ router, queryClient })
```

Router keeps its own preload cache, 30 seconds by default, which sits in front
of Query and overrides its freshness rules. `defaultPreloadStaleTime: 0` hands
caching to Query entirely, which is the point of pairing them.

`setupRouterSsrQueryIntegration` (from `@tanstack/react-router-ssr-query`) is the
whole SSR story — it wraps the app in `QueryClientProvider` and handles
dehydrate, hydrate and streaming. Do not hand-roll those options.

## Loaders are isomorphic

A loader runs on the server during SSR and on the client during navigation. It
must be safe in both. In practice: a loader calls server functions and the query
client, and touches nothing else. A database import in a loader is a client
bundle error waiting to happen.

## Route context

`createRootRouteWithContext<{ queryClient: QueryClient }>()` types the context so
every loader gets `context.queryClient` with inference. `beforeLoad` can add to
context — a resolved session, a tenant — and children receive it typed.

Note the double-call form `createRootRouteWithContext<T>()({ ... })`. It is a
factory, not a typo.

## Guards

```ts
beforeLoad: async ({ location }) => {
  const session = await getSessionFn()
  if (!session) throw redirect({ to: '/login', search: { redirect: location.href } })
  return { session }
}
```

Put this on a **pathless layout route** (`_authed.tsx`) so protection is the
default and every screen inherits it. A route added outside that layout is
public — which is almost never intended.

This guards navigation only. Data protection is `requireSession()` inside every
server function, independently.

## Selective SSR

Per route: `ssr: true` (default — render on the server), `ssr: 'data-only'`
(loaders run on the server, the component renders on the client), `ssr: false`
(client only).

**A screen uses `'data-only'` when its component reads the browser to render —
the viewport, `localStorage`, a measured layout — or takes noticeable server time
to render; every other screen keeps `true`.** Behind a login there is no SEO to
win, so the cost of `'data-only'` is only an unpainted first frame, and it buys a
first render that cannot mismatch on browser state (`debugging.md`, Hydration
mismatch). Decide per screen; do not set it globally.

## Deferring slow data

Return a promise from the loader without awaiting it and the route renders
immediately, streaming that piece in when it resolves. Read it with `<Await>`.
For data the component reads through Query, start the fetch without awaiting
it — `void context.queryClient.query(opts).catch(() => {})` — and read it with
`useSuspenseQuery` under a `<Suspense>` boundary.

Worth it when one panel on a record screen is markedly slower than the rest — an
attachment list, an audit trail. Not worth it for the record's own fields; a
record that renders in pieces reads as broken.

## Errors

`errorComponent` per route, `notFoundComponent` for missing records. When using
Query with suspense, the error component's retry calls `reset()` from
`useQueryErrorResetBoundary` **and** `router.invalidate()`. Without the reset a
retry re-throws the cached error; without the invalidate the loader never re-runs
(upstream `docs/router/guide/external-data-loading.md`, § Error handling with
TanStack Query).

## Signing out

**On sign-out or an account switch, clear the query cache before the next
account's screens render** — `await queryClient.cancelQueries()` then
`queryClient.clear()`, alongside the sign-out call.
The client cache is per browser tab, not per account, and a cached browse is the
previous account's data (upstream `docs/start/framework/react/guide/tanstack-query.md`).
