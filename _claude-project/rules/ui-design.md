---
paths: "{design.md,**/*.tsx,**/*.jsx,**/*.css,**/*.scss}"
---

# UI / Design System Rule

**Invoke the `design-system` skill before writing or editing any UI or styling code, or
a token stylesheet.**

```
Skill({skill: "design-system"})
```

It carries the kinds, the words for status, the pointers every file carries, the
procedure for building from the project's system and the review that approves what is
new. This rule is path-targeted because JSX and TSX consume the system, CSS and SCSS hold
it, and `design.md` is generated from it.

## One app, one look and feel

**We build applications, not websites.** Consistency is the product: the same thing looks
the same, sits in the same place and acts the same on every screen.

**The project's system decides.** Where it covers a piece, use it as it is. Where it is
silent, build the gap pending and put it to the human at the review; never pick a value
because it looks better, never restyle a block on one screen, never write a screen's own
save, error or loading behaviour.

**A change the human asks for is made in the system** — the token, the component, the
recipe, the rule — never on one screen, and you tell them what else it changes before you
make it.

**A change that leaves what the user sees and what the app does exactly the same needs
no approval.** Prove it first with `node .claude/skills/design-system/scripts/compare-ui-values.mjs`;
only what it lists as changed goes to the human.

**Nothing new becomes part of the system until the human has looked at it.** Build what
the work needs, mark what they have not seen pending, and `/deploy` refuses while anything
is. A commit is never refused on a matter of judgement.

## Adding a piece means adding it in two places

The file carries its header — its status and its pointer — and `rules/project/ui-inventory.md`
carries its line, with its block type and status, in the same change as the piece. The
inventory answers "does this already exist". `check-ui-status.mjs` fails while the two
disagree.

## The system is the stylesheet and the components

The token stylesheet is what the browser sees and the components are what screens are made
of. `design.md` is generated from the stylesheet by `npm run build:design-system`; its
prose sections are hand-written, its token section is never edited by hand. A settled UI
decision lands in what the build uses — a token, a component, a recipe, a behaviour rule
or an inventory line — never in a separate decisions document.

## A token names what a thing is

Name the role, never the size, in every family: spacing, radius, weight, elevation and
sizing as much as type. `npm run lint:tokens` fails a raw value, a role named by size and
every other mechanical breach; the judge questions in the `design-system` skill cover the
rest.

## Where UI lives

The design system's UI — tokens, atoms, blocks, `cn()` — lives in a home with client
dependencies only: one front-end app's `src/`, or a dedicated UI workspace every front-end
consumes. Which workspace may import which is `typescript-rules.md`, "The client/server
wall"; the UI home holds no server code.
