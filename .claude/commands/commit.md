# /commit

Full conventional commit with AI-generated message. Part of the gitflow subsystem (layer 3). Invoked directly by the user (`/commit`) or by Claude in response to natural-language triggers ("commit this", "commit the changes") via the gitflow skill.

$ARGUMENTS

## Procedure

### Step 1: Analyze current changes

```bash
git status
git diff --stat
```

If nothing to commit, report and stop.

### Step 2: Categorize changes

Group related files. Identify distinct features, fixes, or chores. **Analyze ALL changes, not just what you worked on this session** — prior-session changes may still be uncommitted.

### Step 3: Build conventional commit message

Load `.claude/skills/gitflow/references/commit-types.md` for emoji/type mapping.

- Single feature: `<emoji> <type>: <description>`
- Multiple features: primary type on first line, bullet list in body
- Subject line: imperative mood, <72 chars
- Breaking change: use `!` after type (e.g., `✨ feat!:`) or `BREAKING CHANGE:` footer

### Step 4: Detect model name

Use the model you are currently running as (e.g., "Claude Opus 4.7", "Claude Sonnet 4.6"). Pass via `--model`.

### Step 5: Decide Gemini review trigger

Gemini Code Assist's auto-review on PR open is **disabled** (`.gemini/config.yaml: pull_request_opened.code_review: false`). Reviews fire only when a `/gemini review` comment is posted on the PR. `commit.sh` posts that comment after push **only when `--review` is passed**. This step decides which flag to pass.

Resolve in this order:

1. **User-specified flag in `$ARGUMENTS`.** If the user invoked `/commit --review` or `/commit --no-review`, honor it and skip the prompt.
2. **No open PR for the current branch.** Pass nothing — there's no PR to comment on. `commit.sh` short-circuits cleanly.
   ```bash
   PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
   ```
3. **The PR was handed to someone else** — assigned, and not to you. Pass nothing: this
   commit lands on a new branch stacked on it (Branch behavior, below), so there is no PR
   for it yet.
   ```bash
   bash -c 'source .claude/skills/gitflow/scripts/branch_helpers.sh && pr_handed_off "$(git branch --show-current)"'
   ```
   Exit 0 means handed off, and it prints who has it.
4. **PR is open and the user did NOT specify a flag.** Ask in prose and wait: whether to trigger a Gemini review on this commit. Carry both consequences — reviewing posts `/gemini review` after the push, which earns its keep early in the PR or when fixes substantively change behavior; skipping it is right in late triage once the decision to ship is made, saving Gemini quota and letting `/merge` proceed on CI alone.

   Map the answer to the flag: review → `--review`, skip → `--no-review`.

`GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` makes `--review` a no-op (script skips the post and logs it). The prompt still appears — the slash command doesn't read the substitution file. That's intentional: the flag is the contract; the runtime decides whether the contract is satisfiable.

### Step 6: Decide which linked issues are code complete

Code complete means finished and waiting for deployment — not "some of it is committed".
A complete issue moves to Staged on the project board; `/open-pr` later refuses to open
while any linked issue is not complete.

**You decide this, and ask only when the evidence cannot.**

1. **User already said in `$ARGUMENTS`** — `/commit --complete 42,43`, or "commit, #42 is
   done". Honor it.
2. **List the linked issues not yet complete:**
   ```bash
   bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && read_branch_incomplete_issues'
   ```
   Empty → nothing to decide, pass nothing.
3. **Judge each one against its issue** (`gh issue view <N>`): what it asks for, its
   "done when" if it has one, and its comments. It is complete when every condition it
   states is met by work you can point to — in this session or in the tree — and nothing
   in it waits on an open question or decision.
4. **Ask only about the ones you cannot judge** — a condition you cannot check, a scope
   reaching past the work in front of you, an open question or decision still on the
   issue. One question in prose naming just those and why each is unclear, then wait. Ask
   it on its own, before the Step 5 review question when both apply — one question at a
   time.

Map the result to `--complete "<N,N>"`, or pass nothing for none. The report names each
issue marked complete with the evidence in a clause.

**Then write the Staged comment for each of them that has not had one** — the issue's
author reviews against it. List the ones still needing it:

```bash
bash -c 'source .claude/skills/gitflow/scripts/issue_helpers.sh && issues_needing_notes "<N N>"'
```

Read `.claude/skills/gitflow/references/staged-comment.md` and the issue itself
(`gh issue view <N>`), then write one file per issue, `<notes_dir>/<N>.md`, in a scratch
directory outside the repo (`mktemp -d`). Pass it as `--notes <notes_dir>`. Write it and
move on — never put the wording to the human for approval. The script refuses before
committing (exit 2) when one is missing, and posts each once the board has moved.

### Step 7: Invoke the script

```bash
.claude/skills/gitflow/scripts/commit.sh \
  --message "<full conventional message>" \
  --model "<model name>" \
  <--review | --no-review | (nothing if no open PR)> \
  [--complete "<N,N>" --notes <notes_dir>]
```

Pass `--skip-typecheck` ONLY if the user explicitly requested bypassing typecheck (rare).

### Step 8: Report result

- Commit succeeded: report the commit hash and branch, and any issues moved to Staged
- `main has moved` in the output: relay the commits behind and the files changed on both
  sides, and recommend `/catchup` — before any further work when files overlap. It is a
  warning; the commit still landed. On `main` it fires BEFORE the branch is cut, so the new
  branch starts from a copy of `main` the user now knows is stale.
- Script exited non-zero: surface the exit code and stderr. Do NOT retry without direction.

## Branch behavior

The script resolves the target branch before committing:

| Current branch | Action |
|----------------|--------|
| `main` / `master` | Derive `<type>/<slug>` from the commit message, create and switch. Any issue links parked on `main` by `/work <issue#>`, and which of them are complete, are carried onto the new branch and cleared from `main`. Any `/checkpoint` commits move with it, and local `main` is reset to where they started. |
| A branch whose PR is assigned to someone else | Its review is theirs, so the commit does not join it. Cut `<type>/<slug>` from here — a branch stacked on it, recorded so `/open-pr` and `/catchup` follow it. Only issue links added since the hand-off come along; the PR keeps its own. |
| Any other branch — no PR, or a PR assigned to you or to nobody | Commit in place |

Collisions on the target name are resolved by appending `-2`, `-3`, etc.

Unpushed `/checkpoint` commits are folded into this one: once every gate has passed, the script soft-resets to the commit they sit on and commits once. The gates scan everything the checkpoints saved, since checkpoints skip them.

The headless reviews — rule, part, design, SQL and the test judge — run side by side, so they take as long as the slowest, and each one's output prints whole once all have finished. Each runs only when its kind of file changed, and a review that passed is reused: the same review over the same input says so and makes no call, so re-running `/commit` after fixing one finding does not pay for the others again. A finding, or a review that could not run, is asked again every time.

The integration gate runs the integration tests that reach a change — the development tests (`*.dev.integration.test.ts`) included, which the full suite leaves out. The separate integration preflight (`test:preflight`) is not run here; the gate's own run reports a database the tests cannot use, and `/deploy` runs the preflight.

The typecheck and the integration gate each record the code fingerprint they passed on (`code-fingerprint.mjs`: the tree with comments and whitespace left out of TypeScript and JavaScript). On the same fingerprint they skip, printing "code unchanged since the last pass (comments and whitespace only)" — so a commit that only rewords comments, or a re-run after fixing a review finding in prose, does not type-check or test again. The integration gate's record also names the commit it measured from. A failure is never recorded.

## What this command does NOT do

- Does not update `changelog.md` — `/deploy` is its only writer
- Does not bump version — handled by `/deploy` (local, human-in-the-loop)
- Does not create a tag — same
- Does not open a PR — separate step via `/open-pr`

## Blocking conditions

The script will exit non-zero if:

- TypeScript or Python typecheck fails, a root `package.json` has no `check-types` script while the repository has TypeScript sources, or a root `pyproject.toml` is present with neither pyright nor mypy installed
- Biome lint reports an error, or `biome.json` is present and `@biomejs/biome` is not installed
- knip reports unused code or cannot run, when `KNIP_GATE` is `"true"` in `.claude/sync-substitutions.json`
- Semgrep reports a finding in a file this commit touches (`.semgrepignore` applies, as in CI), CI declares a `semgrep` job and semgrep is not installed locally, or the changed files cannot be listed
- The integration gate fails: the coverage check finds a changed exported function of a risky database shape that no happy-path or risk test calls, a changed integration test file that imports nothing from the app's source, or a changed `.execute()` with no `raw-sql:` reason; an integration test reaching a changed file fails; the integration tests' database is not ready — the harness refuses before any test connects when it is not set up for tests, cannot be reached, or lacks a migration this branch adds; or the repository has integration tests and no integration project runs here. Write the test, or make the test import and call the app's function (`testing-verification.md`). Put a refusal to the developer as it reads: it names the fix, and a missing migration is an apply for them to approve (`drizzle.md` §II), after which run the command again
- The SQL review finds a table or column typed as text inside a changed `sql` template, or cannot run. Put each finding to the developer with the fix, and ask: fix it, or skip it. Skip: commit again with `SKIP_SQL_REVIEW=1`
- The test judge judges the tests of the changed TypeScript and finds one to fix, or cannot run. Act on each finding by its kind: `missing` — write the test for the case it names; `reimplements` — rewrite the test to call the application's function instead of its own copy of the logic, or delete it when there is no application code for it to call; `superfluous` — delete the test, never rename it a development test; `misnamed` — rename or move it as the fix says. Then commit again. A finding the human judges wrong: they may commit with `SKIP_TEST_REVIEW=1`
- The rule review finds history, justification or a counted list in a changed rule, skill, command or pattern reference, or cannot run. Fix the text; the human may override a wrong finding with `SKIP_RULE_REVIEW=1`
- A pending component has no fit check on its inventory line, or its file changed after the check approved it (`check-ui-status.mjs --fit-only`). Run the fit check (`.claude/skills/design-system/references/fit-check.md`) and commit again
- The part review suspects a new part duplicates a part that already exists in the source, or cannot run. The human decides: the same thing folds into the existing part; different gets their reason on the new part's inventory line
- The design review finds a change that breaks one of the design checks (`.claude/skills/design-system/references/design-checks.md`) — a screen using a role against its purpose or departing from its pattern, a pattern asking for what a part does not have, a call site repainting a part — or cannot run. Put each finding to the developer with its why and fix, and ask: fix it, or skip it. Fix: make the change and commit again. Skip: commit again with `SKIP_DESIGN_REVIEW=1`
- Nothing is staged (empty diff)
- `git commit` itself fails for any reason
- `--review` and `--no-review` both passed (mutually exclusive — exit 2)
- `--review` passed and the `/gemini review` comment failed to post (exit 10 — fail-loud so the user knows Gemini is NOT coming; downstream `wait-for-pr-ready.sh` would otherwise silently proceed CI-only)
- The PR still owes a Gemini review — one asked for and not back, or a finding with no reply (exit 14, before anything is committed). Keep the fix in the tree and do what the message says: rejoin the wait with `--review-only`, or run `/triage`, whose one commit carries the fix. Committing past it is the human's call alone: put it to them and wait, and pass `--skip-review-wait "<their reason>"` only when they say so in the message you are answering. The reason lands in the commit and on the PR
- `--complete` names an issue not linked on the branch (exit 2, before anything is committed)
- The commit and push landed but the board update failed (exit 11 — the issues are marked complete locally; `/open-pr` sets every linked issue to Staged again)
- An issue reaching Staged has no comment in `--notes` (exit 2, before anything is committed)
- The commit, push and board update landed but a Staged comment did not post (exit 13 — the script prints the exact `gh issue comment` to run)

When the script blocks, surface the reason to the user. Fix underlying issues per constitution §XII (own all errors). Do not bypass.

## Recovery: `--push-only` mode

If a prior `/commit` succeeded at the commit step but failed at push (typical cause: a branch left tracking `origin/main` rather than its own remote ref — plain `git push` then fails under `push.default=simple`), re-trigger the push without re-running typecheck or staging:

```bash
.claude/skills/gitflow/scripts/commit.sh --push-only
```

Push-only:
- Refuses if the working tree has uncommitted changes (use the regular flow instead).
- Refuses on detached HEAD.
- Invokes `safe_push` which sets/corrects upstream to `origin/<branch>` on first push.
- No-op behavior when HEAD is already at the remote (git push reports "Everything up-to-date").

Use this when picking up a half-shipped /commit from a previous session.
