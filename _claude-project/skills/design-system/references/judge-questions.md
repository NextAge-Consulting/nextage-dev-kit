# Judge questions

The questions a cold judge is asked about a project's design, one candidate at a time.
Code finds every candidate and never decides; the judge answers one question about one
candidate, yes or no, quoting the evidence; three independent answers decide by
majority; a yes is a pending decision for the human. A question stays here only while its
cases in `scripts/judge-fixtures/<QUESTION>/` give the known answer on nearly every
run (`node scripts/judge.mjs --test`).

The judge is given the fields each question names and nothing else. It is never asked
to find anything, never grades its confidence, and never proposes a design.

## What is not a question

Decided by code, never asked:

- a role named with a t-shirt size, a class off a role, an arbitrary value, a size prop
  by magnitude, a fixed height at a call site, a colour repainted at a call site, a
  faded colour in a screen, a frame atom imported outside a block, a bare scroll area, a
  raw field painting the field look (the token checker);
- a token with no purpose comment, a token value between the steps of its family's
  scale, a rule file stating a pixel, font or weight literal, a rule naming a component,
  prop, slot or variant that does not exist (the token checker);
- the inventory and the files disagreeing, a status missing, a block type not on the
  list, a pointer naming nothing (the status check);
- `design.md` disagreeing with the stylesheet (the file is generated).

## The format

Each question below is one `##` section. `scripts/judge.mjs` reads the bold field labels:
**Asked about** (the one candidate), **Given** (the fields the judge receives, each a key
of the candidate), **Quote** (what the answer must quote, which must appear in the
candidate), **Yes when**, **No when**, **Example yes**, **Example no**.

---

## ROLE-NAME — a role named for how big it is

**Asked about:** one role token or type utility, by its name and its purpose comment.

**Given:** `name`, `purpose`, `value`.

**Quote:** the name.

**Yes when:** the name says how big, heavy, wide, loose or small the value is, or names a
magnitude in disguise (`label`, `micro`, `tiny`, `compact`, `base`, `heavy`, `loose`,
`wide` used as a size), instead of what element or job it serves. Only the words in the
name count; a purpose comment that explains a size word does not rescue it.

**No when:** the name says what the thing is or what job it does (`row-title`,
`field-caption`, `control`, `card-inset`, `overlay`), whatever its value, and even when
the job happens to imply a size.

**Example yes:** `--radius-big` — "the larger corner, for panels" → yes: `big` is a
size, the job (a panel's corner) is in the comment, not the name.

**Example no:** `--spacing-section` — "between sections; a form's actions from its last
field" → no: `section` is the job.

---

## DUPLICATE-ROLE — two roles doing one job

**Asked about:** a pair of roles in one family.

**Given:** `a.name`, `a.purpose`, `a.value`, `b.name`, `b.purpose`, `b.value`.

**Quote:** both names.

**Yes when:** the two purpose comments describe the same job — the same kind of element
in the same situation — so a builder pointing at an element could not say which to use
without hesitating. Equal values do not make a pair a duplicate; different values do not
make them distinct. Only the jobs count.

**No when:** the purposes answer different questions, even when the values are equal today
(`row-title` and `card-title` at the same size are two roles, because a card title may
grow without row titles following).

**Example yes:** `type-hint` — "a line under a field saying how to fill it" and
`type-field-help` — "help text under a form field" → yes: one job, two names.

**Example no:** `type-metadata` — "a timestamp, an id, a count beside a title" and
`type-hint` — "a line under a field saying how to fill it" → no: different places,
different readers.

---

## TOKEN-AGAINST-PURPOSE — a token used for something its purpose rules out

**Asked about:** one use of a role token or type utility, in a block, a screen or a rule.

**Given:** `token`, `purpose`, `line` (the line using it), `where` (block, screen or rule,
with the file), `context` (the lines around it, up to ten).

**Quote:** the line.

**Yes when:** the purpose comment names the element or situation the token is for, and
the line uses it for a different element or situation that the comment, read plainly,
does not cover. A field's error style on a message about the whole form; a card's inset
on a dialog's body; a row title on a page heading.

**No when:** the line's use is one the purpose covers, or the purpose is general enough
that the use fits it, or the purpose is silent on the case. Silence is a no: the
question is "ruled out", never "not mentioned".

**Example yes:** `text-feedback-danger` — "a field's error, under the field" used on
`<PageBanner className="text-feedback-danger">Saving failed</PageBanner>` → yes: a
banner about the screen is not a field's error.

**Example no:** `text-feedback-danger` — "a field's error, under the field" used on
`<FieldError className="text-feedback-danger">` → no: that is the covered case.

---

## VARIANT-INCOMPLETE — a variant left for its callers to finish

**Asked about:** one variant of one component, with how its call sites use it.

**Given:** `component`, `variant`, `definition` (the classes the variant sets, every
state included), `callSites` (each use of this variant, with the classes the call site
adds).

**Quote:** a call-site class that finishes the variant, or the variant name when none
does.

**Yes when:** two or more call sites add the same look-changing class (padding, a fixed
size, colour, type, border, radius, or a state such as hover or selected) on top of the
variant, so the variant is not complete until a caller finishes it. The classes
themselves are the evidence; what they are for is not weighed.

**No when:** call sites add only placement (margin, width, flex or grid position,
alignment, visibility), or the look-changing additions differ from site to site and
appear once each, or there is one call site.

**Example yes:** `Button` variant `ghost` defined as `bg-transparent hover:bg-accent`;
call sites `className="size-7 p-0"`, `className="size-7 p-0"`, `className="size-7 p-0
rounded-pill"` → yes: three callers finish an icon-button look the variant lacks.

**Example no:** `Button` variant `ghost`; call sites `className="mt-2"`,
`className="w-full"`, `className="ml-auto"` → no: placement only.

---

## NAMED-FOR-DATA — a block named for its data or its first screen

**Asked about:** one block, by its name, its block type and what it renders.

**Given:** `name`, `blockType`, `summary` (what it draws and what props it takes, from its
code), `screens` (the screens that use it).

**Quote:** the name.

**Yes when:** the name carries a business word — a thing the application manages
(customer, invoice, resident, payment, property, order) — or the name of one screen or
module, when the block itself would draw the same for any such thing. A block that is
genuinely specific to the business object in its code (it renders that object's own
fields and nothing else) is not named for its data; it is content, and that is a
different question.

**No when:** the name says the kind of thing it is (`ReviewDialog`, `RecordHeader`,
`FilterChips`), and business words appear only in what callers pass in.

**Example yes:** `CustomerNotesDialog`, type ModalShell, draws a title, a scrolling
body and a Close button for any children → yes: it is the ModalShell with a customer's
name on it.

**Example no:** `ResidentRecord`, type RecordScreen, renders the resident's own fields,
balance and tenancy actions → no: it is specific to its object; whether it belongs under
`components/` is the content question, not this one.

---

## RULE-REACH — a rule governing a block it was not written for

**Asked about:** one behaviour rule or recipe and one block its `block-types:` line reaches.

**Given:** `rule` (the file's text), `blockTypes` (its block-types line), `block.name`,
`block.type`, `block.summary` (what it draws, from its code), `block.inventoryLine`.

**Quote:** the rule sentence that does not fit, or the block-types line when the rule
fits.

**Yes when:** at least one sentence of the rule, applied to this block, demands
something the block cannot have by its nature or by the deliberate difference its
inventory line records (a Pager rule demanding a page-size control, reaching a Pager the
inventory records as "count and arrows only, by the human's decision").

**No when:** every sentence of the rule can apply to the block as it is, whether or not
the block follows it today. Not following a rule is FOLLOWS-RULE, not this.

**Example yes:** rule: "every row ends in a RowActions menu"; block `ListRow`, type Row,
inventory line "the card form of Row for the portal's bills; no actions, by the human's
decision" → yes: the rule reaches a block the inventory excludes.

**Example no:** rule: "a browse toolbar's search is leftmost"; block `BrowseToolbar`,
type BrowseToolbar → no: the rule fits; whether the toolbar does it is another question.

---

## RULE-CONFLICT — two rules, two answers

**Asked about:** a pair of behaviour rules or recipes that both apply to one surface.

**Given:** `surface` (the kind of surface both govern, from their block-types lines),
`a.file`, `a.text`, `b.file`, `b.text`.

**Quote:** one sentence from each.

**Yes when:** for one situation on that surface, a builder following rule A must do
something rule B forbids, or place something where B places something else. The two
sentences quoted must be about the same situation.

**No when:** the rules cover different situations on the same surface, or one is the
general case and the other names itself as the exception, or they agree in different
words.

**Example yes:** A: "a failed save shows its line above the actions"; B: "a failed
save shows a banner at the top of the form" → yes: one failure, two places.

**Example no:** A: "a dialog's Cancel sits first"; B: "a page form's Save sits first,
then Close" → no: a dialog and a page form are different surfaces, and each rule says
which it governs.

---

## FOLLOWS-RULE — a screen departing from its rule

**Asked about:** one changed screen and one behaviour rule or recipe that governs it.

**Given:** `rule` (the file's text), `screen` (the changed screen's code, or the changed
region with twenty lines around it).

**Quote:** the screen line that departs. Exceptions are code's, not the judge's: a yes
whose quoted line, or the line above it, carries a `design-accepted` or `design-deferred`
comment is discarded by code, and the judge is never asked to weigh one.

Code keeps a yes only when it quotes a line the change touched, and places the item on
that line.

**Yes when:** a sentence of the rule says what the screen must do or must not do in a
situation the screen's code visibly contains, and the code does otherwise.

**No when:** the code follows the rule, or the rule's situation does not arise in this
code. A rule the screen satisfies by using a block that carries it (the rule names the
block) is followed.

**Example yes:** rule: "a yes/no action that fails keeps its dialog open and replaces the
description with the failure"; screen: `onError: () => { setOpen(false); setBanner(err)
}` → yes: the dialog closes on failure.

**Example no:** rule: "Save is disabled until a field differs from its loaded value";
screen: `<FormActions form={form} />` where the rule names FormActions as its code → no:
the block carries it.

---

## REPAINT — a class at a call site changes how a block looks

**Asked about:** one class a changed line adds to a project component at a call site,
after the token checker has already failed colours and fixed heights.

**Given:** `component`, `class`, `tag` (the opening tag as written), `accepts` (the
classes the component's code reads from its className for layout, if it declares any),
`kind` (block or atom).

**Quote:** the class.

**Yes when:** the class changes padding, type, border, radius, shadow, opacity,
transform, cursor or an interaction state of the component itself, so the component
looks or feels different here than elsewhere. A class on a block's inner element reached
through a selector counts.

**No when:** the class places the component — margin, width, min or max height, flex or
grid share, position, alignment, order, visibility, overflow on a bounded box — or is a
class the component declares it accepts (a gap on a layout block, a column span on a
field).

**Example yes:** `<Card className="p-2 rounded-none">` → yes: padding and radius are the
card's.

**Example no:** `<Card className="mt-4 col-span-2">` → no: placement.

---

## SCREEN-BOX — a screen drawing a frame a block type names

**Asked about:** one element in a screen or feature file that draws a box, found by code
(a background, border, radius, shadow or padding class on a plain tag).

**Given:** `tag` (the opening tag), `children` (the first lines inside it), `file`,
`blockTypes` (the kit's block-type list, name and definition), `blocks` (the project's
blocks of the types that could fit, from the inventory).

**Quote:** the tag.

**Yes when:** the box is a frame a block type on the list names — a dialog, panel,
card, header, toolbar, notice, banner, button, row — drawn by the screen with its own
background, border, radius, shadow or padding instead of that type's block. Whether the
project has a block of that type yet does not matter; the screen drew a frame.

**No when:** the box is a screen's own content cell — a table cell, a list item's text,
a divider, a figure — that no block type names, or the only box classes are a hairline
divider or a bounded scroll area.

**Example yes:** `<div className="rounded-container border bg-card p-4 shadow-card">`
holding a title and a body → yes: a card, which the list names.

**Example no:** `<td className="border-b px-2">` → no: a cell of the screen's own table.

---

## DUPLICATE-BLOCK — a new block that is a variant of one that exists

**Asked about:** a pair: one new block or recipe or rule, and one existing neighbour
code chose for it.

**Given:** `new.name`, `new.type`, `new.code`, `existing.name`, `existing.type`,
`existing.code`, `existing.inventoryLine`.

**Quote:** the line of the new code that draws what the existing one draws, or the new
name when nothing does.

**Yes when:** the new piece draws the same kind of thing playing the same role as the
existing one — the same frame, the same arrangement, the same ending — differing only
in a look, a size, a label or a data shape, so it should be a variant or an option of
the existing piece. An inventory line on the existing piece recording a deliberate
difference between the two settles the pair as no.

**No when:** the two end differently (Close against Save), hold different kinds of
content, play different roles on a screen, or the inventory already records why both
exist.

**Example yes:** new `AlertBox`, no type named, a bordered row with an icon, a title
and a description; existing `Alert`, type PageBanner, "a standing message about the
screen" → yes: the same notice with another name.

**Example no:** new `PickerDialog`, "choose records from a searchable list, ends by
selecting"; existing `ModalShell`, "screen content in a popup, ends Close" → no: they
end differently.
