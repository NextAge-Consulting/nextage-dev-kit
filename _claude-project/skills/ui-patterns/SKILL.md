---
name: ui-patterns
description: The project's own UI patterns — how surfaces are COMPOSED and how they BEHAVE. Browse/list layouts, pagination, filtering, autosave, optimistic updates, loading/empty/error states, inline edit, multi-step flows. Use when building or changing how something is assembled or how it acts, not what it is made of. Each pattern is a reference file in references/, backed by primary-source research; read the matching one before implementing. Complements the design-system skill, which owns tokens and atoms.
---

# UI Patterns

The home for **composition and behaviour** — the layer `design-system`
explicitly disclaims. The split:

- **`design-system`** — what a thing is *made of*. Tokens, atoms, colour, type,
  spacing, `design.md` compliance. **Look.**
- **`ui-patterns`** (this skill) — how things are *assembled* and how they
  *act*. Screen layouts, toolbars, pagination, autosave, optimistic UI, empty
  and error states, inline edit, wizards. **Feel.**

## The boundary test

There is a grey middle, and one question resolves it:

> **What lever does this change pull?** If it is a lever `design.md` or a stock
> component already owns — a colour, a radius, a button variant, a row height —
> it is `design-system`. If it goes beyond what `design.md` is scoped to, it is
> here.

Worked examples of the same screen splitting across both:

| Decision | Home | Why |
|---|---|---|
| Row height | design-system | `design.md` already carries it |
| Which button variant a toolbar action uses | design-system | Button emphasis is an atom concern |
| Adding a `popover` atom | design-system | It is an atom |
| How a page decides how many rows to show | **ui-patterns** | No `design.md` lever exists; it is behaviour |
| What a toolbar contains and in what order | **ui-patterns** | Composition |
| Showing active filters as a count vs. as chips | **ui-patterns** | A UX decision with a rationale worth not re-litigating |

## Why it lives at the skills root

Claude Code discovers skills at `.claude/skills/<skill-name>/SKILL.md` **only** —
the directory name *is* the skill name. Nesting it (e.g.
`.claude/skills/project/ui-patterns/SKILL.md`) makes discovery look for
`.claude/skills/project/SKILL.md`, find nothing, and skip everything beneath it:
the skill silently stops existing. There is no namespacing mechanism. The one
supported nesting is per-directory monorepo scope
(`apps/web/.claude/skills/<name>/`), which is scope, not grouping. Skills root is
the only option — do not "fix" this. Project-local *rules* still belong in
`.claude/rules/project/`; that convention does not and cannot extend to skills.

## How to use it

1. **Look in `references/`** — one file per pattern, named for the pattern, first
   line summarising it. Read the matching one **before** implementing. It carries
   the decided approach and the sources behind it, so it is not re-derived (or
   re-guessed) each time.
2. **No reference for what you need? STOP and research primary sources first.**
   Real design systems — GitHub Primer, Nielsen Norman, GitLab Pajamas, Material,
   PatternFly, Oracle's grid guidance — not model memory. Agree the approach,
   *then* implement, *then* add a `references/*.md` capturing the blueprint and
   the sources.
3. **Patterns still obey the visual layer.** Run `design-system` for any styling
   the pattern needs, and the a11y baseline for JSX.

## Why this skill exists

Composition and interaction are where a plausible first attempt is most often
subtly wrong, and wrong in ways that survive review because the result *looks*
fine. The canonical example is autosave: debouncing the save on every keystroke
is the obvious implementation and it interrupts typing. The fix is research
before code, captured durably — the cost of researching once is paid once, the
cost of guessing is paid on every screen.

The second failure this prevents is quieter: the same question re-argued from
scratch on screen 7 because the reasoning behind screen 1 was never written
down, arriving at a different answer, and leaving the product inconsistent.

## Adding a reference

One file per pattern in `references/`. Lead with a one-line summary, then the
decision, then **why** — including the options rejected and what they cost, so
the next reader can tell a considered choice from an arbitrary one. Cite the
primary sources. Note what is still open.

Keep them short. A reference nobody finishes reading does not get followed.
