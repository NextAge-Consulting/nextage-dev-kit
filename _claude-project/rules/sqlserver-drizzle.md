# SQL Server + Drizzle

**Gate — read this first.** This file applies only when the project declares SQL
Server:

```bash
jq -r '.DB_ENGINE // ""' .claude/sync-substitutions.json
```

`SQLServer` → this rule applies. `PostgreSQL` → read `postgres-drizzle.md`
instead. `Other` or `None` → stop here. Empty → the engine has not been
declared, which is not the same as not having one; ask, and get the key
populated.

**Nothing in `postgres-drizzle.md` or the `postgres-neon-drizzle` skill transfers.**
No `ILIKE`, no nondeterministic collations, no `ciVarchar`/`ciText`, no Neon
branching. Engine-agnostic naming (singular tables, `{table}id`, UUID v7) still
comes from the constitution §V, and the Drizzle rules every engine shares — queries
through the schema, migrations, a partly-owned schema — from `drizzle.md`.

## I. The dialect is on the 1.0 release-candidate channel — pin it exactly

Drizzle's MSSQL dialect does **not** exist on the stable line. It ships only on
the 1.0 pre-release channel:

```bash
npm i drizzle-orm@<exact 1.0 rc version> mssql
npm i -D drizzle-kit@<same exact version>
```

- **Import from `drizzle-orm/node-mssql`**; table builders from
  `drizzle-orm/mssql-core`. The driver is `mssql`.
- **Pin the exact version. Never the `@rc` tag** — the tag moves, and a pre-release
  moving under a project is how a green build becomes a broken one with no commit
  to blame.
- Adopting this puts the project on a different Drizzle major from every project
  on the stable line. That is a real cost, and it is unavoidable: there is no
  "Drizzle, but stable" option for this engine.

Treat every RC upgrade as a change that needs the §III register re-verified.

## II. The connection string has exactly one working form

The `mssql` driver rejects both URL schemes. Only the ADO-style keyword string
connects:

```
mssql://user:pass@host:1433/db          ✗  "config.server property is required"
sqlserver://host:1433;database=…        ✗  "config.server property is required"
Server=host,1433;Database=…;User Id=…   ✓
```

So `dbCredentials.url` takes keyword form, assembled from discrete env values, **every
value in braces with `}` doubled** — a password holding `;`, `=` or a brace otherwise
splits the string and the login is refused:

```ts
const braced = (v: string) => `{${v.replaceAll('}', '}}')}}`;
const url = `Server=${braced(`${process.env.DB_SERVER},${process.env.DB_PORT ?? 1433}`)};`
  + `Database=${braced(process.env.DB_DATABASE)};User Id=${braced(process.env.DB_USER)};`
  + `Password=${braced(process.env.DB_PASSWORD)};Encrypt=true;TrustServerCertificate=true`;
```

A project here typically carries discrete `DB_*` keys rather than the single
`DATABASE_URL` the Postgres projects use. Kit tooling that assumes one URL needs
checking against that.

**Register `sql.map.register(String, sql.VarChar)` in the module every database handle
is built from, before any query runs.** Drizzle binds parameters untyped, the driver
then sends a string as `nvarchar`, and an `nvarchar` value against a `varchar` column
forces a conversion of the column on every row — an index seek becomes a scan.

**Give a genuinely `nvarchar` column a custom type that sends its value as UTF-16
bytes.** Under the `varchar` mapping, text outside the database's code page arrives as
`?`. Bound as `varbinary` and cast on the server, it arrives whole:

```ts
const unicode = customType<{ data: string; driverData: SQL; config: { length: number } }>({
  dataType: (c) => `nvarchar(${c?.length ?? 'max'})`,
  toDriver: (v) => sql`CAST(${Buffer.from(v, 'utf16le')} AS nvarchar(max))`,
});
```

A `where` comparing such a column to text casts the value the same way.

**Run independent queries in parallel on a pool, in sequence on a transaction.** A
transaction is one connection and takes one request at a time, so `Promise.all` on a
`tx` fails with "another request in progress" — and every data function is handed a
transaction under test. Route such calls through one helper that checks which it was
given. `Db` is the type both a pool handle and a transaction satisfy, and the type every
data function takes:

```ts
import { is } from 'drizzle-orm';
import { type MsSqlDatabase, MsSqlTransaction } from 'drizzle-orm/mssql-core';
import type { NodeMsSqlPreparedQueryHKT, NodeMsSqlQueryResultHKT } from 'drizzle-orm/node-mssql';

export type Db = MsSqlDatabase<NodeMsSqlQueryResultHKT, NodeMsSqlPreparedQueryHKT, typeof schema>;

export async function together<T extends readonly unknown[]>(
  db: Db,
  tasks: { [K in keyof T]: () => Promise<T[K]> },
): Promise<T> {
  if (is(db, MsSqlTransaction)) {
    const out: unknown[] = []
    for (const task of tasks) out.push(await task())
    return out as unknown as T
  }
  return (await Promise.all(tasks.map((task) => task()))) as unknown as T
}
```

## III. The RC defect register — re-verify every one on every upgrade

These are current-as-of-adoption defects in Drizzle's MSSQL support, each with a
standing workaround. **A Drizzle upgrade is not complete until each row here has
been re-tested and the row updated or deleted.** A workaround left in place after
upstream fixes it is a permanent, invisible tax; a workaround silently dropped
because someone assumed a fix is a regression.

Record the register in the project's own documentation with the version it was
last verified against.

| Defect | Symptom | Standing workaround |
|---|---|---|
| **`pull --init` WRITES to the database** | Creates a `__drizzle_migrations` table in a `drizzle` schema on the target | Use plain `drizzle-kit pull`. It is read-only and produces the same schema file. **Never `--init`, never against production.** |
| **Duplicate index names across tables break introspection** | `Failed to map the introspected schema` — no detail, no object named, even with stderr isolated | SQL Server scopes index names per table, so the same name on two tables is legal; introspection flattens them and collides. Find duplicates with the query below, then exclude one table via `tablesFilter` and hand-write its schema. |
| **Check constraints emit a missing comma** | Generated `schema.ts` does not parse where a `check()` follows a `unique()` | One post-processing pass after every pull (below) |
| **No relational query API** | `db.query` is `undefined` — no `findMany({ with: … })` | Explicit `select().from().leftJoin()`. Transactions do work. |
| **No `.limit()` on the select chain** | `db.select(…).limit is not a function` on 1.0.0-rc.5 | **Page with `.orderBy(…).offset(n).fetch(m)`**, which is SQL Server's own `OFFSET n ROWS FETCH NEXT m ROWS ONLY` and is what this dialect exposes instead. Verified against a live SQL Server 2019 on 1.0.0-rc.5: two adjacent pages returned the requested row counts and no overlapping rows. **Both `.orderBy()` and `.offset()` are mandatory, `.offset(0)` included.** `.fetch()` alone emits a `FETCH NEXT` with no `OFFSET` clause, which the server rejects with *"Invalid usage of the option next in the FETCH statement"* — so taking a single row is `.orderBy(…).offset(0).fetch(1)`, never `.fetch(1)`. A `where` on a unique or primary-key column needs none of it: it matches at most one row by construction |
| **No `uniqueidentifier` column builder** | Not in `drizzle-orm/mssql-core`'s exports on 1.0.0-rc.5 — every other SQL Server scalar type is there, this one isn't | `customType<{ data: string; driverData: string }>({ dataType: () => 'uniqueidentifier', fromDriver: (v) => v.toLowerCase() })`. The driver reads a GUID back upper-case while `randomUUID()` writes lower-case, so without `fromDriver` the same id compares unequal in JavaScript after a round trip. Drop the custom type the day this ships natively, keeping the lower-casing. |

Find duplicate index names before the first introspection — it is the difference
between a five-minute fix and an afternoon:

```sql
SELECT i.name, COUNT(*) n
FROM sys.indexes i JOIN sys.tables t ON t.object_id = i.object_id
WHERE i.name IS NOT NULL
GROUP BY i.name HAVING COUNT(*) > 1;
```

The check-constraint fix, run after every `pull`:

```bash
perl -0pi -e 's/([^,\s])\n(check\()/$1,\n\t$2/g' schema.ts
```

Typecheck the generated file under `--strict` as part of the pull step. It is the
only thing that catches a new codegen defect on an upgrade.

## IV. Trailing-space padding is invisible to SQL (Zero Tolerance)

A `char` column, and a `varchar` written by a fixed-width client, stores values
padded to the column width. **SQL Server's `=` and `<>` ignore trailing spaces**,
so the obvious detection query cannot see it:

```sql
WHERE col <> RTRIM(col)          -- always zero rows, even on a fully padded column
WHERE DATALENGTH(col) > LEN(col) -- the only reliable test
```

Values reach the application padded, and it is the data, not the driver. Decide
once where trimming happens — a shared read helper or a custom column type — and
never at individual call sites, because the call site that forgets is the one that
ships a padded value into a comparison, a key, or a UI.

The same rule makes comparisons case-insensitive under the common
`SQL_Latin1_General_CP1_CI_AS` collation, so `drizzle.md` §IV applies to every
column under it.

## IV-b. Primary key id strategy — a per-project decision, not inherited

Postgres gets UUID v7 for free: its native `uuid` type compares bytewise, so v7
costs nothing over v4. SQL Server does not cooperate — `uniqueidentifier` sorts by
its **last six bytes**, not its bit pattern, so a v7's leading timestamp is ignored
and its time-ordering benefit is silently destroyed. Getting v7's real payoff
(insert-order index locality) means abandoning the native GUID type for a generic
`CHAR(36)`/`BINARY(16)` column, generating the id in the application, and losing
`uniqueidentifier`'s tooling integration along the way. That is a real cost, not a
formality, so **decide it per project** rather than inheriting the Postgres answer.

**Default: native `uniqueidentifier`, generated by the application with
`randomUUID()` and written on insert, with `DEFAULT NEWID()` on the column for rows
another writer inserts.** Standard type, standard tooling, no shoehorning, and the
application holds the new id without reading it back. Take the CHAR(36)/BINARY(16) route only when the project
has an actual coordination-free-generation or cross-instance-replication
requirement that the native type can't satisfy — record that requirement and the
choice in the project's own schema rules when it's made; don't default into it.

If a project does choose the v7 route, the trap and the fix, demonstrated on SQL
Server 2019 with three v7 values whose timestamps ascend:

```
ORDER BY <uniqueidentifier column>  ->  3, 2, 1     reverse chronological
ORDER BY <char(36) column>          ->  1, 2, 3     correct
```

`CHAR(36)` stays readable in ad-hoc queries; `BINARY(16)` is less than half the
width. Pick one and use it for every owned table in that project — never mix.
`NEWSEQUENTIALID()` is not an alternative: it's host-dependent and its ordering
does not survive a restart or a move, so it satisfies neither the native-type
default nor a real v7 need.

**Never rely on `ORDER BY` over a `uniqueidentifier` column to mean "oldest first"**,
whatever generated the value. If a query needs chronology, order by a timestamp
column.

## IV-c. Reading back a key the server assigns

**On an `IDENTITY` table, read the new key with `.output({ id: table.id })` on the
insert.** Never `SCOPE_IDENTITY()` in a separate statement: each Drizzle statement runs
in its own scope, so it returns `NULL`.

**A table with an enabled trigger refuses `OUTPUT` without `INTO`** (error 334). Read
its key in one batch through `db.execute`, with a `raw-sql:` reason. A column object
renders table-qualified, which the column list and `inserted.` reject, so name each
column through `sql.identifier(column.name)` — still the schema's, so a rename follows:

```ts
const col = (c: { name: string }) => sql.identifier(c.name);
// raw-sql: the table has an enabled trigger, which refuses OUTPUT without INTO.
const result = await db.execute<{ id: number }>(sql`
  DECLARE @ids TABLE (id int);
  INSERT INTO ${legacyOrder} (${col(legacyOrder.name)}) OUTPUT inserted.${col(legacyOrder.id)} INTO @ids VALUES (${name});
  SELECT id FROM @ids`);
```

## V. The integration tests' database

**Integration tests run against the project's development database, every test inside
a snapshot transaction the kit's harness always rolls back** — `test/integration-helpers.ts`'s
`dbTest`, synced from the kit (testing.md §1). SQL Server has no per-run copy, so
isolation is the transaction alone: identity values are not rolled back, and the
database's data drifts between refreshes.

**A test inserts its own rows, keyed so no real row can collide, and never relies on
existing ones:**

- a `uniqueidentifier` key: a fresh `randomUUID()`;
- an `IDENTITY` key: the server assigns it and the test reads it back (§IV-c). Never
  `IDENTITY_INSERT`: it needs `ALTER` permission on the table and holds for one table
  per session;
- any other numeric key: a negative value;
- a character key: a prefix that sorts below every real value under the column's
  collation, so a trigger reading `MAX(key)` never picks a test row. Check the prefix
  with `SELECT v FROM (VALUES ('<prefix>1'), ('<lowest real value>')) AS x(v) ORDER BY v
  COLLATE <the column's collation>` and record it per table in `rules/project/`. Under
  `SQL_Latin1_General_CP1_CI_AS`, `!` sorts below digits and letters.

**A function under test that opens `db.transaction()` on the test's handle gets a
savepoint** (`save transaction`) inside the test's transaction. Its own rollback undoes
only the savepoint's work and rethrows `TransactionRollbackError` to its caller; the
test's transaction carries on, and is rolled back whole at the end.

**Set up the development database once, and record how in the doc
`test/project.ts`'s `integrationDatabase.setupDoc` names:**

- **Mark the server as a test target**, and only a server whose data nobody needs:
  `EXEC sys.sp_addextendedproperty @name = N'integration_test_target', @value = N'…'`
  in its `master` database. The harness refuses an unmarked server; production never
  carries the mark, and a restore leaves `master` alone, so it survives every refresh.
- **Allow snapshot isolation:** `ALTER DATABASE [<db>] SET ALLOW_SNAPSHOT_ISOLATION ON`.
  It changes no other session — never set `READ_COMMITTED_SNAPSHOT` for the tests. A
  restore brings back the source database's setting, so the restore sets it again.

**Declare `integrationDatabase` in `test/project.ts`** — the setup doc, and each
migration folder with the command that applies it. The harness refuses a database
missing a migration the branch adds and prints that command; applying it is the
human's call (`drizzle.md` §II).

**Declare `"test:preflight": "vitest run -c <shared module>/vitest.config.ts --project
integration <shared module>/test/harness.integration.test.ts"` in the root
`package.json`.** `/commit`, `/ship-main` and `/deploy` run it before anything else
(testing.md §3), so a database that is unmarked, offline, refusing snapshot isolation
or missing a migration is caught while the developer is there.
