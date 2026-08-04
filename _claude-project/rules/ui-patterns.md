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

## The non-negotiable

If the pattern you are building has **no reference yet**, do NOT improvise from
training data. Research primary design-system sources first, agree the approach,
then implement AND capture it as a new `references/*.md`.

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
