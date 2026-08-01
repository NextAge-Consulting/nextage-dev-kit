# POSTGRES-COLLATION

Working with non-default PostgreSQL collations — case-insensitive columns in
particular — under Drizzle ORM. Referenced by the `postgres-collation` rule.

Read this when a project's database uses a collation other than the default.
The common reason is a migration from an engine that compares text
case-insensitively by default — several do — where the converted database keeps
that behaviour so the old and new systems agree. The other is a deliberate
choice for user-facing text.

---

## 1. What PostgreSQL gives you

Since v12, a collation can be declared **nondeterministic**, which is what makes
case-insensitive comparison possible at the column level:

```sql
CREATE COLLATION case_insensitive (
  provider = icu,
  locale = 'und-u-ks-level2',
  deterministic = false
);
```

`deterministic = false` tells PostgreSQL that two different byte sequences may
still be equal. `ks-level2` means "ignore case"; `ks-level1` also ignores
accents. This replaces the older `citext` extension and the habit of wrapping
every comparison in `lower()`.

A column then declares it:

```sql
CREATE TABLE mytable (
  itemname varchar(50) COLLATE case_insensitive
);
```

and `=`, `LIKE`, `ORDER BY`, `GROUP BY`, `DISTINCT` and unique constraints all
become case-insensitive for that column, using the index.

### Four constraints that shape everything else

**A collation object is per-database.** `CREATE COLLATION` runs inside one
database. A newly created database does not have it, and referencing it there
fails with `collation "case_insensitive" does not exist`.

**It cannot be a database default.** From `CREATE DATABASE`, Notes: *"There is
currently no option to use a database locale with nondeterministic comparisons…
If this is needed, then per-column collations would need to be used."* Still true
as of PostgreSQL 18, and unchanged in 19. There is no way to make a whole
database case-insensitive; it is applied column by column.

**A new column takes the DATABASE default, not its neighbours'.** Adding a column
to a table whose every other text column is case-insensitive produces a
case-sensitive one. Nothing warns you — queries succeed and quietly compare
differently.

**`ILIKE` throws.** `ERROR: nondeterministic collations are not supported for
ILIKE`. Plain `LIKE` and `=` are already case-insensitive on such a column, so
use those. Code written with `ilike` type-checks, builds, passes review, and
fails the first time a user types in the search box.

### Performance

Nondeterministic collations cost something. B-tree indexes cannot use
deduplication on them, and "starts with" (`LIKE 'value%'`) does not use a plain
B-tree index. On small tables this is invisible; on large ones add a GIN trigram
index (`pg_trgm`) to the affected column. "Contains" (`LIKE '%value%'`) was never
indexed anyway.

---

## 2. What Drizzle does NOT give you

**Drizzle cannot express column collation for PostgreSQL.** There is no collation
option on any `pg-core` column builder, and the only `collate` handling inside
`drizzle-kit` is in its MySQL and SingleStore serializers.

This is a known, long-standing gap: drizzle-orm issue **#638, "[FEATURE]: Support
setting collation of columns"**, open since May 2023, with repeated requests.

One consequence is benign: because `drizzle-kit` cannot *see* collation, it never
diffs on it. Existing collated columns are safe — `generate` will not emit an
`ALTER` that strips them.

The other consequence is the whole problem: **`drizzle-kit` cannot create it
either**, so every column it generates lands on the database default.

---

## 3. The fix: a `customType` that carries the COLLATE clause

`customType.dataType()` returns raw SQL for the column type, so the collation can
ride along:

```ts
import { customType } from 'drizzle-orm/pg-core';

/** varchar with the case-insensitive collation. */
export const ciVarchar = customType<{ data: string; config: { length: number } }>({
  dataType(config) {
    return `varchar(${config!.length}) COLLATE case_insensitive`;
  },
});

/** text with the case-insensitive collation. */
export const ciText = customType<{ data: string }>({
  dataType() {
    return 'text COLLATE case_insensitive';
  },
});
```

Used like any other column type:

```ts
export const mytable = pgTable('mytable', {
  itemname:  ciVarchar({ length: 50 }).notNull(),
  notes:     ciText(),
  tokenhash: varchar({ length: 64 }),   // deliberately case-sensitive
});
```

**Verified against `drizzle-kit` 0.31.x** — it emits the collation on both paths:

```sql
-- CREATE TABLE
"itemname"  varchar(50) COLLATE case_insensitive NOT NULL,
"notes"     text COLLATE case_insensitive,
"tokenhash" varchar(64)

-- ADD COLUMN
ALTER TABLE "mytable" ADD COLUMN "description" varchar(200) COLLATE case_insensitive;
```

Re-running `generate` reports no changes, so the diff is stable — the collation
becomes part of the type string in the snapshot and stays consistent.

This is the whole mechanism. No hand-edited migrations, no post-processing of
generated SQL, no CI enforcement. The declaration is where the column is, visible
in review, and opt-in per column.

### Do NOT blanket-apply it

Some columns must compare byte-for-byte, and making them case-insensitive is a
security defect rather than a convenience:

- password digests and hashes
- TOTP secrets, API keys, session and reset tokens
- opaque ids (UUIDs, external system ids)
- optimistic-concurrency tokens

These use plain `varchar` / `text`. A comment saying *why* is worth the line —
silence is indistinguishable from having forgotten.

A tempting shortcut circulating in issue #638 wraps `pgTable` and rewrites
`getSQLType()` for every text column in the table. Don't: it sweeps the columns
above into case-insensitivity invisibly.

---

## 4. Post-process after `drizzle-kit pull` — same as `bytea`

**`drizzle-kit pull` does not emit collation.** Introspecting a database whose
columns are case-insensitive produces plain `varchar` / `text` declarations, so a
re-introspection silently discards the collation from the schema files.

This is the same class of chore as `bytea`, which introspection also emits as a
`customType` reference that must be wired to a real helper. Treat them together:

**After every `pull`, before committing the schema:**

1. Query the database for which columns actually carry the collation:

   ```sql
   select r.relname as table_name, a.attname as column_name,
          format_type(a.atttypid, a.atttypmod) as type,
          coalesce(c.collname, '(db default)') as collation
   from pg_attribute a
   join pg_class r on r.oid = a.attrelid and r.relkind = 'r'
   join pg_namespace n on n.oid = r.relnamespace and n.nspname = 'public'
   left join pg_collation c on c.oid = a.attcollation
   where a.attnum > 0 and not a.attisdropped
     and a.atttypid in ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
   order by 1, 2;
   ```

2. Rewrite every column the query reports as collated to `ciVarchar` / `ciText`.
   Drive this off the query, not off judgement — on a converted database this is
   hundreds of columns across dozens of files, and hand-editing guarantees
   mistakes.

3. Confirm `drizzle-kit generate` reports **no schema changes**. If it wants to
   alter columns, the schema and the database disagree — resolve that before
   committing rather than letting the migration run.

Same discipline as the `bytea` helper: introspection gets you 95% of the way and
the last 5% is a fixed, documented pass.

---

## 5. Adopting the custom type on an existing database

Converting existing declarations to `ciVarchar` / `ciText` changes the type
string in Drizzle's snapshot from `varchar(50)` to
`varchar(50) COLLATE case_insensitive`, so `generate` emits an
`ALTER COLUMN … TYPE` for every converted column — even though the database
already matches. Running that rewrites tables and rebuilds indexes for no gain.

The reconciliation:

1. Convert the declarations, driven off the query in §4.
2. Run `generate`. It produces a large migration of no-op `ALTER`s.
3. **Empty the generated `.sql` body.** The database already matches, so nothing
   needs to run. Editing a generated `.sql` is allowed; hand-creating one, or
   touching `meta/_journal.json` or a snapshot, is not.
4. The snapshot now records the truth and the journal stays consistent.

This only works if the conversion is exactly right. A column declared collated
that is not collated in the database leaves the schema lying, and the next
migration that touches it will behave unexpectedly. Verify with §4 step 3.

---

## 6. Provisioning a new database (multi-tenant / on-the-fly)

A database created empty and then migrated has **no collation object at all**, so
`CREATE TABLE … COLLATE case_insensitive` fails outright with
`collation "case_insensitive" does not exist`.

That loud failure is the good case. The silent one is a schema that never
references the collation: every text column comes out case-sensitive, the
database provisions cleanly, and it behaves differently from every other database
running identical code — a user whose stored email differs in case can sign in on
one and not the other.

Two ways to close it:

**Create the collation first.** Run `CREATE COLLATION` as the first migration, or
as a provisioning step before migrations. With the §3 custom type, everything
after that is automatic. Simplest, and it works with any provisioning API.

**Clone from a template.** `CREATE DATABASE <new> TEMPLATE <template>` copies the
collation object and every column's collation, so databases are born correct.
Two caveats: `CREATE DATABASE` locks out connections to its template while
copying, so the template must be a dedicated migrated-but-empty database rather
than a live one — which then has to be kept current with migrations. And a hosted
provider's create-database API may not expose `TEMPLATE` at all; check before
designing around it.

Prefer the first unless there is a reason not to. It is one statement, it is
visible in the migration history, and it does not add a database to maintain.
