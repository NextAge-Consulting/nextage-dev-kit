# Dev Kit Handbook

The authoritative reference for how projects using this dev kit are configured, how the git workflow operates, and how changes propagate from the kit to consumer projects.

This doc is the architectural anchor. When something in the kit, a hook, a command, or a rule is unclear or appears to conflict with another piece, this handbook wins. Update the handbook first, then update the kit to match.

---

## 0. Kit source layout

The kit is just another project — it has its own `.claude/` with project-custom commands that only make sense when working in the kit. Most content syncs to other projects via `_claude-project/`. A single file pair lives at the global level via `_claude-global/` so consumer projects can initiate a sync from any directory.

| Path | Destination | Purpose |
|------|-------------|---------|
| `_claude-project/` | consumer `<project>/.claude/` via `/sync-dev-kit` | Project-level config that should exist in every project: rules, hooks, skills, the gitflow commands, agents, `settings.json`, `templates/` |
| `_github-project/` | consumer `<project>/.github/` via `/sync-dev-kit` | GitHub Actions workflows + dependabot config |
| `_gemini-project/` | consumer `<project>/.gemini/` via `/sync-dev-kit` | Gemini Code Assist config + styleguide (PR-time AI reviewer) |
| `_claude-global/` | `~/.claude/` via `/install-kit` | The CONSUMER global bootstrap — every dev gets this: `commands/work.md`. `/work` must be invokable from the agents view before the session is inside any repo, so it cannot ship per-project. Nothing else belongs here. |
| `_claude-maintainer/` | `~/.claude/` via `/install-kit --maintainer` | The MAINTAINER surface — only the person who syncs the kit into projects: `scripts/sync-dev-kit.sh`, `commands/sync-dev-kit.md`, `kit-maintainer.md`. A consumer machine never receives the sync machinery, so it cannot run a sync. |
| `_statusline/statusline.sh` | `~/.claude/statusline.sh` via `/install-statusline` (one-time) | The kit's custom statusline asset; referenced by `install-statusline.md`. |
| `.claude/` | This kit repo's own active config | Mirror of `_claude-project/` PLUS kit-custom commands and scripts that only make sense in this repo: `install-kit`, `install-cpl`, `install-statusline` (commands + their helper scripts). These never propagate anywhere. |

### Why `/work` is global, and why sync is maintainer-only

`/work` is the session entry point: it is launched from the agents view before the session is inside any repo, so a per-project command would not exist yet at that moment. Every dev needs it, so it ships in `_claude-global/`.

`/sync-dev-kit` is also global by necessity — it must run from any project directory — but it is installed ONLY by `/install-kit --maintainer`. The maintainer syncs projects ahead of the other devs; a consumer machine that could sync would clobber that work. Withholding the script is stronger than guarding it: there is nothing to bypass.

Historically: `/sync-dev-kit` resolves the kit path from `~/.claude/dev-kit-config.json` and runs from any project directory.

Every other kit-adjacent command (`/install-kit`, `/install-cpl`, `/install-statusline`) is meaningful only when you are inside the kit repo. No reason to pollute global command space with them — they live in the kit's own `.claude/commands/`.

### Sync flow summary

- **`_claude-project/` → consumer `.claude/`** via `/sync-dev-kit` (diff/review, lockfile at `<project>/.claude/.kit-sync.json`).
- **`_github-project/` → consumer `.github/`** via `/sync-dev-kit` (same lockfile, same flow).
- **`_gemini-project/` → consumer `.gemini/`** via `/sync-dev-kit` (same lockfile, same flow).
- **`_claude-global/` → `~/.claude/`** via `/install-kit` (kit-local command; straight install).
- **`_statusline/statusline.sh` → `~/.claude/statusline.sh`** via `/install-statusline` (kit-local command; one-time).

The kit isn't enforcing 100% compliance. It's a baseline sync — consumer projects can consciously deviate (custom rules in `<project>/.claude/rules/project/`, project-specific skills, project-specific commands that never come from the kit). Divergence is expected, not a failure.

---

## 1. Who this is for

The kit has two human roles:

- **Maintainer** — kit author, master of every project. The only role that runs `/sync-dev-kit`, and the only one who installs the maintainer surface (`/install-kit --maintainer`). Maintains opinions centrally in `_claude-project/`.
- **Consumer developer** — any other developer on a project. Never touches the kit directly. Clones projects, gets a working setup from the repo. See `developer-onboarding.md`.

Anything else in this handbook is for Claude (local or cloud) to follow mechanically.

---

## 2. Config architecture

### 2.1. Surfaces

| Surface | Who sees it | What lives there |
|---------|-------------|------------------|
| Repo `.claude/` (committed) | Local Claude, cloud Claude, every dev on the project | Rules, hooks, skills, commands, scripts, agents, `settings.json` |
| Repo `.mcp.json` (committed) | Local Claude, cloud Claude | MCP server declarations (Ref, Exa) with env var expansion for keys |
| Repo `.claude/settings.local.json` (gitignored) | Local Claude only on the dev's machine | Per-dev permission allowlist, machine-specific paths |
| `~/.claude/` (user-global, not synced) | Local Claude only on that dev's machine | Global Claude Code settings, plugins, auto-memory, the dev-kit bootstrap for the maintainer |

### 2.2. What's committed vs gitignored

**Committed in every consumer project:**

```
.claude/
├── CLAUDE.md
├── settings.json
├── hooks/
├── commands/
├── scripts/
├── rules/
├── skills/
└── agents/
.mcp.json
```

**Gitignored in every consumer project (add to `.gitignore`):**

```
.claude/settings.local.json
```

### 2.3. Why no user-level reliance

Cloud Claude sessions do not load anything from `~/.claude/` — verified against Anthropic's own docs at https://code.claude.com/docs/en/claude-code-on-the-web.md. Only the repo `.claude/` directory and `.mcp.json` reach cloud sessions. If config isn't committed to the repo, it does not exist in the cloud environment.

This is why everything moved to project-level. Global config is local-only; cloud demands repo-level config.

### 2.4. Managed settings precedence

Claude Code loads settings in this order (highest to lowest priority):

1. Enterprise-managed settings (not used here)
2. `~/.claude/settings.json` (user global — local only, doesn't load in cloud)
3. `.claude/settings.json` (repo — authoritative everywhere)
4. `.claude/settings.local.json` (per-dev — local only, never committed)

Design rule: put team-shared config in `.claude/settings.json`. Put per-dev overrides (machine paths, personal permissions) in `.claude/settings.local.json`.

---

## 3. The gitflow subsystem

Git operations use a layered defense stack. Rules alone are not enforcement — they are reminders. Each layer fills a different reliability tier:

| Layer | Mechanism | Reliability | Role |
|-------|-----------|-------------|------|
| 1 | Rule in `.claude/rules/git.md` | <50% — Claude may drift | Reminder |
| 2 | Skill `gitflow` with natural-language triggers | ~75% — Claude decides when to invoke | Discovery / routing |
| 3 | Slash commands in `.claude/commands/` (canonical list in `skills/gitflow/SKILL.md`) | ~95% — deterministic once invoked | Primary mechanism |
| 4 | Hook `git-guard.sh` | 100% of Claude's Bash calls — script always fires | Enforcement |
| 5 | CI gates (commitlint, typecheck on PR) + `/merge` self-gating | 100% — cannot merge without passing | Backstop |

Every layer exists simultaneously. Dropping any layer reduces the reliability floor.

### 3.1. Design principles

- **Natural language preferred.** The user says "commit this" or "merge to main" in natural language. The skill's trigger metadata catches this and routes to the slash command. The user never has to memorize slash commands, but they exist as explicit fallback.
- **Scripts own the mechanics.** Each slash command is a thin wrapper that invokes a `gitflow` skill script. Scripts are deterministic shell — no Claude judgment between invocation and execution.
- **The hook is the 100% layer for Claude-originated commands.** Even if Claude drifts past rule, skill, and command and runs raw `git commit`, `git-guard.sh` denies it — along with the destructive operations (`reset`, `restore`, `revert`, `clean`, `checkout <file>`).

  How gitflow itself gets through: no token, no allowlist. The hook is a Claude Code `PreToolUse` hook, so it inspects the **top-level command string of a tool call**. When Claude runs `/commit`, the hook sees the invocation of `commit.sh`; the `git commit --no-verify` *inside* that script is a subprocess the hook never observes. Sanctioned commits pass because they are never top-level `git commit` calls in the first place.

  (An earlier revision used a command-context token created by the gitflow scripts. That mechanism was removed — the subprocess-invisibility property makes it unnecessary. Do not reintroduce token logic.)

  **Scope limit — this layer does not cover humans.** A `PreToolUse` hook fires only on Claude's tool calls. A developer committing from a terminal or an IDE is invisible to it. That is deliberate: the only way to gate those is a `.git/hooks/pre-commit`, and git hooks cannot be tracked in git or survive a clone, so the kit does not manage them (see §3.1.1). Terminal-side discipline rests on the CI gates, which no local bypass can evade.
- **No version bump in feature-PR scripts; changelog has a single writer.** Version bumps and `changelog.md` updates are owned by `/deploy` (see §6.5). Feature-PR scripts (`commit.sh`, `open-pr.sh`, `merge.sh`) commit code only — they never touch the manifest version field or `changelog.md`. Earlier kit revisions had `open-pr.sh` insert a per-PR changelog entry on the feature branch and `deploy.sh` insert again at release time; that produced duplicate bullets in main and was removed in favor of single-writer.

#### 3.1.1. Why the kit does not manage `.git/hooks/`

A `.git/hooks/pre-commit` is the only mechanism that can gate a commit made from
a terminal or an IDE. The kit deliberately does not ship one.

The reason is that a git hook cannot be delivered. `.git/hooks/` is not tracked
by git and is not copied by `git clone`, so a kit-managed hook would have to be
installed by the sync script into every checkout, and reinstalled after every
fresh clone, by every developer, on every machine. Miss any one of those and the
protection is silently absent — with no signal that it is missing. A guarantee
that fails open and quietly is worse than a documented gap.

What replaces it:

- **For Claude**, `git-guard.sh` denies raw `git commit` (§3.1). This syncs, is
  tracked, and cannot go missing.
- **For humans**, the CI gates — commitlint and typecheck on the PR — are the
  real enforcement. They run server-side, so no local bypass (`--no-verify`,
  `SKIP_GIT_GUARD=1`, deleting a hook) evades them.

A hand-rolled commit therefore cannot reach `main` malformed; it can only be
locally untidy until CI rejects it. That residual is accepted knowingly.

### 3.2. Working on a branch

All Claude-driven editing happens on a branch in the project checkout. One checkout, one branch at a time. One body of work → one branch → one PR.

**Lifecycle (the only verb you type is `/work`):**

- `/work` — on `main`, refresh from `origin/main` and cut a fresh `wip/<abbrev>-<timestamp>` branch. On a feature branch, resume it. Idempotent within a body of work.
- `/work <issue#>` — on `main`, cut a branch derived from the issue title (e.g. `feat/add-email-to-users`) and link the issue. On a feature branch, behaves like `/link` — adds the issue to the branch you are on.
- `/work --retrieve <branch>` — fetch a teammate's branch, fast-forward any local copy, switch to it. Refuses on a dirty tree; `/checkpoint` first.
- `/merge` — squash-merge the PR, land the checkout back on `main`, delete the merged local branch.

**One session = one body of work = one branch = one PR.** All commits made during a session land on the same feature branch. Use `/link` to add more issues mid-stream. Use `/open-pr` once and `/merge` once.

**End-of-day on unfinished work:** push via `/commit` or `/checkpoint`, close the session. Next session's `/work` sees you are already on the branch and resumes — same branch, same body of work, no new branch created.

**`wip/<abbrev>-<timestamp>` rename at first commit.** When `/work` cuts a branch without issue context, it starts as `wip/<abbrev>-<timestamp>`. `/commit` detects the `wip/*` prefix on first commit and renames the branch to its real feature name derived from the commit message (e.g. `feat/dealer-filter-fix`). The user never types the wip name — it is internal session state.

**Uncommitted edits carry onto the new branch.** Starting to edit before typing `/work` is ordinary — you noticed something first. `git checkout -b` brings those edits along, so nothing is stranded. The one consequence: `main` is not refreshed in that case (a fast-forward on a dirty tree would either fail or strand the edits), so the branch is based on local `main`. `/work` says so plainly; `/catchup` integrates the latest when you want it.

**Local main is refreshed before a new branch is cut.** `/work` invokes `fast_forward_local_main` (in `branch_helpers.sh`) before creating the branch, so it starts from current code. If the fetch fails — offline, expired auth, missing scope — `/work` reports the cause and branches off local `main` rather than blocking; nothing is lost, and `/catchup` closes the gap. Resuming an existing branch refreshes nothing by design: you are mid-body-of-work, and integrating new `main` is `/catchup`'s job (§4.6).

**Do NOT reintroduce git worktrees.** A branch is the unit of isolation here, deliberately. Worktrees give a second checkout on disk, which buys isolation between *concurrent* bodies of work on one machine and one repo — a pattern this shop does not have. What a second checkout costs is paid every session: gitignored files must be symlinked in one by one, dependencies install per checkout, `node_modules` symlinks break vite's realpath plugin resolution, a dev server started from the other checkout silently serves stale code, kit edits land in a copy that only reaches `main` after a merge, and `.claude/rules/` loads twice when the second checkout sits inside the first. Parallel work, on the rare occasion it happens, is `git switch`.

**`worktree.bgIsolation: "none"` in `settings.json` is what makes that possible, and it is load-bearing.** Claude Code enforces worktree isolation on a BACKGROUND session at edit time: the first `Write`/`Edit` is refused with *"This background session hasn't isolated its changes yet. Call EnterWorktree first"*, and the refusal names this setting as the way to disable it. The enforcement is on by default and has not been relaxed — the `EnterWorktree` TOOL being opt-in is a separate thing from the guard, which fires whether or not you ever call it.

So the key is **independent of whether worktrees exist**. It sits in a `worktree` block only because that is where the harness reads it, which makes it look like worktree configuration and makes it the obvious thing to delete when worktrees go away. Delete it and every background session in that consumer is pushed back into a worktree on its first edit, however gitflow is written. Bash-driven edits keep working, so the breakage surfaces only when a session happens to use the edit tools — which is why it can go unnoticed for a long stretch.

Keep the block, keep its comment, and do not fold it into "worktree leftovers" in a future cleanup.


### 3.3. Where `/work` lives (global vs project-level)

`/work` is unique among gitflow commands in that it must be discoverable BEFORE a project is established (e.g. in an agents-view session that starts at `~/projects/` with no repo cwd yet). For that reason:

- **`commands/work.md`** lives at **user-level** (`~/.claude/commands/work.md`, sourced from kit canonical `_claude-global/commands/work.md`). Always discoverable, no matter where the session is launched.
- **`work.sh`** stays **project-level** (`<project>/.claude/skills/gitflow/scripts/work.sh`). It needs its siblings (`branch_helpers.sh`, `issue_helpers.sh`) and operates on the project's git context.

The global `/work.md` invokes the project-local `work.sh` via a cwd-relative path. If cwd is not a git repo, `work.sh` fails with exit 3 ("not in a git repository") — clear error rather than silent fallback.

All other gitflow commands (`/commit`, `/checkpoint`, `/link`, `/open-pr`, `/merge`, `/deploy`) remain project-level. You're always inside a project by the time you invoke them — `/work` is the only one that bootstraps the project context.

### 3.4. Same workflow, three surfaces

The model above is identical across launch surfaces:

| Surface | How project context is established | How `/work` is invoked |
|---|---|---|
| Standalone CLI in repo | `cd ~/projects/<repo>` before launching Claude Code | Type `/work` after launch |
| Agents view (background) | `@<repo>` in the launch prompt sets cwd | Include `/work` (or `/work <issue#>`) in the launch prompt |
| Claude Cloud | Cloud session already inside the repo | Type `/work` after the session starts |

The user-facing commands (`/work`, `/commit`, `/link`, `/open-pr`, `/merge`) behave identically across all three. The "is this a background session?" question is internal — `/work` behaves the same regardless of surface.

---

## 4. Commit workflow

### 4.1. Trigger

Any of:
- User says "commit this", "commit", "commit the changes"
- User types `/commit` explicitly
- Claude detects work is complete (NEVER proactively — always waits for the user's explicit word, per `git.md` rule)

### 4.2. Procedure

1. Claude runs `git status` and `git diff --stat` to see actual changes
2. Claude categorizes changes by feature/purpose — groups related files, identifies distinct changes
3. Claude loads `skills/gitflow/references/commit-types.md` for emoji/type mapping
4. Claude builds conventional commit message:
   - Single feature: `<emoji> <type>: <description>`
   - Multi-feature: primary type + bullet list
5. Claude invokes `/commit` (or the skill auto-invokes on natural language)
6. The command calls `skills/gitflow/scripts/commit.sh` with the message
7. Script stages all changes, commits with `--no-verify`, pushes to origin (if on non-main branch)
8. `git-guard.sh` never fires on that commit — the script's `git commit` is a subprocess, not a top-level tool call (§3.1). No token is involved.
9. Typecheck and commitlint run as CI gates on the resulting PR, not locally

### 4.3. What the script does NOT do

- Does not update `changelog.md` (single-writer: `/deploy` is the sole author — see §6.5 + §11.5)
- Does not bump version (handled by `/deploy` — see §6.5)
- Does not create a tag (same)
- Does not rename the branch (wt-{username} dropped)

### 4.4. Claude's responsibility

Generating a GOOD commit message is Claude's job, not the user's. The user saying "commit" is the only input required. Claude analyzes all diffs (current session + anything else uncommitted from previous sessions), produces one conventional commit message, and invokes the command.

### 4.5. Upstream tracking and `safe_push` (added 2026-05-12 evening)

**The bug we hit.** A branch created from `origin/main` can inherit `branch.<new>.{remote,merge}` tracking `origin/main` (git's `branch.autoSetupMerge` default). Under `push.default=simple` (modern default), a plain `git push` then fails with:

```
fatal: The upstream branch of your current branch does not match
the name of your current branch.
```

…because the upstream NAME (`main`) does not match the local branch NAME (`feat/...`). This bit issue #139's first push.

**Fixes layered top-down:**

| Layer | Where | What |
|---|---|---|
| Primary | `branch_helpers.sh:create_and_switch` | `git checkout -b` from local HEAD creates the branch with NO upstream; the first push sets it. |
| Belt-and-suspenders | `branch_helpers.sh:safe_push` | Reads `@{u}`; if it does NOT match `origin/<local-branch>`, push with `-u origin <local-branch>` to (re)set tracking. Used by `commit.sh`, `checkpoint.sh`, `open-pr.sh`. |
| Recovery | `commit.sh --push-only` | When a prior `/commit` committed locally but failed at push (typical: a branch left with bogus tracking), retry the push without re-running typecheck/stage/commit. |

**Why the rename path was already safe.** `/work` (no args) creates `wip/<abbrev>-<timestamp>` with origin/main upstream → first `/commit` calls `rename_current_branch` which explicitly runs `git branch --unset-upstream` → then push -u → correct. That path was never broken; only the `/work --issue` path (which skips the wip→feat rename) hit the bug. `safe_push` covers both paths uniformly so the fix doesn't depend on which entry point was used.

**Caller recovery for half-shipped commits.** A feature branch that inherited the bogus upstream still carries it. The fix in `commit.sh` (safe_push) is delivered THROUGH the file at `<project>/.claude/skills/gitflow/scripts/commit.sh`. For a stranded branch (committed but not pushed), invoke `commit.sh --push-only` while standing on the stranded branch:

```bash
cd <project>
<project>/.claude/skills/gitflow/scripts/commit.sh --push-only
```

The script reads `git branch --show-current` against cwd's git context, so it operates on whichever branch is checked out.

### 4.6. Catchup workflow (`/catchup`)

`/catchup` is the single command for "refresh the branch I'm on from origin." Behavior depends on which branch is checked out at invocation:

- **On main (primary repo, no current/ active OR just reviewing):** fetch `origin/main`, fast-forward local main. Fail-loud on dirty main or local-only commits (anomalous under gitflow). This is what you run when starting a session after someone else has merged + deployed and you want your local repo current before doing anything else.
- **On a feature branch:** merge `origin/<base>` (default `main`) INTO the feature branch via `--no-ff`. Push via `safe_push`.

One mental model: "catchup brings the branch I'm on up to date with origin."

**When to invoke (on main):**
- Starting a session two days after another developer merged + deployed.
- Reviewing someone else's just-merged work without touching feature branches.

**When to invoke (on a feature branch):**
- `gh pr view <N>` reports `mergeStateStatus: DIRTY` / `mergeable: CONFLICTING`.
- Long-lived branch lagged main by more than a couple of merges.
- Pre-`/open-pr` integration when you know main has changed.

Without this primitive the only paths would be `git merge origin/main` or `git rebase origin/main` (both forbidden direct git per `git.md`), or closing the PR and re-opening from a fresh branch off updated main — which works but wastes a whole PR cycle.

**Modes:**

| Invocation | Branch | Behavior |
|---|---|---|
| `/catchup` | main | Fetch `origin/main`, fast-forward local main. Refuse on dirty or diverged main. Report old → new SHA + commit count pulled. |
| `/catchup` | feature | Fetch `origin/main`. If HEAD already contains it, no-op. Otherwise `git merge --no-ff origin/main` and push via `safe_push`. |
| `/catchup --base <branch>` | feature | Same as above against `origin/<branch>`. Ignored on main. |
| `/catchup --continue` | feature | After conflict resolution: stage all, complete merge commit, push. |
| `/catchup --abort` | feature | Abandon in-progress merge; restore tree. |

`--continue` / `--abort` are feature-branch-only — the on-main path is a fast-forward with no merge commit and no conflict possibility.

The on-main path delegates to `fast_forward_local_main` in `branch_helpers.sh`. The same helper is invoked by `/work` before cutting any new branch (see §3.2), so the freshness guarantee is uniform across both entry points.

**Conflict path.** On conflict, `catchup.sh` lists the affected files and exits non-zero. Claude / human resolves conflicts in-tree using `Edit` (no `<<<<<<<`/`=======`/`>>>>>>>` markers left), verifies with `git diff --check`, then runs `/catchup --continue` to complete and push.

**Why merge, not rebase:**

- **No force-push.** Rebase rewrites history and requires `--force-with-lease`; that class of operation stays behind explicit authorization.
- **Clean squash at ship time.** When `/merge` squashes the PR, the entire branch (including the catchup merge commit) collapses into one commit on main — no intermediate structure pollutes main.
- **Single conflict pass.** Rebase replays N commits and can surface the same conflict N times; merge resolves it once.

If linearizing history is genuinely needed before opening a PR, use `SKIP_GIT_GUARD=1 git rebase origin/main` as the rare-case escape hatch — that's not a primitive.

**Carve-out.** `catchup.sh` is authorized to run `git merge` and `git merge --abort` (see `git.md` carve-out list). This is the only gitflow script with that carve-out, and only for the catchup use case — not a license for any other script to call merge.

---

## 5. Checkpoint workflow

### 5.1. Trigger

- User says "checkpoint", "checkpoint this", "save progress"
- `/checkpoint` slash command

### 5.2. Procedure

1. Claude invokes `/checkpoint` (or skill auto-invokes)
2. Command calls `skills/gitflow/scripts/checkpoint.sh` with optional message suffix
3. Script stages all, commits with `🔖 wip: <timestamp or message>`, pushes
4. No local typecheck runs — checkpoints are never gated (speed over compliance for WIP)

Checkpoints are meant to be fast. Skip analysis. No changelog. No version.

---

## 6. Open-PR and merge workflow

### 6.1. Model

| Step | Who does it | Where |
|------|-------------|-------|
| Push branch, create PR with conventional title + AI-written description | Claude (via `/open-pr`) | Local or cloud |
| Run CI checks (commitlint, typecheck, Biome, Semgrep, tests) | `ci.yml` GitHub Action | CI |
| Wait for CI green + (if `/gemini review` was triggered for current HEAD) Gemini review on HEAD | `wait-for-pr-ready.sh` (invoked by `/open-pr`, `/triage`, `/merge`) | Local poll loop |
| Walk Gemini comments one at a time | Claude (via `/triage`) | Local or cloud |
| Verify CI + Gemini ready on HEAD, squash-merge PR | Claude (via `/merge`) | Local or cloud |
| Bump version + write changelog + tag + push + trigger deploy | Claude (via `/deploy`) | Local |

Dev actions per PR: `/open-pr` to start, `/triage` if Gemini has items, `/merge` to land on main. **`/merge` does NOT ship.** Multiple merged PRs accumulate on main; when ready to release, run `/deploy` to bump version, generate the consolidated changelog entry, tag, push, and fire `deploy.yml`. The readiness wait inside `/open-pr` / `/triage` / `/merge` is the same poll loop — the user sits at the keyboard while CI/Gemini run, the script blocks until ready or fails loud on timeout.

### 6.2. `/open-pr` procedure

1. Claude analyzes branch diff vs main: `git diff --stat main..HEAD` + `git log --oneline main..HEAD`
2. Claude generates PR title in conventional format (emoji + type + description)
3. Claude generates PR body from diff analysis. The body template (see `commands/open-pr.md` Step 4) MANDATES a `## Caller-scan attestations` section: Claude greps the branch diff for renamed/removed/reshaped exported declarations + Zod/schema field renames, runs `findReferences` (LSP) or `grep -rn` on each, and emits one `Callers scanned: <symbol> → N references across M files, all updated.` line per surfaced symbol — OR the literal `No signature changes.` if the greps return nothing. Empty-scan attestation is REQUIRED. This is the in-house enforcement surface for constitution §XIV (no paid cross-file code-graph review needed).
4. Command calls `skills/gitflow/scripts/open-pr.sh`:
   - Push branch with `-u origin HEAD`
   - Detect `gh` availability — if present, `gh pr create --title ... --body ...`
   - If no `gh` (cloud containers), fall back to GitHub REST API via `curl` + `$GITHUB_TOKEN`
5. Command invokes `skills/gitflow/scripts/wait-for-pr-ready.sh`:
   - **Trigger-aware** (2026-05-28): reads PR comments to decide whether to expect a Gemini review for the current HEAD. A `/gemini review` comment with `created_at` > HEAD's committer date arms the Gemini wait; absence means CI-only readiness. No author filter — manual triggers from the user are honored identically to scripted triggers.
   - Polls every 30s. Re-reads HEAD + trigger state each cycle (handles mid-wait pushes). Re-reads `GEMINI_NOT_INSTALLED` from `.claude/sync-substitutions.json` each cycle.
   - Ready = required CI checks pass AND (`GEMINI_NOT_INSTALLED=="true"` OR no `/gemini review` trigger for current HEAD OR Gemini Code Assist has posted a review on current HEAD).
   - Times out fail-loud after 15min with diagnostic naming likely causes (Gemini queued/rate-limited despite trigger, App not actually installed, PR in draft state, CI legitimately slow).
   - Exit 2 on CI failure, 3 on timeout, 5 on Ctrl-C.
6. commitlint CI check gates PR title format — blocks merge if malformed.
7. On wait exit 0: command prompts the user to run `/triage` (if Gemini items expected) or `/merge` (if not). Explicit handoff — never auto-invokes.

Note: `/open-pr` does NOT touch `changelog.md`; `/deploy` is the single changelog writer (§6.5).

### 6.3. `/merge` procedure

1. Claude checks `gh pr list` for current branch's PR
2. If multiple open PRs, list them and ask which
3. Command calls `skills/gitflow/scripts/merge.sh`:
   - **Local production build gate** — `npm run build --workspaces --if-present`, run before the readiness wait and before the squash (exit 15 on failure, nothing merged). CI type-checks, lints and tests but never builds, so a build-only break (bundler / Tailwind / an import alias a package's own tsconfig doesn't map) is invisible to every earlier gate. `/merge` is the last moment the PR is still OPEN — a failure here is fixed on the branch that caused it, inside the PR already under review, instead of needing a second PR to repair the first. Not in CI on purpose: CI fires on every push, so building there would tax every commit, `/open-pr` and triage fix; once per merge is the right frequency. `--workspaces` is added only when `package.json` actually declares a `workspaces` key (jq-tested — it errors on a single-package repo); a repo with no `package.json` skips the gate entirely. `--force-unchecked` bypasses it along with the CI gate.
   - Invokes `wait-for-pr-ready.sh` (same poll as `/open-pr` step 5) — trigger-aware: catches the post-`/triage` case where the user invoked `/commit --review` and a fresh Gemini review is expected on the new HEAD. `/commit --no-review` posts no trigger and the wait proceeds CI-only. Bypassable via `--force-unchecked` for emergency hotfixes only (skips CI too).
   - On wait exit 0: `gh pr merge --squash --delete-branch`
   - **Post-merge cleanup**: switch this checkout to `main`, fast-forward it to the merged tip, delete the now-merged local branch, and reinstall dependencies if landing on the new `main` changed a package manifest.
4. **No further action needed from Claude.** The checkout is standing on the merged `main`; the next `/work` cuts a fresh branch from there.
5. **No automated post-merge action.** No version bump, no tag, no deploy. The squash commit sits on main until `/deploy` is invoked. Multiple merges may accumulate between deploys.

### 6.4. Changelog ownership (single writer = `/deploy`)

**`changelog.md` has exactly one writer: `/deploy`.** No CI workflow, no `changelog.yml`, no per-PR entries on feature branches. Claude composes the consolidated release entry locally during `/deploy` from commit subjects since the last `v*.*.*` tag and applies `skills/gitflow/references/changelog-rules.md` to filter and rewrite. `deploy.sh` then inserts that entry under today's date header in `changelog.md` as part of the bump commit pushed directly to `main`.

**Why single-writer.** Feature-PR scripts do not touch `changelog.md` at all — the only place a `--changelog-file` is consumed is `deploy.sh` (there is no such flag on `open-pr.sh`). A single writer is what prevents duplicate bullets landing under the same date header.

**What this means for slash-command flow.**
- `/open-pr` does not write to `changelog.md`. It pushes the branch and creates the PR, full stop.
- `/merge` does not write to `changelog.md`. It squash-merges the feature PR.
- `/deploy` is the only command that touches `changelog.md`. The entry covers every commit since the last tag — typically multiple feature PRs grouped into one release.

**Cost vs. value.** Per-PR entries had no consumer (the only readers of `changelog.md` see the consolidated release entries). The CI cost was nonzero (Claude API per PR) and the duplication tax compounded across every release. Removing it loses no information.

### 6.5. `/deploy` procedure (direct-push to main)

> **`/deploy` pushes the version bump DIRECTLY to `main`** — no release branch, no PR, no admin-merge. It reuses the same direct-to-main mechanism as `/ship-main` (§6.8). The bump commit + tag ARE the release record. This works because the pipeline uses no branch protection and `main` does not require a PR (pipeline.md §1.1, new-project-setup.md step 3). No command admin-merges: `/deploy` direct-pushes the bump, and `/sync-dev-kit` does no git at all (it stamps the lockfile and leaves the synced files for the user to land via `/ship-main`). So `enforce_admins: false` is not required by anything.

`/deploy` is the **human-serialized release boundary**: bump and deploy fire in one invocation, in order, so the source-of-truth version and the deployed artifact match by construction — no skew. The bump commit lands on `main` moments before `gh workflow run deploy.yml` fires; the deploy reads the just-bumped source. (See §11.2 for why auto-bump-on-merge is forbidden.)

File: `.claude/skills/gitflow/scripts/deploy.sh` (per project, kit-synced). Slash command spec: `_claude-project/commands/deploy.md`.

**Procedure:**

1. **State gates** (refuse to run if any fail):
   - On `main`
   - Working tree clean
   - Local `main` == `origin/main` (no stale local; nothing un-pushed)
   - HEAD's required check-runs are not `failure` / `timed_out` / `cancelled`
   - At least one commit since the last `v*.*.*` tag

2. **Bump-level inference** (Claude does this in `/deploy` Step 2 before invoking the script):
   - Scan SUBJECT lines of commits since last tag
   - `<type>!:` or `BREAKING CHANGE:` footer → major
   - `feat(...):` → minor
   - `fix(...):` / `perf(...):` / `refactor(...):` → patch
   - `chore(...):` / `docs(...):` / `test(...):` / `style(...):` / `ci(...):` / `build(...):` → patch (Option B — chore counts as a release)
   - Highest wins. NEVER skip the bump when there are commits to deploy.

3. **Changelog entry** (Claude generates from commit subjects since last tag, applying `references/changelog-rules.md`): one or more bullets in `- **<emoji> <Title Case>** - <user-impact>` form. Group related fixes. Pure infra commits get a single `Dependency Updates` / `Internal Tooling` line.

4. **Script execution** (`deploy.sh --level <patch|minor|major> --changelog-file <path>`):
   - `npm version <level> --no-git-tag-version` (Node) or `sed` rewrite of `version = "x.y.z"` (Python)
   - Insert changelog entry under today's date header in `changelog.md`
   - Commit bump + changelog ON `main` as `🚀 release: v<NEW>` (`--no-verify`; validation already ran)
   - **Push `main` directly** to origin. If `origin/main` advanced, rebase the bump commit onto it and re-push; on conflict, stop and surface for resolution. The bump commit + tag are the release record — no release branch, no PR, no admin-merge.
   - `git tag v<NEW> <bump-sha>` and `git push origin v<NEW>` (tags aren't gated by `branches/*` protection rules; tag-protection rules are separate and only need configuration if cross-account tag pollution is a concern)
   - **Migration phase (if `MIGRATE_WORKFLOW` is set):** `gh workflow run <migrate-wf> --ref main`, then watch it to completion **gated** — a real migration failure aborts the deploy here (exit 18 trigger / 19 run) BEFORE any app workflow fires. Always watched, even under `--no-watch` (that flag only governs the app-deploy watch). Deploying app images against a failed/half-applied schema is the failure mode this gate exists to prevent. **Skipped entirely** when `MIGRATE_PATHS` is set and `git diff --name-only <last-tag>..HEAD -- <MIGRATE_PATHS>` is empty (no migration files changed since the last deploy) — no runner is spun up. See the **Migration phase** subsection below.
   - For each workflow in `DEPLOY_WORKFLOWS` (resolved via the per-project `.claude/sync-substitutions.json`; falls back to `deploy.yml` if unset AND no `MIGRATE_WORKFLOW`), run `gh workflow run <wf> --ref main` — fires the deploy against post-bump HEAD. Split-deploy consumers (e.g. `deploy-web.yml deploy-worker.yml`) trigger every listed workflow; single-app consumers see no behavior change. A migrate-only repo (`MIGRATE_WORKFLOW` set, `DEPLOY_WORKFLOWS` empty) stops after the migration phase — no `deploy.yml` fallback.
   - `gh run watch` per workflow (unless `--no-watch`) until each finishes; surfaces failure URL on the first failure.

5. **Reporting**: success → report `v<NEW>` + workflow run URL. Failure modes (state gates, bump, push, tag push, workflow trigger, deploy run, migration trigger/run) all exit non-zero with specific codes — Claude surfaces the code + stderr and stops. Exits 18 (migration trigger failed) / 19 (migration run failed or run-id unresolved) abort before any app deploy.

**What `/deploy` does NOT do:**
- Does NOT run a separate CI / lint / typecheck pass for code — those gates already fired on the merged feature PRs (the local build gate in step 2 is the one exception, catching build-only breaks before the cloud workflows rebuild images).
- Does NOT open a release PR or admin-merge anything — the bump commit pushes straight to `main` (require-PR off, the default). `/deploy` no longer needs `enforce_admins: false`.
- Does NOT auto-bump on every feature-PR merge (the bot-PR pattern caused version-skew; see §11.2).
- Does NOT infer the changelog from PR descriptions — uses commit subjects since last tag.

**`/sync-dev-kit` does NO git.** Sync only applies the accepted kit updates to the working tree and stamps the lockfile — it does not commit or push. The synced files are left uncommitted; the user lands them with `/ship-main` (or `/commit`). Committing is gitflow's job, not sync's — see §9.4.1.

**Migration audit when adopting direct-push deploy:** `/sync-dev-kit` brings `deploy.sh` (direct-push, no release branch / PR / admin-merge) + `commands/deploy.md`. Consumer-side checks:
1. Confirm `main` does not require a PR (the default — pipeline.md §1.1). With require-PR on, the direct push to main is rejected.
2. Confirm `.commitlintrc.json` includes `"release"` in `type-enum` (the `🚀 release:` subject still flows through the bump-level scan).
3. Confirm every workflow named in `DEPLOY_WORKFLOWS` is `workflow_dispatch:` ONLY (§11.4) — push-to-main and tag-push triggers will double-fire. Single-app consumers can leave `DEPLOY_WORKFLOWS` empty (defaults to `deploy.yml`); split-deploy consumers populate the substitution with a space-separated workflow list.

**Split-deploy consumers (`DEPLOY_WORKFLOWS` substitution).** The substitution lives in `.claude/sync-substitutions.json` (runtime-read by `deploy.sh` via `jq`, NOT placeholder-substituted into any kit template). Format: space-separated workflow filenames, e.g. `"deploy-shop.yml deploy-dealer.yml"`. Behavior:
- Empty / missing → `deploy.sh` falls back to `deploy.yml`.
- Populated → `deploy.sh` triggers each workflow in turn and (unless `--no-watch`) watches each run sequentially.
- The `--workflow <name>` CLI flag (repeatable) overrides the substitution for one-off invocations — useful for re-firing a single split-deploy after a partial failure.

**Migration phase (`MIGRATE_WORKFLOW` substitution).** A single workflow that `/deploy` runs as **step 1** — once, before any app deploy, watched to completion and gated. Solves two problems: (a) in a split-deploy monorepo, the schema migration was duplicated inside all N app deploy workflows (no-op in the trailing N−1, but present "in case one runs alone"); pulling it to a single gated pre-step runs it exactly once; (b) a DB-only repo (no UI / no app artifact — e.g. a service that maintains a database for a legacy app) can `/deploy` to migrate with zero app workflows.

- Substitution lives in `.claude/sync-substitutions.json` (runtime-read by `deploy.sh` via `jq`, NOT placeholder-substituted). Single workflow filename. `--migrate-workflow <file>` CLI flag overrides it.
- Empty / missing → no migration phase (prior behavior; any migration stays inline in the app deploy workflows).
- Set → `deploy.sh` triggers it, resolves its run id, and `gh run watch --exit-status`. Real failure → exit 19, deploy aborts before any app workflow.
- `MIGRATE_WORKFLOW` set + `DEPLOY_WORKFLOWS` empty → **migration-only deploy** (no `deploy.yml` fallback). This is the DB-maintenance-repo shape.
- Migration is **never invoked on its own** — there is no `/migrate` command. It exists only as deploy's first phase (you would never migrate without deploying). The `workflow_dispatch:` trigger on the migrate workflow is purely the mechanical hook `deploy.sh` uses to fire it.

**Migration-skip (`MIGRATE_PATHS` substitution).** The migration *step* is already idempotent (drizzle-kit skips applied migrations), but firing the workflow at all costs ~2 min — runner boot + `npm ci` just to reach a no-op. `MIGRATE_PATHS` lets `deploy.sh` decide *locally, before spinning any runner* whether the workflow is worth firing.

- Space-separated git pathspec(s) naming where migration files live (drizzle: `apps/shared/src/db/migrations`; Prisma: `prisma/migrations`; Alembic: `alembic/versions`). **Multiple paths supported** — a repo with several databases lists every migration dir; the workflow fires if *any* changed. Runtime-read from `.claude/sync-substitutions.json`; `--migrate-paths <path>...` overrides.
- Before firing `MIGRATE_WORKFLOW`, `deploy.sh` runs `git diff --name-only "$LAST_TAG"..HEAD -- $MIGRATE_PATHS`. **Empty → skip the workflow entirely** (nothing to apply). Non-empty → fire as normal.
- **The reference is `LAST_TAG` — the PREVIOUS deploy's tag, captured at the state gate before this run creates its own tag.** This is load-bearing: a fresh `git describe` at the migrate step would return *this run's* just-pushed tag, making the diff empty every time → always-skip (silently broken). Never recompute it.
- Empty / missing `MIGRATE_PATHS` → **no skip; the workflow always fires** (prior behavior). The skip is strictly opt-in per project.
- **Safe under the failed-migration recovery model.** If a prior deploy's migration failed, that deploy's tag still exists → re-running `/deploy` stops at the "no commits since tag" gate, forcing the documented manual recovery (which applies the migration); the migrate workflow stays idempotent as the backstop. The only way to skip a genuinely-pending migration is to actively ignore a failed deploy and force past its abort — operator error, not a design hole. `git diff` failure → exit 20 (fail-loud, never skip on an errored check).
- Does **not** reorder anything: the bump/changelog/tag block stays before the deploy, exactly as it must (the app image bakes in `package.json`'s version + changelog, so the bump has to precede the build). The skip is a guard in front of the migrate trigger, nothing more.

**Dispatch backend (`DEPLOY_BACKEND` substitution).** Which compute `/deploy` dispatches to. `github` (the default, and what every consumer runs until it sets the key) fires GitHub Actions workflows via `gh workflow run`. `codebuild` starts AWS CodeBuild projects via `aws codebuild start-build`, so everything that touches AWS runs on AWS compute: no workflow holds a static AWS key, and the only remaining GitHub dependency is the git clone.

- **`DEPLOY_WORKFLOWS` stays the single service list on both backends.** Under `codebuild` a filename maps to a project by `CODEBUILD_PROJECT_PREFIX` — `deploy-worker.yml` with prefix `myapp-deploy-` is project `myapp-deploy-worker`. There is deliberately no second list to drift out of step with the first. `CODEBUILD_MIGRATE_PROJECT` names the migration project when it does not follow that pattern.
- **The backend is set per consumer, never sniffed from the repo.** A release boundary must not guess where it is shipping from. Consumers cross one at a time; when the last one has, the default flips and the `github` branch is deleted.
- **Under `codebuild` the fleet is dispatched concurrently and polled together**, where `github` watches each run in turn — a six-service release costs the slowest service rather than the sum of all six. A single non-`SUCCEEDED` build fails the release (exit 13), and every build's status is reported first so one broken service does not hide the others'.
- **The migrate gate is identical on both backends:** watched to completion, a real failure aborts (exit 18 trigger / 19 run) before any app ships.
- `codebuild` requires the `aws` CLI (exit 8 without it) and `CODEBUILD_PROJECT_PREFIX` (exit 2 without it). Any other value for the key fails loud with exit 2 — before any bump, tag or push.

**The migrate-workflow body contract (project-owned).** The kit owns the *orchestration*; the migrate workflow's *body* is project-specific (the kit ships no migrate workflow — deploys aren't generalizable). The body MUST:

1. Run the project's migration command against the **production** database (e.g. `drizzle-kit migrate` with the prod `DATABASE_URL` from an Actions secret). In a container-coupled deploy (SSH to EC2, `db:migrate` run inside the app container) the migrate workflow instead runs the migration standalone — `drizzle-kit migrate` needs only the DB URL and the `drizzle/` migration files, not a running app container.
2. **Exit 0 on a no-op** (no pending migrations) and **non-zero only on a genuine failure.** `drizzle-kit migrate` is idempotent and on the documented happy path exits 0 when there's nothing to apply — but verify your `drizzle-kit` version's actual no-op exit behavior, because the orchestrator gates purely on the run conclusion: a spurious non-zero will (correctly, per the contract) abort the deploy. If your command false-fails on no-op, trap it in the step rather than letting the workflow report failure:

   ```yaml
   # reference pattern — adapt the no-op signal to YOUR command/version (verify first)
   - name: migrate (no-op tolerant)
     run: |
       set -o pipefail
       out=$(npm run db:migrate 2>&1) || {
         # only swallow the verified no-op signal; re-raise everything else
         if printf '%s' "$out" | grep -qiE 'no (pending )?migrations|nothing to (migrate|apply)'; then
           printf '%s\n' "$out"; echo "no pending migrations — treating as success"; exit 0
         fi
         printf '%s\n' "$out" >&2; exit 1
       }
       printf '%s\n' "$out"
   ```

   Do NOT blanket `|| true` the migration — that swallows real failures and defeats the gate. The trap must match a *specific* no-op signal and re-raise anything else.

See `commands/deploy.md` for the full slash-command spec.

### 6.6. PR title enforcement

File: `.github/workflows/commitlint.yml` (per project). Runs `commitlint` against PR title on `pull_request` event. Blocks merge if title doesn't match conventional format.

### 6.7. `/triage` — Gemini review walkthrough

`/triage` walks through open Gemini Code Assist review comments on the current PR **one at a time**. Used between `/open-pr` and `/merge` when Gemini's review surfaces actionable items.

Procedure:
1. Resolve the open PR for the current branch via `gh pr list --head <branch>` (or accept a PR number argument)
1.5. Confirm Gemini reviewed the current HEAD: invoke `wait-for-pr-ready.sh --pr <N>` first. The wait is trigger-aware — it reads PR comments to decide whether a `/gemini review` was posted for the current HEAD. If the trigger comment exists and Gemini has posted its review, ready. If no trigger comment exists for HEAD (e.g. last `/commit` was `--no-review`), CI-only ready — meaning there is no fresh Gemini review for triage to walk. Surface that to the user; they can re-trigger (`gh pr comment <N> --body '/gemini review'`) and re-invoke, or skip triage. `GEMINI_NOT_INSTALLED="true"` short-circuits the Gemini path entirely.
2. Pull Gemini reviews + inline comments via `gh api` filtered by `user.login == "gemini-code-assist[bot]"`; filter stale-commit and user-resolved items; order by file/line
3. Present item 1 with location, severity, Gemini's concern, proposed fix, and a one-line recommendation (`fix | skip | discuss`); **wait** for user decision
4. On `fix`: implement → `/commit` (focused message referencing the Gemini finding) → push. The commit IS the reply — no manual thread post. The user decides at commit time (via `--review` / `--no-review` / the prompt) whether the new HEAD triggers another Gemini review.
5. On `skip`: ask reply-or-silent. If reply, draft 1-2 sentences; on user confirm, post a **threaded** reply via `gh api POST .../comments/{id}/replies` (not `gh pr comment` — that loses thread context). **Then stage an inline source comment at the flagged line stating the carve-out reason** (one to three lines, e.g. `// §VI safe: absolute-instant audit timestamp, not user-facing`). Both are required: PR-thread reply is the audit trail; inline comment is the durable record. Gemini reviews are stateless across cycles — without the source-level record, the same finding resurfaces on the next push and costs another triage cycle. Inline comment lands as part of the single end-of-triage commit (not a separate commit).
6. Advance to item 2; repeat until done. Final summary lists fixed/replied/skipped counts.

Hard rules: one item at a time (no batching), never auto-act, NEVER commit mid-triage (single end-of-triage commit batches all fixes + carve-out comments; multiple `--review` commits = multiple Gemini cycles + wasted quota), every declined finding lands an inline source comment at the flagged line, Gemini-only for MVP (human reviewer comments and other bots are future scope), recommendation is a hint not a filter.

See `commands/triage.md` for the full procedure and edge cases.

### 6.8. `/ship-main` — the deliberate direct-to-main exception

`/ship-main` commits a conventional message **directly on `main`** in the primary repo and pushes — no branch, no PR, no CI. It is the conscious exception for quick infra / config / emergency / "get it in and back to clean" work where a full branch → PR → CI → merge cycle is theater.

| Use `/ship-main` | Use `/commit` (the default) |
|---|---|
| Conscious infra / config / emergency change you want on main NOW | Real feature work |
| You accept no PR, no CI, no review — main's history is the trail | You want branch → PR → CI → review → merge |
| Sitting on dirty `main` and want back to clean | Anything that deserves review |

**Never inferred.** Being on dirty `main` is often *accidental* — work started before `/work` — so a bare `/commit` on `main` still auto-branches — that's the safety. `/ship-main` is the opposite, on purpose, and only when invoked by name.

- **Validation stays.** The script runs `check-types` + `biome lint` (the same assist as `/commit`). `--skip-typecheck` is a true-emergency override only.
- **Pushes straight to main.** If `origin/main` advanced, it rebases the commit onto it and re-pushes; conflict → stop and resolve.
- **Feeds `/deploy` like any main commit.** `/ship-main` commits land on `main` and are read by the next `/deploy` (commit subjects since the last tag) to compute the bump level + changelog, exactly like a merged-PR squash commit. Conventional format is therefore required, not optional.
- **Requires require-PR off** (the default — §6.5, pipeline.md §1.1). With require-PR set, GitHub rejects the direct push.

Full spec: `commands/ship-main.md`.

---

## 7. Commit and changelog rules

### 7.1. Commit types

See `skills/gitflow/references/commit-types.md`. Summary:

| Emoji | Type | Use |
|-------|------|-----|
| ✨ | feat | New feature |
| 🐛 | fix | Bug fix |
| 📚 | docs | Documentation |
| 🎨 | style | Formatting |
| ♻️ | refactor | Restructuring, no behavior change |
| ⚡ | perf | Performance |
| 🧪 | test | Testing |
| 🔧 | chore | Maintenance |
| 🔖 | wip | Checkpoint (auto-format) |

Format: `<emoji> <type>: <description>` (imperative mood, first line <72 chars).

### 7.2. Changelog rules

See `skills/gitflow/references/changelog-rules.md`. Summary:

- Changelog is **public-facing**. Write entries as if a customer reads them.
- Include: `feat`, `fix`, `perf`, `BREAKING`.
- Exclude: `refactor`, `style`, `test`, `docs`, `chore`.
- Format: `- **<emoji> <Feature Name>** - User-visible description`.

### 7.3. Version bump semantics

Applied at `/deploy` time across the SUBJECT lines of all commits since the last `v*.*.*` tag. Highest match wins.

| Subject pattern | Bump |
|-----------------|------|
| `<type>!:` or `BREAKING CHANGE:` footer | major |
| `feat(...):` | minor |
| `fix(...):`, `perf(...):`, `refactor(...):` | patch |
| `chore(...):`, `docs(...):`, `test(...):`, `style(...):`, `ci(...):`, `build(...):` | patch (Option B — chore counts as a release) |
| Anything else | patch |

Option B intentionally treats `chore` as patch-bumping. Rationale: `chore(deps): bump foo` IS a release-worthy change — the deployed artifact has new dependencies. Skipping bump on `chore` would ship a new artifact under an unchanged version, breaking version-as-build-identity.

NEVER skip the bump when there are commits to deploy. "Deploy + no version change = lie."

---

## 8. Project bootstrap

Setting up a new project to use this kit:

1. In the dev-kit repo, run `/sync-dev-kit <new-project-path>` — sync tool will create `.claude/` and `.mcp.json` from templates after review
2. Add to project `.gitignore`:
   ```
   .claude/settings.local.json
   ```
3. Commit the new `.claude/` and `.mcp.json`
4. No branch protection to apply — the pipeline uses none (`/merge` self-gates; see `pipeline.md` §1.1). Just confirm `main` does not require a PR (the default), so the direct-push paths work.
5. Copy `commitlint.yml` and `ci.yml` templates (below) into `.github/workflows/`. Author project-specific `deploy.yml` with `workflow_dispatch:` ONLY trigger (§11.4).
7. Optional, per dev: set `EXA_API_KEY` in their shell rc (research tier 3; the built-in tools need no key)

---

## 9. Kit sync workflow

### 9.1. Philosophy

Nothing is ever full-replaced. Every sync is a three-way comparison per file: kit current vs kit baseline (last sync) vs project current. Every difference is shown as a diff, Claude recommends a resolution, the user decides. Resumable — if the user stops mid-review, partial syncs preserve state in the lockfile.

### 9.2. Lockfile

`.claude/.kit-sync.json` in every consumer project (committed):

```json
{
  "kitRepo": "https://github.com/NextAge-Consulting/nextage-dev-kit",
  "lastSyncedCommit": "<kit commit SHA at last sync>",
  "lastSyncedAt": "<ISO timestamp>",
  "files": {
    ".claude/hooks/git-guard.sh": { "kitSha": "<kit file hash at last sync>" },
    ".claude/rules/constitution.md": { "kitSha": "<kit file hash at last sync>" }
  }
}
```

Committed so every dev and every cloud session has the same baseline.

### 9.3. Sync states per file

| Kit vs baseline | Project vs baseline | State | Action |
|-----------------|---------------------|-------|--------|
| unchanged | unchanged | Clean | Silent skip |
| changed | unchanged | Kit-only | Show diff, recommend apply, ask |
| unchanged | changed | Project-only | Inform the user of customization; no change |
| changed | changed | Conflict | Three-way diff, Claude recommends merge, the user decides |
| new file in kit | — | New kit file | Show, ask |
| removed from kit | — | Removed kit file | Show, ask |

### 9.4. Sync procedure

`/sync-dev-kit` (invoked from the project root, on whatever branch you are standing on):

1. Clone or fetch kit at HEAD into a temp location
2. Load project lockfile (create empty if missing — first sync)
3. Build file inventory from kit HEAD
4. For each file:
   - Compute state per Section 9.3
   - Clean → skip silently
   - Any other state → present diff, recommend, await decision
5. On each accepted change: write to project, update lockfile per-file SHA + timestamp
6. At end (`--finalize`): **stamp the lockfile only** — set `lastSyncedCommit` to kit HEAD SHA + `lastSyncedAt` (per-file SHAs are already current from `--apply-file`). **Sync does not commit or push** — committing is gitflow's job, not sync's. The applied `.claude/` changes plus the lockfile bump are left as a normal uncommitted change in the working tree; the user lands them with `/ship-main` (or `/commit`). Sync runs **zero git mutations** (see §9.4.1).

### 9.4.1. Why sync does no git (the bootstrap problem)

Sync modifies the very mechanism that runs gitflow commands (`.claude/commands/`, `.claude/skills/`, `.claude/settings.json`, etc.). If sync were to commit itself via `/commit` or `/merge`, an unanswerable question arises: which version of those commands runs — the old one being replaced, or the new one being installed?

The resolution is simple: **sync does no git at all.** It applies the accepted kit updates to the working tree and stamps the lockfile — nothing more. The commit is a **separate, later, user-initiated step** (`/ship-main` is the natural fit; it commits + pushes straight to `main` in one move). Because no commit happens *during* sync, the "which version runs" question never arises, and there is no need for `SKIP_GIT_GUARD`, a kit-sync branch, a PR, or an admin-merge. This also un-duplicates logic that now lives in `ship-main.sh` — sync syncs; gitflow commits.

This also means:

- **Sync runs on whatever branch you are on, mid-feature included.** There is deliberately no on-`main` requirement. The lockfile records the KIT's SHAs, so applying on a feature branch stamps exactly the values it would on `main`; abandon the branch and the stamp is discarded with the files it describes. Running mid-feature is the point — a rule fixed while working is live in context for the rest of the session rather than stranded until a merge.
- **After sync, the changes are uncommitted.** The interactive `--apply-file` review IS the review — each change was inspected and accepted before it landed in the working tree. Land the result with `/ship-main` (straight to `main`, no PR — there's nothing for a sync PR to gate on: `.claude/` rules, slash commands, sync scripts have no runtime surface to test). `/ship-main` requires require-PR off (the default); `enforce_admins` is irrelevant — nothing admin-merges.
- **Applied kit updates ride the same commit as the rest of the body of work.** That is the house model (one body of work, one PR — `rules/git.md`), not something to avoid. Splitting them out would be exactly the ceremony the constitution forbids.

### 9.4.2. Long, interrupted sessions

The interactive review (steps 4–5) can stretch across multiple sessions:

- User invokes `/sync-dev-kit`, reviews + accepts 3 files, closes the session.
- The lockfile records per-file SHAs as each is applied; pending files are still surfaced in the next `--scan`.
- Working tree has 3 uncommitted .claude/ changes between sessions. No commit yet.
- User reopens `/sync-dev-kit` next session; Claude scans, picks up where left off, reviews remaining files.
- When the review queue is empty (or the user explicitly stops with "finalize anyway"), Claude invokes `--finalize`.
- `--finalize` detects the accumulated uncommitted changes, commits all of them in one commit pushed directly to `main`.

The user's UX is just `/sync-dev-kit`. Claude orchestrates the modes (`--scan` → `--apply-file` per accepted change → `--finalize`). The user never sees the internal mode flags.

### 9.6. Settings.json handling

`.claude/settings.json` uses 3-way comparison like every other file, with one wrinkle: both sides are compared as **jq-canonicalized JSON** rather than raw bytes, so a reordered key or reindented block does not surface as a diff on content that is semantically identical.

Every field — `hooks`, `permissions`, `env` — flows through normal 3-way state. The kit owns them all; there is no project-owned carve-out.

**Implementation:**

- `canonicalize_settings` in `_claude-maintainer/scripts/sync-dev-kit.sh` reads JSON on stdin and emits `jq '.'` output on stdout.
- `sha256_settings_kit` / `sha256_settings_proj` replace the generic `sha256_substituted` / `sha256` for the `_claude-project/settings.json` path, so both sides go through the same normalization.
- The same canonicalization applies in `--apply-file _claude-project/settings.json`, so the written file matches the SHA the scan computed.
- The lockfile baseline SHA for settings.json tracks the canonicalized content.
Cross-reference: §9.7 (placeholder substitutions, the general kit-template specialization mechanism).

### 9.7. Placeholder substitutions (`sync-substitutions.json`)

Some kit templates — workflow files, config files — contain values that are specific to each consumer project. Shipping these as hardcoded strings ties the kit to one project; shipping them as plain placeholders means every consumer's actual values conflict with the kit on every sync. Neither works.

The solution is an inline placeholder + per-project substitution table.

**Kit side** — templates use `{{KEY}}` markers:

```yaml
# In a kit workflow template:
```

`{{KEY}}` syntax is used specifically because it's unambiguous — won't collide with legitimate content in shell, YAML, JSON, or Markdown. (Older `<name>` style risks matching literal angle-bracket text in docs.) All future kit templates use `{{KEY}}` for any project-specific value.

**Consumer side** — `.claude/sync-substitutions.json` maps each key to its real value for this project:

```json
{
  "GITFLOW_PROJECT_ID": "PVT_...",
  "GITFLOW_STATUS_FIELD_ID": "PVTSSF_...",
  "GITFLOW_STATUS_IN_PROGRESS_ID": "..."
}
```

Current kit-referenced placeholders (authoritative list is in `_claude-project/sync-substitutions.json`'s `_placeholders_referenced_by_kit` block):

| Key | Consumed by | What the value is |
|-----|------------|-------------------|
| `GITFLOW_PROJECT_ID` | `_claude-project/gitflow-project.conf` | GraphQL node ID of the Project the lifecycle transitions write to. Empty → board integration off (silent skip); any other GITFLOW_STATUS_* empty when this is set → fail-loud at the transition site. |
| `GITFLOW_STATUS_FIELD_ID` | `_claude-project/gitflow-project.conf` | GraphQL field ID of the Status single-select on that project |
| `GITFLOW_STATUS_IN_PROGRESS_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for "In Progress" — set by `/work` and `/link` |
| `GITFLOW_STATUS_STAGED_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for "Staged" — set by `/open-pr` (code-complete, CI/review pipeline begins) |
| `GITFLOW_STATUS_DONE_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for "Done" — set by `/deploy` after tag push (shipped to production). `/merge` does NOT trigger this — Done is reserved for the deploy boundary. |
| `GEMINI_NOT_INSTALLED` | gitflow scripts (runtime-read via `jq`) | Inverted-default toggle — DEFAULT (missing/empty) = Gemini is installed → trigger scripts (`/open-pr`, `/commit --review`) post `/gemini review` comments, and `wait-for-pr-ready.sh` honors triggered reviews. Set `"true"` only when Gemini is genuinely absent from the repo → trigger scripts skip posting and the wait treats Gemini as `skipped`. Naming captures a fact about the repo, not a config preference. Semantics deliberately INVERTED from `GITFLOW_*` (which use empty = disabled) because the name encodes a negation. See "Runtime-read placeholders" below |
| `PROJECT_ABBREV` | `_claude-project/skills/gitflow/scripts/branch_helpers.sh` (runtime-read via `jq`) | Short project label embedded in `wip/<abbrev>-<timestamp>` branch names so the Agents view can distinguish concurrent sessions across projects. Empty/missing → `branch_helpers.sh` falls back to `basename <primary-repo-root>`. §9.8 walkthrough pre-computes that fallback and offers it as the prefill so the user can accept-with-enter or provide a shorter abbrev. See "Runtime-read placeholders" below |
| `AWS_ACCOUNT_ID` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | 12-digit AWS account ID this project's infra lives in. Confirm `aws sts get-caller-identity` matches it before any operation. Empty → project has no AWS. See "Runtime-read placeholders" below |
| `AWS_REGION` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | Default AWS region for this project's resources, e.g. `us-east-1`. Passed as an explicit `--region` on every AWS CLI command; never the shell default, which is per-machine and routinely points elsewhere. Empty → project has no AWS. See "Runtime-read placeholders" below |
| `AWS_PROFILE` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | Named AWS CLI profile for this project's account, e.g. `acme-prod`. Passed as an explicit `--profile` on every AWS CLI command. Empty → default profile / no AWS. See "Runtime-read placeholders" below |

The kit ships a template at `_claude-project/sync-substitutions.json` with empty values and inline docs of every placeholder kit templates currently reference. Consumer projects bootstrap automatically: `load_substitutions` in `sync-dev-kit.sh` copies the kit template to `.claude/sync-substitutions.json` on first run if absent. Population is then walked through interactively — see §9.8.

**Sync flow** — `sync-dev-kit.sh` uses the substitutions in two places:

1. **During scan**: the `kit_sha` for each file is computed AFTER substituting placeholders with project values. So a kit template with `{{PROJECT_ABBREV}}` matches a project file with `wa` and reports `clean`, not `conflict`. Three states per key, with deliberately distinct behavior:
   - **Key present, non-empty value** → normal substitution, `{{KEY}}` → value.
   - **Key present, empty string value** → substitution still happens, `{{KEY}}` → empty. This is the explicit opt-out for features that gate on a placeholder being unset (e.g. `GITFLOW_*` for gitflow project integration). The conf file lands with `FOO=""` and runtime treats as off.
   - **Key absent from the file** → no substitution, `{{KEY}}` marker survives in the content. Surfaces as a real diff on every scan until the consumer addresses it. Used as a "you haven't decided yet" signal — distinct from empty (informed off).

2. **During apply** (`--apply-file`): substituted content is written to the project. The project file on disk contains real values, never placeholders. Lockfile baseline SHA tracks the substituted content.

**Keys starting with `_`** in the JSON are reserved for metadata/comments (e.g., `_comment`, `_placeholders_referenced_by_kit`) and are ignored by the substitution engine. Use them to document what each placeholder means without affecting replacement.

**Runtime-read placeholders** — recognized variant of the pattern:

Most placeholders follow the canonical model: kit content has `{{KEY}}` markers, sync substitutes at apply time, the substituted value is baked into the consumer file. Changing the value requires another `/sync-dev-kit` pass to re-apply.

Some placeholders are read at runtime instead. Scripts in the kit query `.claude/sync-substitutions.json` directly via `jq` at execution time:

```bash
GEMINI_NOT_INSTALLED=$(jq -r '.GEMINI_NOT_INSTALLED // ""' .claude/sync-substitutions.json)
PROJECT_ABBREV=$(jq -r '.PROJECT_ABBREV // ""' "$primary/.claude/sync-substitutions.json")
```

Properties:

- No `{{KEY}}` marker appears in any kit template — step 2 of the "adding a placeholder" procedure below is skipped.
- Changing the value in the JSON takes effect on the very next script invocation; no re-sync needed.
- The walkthrough still surfaces empty keys per §9.8, so first-time setup behaves identically to canonical placeholders.
- The catalog entry in `_placeholders_referenced_by_kit` MUST explicitly note "runtime-read" so future kit maintainers don't expect a `{{KEY}}` marker to exist somewhere.

When to use each model:

| Use canonical (`{{KEY}}`) | Use runtime-read |
|---|---|
| Value is consumed by static config files (YAML, conf, dotenv) | Value gates dynamic script behavior |
| Value rarely changes — re-sync friction is acceptable | Value may toggle without other kit changes (e.g. installing a GitHub App on a repo) |
| Multiple files need the same value substituted into them | Single decision read from one place at runtime |

**Adding a new placeholder** (kit-side work):
1. Pick a key name matching `{{[A-Z_]+}}` convention.
2. Use `{{KEY}}` in the template wherever the project-specific value belongs. **Skip if runtime-read** — the value will be read from `.claude/sync-substitutions.json` at execution time instead.
3. Add a documentation entry to `_claude-project/sync-substitutions.json`'s `_placeholders_referenced_by_kit` block. Required content: human-readable description, where the value gets consumed, **and** a discovery command if the value is programmatically obtainable (e.g. `gh api graphql ...` for the gitflow project IDs). Discovery commands let the §9.8 walkthrough fetch values rather than asking the user to paste them. For runtime-read placeholders, explicitly note "runtime-read" in the description.
4. Add the key to the top-level body of `_claude-project/sync-substitutions.json` with an empty string value. (Empty signals "feature disabled / not yet populated"; the §9.8 walkthrough surfaces it for the consumer.)
5. Commit kit.
6. In every consumer project, the next `/sync-dev-kit` merges the new key into `.claude/sync-substitutions.json` carrying its empty default, and the §9.8 walkthrough surfaces it for population on that same run. The merge (`load_substitutions`) is what delivers the key. Exactly two things in that file are the consumer's — the VALUES of non-`_` keys, and `_intentionally_empty` (data, not prose). Everything else is the kit's and is overwritten from the template on every sync, including every comment block (`_comment`, `_placeholders_referenced_by_kit`, `_documented_behavior`, `_intentionally_empty_doc`) — they document kit-owned settings, so letting them drift per-project just leaves stale copies that mislead the next reader. Project-specific prose does not belong in them. The new key lands empty and absent from `_intentionally_empty`, which is the "deferred decision" state the walkthrough re-surfaces every sync until it's populated or explicitly disabled.

   The merge exists because this file is in the sync `SKIP_LIST` — every project's values differ, so the kit's empty template would conflict forever after first sync. It is therefore never applied as a file, and `load_substitutions`'s bootstrap only fires on a project that lacks it entirely. Merging per-key is the only path by which a key added AFTER a project bootstrapped reaches that project. This matters most for runtime-read keys: canonical `{{KEY}}` placeholders would at least leave an unsubstituted marker in the synced file as a standing diff, but runtime-read keys have no marker anywhere, so a missing one fails silently — the rule that reads it ships, its config surface does not.

### 9.8. Substitutions setup walkthrough

The kit ships templates with `{{KEY}}` placeholders and the consumer ships `.claude/sync-substitutions.json` with values for those keys. Section 9.7 covers the mechanism. This section covers the FIRST-RUN UX — how `/sync-dev-kit` walks a new consumer project (or an existing one with newly-empty keys) through populating values.

**When the walkthrough fires**

After the bootstrap step inside `load_substitutions` (which copies the kit template to `.claude/sync-substitutions.json` if absent), `/sync-dev-kit` reads the consumer file, identifies every key whose value is empty string, cross-references each against `_placeholders_referenced_by_kit`, and walks the user through them one at a time. Empty-key walkthrough happens BEFORE the per-file diff loop — populating subs first means kit_shas computed during the diff loop reflect the just-populated values, eliminating false-positive diffs on files that gate on the new keys.

**Per-key flow**

For each empty key:

1. **Show the description** from `_placeholders_referenced_by_kit`.
2. **Branch on discoverability:**
   - If the description includes a `gh api graphql ...` command (or other shell-runnable discovery): offer to run it. On accept, run the command, parse the JSON output, present the candidate value(s), and ask the user to confirm. Common case: project IDs, field IDs, status option IDs — all queryable via `gh api graphql`.
   - If the value is not programmatically discoverable (org login, repo slug, custom string): ask the user directly. Show what the value should look like (example from the description).
3. **Three resolutions** the user can pick:
   - **Populate** — write the real value to the JSON.
   - **Disable** — explicitly leave empty. Confirms feature-off intent. Suppresses re-prompt on subsequent syncs (until the user manually clears the value or a new key gets added).
   - **Defer** — skip for now. Re-prompts on next sync. Useful when the user needs to go set something up externally first (create the GitHub App, configure the project board, etc.).

**Distinguishing intentional empty from unset empty**

Both intentional-disable and not-yet-populated states sit as `""` in the JSON, so the bare value isn't enough to tell them apart. The walkthrough records intent in a sidecar block at the top of the JSON:

```json
{
  "_intentionally_empty": ["GITFLOW_PROJECT_ID", "GITFLOW_STATUS_FIELD_ID", "GITFLOW_STATUS_IN_PROGRESS_ID"],
  "_comment": "...",
  "GITFLOW_PROJECT_ID": "",
  "GITFLOW_STATUS_FIELD_ID": "",
  "GITFLOW_STATUS_IN_PROGRESS_ID": ""
}
```

Keys listed in `_intentionally_empty` are skipped by the walkthrough (the user has already decided). Keys with empty values NOT in that list are surfaced for decision. The substitution engine ignores `_`-prefixed keys (per §9.7), so this metadata doesn't affect substitution behavior.

**On every subsequent sync**

The walkthrough re-runs against the current state of the consumer file:
- Newly-added kit keys land with empty values via the `kit-only` diff on `sync-substitutions.json` itself; the walkthrough surfaces them.
- Keys the user previously populated stay populated; not surfaced.
- Keys in `_intentionally_empty` stay skipped.
- Keys that were "deferred" last time (still empty, not in `_intentionally_empty`) get re-surfaced.

This preserves the missing-vs-empty-vs-populated invariants from §9.7 while adding intentional-empty as a fourth state stored only in metadata.

**Where the walkthrough lives**

The orchestration is in the `/sync-dev-kit` slash command (`_claude-maintainer/commands/sync-dev-kit.md`), Step 1.5. Claude reads the substitutions file, the `_placeholders_referenced_by_kit` block, and the `_intentionally_empty` list, then drives the per-key flow with the user. Discovery commands are invoked via `Bash`. Updates are written by re-serializing the JSON via `jq`.

## 10. Environment variables

**None are required.** Documentation and research run on the built-in `WebSearch`
and `WebFetch` tools, which need no key or account.

One optional key, set once per dev in shell rc (`.bashrc` / `.zshrc`):

```bash
export EXA_API_KEY="..."
```

It enables the `research` skill's tier 3 — non-English and primary sources, and
conceptual research. Absent, those degrade to tier 1/2 and nothing else changes.

Cloud sessions: set it in the cloud environment's env-var editor. Per-dev, not committed anywhere.



Maintainer's local: `includeGitInstructions: false` in `~/.claude/settings.json` strips Claude's native git instructions from the system prompt, reducing fallback to raw git. User-level only; doesn't load in cloud. Not a required setting — hook backstop catches anything this doesn't.

---

## 11. Workflow file templates

Live templates ship with the kit at `_github-project/workflows/`. Consumer projects receive them via `/sync-dev-kit` — they land at `.github/workflows/`. Edit the kit files, not the snippets below; the snippets are documentation. Consult `_github-project/workflows/*.yml` for the authoritative versions.

### 11.1. `commitlint.yml`

**PR-title validator (conventional commits). Title ONLY — not branch commits.**

Fires on `pull_request: opened/edited/synchronize/reopened`. Pipes the PR title through `@commitlint/cli` with the repo's `.commitlintrc.json` config. No third-party action — just `actions/checkout` + `actions/setup-node` + an inline `npx commitlint`.

**Why title-only:**
- Consumer repos squash-merge with `commit title = PR_TITLE`. The squash commit that lands on `main` IS the PR title; branch commits are discarded.
- Local gitflow enforces conventional format at commit time for human-authored commits — that's the real guard.
- Machine-generated PRs (Dependabot, Renovate) produce malformed branch commits on a regular basis. Dependabot specifically double-scopes `chore(deps)(deps):` even when `include: scope` is absent from `dependabot.yml`. Linting those branch commits blocks merges that would land as clean squashes.

**Do NOT swap in a commitlint action that lints every commit in the PR** (`wagoid/commitlint-github-action` and similar do this by default). It rejects Dependabot PRs whose branch commits don't conform even when the PR title is clean, and the branch commits never reach `main`.

**Required `permissions:` block.** The workflow declares `permissions: { contents: read, pull-requests: read }`. Kept even though the inline approach only reads `github.event.pull_request.title` — cheap, documented, explicit.

**Job name kept as `lint`** so the GitHub status check name stays `commitlint / lint`. `/merge` self-gates by reading the PR's check-runs by name; renaming the job changes the check name and can let a merge slip through without the gate seeing it.

**`.commitlintrc.json` requires a custom `parserPreset`.** The gitflow commit format is emoji-prefix (`✨ feat: ...`, `🐛 fix: ...`), which stock `@commitlint/config-conventional` rejects because its default `headerPattern` expects the type token at position 0. The template ships a `parserOpts.headerPattern` that tolerates an optional leading emoji cluster before the type. Keep this in sync with the commit format enforced by `commit.sh` — if the commit format changes, the parser regex must change too.

### 11.2. Anti-pattern: never auto-bump the version on merge

Version bump + tag live in the local `/deploy` command (§6.5), never in a CI workflow or a release-bot. Do NOT introduce auto-bump-on-merge — a `version-bump.yml` workflow or a release-bot PR. It fails three ways:

- **Version skew** — the bump trails the feature merge by a cycle, so the version on `main` doesn't match the deployed code.
- **Pre-bump deploys** — a push-triggered deploy races the bump workflow and ships the wrong version.
- **Adversarial body parsing** — scanning commit *bodies* for `BREAKING CHANGE` / conventional markers false-matches prose embedded in PR descriptions. Pipeline control signals read STRUCTURED metadata (commit subject, `author.name`), never freeform body text.

### 11.4. Deploy trigger contract (MANDATORY)

**Consumer-project `deploy.yml` MUST use `workflow_dispatch:` as its ONLY trigger:**

```yaml
on:
  workflow_dispatch:
```

No `on: push: branches:`. No `on: push: tags:`. No cron, no schedule, no `workflow_run`. The deploy fires only when explicitly invoked — by `/deploy` (which calls `gh workflow run deploy.yml --ref main`) or via the GitHub Actions UI manual button.

**Why workflow_dispatch ONLY:**

Do NOT add `on: push: tags: ['v*.*.*']`. `/deploy` creates the tag locally AND fires the workflow directly via `gh workflow run`, so a tag-push trigger double-fires (once from the tag push, once from `gh workflow run`).

Do NOT add `on: push: branches: [main]`. It reintroduces the pre-bump race (the deploy reads `package.json` before the bump) and makes *every* `/merge` ship, not just the merges the user intends as a release. `/merge` is not `/deploy` (§6.5).

**The contract:**

```
/merge       → squash commit lands on main          → NOTHING fires
/merge       → squash commit lands on main          → NOTHING fires
/deploy      → bump + tag + push + gh workflow run  → deploy.yml fires once
                                                       against post-bump HEAD
                                                       with correct version
```

Multiple merges between deploys are normal. The deploy ships everything since the last release tag in one bump.

**What goes inside `deploy.yml` is unchanged.** Build steps, ECR push, EC2 SSH, db migrations, verification — all still consumer-specific. The kit does NOT ship a `deploy.yml` template because deploys are platform-specific (AWS / GCP / Vercel / Fly / Render / etc.). The kit ships only the trigger contract. Build out the body per platform docs.

**Migration audit when adopting `/deploy`:** grep `deploy.yml` for any of these and remove:

- `on: push:` (any branches or tags)
- `on: schedule:`
- `on: workflow_run:`
- `if: !contains(github.event.head_commit.message, 'chore: bump version')` — dead code under `workflow_dispatch` only; remove it

If `deploy.yml` does anything that needs a "fire automatically on X" hook, that work belongs in a separate workflow, not in the deploy.

### 11.5. Changelog generation (not a workflow)

Changelog generation is NOT a GitHub Action and has exactly one writer: `/deploy`. Claude composes the consolidated release entry locally during `/deploy` from commit subjects since the last `v*.*.*` tag. `deploy.sh` inserts that entry under today's date header in `changelog.md` as part of the bump commit pushed directly to `main`. Feature-PR scripts (`commit.sh`, `open-pr.sh`, `merge.sh`) do not touch `changelog.md`.

Rationale:
- Zero CI infrastructure (no `changelog.yml`, no `ANTHROPIC_API_KEY` secret, no runner dependency).
- `changelog-rules.md` requires editorial intelligence (filter `refactor/style/test/docs/chore`, rewrite internals as user-facing prose) that template tools like release-please cannot provide.
- Single-writer eliminates the duplicate-bullet bug from the earlier two-writer design (one entry per feature PR + one per release = two copies of the same line in main). See §6.4.

**Procedure (`/deploy`):**
1. `/deploy` lists conventional commit subjects since the last `v*.*.*` tag.
2. Claude applies `changelog-rules.md` to generate one or more bullets in `- **<emoji> <Title Case>** - <user-impact>` form. Pure infra commits collapse to a single `Internal Tooling` / `Dependency Updates` line.
3. Claude writes the entries to a tempfile and invokes `deploy.sh --changelog-file <path>`.
4. The script inserts the entry under today's date header in `changelog.md`, bumps the manifest version, commits everything as `🚀 release: v<NEW>` on `main`, and pushes `main` directly (require-PR off, the default — no release branch, no PR; see §6.5).
5. The script deletes the tempfile on success.

There is no `--no-changelog` mode and no `--changelog-file` flag on `open-pr.sh`. Releases without user-facing entries still get a one-line `Internal Tooling` bullet — every release commits exactly one new bullet, never zero.

**MANDATORY changelog format — Keep-a-Changelog:**

`deploy.sh` inserts entries by anchoring on standard Keep-a-Changelog landmarks. The consumer project's changelog MUST conform on adoption:

```markdown
# <Project> Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## 2026-05-06

- **🐛 Tracking Number Whitespace** - User-facing description of the fix.

## 2026-04-28

- ...
```

Required:
- An `## [Unreleased]` h2 placeholder after the preamble. `open-pr.sh` anchors new dated sections after this line.
- Date headers as **h2 with ISO-8601 dates**: `## YYYY-MM-DD` (e.g., `## 2026-05-06`). An `### Month Day, Year` (h3, long-form) format is NOT supported — `open-pr.sh`'s Python insertion falls through and appends at EOF, producing an out-of-order changelog.
- Entries as `- **<emoji> <Title Case>** - <user-impact>` bullets.

Adoption migration for projects with non-conforming changelogs: convert all date headers to `## YYYY-MM-DD`, add `## [Unreleased]` placeholder. The renderer (if any) can preserve the prior visual style by swapping the h2/h3 component CSS.

See `commands/open-pr.md`, `commands/deploy.md`, and `skills/gitflow/references/changelog-rules.md`.

### 11.7. Issue → branch → PR linking

Issue↔branch↔PR linking is first-class in the gitflow subsystem. Two commands drive it:

- **`/work <issue#>`** — (if on `main`) creates a branch linked to the issue. Branch slug derived from the issue's title (e.g. `feat/add-email-to-users`). Issue numbers are NOT in the branch name — a branch may close multiple issues over time via `/link`, so embedding one number misleads. The link graph lives in git config (`branch.<name>.gitflow-issues`); collisions resolved by `work.sh`. Moves the linked issue to `In Progress` on the configured project. Assigns to the current `gh`-authenticated user. Dumps issue body + comments to stdout so Claude reads them in-turn and responds with understanding + questions BEFORE any code is written.

- **`/link #27[,#28]`** — mid-work linking. Same side-effects as `/work <issue#>` minus branch creation. Refuses on `main`/`master`. Validates all issues before any side-effects (no half-linked state).

Board transition + assignment are **fail-loud when configured** — see the failure-semantics table in the gitflow-project-integration subsection below. `GITFLOW_PROJECT_ID` empty = feature off, silent skip. Any other broken state (missing scope, wrong option ID, issue not on the configured project) = script exits non-zero with the underlying cause.

**Storage**: `git config --local branch.<name>.gitflow-issues = "23 25 26"` — git wipes on branch delete, no stray metadata files.

**PR body injection**: `/open-pr` reads the git-config list and prepends `Closes #23, #25, #26` to the PR body. Fires GitHub's native auto-close on merge. The project's built-in "Pull request merge — closes linked issues" workflow is belt-and-suspenders; the `Closes` keyword handles the core closure regardless of project state.

**PR titles do NOT include issue #s** — same rationale as branch names. A multi-issue PR with one number in the title misrepresents itself. Linkage lives in the body's `Closes #N` line, which is sufficient. Rule codified in `.claude/commands/open-pr.md` Step 3.

**Board lifecycle (four states):**

| State | Trigger | Mechanism |
|-------|---------|-----------|
| Todo | Board default — no gitflow command fires this | — |
| In Progress | `/work <N>` or `/link <N>` | `move_issue_to_in_progress` in `issue_helpers.sh` |
| Staged | `/open-pr` (PR opens = code-complete; CI + review pipeline begins) | `move_issue_to_staged` after successful PR create |
| Done | `/deploy` (after tag push — shipped to production) | `move_issue_to_done`, sourced from `git log "$LAST_TAG..HEAD"` parsed for `Closes #N` |

`/merge` intentionally does NOT transition. Merge → deploy is seconds in this shop; "Staged" spans the entire PR/CI/review/merge window and "Done" is reserved for the deploy boundary. If a consumer's flow legitimately decouples merge from deploy (long-lived release branches, multi-stage rollouts), the conventions still hold — Done lands when `/deploy` fires, not before.

**Config surface** — `.claude/gitflow-project.conf` (substituted from `sync-substitutions.json` at sync time):

- `GITFLOW_PROJECT_ID` — GraphQL node ID of the project. Empty = feature off (silent skip everywhere).
- `GITFLOW_STATUS_FIELD_ID` — Status single-select field ID on that project.
- `GITFLOW_STATUS_IN_PROGRESS_ID` — option ID for In Progress.
- `GITFLOW_STATUS_STAGED_ID` — option ID for Staged.
- `GITFLOW_STATUS_DONE_ID` — option ID for Done.

**Failure semantics (Zero Tolerance — fail-loud-when-configured):**

| Condition | Behavior |
|-----------|----------|
| `GITFLOW_PROJECT_ID` empty | Silent skip — feature disabled, kit default |
| `GITFLOW_PROJECT_ID` set + `GITFLOW_STATUS_FIELD_ID` empty | ERROR + return 1 (config gap) |
| `GITFLOW_PROJECT_ID` set + a specific status option ID empty | ERROR + return 1 — populate the key or add it to `_intentionally_empty` in `sync-substitutions.json` if the consumer's board legitimately lacks that column |
| Issue not on the configured project | ERROR + return 1 (auto-add workflow off, or wrong PROJECT_ID) |
| GraphQL mutation fails | ERROR + return 1 — almost always missing `project` scope on gh auth (`gh auth refresh -s project`) |

Caller scripts run under `set -e`; a non-zero return from any helper propagates to script exit. All transitions are idempotent — retry after fixing the cause.

**How to populate the IDs** (bash, with `gh` authenticated and `project` scope):

```bash
# 1. Find the project node ID
gh api graphql -f query='{ organization(login:"<ORG>") { projectsV2(first:10) { nodes { id title } } } }'
# (or user(login:"<USER>") for user-owned projects)

# 2. With the project ID, fetch the Status field + all option IDs in one call
gh api graphql -f query='{ node(id:"<PROJECT_ID>") { ... on ProjectV2 { fields(first:20) { nodes { ... on ProjectV2SingleSelectField { id name options { id name } } } } } } }'
# Copy: Status field's id → GITFLOW_STATUS_FIELD_ID
#       "In Progress" option's id → GITFLOW_STATUS_IN_PROGRESS_ID
#       "Staged" option's id → GITFLOW_STATUS_STAGED_ID
#       "Done" option's id → GITFLOW_STATUS_DONE_ID
```

Then populate the five `GITFLOW_*` keys in `.claude/sync-substitutions.json` (via the `/sync-dev-kit` walkthrough, which offers to run the discovery commands above and parse the output for you). Re-run sync to substitute into `gitflow-project.conf` on disk.

Kit ships a placeholder template at `_claude-project/gitflow-project.conf` with empty values. Each consumer project fills in their own IDs once (committed to the repo). To opt out of a specific transition (e.g. consumer's board has no Staged column): leave that `GITFLOW_STATUS_*_ID` empty AND list the key in `_intentionally_empty` in `sync-substitutions.json` — the walkthrough stops re-prompting and the helper silently skips that transition.

### 11.8. `.semgrepignore` (MANDATORY when adopting Semgrep)

Semgrep walks every tracked path by default. In any repo with design assets, reference documents, or other binaries under version control, generic secret-regex rules (`detected-private-key`, `detected-github-token`) match base64-ish noise inside EPS/PDF/PSD binary streams and fire per-file timeouts. A repo carrying a few hundred PDF/EPS brand assets times out on every Semgrep CI run until `.semgrepignore` excludes them.

Kit template at `_claude-project/templates/.semgrepignore` syncs to consumer's `/.semgrepignore` on bootstrap. Scope includes `project-documentation/`, `docs/`, design binaries (pdf/eps/ai/psd/indd/sketch/fig/xd), raster/vector images, video/audio, archives, fonts, build outputs, and lockfiles. Lockfiles excluded because Dependabot owns dep security — Semgrep scanning them is noise.

Ship this as part of Semgrep adoption. Do NOT wait for a timeout-warning incident to discover the need.

### 11.9. `deploy.yml` body pattern (build → push → deploy)

The kit ships no `deploy.yml` — deploy targets vary per project (EC2 / Fly / Cloud Run / Render), so each consumer authors its own. The trigger contract is fixed: `workflow_dispatch:` ONLY, fired by `/deploy` (§11.4, §6.5). A push to `main` triggers no deploy.

Body shape (per app; mirror across apps):

- **`build-and-push`** — checkout, registry auth (e.g. ECR), `docker build` + push tagged `:<git-sha>` and `:latest`.
- **`deploy`** (`needs: build-and-push`) — SSH to the deploy host, pull the image, `docker compose up`. Put every per-app deploy workflow in a shared concurrency group (`group: ec2-deploy`, `cancel-in-progress: false`) so SSH to the host is serialized and parallel `docker compose` runs can't collide.

Selective per-app deploy (rebuild only apps whose files changed) is NOT part of the model — `/deploy` ships everything since the last tag in one intentional release. A consumer with genuinely expensive builds can diff the previous tag against HEAD inside its own `deploy.yml`, but that is project-specific, not kit-standard.

### 11.9.2. New-container provisioning checklist (ECR)

Adding a NEW container/service to a consumer's docker-compose has TWO AWS-side
prerequisites that fail with the same opaque error when missed — a `403 Forbidden`
on a blob/manifest HEAD during push or pull (ECR returns 403, not 404, for both
missing repos and unauthorized ones):

1. **Create the ECR repository (one-time, manual — the CI user intentionally lacks
   `ecr:CreateRepository`):**

   ```bash
   aws ecr create-repository --repository-name <prefix>-<service> --region <region>
   ```

2. **IAM policies must be PREFIX-scoped, never enumerated.** Both the CI push
   user's policy AND the host's pull role must use
   `arn:aws:ecr:<region>:<acct>:repository/<prefix>-*` as the resource — an
   enumerated ARN list means every new container needs TWO policy edits that
   nobody remembers — producing a push 403 from the enumerated push policy and a
   pull 403 from the enumerated EC2 pull role.
   Include `ecr:DescribeRepositories` in both so the guard step below works.

3. **Every deploy workflow carries a fail-fast guard** (after the
   configure-aws-credentials step, before ECR login) so a missing repo surfaces
   as an actionable error instead of the 403:

   ```yaml
   - name: Verify ECR repository exists
     run: |
       aws ecr describe-repositories --repository-names "${{ env.IMAGE_NAME }}" \
         --region ${{ secrets.AWS_REGION }} >/dev/null 2>&1 || {
         echo "::error::ECR repository '${{ env.IMAGE_NAME }}' does not exist (or the push policy doesn't cover it). One-time fix: aws ecr create-repository --repository-name ${{ env.IMAGE_NAME }} --region ${{ secrets.AWS_REGION }}"
         exit 1
       }
   ```

The kit ships no `deploy.yml` template (§11.4 — platform-specific), so this is
adoption guidance: audit existing consumers' push/pull policies for enumerated
ARNs once, and include the guard step in every new deploy workflow. Checklist
row: E67.


### 11.10. `dependabot.yml` (monthly + cooldown + grouping)

`dependabot.yml` schedules the PRs that Dependabot opens for version + security updates. Acting on those PRs is the `dependency-triage` pass (§11.10a), under the policy in §11.10b.

**Ships via:** `/sync-dev-kit` copies `_github-project/dependabot.yml` → `<consumer>/.github/dependabot.yml`. No placeholders.

**Ecosystem coverage out of the box:**

| Ecosystem | Directory | Cadence | Cooldown (patch/minor/major days) | Grouping |
|---|---|---|---|---|
| `npm` | `/` (workspaces auto-detected) | monthly Monday | 3 / 7 / 30 | `npm-patch` + `npm-dev-minor` + `npm-security` — runtime majors open individually |
| `github-actions` | `/` (scans `.github/workflows/*.yml`) | monthly Monday | 3 / 7 / 14 | `actions-minor-patch` |
| `docker` | `/` (scans root for `Dockerfile*`) | monthly Monday | 3 / 7 / 30 | `docker-minor-patch` |

**Why monthly + cooldown** (design rationale — critical for a 2–10 engineer shop to understand before tuning):

Weekly cadence produces waves of ~9 PRs in a single day (majors, dev-majors, grouped batches, framework-track minors) — unsurvivable for a 2-person shop. Research evidence:

- **Matthew Hou (6-engineer team) — dev.to case**: weekly Dependabot = 40–60 PRs/week → turned it off, switched to monthly batched review + quarterly major audits. Post-change: dep incidents 3→0, review time 8hr/wk → 4hr/mo.
- **HN 647-pt thread** on Filippo's "Turn Dependabot off": mainline sentiment is "merge relentlessly OR turn off + do quarterly audits." Weekly is the worst of both.
- **GitHub's own `cooldown` feature** (introduced 2025): explicitly designed to delay PRs N days after a version ships so supply-chain attacks get caught and attacked versions get yanked before you merge them (Shai-Hulud / tinycolor incidents). Phoenix Security recommends 48–72h post-tinycolor. `semver-patch-days: 3, semver-minor-days: 7, semver-major-days: 30` is a defensible default.

Result: one monthly grouped wave per ecosystem + majors individually after 30-day cooldown. Review burden ~1 defined session/month, security-fix lane still fires immediately (Dependabot security updates skip cooldown automatically).

**Commit-message prefix discipline** (unchanged):
- `chore(deps)` / `chore(deps-dev)` / `chore(ci)` / `chore(docker)` are subject-only `chore` types — `deploy.sh`'s bump-level inference (§6.5 Step 2) treats them as patch under Option B (chore counts as a release-worthy bump).
- `include: scope` is INTENTIONALLY ABSENT from all three blocks. With it set, Dependabot appends its own `(deps)` scope on top of the prefix — titles render as `chore(deps)(deps): bump foo`. The prefix already carries the scope; don't double it.

**Interaction with `/deploy` (§6.5)**: dep PRs land on main via `/merge` like any other PR, but do not fire deploys on their own. They ride the next `/deploy` invocation alongside whatever else has accumulated. The monthly cadence + cooldown limits the dep-PR wave per ecosystem; whether a wave triggers a release is the maintainer's call at `/deploy` time. Cadence solves review burden; `/deploy` solves "when does it ship."

**Ignore rules — one ships by default:**

- `dependency-name: "node"` / `update-types: ["version-update:semver-major"]` in the docker block. **Why:** Dependabot doesn't understand Node's LTS policy. Odd-numbered Node releases (25, 27, …) never become LTS; even-numbered ones enter Active LTS ~6 months after release. Without this ignore, every 6 months we'd get a wave of Node-major PRs we don't want to merge. Patches (24.x.y security fixes) still flow through. The ONE major bump we DO care about — the Active-LTS transition — is checked during the `dependency-triage` pass (§11.10a), not by Dependabot.

If a project adds other framework-specific holds (pinned transitive dep, known-broken major), add them in the consumer's `.github/dependabot.yml` as `locally-modified` overrides. Document the hold reason as a comment in the consumer's `.github/dependabot.yml`.

**Auto-review skip coordination**: dep PR prefixes (`chore(deps):` etc.) are the same prefixes used by other pipeline-generated PRs. Gemini Code Assist (§11.11) does not have a built-in `ignore_title_keywords` equivalent at the consumer-config tier; if review noise on dep PRs becomes an issue, switch the dependabot prefix or open a Gemini config feature request.

### 11.10a. `dependency-triage` skill (the weekly dependency + vulnerability pass)

The weekly dependency **process** is a kit skill (`_claude-project/skills/dependency-triage/SKILL.md`); the per-project **policy** — timelines, owner, exceptions — is `dependency-policy.md` (§11.10b). Claude runs the analysis + verification; the human authorizes every main-landing merge.

**Why a skill, not a doc:** you want Claude to *execute* the same triage everywhere, identically — reading prose and re-deriving the process each time is exactly what drifts. The skill encodes the load-bearing facts so they don't have to be re-argued per project.

**The pipeline assumption is the simplification.** The skill *assumes* the kit pipeline (gitflow + `/deploy` + CI-does-not-build) rather than parameterizing a build-gate — because if you're triaging Dependabot you're on the full pipeline by definition (the build-runs-at-`/deploy`, PR-CI-doesn't-build property is uniform across consumers; §11.13 "Wiring CI" + §6.5). A project that broke from the pipeline owns the subtraction.

**What's universal (in the skill) vs project-specific (discovered):**
- Universal: the "PR-CI doesn't build" fact; the three blast-radius tiers; rebase-before-trusting-red; toolchain-build-before-merge; the verification standard; the guardrails.
- Project-specific, **discovered at runtime** (not configured): which packages are Tier 3 (read the `npm-toolchain` group in `dependabot.yml` — §11.10); the build/run commands and app ports (read the project's `Dockerfile.*` + deploy workflows). This is deliberate — the values vary and AI reads them from the repo; a config surface would be over-engineering.

**Pairs with** the `npm-toolchain` / `npm-patch` split in `dependabot.yml` (§11.10, now kit-standard) and the `dep-alignment` gate (§11.13a). Deeper dependency discipline: `dependency-management.md`.

### 11.10b. `dependency-policy.md` (synced as `template` mode)

The operating procedure for dependency and vulnerability work — what to do with what
Dependabot produces. The kit long shipped the configuration (§11.10) and the triage
skill (§11.10a) but never the procedure, so the answer to "who acts on this, and by
when" was undefined in every consumer.

**Ships via:** `/sync-dev-kit` copies `_claude-project/templates/dependency-policy.md`
→ `<consumer>/project-documentation/dependency-policy.md`. It lands in the project's
docs rather than `.claude/` because it is read by a human on a cadence, not loaded as
a rule on every turn.

**Mode `template`.** The timelines table and the owner names are each client's own.
A consumer that tunes them gets `template-drift` (informational), never a reverted
edit. `--ack-file` records "seen it, keeping ours".

**The timelines table is the only dial.** Tightening toward a formal standard —
ISO 27001 Annex A 8.8 wants a documented discover → prioritise → treat → review
process with defined roles, timelines and evidence — is editing that table and adding
a sign-off, not writing a different document. A 8.8 does not require zero
vulnerabilities; it requires them managed deliberately and defensibly, which is what
the exceptions-with-expiry-dates section provides.

**Why there is no enforcing gate.** A gate assumes whoever hits it can resolve it.
Build-graph updates can cost hours and the person holding the keys after handover has
less context than the person who built it, so a gate either stops them shipping or
teaches them to bypass it. The cadence is honour-system by design; the document's job
is to make "did we do it" answerable, not enforced.

### 11.11. `.gemini/config.yaml` + `.gemini/styleguide.md` (Gemini Code Assist config)

Gemini Code Assist is the kit's chosen AI PR reviewer (consumer / free tier). Install via [github.com/marketplace/gemini-code-assist](https://github.com/marketplace/gemini-code-assist) at the org level. **Reviews are comment-triggered, not auto-fired on PR open** (see §11.11.1 below). The kit's `_gemini-project/config.yaml` disables Gemini's auto-trigger and the gitflow scripts post `/gemini review` comments at the deliberate moments where review is wanted.

The kit ships two files via `/sync-dev-kit`:
- `_gemini-project/config.yaml` → `<consumer>/.gemini/config.yaml` — reviewer behavior knobs
- `_gemini-project/styleguide.md` → `<consumer>/.gemini/styleguide.md` — project-specific rules Gemini reads on every review

Both are universal — same content per project, no placeholders. Customize the styleguide per project to add domain rules; the config defaults work for most projects.

**What `config.yaml` sets:**

| Setting | Why |
|---|---|
| `have_fun: false` | No flair / poems in PR summaries. Operational tone. |
| `ignore_patterns` | Skip generated code (`*.gen.ts`, `routeTree.gen.ts`, `*.generated.*`) and lockfiles. Note: Gemini already skips `.github/workflows/**` by Google policy and skips markdown by default — those are not in this list because they're vendor-side. |
| `code_review.comment_severity_threshold: LOW` | Surface everything; consumer triages via `/triage`. Tighten to `MEDIUM`/`HIGH` if review noise becomes excessive. |
| `code_review.max_review_comments: -1` | Unlimited per-PR. The threshold above is the noise control. |
| `code_review.pull_request_opened.summary: false` | Disabled 2026-05-12. `/open-pr` writes the structured PR body; Gemini's auto-summary was duplication. |
| `code_review.pull_request_opened.code_review: false` | **Disabled 2026-05-28.** Reviews are comment-triggered exclusively — gitflow scripts post `/gemini review` at controlled points (see §11.11.1). |
| `code_review.pull_request_opened.include_drafts: false` | Don't review draft PRs. Mirrors the prior reviewer's behavior. |

**What `styleguide.md` adds:**

The styleguide is project-context Gemini reads on every review. The kit template includes:
- Constitution §XIV (caller-scan attestation requirement) — surfaces if the actor forgot the attestation
- Constitution §X (fail-fast / fail-loud) — flags new silent error handlers
- Constitution §VI (timezone-aware code) — flags `new Date()` without explicit tz
- Constitution §XIII (suppression discipline) — flags new lint suppressions without specific reasons
- Severity guidance (`Critical | High | Medium | Low`)
- A "what NOT to flag" section (test files, generated files)
- Project-context placeholders to customize per consumer

Customize the styleguide per project. The defaults assume a TanStack/Hono/drizzle stack — strip what doesn't apply.

**Why Gemini and not a paid alternative**: see `pipeline.md` §1.4 (rejected tools). Short version: Gemini's consumer / free tier matches CR Pro's catch quality on the bake-off seed defects, reads in-repo `.claude/rules/*.md` as review context out of the box, and runs at $0/seat. The 33 PR/day quota is far above typical 2-dev-shop cadence.

**Pairs with `.github/dependabot.yml` (§11.10):** Gemini's `include_drafts: false` plus dependabot's commit-prefix conventions keep mechanical PRs from triggering review cycles.

### 11.11.1. Comment-driven Gemini triggers (2026-05-28 redesign)

Prior model (pre-2026-05-28): Gemini auto-reviewed on PR open + `commit.sh` posted `/gemini review` on every push. `wait-for-pr-ready.sh` blocked until Gemini reviewed the current HEAD on every call. Problems: (a) deploy.sh's release PR triggered Gemini despite having no code to review — wasted quota + hung merge; (b) late-triage commits re-triggered Gemini reviews the user had already decided to ship without; (c) the trigger side and wait side operated in separate vacuums — a silently-failed `gh pr comment` left `/merge` hanging forever waiting for a review that was never coming.

Current model: **trigger reality drives wait reality.** A single observable — the presence of a `/gemini review` comment on the PR scoped to the current HEAD's committer date — couples both sides.

| Site | Trigger behavior |
|---|---|
| `/open-pr` | Always posts `/gemini review` after `gh pr create`. Fail-loud if post fails. |
| `/commit --review` | Posts `/gemini review` after push. Fail-loud if post fails. |
| `/commit --no-review` | Does NOT post. The wait at `/merge` sees no trigger and proceeds CI-only. |
| `/commit` (PR open, no flag) | `.claude/commands/commit.md` prompts the user via `AskUserQuestion`; result determines `--review` / `--no-review`. |
| `/commit` (no PR open) | Nothing to comment on; skips silently. |
| `/checkpoint` | Never posts. Checkpoints are mid-flight saves below the review threshold; `/commit` is the signal that work is review-ready. |
| `/deploy` | Never posts. The bump commit pushes directly to `main` — no PR exists for Gemini to review. (Under the earlier release-PR design, deploy likewise never triggered Gemini; the direct-push model removes the PR entirely.) |

The wait side reads truth, not intent. `wait-for-pr-ready.sh` queries the PR's top-level comments (via `gh api repos/{owner}/{repo}/issues/{pr}/comments`), filters to `/gemini review` body (case-insensitive, exact match — not prose like "I'll run /gemini review later"), and scopes to comments created AFTER the HEAD's committer date. If such a comment exists → wait for a Gemini review on HEAD. If absent → CI-only readiness. No author filter — manual triggers from the user (or from a consumer developer, or from any maintainer) are honored identically to scripted triggers.

This removes the "vacuum" failure mode: a silently-failed `gh pr comment` is now fail-loud at the trigger site (`commit.sh` exits 10, `open-pr.sh` exits 9), and the downstream wait never assumes Gemini is coming when it isn't.

Posting via `gh pr comment` lands the trigger under the developer's GitHub identity (gh CLI auth, not a `[bot]`-suffix account), so Gemini's loop-prevention filter (per Google's own gemini-cli PR #16746, which ignores `[bot]` commenters) does not suppress it.

`GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` short-circuits the entire path: trigger scripts skip posting, and the wait skips the Gemini check entirely (treats it as `Gemini=skipped`). Use only on repos where the Gemini App is genuinely absent — the value records a fact about the repo, not a preference.

### 11.13. Vitest scaffolding (synced as `template` mode)

Per-app test infrastructure, shipped from `_claude-project/templates/testing/` and synced in **`template` mode**: the kit provides the starting point, the **project owns the file**. Consumers edit these freely — `block-kit-edit.sh` permits it and `/sync-dev-kit` never reverts it.

**All six files are `template`, including `globalSetup.ts` and `integration-helpers.ts`.** Those two look like project-agnostic infrastructure — one consumer had copied both byte-for-byte — and marking them `owned` would push harness fixes automatically. A second consumer settled it the other way: a dual-database project adapted `globalSetup.ts` to migrate two databases on one branch and grew `integration-helpers.ts` a second per-plane helper. Under `owned` the hook would have blocked both edits, and the project would have had no legal way to test its own topology. Database shape is project shape; the whole directory is the project's.

**Destination comes from the `SHARED_MODULE_DIR` substitution**, because test layout is project-specific (`apps/shared` in a monorepo, `src` or `.` in a flat repo, `packages/<name>` elsewhere). `vitest.config.ts` lands at `<SHARED_MODULE_DIR>/vitest.config.ts`; every other file at `<SHARED_MODULE_DIR>/test/<name>`. **Empty means the project has no shared test module and the scaffolding is skipped entirely** rather than landing somewhere wrong — so this costs nothing for projects it does not apply to.

**How an improvement reaches a project.** A consumer that never touched its copy sees `kit-only` and is offered the update like any other file. A consumer that adapted its copy sees `template-drift`: the kit's delta is shown, nothing is reconciled, the project decides. When the user keeps theirs, the walkthrough runs `sync-dev-kit.sh --ack-file <kit-path>`, which advances the lockfile baseline to the kit's current content **without writing the project file**. That is what stops a declined drift from re-reporting on every subsequent sync — and it is not a permanent mute, since the next kit change to that file surfaces again.

**Ack is not restricted to `template` files, and the test is not the mode — it is whether the kit's current content has been INCORPORATED.** An ack asserts "this kit version has been seen and our copy still differs on purpose." Acking *instead of* applying makes that assertion false and silences a real enforced update; that is the failure to prevent. Acking an `owned` file *after* resolving its conflict by hand is the opposite — the kit's changes are in the file, only the project's own customization still differs, and skipping the ack leaves the identical conflict re-reporting on every sync forever, burying the next genuine kit change in noise the user has learned to skip. So an `owned` conflict resolves in two steps: merge (or apply), then ack. The script deliberately does not enforce this; the guard lives in the `/sync-dev-kit` walkthrough where the user can see which of the two situations they are in.

A consumer legitimately customizing an `owned` file is expected in at least one place the kit ships today — §11.11 tells projects to add domain rules to `.gemini/styleguide.md` — and the merge-then-ack cycle is what makes that work: quiet until the kit touches the file, one conflict when it does, hand-merge, ack, quiet again.

**A file the project does not want at all is `--decline-file`.** A consumer that has no copy sees `new-kit`, and "skip" is not an answer — a skipped `new-kit` leaves no lockfile entry, so it is offered again on every sync forever. Declining records the kit's current content as a refusal without creating the file, and the entry reports `declined` (silent). Ack is the wrong tool here and the script refuses it in both directions: ack on a file you do not have would report `project-deleted` next scan, and decline on a file you DO have is rejected with a pointer to ack. Like ack, a refusal is per kit VERSION — change the file in the kit and it is offered again — and `--apply-file` undoes it by overwriting the entry.

**What's in the template dir:**

| File | Purpose |
|---|---|
| `vitest.config.ts` | Node env; globals off (explicit imports from `vitest`); two projects — `unit` (parallel, no DB) and `integration` (parallel, present only when Neon creds exist); `globalSetup` → globalSetup.ts; `setupFiles` → test-utils.ts; `root` pinned to the config-file dir so `npm test` from repo root resolves include globs. |
| `globalSetup.ts` | Integration branch lifecycle. Forks the default (production) branch once per run, runs `drizzle-kit migrate` against it, sets `DATABASE_URL` before workers spawn; deletes the branch in `teardown` (`expires_at` 30 min is the crash backstop). Uses `@neondatabase/api-client` — **pin `^2.7.2` or later**: `deleteProjectBranch` takes a single `{ projectId, branchId }` object from 2.7.2, and the older positional form silently requests `/projects/undefined/branches/undefined`, 404s, and leaks a branch per run. Teardown deliberately does not swallow that failure. |
| `integration-helpers.ts` | `dbTest(name, fn)` — the only DB entry point for integration tests. Runs `fn` inside an always-rolled-back Postgres transaction and passes the `tx` handle into the code under test, so parallel tests on the one shared branch stay MVCC-isolated. |
| `auth-mocks.ts` | Typed `MockAuthedUser` + `mockAuthedUser()` / `mockUnauthed()` stubs. |
| `test-utils.ts` | Setup file. Pins `process.env.TZ` (chosen per consumer — UTC for UTC-stored projects, local TZ for projects that store in local time). Exposes a deterministic UUID-v7-like helper. Re-exports auth mocks. |
| `smoke.test.ts` | 4 assertions proving vitest picks up the config, runs the setup file, resolves module imports, runs assertions under node env. |

**TS LSP diagnostics on kit-side files**: the kit repo has no npm deps (see kit-repo-github-config §1), so any LSP scoped to the kit will flag `Cannot find module 'vitest'` / `Cannot find name 'process'` on the template `.ts` files. Expected — they aren't meant to compile in the kit, only in the consumer where the deps exist.

**Enabling it for a consumer:**

```bash
# 1. Deps. Pin api-client ^2.7.2 or later — see the globalSetup.ts row above.
npm install -D vitest '@neondatabase/api-client@^2.7.2' pg

# 2. Point the substitution at the workspace holding the shared module.
#    "apps/shared" in a monorepo, "src" or "." flat, "" if the project has none.
jq '.SHARED_MODULE_DIR = "apps/shared"' .claude/sync-substitutions.json > tmp && mv tmp .claude/sync-substitutions.json

# 3. /sync-dev-kit — the files arrive as `new-kit` and land at their mapped
#    destinations. Every later kit improvement arrives the same way.

# 4. Wire npm scripts in root package.json:
#      "test":       "vitest run -c <shared-module>/vitest.config.ts"
#      "test:watch": "vitest -c <shared-module>/vitest.config.ts"
```

**Test-dir placement** — tests live at `<shared-module>/test/` (sibling of `src/`), NOT under `src/`. Keeps test code out of the production include glob and avoids special-casing test excludes in builder tooling. Runner defaults are not uniform — Mocha defaults to a `test/` directory; Vitest and Jest discover by filename glob (`.test.` / `.spec.`) and don't mandate a layout — but the sibling-of-`src/` convention is common because it works cleanly under all three when configured. `<shared-module>/tsconfig.json` should explicitly `"include": ["src/**/*", "test/**/*"]` so `check-types` still typechecks test files. Tests inside `src/` was tried and reverted after recognizing the real cost (test code leaking into the production include glob).

**TZ pinning** — consumer MUST choose a TZ that matches how their project stores and displays timestamps. The template ships with `America/Chicago` as the default. If your DB stores in UTC, pin `UTC`. The smoke-test assertion also must match.

**Integration pattern — one branch per run, transaction per test.** Reference templates at `_claude-project/templates/testing/`: `globalSetup.ts` (branch lifecycle) + `integration-helpers.ts` (`dbTest`). Same behavior locally and in CI: `globalSetup.ts` forks the project's default (production) branch **once per test run** (Neon copy-on-write), migrates it, points `DATABASE_URL` at it before any worker spawns, and deletes it in `teardown`. One create + one delete for the whole run → no API rate-limiting, no orphaned branches. Uses `@neondatabase/api-client` directly.

**Vitest "projects" split.** `vitest.config.ts` defines two projects: a `unit` project (parallel, no DB — runs in every context including forks and Dependabot PRs that have no Neon creds) and an `integration` project (also parallel, every worker sharing the one branch). The integration project is present only when `NEON_API_KEY` + `NEON_PROJECT_ID` are set.

**Isolation = transaction-per-test.** `dbTest(name, async (tx) => { … })` is the ONLY way a test touches the DB. It runs the body inside a Postgres transaction that is ALWAYS rolled back, so concurrent tests on the one shared branch are MVCC-isolated and run in **parallel** without colliding — nothing persists between tests. There is no exported pool or committing `db` handle, so a test physically cannot write outside a rolled-back transaction; isolation is enforced by the API, not by author discipline. Every production function takes `db` as a parameter, so `tx` threads straight through into the code under test — sequences, triggers, FK cascades, NOTIFY all behave normally inside the transaction. A global-sweep test (a function that scans a whole table) clears that table at the top of its transaction (rolled back after). Carve-out: a test that takes a SESSION-level advisory lock must release it itself — `ROLLBACK` won't.

**Why no fallback to a shared dev DB.** The "fall back to .env DATABASE_URL when Neon creds are absent" pattern was tried and rejected. It silently couples tests to mutable shared state. Postgres sequences (`SERIAL` / `bigserial`) increment globally and are NOT rolled back by transaction rollback, so any mutation test would leave sequence drift on the shared DB forever. An ephemeral branch that's deleted at the end of the run eliminates that entirely and is cheap (~$0.01/run). Use it.

**Required env vars** (set in `.env` locally and as repo Secrets in CI — see "Single-tab Secrets" below):
- `NEON_API_KEY` — personal-scope key, each developer generates their own at `console.neon.tech` → avatar → Account settings → API keys. CI uses the project owner's key. Each dev needs collaborator access to the shared project (Neon UI: "Projects shared with me").
- `NEON_PROJECT_ID` — the shared project ID (e.g. `blue-night-70788817`). Same value for every dev + CI.

**Optional env vars** (project-specific, omit when Neon defaults work):
- `NEON_DATABASE_NAME` — Neon auto-creates a `neondb` database on project creation. If your app's schema lives in a different database (very common), set this so test branches connect to the right DB. Without it, tests get "relation 'product' does not exist" errors.
- `NEON_ROLE_NAME` — defaults to project owner role; set when your app's schema is owned by a non-default role (typical when `NEON_DATABASE_NAME` is also non-default — same name pattern usually).

**Single-tab Secrets.** All four go in repo Secrets (not split between Secrets and Variables). Only `NEON_API_KEY` is technically sensitive; the other three are identifiers. Splitting buys log-visibility but costs a dual-prefix mental model on every workflow edit forever — recoverable any time with one `run: echo "project=$NEON_PROJECT_ID"` step. Single mental model wins for small shops.

**Parent branch.** `globalSetup.ts` forks the project's default (production) branch. Fork-from-production is the canonical answer because:
- prod is the only authoritative reference for "what schema is actually live"
- forking from `dev` risks testing against schema that may never reach prod (devs can leave migrations applied to dev that they later drop from a PR)
- privacy is small concern for shops with shared prod access already

Point it at a different parent only if your project default is not the right reference — change the `createProjectBranch` call in `globalSetup.ts`.

**Migration-during-PR (wired in `globalSetup.ts`).** After forking the branch and setting `DATABASE_URL`, `setup` runs `execSync("npx drizzle-kit migrate")` once against the fresh branch. This is **idempotent**: drizzle tracks applied migrations in `__drizzle_migrations`. The branch forked production, which lacks any migration from THIS PR — so a migration PR applies exactly the new one, and a non-migration PR is a no-op. Either way the pending migration is validated in the same CI pass, same code path as the production deploy step (`npm run db:migrate` post-deploy).

Cost: ~1s per run when a migration is applied (Drizzle is fast on small migration counts). No-op when the branch is already current.

Adopting projects with non-Drizzle migration runners: swap the `execSync` command. The pattern (run-migrations-once-before-tests, in `globalSetup`) is general.

**Required scripts** (root `package.json`):
- `"test": "vitest run -c <vitest-config-path>"` — single command for both the unit and integration projects; the per-run branch + transaction-per-test (`dbTest`) handle isolation.

Integration tests use the `*.integration.test.ts` filename convention as the `integration` project's include glob (the `unit` project excludes it); `npm test` runs both projects in one command.

**Wiring CI** — kit ships a **stack-detecting** `ci.yml` at `_github-project/workflows/ci.yml`. A fast `detect` job checks out and sets `node`/`python` outputs; the rest gate on `needs.detect.outputs.*` (NOT `hashFiles()`, which is empty at job-`if:` time — the workspace isn't checked out yet). Node (root `package.json`) → `dep-alignment`, `check-types`, `biome`, `vitest`; Python (any `pyproject.toml`) → a `python` job running `ruff check` + `pytest` via uv in each pyproject dir (monorepo layouts like `services/<x>/` work with zero config); `semgrep` always runs. (`dep-alignment` is the cross-workspace dependency-version gate — §11.13a / dependency-management.md.) Sync via `/sync-dev-kit` to land it at `<consumer>/.github/workflows/ci.yml`. The Node `vitest` job runs `npm test` — Node projects need a `test` script in root `package.json` pointing at their vitest config (see "Install steps for a consumer" above). Python projects need uv (shop standard) with `ruff`/`pytest` as dev deps — no per-project config. A repo lacking a stack simply skips that stack's jobs; `/merge` self-gates on the check-runs that actually report, so skipped jobs don't block (there are no GitHub-required checks to wait forever on a never-run job).

**No required-status-check promotion.** The pipeline uses no branch protection — `/merge` self-gates by reading the PR's check-runs directly and blocks on any failure, so a job gates merges as soon as it runs on a PR, with nothing to configure on GitHub. New CI jobs are picked up automatically.

Phase 7 integration tests reuse the same `vitest` job once the integration harness is wired (`NEON_API_KEY` + `NEON_PROJECT_ID` secrets via repo Settings — the integration project only activates when both are present).

**Smoke-test latency.** A consumer with only the smoke test takes ~5s in CI; not worth deferring the wiring. Land the workflow with the first real test file or the smoke-test scaffold — either is fine.

**Companion: monorepo-shared workspace wiring (pairs with this scaffolding)**

If your shared module (e.g. `apps/shared/`) is consumed via tsconfig path alias but is NOT a declared npm workspace, the root `npm run check-types --workspaces --if-present` will NOT typecheck it. A real TS error there can ship to main undetected. Close the gap:

1. Create `<shared-module>/package.json` with `private: true`, `"name": "@your-org/shared"`, and `"scripts": {"check-types": "tsc --noEmit"}`.
2. Add `<shared-module>` to the root `package.json` `workspaces` array.
3. If using Vite and `import.meta.env.VITE_*` in shared code, create `<shared-module>/src/vite-env.d.ts` with `/// <reference types="vite/client" />`. This registers `ImportMetaEnv` globally so `import.meta.env.VITE_*` resolves when `tsc` runs standalone in the shared module. Without it, standalone tsc fires TS2339 even though peer workspaces' tsc loads vite types transitively via their own `vite.config.ts`.

**Why this matters** — a shared module that isn't a workspace ships real type errors (TS2339 and friends) invisibly: no CI job type-checks it. Any project with a path-alias-only shared module has this gap until it runs this recipe.

### 11.13a. `dep-alignment` job + `scripts/check-dep-alignment.mjs` (cross-workspace dependency-version gate)

Monorepo invariant enforcement: every shared dependency is declared at **one** version across all workspaces. Version skew across apps produces runtime failures no other check catches, and Dependabot *creates* that skew because it bumps each manifest independently. This gate is the safety net. Full discipline (trust-but-verify, solid-version philosophy, the "logged-in not 200" verification standard, accepted-residuals handling) lives in **`dependency-management.md`**.

**The script.** `scripts/check-dep-alignment.mjs` reads the root `package.json`, expands `workspaces` (literal dirs and trailing-glob `apps/*`; also the `{ packages: [...] }` form), and fails (exit 1) if any dependency name is declared at more than one version-range across the manifests. No install — it reads `package.json` files only. A single-package repo (no `workspaces`) has one manifest, so it's a guaranteed pass: **safe to run on any Node repo.** Fails loud on an unreadable *declared* workspace manifest (never reports "aligned" while a manifest is broken — constitution §X).

**Ships via:** `/sync-dev-kit` copies `_claude-project/templates/scripts/check-dep-alignment.mjs` → `<consumer>/scripts/check-dep-alignment.mjs`. No placeholders.

**CI wiring.** The `dep-alignment` job in `ci.yml` is Node-gated (`needs: detect`, `if: needs.detect.outputs.node == 'true'`), so a Python-only consumer skips it cleanly — it never blocks a non-Node repo (§11.13 "Wiring CI"; a skipped job is neutral, and `/merge` self-gates only on the check-runs that actually report). The job runs `node scripts/check-dep-alignment.mjs` directly (no `npm ci`).

**Local convenience.** Consumers add to root `package.json`:

```json
"scripts": { "check:deps": "node scripts/check-dep-alignment.mjs" }
```

so `npm run check:deps` reproduces the CI gate locally. The CI job calls the script directly and does NOT depend on this npm script existing, but adopting it is the documented convention (the script's failure message and `dependency-management.md §1` both assume `npm run check:deps`).

**Updating a shared dep:** bump it to the same version in *every* workspace that declares it in one change, run `npm run check:deps` (must be ✓), then verify per `dependency-management.md §5`. Never bump one workspace and not the others — the gate fails the PR, by design.

### 11.15. `/e2e` skill (Claude-as-intelligent-tester)

**What this is.** A Skill that implements the locked E2E testing model (kit `pipeline.md` §1.5): Claude drives `agent-browser` through plain-English flow files, detects failure behaviorally, reports pass/fail. **Not a scripted test suite. Not Playwright. Not Stagehand.**

**Components ship:**
- `_claude-project/skills/e2e/SKILL.md` — the skill protocol (discovery, scoping via PR diff, server startup per dev-server.md, execution, reporting)
- `_claude-project/skills/e2e/gen-report.mjs` — data-driven HTML report generator (theme + true CSS lightbox baked in); the run writes `logs/e2e/results.json`, this renders `report.html`
- `_claude-project/skills/e2e/example-flow.md` — copy-paste template for consumer projects to fill in with their own flows

**Report.** A run produces a self-contained HTML report — per-step ✅/❌ with inline (base64) screenshots — so a run can be fired off and reviewed async; the screenshots are the audit trail behind each pass, not a substitute for the behavioral judgment.

**Authoring companion — `e2e-author` skill.** Writing and maintaining flow files is its own skill (`_claude-project/skills/e2e-author/SKILL.md`), sibling to the runner. It carries the flow-file format, the frontmatter spec, and a recipe library for the recurring agent-browser gotchas (off-screen click won't fire, env values with spaces truncate, mouse-move arg split, viewport, OTP-from-DB), plus a dry-run-before-done rule so new flows can't rot unrun. `/e2e` runs flows; `/e2e-author` writes them.

**Consumer setup:**
1. `/sync-dev-kit` copies the skill into `<consumer>/.claude/skills/e2e/`.
2. Consumer creates flow files at `apps/shared/test/e2e/*.md` (monorepo layout) or `test/e2e/*.md` (flat layout). Copy `example-flow.md` as a starting point.
3. Each flow declares `triggers:` — glob patterns for the files it covers. The skill computes the diff∩triggers intersection **only when the user picks the diff-scoped scope option** (see below).

**Invocation modes (documented in SKILL.md):**
- `/e2e all` — force-run every flow regardless of diff (no question)
- `/e2e <flow-name>` — run a single flow by `name:` frontmatter value (no question)
- `/e2e` with no arg — ask the **scope question** (one `AskUserQuestion`): diff-scoped (fires the diff logic) / all flows / select specific (a second `multiSelect` question listing discovered flows).

`/e2e` is a standalone command. It runs only when the user invokes it — `/merge` does not call it and asks nothing about E2E.

**Separation of concerns.** Skill = orchestration + scope selection; flow files = test definitions with their own triggers. Each concern has one home.

**What the skill does NOT do:**
- No scripted assertions / `expect()` calls — failure is behavioral
- No retries or flake-tolerance — a step failing is a real signal
- No browser fleet / parallelism — single `agent-browser` session per flow

**Failure handling.** `/e2e` reports pass/fail — any ❌ is a real signal. Decide per-case whether it's a real bug (fix) or flow-definition drift (update the flow file in the same PR). Don't bypass a red flow.

**Known open work (deferred).** One loose end worth capturing for future iteration:

1. **Substantive behavioral assertions.** MVP flows are render-checks ("homepage loads", "form renders"). Real-value accretion is flow-specific business logic — validate price math on product detail, cart total recalculates when shipping address changes, Stripe elements actually mount and accept input, post-login dealer pricelist reflects the correct tier. Accretion-on-demand per flow when a specific bug class starts slipping through.

---

### 11.16. Dev server protocol (`rules/dev-server.md` + `hooks/dev-server-guard.sh`)

**What this is.** A behavioral rule + a PreToolUse Bash hook that together govern how Claude interacts with dev servers. Lives in kit-synced `rules/dev-server.md` and `hooks/dev-server-guard.sh`. The rule file is the source of truth; the hook enforces the single rule that matters most at tool-call time.

**Why it exists.** A blunt `NEVER RUN THE DEV SERVER WITHOUT EXPLICIT PERMISSION` block on `npm run dev` / `npm start` / `pkill` makes every legitimate E2E run a permission round-trip. The rule instead targets the specific failure modes it must prevent — Claude stacking duplicate servers (`:3001` → `:3002` → `:3003`), killing ports to "take" them from the user, starting alternate ports when the primary is in use, or starting servers for trivial reasons:

- Rule 1 (always check first) + rule 2 (use the occupied port, don't alternate-port) handle the stacking-ports failure.
- Rule 4 (never kill processes you didn't start) handles the cardinal sin — killing the user's live testing server.
- Rule 5 (leave servers running after use) handles the churn of tear-down-then-restart cycles.
- Rule 3 (if the port is free, start with announcement) + the hook's anti-kill guard govern starting and killing servers without a blanket block on `npm run dev`.

**The hook.** `dev-server-guard.sh` is now a focused anti-kill guard — it blocks `pkill`, `fuser -k`, `lsof … | xargs kill`, and similar patterns targeting dev servers. It does NOT block `npm run dev` starts; the behavioral rule governs those.

**Emergency override.** `SKIP_SERVER_GUARD=1 <command>` bypasses the kill-block for cases where the user has explicitly authorized killing a specific process. Use sparingly and only when authorized.

**Ships via:** `/sync-dev-kit` copies `_claude-project/rules/dev-server.md` → `<consumer>/.claude/rules/dev-server.md` and `_claude-project/hooks/dev-server-guard.sh` → `<consumer>/.claude/hooks/dev-server-guard.sh`. Hook must remain executable (`chmod +x`). Hook registration in `.claude/settings.json` is per-project — the `PreToolUse` block must reference `$CLAUDE_PROJECT_DIR/.claude/hooks/dev-server-guard.sh`; adopting projects must include that entry.

**Project-level override.** If a project still carries a `## Development Server Protocol` block in `.claude/rules/project/projectrules.md`, delete it — the kit-synced rule supersedes it.

---

### 11.17. GitHub email noise — what triggers what, and how to silence it

Each dev's noise tolerance differs. This section maps every email GitHub sends on a project running this pipeline to the setting that controls it, so each dev can decide for themselves what to keep and what to mute. **All settings are per-account, not per-repo or per-org** — your tuning doesn't affect anyone else.

**Settings live in three places (override priority: thread > repo > account):**

1. **Account settings** — `https://github.com/settings/notifications`. Global routing rules, default email, Actions/Dependabot scope, comment subscriptions.
2. **Repo Watch dropdown** — top-right of any repo page. Choose `All Activity` / `Participating and @mentions` / `Ignore` / `Custom`. `Custom` lets you check Issues / Pull requests / Releases / Discussions / Security alerts independently.
3. **Per-thread mute** — on a single PR / issue / discussion: `Unsubscribe` link in the right sidebar. Only stops that one thread.

**Trigger → setting map:**

| Email trigger | Source | Where to silence |
|---|---|---|
| New PR opened on a watched repo | Repo Watch | Repo Watch → Custom → uncheck Pull requests, OR set Watch to `Participating and @mentions` |
| New issue opened on a watched repo | Repo Watch | Repo Watch → Custom → uncheck Issues, OR drop to Participating |
| Comment on a PR/issue you're not subscribed to | Repo Watch | Same as above |
| Comment on a PR you authored / commented on | Account: Participating | Account → Notifications → Participating → uncheck Email (rare — most devs keep this on) |
| @mention of you anywhere | Account: Participating | Same as above. Note: Participating ALSO covers PRs you reviewed, issues you assigned yourself, etc. |
| PR review submitted on your PR | Account: Participating | Same. Or per-thread mute. |
| PR you authored was merged | Account: Participating | Same. Most devs want this one. |
| New release published | Repo Watch | Repo Watch → Custom → uncheck Releases |
| Discussion created/replied | Repo Watch | Repo Watch → Custom → uncheck Discussions |
| GitHub Actions workflow failed | Account: Actions | Account → Notifications → Actions → set to `Only notify for failed workflows` (default) or `Off` |
| GitHub Actions workflow succeeded after failing | Account: Actions | Same. Setting also controls this. |
| GitHub Actions workflow first-time failure / restored success | Account: Actions | Same setting; granular sub-options in the same panel. |
| Dependabot security alert opened | Account: Dependabot alerts | Account → Notifications → Dependabot alerts → toggle Email/Web. Repo-level kill switch: Settings → Code security → Dependabot alerts. |
| Dependabot version-update PR opened | Repo Watch (it's a PR) | Repo Watch → Custom → uncheck Pull requests, OR drop to Participating. Dependabot PRs you don't review never fire Participating. |
| Gemini PR summary / code review | Repo Watch | Posted as PR comments — Repo Watch / Participating. Gemini does not have a separate noise-suppression knob like CR's `review_status`. |
| Gemini replied to your inline comment | Account: Participating | Same as any reply. |
| Vulnerability alert (org-wide) | Org settings | `https://github.com/organizations/<org>/settings/security_analysis` — owner only. |
| Workflow run cancelled / skipped | Not emailed by default | Only `Only notify for failed workflows` produces emails; cancels/skips are silent. |

**Common scope-down patterns:**

- **"Just deploy failures, nothing else"** → set every repo's Watch to `Participating and @mentions` (or `Ignore` if you don't want even those); Account → Actions → `Only notify for failed workflows`. You'll still see PRs you author / review / get mentioned in, plus any deploy-failure email.
- **"PRs I'm involved in only"** → Watch all repos as `Participating and @mentions`. No `All Activity` anywhere. Most signal-heavy devs land here.
- **"Watch the team's repo, ignore my own"** → mix Watch settings per repo; account-level rules are global, repo Watch is per-repo.

**Per-org email routing:** Account → Notifications → "Custom routing" lets you send each org's emails to a different address (e.g. `work@`, `personal@`). Useful if you contribute across multiple orgs and want filtering at your mail client.

**What you cannot disable:**
- Account security emails (login from new device, password change, 2FA changes) — always on, by design.
- Direct repository invitations.
- Org membership invitations.

**Verifying your config:** check `https://github.com/notifications` shortly after a known-noisy event (open a draft PR, push to it). If something showed up that you tried to mute, the relevant setting is one of the rows above; trace the trigger column to the source.

---

### 11.18. UI inventory rule (synced as `template` mode)

**What it is.** A per-project rule at `.claude/rules/project/ui-inventory.md`, path-targeted to `{**/*.tsx,**/*.jsx}` so it auto-loads on every UI edit. It enumerates, as content rather than as references: the project's list/detail patterns and which to use when, every pattern reference file and what it governs, the components that already exist, and the standing prohibitions.

**Why it is not just another pointer.** `rules/ui-patterns.md` and `rules/ui-design.md` already auto-load on the same globs, and both tell the reader to go and open a skill. Following a pointer is a separate act, taken at the moment you already feel ready to write — so it is the step that gets skipped, and a screen ships that reinvents a list pattern and hand-rolls a submit control whose component was one import away. The inventory carries the names themselves, in the forced read, which is what removes "I did not know it existed" as a possibility.

**Why it ships from `templates/`.** `is_skipped` excludes `_claude-project/rules/project/*` from the scan entirely — that tree is the consumer's own, and the kit never compares against it. So a seed placed there would reach nobody. `_claude-project/templates/ui-inventory.md` plus an explicit `dest_for_kit_path` entry is what lets the kit put one file into a directory it otherwise never writes to.

**Mode is `template`, and `owned` would be incoherent.** The file's content IS this project's inventory; a consumer that has not replaced every line has not adopted it. It arrives once as `new-kit`, the project rewrites it, and later kit changes to the shape surface as `template-drift` — informational, never reconciled. Keep-ours is the expected answer, followed by an ack (§11.13) so the same drift does not re-report every sync.

**How it stays true.** Not by a note asking nicely — through the two skills that already gate on human sign-off. The `ui-patterns` skill's write-once step adds a pattern's line in the same pass that writes its reference; the `design-system` skill's reconciliation pass adds a component's line in the same pass that documents it in `design.md`. An inventory that lags is worse than none, because it is read as complete.

**Kit does not dogfood it** — no UI here, nothing to enumerate. Listed in the dogfood manifest in `.claude/rules/project/dev-kit-workflow.md`.

---

## 12. The dev-server subsystem

Sibling to gitflow (§3). Owns one concern: launching dev servers in the correct directory with a deterministic port.

### 12.1. Why this subsystem exists

The Agents-view workflow makes a naive "cmd-t → `cd` → `npm run dev`" flow unreliable, for two reasons:

1. **iTerm `cmd-t` lands in `~/projects`, not the project.** Agents view spawns the host shell from `~/projects` with no project context, so "Reuse previous session's directory" reuses the wrong directory.
2. **Silent vite port-bump.** When `:3001` is occupied (most projects default to it), vite silently bumps to `:3002`. Browser-testing `localhost:3001` then tests the wrong project's server.

Solving #1 by adjusting iTerm settings is impossible — Agents view doesn't update the host shell's cwd. Solving #2 manually requires the user to know every project's port and check `lsof` before every `npm run dev`. Neither is scalable across multiple projects.

`/dev` is the structural fix: explicit `osascript`-spawned iTerm tab with the correct `cd`, plus `lsof` pre-check with `+10` port-step on collision.

### 12.2. Layout

| Path | Purpose |
|------|---------|
| `_claude-project/skills/dev-server/SKILL.md` | Natural-language routing layer (same shape as gitflow skill). |
| `_claude-project/skills/dev-server/scripts/dev.sh` | Implementation: project-root detection, port probing, osascript invocation. Supports `--tunnel` flag (§12.3.2). |
| `_claude-project/skills/dev-server/scripts/dev-with-tunnel.mjs` | Implementation for `--tunnel`: spawns `cloudflared tunnel run` + `npm run dev:<app>` in one tab. Hostname hardcoded as `<app>.thenextage.com` (shop standard). Byte-identical across consumer projects. See §12.3.2. |
| `_claude-project/skills/dev-server/templates/DevServer.json` | iTerm DynamicProfile template. Installed once per dev machine to `~/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json`. See §12.3.1. |
| `_claude-project/commands/dev.md` | `/dev` slash command spec. |
| `_claude-project/rules/dev-server.md` | The 5 lifecycle rules (check first, use occupied, never kill, leave running). Updated with `/dev` canonical-path declaration. |
| `project-documentation/devserver-cheatsheet.md` | One-page user reference. Companion to `gitflow-cheatsheet.md`. |

### 12.2.1. DevServer iTerm profile (one-time install per dev machine)

`/dev` spawns tabs using a separate iTerm profile called **DevServer** with `Allow Title Setting = true`. Required because:

- Standard iTerm profiles for daily use (CPL, etc.) set `Allow Title Setting = false` to prevent Claude Code's startup OSC-0 width-probe from corrupting Claude's tab title. The width probe is hardcoded in the Claude binary at startup (one OSC 0 sequence inside an alt-screen buffer, no OSC 22 push/pop to restore — verified empirically against `~/.local/bin/claude`).
- With the regular profile's `Allow Title Setting = false`, iTerm auto-derives `session.name` from cwd via shell integration's `OSC 1337 ; CurrentDir` updates. Any AppleScript `set name` call is overridden within ~300ms.
- The DevServer profile flips `Allow Title Setting = true`, which lets `/dev`'s inline `printf '\e]0;TITLE\a'` actually set the title. Since this profile is used ONLY by `/dev`-spawned tabs (which run vite/etc. — no title-probing), there's no collateral damage on Claude or any other tab.

Install:

```bash
mkdir -p "$HOME/Library/Application Support/iTerm2/DynamicProfiles"
cp <project>/.claude/skills/dev-server/templates/DevServer.json \
   "$HOME/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json"
```

iTerm hot-loads DynamicProfiles — no restart needed. `/dev` fails with a clear error if the profile is missing.

### 12.3. Invocations

| Input | Effect |
|-------|--------|
| `/dev` | List `dev*` scripts from the resolved project's `package.json`. Await user choice. |
| `/dev <app>` | Stage `npm run dev:<app>` at the project root on the detected port (auto-bumped on collision). |
| `/dev <app1> <app2>` | One iTerm tab per app. |
| `/dev <app> --tunnel` | Stage `npm run dev:tunnel:<app>` — cloudflared + vite in one tab, public at `<app>.thenextage.com`. Mutually exclusive with `--main`. See §12.3.2. |
| `/dev --status` | List listening processes on `:3000-:3099` (pid, port, cwd, cmd). Never kills. |

### 12.3.2. Cloudflare tunnel mode (`--tunnel`)

`/dev <app> --tunnel` swaps the staged script from `dev:<app>` to `dev:tunnel:<app>`. Consumer projects wire that script in `package.json`:

```json
"dev:tunnel:shop":   "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs shop",
"dev:tunnel:dealer": "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs dealer"
```

The kit ships `dev-with-tunnel.mjs` at `_claude-project/skills/dev-server/scripts/dev-with-tunnel.mjs`. **Byte-identical across all consumer projects.** Hostname convention is `<app>.thenextage.com` — this shop's standard tunnel parent domain, hardcoded. Not configurable per project: every consumer's apps live under the same parent.

`~/.cloudflared/config.yml` (per-user-machine, not in the repo) carries per-app ingress rules:

```yaml
ingress:
  - hostname: shop.thenextage.com
    service: http://localhost:3001
  - hostname: dealer.thenextage.com
    service: http://localhost:3010
```

`dev-with-tunnel.mjs`:

1. Reads `PORT` from env (set by `dev.sh`'s `lsof` pick).
2. Spawns `cloudflared tunnel run` (uses local `~/.cloudflared/config.yml`).
3. Injects `BETTER_AUTH_URL` and `VITE_BETTER_AUTH_URL` = `https://<app>.thenextage.com` into the dev-server environment so any better-auth (or other origin-aware service) sees the tunnel URL as its public base. Without this, better-auth defaults to `http://localhost:<port>` and login redirects + cookie domains break under the tunnel. Both env vars are no-ops in apps that don't use better-auth.
4. Spawns `npm run dev:<app>` once the tunnel reports "Registered tunnel connection".

**Multi-replica behavior.** `/dev shop --tunnel` + `/dev dealer --tunnel` each spawn their own `cloudflared` process. Cloudflare treats them as replicas of the same tunnel UUID; both share the ingress map; traffic load-balances. Each replica costs ~30–50MB RAM + a few edge keepalive connections. Acceptable; matches the "single-script-per-tab" model.

**One-time DNS** (Cloudflare dashboard, per-machine setup): wildcard CNAME `*.thenextage.com` → `<tunnel-uuid>.cfargotunnel.com`, Proxied. Universal SSL covers single-label wildcards natively; no paid Advanced Certificate needed.

### 12.4. Port-override algorithm

For each chosen app, `dev.sh`:

1. Reads default port from `apps/<app>/vite.config.ts` (monorepo) or root `vite.config.ts` (flat). Falls back to `3000`.
2. Probes via `lsof -iTCP:<port> -sTCP:LISTEN`. If free, uses it.
3. On collision: steps `+10`. Cap at 3 hops:
   - shop: `3001 → 3011 → 3021`
   - dealer: `3010 → 3020 → 3030`
4. Refuses beyond 3 hops with the occupant list for each occupied slot.
5. Launches via vite CLI `--port` override: `npm run dev:<app> -- --port <N>`. CLI flag overrides `vite.config.ts` without any config change.

### 12.5. Why no hook enforcement (and why that's fine)

Gitflow has `git-guard.sh` blocking raw `git commit` / `git push` because those mutate shared state (origin/main, releases, CI) — silent bypass = production damage.

Dev-server has **no** equivalent guard. Three reasons:

1. **E2E auto-starts servers.** `.claude/skills/e2e/SKILL.md` step 3 starts a dev server when no port is occupied (required so a verification run can proceed unattended). A hook would either block e2e (breaking the verification path) or need an env-var bypass (every bypass token weakens the structural claim).
2. **`agent-browser` precedent.** Browser automation is also "skill-only by convention," no hook blocks raw `chromium-launcher` invocations. Works fine because the skill is the path of least resistance.
3. **Failure mode is local and recoverable.** Silent vite port-bump testing the wrong server is annoying, not destructive. The `/dev` skill's `lsof` pre-check eliminates it for anyone using the skill — and they will, because it's the easy path.

The 5 rules in `dev-server.md` remain authoritative for any running server, regardless of how it was started. The `/dev` skill makes following them trivial; e2e codifies its own exception.

### 12.6. Universal across projects

Lives in `_claude-project/skills/dev-server/` → synced to every consumer project via `/sync-dev-kit` (§9). Same skill works for:

- Monorepos with multiple workspace apps (`dev:shop`, `dev:dealer`, …).
- Flat repos with a single `dev` script (`/dev` prompts → runs the one option).
- Any project following the `dev*` script convention in root `package.json`.

No per-project zshrc helpers. No project-specific shell aliases. The kit is the source of truth.

### 12.7. Open work

- Non-vite default-port detection (Next.js, Astro). Currently falls back to `3000`. Future: project-level `.claude/dev-server.json` map.
- `osascript` is macOS / iTerm2 specific. Cloud sessions have no iTerm; the skill exits with a clear message and the user falls back to `npm run dev:<app>` manually in whatever shell the cloud environment provides.

---

## 12a. The design-system subsystem

Sibling to gitflow (§3) and dev-server (§12). Owns one concern: applying a project's design system consistently and refusing UI work in a project that has no design system spec.

### 12a.1. The split between universal skill and per-project spec

The kit ships a project-agnostic `design-system` skill that knows the **discipline** of using a design system (semantic-over-primitive, no inline styles, no raw hex, no `space-y-*`, hover-via-Tailwind, `cn()` for conditionals). It does NOT carry any project-specific tokens or class names — those live in a per-project `design.md` at the project root, conformant with the [google-labs-code `design.md` spec](https://github.com/google-labs-code/design.md).

The contract:

| Concern | Lives in |
|---|---|
| Brand voice, color tokens, typography tokens, spacing scale, atom property tokens | Per-project `<project-root>/design.md` |
| Universal discipline (semantic-over-primitive, no inline style, etc.) | Kit-canonical `_claude-project/skills/design-system/SKILL.md` |
| Runtime token values consumed by the browser | Per-project CSS `@theme` block (typically `src/styles.css` or `apps/shared/src/styles.css`) |
| Accessibility patterns | Kit-canonical `_claude-project/rules/a11y-baseline.md` (auto-loaded on JSX/TSX) |

If the CSS `@theme` block and `design.md` diverge on a value, CSS wins (the browser sees CSS), and `design.md` should be updated to match.

### 12a.2. Skill invocation via path-targeted rule

The kit ships a path-targeted rule at `_claude-project/rules/ui-design.md` with frontmatter:

```yaml
---
paths: "{design.md,**/*.tsx,**/*.jsx,**/*.css,**/*.scss}"
---
```

When Claude edits a matching file in a consumer project, the rule auto-loads and instructs Claude to invoke the `design-system` skill via `Skill({skill: "design-system"})`. The rule fires on:

- JSX/TSX files (component styling)
- CSS/SCSS files (token definitions)
- `design.md` at project root (the spec itself — edits should pass through the skill so the linting expectation is surfaced)

The skill then reads the project's `design.md` and applies the universal discipline against the project's tokens.

### 12a.3. Hard stop when `design.md` is missing

The skill REFUSES to proceed if `<project-root>/design.md` is not present. Surfaces the gap to the user verbatim and waits for direction. Two valid resolutions:

1. **Generate `design.md`** from the codebase (a one-time bootstrap per project). The CSS `@theme` block is the source data; the resulting `design.md` is its documented superset.
2. **Explicit single-task authorization** for ad-hoc styling — rare, treated as tech debt to reconcile later.

The hard stop exists because ad-hoc styling without a design system spec is how token drift starts. Refusing forces the project to either commit to the discipline or explicitly opt out per-task.

### 12a.4. Spec-compliance validation

`design.md` MUST conform to the google-labs-code spec. The skill instructs Claude to run the linter whenever `design.md` is modified:

```bash
npm run lint:design
```

The linter is wired as a **declared** dev tool, not run ad-hoc: each consumer adds `@google/design.md` to `devDependencies` and a `"lint:design": "design.md lint design.md"` script. Declaring it (rather than `npx @google/design.md …`) keeps the lint reproducible and avoids agent sandboxes blocking an undeclared external download. `package.json` is consumer-owned (not a kit-synced file), so this dep + script are added per project at setup.

Lint must pass before the change is committed. The spec defines: optional YAML frontmatter token block (`colors`, `typography`, `rounded`, `spacing`, `components`), markdown body with required-order sections (Overview, Colors, Typography, Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts), atom-level component definitions with property tokens.

### 12a.5. Scope: atoms only

Per the spec, `design.md` covers **atom-level styling** — buttons, chips, lists, tooltips, checkboxes, radios, input fields, plus any domain-specific atoms the project defines. Property tokens: `backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`.

`design.md` does NOT cover:

- Composite layouts (modal scaffolds, dashboard widget composition)
- Interaction patterns (loading states, optimistic UI, error recovery)
- User flow patterns (auth flows, multi-step wizards)
- Code organization conventions

When the task is at one of those layers, the project's own codebase is the cookbook — find a similar production component, adapt the pattern. The design-system skill does not duplicate the cookbook content; it directs Claude to read existing code.

### 12a.6. Bootstrap for new projects

A new kit consumer needs to author `design.md` once before any UI work proceeds. Recommended workflow:

1. Build out the CSS `@theme` block in `src/styles.css` (or the project's equivalent) with the project's tokens.
2. Generate `design.md` by documenting the `@theme` content per the google spec — section order, YAML token frontmatter, atom definitions for the components that exist.
3. Add `@google/design.md` to `devDependencies` + a `"lint:design": "design.md lint design.md"` script, then run `npm run lint:design` until clean.
4. Commit. First subsequent UI edit triggers the path-targeted rule, which invokes the skill, which reads the now-present `design.md`.

### 12a.7. Kit does not dogfood the skill

The kit itself has no UI — no JSX/TSX, no `design.md`. The skill and its companion rule live only in `_claude-project/` (kit canonical for consumer sync) and NOT in the kit's own `.claude/` working copy. Consumer projects DO install both, automatically via `/sync-dev-kit`.

The design-system skill is one entry in a larger set of template-only (not-dogfooded) items. The authoritative list — what the kit excludes from its own `.claude/` and why — is the **"Kit dogfood manifest" table in `.claude/rules/project/dev-kit-workflow.md`**, which also carries the mandate that every new kit item gets an explicit dogfood decision. This section is illustrative; that table is the single source of truth.

---

## 12b. Autonomous mode

`/autonomous <what to work on>` is the only way a turn becomes autonomous when a human launched it. The mode itself is defined in `rules/autonomous-sessions.md`; the command exists to enter it reliably.

The argument is free-form natural language. Scope resolves from a named plan file (`/autonomous execute plan @<path>`), from the conversation (`/autonomous I'm stepping away — finish what we've been discussing`), or from the argument itself (`/autonomous fix the failing integration tests and open a PR`).

Every invocation converges on the same steps: resolve scope, get it into a plan document under `project-documentation/temporary/`, stamp an autonomous line with the date into that document, run to completion without check-ins, then clear the stamp and produce the final report.

The stamp is the point. The mode is declared mid-conversation, and a long turn gets summarized — taking the sentence that set the mode with it. A line in a file survives compaction; the conversation does not.

Dogfooded: the command lives in both `_claude-project/commands/autonomous.md` and the kit's own `.claude/commands/`.

Full spec: `commands/autonomous.md`.

## 13. Troubleshooting

### 12.1. Cloud session can't see my hooks

Verify `.claude/settings.json` exists in the repo and is committed. Cloud loads from the repo only.

### 12.2. `git commit` blocked by hook

`git-guard.sh` denies raw `git commit` — use `/commit`, `/checkpoint`, or
`/ship-main` instead. The gitflow scripts are unaffected by the hook (§3.1), so
if a *slash command* is what got blocked, the deny message will name some other
operation (`reset`, `restore`, `revert`, `clean`, `checkout <file>`); read it
rather than assuming the commit itself was refused.

Typecheck and commitlint failures now surface as CI gates on the PR, not as a
local deny. Fix them from the PR checks.

Emergency override, under explicit user authorization: `SKIP_GIT_GUARD=1 git commit …`

### 12.3. MCP server fails to authenticate

Verify `EXA_API_KEY` is exported in the current shell. For cloud sessions, verify it's in the cloud environment's env-var editor.

### 12.4. Sync shows files I don't recognize as kit-only

Kit added new files since your last sync. The lockfile's `lastSyncedCommit` is behind kit HEAD. Run through the diff review normally; accept or reject each.

### 12.5. `/deploy` failed or didn't ship

`/deploy` is fully local. If it exits non-zero, the script reports the exit code:

- `2`: bad args
- `3`: not on main → `git checkout main`
- `4`: dirty working tree → `/commit` first
- `5`: out of sync with origin → `git pull` or push pending work
- `6`: HEAD has failed CI check-runs on GitHub → fix CI on main first
- `7`: no commits since last `v*.*.*` tag → nothing to deploy
- `10`: `npm version` / manifest-mutation failed
- `11`: push rejected → is require-PR off for this repo? (require-PR on `main` rejects direct pushes; the pipeline expects it off — pipeline.md §1.1)
- `12`: `gh workflow run deploy.yml` failed → does `deploy.yml` exist on the default branch with `workflow_dispatch:` enabled?
- `13`: deploy run watched failed → check the Actions tab for the run URL printed by the script

If `/deploy` succeeded but the deploy workflow itself failed, see the run URL in the script output and inspect Actions tab.

### 12.6. A consumer developer's Claude session keeps falling back to raw git

The developer didn't set `includeGitInstructions: false` in their `~/.claude/settings.json`. See `developer-onboarding.md`. Hooks should still catch raw git, so this is a fallback-frequency issue, not a correctness issue.

---

## 14. What's deliberately NOT here

- **Automated kit-update PRs.** Single-user kit. No need for GitHub Actions that PR kit updates to consumer projects. The maintainer runs `/sync-dev-kit` when ready.
- **Kit versioning / releases.** The kit repo is public, but is not distributed as a versioned artifact — there is no package, tag, or release to depend on. Syncs point at kit HEAD commit SHA, not a version.
- **Install commands as slash commands.** `/install-kit`, `/install-statusline`, `/install-cpl`, `/install-kit` became handbook sections (TBD — see issue log). They're one-time ops, docs are more durable than commands.
- **Global sync.** Dropped. The only global artifacts are the dev-kit bootstrap and statusline, installed once per machine. No ongoing sync.

---

## 15. References

- `skills/gitflow/SKILL.md` — gitflow skill, trigger metadata and routing
- `skills/gitflow/references/commit-types.md` — commit type emoji/format reference
- `skills/gitflow/references/changelog-rules.md` — changelog entry rules
- `skills/gitflow/scripts/*.sh` — the scripts that actually do git operations
- `.claude/rules/git.md` — git workflow rule (reminder layer)
- `.claude/hooks/git-guard.sh` — raw-git blocker (commit + destructive ops)
- `templates/settings.base.json` — settings.json starting point for new projects
- `templates/.mcp.json` — MCP template for new projects
- `developer-onboarding.md` — second-dev setup doc
- Anthropic docs: https://code.claude.com/docs/en/claude-code-on-the-web.md (cloud session behavior)
- Anthropic docs: https://code.claude.com/docs/en/mcp.md (MCP config, env var expansion)
- Exa docs: https://docs.exa.ai/reference/exa-mcp (Exa MCP HTTP transport for Claude Code)
