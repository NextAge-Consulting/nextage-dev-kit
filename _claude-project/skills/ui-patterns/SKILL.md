---
name: ui-patterns
description: The project's recipes and behaviour rules — how each page type is put together, and how the app acts on one topic. Use when composing a screen or changing how something behaves, not what it is made of. Each is a reference file in references/; read the matching ones before building. Complements the design-system skill, which owns the kinds, tokens and components.
user-invocable: false
---

# Recipes and Behaviour Rules

The home for how a project's blocks combine and how its application acts. The
`design-system` skill owns what a thing is made of; this skill owns the two kinds of
reference that govern screens.

## Recipes and behaviour rules

**A recipe** says how one page type (`references/block-types.md` in the `design-system`
skill: BrowseScreen, RecordScreen, SettingsScreen, …) is put together. Its **frame** is a
block in code: fixed, ordered slots accepting named block types, no content, carrying the
behaviour every screen of the type shares. Its **instructions** are this file: which block
fills each slot, and each choice the recipe leaves open as a yes/no or a pick from a closed
list. It names one reference screen that shows it.

**A behaviour rule** says how the app acts on one topic — saving, cancelling, errors,
loading, confirming, feedback, paging, filtering, sorting, navigation — across every
surface. The code that carries it out lives in blocks or shared functions, and the rule
lists them. Three button arrangements can share one save rule.

A reference is one kind, never both. Arrangement that a block owns stays in the block;
a guarantee a component makes is written on the component, not here.

**A reference governs every app unless it says otherwise.** A repository with several
apps on one design system — a shop, a customer portal, an office dashboard — gives a
recipe or rule that holds for some of them an `apps:` line naming those workspaces. Two
references whose apps never meet are never judged against each other, and a screen is
held only to the references that govern its app. Two apps that share a cart share its
rule by both being named on it.

## Which kind, and whether it is one at all

> Would another competent developer plausibly have built this differently, and would the
> difference show to the user as inconsistency?

Yes → it is a recipe instruction or a behaviour rule; write it. No → it is craft; build it
and move on.

| Craft — build it | A rule — settle it |
|---|---|
| Type the name to confirm a destructive action | How a list behaves while it reloads |
| Disabling submit until a required field is filled | Where a failed save shows its failure |
| A spinner on the button you just pressed | What a browse toolbar holds, in what order |

A reference records this project's choice. Guidance equally true in any codebase does not
belong in one.

## How to use them

1. Read `rules/project/ui-inventory.md`, then the recipe for the page type and every
   behaviour rule whose `block-types:` names the block types you are building.
2. Build the screen from the recipe's frame; fill its slots with the blocks it names; make
   each open choice from its closed list. Behaviour comes from the blocks that carry the
   rules, never from the screen.
3. No reference for what you need: research primary sources — a major design system's
   published guidelines, the docs of the library you build on — build it, and write the
   reference pending.

## Writing one

**Writing a reference or an inventory line is rule authoring: invoke the `rule-authoring`
skill first.**

Frontmatter, then a one-line summary, then the rules:

```yaml
---
kind: recipe
frame: browse-screen
reference: apps/web/src/routes/users.tsx
block-types: [BrowseScreen]
ui-status: pending
---
```

```yaml
---
kind: behaviour
code: [packages/ui/src/components/form-actions.tsx, packages/web/src/lib/unsaved-guard.ts]
block-types: cross-cutting
apps: [apps/shop, apps/dealer]
ui-status: pending
---
```

`frame:` names the component as its inventory line does. `block-types:` names the types the
reference governs, or `cross-cutting` for every type. `apps:` names the workspaces the
reference governs, as the root `package.json` declares them; leave it out when it governs
every app. A recipe's reference screen lives in one of its apps.
Every file a rule's `code:` names points back at it (`// ui-behaviour:` on a block,
`// ui-behaviour-code:` elsewhere). `check-ui-status.mjs` fails a pointer that names
nothing.

A reference is an instruction and holds only what the next builder needs:

- **When it applies** — the surfaces and situations, and how to recognise one.
- **How to build it** — each rule present tense and actionable, naming roles and blocks,
  never a size, a pixel or a weight.
- **What is excluded** — "Favourites are not reorderable."

Nothing else: no why, no sources, no incident, no dates, no record of what shipped, no
backlog. The test for every sentence: does it change how the next screen is built?

| Never write | Write instead |
|---|---|
| "The first attempt was a solid fill. It failed because…" | "No background fill of any kind." |
| "We considered X, then tried Y, and settled on Z." | "Z. Never X." |
| "Decided with the customer on 3 March." | *(nothing)* |

## Status

Write a new reference with `ui-status: pending` in its frontmatter and add its inventory
line as pending in the same pass. The human approves it at the review (the
`design-system` skill, "Prove, then put it to the human"), and it becomes `approved` in
both places. **Never mark a reference approved yourself.** One the human sets aside is
`deferred`, with its file's fingerprint on its inventory line, and is pending again when
the file changes.

## Keep this skill at the skills root

It lives at `.claude/skills/ui-patterns/`. Claude Code does not discover a skill nested
under `skills/project/`. `references/` ships empty and a sync never writes into it.
