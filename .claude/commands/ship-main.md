# /ship-main

Commit straight to `main` — no branch, no PR, no CI. The **conscious exception** for quick infra / emergency / "just get it in there and get back to clean" work. Part of the gitflow subsystem. Invoked via `/ship-main` or natural-language triggers: "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main", "quick commit to main".

$ARGUMENTS

## When to use this (and when NOT to)

| Use `/ship-main` | Use `/commit` (the default) |
|---|---|
| Conscious infra / config / emergency change you want on main NOW | Real feature work |
| You accept no PR, no CI, no review — main's history is the trail | You want branch → PR → CI → review → merge |
| You're sitting on dirty `main` and want back to clean | Anything that deserves review |

**This is never inferred.** Being on dirty `main` is often *accidental* — you started editing before `/work`. So a bare `/commit` on `main` still auto-branches — that's the safety. `/ship-main` is the opposite, on purpose, and only when you ask for it by name.

## Procedure

### Step 1: Ask before shipping code

Whether a change goes straight to main is the developer's call — never switch to `/commit` on your own. When the change touches application code — the source the app is built from or runs, the kind of change a code reviewer like Gemini would review — ask, and wait: "This appears to contain code that should go through a PR — are you sure?" Yes → continue. No → stop; the developer picks the next step. Docs, kit files, CI and review configuration (`.github/`, `.gemini/`), Docker and build files are not application code.

Under `ASSURANCE_LEVEL` `strict` the script ships docs only — files under `project-documentation/` and Markdown files — and refuses anything else (exit 16), naming the files, before any gate runs. Everything else reaches `main` through `/commit` and a PR, where CI runs the full suite. Say so and stop; there is no override.

In a repo holding infrastructure (`REPO_KIND` is `org` or `combo`) the script refuses a Terraform change (exit 14) unless every root it touches plans "No changes" — removing a spent `imports.tf`, say. Anything that changes AWS reaches main only through `/open-pr` and `/deploy`, which apply it.

### Step 2: Compose a conventional commit message

Same rules as `/commit` — `<emoji> <type>(<scope>): <subject>`. **Conventional format is required**, not optional: `/ship-main` commits land on `main` and are read by the next `/deploy` (commit subjects since the last tag) to compute the bump level + changelog, exactly like a merged-PR squash commit. A malformed subject mis-classifies the release.

### Step 3: Decide which linked issues are code complete

Decided exactly as `/commit` Step 6 decides it — from the evidence, asking only about an
issue you cannot judge — and it decides more here: only complete issues are named in this
commit's `Closes` line. An incomplete one stays parked on `main` for the work that
finishes it.

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && read_branch_incomplete_issues'
```

Map the result to `--complete "<N,N>"`, or pass nothing.

**Then write the Staged comment for each issue reaching Staged** — those already complete
plus the ones just decided — that has not had one; the issue's author reviews against it.
List them:

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && issues_needing_notes "$(read_branch_complete_issues) <N N>"'
```

Read `.claude/skills/gitflow/references/staged-comment.md` and the issue itself
(`gh issue view <N>`), then write one file per issue, `<notes_dir>/<N>.md`, in a scratch
directory outside the repo (`mktemp -d`). Pass it as `--notes <notes_dir>`. Write it and
move on — never put the wording to the human for approval. The script refuses before
committing (exit 2) when one is missing, and posts each once the board has moved.

### Step 4: Invoke the script

```bash
.claude/skills/gitflow/scripts/ship-main.sh --message "<conventional message>" [--skip-typecheck] [--complete "<N,N>" --notes <notes_dir>]
```

The script:
- Refuses unless on `main`/`master` — a body of work in progress is on its own branch and cannot trip it.
- Runs `check-types`, `biome lint`, `knip` (when `KNIP_GATE` is on), `semgrep`, the integration gate, the fit checks, the rule review, the part review, the design review, the SQL review and the test judge over the files the commit touches — the same gates `/commit` runs. **`--skip-typecheck` skips the TYPECHECK only.** Every other gate and review sits outside that guard and always run; there is no flag that bypasses them. The typecheck and the integration gate skip on code unchanged since their last pass but for comments and whitespace, as at `/commit`, and say so; `--skip-typecheck` records no pass. The headless reviews run side by side, and a review that passed on the same input is reused rather than called again. The integration gate runs the tests reaching the change, development tests included; the separate integration preflight is `/deploy`'s alone.
- Stages all changes, commits directly on `main` with `--no-verify` (validation already ran).
- Pushes straight to `main`. If `origin/main` advanced, it rebases the commit onto it and re-pushes; on conflict it stops and tells you to resolve + push.

### Step 5: Report

- Success: confirm the commit is live on `main` (SHA + subject), and which issues it named and moved to Staged. No PR URL — there is none by design.
- `--complete` names an issue not linked on `main`: exit 2, nothing committed.
- Board update failed after the push: exit 11. The commit is live; the next `/deploy` still moves the named issues to the deploy status.
- An issue reaching Staged has no comment in `--notes`: exit 2, nothing committed.
- A Staged comment did not post after the push: exit 13. The commit is live and the board updated; the script prints the exact `gh issue comment` to run.
- Refused (not on main): tell the user they're on `<branch>`; use `/commit` for branch work.
- Refused under `ASSURANCE_LEVEL` `strict` (exit 16): the change touches more than docs. Relay the files it named; the change goes through `/commit` and a PR.
- Typecheck failure — including a root `package.json` with no `check-types` script while the repository has TypeScript sources, or a `pyproject.toml` with neither pyright nor mypy installed: surface the command to run; offer `--skip-typecheck` only if the user explicitly accepts shipping unverified.
- Biome, knip, semgrep or rule-review failure: surface the finding. `--skip-typecheck` does not apply — fix it, or ship the change through `/commit` and a PR instead. A rule-review finding the human judges wrong: they may re-run with `SKIP_RULE_REVIEW=1`.
- Integration-gate failure: surface it. Write the missing test, rewrite a test that imports no app code to call the app's function, or fix the failing test. When the harness refused the database — not set up for tests, unreachable, or missing a migration this change adds — put its message to the developer as it reads; a missing migration is an apply for them to approve (`drizzle.md` §II), then run `/ship-main` again.
- SQL-review finding: put each one to the developer with the fix, and ask: fix it, or skip it. Skip: re-run with `SKIP_SQL_REVIEW=1`.
- Design-review finding: put each one to the developer with its why and fix, and ask: fix it, or skip it. Fix: make the change and re-run. Skip: re-run with `SKIP_DESIGN_REVIEW=1`.
- Test-review finding: act on each by its kind — `missing`: write the test for the case it names; `reimplements`: rewrite the test to call the application's function, or delete it when there is no application code for it to call; `superfluous`: delete the test, never rename it a development test; `misnamed`: rename or move it as the fix says — then re-run. A finding the human judges wrong: they may re-run with `SKIP_TEST_REVIEW=1`.
- Rebase conflict: surface the conflict; the user resolves then `git push origin main`.

## Naming issues without a PR

`/work <issue#>` parks its issue links on the branch you are standing on and cuts nothing, so on `main` those links are sitting right here. `ship-main.sh` writes a `Closes #N, closes #M` line for the issues marked code complete, moves them to Staged, and unlinks exactly those once the push lands. Incomplete issues stay linked on `main`.

The `Closes` line is how the next `/deploy` finds what shipped. Whether it closes the issue is GitHub configuration, not this command's: with the repository's "Auto-close issues with merged linked pull requests" setting on, GitHub closes the issue on this push; with it off, the issue stays open and the board decides (`github-project-board-setup.md`).

If the push fails the links stay put, so a retry names the same issues.

## What this does NOT do

- Does NOT open a PR or run CI — `pull_request` workflows don't fire on a push to `main`, and that's the point.
- Does NOT deploy — a deploy starts only when `/deploy` dispatches it; a main push triggers nothing. Run `/deploy` to ship.
- Does NOT bump version or write changelog — `/deploy` owns that; your ship-main commits get folded into the next release automatically.
- Does NOT auto-branch — that's `/commit`'s job and the whole reason `/ship-main` is separate.
- Does NOT push checkpoints — unpushed `/checkpoint` commits on `main` are folded into the one commit it makes, after every gate has passed, so no `🔖 wip:` subject reaches `main`.

## Prerequisite

`main` must NOT require a PR — the default on a new repo (the pipeline uses no branch protection; see `pipeline.md` §1.1). With require-PR set, GitHub rejects the direct push.
