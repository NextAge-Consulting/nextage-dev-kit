---
name: design-packs
description: Design Packs — cutting a piece of this project's User Experience System (a behaviour rule with its code, a recipe, or a block) into a folder another project can install, installing a piece or an app pack into this project under its own tokens and roles, and comparing an installed piece with its pack. Use when the human runs `/design-pack`, or asks to extract, install or compare a piece.
user-invocable: false
---

# Design Pack

`scripts/design-pack.mjs` does what code can decide; you do what a person would. Run every
command from the repository root.

## Extract

**A piece is cut from this project, then adjusted in its folder into what any project
would use.** The source project's own code changes only as work the human asks for.

Everything is committed and the status check
(`node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`) passes; the script refuses
otherwise, and does not count its own output folder as uncommitted work.

1. **Extract.** `node .claude/skills/design-packs/scripts/design-pack.mjs extract <piece>`
   writes the piece folder, `project-documentation/temporary/design-pack/<piece>/`, or
   `<dir>/<piece>/` with `--out <dir>`. Every extract replaces that folder whole. With
   `--pack <app pack file>` each role that file's `carries` names is written with the
   source project's value and the pack's reason; every other role travels by purpose
   alone.
2. **On a refusal, say what it refused on and stop.** It refuses on an import of this
   project's business code: that is put to the human as a fix for the source project.
3. **Take out what this project added for itself.** A prop, a slot, a branch or a rule
   that exists for this project's own subject — a switch for the one kind of record its
   whole session works within — comes out of the piece's code, with the rule it carried
   and every line that mentions it. Remove the same from `piece.json`: the rule's name
   under `pieces`, a role or library nothing in the piece uses now. Put what you intend to
   take out to the human first when it changes what the piece does.
4. **Reword the comments and the prose into words any project would use:** each comment
   in the code, `references/<piece>.md`, `inventory.md`, and each role's `purpose` in
   `piece.json`. A piece is found and reused by what it is called, so an example from
   this project's own business becomes a general one, and a role's purpose says its job
   with no size or colour. Extract lists the lines it knows of. Keep what each sentence
   instructs.
5. **Take out real data.** A real customer's or person's name, an account number or a
   figure from a live record becomes an invented one. Extract lists every string a user
   reads: one holding real data is put to the human as a fix for the source project.
6. **Write `GUIDE.md` in the piece folder when it lists wiring.** Say what the receiving
   project writes itself — a provider at an app's root, a server half, the code the rule
   lists that stayed behind — by the piece's exported names and the typed contract its
   block declares, with no server code.
7. **Give each piece `piece.json` lists under `pieces`, and each control an entry under
   `atoms` names as its `piece`, its own folder beside this one,** by steps 1 to 6 with
   the same `--out`. Cut only the pieces the pack is for.
8. **Ask the human what is part of what the pack is, and why.** A pack's pieces take the
   receiving project's look except where the pack says otherwise. Run
   `node .claude/skills/design-packs/scripts/design-pack.mjs roles <folder of pieces>` and
   put the roles to the human in their groups — the gaps, the sizes, the type — with the
   values it prints. Write each group they claim into the app pack's file,
   `"carries": [{ "roles": ["--gap-*"], "why": "<their reason, in their words>" }]`,
   then extract the pieces again with `--pack`. A group with no reason is not written.
9. **Write what an app pack needs that no project holds as a piece,** in a folder of its
   own beside the others: the app assembled from the pack's pieces, and its reference
   pages, from invented data. A reference page is a realistic screen, never a gallery,
   and the pages together show every visual piece the pack ships, in context, in each
   variant and state: a card for a control's kinds and states, a button for each dialog.
   How many pages that takes is the pack's own matter. A whole page a project builds
   first as the real thing — a sign-in — is left to it. Head each page
   `// ui-recipe: <recipe>.md`, write the folder's `piece.json` by hand as extract writes
   one, and run
   `node .claude/skills/design-packs/scripts/design-pack.mjs coverage <folder of pieces>`:
   it names each component no page reaches. Show each on a page, or tell the human which
   are left to the first real screen.
10. **Prove each folder.** `node .claude/skills/design-packs/scripts/design-pack.mjs prove <piece folder>`.
   It says which files were adjusted, and fails on whatever stops the piece, as its
   `piece.json` describes it, typechecking, building, or passing the token check and the
   status check in an empty project. Fix what it names in the folder and prove again.
11. **Hand the folders to the human.** Publishing a pack is theirs.

## Install

**A piece lands on finished layers, and takes this project's look except where the pack
says a value is part of what it is.** The human reviews an install twice — its roles, then
its reference pages — and approves it whole. Run `/uxes` before the first decision.

1. **Plan.** `node .claude/skills/design-packs/scripts/design-pack.mjs install <piece or app pack> --app <workspace>`
   copies nothing. `--app` names the app the pieces are for, once for each: every recipe
   and behaviour rule lands governing those apps alone, and this project's other apps
   keep their own. It reads the published packs, or with `--from` another packs
   repository by its address, or a packs checkout on this machine by its folder. `--swap <listed piece>=<other piece>` replaces one name of an app pack.
2. **Where it refuses because the project is not ready, stop and say what it named.** It
   runs the token check over the whole project, with the vendored atoms read whatever
   `DESIGN_VENDORED_RESTYLED` says, and the status check. Finishing what they name is this
   project's own work, done before any piece is taken.
3. **Put each thing it waits on to the human, one at a time, and record their answer.**
   Answers are kept, while the install is under way, in
   `project-documentation/temporary/design-pack-answers.json`:
   `{ "beside": { "<pack file>": "<answer>" }, "standIn": { "<pack file>": "<this project's file>" } }`.
   - **A file that would stand beside one of this project's own.** Show both as the real
     thing, on a comparison page (the `design-system` skill's
     `references/comparison-pages.md`), with the screens the project's own is used by.
     Their answer goes under `beside`, by the pack file. `use-existing` copies nothing:
     the pieces use the project's file, which the copy marks `// ui-pack-for: <piece>/<file>`,
     and you bring across to it what the human wants of the incoming one. `replace` copies the incoming file; you then move each screen
     onto it and remove the project's. `keep-both: <their reason>` copies it beside the
     project's and writes the reason on its inventory line.
   - **A file the pieces expect that this project lacks.** Build it pending from this
     project's tokens (the `design-system` skill), or name the file that already does the
     job under `standIn`. One the plan found but lists as lacking an export does not
     wait: after the copy, extend it pending, or change the installed files that import
     it to what this project's file offers.
   - **A library this project lacks.** Put it to the human as any new dependency.
4. **Copy.** Run the plan again with `--apply` once it waits on nothing.
5. **Give each stand-in what the pieces pass it.** Run the plan again: under each stand-in
   it lists the variants and options its file never mentions, and `npm run check-types`
   names the rest. Add each to this project's atom, pending.
6. **Give the pieces every theme they are built for.** Where the plan says this project
   lacks a theme the pieces have — dark — that is work to do, never something to hide or
   switch off. The theme's values belong to this project's roles, so they reach every app
   that offers the theme: name those apps to the human first.
7. **Fit the roles, then review them with the human once.** The plan names each role and
   the installed files still using its classes. An install never changes the value of a
   role this project already has.
   - **Fit without asking** wherever this project's own role does the job: change the
     installed file's classes to it. Register each named utility the plan lists that
     starts as one of Tailwind's own classes does — a border width called `border-frame` —
     with this project's class-merge helper, in the group it belongs to.
   - **Then put what is left to the human in one sitting,** on one comparison page (the
     `design-system` skill's `references/comparison-pages.md`), never role by role: each
     role this project lacks, at the pack's value where the pack carries one and from this
     project's tokens where it does not; each carried value that differs from this
     project's own, in the pack's reason, with the ways on — a role of the pieces' own, this
     project's role changed, or this project's value kept; and each change that would
     reach a role another app reads, with those apps named.
   - **Write their answers into the token stylesheet and the inventory. The roles they
     reviewed are approved:** take `ui-status: pending` off each, and where the judge holds
     an item on one of those lines, write their `design-accepted` on it.
8. **Do the wiring each guide it listed describes,** in this project's own conventions.
9. **Run `npm run lint:tokens` and
   `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`, and fix what they name in
   the installed files.**
10. **Show the human the reference pages, as a whole.** Mount each one the pack landed on a
    temporary route, as its guide says. They look each over in each theme for what is
    plainly wrong; fix that in the installed files, and report a fault of the pack's own
    for the pack to be fixed. No piece is put to them one at a time.
11. **On the human's word, approve the install:**
    `node .claude/skills/design-packs/scripts/design-pack.mjs approve`. Every installed
    file becomes approved with its inventory line, and so does each file of this project's
    own marked as standing in for a pack file; the judge's items resting on those files
    are cleared. Approve in the same word each vendored atom that was extended for the
    pieces. From here the pieces are this project's: a change found while
    building is ordinary refinement. Keep the reference pages until the human says to
    remove them.

## Compare

`node .claude/skills/design-packs/scripts/design-pack.mjs compare [<file>]` prints what the
pack has changed in each installed file's pack file since the version the file points at.
With `--from`, it reads the packs repository or checkout named, as the install does.
Offer the human each change to merge by hand or leave. A merged change that changes what
shows or how the app behaves makes the piece pending. Once every change to a file is
merged or left on the human's word, write the pack's version it printed into that file's
pointer — `// ui-pack:` in code, `pack:` in a reference — then run the checks of
Install step 9.

## Report

For an extract: each folder, what was taken out of each piece, the pieces it depends on,
what it expects the project to have, and prove's result. For an install: the pieces installed, each
answer the human gave, the roles added, and what is pending.
