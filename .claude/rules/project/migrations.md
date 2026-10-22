---
paths:
  - "_claude-maintainer/migrations/**"
---

# Writing a migration

**A migration is `_claude-maintainer/migrations/<name>/PROMPT.md`, with any codemod or helper beside it: a prompt `/sync-dev-kit` runs in a project's session to adjust the project to a kit change no file copy can make.** Its folder, named for the change in kebab-case, is added in the same change as the kit change that needs it; the sync runs a backlog in the order the kit added them.

**A `PROMPT.md` runs in this order:** an H1 `# Migration: <what it does>`; one paragraph saying when the sync runs it and when it does not apply; an `## Estimate`; a `---` line; then the steps, which the sync carries out as the user's instruction.

**The Estimate sizes the migration's blast radius in a project that does not yet hold the new kit files.** The sync's briefing runs it before the user decides whether to go ahead:

````
## Estimate

Kind: mechanical
Kind: asks for decisions — <which decisions>     (one or the other)
Your time: <minutes per decision point, or "none — runs unattended">

Blast radius:

```bash
<read-only commands that count what it touches in this project>
```

<how to read the counts, and what output means it does not apply>
````

- **`Kind`** is what `/shipkit` reads for the release title: the line starts exactly `Kind: mechanical` or `Kind: asks for decisions`. Asks for decisions means the steps stop for the team — an approval, a choice, a change only they may apply.
- **`Your time`** is the developer's minutes in the session deciding, per decision point — one figure for each kind of decision when there are several. Never estimate how long Claude's unattended work takes.
- **The commands count what is affected, not everything of that kind** — the blocks a new rule judges differently, not every block. They read new kit content from `$KIT`, set in the block itself as `KIT=$(jq -r .devKitPath ~/.claude/dev-kit-config.json)`, because the project still holds the old, and they write nothing: a codemod only with `--dry-run`.

**Before the migration ships, run the Estimate's commands against a project that has not run it, and check that project's `git status` is unchanged after.**
