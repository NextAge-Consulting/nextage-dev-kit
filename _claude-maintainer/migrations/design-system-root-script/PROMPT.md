# Migration: the root runs the design-system build

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit's `scripts/check-stack.mjs` that requires a root `build:design-system` script. It applies to a project whose UI package is a workspace holding a claude-design config; any other project needs nothing.

## Estimate

Kind: mechanical
Your time: none — runs unattended.

Blast radius:

```bash
UI=$(jq -r '.DESIGN_UI_PACKAGE // ""' .claude/sync-substitutions.json)
echo "UI package: ${UI:-none}"
ls design.md "$UI/design-system/design-system.config.mjs"
jq -r '.scripts["build:design-system"] // "none"' package.json
```

It applies when the UI package is a folder other than `.`, both files are listed, and the last line is `none` or a script that does not pass that package to `-w`. It then changes one line of the root `package.json`. A missing file, or a UI package of `none` or `.`: it does not apply.

---

Give the root `package.json` the `build:design-system` script the kit's stack check requires. Make no git commits — leave everything uncommitted for me to review.

Run every command from the repository root.

1. Read the UI package: `UI=$(jq -r '.DESIGN_UI_PACKAGE // ""' .claude/sync-substitutions.json)`. When it is empty or `.`, or `design.md` or `$UI/design-system/design-system.config.mjs` does not exist, report that the migration does not apply and stop.
2. Read the package's name: `jq -r '.name // ""' "$UI/package.json"`.
3. In the root `package.json`, set `scripts["build:design-system"]` to `npm run build:design-system -w <name>`, using the folder in `$UI` when the package has no name. A script already passing that name or folder to `-w` stays as it is.
4. Run `node scripts/check-stack.mjs` and confirm it reports no `build:design-system` finding.
5. Run `npm run build:design-system` and confirm it runs the UI package's build. Leave any file it regenerates in the tree.

Report the script written, or why the migration did not apply; the stack check's result; and each file the build regenerated.
