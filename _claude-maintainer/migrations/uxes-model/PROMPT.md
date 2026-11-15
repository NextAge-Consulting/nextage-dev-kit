# Migration: the User Experience System model

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose `design-system` skill carries the kinds (token, atom, block, recipe, behaviour rule, screen), the status words and the pointers. A project whose `DESIGN_UI_PACKAGE` is intentionally empty and that has no component or reference files needs none of it: the checks pass saying they do not apply.

## Estimate

Kind: asks for decisions — each inconsistency the app has today (one thing drawn or behaving two ways), which you walk on a comparison page, call right as it is, or defer; each second block of one type, the same thing or different; each shared business-named composite's new home; each page type whose screens are arranged differently
Your time: about 3 minutes per inconsistency walked, 1 minute per one deferred; about 2 minutes per second block and per placement.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
node "$KIT/_claude-maintainer/migrations/uxes-model/codemod.mjs" . --dry-run
grep -c 'unresolved' .claude/rules/project/ui-inventory.md
grep -L '^kind:' .claude/skills/ui-patterns/references/*.md 2>/dev/null | grep -v README | wc -l
git ls-files '*.tsx' | grep -c 'routes/\|features/'
```

The codemod's dry run names what it renames and headers mechanically, and lists what is left for the session: components with no type on the list, screens with no header, references with no `kind:`. The second count is deferred lines renamed in place; the third, reference files to sort into recipes and behaviour rules; the fourth, screens that gain a pointer. Every inconsistency is found only once the system is read; the dry run's "left for the session" counts are the order of magnitude. `DESIGN_UI_PACKAGE` intentionally empty: it does not apply.

---

Bring this project's User Experience System onto the kit's model. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review. Every decision below that is mine comes to me in this session, one at a time, by `asking-questions.md`.

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MIG="$KIT/_claude-maintainer/migrations/uxes-model"
```

## 0. Start on a clean, current main

`git status` must show `main` with nothing uncommitted beyond the files this sync applied. Run `git fetch origin`; when `main` is behind, stop and ask me — migrate nothing until I have cleared it. On another branch, stop and ask me the same.

Read these next, in full: `.claude/commands/uxes.md`, which says how the whole system fits together and that the project is brought to it; the `design-system` skill (`.claude/skills/design-system/SKILL.md`) and its `references/block-types.md`, the `ui-patterns` skill, and the "How this list works" section of `.claude/rules/project/ui-inventory.md`. Invoke the `rule-authoring` skill before editing the inventory or a reference.

## 1. Baseline, and the proof's "before"

Run `npm run lint:tokens` and `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`; keep the counts by kind as the report's "before". Build every app the way CI builds it and keep each app's emitted JavaScript aside (copy the build output folder to `project-documentation/temporary/uxes-before/<app>/`): the mechanical half must leave it byte-identical.

## 2. The mechanical half

Preview, then apply:

```bash
node "$MIG/codemod.mjs" . --dry-run
node "$MIG/codemod.mjs" .
```

It renames `unresolved` to `deferred` and drops the reasons, removes the inventory's Fit check column, and adds `// ui-block: <Type>` or `// ui-atom` to every component whose type the inventory already names. Comments and table cells only.

## 3. Sort every component the codemod left

Sort each component the dry run listed as untyped — typed `<none>` today, or typed with a word not on the list — by `block-types.md`, "Sort before you build", exactly as a new piece is sorted: split the frame from the content, then sort the frame. `$KIT/project-documentation/uxes-layers.svg` draws the layers. What each outcome does to the files:

- **An atom** — `// ui-atom`, its line in the atoms table.
- **A variant or option of an existing block** — fold it in: the existing block gains the variant or option, the file goes, every caller moves.
- **A frame two apps both draw** — one shared block in the shared UI package, built from the two, what differs a slot or an option; each app's file goes, or keeps only that app's content.
- **A block of a type on the list** — `// ui-block: <Type>`, the Type cell.
- **A page type's frame** — a block typed with a page type; step 4 takes its content out.
- **Content** — whichever `components/` folder holds it today. Content one app uses moves to that app's `src/features/<feature>/`; content two apps share moves to a `features/<area>/` folder of the shared package that holds it. Update every import; the compiler checks them. Its `ui-status` line and its inventory line go.

Two blocks of one type, in one app or across two: show me both and ask whether they are the same thing. Same: merge into one. Different: my reason on the second's line.

## 4. Every route gets a page type, and every page type a frame

Sort every route by page type (`block-types.md`, "Screen frames"), by what the screen is: each lands in exactly one, the nearest where none fits exactly, and a type with one screen is still a type. A route is a file a user lands on. A file it pulls in that holds its wording, data and server calls is content, and a file that draws no frame of its own — a root document, a layout route that only mounts an outlet, a router, a provider, a data adapter, a render helper — is wiring: neither is a screen, and neither is sorted. A frame found in wiring, such as a root document drawing the app's top bar, moves into the block of its type.

Each page type the app has needs one frame:

- **A block already typed with it** — that block.
- **A layout component its screens already share** — that component, typed with the page type.
- **Screens that each lay themselves out** — build the frame from what every screen of the type shares today, pending, and move each screen onto it. What differs between them stays in each screen, and goes on step 9's list. `compare-ui-values.mjs` lists nothing changed.

For each frame — a block typed with a page type (BrowseScreen, RecordScreen, ListDetailScreen, AsideScreen, DashboardScreen, SettingsScreen, ModuleLanding, Wizard): it is the recipe's frame. It keeps the behaviour every screen of that type shares — the form element, the loading state, the error state — and loses any content of its own (wording, a module's text), which moves to a feature file. Its inventory line stays in the components table with its type; the recipe in step 5 names it as `frame:`.

## 5. References become recipes and behaviour rules

Each file in `.claude/skills/ui-patterns/references/` becomes one kind, never both:

- **A recipe** (`kind: recipe`, `frame: <component>`, `reference: <one screen file>`, `block-types: [<page type>]`): how that page type's slots are filled, each open choice a pick from a closed list. Every page type step 4 found has one: where no reference file describes it, write it from the screens as they are today, pending.
- **A behaviour rule** (`kind: behaviour`, `code: [<files>]`, `block-types:`): how the app acts on one topic, everywhere, naming the blocks and functions that carry it out.

In a repository with several apps, settle which apps each reference governs from the code — the apps whose screens follow it and whose blocks carry it out — without asking me. One that holds for some of them gets `apps: [<workspace>, …]`, the workspaces as the root `package.json` declares them; one that holds everywhere gets no `apps:` line. Two references for apps that never meet are never judged against each other.

A file that mixes both splits into two. A guarantee a component makes ("the cancel is focused first", "busy never disables") moves onto that component as a header comment and out of the prose. A worked example, a source list, a date, or prose about another project's screens is dropped. Every file keeps its `ui-status` and gains its line in the inventory's Recipes or Behaviour rules table; a reference that governs nothing this project has (a page type with no screen) goes, and so does its line.

## 6. Pointers

Every file a user lands on gets `// ui-recipe: <recipe>.md` for its page type's recipe, never `// ui-content`; content and wiring get `// ui-content`; every block names the rules it carries out (`// ui-behaviour: <rule>.md, …`); behaviour code outside a block gets `// ui-behaviour-code: <rule>.md`. `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` fails until every pointer names something real and every rule's `code:` list is matched by the files pointing back.

## 7. Regenerate `design.md`

```bash
node .claude/skills/claude-design/scripts/design-md.mjs
npm run lint:design
```

The token section is now written from the stylesheet; the prose and the `components:` block are kept as they were. A frontmatter value the stylesheet does not hold is gone from the file: tell me which, so I know. A token the generator refuses — no usage comment, no family — gets its comment or its `publish: off` markers in the stylesheet.

## 8. Prove the mechanical half neutral

```bash
node .claude/skills/design-system/scripts/compare-ui-values.mjs
```

It lists nothing changed. Then rebuild every app and diff each emitted bundle against step 1's copy: byte-identical, apart from the moved files' import paths and the pieces steps 3 and 4 folded, merged or moved onto a frame, which `compare-ui-values.mjs` proves draw the same. Anything else that differs is a change this migration must not have made — undo it, or bring it to me.

## 9. Inconsistencies

Reading the system in steps 3 to 6 shows every place the app does one thing two ways: a delete icon red here and grey there, a failed action reported in three places, two arrangements of the record screen. List them in on-screen terms, with the screens where each way shows, and ask me, one at a time: walk it now, defer it, or it is right as it is.

- **Walked:** build a comparison page by `references/comparison-pages.md`, the lightest render that shows the difference truthfully, no recommendation; I pick; the screens that differ are brought into line and the rule or recipe records the pick.
- **Right as it is:** the difference is deliberate. The rule or recipe records it as a choice, with my words for when each side applies; no screen changes.
- **Deferred:** the rule or recipe is written as the app is today with `ui-status: deferred` and its fingerprint on its inventory line. It blocks nothing and comes back when the file changes.

## 10. Prove it

Run `npm run lint:tokens`, `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`, `npm run check-types`, `npx --no-install @biomejs/biome lint --max-diagnostics=none`, `npm run lint:design`, knip exactly as CI runs it — `npx --yes knip@$(jq -r .packages.knip.version .claude/stack-manifest.json) --no-progress --no-config-hints` — and `npm test`, and fix every failure. Delete `project-documentation/temporary/uxes-before/`.

## Report

- every component sorted: atom, variant folded in, typed block, or moved as content, and where
- every route's page type; every page-type block now a frame, and what content left it; every frame built here and the screens moved onto it
- every reference split, and the kind each file is now
- every pointer added, as counts
- `design.md`: what the generator wrote and what left the frontmatter
- the bundle diff's result per app
- every inconsistency: walked (what I picked), right as it is (when each side applies), or deferred
- `lint:tokens` and the status check before and after, by kind; each check's result
