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
   nothing new since the last release — or if the full test suite fails. It runs the suite
   only when `main`'s exact code has no recorded pass.
2. Works out the version bump from the commit subjects (a breaking change is major, a
   feature is minor, anything else is a patch) and writes the changelog entry.
3. Commits the bump, tags it, and pushes both.
4. Runs the database migration, if the project has one. It can be set to skip when no
   migration file changed. A failed migration stops everything before any app ships.
5. Starts every service's deploy (all at once on CodeBuild) and reports each one's result.

Every failure exits with a code that says what went wrong and what to do.
(`pipeline.md` §2.8)

## Promoting a release to Prod

A project with a separate Prod splits the release in two. `/deploy` releases to Test, as
often as you like. `/deploy promote <version>` puts one of those releases onto Prod:
the same image, never rebuilt, so what reaches clients is exactly what was tested.

Promotion takes Prod down briefly: the running version stops, the migrations run, and
the new version starts. A failed migration brings the previous version back. Nothing
counts as promoted until Prod itself reports the new version, and then a GitHub Release
records that it shipped and when. Promoting an older version is a rollback, but its
database changes are not undone: the older version then runs on the newer schema. Roll
back across a release that changed the schema only after checking the old code survives it.

It runs with its own key, separate from the deploy key every developer holds. Whoever
holds the promote key is who may promote. (`pipeline.md` §2.9)

## Setting a project up

Hand `new-project-setup.md` to Claude: "walk me through new project setup". It works the
checklist and stops for the steps only you can do, such as cloud access, billing, and
secrets. The parts that are yours:

- **The deploy pipeline.** Build specs, CodeBuild projects, the image registry and its
  cleanup policy. The kit ships no build spec, because every target differs; it ships the
  pattern. (`pipeline.md` §2.7)
- **The servers.** `infrastructure.md` is how the box under an app is normally built: a
  load balancer in front, nginx and containers behind it, health checks, logs, and what
  gets forgotten on the second box. `infrastructure-terraform.md` is how every piece of it
  is owned as Terraform, so Test and Prod come from one reviewed definition and a change
  shows its blast radius before it runs.
- **The org repo.** Every organization has one per AWS account: all of its Terraform, the
  org map of who owns what and what crosses between projects, and the infrastructure docs —
  the org overview linking down to each project's. Projects hold no Terraform; they ask for
  infrastructure with an issue on it. A new organization gets one before any project builds
  in it (`infrastructure-terraform.md`, commands in `org-repo-cheatsheet.md`).
- **Backups.** `db-backup-pattern.md` gives a daily offsite copy of the database with a
  monitor that alarms when a backup doesn't arrive.
- **The review bot and the board.** `gemini-code-review-setup.md` and
  `github-project-board-setup.md`.

## The test gates

Every project with a database gets integration tests by default, enforced at three points:
`/commit` checks that each changed database function has a test and runs the ones the change
reaches, CI runs the whole suite — once per version of the code, so a comment-only push
reuses the last pass — and fails if the integration tests didn't run, and `/deploy` runs
the whole suite before it bumps anything, unless `main`'s exact code already passed it. Turning a gate off is your call as
the project owner. Write the reason as the value of `INTEGRATION_COMMIT_OFF`,
`INTEGRATION_CI_OFF` or `INTEGRATION_DEPLOY_OFF` in `.claude/sync-substitutions.json`;
the gate prints it when it stands down. The usual reason is reach: CI or the deploy machine
can't get to the test database. Set all three and the project needs no integration tests. On Postgres, CI needs the `NEON_API_KEY` and
`NEON_PROJECT_ID` secrets. (`testing.md` §3)

The check asks nothing of code nobody touches. A developer editing an old database function
writes its test then, so the untested count CI prints falls as the code is worked on.

**Where the whole suite runs is your setting too.** `TEST_RUNNER` is `github` by default:
CI runs it on GitHub Actions. Set it to `aws` and it runs in a CodeBuild project in the
project's own account instead — fewer GitHub minutes, and the one way to reach a database
on a private network. You provision that project, its role and its PR webhook as
Terraform, and give it the database credentials CI held (`infrastructure.md`, "The full
suite in CodeBuild"). `/deploy` then reads its results, and starts a run there when `main`'s
code has none.

**`ASSURANCE_LEVEL` `strict` is for a project that has to show evidence of its controls.**
Under it `/ship-main` takes docs only, `/deploy` ships only code with a recorded full-suite
pass, and `/open-pr` refuses an app with no current happy path. You also turn on a GitHub
ruleset requiring the `full-suite` check (`new-project-setup.md` step 3a). The default,
`assist`, warns where strict refuses. (`pipeline.md` §1.6)

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
