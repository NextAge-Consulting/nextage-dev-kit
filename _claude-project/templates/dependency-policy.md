# Dependency & Vulnerability Policy

> **The kit owns every line outside the `project:begin` / `project:end` markers;
> this project owns everything between them.** The timelines table is the dial:
> tune it to this client's risk appetite. Nothing else needs to change when you do.

The doctrine behind this pass — one version per shared dependency, one shared build
config, the verification standard, how a security residual is accepted — lives in the
kit's `project-documentation/dependency-management.md`. Read it there; it is
deliberately not copied into consumer projects, so there is one copy to keep true.
This file holds only what that document cannot know about a given project: its
owners, its timelines, its exceptions, and the project-specific facts a maintainer
adds under "Project notes".

## How updates happen here

**No bot opens dependency PRs.** Every update is made by the dependency pass, on a
branch, through the same `/commit`, `/open-pr` and `/merge` as any other change — so
it gets the full test suite, the build gate and review like everything else.

Three things tell you something needs updating:

- **The dependency pass** — ask Claude for a **"dependency triage"**. It lists what is
  vulnerable (`npm audit`), what is behind (`npm outdated`), and whether Node's LTS has
  moved, and recommends a decision for each.
- **`/deploy`** — before every release it names any high or critical vulnerability
  that has a fix and is older than its window below. How hard it insists depends on
  `ASSURANCE_LEVEL`: it warns under `assist` and refuses under `strict` until the
  update lands or an exception below covers it.
- **GitHub's vulnerability alerts**, if this project turns them on (below) — an email
  the day a vulnerability is published, and a list under the repository's Security tab.
  Alerts open no PRs; leave *Dependabot security updates* off, since those PRs skip
  the cooldown below.

**The cooldown.** A version is taken only once it has been published for 3 days (a
patch), 7 days (a minor) or 30 days (a major). A compromised release is usually
caught and pulled inside that window; taking it the day it ships is how a
supply-chain attack reaches production.

## Who owns this

<!-- project:begin owners -->
| | |
|---|---|
| Runs the weekly pass | *(name)* |
| Approves an exception | *(name)* |
| Escalate to | *(name)* |
<!-- project:end owners -->

## Vulnerability alerts

A small team running the weekly pass and relying on `/deploy`'s check needs nothing
more. A project that must show continuous monitoring — an ISO 27001 audit, a client's
security review — turns them on: an admin, under the repository's **Settings → Code
security**, enables **Dependabot alerts** and leaves **Dependabot security updates**
off.

<!-- project:begin alerts -->
Alerts: **off**
<!-- project:end alerts -->

## Timelines

How long a known issue may remain unresolved, from the day it appears. `/deploy`
reads the Critical and High rows.

<!-- project:begin timelines -->
| Severity | Act within | If it can't be met |
|---|---|---|
| Critical | 7 days | Escalate immediately — do not let it lapse silently |
| High | 14 days | Record an exception |
| Medium | 30 days | Record an exception |
| Low | Next routine pass | — |
| No fix published | Record within 7 days | Review every 90 days until fixed |
<!-- project:end timelines -->

## Exceptions

An issue that can't be resolved inside its window is written down here, not
forgotten: what it is, why it can't be fixed now, who approved it, and **the date it
gets looked at again**. An exception with no review date is not an exception, and
one past its date no longer covers anything — `/deploy` reads this table.

<!-- project:begin exceptions -->
| Advisory | Package | Why it can't be fixed now | Approved by | Review by |
|---|---|---|---|---|
<!-- project:end exceptions -->

## The weekly pass

Run it weekly, on a fixed day. It takes minutes when there's nothing to do.

**1. Routine updates** — leaf libraries, dev dependencies, patch bumps. The full suite
on the PR is sufficient.

**2. Build-graph updates** — the packages below, and anything else in the bundler,
framework, router, server adapter or database driver. CI does not build the app, so
these are built and run in the real deploy image, with a real sign-in, before the PR
opens. Expect them to occasionally cost hours. If one turns into a fight, stop and
escalate rather than forcing it through — a half-migrated build graph is worse than a
stale one.

The kit's list: `vite`, `@vitejs/*`, `vite-tsconfig-paths`, `esbuild`, `rollup`,
`postcss`, `react`, `react-dom`, `@types/react`, `@types/react-dom`, `@tanstack/*`,
`hono`, `@hono/*`, `drizzle-orm`, `drizzle-kit`, and the database driver (`pg`,
`mssql`). This project adds:

<!-- project:begin build-graph -->
<!-- project:end build-graph -->

**3. Security fixes** — read what changed before taking one. A fix is a new release
like any other, and gets the same cooldown.

**4. Nothing to fix** — an advisory with no patched version, or one only the package
that pulls it in can fix. Bump that parent when it has a release that does; otherwise
record an exception with a review date and move on.

**5. Node LTS** — whether Node's Active LTS has moved past what this project runs.
The Node major is the kit's: it moves every project at once, with a migration.

Under `ASSURANCE_LEVEL` `strict`, each pass is recorded under "Pass log" below: the
date, what was found, what was decided, and who decided it.

## When to stop and escalate

- A critical issue can't be resolved inside its window.
- A build-graph update breaks the app and the fix isn't obvious within an hour.
- An advisory affects something handling customer data and you can't tell whether
  it's exploitable here.
- You don't understand what a change does. That is a legitimate reason to stop —
  taking it anyway is the failure this document exists to prevent.

## Pass log

<!-- project:begin pass-log -->
| Date | Found | Decided | By |
|---|---|---|---|
<!-- project:end pass-log -->

## Project notes

<!-- project:begin project-notes -->
<!-- project:end project-notes -->
