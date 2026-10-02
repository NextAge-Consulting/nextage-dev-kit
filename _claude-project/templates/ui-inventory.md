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

## The list patterns — pick one, never a third

<!-- project:begin list-patterns -->
| Pattern | For | The row is | Reference |
|---|---|---|---|
| _[e.g. **Browse**]_ | _[first-class records — the things that get their own route]_ | _[the control: clicking it opens the record; no per-row edit affordance]_ | _[`browse-layout.md`]_ |
| _[e.g. **Edit-in-place**]_ | _[short lookup tables — a handful of rows, two or three short columns]_ | _[edited in the grid, with an explicit add row and per-row confirm]_ | _[`lookup-table-editing.md`]_ |

State the boundary between them explicitly. _[e.g. "A record with more than a
couple of fields opens as its own route."]_

Built examples: _[name a real screen for each pattern, with its route]_.
<!-- project:end list-patterns -->

## Every pattern reference, and what it governs

Read the matching one IN FULL before composing that kind of surface.
`.claude/skills/ui-patterns/references/`:

<!-- project:begin pattern-references -->
| File | Governs |
|---|---|
| _[`browse-layout.md`]_ | _[one line: what surface it covers and the decisions it settles]_ |
| _[`loading-states.md`]_ | _[skeleton vs spinner, when an indicator is gated, busy vs disabled]_ |
| _[…one row per reference file that exists…]_ | |
<!-- project:end pattern-references -->

## Components that EXIST — do not hand-roll these

Check a control against this list before writing one.

<!-- project:begin components -->
### _[`@acme/ui/components/` — the project's own display vocabulary]_

| Component | Use for |
|---|---|
| _[`IconButton`]_ | _[**every** icon-only button; its required label feeds both `aria-label` and the tooltip]_ |
| _[…]_ | _[one line each: what it is for]_ |

### _[`@acme/ui/components/ui/` — vendored atoms (shadcn or equivalent)]_

_[List the installed atoms as a plain run of names. e.g. `badge` `button` `card`
`checkbox` `dialog` `input` `label` `popover` `select` `skeleton` `switch` `table`
`tabs` `textarea` `tooltip`]_

### _[`@/components/` — app-level composites]_

| Component | Use for |
|---|---|
| _[`form/FormActions`]_ | _[the submit control of every record form — gating, busy state and status wording in one place]_ |
| _[`form/fields`]_ | _[the bound field set: label, hint and error wired to the form library]_ |
| _[…]_ | |
<!-- project:end components -->

### Hooks

<!-- project:begin hooks -->
_[`useFitPageSize` (paging), `useDelayedLoading` (indicator gating),
`usePermission` (what the current user may do) — one line each]_
<!-- project:end hooks -->

## Standing prohibitions

Each names what to use instead. Add a line the second time something is
hand-rolled.

<!-- project:begin prohibitions -->
- _[**Never hand-roll a save/cancel pair.** Use the form-actions composite.]_
- _[**Never a bare button with only an icon child.** Use the icon-button atom.]_
- _[**Never invent a third list pattern.** If neither fits, stop and discuss.]_
<!-- project:end prohibitions -->

## Keeping this file true

**The regions list what exists — components, patterns, hooks, and the "never
hand-roll X, use Y" prohibitions — and nothing else.** A rule about how work is
done goes in an issue on the kit's repository when every project needs it, or in
its own file under `.claude/rules/project/` when only this one does — never here.

Generated from the filesystem, not from memory. Invoke the `rule-authoring` skill
before editing it, and edit only inside the project regions.

- **A new pattern** → the `ui-patterns` skill's write-once step adds its line here.
- **A new component** → the `design-system` skill's reconciliation pass adds its
  line here.
