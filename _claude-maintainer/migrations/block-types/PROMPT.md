# Migration: block types, parts and feature folders

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has landed the kit version that ships `.claude/skills/design-system/references/block-types.md`. A project whose `DESIGN_UI_PACKAGE` is intentionally empty and that has no component or pattern files needs none of it: both checks pass saying they do not apply.

---

Bring this project's UI onto the kit's block types. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review.

Read these first, in full: `.claude/skills/design-system/references/block-types.md`, the `design-system` skill's Step 2, the `ui-patterns` skill's "Adding a reference", and the "How this list works" section of `.claude/rules/project/ui-inventory.md`. Invoke the `rule-authoring` skill before editing the inventory or a pattern reference.

## 1. Baseline

Run `npm run lint:tokens` and `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`. Keep the counts by kind — screen boxes and colours, frame atoms, repaints, block types, inventory lines. They are the report's "before".

## 2. Sort every component into part or content

Go through every `.tsx` under a `components/` folder, vendored atoms aside. For each, ask: is it a kind of thing — a frame of a block type, or a shared piece several screens use — or one screen's content, named for that screen's data?

- **Content** moves to `apps/<app>/src/features/<feature>/`, the feature being the screen or module it serves, with its imports updated. Its `ui-status` line and its inventory line go.
- **A part** stays. Name it for its kind, never its content: `CustomerNotesDialog` becomes the type it is, or folds into the part of that type that already exists.

## 3. Type every part

Give each component table in the inventory a Type column, after "Use for". Each part's line names its block type from the list, or `<none>` when no type fits. A vendored atom's table has no Type column.

Two parts of one type: merge them into one, unless they genuinely differ — another app's chrome in the same repository — and then each line says what sets it apart.

## 4. Type every pattern

Every reference in `.claude/skills/ui-patterns/references/` gets `block-types:` in its frontmatter: the types it governs as a list (`[BrowseScreen, Pager]`), or `cross-cutting` when it governs every type. A reference named for this project's data is renamed for the kind it governs, and its inventory line with it.

## 5. Frames come from parts

For each `lint:tokens` finding "a frame atom is used only inside a part": the screen uses this app's part of the type the finding names. When the app has none, build it in the UI package — pending, named for the type — and move every screen of that type onto it. The screen keeps its content: the wording, the data, the server calls.

## 6. Screens draw no box

A screen styles its own text from the semantic roles; every finding that starts "a screen or feature file" is a box, a palette or faded colour, or another look that belongs in a part.

1. **Group the findings into looks** — one element's classes, merged where they differ only by placement — and count each look's uses.
2. **Match each look to the component that already draws it.** A palette colour whose semantic token holds the same value becomes that token. A look an existing atom or part already draws exactly moves onto it. Neither changes anything on screen.
3. **A look no component draws** becomes the part of its block type — new, pending — or a part typed `<none>`, or an atom variant when it is text or a single control.
4. **A thing drawn more than one way** — a notice at two paddings, muted text at three opacities, a page gutter three ways — is a decision for me, put to me as a comparison page built exactly as `.claude/skills/design-system/references/comparison-pages.md` says. Present only looks that differ on screen; code variants that render the same are unified without asking. Move every use onto the pick.
5. A class constant shared between screens becomes a variant on the part, and the constant goes.

Then prove the rest did not change: `node .claude/skills/design-system/scripts/compare-ui-values.mjs`. A line it proves identical needs nothing. Every change it lists is one I picked in step 4, or is corrected until identical.

## 7. Repaints through constants

For each "a call site places a component, never repaints it" finding the sync introduced, make the look a variant on the component, named for what the thing is.

## 8. Prove it

Run `npm run lint:tokens`, `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`, `npm run check-types`, `npx --no-install @biomejs/biome lint --max-diagnostics=none`, `npm run lint:design`, the project's knip script and `npm test`, and fix every failure.

A part extracted unchanged — `compare-ui-values.mjs` lists its styles as moved — or carrying a look I picked in step 6 is written `approved`. Only a part bringing a look I have not seen is pending; walk me through those, as the `design-system` skill's review describes, before calling this done.

## Report

- every component moved to a feature folder, and where it went
- every part with its block type, and every merge or rename
- every pattern with its `block-types:`
- the parts built, each with the type it serves and the screens moved onto it
- every decision, its variants and my pick
- `lint:tokens` and the UI status check before and after, by kind
- what `compare-ui-values.mjs` still lists, grouped by part
- each check's result
