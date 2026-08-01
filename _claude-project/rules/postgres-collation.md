---
paths: **/db/**/*.ts, **/schema/**/*.ts, **/schema.ts
---

# Postgres Collation: New Columns Do Not Inherit It

Applies only to projects whose database uses a non-default collation — usually a
converted legacy database, where case-insensitive comparison was the norm.
Full background, the verified mechanics, and the introspection chore: the
**POSTGRES-COLLATION** doc in the dev kit.

**You added or changed a `varchar` / `text` column. Should it be
case-insensitive? Surface the question — nothing in the schema does it for you.**

## Why it needs asking

- **A new column takes the DATABASE default, not its neighbours'.** A table whose
  every other text column is case-insensitive will happily take a case-sensitive
  one, with no warning. Queries succeed and quietly compare differently.
- **Drizzle cannot express column collation for PostgreSQL** — no option on any
  `pg-core` column builder (drizzle-orm issue #638, open since 2023).
- **PostgreSQL will not accept a nondeterministic collation as a database
  default**, so it cannot be solved once, database-wide.

## What to do

Find out whether this project uses one, and what it is called:

```sql
select coalesce(c.collname, '(db default)'), count(*)
from pg_attribute a
join pg_class r on r.oid = a.attrelid and r.relkind = 'r'
join pg_namespace n on n.oid = r.relnamespace and n.nspname = 'public'
left join pg_collation c on c.oid = a.attcollation
where a.attnum > 0 and not a.attisdropped
  and a.atttypid in ('text'::regtype, 'varchar'::regtype, 'bpchar'::regtype)
group by 1 order by 2 desc;
```

`(db default)` everywhere → nothing to do, stop here.

Otherwise the project should have a `customType` carrying the collation — the
`ciVarchar` / `ciText` pattern in the kit doc. Declare the column with it:

```ts
itemname:  ciVarchar({ length: 50 }).notNull(),   // case-insensitive
tokenhash: varchar({ length: 64 }),               // byte-for-byte, deliberate
```

`drizzle-kit` then emits the `COLLATE` clause itself, on `CREATE TABLE` and on
`ADD COLUMN`. No hand-edited migrations. If the project has no such custom type
yet, that is the thing to add — not a one-off `ALTER` in a migration file.

## Leave it case-sensitive when the value is compared byte-for-byte

Password digests and hashes, TOTP secrets, API keys, session and reset tokens,
opaque ids, optimistic-concurrency tokens. Case-insensitivity on these is a
security defect, not a convenience. Say so in a comment — silence is
indistinguishable from having forgotten.

## `ILIKE` throws on these columns

`nondeterministic collations are not supported for ILIKE`. Plain `LIKE` and `=`
are already case-insensitive, so use those. `ilike` type-checks, builds, passes
review, and fails the first time a user types in the search box.

## After `drizzle-kit pull`, post-process — same as `bytea`

Introspection does **not** emit collation: a re-pull silently replaces every
`ciVarchar` with plain `varchar` and the schema stops describing the database.
Treat it as a fixed post-pull pass alongside wiring up `bytea`. Procedure in the
kit doc.
