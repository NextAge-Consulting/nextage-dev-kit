# Search params as screen state

Distilled from `@tanstack/router-core` skills `router-core/search-params` and its
`validation-patterns` reference, plus our decisions.

For back-office apps this is not a routing detail — it is where a browse keeps
its state. Filters, page, page size and sort live in the URL so a screen can be
bookmarked, pasted into a ticket, reopened after a refresh, and reached by the
back button. A browse whose page number lives in `useState` is a browse nobody
can share.

## Validate, don't parse

```ts
export const ITEM_SORTS = ['name', 'sku', 'updated'] as const   // the sortable columns

export const itemBrowseSearch = z.object({
  q: z.coerce.string().optional(),
  page: z.coerce.number().int().min(1).optional().catch(undefined),
  size: z.coerce.number().int().min(1).max(100).optional().catch(undefined),
  sort: z.enum(ITEM_SORTS).optional().catch(undefined),
  dir: z.enum(['asc', 'desc']).optional().catch(undefined),
  inactive: z.boolean().optional().catch(undefined),
})
export type ItemBrowseSearch = z.output<typeof itemBrowseSearch>

export const Route = createFileRoute('/…')({
  validateSearch: itemBrowseSearch,
  search: { middlewares: [stripSearchParams(ITEM_BROWSE_DEFAULTS)] },
})
```

`sort` names a column from the list the server can order by, and `dir` its
direction; `size` has a ceiling, so a hand-edited `?size=100000` cannot ask the
server for the whole table. `ITEM_BROWSE_DEFAULTS` and `toParams` live beside
the schema (`data-loading.md`).

Then `Route.useSearch()` is fully typed and `navigate({ search })` is checked.

**Every param a hand-edited URL can break ends in `.catch(…)`.** Without it
`?page=abc` or `?page=0` fails validation and the screen becomes an error page;
with it the param falls back and the screen opens. Pass the Zod 4 schema to
`validateSearch` directly — never through `zodValidator()` (upstream
`router-core/search-params`: "Zod v4 … should use `.catch()` and not use the
`zodValidator()`").

## `z.coerce` on anything a user can type

**TanStack parses search params by inferred type.** `?q=1234` arrives as the
number `1234`, not the string `"1234"`. A plain `z.string()` then throws and
takes the whole screen down with an error page.

In an ERP that is not an edge case — SKUs, part numbers, work-order numbers and
invoice numbers are routinely all digits. **Any text field a user can type a
number into gets `z.coerce.string()`.** The same applies in reverse to numeric
params arriving as strings from a hand-edited URL.

`z.coerce.string()` keeps the screen up; it does not keep the exact text of a
hand-typed URL. The router JSON-parses any value that starts like JSON (a digit,
`-`, `true`, `null`), so `?q=1e3` reaches the schema as `1000` and `?q=1.50` as
`1.5`. A link the app builds is safe: `stringifySearch` quotes a string that
would parse as JSON, so it round-trips (`router-core` `searchParams.js`,
`parseSearchWith` / `stringifySearchWith`). Only a router-level `parseSearch`
and `stringifySearch` pair that leaves text params unparsed keeps hand-typed
text exact; reach for it only when such values are routine on a screen.

## Filter, sort and size changes reset the page

```ts
navigate({ search: (prev) => ({ ...prev, page: undefined, ...next }) })
```

Drop `page` whenever a filter, the sort or the page size changes. Page 7 of one
result set is not page 7 of another: after a filter it may not exist, and the
user lands on an empty page and thinks the filter is broken; after a sort it
holds rows nobody asked to see; after a size change it is a different slice
that may run past the end.

## A search box navigates when typing pauses

**The search box holds its own text and navigates once typing pauses, about
300 ms after the last key, as a normal push.** Navigating per keystroke writes a
history entry and starts a fetch for every letter, and the back button then
walks back one character at a time. A burst of typing is one search, one entry
and one fetch.

## `replace` for restorations, not for intent

Use `replace: true` when writing a param the user did not ask for — restoring a
remembered page size, refitting to the viewport. Those must not litter history.

Use a normal push for anything the user did — searching, filtering, paging — so
the back button returns to the previous result set, which is what they expect.

## Omit defaults

Leave a param out of the URL when it holds its default value. `?page=1&size=25`
on a freshly-opened screen is noise, and it makes a shared link look
deliberately configured when it isn't. The route's
`stripSearchParams(ITEM_BROWSE_DEFAULTS)` (above) removes them, so no `navigate`
call has to remember; it reads the same defaults constant `toParams` fills from,
so the two cannot disagree.

A param that should follow the user to the next screen — a selected company, a
fiscal year — is kept with `retainSearchParams(['company'])` on the parent route
instead of being re-passed by every link.

## Keep the param shape flat

Params are a query string. Flat scalars survive a copy-paste, a redirect and a
log line; nested objects encode into something unreadable and awkward to hand-
edit. If a screen's state genuinely needs structure, that is a signal it belongs
in a saved view stored server-side, keyed by a single id in the URL.
