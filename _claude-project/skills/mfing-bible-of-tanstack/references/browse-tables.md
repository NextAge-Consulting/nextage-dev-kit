# Browse tables

Distilled from `@tanstack/react-table` v9 skills `getting-started` (with its
`with-tanstack-query` reference) and `table-state`, and `@tanstack/table-core`'s
`table-features`, plus our decisions. The browse is the spine of a
back-office app; this is how we build one.

## Table renders nothing

It is a state machine that tells you which rows and cells exist. All markup
stays ours — the project's `Table` atoms, toolbar and footer are untouched by
adopting it. Anyone expecting a grid component will be surprised; there is no
styling, no filter UI, no export.

What you get is columns as **data** instead of duplicated markup. Before, an
11-column browse listed its columns twice — once as headers, once as cells —
kept in the same order by hand, with a hardcoded `colSpan` in the empty state.
One array replaces all of that, and `colSpan` becomes `columns.length`.

## Features are opt-in

```ts
const features = tableFeatures({ rowSelectionFeature, columnVisibilityFeature })
const helper = createColumnHelper<typeof features, Row>()
const table = useTable({ features, columns, data })
```

v9 registers only what you name, so a plain browse stays small. Register a
feature when the screen uses it, not preemptively.

**Never `legacyCreateColumnHelper`.** It is the v8 compatibility shim: it exists
to carry v8 column definitions across, and new code has none to carry.

**An app where two or more browses share features, a `getRowId` rule or cell
components builds them on `createTableHook`.** One infrastructure module binds
those once; every screen calls the `useAppTable` it returns, so no browse can
drift from the others (`react-table` skill `getting-started`, reference
`create-table-hook`).

## Keep `data` and `columns` stable

**Pass Table the same `data` and `columns` arrays across renders until their
contents change.** Table rebuilds every row whenever `data` is a new array
(`table-core` `createCoreRowModel.js`: `memoDeps: () => [table.options.data]`),
and the column tree whenever `columns` is. After a rebuild it auto-resets
page index, sorting and expansion. With one of those features registered and its
state controlled away from its default, the reset updates the screen's state,
the screen re-renders, and an unstable array starts the rebuild again — a render
loop.

Define `columns` at module scope, or in a `useMemo` keyed on what it is built
from — a saved view's visible-column list included, which must itself be
memoised rather than rebuilt with `.filter().map()` each render. Memoise a slice
or mapping the screen derives for `data`; pass a query's `data` through as it
is.

## Rows the server paged, sorted and filtered

**A browse the server pages, sorts and filters hands Table the page's rows and
registers no row-model factory for those stages.** With no paginated, sorted or
filtered row-model factory, Table passes the rows through untouched
(`table-core` `coreRowModelsFeature.utils`: `table_getPaginatedRowModel` and its
siblings return the previous stage's rows), so what renders is exactly the page
the query returned:

```ts
useTable({ features, columns, data: rows, getRowId: (row) => row.itemid })
```

The total for the footer comes from the query's result, not from Table.

A feature's options exist only when the feature is registered: `TableOptions`
is built from the registered features (`types/TableOptions.d.ts`), so
`manualPagination` and `rowCount` belong to `rowPaginationFeature`,
`manualSorting` to `rowSortingFeature`, `manualFiltering` to
`columnFilteringFeature`. Register `rowSortingFeature` for the header toggle and
its sorting state, still with no sorted row model; the server sorts.

Anything upstream that the query owns must be in the **query key**, or changing
a sort will not refetch.

Which lists are paged upstream at all, and by what, is a UI-architecture
decision rather than a Table one — see the project's browse pattern.

## Where paging state lives

Two valid designs, and mixing them is the bug:

- **URL-owned** (our default) — page and size are search params, the footer
  drives them, and Table's pagination feature is *not* registered. One source of
  truth, and the browse stays shareable.
- **Table-owned** — `rowPaginationFeature` is registered with
  `manualPagination: true`, `rowCount` from the query, and Table holds the page
  state. Correct only for a grid embedded in a larger screen where the page
  number genuinely should not be in the URL.

A browse that registers the pagination feature *and* keeps page in the URL
controls it from the URL: `state: { pagination }` derived from the search
params, and `onPaginationChange` navigating. Uncontrolled pagination beside a
URL page is two sources of truth, and the symptom is a pager that skips or
repeats a page (`react-table` skill `table-state`).

## Row identity

Give Table a stable `getRowId` from the record's real id. The default is the
array index, which breaks selection and React reconciliation the moment rows
reorder or one is removed — exactly what happens when a filter changes.

## What each feature is actually for

- **Column visibility / order** — an ERP browse has more columns than fit. This
  plus persistence is the "saved views" feature; the state object Table exposes
  *is* the saved view, which is most of why adopting Table pays.
- **Row selection** — bulk actions. Selection changes what the toolbar contains,
  so plan the toolbar for it rather than bolting it on. Table's selection state
  is a map keyed by `getRowId`, and nothing resets it when `data` changes, so a
  selection made on one page survives moving to the next while the screen stays
  mounted. Rows on other pages have no `Row` object, so a bulk action reads
  `table.getSelectedRowIds()` — the state's keys — never the selected row model.
  The header checkbox (`getToggleAllPageRowsSelectedHandler`) toggles
  `table.getRowModel().rows`, which on a server-paged browse is the page on
  screen (`table-core` `rowSelectionFeature.utils.js`). Clear the selection with
  `table.resetRowSelection()` when a filter changes, since ids from the previous
  result set no longer match what is shown.
- **Sorting** — Table owns the header state and the toggle cycle. It does not
  write your `ORDER BY`, and it cannot help when a sort column exists on one
  data source and not the other.
- **Virtualization** — only when a screen genuinely cannot page. Paging is the
  better answer for record lists; virtualization is for logs and telemetry.

## Loading

A filter, sort or page change is a navigation: the loader fetches the next page
while the current rows stay on screen, so the grid never empties. Mark the grid
busy while the router is loading, gated by the anti-flash hook — see
`loading-states.md` for the signal and the indicator. The toolbar stays live
throughout; the user needs to be able to correct the filter they just mistyped.
