# Queries and mutations

**TanStack ships no Query skill** — verified zero `SKILL.md` files across
`query-core`, `react-query` and the whole `TanStack/query` repo. The nearest
upstream guidance is Router's `compositions/router-query` skill, which lives in
the router repository and is not in the published package. This file is
entirely ours.

## One definition per resource

The loader prefetches and the component reads. They share **one** object, so the
cache key cannot drift. The keys come from one exported object per resource, so
a query and an invalidation can only name prefixes that exist:

```ts
export const itemKeys = {
  all: ['item'] as const,
  browses: () => [...itemKeys.all, 'browse'] as const,
  browse: (params: ItemBrowseParams) => [...itemKeys.browses(), params] as const,
  detail: (itemid: string) => [...itemKeys.all, 'detail', itemid] as const,
}

export const itemBrowseQuery = (params: ItemBrowseParams) =>
  queryOptions({
    queryKey: itemKeys.browse(params),
    queryFn: () => getItemBrowse({ data: params }),
  })
```

Writing the key in two places is how you get a permanent loading flash nobody
can reproduce: the loader warms `{page: 1}` and the component subscribes to
`{page: '1'}`. A key typed inline is how an invalidation silently matches
nothing.

**Every server-owned slice belongs in the key.** Page, size, search, filters,
sort. If it changes what the server returns, it is part of the key. Anything
that only affects rendering — a column's visibility, an expanded row — does not.

**A mutation is defined once the same way, with `mutationOptions`,** taking the
QueryClient as a parameter; the component supplies it from `useQueryClient()`:

```ts
const save = useMutation(saveItemMutation(useQueryClient()))
```

## Freshness is configured once

Business screens must show current data without the user reloading, so the
QueryClient carries the posture and every screen inherits it:

```ts
defaultOptions: { queries: { staleTime: 30_000, refetchOnWindowFocus: true, retry: 1 } }
```

Override per-query only where the requirement genuinely differs. Money and stock
read at the point of an action want `staleTime: 0`. Reference data that changes
monthly wants minutes. Most screens want neither.

## After a mutation, repair the cache by key, never by router

**Repair in this order, and stop at the first that fits:** the server returned
the saved row, so write it into its own key with `setQueryData`; the change is
predictable and moves nothing, so apply it optimistically (below); only where
the server computes something the client cannot, invalidate that key's prefix —
with a comment saying what the server computes.

A saved record is usually both. Its own key takes the returned row; the browses
it appears in are invalidated, because the server decides its sort position,
whether it still matches each filter, and the total:

```ts
export const saveItemMutation = (queryClient: QueryClient) =>
  mutationOptions({
    mutationFn: (item: Item) => saveItem({ data: item }),
    onSuccess: async (saved) => {
      queryClient.setQueryData(itemQuery(saved.itemid).queryKey, saved)
      // The server decides sort position, filter membership and the total.
      await queryClient.invalidateQueries({ queryKey: itemKeys.browses() })
    },
  })
```

Invalidation refetches only the browses on screen; the others refetch when next
shown. `router.invalidate()` instead re-runs **every active loader on the page**
to fix one list — on a screen with a browse, a nav tree and a shell query that is
four round trips, and against a slow upstream the user sees all four.

## Optimistic updates

**Apply optimistically a change the client can predict that does not move the
row** — a star, a toggle, a status flag. On a paged browse, patch the row in
every cached page, roll every page back on failure, and tell the user:

```ts
// ItemPage is what getItemBrowse returns ({ rows, total }); showFailure is the app's toast
export const starItemMutation = (queryClient: QueryClient) =>
  mutationOptions({
    mutationFn: (v: { itemid: string; starred: boolean }) => setStar({ data: v }),
    onMutate: async ({ itemid, starred }) => {
      await queryClient.cancelQueries({ queryKey: itemKeys.browses() })
      const previous = queryClient.getQueriesData<ItemPage>({ queryKey: itemKeys.browses() })
      queryClient.setQueriesData<ItemPage>({ queryKey: itemKeys.browses() }, (page) =>
        page && { ...page, rows: page.rows.map((r) => (r.itemid === itemid ? { ...r, starred } : r)) })
      return { previous }
    },
    onError: (_err, _v, ctx) => {
      for (const [key, page] of ctx?.previous ?? []) queryClient.setQueryData(key, page)
      showFailure("Couldn't update the star — it is back as it was.")
    },
  })
```

The `cancelQueries` line is the one people drop, and its absence is a race that
only shows up under load: a refetch started before the mutation resolves after
it, and silently restores the old value.

**Rolling back is not enough.** The user must be told it failed, or they will
believe the optimistic value (constitution §X) — a general statement, or the
message of a `UserFacingError` (`server-functions.md`).

A change that moves the row — a rename under a name sort, a status a filter
selects on, a delete that shifts the page — is not optimistic on a paged browse:
the client cannot know the new page. Write the returned row and invalidate the
browses, as above.

## Not against a write the client cannot predict the outcome of

Optimistic updates assume the server will almost certainly agree. That holds for
a star or a reorder. It does not hold for a write to a third-party system of
record, and there the pattern inverts: **busy state, then the real result.**

The test is whether the client can know the write will succeed. It cannot when:

- **A concurrency token is owned elsewhere.** The upstream rejects a write
  carrying a stale version/sync token, and the token goes stale from edits made
  in the other system — which this app never sees.
- **Validation lives upstream and is not mirrored.** Rules the client has no
  copy of, and cannot evaluate.
- **Another party may have changed the record**, in a UI this app does not own.

Rolling a failure back is not free. A value that appears saved and silently
reverts a second later is worse than a spinner that never lied — and against a
slow upstream the revert lands long after the user has moved on.

Whether a given integration falls in this bucket is a project fact, so the
project's own rules name it. The generic guidance stops here.

## Suspense vs plain queries

`useSuspenseQuery` for anything the route loader prefetched — data is guaranteed
present, `data` is non-nullable, no loading branch in the component.

`useQuery` for anything fetched *after* render on user action — a type-ahead
lookup, a panel opened on demand. Those pass `skipToken` as the `queryFn` while
there is nothing to fetch — `queryFn: term ? () => lookup({ data: term }) :
skipToken` — so an empty term never fetches and the function never sees an
undefined argument. They are the only place `placeholderData: keepPreviousData`
applies (`useSuspenseQuery` omits that option from its type entirely).

## A dead session must bounce, even with no navigation

A route guard only re-checks on navigation. An already-open screen with an
expired session keeps showing authed UI while every query quietly fails — the
user sits looking at stale data that will not refresh, and nothing tells them
why.

**The server function throws `redirect({ to: '/login' })` from `requireSession()`,
and `setupRouterSsrQueryIntegration` turns it into a navigation.** The redirect
reaches the browser as a serialized redirect, which the server-function client
rebuilds into a real one and throws (`start-client-core` `serverFnFetcher.js`,
`parseRedirect`). The integration wraps the query and mutation caches' `onError`
and navigates on any `isRedirect(error)`, passing every other error on to the
app's own handler (`router-ssr-query-core`, `handleRedirects`, on by default).
One place, every query and mutation covered — leave `handleRedirects` at its
default and add no handler of your own for redirects.

## Per-request QueryClient

Create it inside the router factory, never at module scope. A module-level
client is shared across SSR requests and leaks one user's cached data into
another's render. In a multi-tenant app that is a cross-tenant leak.
