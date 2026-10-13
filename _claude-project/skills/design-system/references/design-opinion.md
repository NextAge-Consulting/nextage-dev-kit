# Design opinions

The kit's opinions about the small building blocks of an application's design system:
spacing, type, colour, radius, lines and elevation, motion, icons, controls, focus, dark
mode, badges. How a browse or a form behaves is a UI pattern and lives in `ui-patterns`.

## Before any value: the system, then this file, then the human

Every value a screen, part or design uses is decided in this order:

1. **The project's design system** — its tokens, parts and variants. It answers, use it.
2. **Silent → this file.** It has an opinion: adopt it into the project's system, built in
   the project's own tokens and parts, in the same change. The system now answers that
   question, and nobody reads this file for it again.
3. **This file silent too → decide with the human, then lock it** into the system the same
   way.

**A locked decision stays decided.** A different answer later is either a reversal applied
everywhere the decision reaches, or a second variant whose reason the human gave, recorded
where the variant is defined. A small adjustment "while I'm here" is neither.

**What the human approves lands exactly as approved.** A value that cannot be built as
approved goes back to them before anything is built — never adjusted afterwards.

**A gap is one decision, raised as itself.** Never several changes under one approval,
never a value hidden inside a treatment.

## The kinds of opinion here

- **Guidance** — what a working designer would agree with. The project picks the values and
  stays consistent; this file sets the shape.
- **The kit's side** — a debate with two legitimate camps where the kit chose one. Marked
  *(the kit's side)*.

A project overrides either only with a reason, written where its own system holds the
overriding value.

## Every value family has the same shape

**A short set of values, and roles on top.** Spacing and radius work their values out from
one base — the project's starting theme (tweakcn) or its brand. Type is a ramp: a short set
of sizes chosen by eye. Roles name the job — `control`, `card-title`, `section`, `overlay`
— and some roles are fixed constants that never move with a base (square and pill, `none`,
transparent).

**Use a role.** A step of the scale appears only inside a part, for a meaning no role names
yet. A raw value never appears anywhere.

**A part of a known block type names its meanings when it is created** — a card, a dialog,
a field is common by definition. Any other meaning earns a role when it recurs.

**Rename the moment a name proves wrong.** Never keep a bad name to keep a change small.

## Naming

- A token or role names what a thing is, never how big it is.
- A frame is named by how it ends (`block-types.md`).
- Use the established term — a "tab bar", not a "bottom bar".
- The same thing carries the same name in every project.
- The kit names the types; the project names each part in its own domain words.

## Spacing

Each layer is owned by one place:

- **The scale** — the steps anything may use: 0, 4, 8, 12, 16, 24, 32, 48. Nothing in
  between.
- **Inside a component** — the component owns it, fixed: padding, header to body, label to
  control, icon to text. A screen never changes it.
- **Between siblings** — a stack or inline layout part whose gap takes a name, never a
  number. Children carry no margin.
- **The page frame** — the shell owns the page edge and the gap between a page's regions.

| Default | Value |
|---|---|
| `tight` — a title and its subline | 4 |
| `related` — buttons in a row, options in a group | 8 |
| `default` — field to field, block to block, card to card | 16 |
| `section` — between sections; a form's actions from its last field | 24 |
| Container padding — card, panel, popover, dialog | 16 |
| Label to its control | 8 |
| Page edge — under 768px / 768px and wider | 16 / 24 |

Whether a rule sits above a form's actions depends on the form: a dialog's actions sit in a
footer outside the content and take one; a form in a card does not.

## Type

- Type comes as roles named for their job — body, label, card title, section heading,
  figure, metadata. The sizes are a ramp — a short set chosen by eye, in whole pixels —
  and the few weights are roles too.
- Size follows importance, not category: a fact the user needs sits at body size, and a
  section heading clearly outranks the field labels under it.
- Numbers in tables and figures are tabular, carried in their role. *(the kit's side)*
- Default: body 14 for a dense business application; card title and section heading one
  step up, at 18, and equal to each other.

## Colour

- **The palette is the project's** — its brand, or its starting theme. The kit has no
  opinion on hues, and a black-and-white application is not its default.
- **Base tokens hold the palette; meaning tokens name the job** — action, status, surface,
  feedback. A screen never uses a base token where a meaning token exists.
- **Different jobs are different families and never borrow from each other:** what to
  click, what condition something is in, whether an action worked, which kind of thing it
  is.
- **Contrast:** 4.5:1 for text, 3:1 for large text and for anything non-text that must be
  seen.
- **A brand colour is never changed.** When it fails contrast, change the colour paired
  with it, accept the shortfall with the reason written on the token, or put it to the
  human.
- A light token never needs a dark twin written by hand: its dark value can be derived
  from it (`color-mix` of the light token), so a change to the light one carries through.
  A project may set its own dark value wherever it chooses.
- Every colour token carries a comment saying what it is for. Text takes the foreground of
  the surface it sits on.

## Radius

- Roles named by what the shape is, with defaults derived from the starting theme's single
  base radius:

  | Role | Default |
  |---|---|
  | `stamp` — badges, small tags | base minus one step |
  | `control` | base |
  | `container` | base plus one step |

- Fixed shapes: square (0) and `pill` (fully round). They never move with the base.
- A shape nested inside another is concentric: its radius is the outer radius minus the gap
  between them, border included, never below zero. Square and pill need no adjusting.

## Lines and elevation

- The project picks one coherent approach — flat, or layered — and keeps it everywhere.
  Flat surfaces with heavy shadows, or any other pair of treatments that fight, is the
  failure.
- Shadows are roles named for what casts them (card, overlay, dialog), never by depth
  number.
- Lines are roles named for their job — a frame, a divider — and each has one width
  across the application. A divider has equal space above and below.

## Motion

- Small, purposeful feedback only: a state changing, an overlay opening, a row expanding.
  No entrance or attention animation in a business application.
- A few named durations and one easing, used the same everywhere.
- `prefers-reduced-motion` is always honoured.

## Icons

- One icon set. Sizes are a few roles tied to the text they sit beside; the stroke stays
  constant across sizes.
- Standard actions — edit, delete, download a file — are icon-only with a tooltip. One-off
  actions use words. *(the kit's side)*
- A standard icon never sits beside its own word. An icon may replace a word in a label.
  *(the kit's side)*
- An icon-only button takes no fill on hover: muted at rest, full colour on hover or while
  open. *(the kit's side)*
- One tooltip style everywhere.
- Default: an alert's icon is 20 with no title, 32 with a title, at the same stroke.

## Controls, touch and focus

- Control height is a role: 36 with a mouse, 44 under a coarse (touch) pointer. No target is
  smaller than 24.
- A loading placeholder takes the height of the control it stands in for.
- One focus treatment everywhere: a soft ring, never only a colour change, never removed.
  *(the kit's side)*

## Dark mode

- The application follows the operating system's light or dark setting by default; a class
  on the root overrides it only for an explicit choice, set before first paint so nothing
  flashes. *(the kit's side)*
- A project may ship without dark mode, with the reason written in its design system.

## Badges and pills

- A badge marks state. Tags and topics are pills. An identifier is neither. *(the kit's side)*
- A status reads as a state ("Connected"), never as an action ("Set up").
- Every badge variant shares one construction and differs only in colour family; no badge
  can be mistaken for a button.

## A component owns its look

A screen places a component and never restyles it — no colour, padding, border, radius or
type at the call site. A look a screen needs that the component lacks is a variant the
component gains, or a gap raised to the human.
