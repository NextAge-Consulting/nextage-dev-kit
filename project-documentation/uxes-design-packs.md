# Design Packs — concept and contract (not yet built)

A Design Pack is a project's finished User Experience System, extracted as a bundle that
another project installs on day one and owns from then on. The kit provides the extract
and the install and holds no opinion about the contents. This document is the contract a
pack must meet, written now so the kinds of the User Experience System are shaped to make
extracting possible. Nothing here is built.

## Why

A new project does not start from nothing and does not start from the kit's taste. It
starts by borrowing: a base theme from tweakcn for the colours, type and radius, and a
system of blocks, recipes and behaviours from somewhere that already got them right. A
pack is that second thing, made portable. Pick a base theme, add a pack, and the first
screen is built from a cohesive system the kit helps maintain.

The kit stays clean: it enforces the system a project chose and never argues about what
the system should say.

## What a pack contains

Everything a project's system is, minus the project:

- **Role tokens**, defined over a base theme's tokens. A pack never ships base colours;
  it ships the roles (`row-title`, `feedback-*`, `control` radius) and what each is
  defined in terms of, so any tweakcn theme slots underneath.
- **Blocks and atoms** as source: the components, their variants, props, slots and
  guarantees, with the pointer each carries.
- **Recipes**: each frame as a component, each instruction set as prose.
- **Behaviour rules**: the prose, and the behaviour code they point at, inside the blocks
  that carry it.
- **The inventory lines** for all of the above, every one `approved` on install, because
  the human adopting the pack is approving it as a whole.
- **The generated `design.md`** and the Claude Design config, so the installed system
  publishes to Claude Design on the first run.
- **A README** saying what the pack is for, which base themes it was built over, and what
  it deliberately does not cover.

## A pack ships in pieces

The unit of a pack is a **piece**, and a whole pack is every piece a system has. A project
that already has a system it likes takes one piece from another: the behaviour of a
filtered, sortable list, say, without the rest.

- **A behaviour rule with its code** is a piece: the rule file and every block its `code:`
  list names. It installs pending, under the project's own roles, and it comes whole: a rule
  whose code reaches into blocks the project is not taking is not a piece on its own.
- **A recipe with its frame** is a piece: the instructions, the frame block, and every block
  the instructions name for a slot.
- **A block** is a piece: the component, its variants, props, slots and guarantees, and the
  atoms it builds on.
- **A role token** travels only with the pieces that use it, and the installer maps it onto
  the project's existing role when one has the same purpose.

The status check already measures whether a piece is whole: a pointer that names nothing is
a piece that was cut too small. Install and Extract below describe the whole pack; a piece
is the same steps over a subset, and the installed files are the project's from that moment.

## What a pack never contains

- Anything that identifies the project it came from, its client, its product, its data or
  its screens. Block and recipe names already carry no business words
  (the `design-system` skill, Naming); a pack extractor fails on any that do, and on any
  comment, sample row or label that names a customer.
- Base colours, fonts or the brand. Those are the base theme's.
- Screens. A pack has no routes and no features.
- Kit files. The kit arrives through `/sync-dev-kit`; a pack assumes it is there.

A pack built from a consumer project is published only once a human has read every file
in it for the list above. The kit is public; a pack published beside it is public.

## Install

1. The project has the kit synced, a UI package named in `DESIGN_UI_PACKAGE`, and a base
   theme's tokens in its token stylesheet.
2. The install copies the pack's components, recipes, rules and role tokens into the UI
   package, writes the inventory regions, writes the Claude Design config, and generates
   `design.md`.
3. It runs the token check, the status check and `compare-ui-values.mjs` against an empty
   base and must come out clean: a pack that installs with a pending item or a finding is
   a broken pack.
4. From that moment every file is the project's. A later version of the pack is not
   synced in; it is a new pack a new project may choose. Projects diverge by design.

## Extract

1. Runs in the source project's session against a clean tree with nothing pending.
2. Takes the UI package's components, recipes, rules, role tokens and config, less the
   base theme and less anything a screen owns.
3. Fails, naming each, on a business word, a client name, a sample value that reads as
   real data, a block typed for one screen, or an unresolved pointer.
4. Writes the pack folder with its README, and installs it into an empty fixture project
   to prove step 3 of Install passes.

## Where packs live

A separate public repository per pack, or one `design-packs` repository with a folder
per pack, named by what the pack is for ("basic back-office"). Never inside a consumer
project and never inside the kit's `_claude-project/`, which syncs into every project.
Decided when the first pack is ready.

## Dependencies on the model

A pack is only extractable when the source project's system has:

- every block typed, one per type, with no `<none>`;
- recipes separated from behaviour rules, each file one kind;
- every pointer resolving;
- the business words only in screens;
- `design.md` generated, not hand-maintained.

These are what the kit's `uxes-model` migration leaves a project with. The first pack
follows them; it does not precede them.
