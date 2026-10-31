---
name: gitflow
description: This skill should be used when the user asks to "work on", "start work", "pick up where I left off", "open the project", "commit", "commit this", "commit the changes", "ship to main", "commit straight to main", "infra commit", "emergency commit to main", "checkpoint", "save progress", "wip commit", "link issue", "link this issue", "also works on issue", "open pr", "open a pull request", "submit for review", "triage", "work the review", "go through gemini", "merge", "merge to main", "ship it", "promote to prod", "retrieve a branch", "catch up with main", "catch my branch up", "get latest main", "pull main into my branch", "update my branch with main", "continue the merge", "abort the catchup", or any natural-language request for git work-session, commit, checkpoint, issue-link, pull-request, review-triage, catchup, merge, deploy, or promotion operations. Routes to the corresponding slash command. The canonical and ONLY authorized path for starting work, committing, checkpointing, PR creation, review triage, catchup, and merges in this project.
user-invocable: false
---

# gitflow

The gitflow skill is the natural-language routing layer for the git workflow subsystem. It maps user requests to the slash commands that own the mechanics.

## When gitflow applies

Invoke this skill when the user asks for any of:

| User intent | Command to invoke |
|-------------|-------------------|
| "work on this", "open the project", "pick up where I left off", "start work" | `/work` |
| "start work on #N", "work issue N" | `/work <N>` |
| "retrieve branch", "pull a teammate's branch", "check out their branch" | `/work --retrieve <branch>` |
| "the discussion is done", "pull the discussion in", "pull back <slug or artifact URL>" | `/work --discussion <slug or URL>` |
| "work in a worktree", "start a worktree", "isolated session", "back to the worktree <name>" | `/work --worktree [<name> or <issue#>]` |
| "commit", "commit this", "commit the changes" | `/commit` |
| "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main", "quick commit to main" | `/ship-main` |
| "checkpoint", "save progress", "wip commit", "quick save" | `/checkpoint` |
| "link issue", "link this issue", "also works on #N", "add #N to this branch" | `/work <N>` |
| "catch up with main", "catch my branch up", "get latest main", "pull main into my branch", "update my branch with main" | `/catchup` |
| "continue the merge", "finish catching up" | `/catchup --continue` |
| "abort the catchup", "bail on the merge" | `/catchup --abort` |
| "open pr", "open a pull request", "submit for review" | `/open-pr` |
| "triage", "work the review", "go through gemini", "walk the review" | `/triage` |
| "merge", "merge to main", "ship it", "land this" | `/merge` |
| "deploy", "release", "cut a release" | `/deploy` |
| "promote <version>", "promote to prod", "ship to prod", "release to production" | `/deploy promote <version>` when the project sets `CODEBUILD_PROMOTE_PREFIX`; otherwise `/deploy` |

## Workflow philosophy: bundle freely, ship when the user says ship

This shop bundles multiple unrelated issues into a single session, branch, and PR. **That is the intended workflow, not a violation of scope discipline.** A session may start with `/work <A>` and then add `/work <B>`, `/work <C>` for genuinely unrelated issues — the user is intentionally batching work to ship together when they decide.

**Forbidden behaviors when the user is bundling (Zero Tolerance):**

- Scolding or warning the user for "mixing unrelated issues" on one branch/PR.
- Recommending they `/open-pr` + `/merge` the prior issue before starting the next.
- Suggesting a separate branch to "keep things clean" when the user explicitly linked a further issue onto the branch they are on.
- Framing single-PR multi-issue work as a tradeoff (clean history vs. fewer cycles). It is not a tradeoff here — bundling is the default.
- Asking "do you want to PR this first?" between linked issues. The user did not ask; do not offer.
- Asking "should I update the handbook / docs separately?" or "split that into a follow-up PR?" Doc updates ride in the same PR as the change they document.
- Committing infra/script work without self-reviewing the staged diff first.

**Why:** in an AI-driven shop, every split PR multiplies review cycles, CI runs, Gemini re-reviews, version-bump churn, and merge coordination — without adding review value. The user controls the ship cadence. Linking a further issue onto the branch IS the user's explicit decision to bundle; treat it as a directive, not a question to re-open.

**The only exceptions** (and only the user can flag them):
- The user explicitly asks to split ("PR just A, then start B fresh").
- A hard rollback boundary one issue crosses but the other doesn't (rare; user surfaces it).

**Default:** if unsure, bundle. The user will redirect if they want otherwise.

This rule subsumes any prior or training-data instinct toward "one issue per PR." It is not the convention in this shop and recommending it is a violation.

## What gitflow does NOT do

- Does not run git commands directly. All mechanics live in `/commit`, `/checkpoint`, `/open-pr`, `/merge`, `/deploy` commands, which in turn call scripts in `skills/gitflow/scripts/`.
- Does not bypass validation. `commit.sh` and `ship-main.sh` run the gates in `gates.sh` before committing — typecheck, biome, knip, semgrep, the integration gate and the headless reviews, each saying what it checked or why it does not apply here — and `git-guard.sh` fires regardless. If either blocks, fix the underlying issue — do not attempt to bypass.
- Does not auto-bump version or auto-write changelog at merge time. Version bump + changelog generation happen at `/deploy` time only (human-in-the-loop). Merging to main does not ship.

## Usage procedure

When a user request matches a gitflow trigger:

1. Identify which command applies.
2. Gather the inputs that command needs (see each command's `.md` file for parameters). For `/commit` and `/open-pr`, this means analyzing the diff to generate the message or title.
3. Invoke the slash command. Claude invokes commands via the normal slash command invocation path.
4. If the command blocks for any reason (hook denial, CI failure, merge conflict), report the blocker to the user. Do not retry without explicit direction.

## The commands

### /commit

Full conventional commit with AI-generated message.

**Procedure:**
- Run `git status` and `git diff --stat` to understand changes
- Categorize changes by feature/purpose
- Load `references/commit-types.md` for emoji/type mapping
- Build commit message: `<emoji> <type>: <description>` for single feature, or multi-line format for multiple features
- Decide which linked issues are code complete (finished, waiting for deployment) from the issue and the work, asking only about one you cannot judge; each becomes `--complete "<N,N>"`, is marked on the branch and moves to Staged after the push
- Invoke `/commit` passing the message

Auto-branch behavior: if on `main`, `/commit` derives a `<type>/<slug>` branch from the commit message and creates it before committing. Unpushed `/checkpoint` commits are folded into the one commit it makes.

See `commands/commit.md` for the full specification.

### /ship-main

Direct conventional commit straight to `main` — no branch, no PR, no CI. The **conscious exception** for quick infra / emergency work.

**Procedure:**
- Confirm this is genuinely a deliberate direct-to-main change — if it looks like feature work or the user said "commit" (not "ship to main"), use `/commit` instead.
- Build a conventional message exactly as for `/commit` (required — the next `/deploy` reads it for bump-level + changelog).
- Decide code complete as `/commit` does. Only complete issues get a `Closes #N` line, move to Staged and are unlinked; incomplete ones stay parked on `main`.
- Invoke `/ship-main` passing the message.

**Critical distinction:** `/ship-main` is the OPPOSITE of `/commit`'s auto-branch. Bare "commit" on `main` auto-branches (the safety); `/ship-main` commits ON `main` and pushes directly. Route here ONLY on the explicit triggers ("ship to main", "infra commit", "emergency to main") — NEVER from a bare "commit", and NEVER inferred from the user being on `main`. The script refuses unless actually on `main`.

See `commands/ship-main.md` for the full specification.

### /checkpoint

A local save point, without deep analysis.

**Procedure:**
- Optional: take a short message from the user
- Invoke `/checkpoint`

See `commands/checkpoint.md`. The command auto-formats the message as `🔖 wip: <timestamp or user message>`. It makes no code-complete decision — a checkpoint is partway by definition.

No branch is cut and nothing is pushed: the checkpoint is a local commit on the current branch, `main` included. `/commit` and `/ship-main` fold every unpushed checkpoint into the one real commit they make, so a `🔖 wip:` subject never reaches origin.

### /work

Start or resume a body of work on a branch in this checkout. This is the session-init command — invoke first in any session that will edit code.

Work happens on a branch in the project checkout. On `main`, `/work` refreshes from origin and STAYS there — no branch is cut; on a feature branch it resumes.

**Modes:**
- `/work` — refresh `main` and stay on it, or resume the branch you are on. Idempotent, cuts nothing.
- `/work <issue#[,issue#…]>` — link one or more issues to the branch you are on, transition each to In Progress, assign, and dump their context. Cuts no branch either. Every issue is validated before any is linked, so a typo aborts the call instead of half-applying it.
- `/work --retrieve <branch>` — fetch a teammate's branch and switch to it (refuses on a dirty tree).
- `/work --discussion <slug or artifact URL>` — pull a finished discussion back into an action plan (`commands/work.md` Step 3b).
- `/work --worktree [<name> | <issue#>]` — opt-in: create or re-enter the worktree `.claude/worktrees/<label>` on its own `wip/` branch, and move the session into it (`commands/work.md` Step 2a). For two sessions on one project at once.

**Procedure:**
- Parse `$ARGUMENTS` to determine mode (default / issue / retrieve).
- Invoke `.claude/skills/gitflow/scripts/work.sh` with appropriate flags.
- For `--issue` mode: read the dumped issue body + comments and respond with understanding + plan before touching code.

See `.claude/commands/work.md` (synced per-project from `_claude-project/commands/work.md`; `work.sh` refuses to run while a `/work` command exists in `~/.claude/commands/`). The script (project-local at `.claude/skills/gitflow/scripts/work.sh`) refreshes `main`, resumes an existing branch, and handles issue linking. `/work` never cuts a branch, with or without an issue — `/commit` and `/checkpoint` do that — except `--worktree`, whose worktree needs a branch of its own from the start. It does not commit or push.

### /open-pr

Push current branch and create a PR via gh (local) or GitHub API (cloud).

**Procedure:**
- Analyze branch diff against main: `git diff --stat main..HEAD` and `git log --oneline main..HEAD`
- Generate conventional PR title (emoji + type + description)
- Generate PR body describing the changes
- Ask about every linked issue not yet marked code complete ("Does this PR finish #42, or is it part of #42?"). Finishes → `--complete "<N,N>"`; part of it → `--part "<N,N>"`, written `Part of #N`, closing nothing; neither → stop, no PR is opened
- Invoke `/open-pr` passing title and body

See `commands/open-pr.md`. The command pushes the branch, creates the PR, posts an explicit `/gemini review` comment (Gemini's auto-review on PR open is disabled in `.gemini/config.yaml`), then invokes `wait-for-pr-ready.sh` to block until CI passes and Gemini has reviewed HEAD (the wait is trigger-aware: it reads PR comments to confirm a `/gemini review` was posted for the current HEAD). On exit 0, prompts the user to run `/triage` or `/merge` — explicit handoff, never auto-invokes.

### /triage

Walk through open Gemini Code Assist review comments on the current PR **one at a time**. Present each item with location, severity, Gemini's concern, proposed fix, and a one-line recommendation. Wait for the user's decision (fix / skip / discuss) before acting. Never batch; never auto-act.

**Procedure:**
- Resolve the open PR for the current branch via `gh pr list --head <branch>`
- Pull Gemini reviews + inline comments via `gh api` filtered by `user.login == "gemini-code-assist[bot]"`
- Filter stale/resolved items, order by file/line
- Present item 1 → wait → act → advance to item 2 → repeat

On "fix": implement it and reply on the thread; nothing is committed mid-triage. On "skip": reply on the thread and leave an inline source comment stating the carve-out. At the end, one `/commit` bundles every fix, on the user's instruction; they decide then whether to post a fresh `/gemini review` (`--review` or the `/commit` prompt).

See `commands/triage.md`. Gemini-only for MVP; human reviewers and other bots are future scope.

### /merge

Wait for PR readiness and squash-merge the current branch's PR.

**Procedure:**
- Identify the open PR (auto-detect from current branch, or `--pr <number>` arg)
- If multiple open PRs are associated with the branch, ask the user which
- `merge.sh` invokes `wait-for-pr-ready.sh` (trigger-aware: waits for Gemini only if a `/gemini review` was posted for the current HEAD; otherwise proceeds CI-only). `/commit --no-review` is the user's signal that no Gemini wait is needed at merge. It refuses uncommitted changes first (exit 26), and builds every workspace locally while the wait polls. Bypassable via `--force-unchecked` for emergency hotfixes only (skips the build and the CI wait).
- On a passed build and wait: squash-merge, switch to main, fast-forward. In a worktree nothing local changes and the worktree is removed afterwards, or kept to `/deploy` from (`--deploy-from-worktree`)

See `commands/merge.md`. Wait timeout is 15min by default; on timeout, surface diagnostic and stop — the user decides whether to extend (Gemini may be rate-limited despite the trigger landing), opt this repo out of Gemini gating (`GEMINI_NOT_INSTALLED="true"` — only correct if Gemini is genuinely absent), or `--force-unchecked`.

## What happens after merge

After `/merge` completes, the squash commit lands on main. **Nothing fires automatically.** No version bump, no tag, no deploy. Multiple feature merges can accumulate on main between releases.

To ship the accumulated commits to production, run `/deploy`:

1. Detects bump level (patch/minor/major) from conventional commit subjects since the last `v*.*.*` tag
2. Generates a user-facing changelog entry from the same commits
3. Bumps `package.json` (or `pyproject.toml`), writes the changelog entry, commits the bump, tags `v<NEW>`, pushes
4. Dispatches the migration (if any) and every service's deploy — CodeBuild projects by default, GitHub workflows under the `github` backend — and watches them

`/deploy` is the changelog's only writer — `/open-pr` never touches it. See `commands/deploy.md`.

**Deploy trigger contract (MANDATORY):** a deploy starts only when `/deploy` dispatches it, after pushing the bump commit + tag, so it builds post-bump HEAD with the correct version. A CodeBuild deploy project carries no webhook and no schedule; a GitHub deploy workflow's only trigger is `workflow_dispatch:`. A push trigger races the bump; a tag trigger double-fires. See pipeline.md §2.5.

## Reference files

Load these only when needed for the task:

- **`references/commit-types.md`** — Emoji/type mapping for commit message construction.
- **`references/changelog-rules.md`** — Changelog entry rules (applied by Claude during `/deploy` to write the release entry).

## Scripts

The commands invoke these scripts in `skills/gitflow/scripts/`:

| Script | Purpose |
|--------|---------|
| `work.sh` | Refresh `main` or resume the current branch, cutting nothing; `--issue <N[,N…]>` to link one or more issues to the branch you are on; `--retrieve` to fetch and switch to someone else's branch; `--discussion <slug\|URL>` to locate a discussion folder and print its pointer; `--worktree` to create or re-enter a worktree |
| `commit.sh` | Full conventional commit after the gates, stages all, pushes; auto-branches on main; folds unpushed checkpoints |
| `ship-main.sh` | The same gates, then a conventional commit straight to `main` and a push |
| `checkpoint.sh` | Local commit on the current branch, stages all; no branch, no push |
| `catchup.sh` | Fast-forward `main`, or merge `main` (or a stacked branch's parent) into the current branch |
| `open-pr.sh` | Refuse (exit 12) while a linked issue is neither code complete nor `--part`; run the happy-path check (a warning; exit 16 under `ASSURANCE_LEVEL` `strict`); push branch, create PR via gh or GitHub API; prepends `Closes #N` for the issues it finishes and moves them to Staged, and `Part of #N` for `--part` ones |
| `wait-for-pr-ready.sh` | Poll until CI green + (if a `/gemini review` comment was posted for the current HEAD) Gemini Code Assist has posted its review; under `TEST_RUNNER` `aws`, also the `full-suite` status; fail-loud timeout. Trigger-aware: no trigger comment for HEAD → CI-only ready. `GEMINI_NOT_INSTALLED="true"` short-circuits the Gemini path entirely. A CI failure exits at once and says whether a review is still due; `--review-only` rejoins that wait, ignoring CI, while the fix sits in the tree. Invoked by `/open-pr`, `/triage`, `/merge`. |
| `merge.sh` | Refuse uncommitted changes, build locally while waiting for PR readiness, squash-merge via gh, land this checkout back on `main`, delete the merged local branch, reinstall deps if manifests changed |
| `worktree-remove.sh` | Remove a finished worktree and its local branch, from the primary checkout |
| `deploy.sh`, `deploy-org.sh` | `/deploy`: release gates, bump, changelog, tag, dispatch; in a repo holding infrastructure, apply and merge a Terraform PR |
| `gates.sh` | The gates `/commit`, `/ship-main`, `/merge` and `/deploy` run; the typecheck, integration and build gates skip on an unchanged code fingerprint |
| `rule-review.sh`, `part-review.sh`, `design-review.sh`, `sql-review.sh`, `test-review.sh` | The headless reviews, run side by side by `gates.sh` |
| `review-cache.sh` | Remembers each review's last pass, so the same review over the same input is not called again |
| `code-fingerprint.mjs` | One hash of the code, unchanged by comments and whitespace; the name and description of the `full-suite` status |
| `settings.sh` | Resolves `TEST_RUNNER` and `ASSURANCE_LEVEL` — kit default, then the project's value, then (`TEST_RUNNER` only) `.env` |
| `codebuild-suite.sh` | The full suite in a CodeBuild test project under `TEST_RUNNER` `aws` |
| `repo_kind.sh` | What the repository holds — app, org or combo |
| `file-issue.sh` | File an issue and put it on the project board |
| `branch_helpers.sh` | Shared helpers sourced by work/commit/checkpoint scripts |
| `issue_helpers.sh` | Shared issue helpers: parse CSV, validate issues, link to branch and mark code complete (git config), project status transitions (In Progress, Staged, the deploy status), user assignment, issue context dump |
| `get_timestamp.sh` | Local-timezone timestamp utility |

Scripts use `git commit --no-verify` because validation is the hook layer's responsibility (or the script's own first-step validation).

## Constraints

- **Never bypass hooks.** If `git-guard.sh` denies, or `commit.sh`'s inline typecheck or lint fails, the issue is real. Report to user.
- **Never use raw `git commit`, `git add`, `git push`, `git merge`, `git reset`, `git revert`, `git restore`, `git clean`, `git checkout <file>` directly.** Use the commands. Hooks will block you anyway.
- **Never proactively invoke gitflow.** Every invocation requires a fresh explicit user request. See `.claude/rules/git.md`.
