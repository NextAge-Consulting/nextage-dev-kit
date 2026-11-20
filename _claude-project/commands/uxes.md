---
description: Load the whole User Experience System before any UI advice or work — its layers, the path of a change from edit to deploy, who decides what, and what a change in one place moves in the others
argument-hint: "[what you are about to do or advise on]"
---

# /uxes

$ARGUMENTS

**Everything below is settled. Work inside it; never re-open it, and never offer a part of it
back as a new idea.** It says how the pieces bind each other. A file's own detail — a
header's syntax, a command's flags — is in the file the last section names.

## What it is

A project's User Experience System is its token stylesheet and its components, with the
recipes and behaviour rules that say how they combine and act. Consistency is the product:
the same thing looks the same, sits in the same place and acts the same on every screen.

- **The kit** owns the kinds, the words, the checks, the judge and the publishing. It holds
  no opinion on how anything looks or behaves.
- **The project** owns every value, block, recipe, rule and screen.
- **The human** approves what is new. `approved`, `deferred`, `design-accepted` and
  `design-deferred` are the human's words alone; you write one only when they have said it.
  A recipe or behaviour rule a Design Pack lands arrives `approved` by the install, and
  the human approves everything else it lands in one word, after reviewing its roles and
  its reference pages.

## The layers

Listed bottom first. Each layer is made only from the layers beneath it, so a change in one
changes every layer above it.

| Layer | Holds | Lives in |
|---|---|---|
| Base tokens | The theme's palette and scale; the one place a look is chosen by eye | the token stylesheets, between the `publish: off` markers |
| Role tokens | A name for each job, with a purpose comment; the only tokens used outside the token files | the token, type and styles stylesheets |
| Atoms | One control or element that owns its look | `components/ui/` |
| Blocks | One per block type; owns its look, inner layout and guarantees; carries variants, props and slots | `components/` |
| Recipes and behaviour rules | A recipe: how one page type is put together — a frame, which is a block, plus instructions. A behaviour rule: how the app acts on one topic, everywhere, listing the code that carries it out | `.claude/skills/ui-patterns/references/` |
| Screens | A route following one recipe, filling its slots with content: wording, data, server calls | `routes/`, `features/` |
| App build | Each app's entry stylesheet names the folders Tailwind reads; a class in no scanned folder is in the code and absent from the page | each app's stylesheet |

`design.md` and the Claude Design system are published from the stylesheet and the
components, and are never edited themselves.

**A layer is built on a finished layer beneath it.** Frames come before recipes, blocks
before frames, roles before blocks, and the token stylesheet with its generated files
before any of them. Bringing an existing app onto the system runs bottom up in that order.

## The path of a change

1. **Every edit.** Read `.claude/rules/project/ui-inventory.md`, the recipe for the page type and
   every behaviour rule whose `block-types:` names what you touch, then build from what
   they name. Where the system has nothing that does the job, build the gap `pending` — a
   token, a variant, a block, a recipe instruction, a rule — with its status line and its
   inventory line in the same change, and keep going. Where it has a piece that does the
   job and does not fit, stop ("When a piece does not fit").
2. **`/commit` and `/ship-main`.** The token check (`npm run lint:tokens`) decides
   everything mechanical and refuses the commit on a finding, judging a screen on its
   changed lines only. Then the judge asks one yes/no question per candidate the change
   holds. A yes never refuses the commit: it is written to `.claude/ui-pending.json` as a
   pending item and printed as a `✗` line.
3. **That same turn, before `/open-pr`.** Sort every `✗` line: fix yourself each one that
   can be settled with nothing changing on screen or in behaviour, and run the judge on
   the fix until it is clean before it is committed. Put to the human only
   what changes what they see or how the app behaves, with everything this work left
   `pending`, opening with "nothing new to look at" where that is true.
4. **`/deploy`.** The status check
   (`node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`) refuses while anything is
   pending, while the inventory and the files disagree, or while a pointer names nothing.
   `/work` and `/handoff` run it to show what waits.

## Where status is kept — the conversation is not one of them

| Record | Holds | Changes when |
|---|---|---|
| The file's `ui-status` line and its inventory line, which must agree | A component's, recipe's or rule's status | You write `pending` on building it; `approved` or `deferred` on the human's word |
| A token's comment | `ui-status: pending` on a new role | You remove it on the human's word |
| The judge's ledger, `.claude/ui-pending.json` | Each yes, keyed by question, place and what it is about — the rule, token, class or other piece — resting on a line, on the sentence quoted from a rule, or on a whole component | The human's `design-accepted — <reason>` or `design-deferred <fingerprint>` on the line or on a comment line directly above it — for a rule's sentence, above the line it starts on — or that line or sentence changing. A yes about a whole component: the human approving or deferring the component |

- **The judge sees only the candidate it is given.** It knows nothing of what the human
  approved in conversation, so a yes on a screen the human has already seen is expected,
  and is settled on the line by the human's word like any other.
- **An approval the human speaks is recorded nowhere until you write it** in the record
  that holds that thing — in that turn: the status in the file and the inventory, or the
  marker on the line. `check-ui-status.mjs --line-fingerprint <file> <n>` gives a deferred
  line's fingerprint, and `--fingerprint <file>` a deferred file's, which goes on its
  inventory line.
- **Never clear an item any other way:** no asking the judge again until it says no, no
  editing the ledger, no marker the human did not give.

## What moves a status

| Stays as it is | Becomes `pending` |
|---|---|
| Wiring approved pieces together | A new atom, block, recipe or rule; a new token that brings a value a user sees |
| A change the human asked for that does not change the kind of thing it is | A new variant, or a new option on a closed list |
| A behaviour change the human asked for by name | A behaviour change that comes as a side effect of something else, even with nothing new to see |
| Writing an approved decision into its recipe or rule | |
| A recipe or behaviour rule a Design Pack lands: it arrives approved, for the apps the install names | A component a Design Pack lands, until the human approves the install whole |
| A change `node .claude/skills/design-system/scripts/compare-ui-values.mjs` proves leaves every visible value the same | A `deferred` piece or line whose code changed |

A comment, a header, an import or code that only moved is not a change, and an approved or
deferred piece is not asked about its own contents at a commit. Nor is what a Design Pack
installs, in the change that adds it. `deferred` is the human choosing not to
look: it blocks nothing, needs no reason, and carries a fingerprint.

## Who decides

**The human decides what shows on screen and how the app behaves, and sees it as the real
thing before deciding.**

- Put a pending item as what changed on screen or in behaviour, never by file name or by
  the system's vocabulary, with the app running where they can use it themselves.
- Two competing looks are shown on the app's real stylesheet and classes, never with a
  value typed by hand, with no recommendation and nothing on the page the app would not
  show. Use the lightest render that is accurate for what the decision turns on, and say
  which you used and what it does not show (`references/comparison-pages.md` in the
  `design-system` skill).
- A piece no screen uses yet is shown on a temporary screen and settled there.
- A brand colour and an approved piece are fixed inputs: never recommend changing one.
- A fix the human turns down is not their acceptance of what it would have fixed. Write
  nothing.

**You decide everything that is only the system's bookkeeping,** from the code: which kind
a file is, its block type, its header, its `apps:` line, its inventory line, which
reference governs which screen. Never ask the human to rule on a file they have never
opened.

**A change to anything shared is said before it is made.** A token, a block or a shared
function reaches every screen that uses it: name those screens to the human first.

## When a piece does not fit

The sort is the same for a piece you are building and one that already exists
(`block-types.md`, "Sort before you build"). Split the piece into frame and content first:
the frame is what it is and how it ends; the content — one screen's words, data and server
calls — stays in `features/` and is no part of the system. Then sort the frame up the
layers, bottom first, and stop at the first it belongs to. Every piece lands in exactly
one:

1. **An atom** — one control or element that owns its look.
2. **A variant or option of an existing block** — it differs a little from one.
3. **A block of the nearest type on the list,** matched by what it is and how it ends,
   with the reason on its inventory line when the fit is loose.
4. **A page type's frame** — slots and shared behaviour, no content.
5. **Content** — what is left once the frame is taken out: one business object's own
   fields.

- **A route is sorted the same way, by page type, and always follows a recipe** — a type
  with one screen included. `// ui-recipe` goes on a file a user lands on; `// ui-content`
  goes on content and wiring — a feature file, a root document, a layout route, a router,
  a provider, a helper — never on a file a user lands on. A screen that is unlike the rest of
  its type follows the recipe and carries the human's exception where it departs.
- The block types are generic kinds a business application has, loose enough that a piece
  lands in one. A project's piece is never a reason to add a type.
- One block per type is the norm, across every app on the system: a frame two apps draw is
  one shared block, varied by slot and option, and the same code never sits in two apps.
- A second block of a type is put to the human with both shown as the real thing: the same
  frame folds into the first; a different layout or behaviour carries their reason on its
  inventory line. Never write that reason yourself.
- **An existing block that does not fit a new place is raised with the human before
  anything is built beside it.**
- Where the system covers a piece, use it as it is — its states included. Focus, hover
  and selected come from the atom that already has them.

## The project conforms to the kit

**A check, generator or migration that refuses is stating the system's contract.** Change
the project until it passes.

- Never edit a kit-owned file, and never recommend a kit change, to make a project's code
  pass. What you believe is a fault in the kit goes to the human as what you saw, apart
  from what you concluded.
- A check is evidence that the work is right, never the goal. Sort a file by what it is,
  then write the header the check reads.
- A setting in `.claude/sync-substitutions.json` — the `DESIGN_*` keys — switches a whole
  layer's checks on or off, and is the project owner's decision.

## A decision lands in the system in the same change

A settled decision is written into what the build uses — a token, a component, a recipe, a
behaviour rule or an inventory line — in the change that makes it, so the next screen is
built from it.

## Before you advise or build

**Find the sentence that governs the task above — in this briefing, or in the file the last
section names for it — then open your reply with these lines.** An answer without them was
given without the system.

```
Layer: <the layer the change sits in>
Made from: <what beneath it this depends on>
Reaches: <the layers above, the checks and the records it moves>
Settled: "<the sentence that governs it, quoted>" — <the file it is in>
```

Before the first edit, read in full the recipe, rule or component the change touches.

## Where each thing is written

| For | Open |
|---|---|
| The kinds, naming, pointers, the procedure for every UI task, the review | `.claude/skills/design-system/SKILL.md` |
| The block types and the sort | `.claude/skills/design-system/references/block-types.md` |
| What the judge is asked, and what code decides instead | `.claude/skills/design-system/references/judge-questions.md` |
| How a visual decision is put to the human | `.claude/skills/design-system/references/comparison-pages.md` |
| How a recipe or behaviour rule is written | `.claude/skills/ui-patterns/SKILL.md` |
| This project's recipes and rules | `.claude/skills/ui-patterns/references/` |
| What this project already has | `.claude/rules/project/ui-inventory.md` |
| Publishing, and a design's life in Claude Design | `.claude/skills/claude-design/SKILL.md` |
| Auditing a whole layer, when the human asks | `/design-audit` |
| Cutting a piece of the system into a Design Pack, or installing one, when the human asks | `.claude/skills/design-packs/SKILL.md` |
