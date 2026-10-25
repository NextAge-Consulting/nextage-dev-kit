# Developer

The guide for writing code in a kit-enabled project: the day, the few commands behind it,
and where to look when something goes wrong. `overview.md` shows where this fits; the
command details are in `gitflow-cheatsheet.md` and `devserver-cheatsheet.md`.

## Getting set up

Clone the project. Its `.claude/` folder is committed, so the kit's rules, skills and
commands come with it; nothing else gets installed. On a fresh Mac, `macbook-setup.md`
first; on Windows, `windows-handbook.md` first; then hand `developer-onboarding.md` to Claude and it walks you through the rest.

**The project's kit syncer** — one person per project — keeps it on the kit's releases with
`/sync-dev-kit`. If that is you, `kit-sync-cheatsheet.md` is your page.

## The day

**Start with `/work`.** On `main` it pulls the latest and stays there; on a branch it picks
up where you left off. `/work 42` links issue #42 to what you're doing, assigns it to you
and moves it to In Progress, and Claude reads the issue before proposing anything.
`/work` reads your last session's handoff and lists the issues assigned to you, so you start
where you stopped. "Where work is tracked" below says what goes where.

**Save as you go with `/checkpoint`.** It is a local save point: no checks, nothing pushed.
The next real commit folds checkpoints away, so they never reach `main`.

**Commit with `/commit`.** Claude writes the message. Before anything is staged, the type
check, lint and security scan run over what you changed, so problems surface in seconds
here instead of minutes later in CI. The AI reviews run together, and a re-run after a fix
reuses every review that already passed; a change to comments alone skips the type check
and the tests. On `main`, `/commit` cuts a branch named from the
message. It decides which linked issues are finished, asks you only about one it cannot
judge, and moves the finished ones to Staged with a note for whoever filed them.

**Review with `/open-pr`, then `/triage`.** `/open-pr` pushes, opens the PR with
`Closes #N` for your issues, and waits for CI and the AI reviewer. `/triage` walks the
reviewer's comments one at a time: fix it, skip it with a reason, or discuss it.

**Land it with `/merge`.** It refuses while you have uncommitted changes, builds the app
while it waits for CI to go green, squash-merges and puts
you back on an up-to-date `main`. Merging does not deploy; `/deploy` and `/deploy promote` are DevOps's steps.

**Stay current with `/catchup`.** It brings `main` into your branch when others have
shipped, and fast-forwards `main` when you're on it.

**Two sessions on one project?** Give the second one `/work --worktree`. It gets a folder
and branch of its own, so neither session's commit sweeps up the other's work, and `/merge`
removes it when the work lands. The gitflow cheatsheet has the details.

**Small infra fix straight to `main`?** `/ship-main` commits and pushes directly: no
branch, no PR. You have to ask for it by name; a plain "commit" on `main` always branches. On a project at `ASSURANCE_LEVEL` `strict` it takes docs only; code goes
through a PR.

## Where work is tracked

**Issues are the task list.** Anything with an owner — a feature, a fix, something for a
teammate — is a GitHub issue assigned to someone. Everyone can see it, and it closes when
it's done.

**Your handoff is your own messy middle.** `/handoff` writes
`project-documentation/temporary/handoff-<your-github-login>.md` at the end of a session,
and your next `/work` reads it back: what you were in the middle of, where you left it,
what's next, and what you're waiting on from someone else. It is yours alone — not a
baton to pass, and not a shared to-do list. Items you're waiting on stay listed but are
never nagged about, since no session of yours can move them.

**To reach a teammate at the start of their next session, tell Claude.** "Ask Sam to
look at the import brief" puts a signed, dated note under *From others* in Sam's
handoff, and their next `/work` raises it. It is quicker than an issue for a nudge, a
question or a pointer. Anything that is real work with an owner still wants an issue.
The note travels through git, so Sam sees it once it's committed and on their branch.
Claude never writes in someone else's handoff unless you ask.

## Running the app

Start dev servers yourself with `/dev` (`/dev shop`, `/dev shop dealer`). Claude never
starts one on its own. `devserver-cheatsheet.md` has ports, tunnels and troubleshooting.

## Your database

On Postgres with Neon, work against a database branch of your own, never the shared one
everyone branches from. Make it, point `.env` at it, reset it after a deploy, and change
its schema only through migrations: `neon-branches.md`.

## Tests

Write a test in the same change as the code it covers. Logic that lives in the code gets a
unit test; anything whose answer comes from the database gets an integration test. On
Postgres each run gets a throwaway copy of the real database; the engine rule says where
other engines run theirs. Run `npm test` from the repo root.

An integration test is one of three kinds, told apart by its file name. A happy-path test
(`*.happy.integration.test.ts`) proves the main success case of a core function. A risk
test (`*.integration.test.ts`) covers something a sensible later change could quietly
break: money, dates and time zones, permissions, data integrity, locking, another
system's contract, code many others depend on. A development test
(`*.dev.integration.test.ts`) is one you wrote to get the code right; it runs while that
code changes and stays out of the full suite, so the suite grows only with tests that keep
paying.

Which functions are core is yours to decide, with Claude, in `/happy-path <app>`: it ranks
the app's core, you correct the list, and it writes the missing happy-path tests and a
snapshot of the app beside them. `/open-pr` warns when an app you touched has no happy
path, or has changed too much since its snapshot to trust it, and names that command. On a
project at `ASSURANCE_LEVEL` `strict` it refuses the PR instead.

Database code of a risky shape — raw SQL, a join, a real filter, an aggregate, a date
range, an upsert, a transaction, more than one write — needs a happy-path or risk test
that calls it, and `/commit` checks: it names the function and the shapes, and stops. The
shape only means one test is kept: when nothing about the function is on the risk list, its
main success case, filed as a risk test, is enough, and its other cases are development
tests. A plain insert or a select by key needs none. A test has to import and call your code; one
that only talks to the database is refused. Old code you do not touch is left alone; touch
it and it needs its test too. A whole query written as raw SQL through `.execute()` needs
`// raw-sql: <what the builder can't do>` above it. `/commit` also runs the integration
tests your change reaches, development tests included, and sends any `sql` template you
wrote to a quick review for table or column names typed as text (`testing.md` §3).

`/e2e` drives the app in a browser through plain-English flows; it is a check you run, not
a gate. Setup and the flow format: `testing.md`.

## Adding your own build-output checks

A check on what the build produces — a secret scan of the browser bundle, no source maps
in production — goes in a `postbuild` script in the `package.json` of the app that builds
it:

```json
"scripts": {
  "build": "vite build",
  "postbuild": "gitleaks dir dist/client --no-banner"
}
```

npm runs `postbuild` after every `npm run build`, and a non-zero exit fails the build.
`/merge` and the deploy image's build stage both run `npm run build`, so this one hook
stops a merge and a deploy alike; it needs no CI step. The tool must exist in both places:
a scanner installed as a dev dependency arrives with `npm ci` in each, while a standalone
binary such as gitleaks has to be on every developer's machine and installed in the
Dockerfile's build stage too, or every deploy fails. Point it at the client output
(`dist/client` on TanStack Start), have it print how many files it checked so a scan that
read nothing never passes, and commit any allowlist it uses (for gitleaks,
`.gitleaksignore` at the repo root). `package.json` is the project's, so a kit sync never
touches it.

A check on your source, rather than on the build, belongs in `.claude/project-gate.sh`
instead, which runs at every commit (see "When something goes wrong").

## A Claude Code hook for the whole team

`.claude/settings.json` is the kit's, so a hook of the project's own goes in
`.claude/settings.project.json` instead, in the same shape:
`{"hooks": {"PreToolUse": [{"matcher": "…", "hooks": [{"type": "command", "command": "…"}]}]}}`.
Commit it with the script it runs. It takes effect for everyone once the project's kit
syncer next runs `/sync-dev-kit`, which writes it into `settings.json` beside the kit's
own hooks.

## UI work

Screens use the project's design system: tokens and rules in `design.md` at the repo
root, and the components listed in the UI inventory rule. Claude loads both when you touch
a component or a stylesheet. Every dialog, panel, header or toolbar is one of a short list
of block types, and each app builds one component per type the first time it needs it; a
screen's own content lives in the app's `src/features/<feature>/`, arranges those
components and styles its own text from the semantic roles — every box comes from a
component. When a screen should be worked out visually first, that's
`designer-handbook.md`. User theme settings (accent colour, colour-blind mode, text size)
are `custom-themes.md`.

Anything new Claude adds to the design system is marked pending until a human approves it,
and `/deploy` refuses while anything is pending — `designer-handbook.md`, "Nothing new ships
until you approve it".

When the system has no answer for a value, Claude takes the kit's design opinion
(`design-opinion.md` in the design-system skill) into the system, or asks you. Existing
screens that predate the system are never blocked — the checks judge only the lines you
change — and `/design-audit` brings an area into line when you have time for it:
`designer-handbook.md`, "Starting and growing a design system".

## Longer runs

- **`/autonomous <what>`** hands Claude a body of work while you step away. It runs to the
  end without check-ins, saves checkpoints as it goes, and reports what was done,
  verified and blocked.
- **`/handoff`** writes your session's state for your next one to pick up.
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

**`/commit` stopped on the rule review.** A change to a rule, skill, command or pattern
reference carries history, a justification, or a counted list. Have Claude fix the text
and commit again. If you judge a finding wrong, commit with `SKIP_RULE_REVIEW=1`.

**`/commit` stopped on the test judge.** It judged the tests of the TypeScript you
changed: risky code with no test (write it), a test running its own copy of the logic
(make it call the app), a test that proves nothing or repeats another (delete it), or a
test filed as the wrong kind (rename it). It searches the whole repository's tests before
calling one missing or a duplicate, and judges a change of any size. Have Claude
act on each and commit again. If you judge a finding wrong, commit with `SKIP_TEST_REVIEW=1`.

**`/commit` stopped on the project gate.** The project has a `.claude/project-gate.sh`,
which `/commit` and `/ship-main` run after the kit's own checks, passing the commit it
compares against. Its output says what failed. A project adds one for a check of its own
that every commit must pass.

**A session opens with "Shell edits are not being checked".** Claude Code reports which
files a shell command changed only in auto mode unless you add
`"bashEditDiffEnabled": true` to `~/.claude/settings.json`, and a project cannot set it
for you. Add it and restart; the project's file guards then cover shell edits in every
mode, and the warning stops.

**A cloud session doesn't see the project's hooks.** Cloud loads only what's committed:
check `.claude/settings.json` is in the repo.

**Research can't reach its deeper sources.** `EXA_API_KEY` isn't set in this shell, or in
the cloud environment's settings for a cloud session. Research still works without it.

**The kit changed.** Kit updates arrive as ordinary commits on `main`. Pull, and the next
session picks them up.
