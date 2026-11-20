---
description: Design Packs — cut a piece of this project's User Experience System for another project to take, install a piece or an app pack here under this project's own look, or compare an installed piece with its pack
argument-hint: "extract <piece> | install <piece or app pack> --app <workspace> [--from <packs repository>] [--swap <listed piece>=<other piece>] | approve | compare [<file>] [--from <packs repository>]"
---

# /design-pack

$ARGUMENTS

Run only when the human asks for it. Invoke the `design-packs` skill and follow the steps
of the mode named, to the end.

- **`extract <piece>`** — `<piece>` is a recipe's or behaviour rule's file name without
  `.md`, or a block as the inventory names it.
- **`install <piece or app pack> --app <workspace>`** — a piece's name, or an app pack's,
  which is a list of pieces, and the app taking them. Ask the human which app when they
  have not said.
- **`approve`** — approves everything a pack installed here. Run it only on the human's
  own word, after they have reviewed the roles and looked over the reference pages.
- **`compare [<file>]`** — one installed file, or every one.

`--from <packs repository>` on `install` and `compare` reads that repository in place of
the published packs. Pass it to the script as given.
