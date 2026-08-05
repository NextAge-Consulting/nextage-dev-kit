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
   *then* implement, *then* **wait for the human to review the built UI and call
   it good** — and only then write the `references/*.md`, once. See "Write it
   ONCE, after sign-off" below; this gate is not optional.
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

## Write it ONCE, after sign-off, describing only the approved result (Zero Tolerance)

**A pattern becomes a pattern when the human has looked at the working UI and
called it good. Two people, not one.** Until then there is a proposal, and a
proposal does not go in `references/`.

The order is: research → agree the approach → build → **human reviews and
approves** → write the reference, once. Hold the research and the discarded
options in the build's own code comments meanwhile; that is where they are useful
during review anyway. **Say the reference is still owed** when you hand off for
review, so it is not forgotten once the design is blessed.

### The timing IS what makes it present-tense

These are not two rules. Writing once, at the end, means the only thing you can
describe is the approved end state — the iterations are not yours to record
because you were not writing during them.

Write as you go instead and the file becomes a diary by construction: each round
of review leaves a scar ("the first attempt was…", "once X was removed…"), and
the next writer reads that shape as the house style and adds their own chapter.

So a reference **states what the rule IS, never how it was arrived at** — this is
constitution §XV applied to this skill. No dates, no "originally", no "we changed
this because", no status of what shipped when. That history lives in git.

| Never write | Write instead |
|---|---|
| "The first attempt was a solid fill. It failed because…" | "No background fill of any kind — a starred screen indicates in two places at once." |
| "The tabs went through two lives and lost both…" | "The top bar holds no navigation." |
| "Once the tabs were gone, sections became independent for free." | "Sections are independent." |
| "We considered X, then tried Y, and settled on Z." | "Z. Never X — <cost>." |

**A discarded option is recorded as a present-tense prohibition, not a story.**
"Never store favourites in `localStorage` — they must follow the user across
machines" carries everything the next builder needs. "We tried localStorage first
and it stranded people per-device" carries the same fact plus a chapter of
autobiography.

### Why the gate exists at all

- **Writing early stamps "decided" on something undecided.** Everything in
  `references/` is read by the next session as settled and followed without
  re-litigation. A writeup of a design nobody has reviewed launders one party's
  judgment into house style.
- **Every round of review then costs a second edit** — chase the doc or let it go
  stale — and it is those chases that deposit the narrative in the first place.

## A reference is GUIDANCE, never a backlog (Zero Tolerance)

**These files are rules an AI follows when building UI. Nothing belongs in one
except how to build the pattern.** A product idea parked in a reference is read
by the next session as direction, and gets built.

So a reference NEVER carries:

- **Feature ideas or "what we could add next."** Not in a "Still open" section,
  not in a "Future" note, not as an aside. Backlog lives wherever the project
  tracks work — an issue, a planning doc — never in a behavioural rule.
- **Open product questions** ("should we delete the old landing pages?"). A
  decision nobody has made is not guidance.
- **Status reporting** — what is built, what is not, what shipped when.

It DOES carry — because each of these tells the next builder what to do:

- The rule, and enough of the reason that nobody re-opens it.
- **Deliberate exclusions**, stated as a boundary: "favourites are not
  reorderable — do not add drag-to-reorder." That is scope, and it stops the next
  session re-deriving it.
- Known limitations of the pattern as specified.

The test: **would this sentence change how the next screen is built?** Yes →
keep it. No → it is backlog or a status update, and it goes somewhere else.

## Adding a reference

One file per pattern in `references/`. Lead with a one-line summary of the rule,
then the rules themselves — each present tense, each actionable. Record what is
excluded as a prohibition with its cost. Cite the primary sources.

Keep them short. A reference nobody finishes reading does not get followed.
