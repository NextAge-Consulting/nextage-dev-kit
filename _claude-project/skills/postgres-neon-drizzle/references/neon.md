# Neon: Branching and Provisioning

Neon's branches are copy-on-write forks of a database at a point in time. Cheap,
fast, and the reason dev and tests can run against real data instead of fixtures.

## Dev is a branch of production

A dev database is a branch of prod, not a hand-seeded copy. That is what makes it
real enough to trust: the same rows, the same distributions, the same
awkward legacy values.

Two consequences that catch people:

**A reset from parent wipes everything created on the branch.** Refreshing dev
from prod discards any object, row or grant that exists only on dev.

**So infrastructure lands on production first, always.** Seed prod once and let
the reset carry it down. Doing it the other way — building on dev, then
refreshing — destroys the work while prod stays un-seeded. This applies to
anything structural: a collation object, an extension, a role grant, a
bookkeeping row.

## Tests fork their own branch

DB-backed tests provision **one ephemeral branch per run**, migrate it, point the
connection string at it before any worker spawns, and delete it in teardown, with
a short `expires_at` as the crash backstop. Each test runs inside a rolled-back
transaction, so parallel tests are MVCC-isolated and production is never written.
Costs about a cent a run.

Because the branch forks production, these tests see **real** data — which makes
them the only place a whole class of defect is reachable at all: a lookup table
drifting from what the field actually reports, a catalog missing a row a live
device depends on. A fixture-based unit test can only ever prove the fixture is
self-consistent.

The discipline around *confirming the suite actually ran* — it drops silently when
the Neon credentials are absent, and the run still exits green — is in the
`testing-verification` rule. Read it before reporting a pass.

## Provisioning a new database

A database created empty and then migrated is **not** equivalent to a branch of
an existing one. Anything that lives at the database level rather than in the
migrations is simply absent.

The one that bites hardest is a nondeterministic collation. `CREATE TABLE …
COLLATE case_insensitive` fails outright with `collation "case_insensitive" does
not exist` — a loud failure, and the good case. The silent one is a schema that
never references the collation: every text column comes out case-sensitive, the
database provisions cleanly, and it behaves differently from every sibling while
running identical code. A user whose stored email differs in case signs in on one
and not the other.

**Create the collation as the first migration, or as a provisioning step before
migrations run.** One statement, visible in the migration history, works with any
provisioning API:

```sql
CREATE COLLATION IF NOT EXISTS case_insensitive (
  provider = icu, locale = 'und-u-ks-level2', deterministic = false
);
CREATE EXTENSION IF NOT EXISTS pg_trgm;
```

Cloning from a template (`CREATE DATABASE <new> TEMPLATE <template>`) also copies
the collation and every column's collation, so databases are born correct. Two
caveats: `CREATE DATABASE` locks out connections to its template while copying, so
the template must be a dedicated migrated-but-empty database that then has to be
kept current — and a hosted provider's create-database API may not expose
`TEMPLATE` at all. Prefer the first unless there is a reason not to.

## Ownership is set at creation, not fixed afterwards

Create the database with the **application's owning role** named explicitly
(`owner_name` in Neon's API). Ownership is a control-plane property that Neon
re-applies on every compute start, so a database created under the provider's
default role and then handed over with `ALTER DATABASE … OWNER TO` does not stay
handed over — the change is reverted underneath you, and migrations fail with
permission errors that look intermittent.

The app and its migrations connect as the same owning role. A separate
least-privilege application role is a legitimate choice, but it is a decision to
make deliberately, not a default to drift into: with migrations and runtime on
different roles, every new object needs its grants sorted out.
