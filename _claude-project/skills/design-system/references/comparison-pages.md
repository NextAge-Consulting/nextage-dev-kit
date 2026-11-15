# Comparison pages

How to put a visual decision to the human so they can answer it in seconds. A decision is
two or more competing looks for the same thing — never two pieces of code that render the
same.

## Only real differences

**Group by what a thing is before building a page.** Two looks are a decision only when
they draw the same thing — the same role, holding the same kind of content. Different
things that happen to look alike are separate blocks, and never share a page.

**Present a choice only when the options look different on screen.** Variants that differ
in code but render the same are unified without asking; prove it with
`compare-ui-values.mjs`.

## Use the lightest render that is accurate

**Ask what the decision turns on, then take the first render below that shows that
truthfully.** Never a render that leaves out something the decision turns on, and never a
heavier one than it needs. When the human asks for a better render, go down the list.

| Render | Use when the decision turns on | It does not show |
|---|---|---|
| **A sample** | A value on the piece itself: a type role, weight, colour, shadow, radius, spacing | What the piece inherits from its page, its width in place, its neighbours |
| **The component, mounted** | A state a click or typing produces: an open menu, a filled field | The piece's page; a piece outside the component bundle |
| **A captured section** | Where the piece sits: inherited font, colour or background, its width, what is beside it, a state only real data produces | Anything a click changes |
| **A captured screen** | A screen's arrangement | Anything a click changes |
| **Real pages** | How the app behaves: a flow, a save, a failure. Also a screen no capture can reach | — |

**Every render draws with the app's real stylesheet and the project's real classes.** Never
type a colour, a size, a font or a shadow into a comparison page.

**Say in your reply which render you used and what it does not show,** with which option is
which and what to try on each.

## The rules every render keeps

- **The page holds the real thing and nothing else.** No explanation, instruction, heading
  or box the app itself would not show; the options' names and a light/dark switch are the
  only additions.
- **No recommendation.** The human picks.
- **One piece: the options side by side on one page.** **A whole screen: one page per
  option, each opened in its own tab.**
- **An option differs from today only in what the decision is about** — a class swapped, or
  a token's value set on that option.

## Building each

`render-comparison.mjs` is in the `design-system` skill's `scripts/`. When it refuses a
class no stylesheet styles, or a font file it cannot find, fix the markup and run it again.

### A sample

Write each option's markup with the project's real classes — the piece, and any wrapper
whose classes it depends on — into a spec, then:

```bash
node .claude/skills/design-system/scripts/render-comparison.mjs sample \
  --spec project-documentation/temporary/<name>.json \
  --out project-documentation/temporary/<name>.html
```

```json
{ "entry": "apps/web/src/styles.css",
  "body": { "class": "<the classes the app's body carries>" },
  "options": [
    { "name": "Today", "html": "<h2 class=\"type-card-title\">Kitchen sensor</h2>" },
    { "name": "Section title", "html": "<h2 class=\"type-section-title\">Kitchen sensor</h2>" } ] }
```

### The component, mounted

One local page loading the bundle `build:design-system` writes —
`components/lib/react.production.min.js`, `react-dom.production.min.js`,
`components/bundle.js` and `bundle.css` — with the components mounted from
`window.<namespace>`, the options side by side under their names, each differing by a CSS
override on its column, and a light/dark switch that sets `data-theme` on `<html>`.

### A captured section, a captured screen

Open the real page in a named `agent-browser` session, signed in with the project's test
login, in the state to be judged. Capture the section by a selector — `body` for the whole
screen — then build the page:

```bash
node .claude/skills/design-system/scripts/render-comparison.mjs capture-script --selector "<selector>" \
  | agent-browser eval --stdin --json > project-documentation/temporary/<name>.capture.json
node .claude/skills/design-system/scripts/render-comparison.mjs captured \
  --capture project-documentation/temporary/<name>.capture.json \
  --spec project-documentation/temporary/<name>.json \
  --out project-documentation/temporary/<name>.html
```

```json
{ "options": [ { "name": "Today" },
               { "name": "Raised", "edits": [ { "select": "[role=menu]", "swap": [["shadow-popover", "shadow-menu"]] } ] } ] }
```

**Change the one element the decision is about with `edits`** — a selector, then `swap`,
`add` or `remove`. An option's own `swap` replaces a class on every element that carries
it. Never force a value onto an element with an `!` class.

The page opens with the app stopped and no sign-in: it carries the section's real markup
inside its real ancestors, each held at the width it measured, with the page's stylesheets,
fonts and images. It shows each option cropped to the piece and what is just around it,
numbered `1 of n`, in one row, scaled down together when the row would not hold them. Each
option is also written alone as `<name>-<option>.html`, for a second screen.

**Open the page at the human's window size and check every option is on screen at once**
before they see it. When it is not, capture a smaller section.

### Real pages

One page per option, each the real screen in the app's own frame, built from the app's own
components with real content, each at its own address. Light and dark come from the app's
own theme control. Give the human each address and the account to sign in as.

## Before the human sees it

Write the pages to `project-documentation/temporary/`. **Use them yourself first** — Tab,
hover and the theme switch, in a named `agent-browser` session — then open them for the
human.

## After the pick

Move every use onto the picked look. The component carrying it is written `approved` — the
pick is the approval. Remove the pages, their specs and their captures.
