# Migration: UI status and the plain UI inventory

The maintainer pastes everything below the line into a consumer project's Claude session, on the maintainer machine, after `/sync-dev-kit` has landed the kit version that ships `.claude/skills/ui-patterns/scripts/check-ui-status.mjs`. A project with no component or pattern files needs none of it: the check passes saying it does not apply.

---

Bring this project's UI onto the kit's approval model. Work through every step below to the end. Make no git commits — leave everything uncommitted for me to review.

Read these first: `.claude/rules/ui-design.md` ("One app, one look and feel"), the `design-system` skill's Step 2, and the kit's `templates/ui-inventory.md`. The migration tools live in the kit:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
MIG="$KIT/_claude-maintainer/migrations/ui-status"
```

## 1. Bring the UI inventory onto the kit's regions

When the sync reported `.claude/rules/project/ui-inventory.md` as unable to merge because the project has a region the kit does not (`list-patterns`), move that region's content by hand:

- each list pattern becomes a row in the `pattern-references` region;
- the rules it carried — which pattern to use when, the boundary between them, "never a third" — move into the reference file of the pattern they govern;
- then delete the region and its markers, and apply the kit's version: `bash ~/.claude/scripts/sync-dev-kit.sh --apply-file _claude-project/templates/ui-inventory.md`.

## 2. Mark everything that exists as approved

Preview, then mark:

```bash
node "$MIG/mark-approved.mjs" . --dry-run
node "$MIG/mark-approved.mjs" .
```

## 3. Rewrite the inventory's regions as plain lists

Match the kit template's tables: patterns, components (the project's own, the vendored atoms, app composites) and hooks, one row each, with a Status column on patterns and components. Name each component by its file — `icon-button.tsx`, `IconButton`, or a path such as `form/fields` where two files share a name. Every component and pattern file gets a row.

A line that is not a list item or a "never hand-roll X, use Y" line is a rule. Move it into the reference file of the pattern it governs; a rule that governs no pattern goes in its own file under `.claude/rules/project/`. Do the same for any other `.claude/rules/project/*.md` whose rules are about how a kind of screen works.

## 4. Known Gaps

If `design.md` has a Known Gaps section, leave it in place and list every entry in the report: each one is now either a part to build and mark pending, or a decision for me.

## 5. Prove it

```bash
node .claude/skills/ui-patterns/scripts/check-ui-status.mjs
```

It passes with nothing pending. Then run `npm run check-types`, `npx --no-install @biomejs/biome lint --max-diagnostics=none`, and `npm run lint:tokens` and `npm run lint:design` when `design.md` exists, and fix every failure.

## Report

- the files marked approved, as a count
- the inventory before and after, in rows per section
- every rule moved, and where it went
- every Known Gaps entry
- each check's result
