# Block types

The kinds of building block a business application is made of. Each app designs its
own look for each one; this list is the vocabulary that tells you which one you are
building.

## Sort before you build

1. **Name the block type** of every frame you are about to build — a dialog, a panel, a
   header, a toolbar, a row, a whole screen's layout. Match it by what it is and how it
   ends, never by what it contains.
2. **Find this app's part of that type** in `rules/project/ui-inventory.md` (its Type
   column) and use it. Read every pattern reference whose `block-types:` names the type.
3. **None yet → build the part now, from this first use,** pending, named for the kind
   (`ReviewDialog`, never `CustomerNotesDialog`). Its inventory line carries the type.
4. **No type fits → it is this app's own.** Drawing no box, it stays in its screen's
   feature folder until a second screen needs it, then becomes a part typed `<none>`.
   Drawing a box, it is a part typed `<none>` from the start.

**One part per type is the norm.** A second part of the same type is a question for the
human: same thing, and it folds into the first; different, and their reason goes on its
inventory line.

**Two overlays that end differently are two types.** A popup that ends Close is not a
popup that ends Save.

A frame atom — the atom a type's **Wraps** cell names — is imported only inside a part.

## Overlays

| Type | What it is | You need it when / how it ends | Not to be confused with | Wraps |
|---|---|---|---|---|
| ModalShell | Screen content in a popup — a browse, a lookup list, a must-read message, a form whose actions live inside it | Ends ✕ / Close, or OK | EntityModal (ends Save) | Dialog |
| EntityModal | Create or edit one record in a popup, at any size | Ends Save or Create / Cancel | EditDrawer (page stays visible) | Dialog |
| ConfirmDialog | One short question about an action, destructive or not | Ends Yes / No; no inputs | ReviewDialog (has detail); PromptDialog (asks a value) | AlertDialog |
| PromptDialog | Asks for one value before an action proceeds | Ends Confirm / Cancel, with one input | EntityModal (a whole record) | Dialog |
| ReviewDialog | A detailed pre-flight report of a write — counts, tables, problems — then its result | Ends Continue / Cancel after inspection; Continue shows busy | ConfirmDialog (one line) | Dialog |
| PickerDialog | Choose one or many records from a searchable list, returned to the field that opened it | Ends by selecting — a row click, or Select | FilterPopover (narrows a list) | Dialog |
| EditDrawer | Create or edit a record in a side panel while the page stays readable | Ends Save / Cancel | EntityModal (covers the page) | Sheet |
| DetailDrawer | A read-only look at a record without leaving the screen | Ends ✕; offers the full record | EditDrawer (edits) | Sheet |
| FilterPopover | A small anchored panel setting one or a few filters | Applies live or on Apply; closes on click-away | FilterPanel (always open) | Popover |
| ColumnChooser | Show, hide and order a table's columns | Applies live, or Apply / Reset | FilterPopover | Popover |
| InlineEdit | Edit one value where it is shown | Enter saves, Esc cancels | EditDrawer | |

## Screen frames

| Type | What it is | Not to be confused with |
|---|---|---|
| AppShell | The frame around every signed-in screen: top bar, navigation, account entry | AuthShell |
| NavRail | The app's section navigation | RecordTabs |
| AccountMenu | Who is signed in, and their account actions | |
| AuthShell | The frame around signed-out screens: sign-in, reset, register | AppShell |
| ScreenHeading | The title and screen-level actions of a screen that is not one record | RecordHeader |
| ModuleLanding | A module's entry screen: tiles or links to its screens | DashboardScreen |
| BrowseScreen | Find and act on many records: heading, toolbar, collection, pager | ListDetailScreen |
| RecordScreen | One record: header, then sections or tabs, then related lists | EntityModal |
| ListDetailScreen | A list and one record side by side; selecting does not navigate | DetailDrawer |
| DashboardScreen | A read-only overview of tiles and cards that click through | ModuleLanding |
| SettingsScreen | Grouped preferences with one save behaviour | RecordScreen |
| Wizard | A guided multi-step create, Next / Back, with a summary last | ReviewDialog |

## Record

| Type | What it is | Not to be confused with |
|---|---|---|
| RecordHeader | The identity, key facts, status and primary actions of one record | ScreenHeading |
| RecordTabs | Moves between the sections of one record | NavRail |
| FieldGroup | A titled group of a record's fields, read or edit | RecordScreen |
| FormActions | The submit control of an edit surface: Save gated on changes, busy, and its status words | ConfirmDialog |
| RelatedList | A record's child records, with their own add action | BrowseScreen |
| ActivityTimeline | The append-only history of events on a record or account | Row |
| StageTracker | A record's place in a linear process, which may advance it | Wizard |

## Collections

| Type | What it is | Not to be confused with |
|---|---|---|
| BrowseToolbar | Search, filters, view switch and add above a collection; with rows selected, it carries their bulk actions | ScreenHeading |
| Row | One record in a collection, as a table row or a card | ExpandableRow |
| RowActions | A row's own actions, inline or in an overflow menu | BrowseToolbar |
| ExpandableRow | A row that discloses detail or an editor in place | DetailDrawer |
| CardGrid | A collection laid out as cards | Row |
| EditableTable | A table edited in place, row by row | BrowseScreen |
| Pager | Page navigation, page size and the record count | |

## Filtering

| Type | What it is | Not to be confused with |
|---|---|---|
| FilterPanel | Filters that stay open beside or above a collection — facets, a bar of fields, or a token search | FilterPopover |
| FilterChips | The active filters, each removable, with Clear all | |
| SavedViews | Named filter-and-sort combinations, as tabs or a menu | FilterChips |

## Feedback and status

| Type | What it is | Not to be confused with |
|---|---|---|
| EmptyState | Nothing to show — first use, no results, or not allowed — with the next action | ErrorState |
| ErrorState | A failure shown in place of the region that failed, including a record or route not found | EmptyState |
| PageBanner | A standing message about the screen that stays until resolved or dismissed | ErrorState |
| ImpersonationBanner | Says the user is viewing as someone else, and how to stop | PageBanner |
| StatusBadge | A status word in its tone, from one vocabulary | |
| StatTile | One headline figure, which may drill through | StatusBadge |
| StatRow | A row of StatTiles | DashboardScreen |
| SaveStatus | Saving, saved or failed, on a surface that saves itself with no Save button | FormActions |
