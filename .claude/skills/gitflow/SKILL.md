---
name: gitflow
description: This skill should be used when the user asks to "work on", "start work", "pick up where I left off", "open the project", "commit", "commit this", "commit the changes", "ship to main", "commit straight to main", "infra commit", "emergency commit to main", "checkpoint", "save progress", "wip commit", "link issue", "link this issue", "also works on issue", "open pr", "open a pull request", "submit for review", "triage", "work the review", "go through gemini", "merge", "merge to main", "ship it", "retrieve a branch", "catch up with main", "catch my branch up", "get latest main", "pull main into my branch", "update my branch with main", "continue the merge", "abort the catchup", or any natural-language request for git work-session, commit, checkpoint, issue-link, pull-request, review-triage, catchup, merge, or deploy operations. Routes to the corresponding slash command. The canonical and ONLY authorized path for starting work, committing, checkpointing, PR creation, review triage, catchup, and merges in this project.
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
| "discard current", "reset the workspace", "nuke current/" | `/work --discard current --force` |
| "commit", "commit this", "commit the changes" | `/commit` |
| "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main", "quick commit to main" | `/ship-main` |
| "checkpoint", "save progress", "wip commit", "quick save" | `/checkpoint` |
| "link issue", "link this issue", "also works on #N", "add #N to this branch" | `/link` |
| "catch up with main", "catch my branch up", "get latest main", "pull main into my branch", "update my branch with main" | `/catchup` |
| "continue the merge", "finish catching up" | `/catchup --continue` |
| "abort the catchup", "bail on the merge" | `/catchup --abort` |
| "open pr", "open a pull request", "submit for review" | `/open-pr` |
| "triage", "work the review", "go through gemini", "walk the review" | `/triage` |
| "merge", "merge to main", "ship it", "land this" | `/merge` |
| "deploy", "ship to prod", "release", "cut a release" | `/deploy` |

## Workflow philosophy: bundle freely, ship when the user says ship

This shop bundles multiple unrelated issues into a single session, branch, and PR. **That is the intended workflow, not a violation of scope discipline.** A session may start with `/work <A>` and then add `/link <B>`, `/link <C>` for genuinely unrelated issues — the user is intentionally batching work to ship together when they decide.

**Forbidden behaviors when the user is bundling (Zero Tolerance):**

- Scolding or warning the user for "mixing unrelated issues" on one branch/PR.
- Recommending they `/open-pr` + `/merge` the prior issue before starting the next.
- Suggesting a separate branch to "keep things clean" when the user explicitly chose `/link`.
- Framing single-PR multi-issue work as a tradeoff (clean history vs. fewer cycles). It is not a tradeoff here — bundling is the default.
- Asking "do you want to PR this first?" between linked issues. The user did not ask; do not offer.
- Asking "should I update the HANDBOOK / docs separately?" or "split that into a follow-up PR?" Doc updates ride in the same PR as the change they document.
- Committing infra/script work without self-reviewing the staged diff first.

**Why:** in an AI-driven shop, every split PR multiplies review cycles, CI runs, Gemini re-reviews, version-bump churn, and merge coordination — without adding review value. The user controls the ship cadence. The act of invoking `/link` IS the user's explicit decision to bundle; treat it as a directive, not a question to re-open.

**The only exceptions** (and only the user can flag them):
- The user explicitly asks to split ("PR just A, then start B fresh").
- A hard rollback boundary one issue crosses but the other doesn't (rare; user surfaces it).

**Default:** if unsure, bundle. The user will redirect if they want otherwise.

This rule subsumes any prior or training-data instinct toward "one issue per PR." It is not the convention in this shop and recommending it is a violation.

## What gitflow does NOT do

- Does not run git commands directly. All mechanics live in `/commit`, `/checkpoint`, `/open-pr`, `/merge`, `/deploy` commands, which in turn call scripts in `skills/gitflow/scripts/`.
- Does not bypass validation. The `pre-commit-validation.sh` and `git-guard.sh` hooks fire regardless. If hooks block, fix the underlying issue — do not attempt to bypass.
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
- Invoke `/commit` passing the message

Auto-branch behavior: if on `main`, `/commit` derives a `<type>/<slug>` branch from the commit message and creates it before committing. If on a `wip/<timestamp>` branch (from a prior `/checkpoint`), it renames the branch to `<type>/<slug>` — unless there is an open PR for the branch, in which case it commits in place to preserve the PR link.

See `commands/commit.md` for the full specification.

### /ship-main

Direct conventional commit straight to `main` — no branch, no PR, no CI. The **conscious exception** for quick infra / emergency work.

**Procedure:**
- Confirm this is genuinely a deliberate direct-to-main change — if it looks like feature work or the user said "commit" (not "ship to main"), use `/commit` instead.
- Build a conventional message exactly as for `/commit` (required — the next `/deploy` reads it for bump-level + changelog).
- Invoke `/ship-main` passing the message.

**Critical distinction:** `/ship-main` is the OPPOSITE of `/commit`'s auto-branch. Bare "commit" on `main` auto-branches (the safety); `/ship-main` commits ON `main` and pushes directly. Route here ONLY on the explicit triggers ("ship to main", "infra commit", "emergency to main") — NEVER from a bare "commit", and NEVER inferred from the user being on `main`. The script refuses unless actually on `main`.

See `commands/ship-main.md` for the full specification.

### /checkpoint

Fast WIP commit without deep analysis.

**Procedure:**
- Optional: take a short message from the user
- Invoke `/checkpoint`

See `commands/checkpoint.md`. The command auto-formats the message as `🔖 wip: <timestamp or user message>`.

Auto-branch behavior: if on `main`, `/checkpoint` creates a `wip/<timestamp>` branch before committing. A later `/commit` on that `wip/*` branch renames it based on the commit message.

### /work

Start or resume a body of work on a branch in this checkout. This is the session-init command — invoke first in any session that will edit code.

Work happens on a branch in the project checkout. On `main`, `/work` refreshes from origin and cuts the branch; on a feature branch it resumes.

**Modes:**
- `/work` — enter `current/`, create on `main` if missing. Idempotent.
- `/work <issue#>` — enter `current/`, ensure a feature branch (derived from issue title) is checked out, link the issue. Behaves like `/link` if `current/` is already on a feature branch.
- `/work --retrieve <branch>` — fetch a teammate's branch and switch to it (refuses on a dirty tree).

**Procedure:**
- Parse `$ARGUMENTS` to determine mode (default / issue / new / retrieve / discard).
- Invoke `.claude/skills/gitflow/scripts/work.sh` with appropriate flags.
- For `--issue` mode: read the dumped issue body + comments and respond with understanding + plan before touching code.

See `_claude-global/commands/work.md` (installed at `~/.claude/commands/work.md` so `/work` is discoverable from any cwd, including pre-project agents-view sessions). The script (project-local at `.claude/skills/gitflow/scripts/work.sh`) handles branch creation, branch derivation, and issue linking. It does not commit or push.

### /link

Link one or more GitHub issues to the CURRENT feature branch mid-work. Use when additional issues are discovered after `/work` or when backfilling issue links on a `wip/*` branch.

**Procedure:**
- Parse `$ARGUMENTS` into an issue CSV
- Invoke `.claude/skills/gitflow/scripts/link.sh --issues "<csv>"`
- Same side-effects as `/work <issue#>` minus branch creation: status transition, assignment, git-config link store, issue context dump
- Claude reads the dumped context and responds with understanding + impact assessment

See `commands/link.md`. Refuses to run on `main`/`master`. Linked issues flow into PR body as `Closes #N` when `/open-pr` later fires.

### /open-pr

Push current branch and create a PR via gh (local) or GitHub API (cloud).

**Procedure:**
- Analyze branch diff against main: `git diff --stat main..HEAD` and `git log --oneline main..HEAD`
- Generate conventional PR title (emoji + type + description)
- Generate PR body describing the changes
- Invoke `/open-pr` passing title and body

See `commands/open-pr.md`. The command pushes the branch, creates the PR, posts an explicit `/gemini review` comment (Gemini's auto-review on PR open is disabled in `.gemini/config.yaml`), then invokes `wait-for-pr-ready.sh` to block until CI passes and Gemini has reviewed HEAD (the wait is trigger-aware: it reads PR comments to confirm a `/gemini review` was posted for the current HEAD). On exit 0, prompts the user to run `/triage` or `/merge` — explicit handoff, never auto-invokes.

### /triage

Walk through open Gemini Code Assist review comments on the current PR **one at a time**. Present each item with location, severity, Gemini's concern, proposed fix, and a one-line recommendation. Wait for the user's decision (fix / skip / discuss) before acting. Never batch; never auto-act.

**Procedure:**
- Resolve the open PR for the current branch via `gh pr list --head <branch>`
- Pull Gemini reviews + inline comments via `gh api` filtered by `user.login == "gemini-code-assist[bot]"`
- Filter stale/resolved items, order by file/line
- Present item 1 → wait → act → advance to item 2 → repeat

On "fix": implement + `/commit` (focused message) + push; the user decides at commit time whether to post a fresh `/gemini review` (via `--review` flag or the `/commit` prompt). On "skip": optional 1-2 sentence reply via `gh pr comment` or silent pass. One commit per accepted fix.

See `commands/triage.md`. Gemini-only for MVP; human reviewers and other bots are future scope.

### /merge

Wait for PR readiness and squash-merge the current branch's PR.

**Procedure:**
- Identify the open PR (auto-detect from current branch, or `--pr <number>` arg)
- If multiple open PRs are associated with the branch, ask the user which
- `merge.sh` invokes `wait-for-pr-ready.sh` (trigger-aware: waits for Gemini only if a `/gemini review` was posted for the current HEAD; otherwise proceeds CI-only). `/commit --no-review` is the user's signal that no Gemini wait is needed at merge. Bypassable via `--force-unchecked` for emergency hotfixes only (skips CI too).
- On wait exit 0: `gh pr merge --squash --delete-branch`, switch to main, pull

See `commands/merge.md`. Wait timeout is 15min by default; on timeout, surface diagnostic and stop — the user decides whether to extend (Gemini may be rate-limited despite the trigger landing), opt this repo out of Gemini gating (`GEMINI_NOT_INSTALLED="true"` — only correct if Gemini is genuinely absent), or `--force-unchecked`.

## What happens after merge

After `/merge` completes, the squash commit lands on main. **Nothing fires automatically.** No version bump, no tag, no deploy. Multiple feature merges can accumulate on main between releases.

To ship the accumulated commits to production, run `/deploy`:

1. Detects bump level (patch/minor/major) from conventional commit subjects since the last `v*.*.*` tag
2. Generates a user-facing changelog entry from the same commits
3. Bumps `package.json` (or `pyproject.toml`), writes the changelog entry, commits the bump, tags `v<NEW>`, pushes
4. Triggers the consumer project's `deploy.yml` via `gh workflow run` and watches the run

The changelog skeleton is also generated by Claude during `/open-pr` (not by a CI workflow) — that entry is committed to the feature branch before the PR push. `/deploy` collects per-PR entries into the date section. See `commands/deploy.md` and `commands/open-pr.md`.

**Deploy trigger contract (MANDATORY):** consumer projects MUST configure `deploy.yml` to trigger on `workflow_dispatch:` ONLY. No `on: push:` (races version-bump). No `on: push: tags:` (legacy tag-trigger pattern was abandoned 2026-05-06 in favor of human-in-the-loop). `/deploy` calls `gh workflow run deploy.yml --ref main` after pushing the bump commit + tag, so the workflow runs against the post-bump HEAD with the correct version. See HANDBOOK §11.4.

## Reference files

Load these only when needed for the task:

- **`references/commit-types.md`** — Emoji/type mapping for commit message construction.
- **`references/changelog-rules.md`** — Changelog entry rules (applied by Claude during `/open-pr` to generate the entry).

## Scripts

The commands invoke these scripts in `skills/gitflow/scripts/`:

| Script | Purpose |
|--------|---------|
| `work.sh` | Start or resume the body-of-work branch; --issue to start an issue-linked branch; --retrieve to fetch and switch to someone else's branch |
| `commit.sh` | Full conventional commit, stages all, pushes; auto-branches/renames as needed |
| `checkpoint.sh` | WIP commit, stages all, pushes; auto-creates `wip/<timestamp>` on main |
| `link.sh` | Links additional GitHub issues to the current branch mid-work |
| `open-pr.sh` | Push branch, create PR via gh or GitHub API; prepends `Closes #N` from branch-linked issues |
| `wait-for-pr-ready.sh` | Poll until CI green + (if a `/gemini review` comment was posted for the current HEAD) Gemini Code Assist has posted its review; fail-loud timeout. Trigger-aware: no trigger comment for HEAD → CI-only ready. `GEMINI_NOT_INSTALLED="true"` short-circuits the Gemini path entirely. Invoked by `/open-pr`, `/triage`, `/merge`. |
| `merge.sh` | Wait for PR readiness, squash-merge via gh, land this checkout back on `main`, delete the merged local branch, reinstall deps if manifests changed |
| `branch_helpers.sh` | Shared helpers sourced by work/commit/checkpoint scripts |
| `issue_helpers.sh` | Shared helpers for `/work --issue` and `/link`: parse CSV, validate issues, link to branch (git config), project status transition, user assignment, issue context dump |
| `get_timestamp.sh` | Local-timezone timestamp utility |

Scripts use `git commit --no-verify` because validation is the hook layer's responsibility (or the script's own first-step validation).

## Constraints

- **Never bypass hooks.** If `pre-commit-validation.sh` or `git-guard.sh` denies, the issue is real. Report to user.
- **Never use raw `git commit`, `git add`, `git push`, `git merge`, `git reset`, `git revert`, `git restore`, `git clean`, `git checkout <file>` directly.** Use the commands. Hooks will block you anyway.
- **Never proactively invoke gitflow.** Every invocation requires a fresh explicit user request. See `.claude/rules/git.md`.
