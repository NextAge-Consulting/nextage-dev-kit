---
name: design-system
description: How a project's User Experience System is built, kept and approved — tokens, atoms, blocks, recipes, behaviour rules and screens, the words for status, the pointers every file carries, and the checks. Use when creating or styling UI components, composing a screen, changing how the app behaves, or touching the token stylesheets. The kit holds no opinion on how anything looks or behaves; every answer is the project's system's, and where the system is silent the gap is built pending and put to the human.
user-invocable: false
---

# Design System

A project's User Experience System is its token stylesheet and its components, with the
recipes and behaviour rules that say how they combine and act. The stylesheet and the
components are the source: `design.md` is generated from them, and the Claude Design
system is published from them. This skill says how the system is built from and grown;
the look and the behaviour are the project's.

## The kinds

| Kind | What it is | Where it lives |
|---|---|---|
| **Token** | A named value. A **base token** holds the raw palette or scale, usually a tweakcn theme's output. A **role token** names a job (`row-title`, `control`, `feedback-danger`). Only role tokens are used outside the token files. | the token stylesheets (`DESIGN_TOKEN_FILES`), the type roles (`DESIGN_TYPE_FILE`), the Tailwind entry (`DESIGN_STYLES_FILE`) |
| **Atom** | One control or element that owns its look: a button, an input, a badge, a chart mark. | `components/ui/` (vendored, `DESIGN_VENDORED_DIR`) or `components/` |
| **Block** | A component of one block type (`references/block-types.md`), built from atoms and blocks. Owns its look, its inner layout and its guarantees. | `components/` |
| **Recipe** | How one page type is put together: a **frame** — the block of that page type, fixed ordered slots accepting named block types, no content, carrying the behaviour every screen of the type shares — and **instructions**, each a yes/no or a pick from a closed list, with one reference screen. | the frame in `components/`; the instructions in `.claude/skills/ui-patterns/references/` |
| **Behaviour rule** | The project's decision on how the app acts on one topic: saving, cancelling, errors, loading, confirming, feedback. Prose, listing its code. | `.claude/skills/ui-patterns/references/` |
| **Behaviour code** | The code that carries a rule out, inside a block or as a shared function. Names its rule. | wherever it sits |
| **Screen** | A route that follows one recipe and fills its slots with content: wording, data, server calls. A feature file holds one screen's content. | `routes/`, `features/` |

**Component** means an atom or a block. A component carries **variants** (named complete
looks), **props** (named for meaning), **slots** (declaring which components they accept)
and **guarantees** (behaviour no use may break, written on the component and enforced in
its code). Every kind is prose plus code, each pointing at the other.

**Content two apps share is still content.** It lives in a `features/` folder of the
shared package, never in a `components/` folder, and keeps its business words there.

**Several apps on one system each have their own experience.** The tokens, the atoms and
the shared blocks are one system; an app's own blocks live in its `components/`, with the
human's reason on their inventory lines; a recipe or behaviour rule that holds for some
apps names them on its `apps:` line (the `ui-patterns` skill).

## Variant, option and exception

| Word | What it is | Who decides |
|---|---|---|
| **Variant** | A named, complete look on a component: every visual property and every state. | Built by the AI, pending until the human approves. |
| **Option** | A pick from a recipe's closed list, or a prop on a component named for its meaning. | A new option is pending; a pick from an existing list needs nothing. |
| **Exception** | A deliberate departure on one screen from what the system says: an arrangement that differs from the recipe, with the human's reason written where it is made (`design-accepted — <reason>`). Never behaviour. | The human only. |

A new block or recipe is the answer only when the piece is a different kind of thing. The
judge's duplicate question (`references/judge-questions.md`, DUPLICATE-BLOCK) tests that.

## Naming

- A role token names the job, never the size: `field-caption`, `row-title`, `control`,
  `card-inset`. `sm`, `lg`, `label`, `micro` are sizes in token clothing.
- A family is named at the level people decide at. A finer distinction is a member of the
  family (`feedback-*`), each member carrying its meaning on its own token; no document
  lists the members.
- A block carries its block type's name. An approved second block of a type adds a word
  for how it differs, never for its data.
- A recipe carries its page type's name. A decision made at the level of "a list of
  accounts" — the same columns and search on every such list — is a recipe.
- Business words appear only in screens and content.
- Test a name: can someone point at the element and name it without hesitating,
  and does one name cover many values in the code? Collect every use of the name and list
  the values: many values each used a few times means several things hide under one name,
  split it; one value used by most with a few others means the name is right and the
  others are drift, move them onto it.
- Rename the moment a name proves wrong.

## Pointers

Every file names what governs it in its first lines, and `check-ui-status.mjs` confirms
every pointer names something real:

```
// ui-status: approved
// ui-block: ReviewDialog
// ui-behaviour: confirm-before-write.md
```

- a block: `// ui-block: <Type>`, and `// ui-behaviour: <rule>.md, …` for the rules it
  carries out;
- an atom: `// ui-atom`;
- behaviour code outside a block: `// ui-behaviour-code: <rule>.md`;
- a screen: `// ui-recipe: <recipe>.md`; a feature file holding one screen's content:
  `// ui-content`;
- a recipe's frontmatter: `kind: recipe`, `frame: <component, as its inventory line names
  it>`, `reference: <screen file>`, `block-types: [<page type>]`;
- a behaviour rule's frontmatter: `kind: behaviour`, `code: [<files>]`, `block-types:`.
  Every file in `code` points back.

## Status

Status words, the same everywhere — a component's first line, a reference's frontmatter, a
token's comment, an inventory line, a line in a screen:

- **pending** — built, or found by a check, and not yet put to the human. `/deploy`
  refuses while anything is pending. Nothing refuses a commit.
- **approved** — the human looked and approved it. Wiring approved pieces together stays
  approved. A later change the human asked for, that does not change the kind of thing it
  is, keeps it approved. A new variant is pending; a behaviour change is pending even
  with nothing new to see. On a line: `design-accepted — <reason>`.
- **deferred** — the human chose not to look and trusts the work. It blocks nothing and
  needs no reason. Its inventory line carries the file's fingerprint
  (`check-ui-status.mjs --fingerprint <file>`); on a line, `design-deferred <fingerprint>`
  with the line's (`--line-fingerprint <file> <n>`). Once the code changes it is pending
  again.

Checks and judges say pass / fail or yes / no, never "approved": approving is the human's
word alone.

## Procedure — every UI task

### 1. Read the system

Read `rules/project/ui-inventory.md`, then the recipe and every behaviour rule whose
`block-types:` names the block types the task touches, then the components they name.
The token stylesheets hold the roles; `check-design-tokens.mjs --roles` lists them.

**A project with no system yet builds one, pending, in the same pass**: the base theme's
tokens go in the token stylesheet, the roles the first screen needs are named over them,
and the first blocks are built from the atoms. Nothing halts. A project arriving with a
Design Pack installs it instead (`uxes-design-packs.md` in the kit's docs).

### 2. Build from the system

1. **Split what you build into frame and content.** The frame — a dialog, a drawer, a
   toolbar, a row, a screen's layout — is a block. The content is this screen's: wording,
   data, server calls, which blocks fill which slots.
2. **Sort every frame by its block type** (`references/block-types.md`, "Sort before you
   build") and use this project's block of that type. None yet: build it now, pending,
   from the atoms and blocks nearest in kind, named for the kind.
3. **A screen follows its recipe.** Its slots take the block types the recipe names; a
   choice the recipe leaves open is a pick from its closed list. A screen draws no box —
   no background, border, radius, shadow or padding of its own — and fades no colour; it
   places and arranges, and styles its own text from the type and colour roles.
4. **A screen never restyles a component.** Its `className` places the component: margin,
   width, a bounded height, its flex or grid share, position, alignment, visibility. A
   look the component lacks is a variant the component gains, pending.
5. **Behaviour comes from the block that carries the rule.** A screen that saves uses the
   block that owns saving; a screen never writes its own save, error or loading behaviour.
6. **Where the system is silent, build the gap and keep going.** A token, a variant, an
   option, a block, a recipe instruction or a behaviour rule, marked pending, with its
   pointers and its inventory line, in the same change. Never stop to ask about each one.

### 3. Values

Every value is a role. A screen writes no raw value; a component picks a role. A new role
is added when a thing exists that no role names, named for the job, with its purpose
comment, pending. A raw `text-sm`, `px-[10px]` or `rounded-lg` fails `npm run lint:tokens`.

### 4. Discipline the checks do not cover

- **A variant is complete.** It carries every visual property and every state; it never
  expects a caller to finish it. State is keyed inside the variant (`data-selected:`,
  `read-only:`), so no caller paints it.
- **A prop names meaning, never style:** `cols={2}`, `size="detail"`, never
  `radius="xl"`. The token check fails a size prop by magnitude; every other style prop
  is yours to refuse.
- **A look shared by an atom and a block is exported once** (`fieldVariants()` beside
  `buttonVariants()`) and built from.
- **A vendored atom is restyled once, at the source**, keeping its focus ring.
- **A rule about a kind of region is one named `@utility`** (a scroll area), never three
  classes per site.
- **Dark mode is the token file redefining values** under `prefers-color-scheme` unless
  `<html>` carries `light`, with `dark` or `light` forcing it; never a `dark:` variant in
  a component.
- **Colour is the worked example**: a ramp plus role aliases, components naming only the
  aliases. Every other family has the same shape.
- Tailwind mechanics are the `shadcn` skill's `rules/styling.md`; accessibility is
  `a11y-baseline.md`.

### 5. Prove, then put it to the human

**First prove what did not change:** `node .claude/skills/design-system/scripts/compare-ui-values.mjs [--base <ref>]`
resolves every changed class through the project's own Tailwind build and lists only the
values a user would see differently, in light and dark, with moved styles told apart from
changed ones. A line it proves identical needs no review.

**When `/commit` or `/ship-main` prints the judge's `✗` lines, and at the end of a body of
work, walk the human through every pending item** — in that turn, before `/open-pr`: `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`
lists them, each with the screens that use it. Open by asking whether to include what is
deferred (`--deferred` lists it). Describe each item by what changed on screen or in
behaviour, never by file or vocabulary, opening with "nothing new to look at" where that
is true. Two competing looks for the same thing go to the human on a comparison page
(`references/comparison-pages.md`), never in prose and never with a recommendation. Each
item the human approves becomes `approved`; one they reject is replaced by an existing
piece or changed until they approve it; one they set aside becomes `deferred`, with its
fingerprint.

**Run the checks once, when the iteration settles**, never after each tweak the human is
watching live: `npm run lint:tokens`, `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`,
and `npm run build:design-system` when a token changed, which regenerates `design.md`'s
token section and the files the token check compares; a project that publishes nothing to
Claude Design regenerates `design.md` with `node .claude/skills/claude-design/scripts/design-md.mjs`.

## The build-from gate

State, in your response, what you built from:

```
Built from: <path(s) to the block(s) or atom(s)>
```

A new block: `Built from: <path> (new, pending: <Type> <name>)`. Content kept in its
feature folder: `Built from: <path> (content)`. Nothing similar exists: `Built from: none
— new, pending: <the piece>`. No citation means Step 2 did not happen and the work is
incomplete.

## Tokens must survive the trip to Claude Design

The token stylesheet is also the source the design system is published from, and the
design tool reads a narrower language than a browser.

- **Every value resolves to a plain colour or length**: a literal, a `var()` reference to
  another token, or a `color-mix()` whose operands are literals or tokens. The producer
  fails the build on anything else.
- **Every token carries a comment saying what it is for**, on its line or directly above
  it, no blank line between. The sync copies it as the token's usage note, and the token
  check fails a token without one. Group headers use the `/* ─── name ─── */` form.
- **Wrap what the design system does not carry in `/* publish: off */` … `/* publish: on */`**:
  raw palette colours, the sizes the type roles consume, layout measurements. The same
  markers decide what `design.md` publishes.
- **Say in words what the format has no field for**: a type role's size at a breakpoint,
  tabular figures.
- A user theme setting follows `references/custom-themes.md`.

## Design-system components run on React 18 inside Claude Design

A component in the design system's feed stays inside what React 18 and 19 share: no
`use()`, no `<Context>` rendered as a provider, no `useActionState`, `useOptimistic`,
`useFormStatus` or `useEffectEvent`, no form actions, no ref cleanup functions. **A
component's look never depends on its neighbours or on how its children are nested**: no
adjacent-sibling, `:first-child`, `:last-child` or direct-child rule, because every
mounted component sits in its own wrapper on a canvas. The render check fails a
component whose canvas render differs from its plain render by a pixel. The
`claude-design` skill carries the bundle and the check.

## What checks what

- **The token check** (`npm run lint:tokens`, `scripts/check-design-tokens.mjs`) decides
  everything mechanical: a class off a role, an arbitrary value, a role named by size, a
  fixed height or a colour at a call site, a faded colour or a frame atom in a screen, a
  bare scroll area, a raw field painting the field look, a token that resolves to nothing
  or that nothing reaches, light and dark disagreeing, every text pair at 4.5:1, a
  reference naming what does not exist, the generated files current. It judges a screen's
  changed lines only, so untouched screens are never blocked. Exemptions are named in the
  `DESIGN_*` keys, never in code; a project's own check is a `*.mjs` in
  `<UI package>/design-system/checks/`.
- **The status check** (`.claude/skills/ui-patterns/scripts/check-ui-status.mjs`) decides
  status, the inventory, the block types, every pointer and the judge's ledger; its
  `--maturity` prints how many inventory lines each commit that added a screen brought, the
  reading of whether the system is maturing.
- **The judge** (`references/judge-questions.md`, `scripts/judge.mjs`) answers the
  questions code cannot — a class that repaints, a screen drawing a frame, a token used
  against its purpose, two rules in conflict, a screen departing from its rule, a new
  block that is a variant of an existing one — one candidate at a time, yes or no, three
  answers and the majority wins. It runs at `/commit` and `/ship-main`
  (`skills/gitflow/scripts/design-judge.sh`); a yes is one more pending item for the
  walk-through, held in `.claude/ui-pending.json`. It never stops a commit, and an item
  leaves the ledger only on the human's word or when its line's code changes; a no from a
  second asking is not an answer. A comment-only change is not a change: a header added
  to every file judges nothing.
- **`/design-audit`** asks the same questions over a whole layer, when the human asks.

## Converting a legacy app: do not derive values from it

Take the names from what things are, the values from the base theme's scale, and anchor
on one known-good value.
Whole pixels. A thing drawn several ways today is an inconsistency the human walks on a
comparison page or defers; it is never averaged.

## Adjacent skills and rules

- **`references/block-types.md`** — the block-type vocabulary and the sort.
- **`references/judge-questions.md`** — what the judge is asked.
- **`references/comparison-pages.md`** — how a visual decision is put to the human.
- **`references/custom-themes.md`** — user theme settings on top of light and dark.
- **`ui-patterns` skill** — the recipes and behaviour rules, how each is written.
- **`claude-design` skill** — publishing the system and designing from it.
- **`a11y-baseline.md`** — accessibility, authoritative, auto-loaded on JSX.
- **`shadcn` skill** — Tailwind mechanics and the vendored atoms.
