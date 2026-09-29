---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Patterns Rule

**Invoke the `ui-patterns` skill before building or changing how a surface is composed or how it behaves** — screen and toolbar layout, pagination, filtering, autosave, optimistic updates, loading / empty / error states, inline edit, multi-step flows. Then read the reference for the pattern you are using, from `.claude/skills/ui-patterns/references/`, named for that pattern.

```
Skill({skill: "ui-patterns"})
```

## Sibling to the design rule

`ui-design.md` routes to the `design-system` skill and owns what a thing is made of — tokens, atoms, `design.md`. This rule owns how things are assembled and how they act. Where a change could belong to either, the skill's boundary test decides.

## The project keeps an inventory

Every project maintains `rules/project/ui-inventory.md`, with the same `paths:` frontmatter as this file. The kit seeds it on first sync and the project owns every line from then on. It holds:

- **The pattern index** — every pattern the project has, one line each, and what it governs.
- **The component inventory** — atoms, composites and hooks, enumerated from the filesystem, one line on what each is for.
- **The standing prohibitions** — the things never to hand-roll, each naming what to use instead.

Update it in the same change that adds a pattern or a component.

## Every UI change states what it was built from (Zero Tolerance)

**End the reply that delivers UI with a `Built from:` line naming the existing file you matched.**

```
Built from: packages/ui/src/components/record-header.tsx
Built from: src/components/ui/dialog.tsx (leveled up: added the divided regions)
Built from: none — new pattern, researched and agreed first
```

Open the named file beside what you built and make them match. No line means the work is not done.

## Name the pattern while agreeing the work

**Name a screen's pattern in the plan document, in the sentence that agrees the screen.** A plan deliverable that produces a screen, dialog, panel or report names its pattern.

- **Writing a plan** → name the pattern in the same sentence that agrees the screen.
- **Reading a plan before executing it** → raise a screen step with no named pattern before that step starts.

**No pattern fits? Stop and discuss.** Never invent one mid-build.

## A pattern names roles, never values

A pattern describing a composite — a row, a card, a field block — names which token role each part uses and states no sizes. "A row carries a `row-title`, a `row-subtitle` and a `metadata` line", never "13.5px, semibold".

A part no role names is a missing role: raise it with the design system rather than inventing a size in a pattern.

## Is it even a pattern?

It is a pattern if another competent developer would plausibly have built it differently and the difference would show to the user as inconsistency. Otherwise it is craft — build it and move on. The skill carries the test and the examples.

**A pattern with no reference yet is researched, never improvised from training data.** Research primary design-system sources — the published guidelines of a major system such as Material, Apple's HIG, or the docs of the library you are building on — agree the approach with the human, build it, and write the reference as the skill directs.

**Patterns are project-owned.** The kit ships this rule and the skill; `references/` arrives empty and a sync never writes into it. To use another project's pattern, copy it across by hand or re-decide it here.

## The one carve-out

A purely presentational component — no state, no mutations, no transitions, no layout decisions of its own — does not need this.
