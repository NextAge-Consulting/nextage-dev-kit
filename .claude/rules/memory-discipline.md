# Memory Discipline

Before writing anything to auto-memory, route it. Auto-memory is machine-local
and invisible to everyone else — anything shared that lands there is a leak.

## The routing test — run it before every memory write

1. **Would this apply to more than one project, or to anyone on the team?**
   → It's a KIT rule. Put it in the kit's `.claude/rules/`, not memory.
2. **Is it specific to THIS project** (its schema, apps, architecture, legacy
   quirks)? → It's a PROJECT rule or doc: `.claude/rules/project/**` or
   `project-documentation/`, not memory.
3. **Only if it's neither** — a genuinely ephemeral single-session scratch note,
   or a personal/machine fact that must NOT be shared — does it belong in memory.
   That is rare. When in doubt, it's a rule, not a memory.

## Why

A behavior rule written to memory reaches only the machine that wrote it. A
teammate's AI on the same project never sees it, so the two drift. Rules files
travel with the repo; memory does not. If it should govern how work gets done,
it goes in a rule.
