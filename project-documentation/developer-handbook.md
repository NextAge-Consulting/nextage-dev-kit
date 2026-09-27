# Developer

The guide for writing code in a kit-enabled project: the day, the few commands behind it,
and where to look when something goes wrong. `overview.md` shows where this fits; the
command details are in `gitflow-cheatsheet.md` and `devserver-cheatsheet.md`.

## Getting set up

Clone the project. Its `.claude/` folder is committed, so the kit's rules, skills and
commands come with it; nothing else gets installed. On a fresh Mac, `macbook-setup.md`
first; then hand `developer-onboarding.md` to Claude and it walks you through the rest.

## The day

**Start with `/work`.** On `main` it pulls the latest and stays there; on a branch it picks
up where you left off. `/work 42` links issue #42 to what you're doing, assigns it to you
and moves it to In Progress, and Claude reads the issue before proposing anything.
`/work` reads the last session's handoff, so you start where the previous session
stopped.

**Save as you go with `/checkpoint`.** It is a local save point: no checks, nothing pushed.
The next real commit folds checkpoints away, so they never reach `main`.

**Commit with `/commit`.** Claude writes the message. Before anything is staged, the type
check, lint and security scan run over what you changed, so problems surface in seconds
here instead of minutes later in CI. On `main`, `/commit` cuts a branch named from the
message. It asks which linked issues are finished, and moves those to Staged with a note
for whoever filed them.

**Review with `/open-pr`, then `/triage`.** `/open-pr` pushes, opens the PR with
`Closes #N` for your issues, and waits for CI and the AI reviewer. `/triage` walks the
reviewer's comments one at a time: fix it, skip it with a reason, or discuss it.

**Land it with `/merge`.** It builds the app, confirms CI is green, squash-merges and puts
you back on an up-to-date `main`. Merging does not deploy; `/deploy` is DevOps's step.

**Stay current with `/catchup`.** It brings `main` into your branch when others have
shipped, and fast-forwards `main` when you're on it.

**Small infra fix straight to `main`?** `/ship-main` commits and pushes directly: no
branch, no PR. You have to ask for it by name; a plain "commit" on `main` always branches.

## Running the app

Start dev servers yourself with `/dev` (`/dev shop`, `/dev shop dealer`). Claude never
starts one on its own. `devserver-cheatsheet.md` has ports, tunnels and troubleshooting.

## Tests

Write a test in the same change as the code it covers. Logic that lives in the code gets a
unit test; anything whose answer comes from the database gets an integration test. On
Postgres each run gets a throwaway copy of the real database; other engines define their
own. Run `npm test` from the repo root. `/e2e` drives
the app in a browser through plain-English flows; it is a check you run, not a gate.
Setup and the flow format: `testing.md`.

## UI work

Screens use the project's design system: tokens and rules in `design.md` at the repo
root, and the components listed in the UI inventory rule. Claude loads both when you touch
a component or a stylesheet. When a screen should be worked out visually first, that's
`designer-handbook.md`.

## Longer runs

- **`/autonomous <what>`** hands Claude a body of work while you step away. It runs to the
  end without check-ins, saves checkpoints as it goes, and reports what was done,
  verified and blocked.
- **`/handoff`** writes the session's state for the next one to pick up.
- **An analysis to share** gets published as a page people comment on;
  `/work --discussion <name>` turns the discussion into a plan. `analysis-and-discussions.md`
  has the detail.

## When something goes wrong

**A raw `git` command was blocked.** That's intended; use the matching command. If a
command itself was refused, the message names the operation; read it. A genuine
emergency override is `SKIP_GIT_GUARD=1 <command>`, and only with a reason.

**CI failed on the PR.** Fix it on the branch and `/commit` again; the PR updates itself.

**Claude keeps reaching for raw git.** Set `includeGitInstructions: false` in
`~/.claude/settings.json` (`developer-onboarding.md` §3). The guard still blocks it
either way.

**A cloud session doesn't see the project's hooks.** Cloud loads only what's committed:
check `.claude/settings.json` is in the repo.

**Research can't reach its deeper sources.** `EXA_API_KEY` isn't set in this shell, or in
the cloud environment's settings for a cloud session. Research still works without it.

**The kit changed.** Kit updates arrive as ordinary commits on `main`. Pull, and the next
session picks them up.
