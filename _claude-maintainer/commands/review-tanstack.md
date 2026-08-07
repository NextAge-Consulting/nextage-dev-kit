# /review-tanstack

Maintainer-only. Answers one question: **what has changed in TanStack since we
pinned, does it affect us, and if we take a bump — what in our skill has to
change to match.**

**This is the only way the TanStack manifest changes.** A consumer project never
bumps a version to make its build pass; `scripts/check-tanstack.mjs` failing
there is the system working.

## When to invoke

The user types `/review-tanstack`, or asks what's new in TanStack since we
pinned. Run it when there is time to act on the answer — it produces judgment
calls, not a notification. **Never proactively**, and never from a consumer
session to work around a failing CI job.

## Step 1: Gather

```bash
~/.claude/scripts/review-tanstack.sh
```

Emits JSON: `versions` (pinned vs latest, plus release notes for everything in
between), `open_issues` touching what we use, `watch` entries, and the
`references` list with what each was distilled from. Exit 4 means the kit path or
manifest is missing — surface it and stop.

The script decides nothing. Everything below is your reading of it.

## Step 2: Read the deltas, not the version numbers

For each package marked `behind`, read `releases_since`. A jump of forty patch
versions can be irrelevant, and a single minor can change how a loader behaves.

For each change, answer only this: **does it touch how we use TanStack?** Our
usage is narrow and the references say what it is — route loaders with
`loaderDeps`, `ensureQueryData` + `useSuspenseQuery`, server functions with
handler-level auth, server-paged Table v9, TanStack Form. A change to RSC,
offline persistence, infinite queries or migration tooling affects us not at all,
and saying so is a complete answer.

Do not summarise the changelog back. The output that matters is the subset that
reaches us.

## Step 3: Check the watch entries

`watch` records things we are deliberately waiting on, each with the action to
take. Two live ones:

- **`@tanstack/query-intent`** — when it publishes, Query finally has an upstream
  and `queries-and-mutations.md` should be re-distilled against it rather than
  written from scratch. That is the single largest maintenance win available.
- **`start-middleware`** — if #7213 and #7459 both close, the *technical*
  objection is gone. That is not a reason to adopt it. Middleware's only real
  capability over a call at the top of a handler is running code after the
  handler; unless something genuinely needs wrapping, the answer stays no. Do not
  reopen this on the strength of upstream docs using `authMiddleware` in
  examples — that has already misled once.

## Step 4: Recommend, do not bump

Present per package: what changed, whether it reaches us, and the recommendation.

**Remember what a bump costs.** Lockstep is absolute, so every project upgrades
together — it is an N-project event, and the projects most affected may not be
the one the user is sitting in.

Wait for the decision. Only then edit `_claude-project/tanstack-manifest.json`,
and move `blessed_at` in the same edit — a pin without a date reads as accidental
six weeks later.

## Step 5: Update what the bump invalidates

This is the step that makes the review worth running.

For each accepted bump, use `references[].distilled_from` to find which of our
files were written against the changed upstream skills, re-read those skills at
the new version, and update our distillation where the change reaches us.

References with an empty `distilled_from` — Query, Form, loading states,
debugging, dependency management — have no upstream. They go stale only against
reality, so check them against the release notes and our own code instead.

Our references are **distilled, not copied**. Never replace one with upstream
text, and never add a section explaining a feature we do not use.

## Step 6: Propagate

Any change touches the kit source AND every consumer in ONE pass, per
`kit-maintainer.md`:

- `_claude-project/tanstack-manifest.json`
- `_claude-project/skills/mfing-bible-of-tanstack/**`
- each consumer's `.claude/` copies

The bible is **template-only** — the kit does not dogfood it — so do not mirror
into the kit's own `.claude/`. `diff` to prove byte-identity. Do not run
`/sync-dev-kit` as the propagation step, and do not commit.

## Step 7: Report

Versions current vs behind, with the recommendation and its blast radius. Watch
entries that fired. Which references were updated and why. Whether `blessed_at`
moved.

If nothing needs doing, say so in one line. A review that finds nothing is a good
outcome, not a reason to manufacture work.
