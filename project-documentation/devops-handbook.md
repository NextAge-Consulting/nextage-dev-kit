# DevOps

The guide for whoever owns the pipeline, the servers and the release in a kit-enabled
project. `overview.md` shows where this fits. The detail is in `pipeline.md`, which is
written to be handed to Claude when something needs setting up or has broken.

## What you own

Everything after a PR merges: the release, the deploy, the database migration, the
servers the app runs on, the backups, and the CI and review tooling that gates every PR.

## The shape, and why

**No branch protection.** `/merge` reads a PR's CI results itself and refuses to land a
red one, so the gate works the same on every repo with nothing configured. The one
requirement on GitHub: `main` must not require a PR, because `/deploy` and `/ship-main`
push to it directly. That is the default on a new repo. (`pipeline.md` §1.1)

**Merging is not releasing.** Merges pile up on `main`, and nothing fires. `/deploy` is the
single, deliberate release step. (§1.3)

**Deploys start only when `/deploy` starts them.** No push, tag, merge or schedule starts a
deploy. That is what keeps the version in the code and the version running in production
identical. (§2.5)

**Everything that touches AWS runs on AWS.** Deploys run as AWS CodeBuild projects that
`/deploy` starts, so no GitHub workflow holds an AWS credential. Projects not on AWS can
dispatch GitHub Actions instead, or record that they deploy by their own procedure.
(§2.1, "Dispatch backend")

## A release

Run `/deploy` on an up-to-date `main`. In one pass it:

1. Refuses to start if `main` is dirty, out of step with GitHub, failing CI, or has
   nothing new since the last release.
2. Works out the version bump from the commit subjects (a breaking change is major, a
   feature is minor, anything else is a patch) and writes the changelog entry.
3. Commits the bump, tags it, and pushes both.
4. Runs the database migration, if the project has one. It can be set to skip when no
   migration file changed. A failed migration stops everything before any app ships.
5. Starts every service's deploy (all at once on CodeBuild) and reports each one's result.

Every failure exits with a code that says what went wrong and what to do.
(`pipeline.md` §2.8)

## Setting a project up

Hand `new-project-setup.md` to Claude: "walk me through new project setup". It works the
checklist and stops for the steps only you can do, such as cloud access, billing, and
secrets. The parts that are yours:

- **The deploy pipeline.** Build specs, CodeBuild projects, the image registry and its
  cleanup policy. The kit ships no build spec, because every target differs; it ships the
  pattern. (`pipeline.md` §2.7)
- **The servers.** `infrastructure.md` is how the box under an app is normally built: a
  load balancer in front, nginx and containers behind it, health checks, logs, and what
  gets forgotten on the second box.
- **Backups.** `db-backup-pattern.md` gives a daily offsite copy of the database with a
  monitor that alarms when a backup doesn't arrive.
- **The review bot and the board.** `gemini-code-review-setup.md` and
  `github-project-board-setup.md`.

## Keeping it healthy

- **Dependencies.** Dependabot opens grouped PRs monthly, and waits a few days before
  proposing a new version so a bad release gets pulled first. The `dependency-triage`
  skill runs the weekly pass, and the project's `dependency-policy.md` sets the
  timelines. In a monorepo, a CI gate keeps every app on the same version of each
  shared dependency. (`pipeline.md` §3.3–§3.6, `dependency-management.md`)
- **CI.** Every PR gets a PR-title check, type check, lint, security scan and tests.
  (§3.1–§3.2, `testing.md`)
- **Notification noise.** Which GitHub emails the pipeline triggers, and how to silence
  them. (§3.8)

## When a deploy fails

Read the exit code; `pipeline.md` §2.8 maps each one to a cause and a fix. If a build
fails after the migration ran, the new schema is live under the old code. Read the build
log first: a transient failure, such as a registry rate limit, is fixed by re-running the
same builds, with no new version and no second migration.
