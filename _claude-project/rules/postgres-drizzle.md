---
paths: "**/*.{ts,tsx,mts,cts}"
---

# Postgres + Drizzle: The Three Silent Failures

Applies only to a project on PostgreSQL with Drizzle. No `drizzle.config.ts` →
none of this applies, stop here.

Everything else about this stack — how to define the types, run the migration,
branch the database, provision a new one — is the **postgres-neon-drizzle**
skill. This file is only the failures you would not think to look up, because
nothing catches them until production.

**1. On a nondeterministic (case-insensitive) collation, `ILIKE` and regex
throw.** `nondeterministic collations are not supported for ILIKE` / `for regular
expressions` — so no `~`, `~*`, `regexp_*` either. `=` and `LIKE` are already
case-insensitive on those columns; use them, and never wrap in `LOWER()`. When
you genuinely need a regex, `COLLATE "C"` on the expression makes it
deterministic — and case-sensitive, so handle case in the pattern.

**2. A new text column does not inherit its neighbours' collation.** It takes the
database default, so it lands case-SENSITIVE in a table where everything else is
not. Queries succeed and compare differently. Declare it with the project's
collation-carrying custom type (`ciVarchar` / `ciText`) — never a hand-written
`ALTER` in a migration.

**3. Never hand-author migration bookkeeping.** A migration is three coupled
files — the `.sql`, its `meta/NNNN_snapshot.json`, and the `meta/_journal.json`
entry. Only `drizzle-kit generate` writes all three together; hand-creating a
`.sql` or editing the journal or a snapshot desyncs the chain. Editing the body
of a `.sql` that `generate` produced is fine and often correct.

Naming conventions (singular tables, `{table}id`, UUID v7) are engine-agnostic
and live in the constitution, not here.
