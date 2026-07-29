---
paths: **/migrations/**/*, **/drizzle/**/*
---

# Drizzle Migrations

**Never hand-author Drizzle's migration bookkeeping.** A migration is three
coupled files that must stay in sync: the `.sql`, its
`meta/NNNN_snapshot.json`, and an entry in `meta/_journal.json`. Only
`drizzle-kit generate` writes all three atomically. Hand-creating a `.sql`, or
hand-editing the journal or a snapshot, desyncs the chain — the next
`db:generate` diffs against a missing or mismatched snapshot, which is painful
to unravel.

## The workflow

| Step | Command / action |
|------|------------------|
| Schema-derived migration | `db:generate` — drizzle diffs the schema and writes all three files |
| Data-only / custom SQL | `db:generate --custom` — scaffolds an empty `.sql` plus its bookkeeping |
| Write the SQL | Edit ONLY the generated `.sql` body — paste your SQL into the file drizzle made |
| Apply | `db:migrate` (NEVER `db:push`) |

## Forbidden

| Never | Why |
|-------|-----|
| Create a new `.sql` in a migrations dir by hand | Bypasses the snapshot + journal; desyncs the chain |
| Edit `meta/_journal.json` | Drizzle bookkeeping — corrupts migration ordering |
| Edit `meta/*_snapshot.json` | Drizzle bookkeeping — the next `db:generate` diffs wrong |
| `db:push` | Skips the migration files entirely; no audit trail |

## Enforcement

The `block-drizzle-handroll.sh` PreToolUse hook blocks Write of a new `.sql` in
a drizzle dir and any edit to the journal or snapshots. If you hit it, you are
hand-rolling — stop and run `db:generate --custom`, then Edit the `.sql` it
produces. Editing an existing generated `.sql` is allowed and correct.

Migration runs are human-gated in interactive sessions (approved runs are
prefixed `SKIP_DB_GUARD=1`); autonomous sessions run `db:generate` / `db:migrate`
under their standing authorization.
