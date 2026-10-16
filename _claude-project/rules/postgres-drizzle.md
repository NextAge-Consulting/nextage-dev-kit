# Postgres + Drizzle

**Gate — read this first.** This file applies only when the project declares
PostgreSQL:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

`PostgreSQL` → this rule applies. `SQLServer` → read `sqlserver-drizzle.md`
instead; nothing here transfers. `Other` or `None` → none of this applies, stop
here. Empty → **the engine has not been declared, which is not the same as not
having one.** Ask before applying any engine-specific guidance, and get the key
populated.

Gate on the declared engine, never on the presence of a `drizzle.config.ts`: a
SQL Server project has one too.

`drizzle.md` holds the Drizzle rules every engine shares. Everything else about
this stack is the **postgres-neon-drizzle** skill. This file is only the failures
nothing catches until production.

**On a nondeterministic (case-insensitive) collation, `ILIKE` and regex throw.**
`nondeterministic collations are not supported for ILIKE` / `for regular
expressions` — so no `~`, `~*`, `regexp_*` either. Use `=` and `LIKE`, which are
already case-insensitive on those columns (`drizzle.md` §IV). When you need a
regex, `COLLATE "C"` on the expression makes it deterministic — and
case-sensitive, so handle case in the pattern.

**Declare every new text column with the project's collation-carrying custom type
(`ciVarchar` / `ciText`)** — never a hand-written `ALTER` in a migration. A plain
text column takes the database default and lands case-SENSITIVE beside
case-insensitive neighbours.

**Which branch am I on? Ask, don't guess.** `node scripts/db-branch.mjs` reads
`DATABASE_URL`, resolves its endpoint through the Neon API, and prints the branch
name. `DEV` (exit 0) means a resettable fork — reads and tests against it are
normal work, and a migration there is the routine case of `drizzle.md`'s approval
rule. `PRODUCTION` (exit 1) means the project's default or protected branch —
stop, and say so when you ask. `UNKNOWN` (exit 2) means it could not tell, which
is never the same as safe.

**The integration tests' database is a Neon branch per run**, forked from
production by the kit's `globalSetup.ts` and deleted in teardown, with every test
in a rolled-back transaction (`dbTest`, testing.md §1). It needs `NEON_API_KEY` and
`NEON_PROJECT_ID` in `.env` locally and in the repository's Actions secrets.

The id is UUID v7 in the native `uuid` column type (constitution §V).
