---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Inventory: What Already Exists (Zero Tolerance)

**Read this list before composing a screen. Name the block type you need, use this
project's block of that type, follow the recipe for the page type, and never hand-roll
anything listed here.**

---

> **The kit owns every line outside the `project:begin` / `project:end` markers;
> this project owns everything between them.** Replace the bracketed examples
> inside each region with what this project actually has, enumerated from the
> filesystem. Edit only inside the markers — sync carries the regions and
> rewrites everything else from the kit.

## How this list works

- **It lists the pieces of the system — every recipe, behaviour rule, component and
  hook, one line each on what it is for — and nothing else.** A screen's content is
  never listed. A rule about how a kind of screen works goes in its recipe.
- **Each component carries its block type** from the `design-system` skill's
  `references/block-types.md`, agreeing with the `// ui-block:` line in its file. A
  vendored atom carries none. A second block of one type carries, on its line, the
  human's reason it is not the first.
- **Each line carries its status**, `approved`, `pending` or `deferred`, the same as the
  `ui-status` line in its file. Pending means built and not yet approved by the human.
  Deferred means the human chose not to look: its cell reads `` deferred `<fingerprint>` ``
  (`check-ui-status.mjs --fingerprint <file>`), it blocks nothing, and once the file
  changes it is pending again.
- **Add a line in the same change that adds the piece**, enumerated from the filesystem,
  never from memory. Invoke the `rule-authoring` skill before editing.
- `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` fails while this list and
  the files disagree, a pointer names nothing, or anything is pending; `/deploy` refuses
  until it passes.

## Recipes

How each page type is put together. Read the one for your page type in full before
composing it. `.claude/skills/ui-patterns/references/`:

<!-- project:begin recipes -->
| File | Page type | Frame | Status |
|---|---|---|---|
| _[`browse-screen.md`]_ | _[BrowseScreen]_ | _[`browse-screen`]_ | _[approved]_ |
| _[…one row per recipe file…]_ | | | |
<!-- project:end recipes -->

## Behaviour rules

How the app acts on one topic, everywhere. Read every rule whose block types you touch.

<!-- project:begin behaviour-rules -->
| File | Governs | Status |
|---|---|---|
| _[`saving.md`]_ | _[Save then Close on a page, Cancel first in a dialog; the dirty gate; where a failure shows]_ | _[approved]_ |
| _[`loading.md`]_ | _[skeleton on rows, spinner on the pressed control, label never changes]_ | _[pending]_ |
| _[…one row per rule file…]_ | | |
<!-- project:end behaviour-rules -->

## Components

<!-- project:begin components -->
### _[`@acme/ui/components/` — the project's blocks]_

| Component | Use for | Type | Status |
|---|---|---|---|
| _[`ModalShell`]_ | _[screen content in a popup that ends with Close]_ | _[ModalShell]_ | _[approved]_ |
| _[`ReviewDialog`]_ | _[a pre-flight report of a write, then its result]_ | _[ReviewDialog]_ | _[approved]_ |
| _[`FactList`]_ | _[read-only facts as label and value pairs]_ | _[FactList]_ | _[pending]_ |
| _[…]_ | _[one line each: what it is for]_ | | |

### _[`@acme/ui/components/ui/` — the atoms (shadcn or equivalent)]_

| Atom | Status |
|---|---|
| _[`button`]_ | _[approved]_ |
| _[…one row per atom…]_ | |

### _[`@/components/` — an app's own blocks, each with the human's reason]_

| Component | Use for | Type | Status |
|---|---|---|---|
| _[`PortalShell`]_ | _[the signed-in frame of the customer portal; differs from the shared AppShell by the human's decision: no module navigation]_ | _[AppShell]_ | _[approved]_ |
| _[…]_ | | | |
<!-- project:end components -->

## Hooks

<!-- project:begin hooks -->
| Hook | Use for |
|---|---|
| _[`useFitPageSize`]_ | _[paging: how many rows fit]_ |
| _[…]_ | |
<!-- project:end hooks -->

## Never hand-roll

Each line names the block to use instead.

<!-- project:begin prohibitions -->
- _[**Never a bare button with only an icon child.** Use the icon-button atom.]_
- _[**Never a screen's own save row.** Use the FormActions block.]_
<!-- project:end prohibitions -->
