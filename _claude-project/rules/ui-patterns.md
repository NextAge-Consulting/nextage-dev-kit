---
paths: "{**/*.tsx,**/*.jsx}"
---

# UI Patterns Rule

**Before building or changing how a surface is COMPOSED or how it BEHAVES —
screen and toolbar layout, pagination, filtering, autosave, optimistic updates,
loading / empty / error states, inline edit, multi-step flows — invoke the
`ui-patterns` skill and read the matching `references/*.md`.**

```
Skill({skill: "ui-patterns"})
```

## Sibling to the design rule

- **`ui-design.md`** → `design-system` skill — what a thing is *made of*:
  tokens, atoms, `design.md`. **Look.**
- **`ui-patterns.md`** (this) → `ui-patterns` skill — how things are *assembled*
  and how they *act*. **Feel.**

Most interactive work trips both. The boundary test lives in the skill: *what
lever does this pull* — one `design.md` already owns, or something beyond it?

This rule is path-targeted to `**/*.tsx` / `**/*.jsx`, where composition and
behaviour are authored. It does not load on CSS or `design.md` — that is styling,
owned by `ui-design.md`.

## The project keeps an INVENTORY, and it carries content

**This rule and `ui-design.md` are pointers — they tell you to go and read
something. That is not enough, and the failure is documented: both files load
automatically on every UI edit, and a screen still shipped that reinvented a
list pattern and hand-rolled a submit control whose component was one import
away.** Following a pointer is a separate act, chosen at the moment you already
feel ready to write, which is exactly when it gets skipped.

So every project maintains an inventory rule — conventionally
`rules/project/ui-inventory.md`, with the same `paths:` frontmatter as this file
so it loads on the same edits — and it carries **content, not references**:

- **The pattern index.** Every pattern the project has, one line each, and what
  it governs. Enough to pick the right one without opening anything, and enough
  that "there was no pattern" is falsifiable.
- **The component inventory.** What actually exists, enumerated from the
  filesystem rather than remembered — atoms, composites, hooks — and one line on
  what each is for.
- **The standing prohibitions.** The things that keep getting rebuilt, written as
  prohibitions rather than as advice to go and look.

**Generated from the filesystem and updated in the same change that adds a
component.** An inventory that lags is worse than none, because it is read as
complete.

## Name the pattern while agreeing the work

**A screen's pattern is named when the work is planned, not chosen while it is
built.** In the plan document, in the sentence that agrees the screen: which
pattern it follows.

This is the only check that fires at the moment the decision is actually made.
Edit-time enforcement cannot work, because by then the shape is already decided
and the rule reads as something you should have done already.

**If no pattern fits, that is the signal to stop and discuss** — never a licence
to invent one mid-build. A missing name is a visible hole; "did you follow the
patterns?" is unfalsifiable and gets waved through.

## The non-negotiable

**First, is it even a pattern?** A reference settles a question that had more
than one defensible answer. If another competent developer would plausibly have
built it differently, and that difference would show as inconsistency to the
user, it is a pattern. If there is one obvious way anyone would reach on their
own, it is craft — build it and move on. The skill carries the test and
examples.

If it IS a pattern and has **no reference yet**, do NOT improvise from training
data. Research primary design-system sources first, agree the approach, then
implement AND capture it as a new `references/*.md`.

Two things this prevents, both of which have happened:

- **A plausible-but-wrong first attempt that survives review** because the result
  looks fine. Autosave debounced on every keystroke is the canonical case.
- **The same question re-argued on a later screen**, reaching a different answer,
  leaving the product inconsistent — because the reasoning behind the first
  screen was never written down.

## When this rule is wrong

Rarely. A purely presentational component — no state, no mutations, no
transitions, no layout decisions of its own — does not need it. Those are less
common in `.tsx` than they sound.
