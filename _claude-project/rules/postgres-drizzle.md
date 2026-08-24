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

**Which branch am I on? Ask, don't guess.** `node scripts/db-branch.mjs` reads
`DATABASE_URL`, resolves its endpoint through the Neon API, and prints the branch
name. `DEV` (exit 0) means a resettable fork — reads, tests and migrations against
it are normal work, so proceed. `PRODUCTION` (exit 1) means the project's default
or protected branch — stop and get approval. `UNKNOWN` (exit 2) means it could not
tell, which is never the same as safe.

Your local `.env` normally points at a dev branch. Run the check rather than
inferring in either direction: stalling on a dev branch wastes the session, and
assuming a dev branch on prod is worse.

Naming conventions (singular tables, `{table}id`, UUID v7) are engine-agnostic
and live in the constitution, not here.
