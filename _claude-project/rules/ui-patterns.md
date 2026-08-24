---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Patterns Rule

**Invoke the `ui-patterns` skill before building or changing how a surface is composed or how it behaves** — screen and toolbar layout, pagination, filtering, autosave, optimistic updates, loading / empty / error states, inline edit, multi-step flows. Then read the reference for the pattern you are using, from the skill's own `references/` directory, named for that pattern.

```
Skill({skill: "ui-patterns"})
```

## Sibling to the design rule

`ui-design.md` routes to the `design-system` skill and owns what a thing is made of — tokens, atoms, `design.md`. This rule owns how things are assembled and how they act.

Most interactive work trips both, and the boundary test lives in the skill: what lever does this pull — one `design.md` already owns, or something beyond it? This rule is path-targeted to `.tsx` and `.jsx`, where composition and behaviour are authored, and does not load on CSS or `design.md`.

## The project keeps an inventory, and it carries content

**A pointer is not enough, and the failure is documented:** this rule and `ui-design.md` both load automatically on every UI edit, and a screen still shipped that reinvented a list pattern and hand-rolled a submit control whose component was one import away. Following a pointer is a separate act, chosen at the moment you already feel ready to write — exactly when it gets skipped.

So every project maintains `rules/project/ui-inventory.md`, with the same `paths:` frontmatter as this file so it loads on the same edits. The kit seeds it on first sync and the project owns every line from then on. It holds content, not references:

- **The pattern index** — every pattern the project has, one line each, and what it governs. Enough to pick the right one without opening anything, and enough that "there was no pattern" is falsifiable.
- **The component inventory** — what actually exists, enumerated from the filesystem rather than remembered: atoms, composites, hooks, one line on what each is for.
- **The standing prohibitions** — the things that keep getting rebuilt, written as prohibitions rather than as advice to go and look.

Generate it from the filesystem and update it in the same change that adds a component. An inventory that lags is worse than none, because it is read as complete.

## Name the pattern while agreeing the work

**Name a screen's pattern in the plan document, in the sentence that agrees the screen** — not while it is being built.

This is the only check that fires at the moment the decision is actually made. Edit-time enforcement cannot work: by then the shape is already decided, and the rule reads as something you should have done already.

**No pattern fits? Stop and discuss.** That is never a licence to invent one mid-build. A missing name is a visible hole; "did you follow the patterns?" is unfalsifiable and gets waved through.

## Is it even a pattern?

A reference settles a question that had more than one defensible answer. If another competent developer would plausibly have built it differently, and that difference would show as inconsistency to the user, it is a pattern. If there is one obvious way anyone would reach on their own, it is craft — build it and move on. The skill carries the test and the examples.

**If it is a pattern and has no reference yet, do not improvise from training data.** Research primary design-system sources — the published guidelines of a major system such as Material, Apple's HIG, or the docs of the library you are building on, never a blog summary of them — agree the approach with the human, then implement it *and* capture it as a new file in the skill's `references/`.

That prevents two things, both of which have happened here: a plausible-but-wrong first attempt surviving review because the result looks fine — autosave debounced on every keystroke is the canonical case — and the same question re-argued on a later screen, reaching a different answer, because the reasoning behind the first was never written down.

## The one carve-out

A purely presentational component — no state, no mutations, no transitions, no layout decisions of its own — does not need this. Those are rarer in `.tsx` than they sound.
