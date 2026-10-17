# The fit check

A fresh agent decides whether a component should exist as built, and what it is called,
before its inventory line is written.

## When

- A new component, before its line goes into `rules/project/ui-inventory.md`.
- A change that sets a component pending, before its line is updated.
- A pending component whose file changed since its check. `check-ui-status.mjs` names it,
  and `/commit`, `/ship-main` and `/deploy` refuse until it is checked again.

## How

1. **Describe the piece neutrally:** what it draws, what it does, its states — never the
   screen it serves, its data, or its working name.
2. **Start a fresh agent** with the prompt below, the description and the built file's path.
3. **On `CHANGES`, make them and send the revised file to the same agent.** Repeat until
   it answers `APPROVED`. A change may be using an existing component, adding a variant,
   slot or prop to one, renaming, retyping, or moving the piece into its feature folder,
   where it is content: no status and no line.
4. **On `APPROVED`, write the line it returns**, with the Fit check cell holding the file's
   fingerprint and the agent's verdict:

   ```
   | `facet-choice` | One facet of a list's filter where exactly one option applies | <none> | pending | `1a2b3c4d` new; the single-choice partner of facet-checklist |
   ```

   Take the fingerprint after the last change the agent approved:
   `node .claude/skills/ui-patterns/scripts/check-ui-status.mjs --fingerprint <file>`.

Take a disagreement with the agent to the human.

## The prompt

```
You review whether a UI component should exist as built. Read, in this repository:
- .claude/rules/project/ui-inventory.md — every component, pattern and hook the app has
- .claude/skills/design-system/references/block-types.md — the block types and "Sort before you build"
- the code of every component you consider, under the app's components/ folders
- the built file: <path>

The piece, described without its screen or name: <description>

Decide, reading the code rather than guessing:
1. Does an existing component already carry this, or would a variant, slot or prop named
   for meaning on one carry it?
2. If not: is it a component at all? A piece that fits no block type and draws no box
   (background, border, radius, shadow, padding) stays in its feature folder until a
   second screen needs it.
3. If it is: is it named for the kind of thing it is, never its data or its screen? Is its
   block type right? Is it the only component of that type, or does its line give the
   human's reason for a second?

Answer APPROVED with the inventory line to write — name, what it is for, type, `pending` —
and a verdict of a few words naming the nearest existing component. Or answer CHANGES,
listing each change and why. Approve only what you would leave exactly as it is.
```
