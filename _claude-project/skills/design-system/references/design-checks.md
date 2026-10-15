# Design checks

The one list of judgement checks on a project's design. The commit design review applies
them to the lines a change adds; `/design-audit` applies them to everything, one layer at a
time, from the bottom up. A check belongs here and nowhere else.

## The layers

Each layer is held to the layers beneath it.

- **1. Tokens** — the token, type and styles stylesheets, and `design.md`. Held to the kit's
  design opinions.
- **2. Parts** — every component on the UI inventory, and the inventory itself. A part is a
  `.tsx` file under a `components/` folder outside `features/`. Held to 1.
- **3. Patterns** — every reference in `.claude/skills/ui-patterns/references/`. Held to 1
  and 2.
- **4. Screens** — every other `.tsx` in the UI source: routes, and anything under
  `features/`. Held to 1, 2 and 3.

## Reporting

**Report only what the material shows clearly; when unsure, do not report.** Each finding
names the file, the line, the check, the text quoted, what is wrong in one sentence, and the
fix: the token, part, variant or pattern rule to use, change or create.

**Skip a line marked accepted.** `design-accepted — <reason>` in a comment on a line, or on
the line above it, accepts every finding there. `design-accepted(<reference file>) —
<reason>` accepts only a departure from that pattern.

**Guidance is the project's to decide.** Where the design opinions give guidance rather than
take *(the kit's side)*, a different project value is never a finding. The audit lists it
apart as *worth a look* unless the line is marked `design-choice`; the review never reports
it.

**A check marked *Whole layer* needs the whole layer to judge.** The audit applies it; the
review, which sees one change, does not.

## 1. Tokens

### TOKEN-GAP — the system is silent where the design opinions are not
*Whole layer.* The project has no token, role or rule where `design-opinion.md` has an
opinion. Recommend adopting it, in the project's own token and part names.

### OPINION — an absolute broken with no reason recorded
A token, role or `design.md` rule contradicts a side marked *(the kit's side)* or a floor the
opinions set — contrast, target size, focus that can be seen — and no comment where the value
is held gives the project's reason. Name the opinion.

### ROLE-NAME — a role named for its size
A role (a `--radius-*`, `--font-weight-*`, `--shadow-*`, `--spacing-*`, `--leading-*`,
`--tracking-*` token, or a `type-*` utility) named for how big, heavy or wide it is —
"small", "big", "large", "heavy", "base", "wide", "loose", "micro", "label" used as a size —
rather than for the element it serves. Report it once, where its value is defined.

### DUPLICATE-ROLE — two roles doing one job
A role whose job another role already does under another name. Name the existing role.

### TOKEN-PURPOSE — a token with no stated purpose
A token or role with no comment saying what it is for. Draft the comment from where it is
used, for the human to correct.

### OFF-SCALE — a value off the system's own scale
A token whose value sits between the steps of its own family's scale.

### DESIGN-PROSE — `design.md` contradicting the roles
A sentence in `design.md` that states a value or rule the roles do not hold: a role that
does not exist, or a value no role has.

## 2. Parts

### PART-TOKEN — a part using a token against its purpose
A part uses a token or role for something its purpose comment rules out. Quote the comment.

### VARIANT — a part left for its callers to finish
A variant left incomplete for callers to finish; a state (selected, active, disabled,
read-only) of another part painted through its `className` instead of a variant of that
part; or a look another part already exports, copied by hand.

### PART-NAME — a part that is not what its name says
A part named for the one screen that first used it, two parts doing one job, or a part that
is a variant of another. Recommend the generic name, or the part it folds into.

### PART-HOME — a part held by one app that belongs to every app
*Whole layer.* An app's own part that imports nothing app-specific, or that another app's
screens redraw. Recommend the shared UI package, with what it needs passed in.

### INVENTORY — the inventory and the parts disagree
*Whole layer.* A part with no inventory line, a line for a part that does not exist, or a
line whose block type or "use for" does not describe the part.

## 3. Patterns

### PATTERN-TOKEN — a pattern using a token against its purpose
A pattern rule tells builders to use a token or role for something its purpose comment
rules out, or names one that does not exist. Quote both.

### PATTERN-PART — a pattern asking a part for what it does not have
A pattern rule names a part not on the inventory, or relies on a prop, slot or variant the
part does not have. Recommend changing the rule, or the part gaining it, built pending.

### PATTERN-REACH — a pattern governing a part it was not written for
The reference's `block-types:` reaches a part the rule does not fit, such as a part the
inventory or its own doc records as a deliberate different form. Recommend narrowing the
`block-types:` or the rule.

### PATTERN-CONFLICT — two patterns, two answers
Two references give different rules for the same surface or situation. Quote both.

### PATTERN-VALUE — a pattern prescribing a size
A pattern gives a raw value — pixels, a font, a weight — where it names a part's role.
Recommend the role, or raise the missing one with the design system.

## 4. Screens

### SCREEN-TOKEN — a screen using a token against its purpose
A screen uses a token or role for something its purpose comment rules out — a field's error
style on a message that is not about one field. Quote the comment.

### SCREEN-PATTERN — a screen departing from its pattern
A screen breaks a rule of a pattern that governs that kind of surface. Quote the rule. The
fix is the screen, unless the rule is what is wrong — then it is a PATTERN finding.

### CALL-SITE-REPAINT — a screen restyling a part
Where a screen uses a part, its `className` changes how the part looks — colour,
background, border, radius, shadow, padding, type — rather than where it sits (margin, width,
a bounded height, a flex or grid slot, position, alignment, visibility). A class the part
exists to receive, such as a gap on a layout part, is not a repaint. Several look-changing
classes on one use mean a missing variant; name it.

### SCREEN-BOX — a screen drawing a frame a part owns
A screen draws, with its own background, border, radius, shadow or padding, a frame a block
type names — a dialog, panel, header, toolbar, card, notice, banner, button — instead of
using that type's part. Name the block type and the part, or say none exists yet.

### SIZE-PROP — a size picked by magnitude
A component's size or variant prop names a magnitude ("small", "large", "compact", "tiny",
"big") rather than what the thing is.

### SYSTEM-GAP — the screen needs what the system lacks
A screen hand-builds something because the system has no role, variant or part for it.
Recommend what the system gains; the block types and the inventory decide which.

## Never report

- What the token checker decides: arbitrary values, a class that is not a role, `dark:`
  variants, bare overflow, an unresolved `var()`, a t-shirt size name, a fixed height at a
  call site, a colour role painted on a part at a call site, a faded colour.
- Text a screen styles from roles — a type role, a weight, a semantic text colour — and the
  layout a screen writes: flex, grid, gap, alignment, margin, width, height bounds, order.
- Styling on cells, list items, rows or dividers that are a screen's content rather than a
  frame around it.
- Focus rings, skip links, screen-reader-only content, and icons coloured by their caller.
- Strings that are not class lists, headless primitives, vendored atoms' own source, tests
  and stories.
- A pixel value in `design.md` prose that is a breakpoint, a device width, a hairline, or an
  example of what not to do.
- Whether the design is good.
