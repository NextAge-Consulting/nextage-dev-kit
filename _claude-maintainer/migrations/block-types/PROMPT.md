# Migration: block types, parts and feature folders

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine. The session brings `main` level, syncs the kit, then migrates. A project whose `DESIGN_UI_PACKAGE` is intentionally empty and that has no component or pattern files needs none of it: both checks pass saying they do not apply.

---

Bring this project's UI onto the kit's block types. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review.

## 0. Start on a clean, current main, then sync

`git status` must show `main` with nothing uncommitted. Run `git fetch origin`; when `main` is behind, bring it level with `git pull --ff-only origin main`. On another branch, with uncommitted work, or with a pull that will not fast-forward, stop and ask me — sync and migrate nothing until I have cleared it.

Then run `/sync-dev-kit` and apply everything it offers. When auto mode refuses `sync-dev-kit.sh --apply-file`, ask me to approve it; never work around it.

Read these next, in full: `.claude/skills/design-system/references/block-types.md`, the `design-system` skill's Step 2, the `ui-patterns` skill's "Adding a reference", and the "How this list works" section of `.claude/rules/project/ui-inventory.md`. Invoke the `rule-authoring` skill before editing the inventory or a pattern reference.

## 1. Baseline

Run `npm run lint:tokens` and `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`. Keep the counts by kind. They are the report's "before".

The screen rules — no box, no faded colour, no frame atom outside a part — judge only lines a change touches, so screens nobody edits are left as they are; this migration does not clean them up.

## 2. Sort every component into part or content

Go through every `.tsx` under a `components/` folder, vendored atoms aside. For each, ask: is it a kind of thing — a frame of a block type, or a shared piece several screens use — or one screen's content, named for that screen's data?

- **Content** moves to the app's `src/features/<feature>/` (`apps/<app>/src/features/<feature>/` in a monorepo), the feature being the screen or module it serves, with its imports updated. Its `ui-status` line and its inventory line go.
- **A part** stays. Name it for its kind, never its content: `CustomerNotesDialog` becomes the type it is, or folds into the part of that type that already exists.

## 3. Type every part

Give each component table in the inventory a Type column, after "Use for". Each part's line names its block type from the list, or `<none>` when no type fits. A vendored atom's table has no Type column.

Two parts of one type: ask me whether they are the same thing. Same: merge them into one. Different: write my reason on each line.

## 4. Type every pattern

Every reference in `.claude/skills/ui-patterns/references/` gets `block-types:` in its frontmatter: the types it governs as a list (`[BrowseScreen, Pager]`), or `cross-cutting` when it governs every type. A reference named for this project's data is renamed for the kind it governs, and its inventory line with it.

## 5. Repaints through constants

For each "a call site places a component, never repaints it" finding, make the look a variant on the component, named for what the thing is.

## 6. Prove it

Run `npm run lint:tokens`, `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs`, `npm run check-types`, `npx --no-install @biomejs/biome lint --max-diagnostics=none`, `npm run lint:design`, knip exactly as CI runs it — `npx --yes knip@$(jq -r .packages.knip.version .claude/stack-manifest.json) --no-progress --no-config-hints` — and `npm test`, and fix every failure.

A part this migration only moved or retyped stays as it was. A new part is pending and goes to me at the end.

## Report

- every component moved to a feature folder, and where it went
- every part with its block type, and every merge or rename
- every pattern with its `block-types:`
- `lint:tokens` and the UI status check before and after, by kind
- each check's result
