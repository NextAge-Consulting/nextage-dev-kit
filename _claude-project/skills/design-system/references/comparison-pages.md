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

## Build it live — never a screenshot

The human decides by using the options: hovering, tabbing, clicking, typing. A screenshot
shows one state, so it is never the page.

1. **One local page, the project's real parts.** Load the bundle `build:design-system`
   writes — `components/lib/react.production.min.js`, `react-dom.production.min.js`,
   `components/bundle.js` and `bundle.css` — and mount the parts from
   `window.<namespace>`. Nothing on the page is styled by hand.
2. **The options side by side, built from the same parts.** An option differs from today
   only in the value the decision is about, set as a CSS override on that option's column
   — a token, or the variable a class reads (`--tw-ring-color`).
3. **A light/dark switch** that sets `data-theme` on `<html>`; the bundle's dark tokens
   apply only at the root.
4. **Real content, in the state it is judged in** — a filled field and an empty one, a
   menu a click opens, a row a hover lights.

## Lay out the page

- **One caption per option**, and one line saying what to do with it — "Tab through the
  fields", "hover a row".
- **No recommendation.** The page shows the options; the human picks.
- Write it to `project-documentation/temporary/`. **Use it yourself first** — Tab, hover
  and the theme switch, in a named `agent-browser` session — then open it for the human.

## After the pick

Move every use onto the picked look. The part carrying it is written `approved` — the
pick is the approval.
