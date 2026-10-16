# Drizzle

**Gate — read this first.** This file applies when a `package.json` outside
`node_modules` declares `drizzle-orm`:

```bash
rg -l '"drizzle-orm"' --glob '**/package.json' --glob '!**/node_modules/**'
```

No hit → stop here. A hit → this rule applies on every engine, alongside the
engine's own rule: `postgres-drizzle.md` on `PostgreSQL`, `sqlserver-drizzle.md`
on `SQLServer` (`jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json`).

## I. Queries go through the schema

**Use the query builder on the schema's table objects.**

**Where SQL is needed, interpolate the schema's objects, never a typed name.**

```ts
sql`${invoice.total} - coalesce(${invoice.paid}, 0)`        // ✓ checked
sql`invoice.total - coalesce(invoice.paid, 0)`              // ✗ a rename compiles clean
```

**Interpolate every value as `${value}`.** `sql.raw` takes only text the code
itself wrote — an identifier from the schema, a keyword — never a value.

**Add a table a query needs to the schema.** On a partly-introspected schema,
widen the drizzle config's `tablesFilter` and pull it.

**Mark a whole query sent through any handle's `.execute(…)` — `db`, `tx`, a pool — with
a `raw-sql:` comment naming what the builder cannot express**, on the line above or the
same line:

```ts
// raw-sql: recursive CTE over the category tree
const rows = await db.execute(sql`with recursive tree as (…) select …`);
```

`scripts/check-integration-coverage.mjs` fails a changed `.execute(…)` without one,
and `/commit`'s SQL review reads changed `sql` templates for typed names.

## II. Migrations

**Write migrations with `drizzle-kit generate` only.** It writes the `.sql`, its
`meta/NNNN_snapshot.json` and the `meta/_journal.json` entry together; never
create a `.sql` by hand or edit the journal or a snapshot. Editing the body of a
generated `.sql` is fine. `block-drizzle-handroll.sh` enforces it.

**Apply a migration only with the human's explicit approval in the current
conversation.** That covers `db:migrate` and `drizzle-kit migrate`; prefix an
approved run with `SKIP_DB_GUARD=1` (`block-db-commands.sh`). An autonomous session
follows the authorization the human gave it at handoff (`autonomous-sessions.md`);
with none, the approval rule stands.

`db:generate` needs no approval: it writes files and opens no connection. Neither does
running the test suite: the harness migrates only the throwaway database it creates.

**Never run `drizzle-kit push` or `db:push`.**

## III. When the project does not own the whole schema

The boundary is which files each drizzle config's `schema` points at, because
`drizzle-kit generate` diffs the TypeScript schema against its stored snapshot and
never reads the database:

- **Introspected tables** — pulled from the existing database, used for queries.
  No config's `schema` points `generate` at them.
- **Owned tables** — everything this project adds, with their own schema entry
  point, config, `out` directory and snapshot chain. Prefix them so they stand out
  in the shared namespace.

**A schema change to a table the project does not own is a cross-team change**,
agreed with whoever owns the other writer first.

Nothing at the database level enforces the boundary; enforcement is a
login-and-permissions change. Record in the project's documentation which side
each table sits on, and whether full ownership of the schema is a goal.

## IV. Case-insensitive collations

**Compare a case-insensitive column directly — never wrapped in `LOWER()` or
`UPPER()`.** `=` and `LIKE` already ignore case there, and the wrapper defeats the
index. The engine rule says which columns are case-insensitive.
