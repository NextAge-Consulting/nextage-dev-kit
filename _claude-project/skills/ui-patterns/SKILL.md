---
name: ui-patterns
description: The project's own UI patterns — how surfaces are COMPOSED and how they BEHAVE. Browse/list layouts, pagination, filtering, autosave, optimistic updates, loading/empty/error states, inline edit, multi-step flows. Use when building or changing how something is assembled or how it acts, not what it is made of. Each pattern is a reference file in references/; read the matching one before implementing. Complements the design-system skill, which owns tokens and atoms.
user-invocable: false
---

# UI Patterns

The home for **composition and behaviour**:

- **`design-system`** — what a thing is *made of*. Tokens, atoms, colour, type,
  spacing, `design.md` compliance.
- **`ui-patterns`** (this skill) — how things are *assembled* and how they
  *act*. Screen layouts, toolbars, pagination, autosave, optimistic UI, empty
  and error states, inline edit, wizards.

## The boundary test

> **What lever does this change pull?** If it is a lever `design.md` or a stock
> component already owns — a colour, a radius, a button variant, a row height —
> it is `design-system`. If it goes beyond what `design.md` is scoped to, it is
> here.

| Decision | Home |
|---|---|
| Row height | design-system |
| Which button variant a toolbar action uses | design-system |
| Adding a `popover` atom | design-system |
| How a page decides how many rows to show | **ui-patterns** |
| What a toolbar contains and in what order | **ui-patterns** |
| Showing active filters as a count vs. as chips | **ui-patterns** |

## A pattern names the ROLES its parts play

When a pattern describes a composite — a row, a card, a field block, a toolbar —
it names which token role each part uses and says nothing about sizes.

> A row carries a `row-title`, a `row-subtitle` beneath it, and a `metadata` line.

A part no role names is a missing role — raise it with the design system, never
invent a size here. The `design-system` skill's token section covers how a role
gets named.

## Keep this skill at the skills root

It lives at `.claude/skills/ui-patterns/`. Claude Code does not discover a skill
nested under `skills/project/`.

## First: is it even a pattern?

> **Would another competent developer plausibly have built this differently, and
> would that difference show up to the user as inconsistency?**

Yes → it is a pattern. Write its reference (below).
No → it is craft. Build it and move on.

| Craft — build it | A pattern — settle it |
|---|---|
| Type the name to confirm a destructive action | How a list behaves while it reloads: skeleton, spinner, blank, or hold the old rows |
| Disabling submit until a required field is filled | Whether filters show as chips or a count |
| A spinner on the button you just pressed | What a toolbar contains and in what order |
| Marking the current nav item as active | How a screen decides how many rows to show |

**A reference records THIS project's choice.** Guidance equally true in any
codebase does not belong in one.

## How to use it

1. **Look in `references/`** — one file per pattern, named for the pattern, first
   line summarising it. Read the matching one **before** implementing.
2. **No reference for what you need? Research primary sources first.**
   Real design systems — GitHub Primer, Nielsen Norman, GitLab Pajamas, Material,
   PatternFly, Oracle's grid guidance — not model memory. Then build it, write its
   reference marked pending (below), and carry on.
3. **Patterns still obey the visual layer.** Invoke the `design-system` skill for
   any styling the pattern needs; `rules/a11y-baseline.md` auto-loads on JSX and is
   authoritative for accessibility.

## A new pattern is written pending; only the human approves it (Zero Tolerance)

**Write the reference when you build the pattern, with `ui-status: pending` in its
frontmatter, and add its line to `rules/project/ui-inventory.md` as pending in the
same pass.** The human approves it at the review (the `design-system` skill's Step
2), and it becomes `approved` in both places. If they ask for changes, change the
build and rewrite the reference to match.

**Never mark a pattern approved yourself** — not in an autonomous session, not to
close your own loop. Keep the research and the discarded options in the build's own
code comments.

## What a reference holds

**Writing a reference or an inventory line is rule authoring: invoke the
`rule-authoring` skill first**, whatever tool writes the file.

A reference is an instruction, and it holds only what the next builder needs:

- **When it applies** — the surfaces and situations it governs, and how to
  recognise one.
- **How to build it** — each rule present tense and actionable.
- **What is excluded** — a prohibition: "Favourites are not reorderable — no
  drag-to-reorder."
- **Known limitations** of the pattern as specified.

Nothing else. No why, no evidence, no sources, no incident, no dates, no names, no
"originally", no record of what shipped or was removed. The pattern is the law
because the project adopted it.

| Never write | Write instead |
|---|---|
| "The first attempt was a solid fill. It failed because…" | "No background fill of any kind." |
| "The tabs went through two lives and lost both…" | "The top bar holds no navigation." |
| "We considered X, then tried Y, and settled on Z." | "Z. Never X." |
| "Decided with the customer on 3 March." | *(nothing)* |

**Never a backlog.** A reference carries no feature ideas, no "future" or "still
open" section, no open product questions and no status of what is built. Those go
wherever the project tracks work.

The test for every sentence: **does it change how the next screen is built?** No →
cut it.

## Adding a reference

One file per pattern in this project's `references/`, which the kit ships empty
and a sync never overwrites. Open with frontmatter carrying its `ui-status`, lead
with a one-line summary of the rule, then the rules themselves. Keep it short.
