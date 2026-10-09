# Neon branches for day-to-day development

For developers on a Postgres project hosted on Neon: how to get a database of your own to
work against, keep it current, and change its schema without stepping on anyone else.

## What a branch is

A Neon branch is a copy of a database made in a second, at a moment in time. It costs
nothing until you change something, because it shares storage with the branch it came
from (its **parent**) and stores only your differences.

Every branch has its own address. Two branches of the same project serve databases with
the same name from different hosts:

```
postgresql://app_user:…@ep-quiet-river-a1b2c3d4-pooler.<region>.aws.neon.tech/app_db?sslmode=require
postgresql://app_user:…@ep-bold-field-e5f6g7h8-pooler.<region>.aws.neon.tech/app_db?sslmode=require
                         └─ this part is the branch ─────────────────────────┘
```

So switching branches is switching the host in `DATABASE_URL`. The database name stays.

Each branch also has its own compute, which sleeps when nobody uses it and wakes on the
next connection, with a second or two of delay.

## Pick the parent

The mechanics below are the same either way. What differs is the branch everyone else's
branches are made from.

| Model | Parent | Use it when |
|---|---|---|
| **Branch from Production** | The production database's main branch | Developers may hold a copy of production data on their machines. Each dev branch starts as real data, and refreshing it pulls in today's. |
| **Branch from a shared dev database** | The main branch of a separate dev or test project | Production must stay unreachable from developer machines and the dev side holds a copy instead. Branches are made per developer, or per pull request or piece of work. |

In the second model the shared branch plays production's part for developers: nobody
works on it directly, and only the deploy changes it.

Whichever you use, `node scripts/db-branch.mjs` tells you where your `DATABASE_URL` points.
It reports the project's default branch — the parent — as `PRODUCTION` and any other
branch as `DEV`. Claude stops for approval before changing a `PRODUCTION` branch and
works freely on a `DEV` one.

## Make your own branch

In the Neon console, open the project, then **Branches → Create branch**:

- **Name:** your own, e.g. `alice`, or the work it is for, e.g. `pr-142`.
- **Auto-delete:** **Never** for a branch you keep; a date for one made for a single piece
  of work, so it cleans itself up.
- **Parent branch:** the parent from the table above, normally `main`.
- **Branch data and schema**, which is the default.

Keep a branch of your own rather than sharing one. Two people resetting and migrating the
same branch undo each other's work without either noticing.

## Point your `.env` at it

On your branch's page, **Connect**:

1. Check **Branch** is yours, then choose the **Database** and the **Role** the project uses.
2. Leave **Connection pooling** on.
3. **Show password**, then **Copy snippet**.
4. Paste it as `DATABASE_URL` in `.env`, replacing the previous value.

Then confirm it took: `node scripts/db-branch.mjs` should print `DEV` and your branch's name.

## Keep it current: reset from parent

**Reset from parent**, on your branch's page, makes your branch an exact copy of its
parent as it is now. Do it as often as you like:

- after a deploy, to pick up the schema changes everyone else's work brought,
- when your test data has got into a state you no longer want,
- before starting something new.

**It discards everything that exists only on your branch** — rows you added, and any
migration you applied there that has not been deployed yet. That is the point of it, and
it is why every schema change is a migration rather than SQL typed into a console: a
migration can be applied again after a reset, and a hand edit is simply gone.

## Change the schema

1. Change the schema files and generate the migration (`npm run db:generate`).
2. Apply it to **your** branch (`npm run db:migrate`). Claude asks before running it; on
   your own branch that approval is routine.
3. Build and test against your branch.
4. Commit, review and merge as usual.
5. **The deploy applies the migration to the parent.** Nobody runs it there by hand.
6. Reset your branch from parent. It now has the migration from the deploy, and you
   carry on.

If you reset in the middle of step 3, apply your migration again with `npm run db:migrate`.

## What you never do

- **Point a local session at the parent to work.** It is everyone's starting point; a
  stray write or a half-finished migration there lands on everyone's next reset, and in
  the first model it is production itself.
- **Fix data with SQL typed into the console.** The next reset erases it and the deploy
  never carries it. If the change matters, it is a migration.

## Automated tests

You do not need a branch for tests. Each `npm test` run (and each CI run) makes its own
throwaway branch from the parent, runs against it and deletes it, so tests never touch
your branch or anyone else's. `testing.md` has the details.

## Tidying up

Delete a branch when its work is merged and deployed. Each Neon plan includes a set number
of branches per project and bills compute per branch. Count the parent, every permanent
branch, and the throwaway branches test runs hold while they run — two CI runs at once are
two more — before giving every developer a permanent one.
