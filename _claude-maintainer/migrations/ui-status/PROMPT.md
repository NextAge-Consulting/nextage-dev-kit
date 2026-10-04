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

## 3a. Build the roles and switch the token check on

Read the `design-system` skill's "Semantic tokens, or it is a design system in name only" through "Enforce it or it decays" first.

1. **Name the UI package.** Set `DESIGN_UI_PACKAGE` in `.claude/sync-substitutions.json` to the package that holds the design system (`packages/ui`, or the one app's folder) and take it out of `_intentionally_empty`. Set the other design keys the catalog's `_placeholders_referenced_by_kit` describes. A token stylesheet holds only the `:root` and dark blocks; when the tokens sit in the Tailwind entry beside its `@theme`, move them into their own `tokens.css` first. `DESIGN_FEED_BARREL` is `""` and listed in `_intentionally_empty` unless the project publishes to Claude Design. Wire `"lint:tokens": "node .claude/skills/design-system/scripts/check-design-tokens.mjs"` at the root if it is missing. Run `npm run lint:tokens` and keep its counts as the baseline.
2. **Build the roles on a deliberate scale.** Each family — type, weight, radius, spacing, shadow, colour — gets a scale with deliberate steps in whole pixels, per "Converting a legacy app: do not derive values from it". Then group the values in use by what each element is. Each group becomes a role named for what it is, set to the scale step the group already uses most, so the swap changes nothing; a value off the scale is never a role's value — it snaps to the nearest step. Define every role in the token stylesheets, each with its comment.
3. **Convert every call site and every component variant to the roles.** A size a screen picks (`size="sm"`, `h-8`) becomes a role-named size or variant on the component.
4. **Prove what changed.** Run `node .claude/skills/design-system/scripts/compare-ui-values.mjs`. A line it proves identical needs nothing. For each change it lists, either adjust the role until the line is identical, or keep it as a deliberate snap.
5. Run `npm run lint:tokens` until it passes.

A role that only names values already in use changes nothing a user sees, so it needs no approval. What goes to me is only what `compare-ui-values.mjs` still lists, grouped by role.

## 4. Known Gaps

If `design.md` has a Known Gaps section, remove the heading and move each entry, in present tense, into the section it belongs to — a colour fact into Colors, a scope note into Overview. Anything that is a real missing piece goes to me instead.

## 5. Prove it

```bash
node .claude/skills/ui-patterns/scripts/check-ui-status.mjs
```

It passes with nothing pending. Then run `npm run check-types`, `npx --no-install @biomejs/biome lint --max-diagnostics=none`, `npm run lint:tokens` and `npm run lint:design`, and fix every failure.

## Report

- the files marked approved, as a count
- the inventory before and after, in rows per section
- every rule moved, and where it went
- the roles built, one line each, with the values they hold
- `lint:tokens` before and after, by kind
- what `compare-ui-values.mjs` still lists, grouped by role
- every Known Gaps entry, and where it went
- each check's result
