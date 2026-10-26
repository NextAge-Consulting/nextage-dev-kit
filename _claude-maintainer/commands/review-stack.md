# /review-stack

Maintainer-only. Answers one question: **what has changed in every package
`stack-manifest.json` pins since we pinned it, does it affect us, and if we take a
bump — what in our skills, templates and workflows has to change to match.**

**This is the only way the manifest changes.** Each version in it is a minimum:
a consumer project may run a newer exact version, which `scripts/check-stack.mjs`
notes and passes, but never an older one.

## When to invoke

When the user types `/review-stack` or asks what's new in the stack since we
pinned — never proactively, and never from a consumer session to work around a
failing CI job.

The usual cue is an issue the kit's scheduled `stack-watch` workflow filed —
`stack-review` monthly, `stack-advisory` when a published advisory affects a
pinned version (kitmaintainer-handbook.md §9.13). Read that issue first.

## What "our usage" means

Everywhere below, **our usage** is the following, all read on this machine:

- the bible's references, `_claude-project/skills/mfing-bible-of-tanstack/references/`;
- the kit's templates, scripts and workflows, `_claude-project/` and `_github-project/`;
- the consumer projects' code — every directory beside the kit holding a
  `.claude/.kit-sync.json`. **Read them; never write to one.**

**Verify against the source** means the published package — `npm pack <pkg>@<ver>`
into a scratch directory — read against that code. A changelog line is a lead,
not evidence.

## Step 1: Gather

```bash
~/.claude/scripts/review-stack.sh
```

Emits JSON: `versions` (every manifest package, pinned vs latest, plus every
release in between with its full notes, from the package's own repository),
`open_issues` touching what we use, `watch` entries, and the `references` list
with what each was distilled from.

- **Exit 0** — every lookup succeeded.
- **Exit 4** — the kit path or manifest is missing. Surface it and stop.
- **Exit 6** — a lookup failed, and the JSON is still printed: a failed package
  has `releases_since: null` and a `releases_note`, a failed search is listed in
  `open_issue_searches_failed`, and stderr names each. Tell the user which parts
  are missing, then continue the review with what was gathered. Never present a
  `null` as "nothing new".

Each package has a `status`:

- **`behind`** — read it in Step 2.
- **`current`** — nothing to read; it appears in the report's count only.
- **`unknown`** — npm could not be read. Name it as unreviewed in the report.

A `releases_note` on a package that did not fail means its release list is
partial — say so for that package.

The script decides nothing. Everything below is your reading of it.

## Step 2: Read the deltas, not the version numbers

For each `behind` package, read `releases_since`. A jump of forty patch versions
can be irrelevant, and a single minor can change how a loader behaves.

For each change, answer: **does it touch our usage?** A change to a feature we
do not use — RSC, offline persistence, infinite queries — affects us not at all,
and saying so is a complete answer.

Then: **is there something new we should use?** A built-in that replaces
something we do by hand, or an upstream recommendation our references
contradict, is a recommendation too — once verified against the source.

Weigh each entry in `open_issues` against our usage the same way. One that
reaches us goes into the recommendation, for the package it affects.

Do not summarise the changelog back. The output that matters is the subset that
reaches us.

## Step 3: Check the watch entries

Each `watch` entry names what we are waiting on and the `action` to take. Check
the state of every issue and PR it names (`gh issue view <url> --json state`,
`gh pr view <url> --json state`). An entry has **fired** when the condition its
own `action` states is met; a fired entry's action is a recommendation in Step 4.

Do what the action says, no more. The `start-middleware` entry's action already
says its issues closing is no reason to adopt middleware.

## Step 4: Recommend, do not bump

**A `stack-advisory` hit comes first**, and is recommended now whatever the
monthly cadence — unless the advisory does not reach our usage, which you show.
Once the user agrees it does not, record it in the manifest under that package's
`advisoriesReviewed`, keyed by its GHSA id, with the reason in one sentence, so the
watch stops filing it.

Then one recommendation covering every package: what changed, whether it
reaches us, what we should take up, and the blast radius — which consumers'
code the bump changes, measured by reading it. Raising a minimum moves every
project still below it at its next sync.

**The user answers it once.** Steps 5–7 run only for the bumps they accept, and
not at all when they accept none.

Then edit `_claude-project/stack-manifest.json`: each accepted version, that
package's `blessedAt` set to today, and the manifest's `blessed_at` set to
today — the day the bump was decided.

## Step 5: Update what the bump invalidates

For each accepted bump, use `references[].distilled_from` to find which of our
files were written against the changed upstream skills. Each entry reads
`<npm package>: <skill path>`, naming
`<npm package>/skills/<skill path>/SKILL.md` and, where listed, files under its
`references/`. Read them at the new version — in a consumer's
`node_modules/@tanstack/*/skills/`, or from `npm pack <pkg>@<ver>` — and update
our distillation where the change reaches us.

References whose `distilled_from` is empty have no upstream. They go stale only
against reality, so check them against the release notes and our usage.

Our references are **distilled, not copied**. Never replace one with upstream
text, and never add a section explaining a feature we do not use.

## Step 6: Write the migration

**A bump changes consumer code when any consumer must edit a source file, a
config or a schema to pass its checks at the new pins.** Then the review ships
one migration, named after it: `_claude-maintainer/migrations/stack-YYYY-MM/`.

- `PROMPT.md`, written to `.claude/rules/project/migrations.md`, Estimate included. `/sync-dev-kit` runs it
  in each consumer's session, so it is the only way a consumer learns what to
  change. Write it so a project finds its own cases: what to search for, what to
  change, how to prove it. The kit is public — never name a project, a client or
  a file from one.
- `gate-accepts.txt` listing the findings the pin moves cause in consumers, one
  literal fragment per line, so the kit's pre-ship replay reports them as
  resolved by this migration (kitmaintainer-handbook.md §9.11).

## Step 7: Propagate

Edit every file the bump touched in the kit source:

- `_claude-project/stack-manifest.json`
- `_claude-project/skills/mfing-bible-of-tanstack/**`
- every template, script or workflow under `_claude-project/` or `_github-project/`

Mirror each into the kit's own `.claude/` where the dogfood manifest in
`dev-kit-workflow.md` says it is dogfooded. The bible and the manifest are
template-only.

When you are working inside a consumer, edit that consumer's copy in the same
pass (`kit-maintainer.md`): `_claude-project/<path>` lands at `.claude/<path>`,
`_github-project/<path>` at `.github/<path>`. Never another consumer's working
tree — every other project receives the change, and runs the migration, on its
own next `/sync-dev-kit`.

Prove each mirrored or consumer copy with `diff`. A file carrying `{{KEY}}`
placeholders is compared after substitution — what `apply_substitutions` in
`sync-dev-kit.sh` writes — not byte for byte. With no consumer and no dogfood
copy in play there is nothing to diff.

Do not run `/sync-dev-kit` as the propagation step, and do not run git.

## Step 8: Report

Advisory hits first. Then versions current, behind and unknown, with the
recommendation and its blast radius; watch entries that fired; which references
were updated and why; the migration written; whether `blessed_at` moved.

When a `stack-review` or `stack-advisory` issue started the review, name it by
number. The commit that lands the review cites it (`kit-maintainer.md`).

**When nothing is behind, no lookup failed, no watch entry fired and no advisory
hit, the report is one line.** A review that finds nothing is a good outcome,
not a reason to manufacture work.
