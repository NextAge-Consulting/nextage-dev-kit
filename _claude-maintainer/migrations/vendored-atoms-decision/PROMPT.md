# Migration: decide where the vendored atoms stand

`/sync-dev-kit` runs everything below the line in the consumer project's session, once it has landed the kit version whose status check reads `DESIGN_VENDORED_RESTYLED`. It does not apply to a project that names no `DESIGN_VENDORED_DIR`, or whose `DESIGN_VENDORED_RESTYLED` is `"true"`: say so and record it as run.

## Estimate

Kind: asks for decisions — whether the vendored atoms are restyled onto the project's roles now, set aside, or left pending
Your time: about 5 minutes, once, to see what is off the roles and choose. Restyling, when chosen, is the project's own work after the sync, with each restyled control put to you as any new piece is.

Blast radius:

```bash
KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)
jq -r '"dir=\(.DESIGN_VENDORED_DIR // "") restyled=\(.DESIGN_VENDORED_RESTYLED // "") listed=\((._intentionally_empty // []) | index("DESIGN_VENDORED_RESTYLED") != null)"' .claude/sync-substitutions.json
DIR=$(jq -r '.DESIGN_VENDORED_DIR // ""' .claude/sync-substitutions.json)
[ -n "$DIR" ] && node "$KIT/_claude-project/skills/design-system/scripts/check-design-tokens.mjs" --controls --repo . 2>&1 | grep -c "^ *$DIR/"
```

An empty `dir`, or `restyled=true`, means it does not apply. The count is the places inside the vendored atoms that bypass a role: what restyling would change. `listed=true` means the project's settings already record the atoms as deliberately left as they are.

---

Settle where this project's vendored atoms stand. Make no git commits — leave everything uncommitted for me to review.

The vendored atoms are the controls under `DESIGN_VENDORED_DIR`. Until they are restyled onto this project's roles they keep the styling they were downloaded with: a role this project changes does not reach inside them, and the token check does not read them. `DESIGN_VENDORED_RESTYLED` records which state they are in, and the status check reports it.

1. **List what is off the roles:** `node .claude/skills/design-system/scripts/check-design-tokens.mjs --controls`. Count the lines under `DESIGN_VENDORED_DIR`, by control.
2. **Put it to me once, with those counts and the screens that use the controls:**
   - **Restyle them.** Each control's classes move onto this project's roles at source (the `design-system` skill, "A vendored atom is restyled once, at the source"). Every screen that uses a control changes a little, and each restyled control is pending until I have looked at it. When the last is done, set `DESIGN_VENDORED_RESTYLED` to `"true"`.
   - **Set them aside.** List `DESIGN_VENDORED_RESTYLED` in `_intentionally_empty`. Nothing is blocked, the status check counts them among what is set aside, and no Design Pack can be installed until they are restyled.
   - **Leave them pending.** Keep the key empty and out of `_intentionally_empty`. `/work` shows them each session and `/deploy` refuses until restyled or set aside is chosen.
3. **Where the key is already listed in `_intentionally_empty`,** ask the same question, and keep the listing only on my answer.
4. **Write my answer into `.claude/sync-substitutions.json`** and run `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs` to show the state it now reports. Restyling, where I chose it, starts after this sync.
