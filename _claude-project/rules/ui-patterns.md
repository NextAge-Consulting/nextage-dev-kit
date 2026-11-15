---
paths: "{**/*.tsx,**/*.jsx}"
---

# Recipes and Behaviour Rules

**Invoke the `ui-patterns` skill before composing a screen or changing how the app
behaves** — a screen's arrangement, saving, cancelling, errors, loading, confirming,
feedback, paging, filtering, inline edit, multi-step flows. Then read the recipe for the
page type and every behaviour rule whose `block-types:` names the block types you touch
and whose `apps:` line, when it has one, names the app you are in, in
`.claude/skills/ui-patterns/references/`.

```
Skill({skill: "ui-patterns"})
```

## Sibling to the design rule

`ui-design.md` routes to the `design-system` skill and owns the kinds, the tokens and the
components. This rule owns the two kinds of reference: a **recipe** says how one page type
is put together; a **behaviour rule** says how the app acts on one topic. The skill says
how each is written.

## The project keeps an inventory

Every project maintains `rules/project/ui-inventory.md`: every recipe, behaviour rule,
component and hook the project has, one line each, with each component's block type and
each recipe's, rule's and component's status. Read it before composing a screen, and update it in the same change
that adds a piece.

## Name the recipe while agreeing the work

A plan deliverable that produces a screen, dialog, panel or report names its page type
and its recipe in the sentence that agrees it. A screen step with neither gets them before
it starts: an existing recipe, or one written pending.

## A rule with no reference yet is researched, never improvised

Research primary sources — the published guidelines of a major system, or the docs of the
library you build on — build it, and write its reference marked pending. The human
approves it at the review. The kit holds no view on what the rule should say.

**References are project-owned.** The kit ships this rule and the skill; `references/`
arrives empty and a sync never writes into it.
