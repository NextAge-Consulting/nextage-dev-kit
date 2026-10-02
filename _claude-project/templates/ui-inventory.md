---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Inventory: What Already Exists (Zero Tolerance)

**Read this list before composing a screen. Use what exists; never hand-roll
anything listed here.**

---

> **The kit owns every line outside the `project:begin` / `project:end` markers;
> this project owns everything between them.** Replace the bracketed examples
> inside each region with what this project actually has, enumerated from the
> filesystem. Edit only inside the markers — sync carries the regions and
> rewrites everything else from the kit.

## How this list works

- **It lists what exists — every pattern, component and hook, one line each on what
  it is for — and nothing else.** A rule about how a kind of screen works goes in
  that pattern's reference.
- **Each pattern and component carries its status**, `approved` or `pending`, the
  same as the `ui-status` line in its file. Pending means built and not yet approved
  by the human.
- **Add a line in the same change that adds the thing**, enumerated from the
  filesystem, never from memory. Invoke the `rule-authoring` skill before editing.
- `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` fails while this list
  and the files disagree or anything is pending, and `/deploy` refuses until it passes.

## Patterns

Read the matching reference IN FULL before composing that kind of surface.
`.claude/skills/ui-patterns/references/`:

<!-- project:begin pattern-references -->
| File | Governs | Status |
|---|---|---|
| _[`browse-layout.md`]_ | _[one line: what surface it covers and the decisions it settles]_ | _[approved]_ |
| _[`loading-states.md`]_ | _[skeleton vs spinner, when an indicator is gated, busy vs disabled]_ | _[pending]_ |
| _[…one row per reference file that exists…]_ | | |
<!-- project:end pattern-references -->

## Components

<!-- project:begin components -->
### _[`@acme/ui/components/` — the project's own display vocabulary]_

| Component | Use for | Status |
|---|---|---|
| _[`IconButton`]_ | _[**every** icon-only button; its required label feeds both `aria-label` and the tooltip]_ | _[approved]_ |
| _[…]_ | _[one line each: what it is for]_ | |

### _[`@acme/ui/components/ui/` — vendored atoms (shadcn or equivalent)]_

| Atom | Status |
|---|---|
| _[`button`]_ | _[approved]_ |
| _[…one row per installed atom…]_ | |

### _[`@/components/` — app-level composites]_

| Component | Use for | Status |
|---|---|---|
| _[`form/FormActions`]_ | _[the submit control of every record form — gating, busy state and status wording in one place]_ | _[approved]_ |
| _[`form/fields`]_ | _[the bound field set: label, hint and error wired to the form library]_ | _[approved]_ |
| _[…]_ | | |
<!-- project:end components -->

## Hooks

<!-- project:begin hooks -->
| Hook | Use for |
|---|---|
| _[`useFitPageSize`]_ | _[paging: how many rows fit]_ |
| _[…]_ | |
<!-- project:end hooks -->

## Never hand-roll

Each line names what to use instead.

<!-- project:begin prohibitions -->
- _[**Never hand-roll a save/cancel pair.** Use the form-actions composite.]_
- _[**Never a bare button with only an icon child.** Use the icon-button atom.]_
<!-- project:end prohibitions -->
