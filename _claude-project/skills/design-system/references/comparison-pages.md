# Comparison pages

How to put a visual decision to the human: one page they can answer in seconds. A
decision is two or more competing looks for the same thing — never two pieces of code
that render the same.

## Only real differences

**Group by what a thing is before building a page.** Two looks are a decision only when
they draw the same thing — the same role, holding the same kind of content. Different
things that happen to look alike are separate parts, and never share a page.

**Present a choice only when the options look different on screen.** Variants that differ
in code but render the same are unified without asking; prove it with
`compare-ui-values.mjs`.

## Shoot the running app

1. **Capture the running app**, headless, in a named `agent-browser` session (the
   `agent-browser` skill), signed in as the test user the project's `.env` holds. Never a
   page compiled from the stylesheet alone — the app's Tailwind setup is what makes boxes,
   borders and buttons render.
2. **Frame one screen, the viewport — about 1440 × 760 — never the full page.** Scroll the
   app's own scroll container so the element sits mid-frame, with the UI around it that
   it is judged against.
3. **Put it in the state where it appears**: expand the groups, type the filter that
   empties the list, open the dialog. A rare branch may be forced with a temporary code
   change, reverted straight after the capture.
4. **Show each competing look where the app draws it today** — one screenshot per real
   location. Never transplant one option into another's place.
5. **A light row and a dark row**, each captured with the `<html>` class toggled. Dark is
   its own capture; a dark wrapper inside a light page keeps the light tokens.

## Lay out the page

- **One caption per option**, naming the option and where it lives. Never two options
  under one caption.
- **No recommendation.** The page shows the options; the human picks.
- Write it to `project-documentation/temporary/`, **open the page and look at it yourself**
  before handing it over, then open it for the human.

## Around the human's dev server

Say so before changing code under a dev server the human is running for a capture, and
restore and diff it afterwards.

## After the pick

Move every use onto the picked look. The part carrying it is written `approved` — the
pick is the approval.
