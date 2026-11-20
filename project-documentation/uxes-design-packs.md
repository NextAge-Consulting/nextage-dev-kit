# Design Packs

For the kit maintainer. A Design Pack carries the behaviour, recipes and layout one project
has already got right into another project, which keeps its own look. The kit provides the
extract, the install and the compare, and holds no opinion about the contents. How each is
built is kitmaintainer-handbook.md §12a.12. What a project's own people do with a pack is
`design-packs-guide.md`.

## Why

Making a list filter, sort, page and remember its columns is a lot of work, and so is a
date field, a form that saves well, or a side rail. Designing that again in each project
is waste. A pack lets a second project take it finished.

It does not make projects look alike. The receiving project's type, colour, spacing and
radius stay its own: a back office installed from a pack has the shape and behaviour of
the one it came from, and looks like it belongs where it landed.

The kit stays clean: it enforces the system a project chose and never argues about what
the system should say.

## The unit is a piece

A **piece** is the smallest thing a project can take: one behaviour, recipe or block, with
everything it needs to run.

- **A behaviour rule with its code:** the rule's prose and every file its `code:` list
  names.
- **A recipe with its frame:** the instructions, the frame block, and every block the
  instructions name for a slot.
- **A block:** the component, its variants, props, slots and guarantees.

A piece holds every file its code imports — a helper and a hook included — and names the
other pieces it depends on, so a shared file is stored once. The status check already
measures whether a piece is whole: a pointer that names nothing is a piece cut too small.

**Every file has one home piece, read from its own header.** A file carrying one rule
travels in that rule's piece. A file carrying several rules is a piece of its own, named
as its file is: it depends on each of those rules, and they name it a carrier. A rule is
whole without its carriers, so a block is taken without every other block that shares a
rule with it; a rule with no code of its own is installed with its carriers. A recipe's
frame carrying no rule travels with the recipe; the blocks its instructions name are
pieces it depends on. Any other block is a piece of its own. An atom the project made travels with the rule it carries or with whatever imports it;
one that nothing carries is a piece of its own, and a recipe or rule that tells a builder
to use it brings it, so a reference never names a component the pack does not hold.
A stock control — a vendored atom — is a piece of its own: the pieces that import it
expect it of the receiving project, and install lands it only where the project has none.

**A piece's files come from the workspaces others build on:** the UI package, and any
workspace of the system another workspace depends on. An app's own code, a screen, server
code and code outside those workspaces are the source project's own. Listed as a rule's
code they stay behind and the guide names what the receiving project writes in their
place; imported by a piece's file they refuse the piece. A file every project built on the
kit has one of its own — its logger, its user-facing error class — is the exception: a
piece expects the receiving project's.

**A pack also holds pieces written in it, not cut:** the app assembled — the shell with
its top bar, theme switch, account menu and rail — and its reference pages,
built from the pack's own pieces and invented data. A reference page is a realistic
screen, and together they show every visual piece the pack ships, in context, in each
variant and state; how many that takes is the pack's own matter, and `coverage` names
the components no page reaches. Install lands them, the human approves the pieces on
them in each theme, and they stay until the human says to remove them. A
piece records the themes it is built for; install says when the receiving project lacks
one.

An **app pack** is a list of piece names, and what the pack carries with why.
`"carries": [{ "roles": ["--gap-*"], "why": "a back office is compact" }]` is the
human's statement of what is part of the pack's nature; the kit chooses none of it. A
receiving project whose own role for that job holds another value is shown the
difference in the pack's reason, and decides how it lands. "Back office" names the shell,
the list, the forms, the dialogs and one filter piece. A project takes the whole list, one
piece from it, or the list with one name swapped: the back office, with a different filter
piece in place of the listed one.

Two pieces can be swapped only where the source code already meets at a slot or a typed
contract. Code that imports its neighbour by name is one piece with it.

## What a piece contains

A piece is a folder: its files, a `piece.json` saying what they need, and a guide where
the receiving project has work no copy can do.

- **Code, cut from the source project** at the path it has there, a workspace's package
  name on an import becoming `@design-pack/<its folder>`, and then **adjusted in the piece
  folder into what any project would use**: what the source project added for its own
  subject — a prop, a branch, a rule — comes out. That is the point of extracting over
  copying. A reference loses its `apps:` and `reference:` lines.
- **The rule or recipe prose,** reworded into words any project would use.
- **Its inventory lines.**
- **`piece.json`,** written by extract from the code:
  - `files` — what travels. An atom the project made travels with the behaviour it
    carries: a calendar rebuilt for the date field.
  - `pieces` — the other pieces it depends on, by name.
  - `atoms` — the files it expects the project to have, each with the exports it uses,
    and for a stock control the piece that holds it:
    the input and the field look it reads from it, a popover, a label, and the class-merge
    helper, which is built on the project's generated class groups.
  - `roles` — the roles its classes use, each by name and purpose. A role the app pack's
    `carries` names also holds the source project's `value` and the pack's `why`; every
    other role holds neither, and takes the receiving project's look.
  - `themes` — the themes it is built for.
  - `packages` — the libraries it imports, with the versions it ran on.
  - `carriers` — for a rule, the pieces that carry it beside other rules.
  - `workspaces` and `imports` — where its files sat in the source project, and the pack
    file each package-name import meant, so install can land them in another layout.
- **A guide, where the piece needs wiring the project writes itself:** a provider at each
  app's root, or a server half. For a server half it gives the typed contract the block
  already declares — the reads and writes it is handed — and a written account of what
  the project must store and return. It ships no server code: where a person's saved
  layout is kept differs from project to project.

## What a pack never contains

- Real data: a real customer's or person's name, an account number, a figure from a live
  record. An example drawn from the source project's own business is reworded into a
  general one, because a piece is found and reused by what it is called; extract lists the
  lines it knows of and refuses nothing over a word.
- A value the pack gives no reason for. What a user sees — colours, fonts, sizes,
  spacing, radius, the brand — is the receiving project's, except a value the human named
  as part of what the pack is, which travels with their reason.
- The source project's screens. A reference screen is written in the pack, from its own
  pieces and invented data.
- A rule or block that only makes sense in the source project.
- Kit files. The kit arrives through `/sync-dev-kit`; a pack assumes it is there.

## Where packs live

One public repository, `uxes-design-packs` in the kit's organisation, separate from the
kit and holding only pieces (`pieces/<piece>/`) and app-pack lists (`packs/<name>.json`).
A pack's version is that repository's own. The kit holds every tool and names the
repository's address. A human reads every file of a
piece for the list above before it is pushed: what is published there is public for good.

## Extract

1. Runs in the source project's session, against a clean tree with nothing pending. The
   source project's code is not changed to make a piece; the piece is adjusted in its own
   folder.
2. Works out the piece from its pointers and imports, less anything a screen owns.
3. Fails, naming each, on an import of the source project's business code, of a generated
   file, or one that resolves to nothing.
4. Writes the piece folder, and lists what the session rewords and reads: comments and
   prose in the source project's own domain words — read from its packages, apps, feature
   folders and routes — every string a user sees, and the wiring the source project does
   with the piece.
5. Proves the adjusted folder with checks alone: installed into an empty project with
   every piece it
   depends on, it must typecheck, build, and pass the token check and the status check.

**A rule in question is settled in its source project before it is extracted.** The pack
receives what a human has approved on real screens.

## Install

Install is a procedure a session follows in the receiving project, with a script for the
mechanical steps. Fitting a piece to a project — its roles, its atoms, its file names — is
judgement, and where it changes what shows, the human's.

1. The project has the kit synced, a UI package named in `DESIGN_UI_PACKAGE`, and every
   layer finished: the token check passes over the whole project with the vendored atoms
   read, and the status check holds nothing. Install refuses otherwise and names what to
   finish, because a piece landed on an unfinished layer follows the system only in part.
2. The script fetches the piece, and every piece it depends on, at one pack version.
3. Install runs bottom up. For each role in `roles`, it takes the project's role of the
   same purpose, or builds the role from the project's tokens where none exists. Two
   candidate roles that look different go to the human on a comparison page.
4. For each atom in `atoms`, it checks the project's atom offers the exports the piece
   uses, and builds what is missing, pending, from the project's tokens.
5. Where the project already has a block or atom an incoming file would stand beside,
   install stops and says which one and which screens use it, before anything is copied.
   The human folds one into the other, replaces the old one, or keeps both — an app with
   its own layout or behaviour keeps its own block, with their reason on its inventory
   line.
6. Libraries in `packages` the project lacks are put to the human as any new dependency
   is.
7. It copies each file into the workspace named as its own where the project has one in
   its system, else into the UI package, under the project's package name and named as
   that folder's files already are, and writes their inventory lines. Each file carries a pointer naming
   its pack file and the pack version: `// ui-pack: <piece>/<file> @ <version>` in a
   component, `pack: <piece>/<file> @ <version>` in a reference's frontmatter.
8. Where the piece has a guide, install does the wiring it describes, in the project's
   own conventions.
9. **The human reviews an install twice and approves it whole.** First the roles, in one
   sitting: each role the project lacks, each carried value that differs from its own,
   each change that would reach a role another app reads. Those are what really changes
   on landing, and once reviewed the lower layer is approved. Then the reference pages,
   looked over as a whole for what is plainly wrong. On their word, `approve` marks every
   installed file approved; nothing is put to them piece by piece, and a change found
   later while building is ordinary refinement. The recipes and behaviour rules land
   approved from the start. A recipe or rule is instruction
   already proven in the source project: reading its prose proves nothing, building with
   it does, and one that fails is fixed in the pack. Each lands naming the apps the
   install was for, so the project's other apps keep their own rules.
10. From that moment every file is the project's, to change as it needs.

## The commands

One command, `/design-pack`, shipped by the kit to every project with a UI:

- `/design-pack extract <piece>` — in the source project. A script works out the files,
  writes `piece.json` and runs the checks; the session rewrites the comments and prose.
- `/design-pack install <piece or app pack>`, with `--swap <listed piece>=<other piece>` —
  in the receiving project. `--from <address>` reads another packs repository in place of
  the published one, on install and compare; that repository is its owner's alone.
- `/design-pack compare [<file>]` — in a project that installed a piece: what the pack has
  changed since the version the file's pointer names.

And one in the kit alone, `/shippack <source project>`, which releases the packs
repository: it reports every line that looks private, proves the pieces that changed since
their proof was recorded (`pieces/proved.json`), then commits, pushes and tags a dated
version. `/shipkit` never publishes the packs, and says when they hold unreleased work
(kitmaintainer-handbook.md §9.15).

## Updates

Nothing syncs and nothing reports a project as behind. A project that wants to see what a
pack has changed compares the pack file at the version its pointer names against the pack
file now, and is offered each difference to merge by hand or leave. A merged difference is
an ordinary change to a project-owned piece, pending where it changes what shows or how
the app behaves.

## Dependencies on the model

A piece is only extractable when the source project's system has:

- every block typed, one per type, with no `<none>`;
- recipes separated from behaviour rules, each file one kind;
- every pointer resolving;
- the business words only in screens and in comments;
- `design.md` generated, not hand-maintained.

These are what the kit's `uxes-model` migration leaves a project with. The first pack
follows them; it does not precede them.

## Not yet decided

- Whether a piece ships tests, and where they land.
