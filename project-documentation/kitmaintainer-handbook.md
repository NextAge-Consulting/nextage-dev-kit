# Kit Maintainer Handbook

The kit maintainer's handbook: how the kit is built, how its subsystems work inside, and how a change to it reaches every project. Working **with** the kit — developing, designing or running the pipeline in a project that uses it — starts at `overview.md` instead.

This doc is the architectural anchor. When something in the kit, a hook, a command, or a rule is unclear or appears to conflict with another piece, this handbook wins. Update the handbook first, then update the kit to match.

---

## 0. Kit source layout

The kit is just another project — it has its own `.claude/` with project-custom commands that only make sense when working in the kit. Everything a consumer receives syncs via `_claude-project/`. Nothing is installed globally for consumers at all.

| Path | Destination | Purpose |
|------|-------------|---------|
| `_claude-project/` | consumer `<project>/.claude/` via `/sync-dev-kit` | Project-level config that should exist in every project: rules, hooks, skills, the gitflow commands (`/work` included), agents, `settings.json`, `templates/` |
| `_github-project/` | consumer `<project>/.github/` via `/sync-dev-kit` | GitHub Actions workflows + dependabot config |
| `_gemini-project/` | consumer `<project>/.gemini/` via `/sync-dev-kit` | Gemini Code Assist config + styleguide (PR-time AI reviewer) |
| `_claude-maintainer/` | `~/.claude/`, copied by hand (§0.1) | The MAINTAINER surface — only the person who syncs the kit into projects: `scripts/sync-dev-kit.sh`, `commands/sync-dev-kit.md`, `scripts/review-stack.sh`, `commands/review-stack.md`, `kit-maintainer.md`. A consumer machine never receives the sync machinery, so it cannot run a sync. `migrations/` is not copied: each holds a codemod and a `PROMPT.md` the maintainer pastes into a consumer session after a sync, which finds the codemod through `devKitPath`. |
| `_statusline/statusline.sh` | `~/.claude/statusline.sh` via `/install-statusline` (one-time) | The kit's custom statusline asset; referenced by `install-statusline.md`. |
| `tests/` | Nowhere — sync reads only the `_*-project/` folders | Tests for kit-shipped files that must not ship with them, e.g. `tests/templates/check-workspace-tiers.test.sh`. Each case copies the real script into a throwaway repo where sync would put it. |
| `.claude/` | This kit repo's own active config | Mirror of `_claude-project/` PLUS kit-custom commands and scripts that only make sense in this repo: `install-cpl`, `install-statusline` (commands + their helper scripts). These never propagate anywhere. |

### Why consumers get nothing globally

**A command file in `~/.claude/commands/` outranks a project's copy of the same name.** Claude Code resolves personal over project, so a global command silently wins — and `/sync-dev-kit` deliberately does not scan `~/.claude/`, so it can never be updated or removed by the normal pull. The result is a file that ships once and then diverges forever, invisibly.

`/work` used to ship globally, on the reasoning that it is launched from the agents view before the session is inside any repo. That reasoning is dead: `@projectname` is how you enter a client session now, and `/work` is never issued from the agents view. It ships per-project like every other kit command.

The one-way door that left behind is handled at the only reliable point — `work.sh` refuses to run, with removal instructions, when it finds a `~/.claude/commands/work.md`. It is the one thing that executes on every `/work`, whichever doc won, so it is the only place the stale file can be caught. Neither a sync nor an installer can be relied on to run.

`/sync-dev-kit` remains global by necessity — it must run from any project directory — but it is installed only on a maintainer machine, by hand. The maintainer syncs projects ahead of the other devs; a consumer machine that could sync would clobber that work. Withholding the script is stronger than guarding it: there is nothing to bypass.

### 0.1. Setting up a maintainer machine

This happens twice in the kit's life — a new machine, or someone taking over a fork — so it is prose, not a command. A dedicated installer for a twice-ever operation is a maintenance surface that earns nothing, and one that is run so rarely it can never be trusted to deliver a change.

Clone the kit, then from inside it:

```bash
KIT=$(pwd)

# 1. The maintainer surface — commands and scripts.
mkdir -p ~/.claude/commands ~/.claude/scripts
cp _claude-maintainer/commands/*.md      ~/.claude/commands/
cp _claude-maintainer/scripts/*.sh       ~/.claude/scripts/
cp _claude-maintainer/kit-maintainer.md  ~/.claude/
chmod +x ~/.claude/scripts/*.sh

# 2. Where the kit lives. `sync-dev-kit.sh` reads this and cannot run without it.
cat > ~/.claude/dev-kit-config.json <<EOF
{
  "devKitPath": "$KIT",
  "lastConfigured": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

# 3. The two per-machine markers. Deliberately unshipped — a consumer
#    machine must not be able to self-promote.
echo '@kit-maintainer.md' >> ~/.claude/CLAUDE.md   # makes the maintainer rule load
touch ~/.claude/kitmaster                          # makes block-kit-edit.sh go inert
```

Both markers are required and they gate different things. The `@kit-maintainer.md` import is what makes the maintainer rules load; the `kitmaster` file is what makes `block-kit-edit.sh` stop blocking kit edits. A machine with one and not the other is misconfigured — the rule without the marker tells you that you may edit kit files while the hook refuses, and the marker without the rule yields the hook while nothing tells you the routing rules.

Verify:

```bash
ls ~/.claude/scripts/sync-dev-kit.sh ~/.claude/kitmaster
jq -r .devKitPath ~/.claude/dev-kit-config.json
grep kit-maintainer ~/.claude/CLAUDE.md
```

**`~/.claude/` is a copy, never a symlink.** Symlinking it at the kit would make global tooling follow whatever branch or half-finished edit the kit working tree happens to be sitting on. And this copy is maintained the same way a consumer project is — by editing both the kit source and `~/.claude/` to byte-identical in one pass, proven with `diff`. Re-running a setup procedure is not how a change is delivered.

### Sync flow summary

- **`_claude-project/` → consumer `.claude/`** via `/sync-dev-kit` (diff/review, lockfile at `<project>/.claude/.kit-sync.json`).
- **`_github-project/` → consumer `.github/`** via `/sync-dev-kit` (same lockfile, same flow).
- **`_gemini-project/` → consumer `.gemini/`** via `/sync-dev-kit` (same lockfile, same flow).
- **`_claude-maintainer/` → `~/.claude/`** by hand, in the same pass as the kit-source edit (§0.1).
- **`_statusline/statusline.sh` → `~/.claude/statusline.sh`** via `/install-statusline` (kit-local command; one-time).

The kit isn't enforcing 100% compliance. It's a baseline sync — consumer projects can consciously deviate (custom rules in `<project>/.claude/rules/project/`, project-specific skills, project-specific commands that never come from the kit). Divergence is expected, not a failure.

---

## 1. Who this is for

**The kit maintainer** — the one person who changes the kit, runs `/sync-dev-kit`, and installs the maintainer surface (§0.1).

Everyone else works with the kit and never needs this file. Their guides are role by role: `developer-handbook.md`, `designer-handbook.md` and `devops-handbook.md`, tied together by `overview.md`. One person often wears several of those hats; each guide stays short so that wearing one never means reading the others.

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
- **No version bump in feature-PR scripts; changelog has a single writer.** Version bumps and `changelog.md` updates are owned by `/deploy` (see pipeline.md §2.1). Feature-PR scripts (`commit.sh`, `open-pr.sh`, `merge.sh`) commit code only — they never touch the manifest version field or `changelog.md`. Earlier kit revisions had `open-pr.sh` insert a per-PR changelog entry on the feature branch and `deploy.sh` insert again at release time; that produced duplicate bullets in main and was removed in favor of single-writer.

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

- `/work` — on `main`, refresh from `origin/main` and stay there; no branch is cut until the first `/commit`. On a feature branch, resume it. Idempotent within a body of work.
- `/work <issue#[,issue#…]>` — links the issue(s) to the branch you are standing on and cuts no branch, on `main` or anywhere else. Re-run it on a branch that already carries links to add more.
- `/work --retrieve <branch>` — fetch a teammate's branch, fast-forward any local copy, switch to it. Refuses on a dirty tree; `/checkpoint` first.
- `/work --discussion <slug or artifact URL>` — pull a finished discussion back: the `analysis` skill's published page, its comment threads and any feedback that arrived outside it become `project-documentation/temporary/<slug>-plan.md`, and the discussion folder is removed.

Every shape of `/work` also reads the developer's own `project-documentation/temporary/handoff-<login>.md` once per session, lists the open issues assigned to them, and folds both into the opening orientation (§12c).
- `/merge` — squash-merge the PR, land the checkout back on `main`, delete the merged local branch.

**One session = one body of work = one branch = one PR.** All commits made during a session land on the same feature branch. Re-run `/work <N>` to add more issues mid-stream. Use `/open-pr` once and `/merge` once.

**End-of-day on unfinished work:** `/commit` it (pushed) or `/checkpoint` it (local only), close the session. Next session's `/work` sees you are already on the branch and resumes — same branch, same body of work, no new branch created.

**Uncommitted edits carry onto the new branch.** Starting to edit before typing `/work` is ordinary — you noticed something first. `git checkout -b` brings those edits along, so nothing is stranded. The one consequence: `main` is not refreshed in that case (a fast-forward on a dirty tree would either fail or strand the edits), so the branch is based on local `main`. `/work` says so plainly; `/catchup` integrates the latest when you want it.

**Local main is refreshed before a new branch is cut.** `/work` invokes `fast_forward_local_main` (in `branch_helpers.sh`) before creating the branch, so it starts from current code. If the fetch fails — offline, expired auth, missing scope — `/work` reports the cause and branches off local `main` rather than blocking; nothing is lost, and `/catchup` closes the gap. Resuming an existing branch refreshes nothing by design: you are mid-body-of-work, and integrating new `main` is `/catchup`'s job (§4.6).

**Do NOT reintroduce git worktrees.** A branch is the unit of isolation here, deliberately. Worktrees give a second checkout on disk, which buys isolation between *concurrent* bodies of work on one machine and one repo — a pattern this shop does not have. What a second checkout costs is paid every session: gitignored files must be symlinked in one by one, dependencies install per checkout, `node_modules` symlinks break vite's realpath plugin resolution, a dev server started from the other checkout silently serves stale code, kit edits land in a copy that only reaches `main` after a merge, and `.claude/rules/` loads twice when the second checkout sits inside the first. Parallel work, on the rare occasion it happens, is `git switch`.

**`worktree.bgIsolation: "none"` in `settings.json` is what makes that possible, and it is load-bearing.** Claude Code enforces worktree isolation on a BACKGROUND session at edit time: the first `Write`/`Edit` is refused with *"This background session hasn't isolated its changes yet. Call EnterWorktree first"*, and the refusal names this setting as the way to disable it. The enforcement is on by default and has not been relaxed — the `EnterWorktree` TOOL being opt-in is a separate thing from the guard, which fires whether or not you ever call it.

So the key is **independent of whether worktrees exist**. It sits in a `worktree` block only because that is where the harness reads it, which makes it look like worktree configuration and makes it the obvious thing to delete when worktrees go away. Delete it and every background session in that consumer is pushed back into a worktree on its first edit, however gitflow is written. Bash-driven edits keep working, so the breakage surfaces only when a session happens to use the edit tools — which is why it can go unnoticed for a long stretch.

Keep the block, keep its comment, and do not fold it into "worktree leftovers" in a future cleanup.


### 3.3. Where `/work` lives

`/work` ships per-project, exactly like every other gitflow command:

- **`commands/work.md`** — `<project>/.claude/commands/work.md`, synced from `_claude-project/commands/work.md`.
- **`work.sh`** — `<project>/.claude/skills/gitflow/scripts/work.sh`. It needs its siblings (`branch_helpers.sh`, `issue_helpers.sh`) and operates on the project's git context.

It used to ship globally, so it would be discoverable in an agents-view session starting outside any repo. That is no longer how a client session is entered — `@projectname` is — and `/work` is never issued from the agents view, so the reason is gone.

The reason it must NOT go back is stronger than the reason it left. A command file in `~/.claude/commands/` **outranks** the project's copy of the same name, and `/sync-dev-kit` does not scan `~/.claude/`. A global `/work` therefore wins silently and can never be updated or removed by the normal pull — it ships once and diverges forever.

`work.sh` guards that one-way door: it refuses to run, with removal instructions, when it finds a `~/.claude/commands/work.md`. That guard is the only reliable catch, because `work.sh` is the one thing that executes on every `/work` regardless of which doc won, and neither a sync nor an installer can be relied on to run.

If cwd is not a git repo, `work.sh` exits 3 ("not in a git repository") — a clear error rather than a silent fallback.

### 3.4. Same workflow, three surfaces

The model above is identical across launch surfaces:

| Surface | How project context is established | How `/work` is invoked |
|---|---|---|
| Standalone CLI in repo | `cd ~/projects/<repo>` before launching Claude Code | Type `/work` after launch |
| Agents view (background) | `@<repo>` in the launch prompt sets cwd | Include `/work` (or `/work <issue#>`) in the launch prompt |
| Claude Cloud | Cloud session already inside the repo | Type `/work` after the session starts |

The user-facing commands (`/work`, `/commit`, `/open-pr`, `/merge`) behave identically across all three. The "is this a background session?" question is internal — `/work` behaves the same regardless of surface.

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
9. Before staging, the script runs the gates that MIRROR CI so a failure costs a second here rather than a round trip after the PR is open: typecheck, Biome lint, and Semgrep over the files this commit touches (gated on CI declaring a `semgrep` job, and scoped to changed files so it stays seconds — CI still scans everything). Then the rule review (`rule-review.sh`): every rule-prose file changed since the fold base — the set `hooks/rule-prose.sh` defines — goes to a headless `claude -p` with no tools, no settings and no CLAUDE.md, which reports history, justification and counted lists in added lines only. It runs on the developer's Claude subscription; a missing CLI or a failed call fails the gate. Each exits 4. commitlint is the one gate that remains CI-only, because it validates the PR title, which does not exist yet at commit time.

### 4.3. What the script does NOT do

- Does not update `changelog.md` (single-writer: `/deploy` is the sole author — see pipeline.md §2.1, §2.4)
- Does not bump version (handled by `/deploy` — see pipeline.md §2.1)
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
| Belt-and-suspenders | `branch_helpers.sh:safe_push` | Reads `@{u}`; if it does NOT match `origin/<local-branch>`, push with `-u origin <local-branch>` to (re)set tracking. Used by `commit.sh`, `open-pr.sh`. |
| Recovery | `commit.sh --push-only` | When a prior `/commit` committed locally but failed at push (typical: a branch left with bogus tracking), retry the push without re-running typecheck/stage/commit. |

**Caller recovery for half-shipped commits.** A feature branch that inherited the bogus upstream still carries it. The fix in `commit.sh` (safe_push) is delivered THROUGH the file at `<project>/.claude/skills/gitflow/scripts/commit.sh`. For a stranded branch (committed but not pushed), invoke `commit.sh --push-only` while standing on the stranded branch:

```bash
cd <project>
<project>/.claude/skills/gitflow/scripts/commit.sh --push-only
```

The script reads `git branch --show-current` against cwd's git context, so it operates on whichever branch is checked out.

### 4.6. Catchup workflow (`/catchup`)

`/catchup` is the single command for "refresh the branch I'm on from origin." Behavior depends on which branch is checked out at invocation:

- **On main (between bodies of work, or just reviewing):** fetch `origin/main`, fast-forward local main. Fail-loud on dirty main or local-only commits (anomalous under gitflow). This is what you run when starting a session after someone else has merged + deployed and you want your local repo current before doing anything else.
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
3. Script stages all and commits with `🔖 wip: <timestamp or message>` on the current branch, `main` included. No branch is cut and nothing is pushed.
4. No local typecheck runs — checkpoints are never gated (speed over compliance for WIP)

Checkpoints are meant to be fast. Skip analysis. No changelog. No version.

### 5.3. The fold

`/commit` and `/ship-main` fold every unpushed checkpoint into the one real commit they make. `checkpoint_fold_base` (`branch_helpers.sh`) walks back from HEAD over commits whose subject starts `🔖 wip:` and that no remote ref contains; once every gate has passed, `fold_checkpoints` soft-resets to that base and the script commits once. The gates scan from the base, so content saved in checkpoints — which skipped them — is checked too.

Why the fold exists: `/deploy` reads subjects on `main` to compute the bump, so a checkpoint must never land there. Why after the gates: a failing gate then leaves the checkpoints exactly as they were.

`/commit` on `main` cuts its branch first, moving the checkpoints with it, and resets local `main` to the base straight away. Until `/commit` or `/ship-main` runs, local `main` is ahead of `origin/main`: `fast_forward_local_main` refuses and names the checkpoints, and `/deploy`'s in-sync gate refuses.

A checkpoint already on a remote is never folded — rewriting it would need a force-push.

`skills/gitflow/scripts/checkpoint.test.sh` covers all of this against a real bare origin.

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

Dev actions per PR: `/open-pr` to start, `/triage` if Gemini has items, `/merge` to land on main. **`/merge` does NOT ship.** Multiple merged PRs accumulate on main; when ready to release, run `/deploy` to bump version, generate the consolidated changelog entry, tag, push, and dispatch the deploy (CodeBuild projects by default). The readiness wait inside `/open-pr` / `/triage` / `/merge` is the same poll loop — the user sits at the keyboard while CI/Gemini run, the script blocks until ready or fails loud on timeout.

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

Note: `/open-pr` does NOT touch `changelog.md`; `/deploy` is the single changelog writer (pipeline.md §2.1).

### 6.3. `/merge` procedure

1. Claude checks `gh pr list` for current branch's PR
2. If multiple open PRs, list them and ask which
3. Command calls `skills/gitflow/scripts/merge.sh`:
   - **Base drift gate** — first of all. When `origin/main` has moved past the branch, a trial merge (`git merge-tree`, which touches no file, index or ref) decides: a conflict refuses with exit 23 before any build or wait, and drift that merges cleanly is reported and the merge continues. The same drift report (`main_drift_report` in `branch_helpers.sh`) runs as a warning in `/work`, `/commit` and `/open-pr`, so a branch cut from a stale `main` is flagged when it is cut rather than at the squash. `--force-unchecked` bypasses it.
   - **Local production build gate** — every workspace that declares a `build` script (or the root, in a single-package repo) builds before the readiness wait and before the squash (exit 15 on failure, nothing merged). The gate counts the declared build scripts first and reports how many it built; with none it says so rather than reporting a build that never ran (`run_build_gate` in `gates.sh`). CI type-checks, lints and tests but never builds, so a build-only break (bundler / Tailwind / an import alias a package's own tsconfig doesn't map) is invisible to every earlier gate. `/merge` is the last moment the PR is still OPEN — a failure here is fixed on the branch that caused it, inside the PR already under review, instead of needing a second PR to repair the first. Not in CI on purpose: CI fires on every push, so building there would tax every commit, `/open-pr` and triage fix; once per merge is the right frequency. `--workspaces` is added only when `package.json` actually declares a `workspaces` key (jq-tested — it errors on a single-package repo); a repo with no `package.json` skips the gate entirely. `--force-unchecked` bypasses it along with the CI gate.
   - Invokes `wait-for-pr-ready.sh` (same poll as `/open-pr` step 5) — trigger-aware: catches the post-`/triage` case where the user invoked `/commit --review` and a fresh Gemini review is expected on the new HEAD. `/commit --no-review` posts no trigger and the wait proceeds CI-only. Bypassable via `--force-unchecked` for emergency hotfixes only (skips CI too).
   - On wait exit 0: `gh pr merge --squash` with the PR's own title and body as the commit message — explicit, because GitHub's default squash message depends on a per-repository setting, and its "commit messages" option drops the PR body and with it the `Closes #N` line `/deploy` reads (exit 22 if the title or body cannot be read, nothing merged). The remote branch is deleted afterwards as a separate, best-effort step.
   - **Post-merge cleanup**: switch this checkout to `main`, fast-forward it to the merged tip, delete the now-merged local branch, and reinstall dependencies if landing on the new `main` changed a package manifest.
4. **No further action needed from Claude.** The checkout is standing on the merged `main`; the next `/work` cuts a fresh branch from there.
5. **No automated post-merge action.** No version bump, no tag, no deploy. The squash commit sits on main until `/deploy` is invoked. Multiple merges may accumulate between deploys.

Changelog ownership, the `/deploy` procedure and version bumps are DevOps reference: `pipeline.md` Part 2.

### 6.4. `/triage` — Gemini review walkthrough

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

### 6.5. `/ship-main` — the deliberate direct-to-main exception

`/ship-main` commits a conventional message **directly on `main`** and pushes — no branch, no PR, no CI. It is the conscious exception for quick infra / config / emergency / "get it in and back to clean" work where a full branch → PR → CI → merge cycle is theater.

| Use `/ship-main` | Use `/commit` (the default) |
|---|---|
| Conscious infra / config / emergency change you want on main NOW | Real feature work |
| You accept no PR, no CI, no review — main's history is the trail | You want branch → PR → CI → review → merge |
| Sitting on dirty `main` and want back to clean | Anything that deserves review |

**Never inferred.** Being on dirty `main` is often *accidental* — work started before `/work` — so a bare `/commit` on `main` still auto-branches — that's the safety. `/ship-main` is the opposite, on purpose, and only when invoked by name.

- **Validation stays.** The script runs `check-types`, `biome lint`, `semgrep` and the rule review over the files the commit touches — the same gates as `/commit`, and they matter more here: a finding that slips through does not sit on a branch awaiting review, it lands on the default branch and breaks CI for everyone. `--skip-typecheck` is a true-emergency override for the TYPECHECK alone; biome and semgrep sit outside that guard and have no bypass.
- **Pushes straight to main.** If `origin/main` advanced, it rebases the commit onto it and re-pushes; conflict → stop and resolve.
- **Feeds `/deploy` like any main commit.** `/ship-main` commits land on `main` and are read by the next `/deploy` (commit subjects since the last tag) to compute the bump level + changelog, exactly like a merged-PR squash commit. Conventional format is therefore required, not optional.
- **Requires require-PR off** (the default — pipeline.md §1.1). With require-PR set, GitHub rejects the direct push.

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
5. Copy `commitlint.yml` and `ci.yml` templates (pipeline.md Part 3) into `.github/workflows/`. If the project deploys, stand up its CodeBuild pipeline (`new-project-setup.md` step 7, pipeline.md §2.7) — dispatched only by `/deploy` (pipeline.md §2.5).
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
    ".claude/hooks/git-guard.sh": { "sha": "<hash of what sync wrote>", "mode": "owned" },
    ".claude/rules/project/ui-inventory.md": { "sha": "<hash of what sync wrote>", "mode": "merge", "skeleton": "<hash of the kit-owned text>" },
    ".gemini/config.yaml": { "sha": "<kit hash at refusal>", "mode": "owned", "declined": true }
  }
}
```

Committed so every dev and every cloud session has the same baseline. `sha` is the hash of what sync wrote — substituted, canonicalized for `settings.json`, region-merged for a `merge` file. `skeleton` is recorded for `merge` files only (§9.10).

### 9.3. Sync states per file

| State | When | Action |
|---|---|---|
| `clean` | Kit and project both match the baseline | Silent skip |
| `clean-first` | No baseline yet; project already matches the kit | Silent skip; finalize records the baseline |
| `clean-converged` | Both moved to the same content (a `merge` file whose project changed only its regions lands here too) | Silent skip; finalize records the baseline |
| `kit-only` | Kit changed, project did not | Show diff, recommend apply |
| `project-only` | `template` file: project changed, kit did not | Silent skip — the project owns it |
| `patched` | `owned`/`merge` file: project changed kit-owned text and the patch register sanctions it | Reported every sync with both issues and a recommendation (§9.10) |
| `unsanctioned` | `owned`/`merge` file: project changed kit-owned text with no register entry | Reported loudly every sync; revert to the kit or register it |
| `conflict` | `owned` file, no register entry: both changed, differently | Three-way diff; recommend the kit's version |
| `conflict-first` | No baseline yet; project and kit differ | Show both, the user decides |
| `template-drift` | `template` file: both changed, differently | Show the kit's delta as information; the project decides |
| `merge-unmarked` | `merge` file whose project copy has no region markers | Never written; the content is moved into the regions by hand |
| `merge-invalid` | `merge` file with malformed markers, or a project region the kit lacks | Never written until the markers are fixed |
| `new-kit` | Kit file the project does not have | Show, recommend apply, or decline |
| `declined` | The project refused this file at its current kit content | Silent skip |
| `project-deleted` | Baseline and kit have it; the project deleted it | Ask: re-add or accept |
| `removed-kit` | Kit deleted a file the project still has | Ask: delete or keep as project-owned |

The scan also reports `unmapped_templates` (a `templates/` file with no destination mapping — a kit defect), `skipped_unconfigured` (files skipped because their destination key, `SHARED_MODULE_DIR` or `DESIGN_UI_PACKAGE`, is empty) and `stale_patches` (§9.10).

### 9.4. Sync procedure

`/sync-dev-kit` (invoked from the project root, on whatever branch you are standing on):

1. Read the kit working tree at `devKitPath` (`~/.claude/dev-kit-config.json`); warn when it is dirty or behind its remote
2. Load project lockfile (create empty if missing — first sync)
3. Build the file inventory from the kit working tree
4. For each file:
   - Compute state per Section 9.3
   - Clean → skip silently
   - Any other state → present diff, recommend, await decision
5. On each accepted change: write to the project, update the lockfile entry
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
- `--finalize` stamps the lockfile. The accumulated changes stay uncommitted until the user lands them with `/ship-main` or `/commit`.

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
| `GITFLOW_PROJECT_ID` | `_claude-project/gitflow-project.conf` | GraphQL node ID of the Project the lifecycle transitions write to. Empty → no board (silent skip). Set → the other four `GITFLOW_STATUS_*` keys are all required; an empty one fails the command that needs it. |
| `GITFLOW_STATUS_FIELD_ID` | `_claude-project/gitflow-project.conf` | GraphQL field ID of the Status single-select on that project |
| `GITFLOW_STATUS_IN_PROGRESS_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for "In Progress" — set by `/work <N>` |
| `GITFLOW_STATUS_STAGED_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for "Staged" (code complete, waiting for deployment) — set by `/commit` and `/ship-main` for each issue answered code complete, and by `/open-pr` for every linked issue |
| `GITFLOW_STATUS_DEPLOYED_ID` | `_claude-project/gitflow-project.conf` | GraphQL option ID for the deploy status — set by `/deploy` after tag push for every issue named by a closing keyword since the last tag. The column may be named anything (`Done`, `Deployed`, …). `/merge` does NOT trigger it. |
| `GEMINI_NOT_INSTALLED` | gitflow scripts (runtime-read via `jq`) | Inverted-default toggle — DEFAULT (missing/empty) = Gemini is installed → trigger scripts (`/open-pr`, `/commit --review`) post `/gemini review` comments, and `wait-for-pr-ready.sh` honors triggered reviews. Set `"true"` only when Gemini is genuinely absent from the repo → trigger scripts skip posting and the wait treats Gemini as `skipped`. Naming captures a fact about the repo, not a config preference. Semantics deliberately INVERTED from `GITFLOW_*` (which use empty = disabled) because the name encodes a negation. See "Runtime-read placeholders" below |
| `AWS_ACCOUNT_ID` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | 12-digit AWS account ID this project's infra lives in. Confirm `aws sts get-caller-identity` matches it before any operation. Empty → project has no AWS. See "Runtime-read placeholders" below |
| `AWS_REGION` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | Default AWS region for this project's resources, e.g. `us-east-1`. Passed as an explicit `--region` on every AWS CLI command; never the shell default, which is per-machine and routinely points elsewhere. Empty → project has no AWS. See "Runtime-read placeholders" below |
| `AWS_PROFILE` | `_claude-project/rules/cli-utilities.md` (runtime-read via `jq`) | Named AWS CLI profile for this project's account, e.g. `acme-prod`. Passed as an explicit `--profile` on every AWS CLI command. Empty → default profile / no AWS. See "Runtime-read placeholders" below |
| `DB_ENGINE` | `_claude-project/rules/postgres-drizzle.md`, `rules/sqlserver-drizzle.md`, `skills/postgres-neon-drizzle/SKILL.md`, `rules/testing-verification.md` (runtime-read via `jq`) | Which engine the project runs on, and the single gate deciding which engine-specific guidance applies. Five exact, case-sensitive values: `PostgreSQL`, `SQLServer`, `Other` (has a DB, neither of those — the project supplies its own rule under `rules/project/`), `None` (no database at all), and empty (**not yet declared** — re-surfaced every sync; engine rules must not assume an engine). Empty NEVER means "no database"; that is `None`. Gating on the presence of a `drizzle.config.ts` is the bug this key replaces — a config file proves Drizzle, not the dialect. See "Runtime-read placeholders" below |
| `DEPLOY_BACKEND`, `DEPLOY_WORKFLOWS`, `MIGRATE_WORKFLOW`, `MIGRATE_PATHS`, `CODEBUILD_PROJECT_PREFIX`, `CODEBUILD_MIGRATE_PROJECT` | `deploy.sh` (runtime-read) | The release path `/deploy` dispatches to, its services, and its gated migration phase — DevOps reference, `pipeline.md` §2.1 |
| `FORM_LIB_EXEMPT_APPS` | `scripts/check-stack.mjs` (runtime-read) | Front-end apps that deliberately use no form library. An app neither declaring the library nor listed here fails the check until someone answers the question |
| `SHARED_MODULE_DIR` | sync's destination mapping for `templates/testing/*` | The workspace holding the shared module and its test scaffolding, e.g. `apps/shared`. Empty → the testing templates are skipped (`skipped_unconfigured`). `testing.md` §1 |
| `DESIGN_UI_PACKAGE` | sync's destination mapping for `templates/design-system/*`; `stack-manifest.json` (substituted); the `claude-design` engine, `check-design-tokens.mjs` and `check-stack.mjs` (runtime-read) | The UI package holding the design system, from the repository root, e.g. `packages/ui`. Its config sits at `<DESIGN_UI_PACKAGE>/design-system/design-system.config.mjs`. Empty → the project publishes no design system: the templates are skipped and the engine refuses to run |
| `DESIGN_FEED_BARREL` | `templates/design-system/tsconfig.types.json` (substituted); the engine (runtime-read) | The module exporting every component a design may mount, relative to the UI package. Required whenever `DESIGN_UI_PACKAGE` is set |
| `DESIGN_TOKEN_FILES` | the engine and the token checker (runtime-read) | Stylesheets declaring the tokens in light and dark blocks, relative to the UI package. Required whenever `DESIGN_UI_PACKAGE` is set |
| `DESIGN_TYPE_FILE` | the engine and the token checker (runtime-read) | The stylesheet defining the `@utility type-*` roles. Empty → no type roles |
| `DESIGN_STYLES_FILE` | the engine and the token checker (runtime-read) | The UI package's Tailwind entry stylesheet. Empty → none |
| `DESIGN_SOURCE_DIRS` | the token checker (runtime-read) | Source trees, from the repository root, whose `.ts`/`.tsx` the checker reads. Required when the project has `design.md`; a listed folder that does not exist fails the check |
| `DESIGN_VENDORED_DIR` | the token checker (runtime-read) | The vendored shadcn `components/ui` folder. Empty → nothing vendored |
| `DESIGN_VENDORED_RESTYLED` | the token checker (runtime-read) | `"true"` when the vendored atoms are restyled onto the project's roles, so every class rule applies to them. Empty → they keep registry defaults and only the arbitrary-spacing rule applies |
| `DESIGN_FIELD_LOOK_CLASSES` | the token checker (runtime-read) | Classes that paint a text field's look; a raw `<input>` or `<textarea>` carrying one fails. Empty → only `rounded-*` is checked |
| `DESIGN_EXEMPT_COMPONENTS` | the token checker (runtime-read) | Headless primitives and `currentColor` glyphs a call site may style. Empty → none |
| `KNIP_GATE` | the `knip` job in `ci.yml` (runtime-read) | `"true"` → CI runs knip with the kit's `knip.config.ts` and fails on any finding. Empty and listed in `_intentionally_empty` → the gate is off. Missing, or empty and unlisted → undecided: the job passes with a warning naming the key. `pipeline.md` §3.9 |

The kit ships a template at `_claude-project/sync-substitutions.json` with empty values and inline docs of every placeholder kit templates currently reference. Consumer projects bootstrap automatically: `load_substitutions` in `sync-dev-kit.sh` copies the kit template to `.claude/sync-substitutions.json` on first run if absent. Population is then walked through interactively — see §9.8.

**Sync flow** — `sync-dev-kit.sh` uses the substitutions in two places:

1. **During scan**: the `kit_sha` for each file is computed AFTER substituting placeholders with project values. So a kit template with `{{ORG}}` matches a project file with `acme` and reports `clean`, not `conflict`. Three states per key, with deliberately distinct behavior:
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
  "_intentionally_empty": ["GITFLOW_PROJECT_ID", "GITFLOW_STATUS_FIELD_ID", "GITFLOW_STATUS_IN_PROGRESS_ID", "GITFLOW_STATUS_STAGED_ID", "GITFLOW_STATUS_DEPLOYED_ID"],
  "_comment": "...",
  "GITFLOW_PROJECT_ID": "",
  "GITFLOW_STATUS_FIELD_ID": "",
  "GITFLOW_STATUS_IN_PROGRESS_ID": "",
  "GITFLOW_STATUS_STAGED_ID": "",
  "GITFLOW_STATUS_DEPLOYED_ID": ""
}
```

Keys listed in `_intentionally_empty` are skipped by the walkthrough (the user has already decided). Keys with empty values NOT in that list are surfaced for decision. The substitution engine ignores `_`-prefixed keys (per §9.7), so this metadata doesn't affect substitution behavior.

**On every subsequent sync**

The walkthrough re-runs against the current state of the consumer file:
- Newly-added kit keys are merged into the consumer file with empty values by the scan's additive key merge (`load_substitutions` in `sync-dev-kit.sh`); the walkthrough surfaces them.
- Keys the kit no longer ships are never removed — the merge only adds. Delete a retired key from the consumer file by hand.
- Keys the user previously populated stay populated; not surfaced.
- Keys in `_intentionally_empty` stay skipped.
- Keys that were "deferred" last time (still empty, not in `_intentionally_empty`) get re-surfaced.

This preserves the missing-vs-empty-vs-populated invariants from §9.7 while adding intentional-empty as a fourth state stored only in metadata.

**Where the walkthrough lives**

The orchestration is in the `/sync-dev-kit` slash command (`_claude-maintainer/commands/sync-dev-kit.md`), Step 1.5. Claude reads the substitutions file, the `_placeholders_referenced_by_kit` block, and the `_intentionally_empty` list, then drives the per-key flow with the user. Discovery commands are invoked via `Bash`. Updates are written by re-serializing the JSON via `jq`.

### 9.9. Template-mode files, ack and decline

**All six testing templates (`testing.md` §1) are `template`, including `globalSetup.ts` and `integration-helpers.ts`.** Those two look like project-agnostic infrastructure — one consumer had copied both byte-for-byte — and marking them `owned` would push harness fixes automatically. A second consumer settled it the other way: a dual-database project adapted `globalSetup.ts` to migrate two databases on one branch and grew `integration-helpers.ts` a second per-plane helper. Under `owned` the hook would have blocked both edits, and the project would have had no legal way to test its own topology. Database shape is project shape; the whole directory is the project's.

**How an improvement reaches a project.** A consumer that never touched its copy sees `kit-only` and is offered the update like any other file. A consumer that adapted its copy sees `template-drift`: the kit's delta is shown, nothing is reconciled, the project decides. When the user keeps theirs, the walkthrough runs `sync-dev-kit.sh --ack-file <kit-path>`, which advances the lockfile baseline to the kit's current content **without writing the project file**. That is what stops a declined drift from re-reporting on every subsequent sync — and it is not a permanent mute, since the next kit change to that file surfaces again.

**Ack is not restricted to `template` files, and the test is not the mode — it is whether the kit's current content has been INCORPORATED.** An ack asserts "this kit version has been seen." Acking *instead of* applying makes that false and hides a real enforced update. Acking an `owned` file *after* hand-merging the kit's change into a registered patch is the legitimate case: the kit's change is in the file, the register sanctions what still differs, and the file reports `patched` with `kit_changed: false` until the kit moves again. The script does not enforce the distinction; the `/sync-dev-kit` walkthrough does, where the user can see which situation they are in.

**A file the project does not want at all is `--decline-file`.** A consumer that has no copy sees `new-kit`, and "skip" is not an answer — a skipped `new-kit` leaves no lockfile entry, so it is offered again on every sync forever. Declining records the kit's current content as a refusal without creating the file, and the entry reports `declined` (silent). Ack is the wrong tool here and the script refuses it in both directions: ack on a file you do not have would report `project-deleted` next scan, and decline on a file you DO have is rejected with a pointer to ack. Like ack, a refusal is per kit VERSION — change the file in the kit and it is offered again — and `--apply-file` undoes it by overwriting the entry.

**TS LSP diagnostics on kit-side files**: the kit repo has no npm deps (see kit-repo-github-config §1), so any LSP scoped to the kit will flag `Cannot find module 'vitest'` / `Cannot find name 'process'` on the template `.ts` files. Expected — they aren't meant to compile in the kit, only in the consumer where the deps exist.

### 9.10. Merge regions and the patch register

**A `merge` file is kit-owned except inside named project regions.** The markers use the file's own comment syntax — `<!-- project:begin <name> -->` … `<!-- project:end <name> -->` in Markdown, `# project:begin <name>` … `# project:end <name>` in YAML and `.gitattributes`. Names are `[A-Za-z0-9_-]+`, unique per file, never nested. `mode_for_kit_path` declares which files are `merge`: `templates/ui-inventory.md`, `templates/dependency-policy.md`, `templates/.gitattributes`, `_github-project/workflows/ci.yml` (the `project` job's `project-steps` region) and `_gemini-project/styleguide.md` (the `project-rules` region).

**What sync writes:** the substituted kit file, with each region's body replaced by the project's body for the same name. A region the project does not have yet takes the kit's body as its seed. A project region the kit does not have is `merge-invalid` — writing would lose it.

**How the scan tells a region edit from an outside edit.** The lockfile records two hashes for a `merge` file: `sha`, of what was written, and `skeleton`, of that file with every region body removed. A project skeleton that matches neither the recorded skeleton nor the kit's current one means kit-owned text was edited in the project → `patched` or `unsanctioned`. Otherwise the scan compares the composed result with the project file: equal is `clean` (or `clean-converged` after a region edit), different is `kit-only`, which is always safe to apply. A file with no recorded skeleton yet (first merge-aware sync) reports `clean-first`, `kit-only` when only region seeds differ, or `conflict-first`.

**First sync of an existing project file without markers is `merge-unmarked`**, and `--apply-file` refuses it. Someone moves the project's content into the kit's regions by hand, then the next scan proceeds normally.

**The patch register.** `.claude/.kit-patches.json` is the project's record of sanctioned edits to kit-owned text:

```json
{"patches":[{"path":".claude/hooks/example.sh","kitIssue":"owner/repo#12","projectIssue":"#34","reason":"…"}]}
```

`path` is the destination path, the lockfile's key. `block-kit-edit.sh` allows an edit to a listed file once both issues are filled in. Its deny message for an owned file carries the script Claude puts to the human — the reason, whether it blocks the work, and the three steps of a temporary patch — so the register is reached only through the human's yes. On a `merge` file the hook allows an edit that changes only region bodies, comparing the file before and after with every region body removed; that check needs `python3`. Sync reads the register and never writes it, except `--remove-patch <dest>`, which drops one entry and prints it. A listed file that differs from the kit is `patched`, and the scan attaches the issues' states (via `gh issue view`; `unknown` when `gh` cannot answer) and a recommendation: `keep` (kit unchanged, issue open), `merge-kit-keep-patch` (kit changed, issue open), `take-kit` (kit changed, issue closed — apply, remove the entry, close the project issue) or `kit-issue-closed-file-unchanged`. An entry whose file no longer differs, or is not kit-owned, is listed under `stale_patches`.

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

## 11. Templates and integrations

Workflow templates live at `_github-project/workflows/` and land in a consumer's `.github/workflows/`; edit the kit files, never a doc's snippet of them. How a project uses the CI, deploy, dependency and Gemini templates is DevOps reference, `pipeline.md` Parts 2–3; test scaffolding and `/e2e` are `testing.md`. What stays here is the machinery behind the rest.

### 11.1. Issue → branch → PR linking

Issue↔branch↔PR linking is first-class in the gitflow subsystem. Two commands drive it:

- **`/work <issue#>`** — links the issue to the current branch and cuts NO branch. An issue number says what the work is about, never which pipeline it belongs in: an issue can be a docs or infra change belonging straight on `main`, and in a repo with no CI and no deploy the PR round-trip buys nothing. Cutting a branch here would make `/ship-main` unreachable for the whole session. The link graph lives in git config (`branch.<name>.gitflow-issues`), so on `main` it simply parks under `branch.main.gitflow-issues`; `/commit` and `/checkpoint` carry it, and its code-complete marks, onto the branch they create (`migrate_branch_linked_issues`) and clear the source, while `/ship-main` consumes the complete ones as a `Closes #N` line. Issue numbers are NOT in any branch name — a branch may close several issues, so embedding one misleads. Moves the linked issue to `In Progress` on the configured project. Assigns to the current `gh`-authenticated user. Dumps issue body + comments to stdout so Claude reads them in-turn and responds with understanding + questions BEFORE any code is written.

Board transition + assignment are **fail-loud when configured** — see the failure-semantics table in the gitflow-project-integration subsection below. `GITFLOW_PROJECT_ID` empty = feature off, silent skip. Any other broken state (missing scope, wrong option ID, an issue that cannot be added to the project) = script exits non-zero with the underlying cause. An issue not yet on the project is added to it, with a warning that the board's auto-add is not catching this repository.

**Storage**: `git config --local branch.<name>.gitflow-issues = "23 25 26"` — git wipes on branch delete, no stray metadata files. Code-complete marks sit beside it in `branch.<name>.gitflow-complete = "23 25"`, and the issues whose Staged comment has been posted in `branch.<name>.gitflow-noted`.

**Code complete** means finished and waiting for deployment. `/commit` and `/ship-main` ask, for each linked issue not yet marked, whether it is code complete (`--complete "<N,N>"`); each yes is marked on the branch and moved to Staged once the push lands. `--complete` naming an issue not linked on the branch exits 2 before anything happens. `/checkpoint` asks nothing — it is partway by definition — and leaves links and marks where they are. `/ship-main` names only the complete issues in its `Closes` line, moves them to Staged and unlinks exactly those after the push; incomplete ones stay parked on `main`. `/open-pr` is a gate: every linked issue must be complete, any unmarked one is confirmed first ("Opening this PR marks #42 as Staged. Proceed?"), and an unconfirmed one makes `open-pr.sh` exit 12 before pushing.

**Every issue reaching Staged gets one comment for its author** — what was built, what they will see, and where it differs from what they asked (`skills/gitflow/references/staged-comment.md`). Claude writes it as `<notes_dir>/<N>.md` and passes `--notes <notes_dir>`; `commit.sh`, `open-pr.sh` and `ship-main.sh` refuse (exit 2, before committing or pushing) when an issue about to be staged has none, and post it once the board has moved. The comment is posted once per issue: `/open-pr` re-staging an issue `/commit` already staged posts nothing.

**PR body injection**: `/open-pr` reads the git-config list and prepends `Closes #23, #25, #26` to the PR body. gitflow always writes the closing keyword — it is the history, and it is how `/deploy` finds what shipped — and never closes an issue itself. Whether one closes is GitHub configuration: the repository's "Auto-close issues with merged linked pull requests" setting and the board's "Auto-close issue" workflow. `github-project-board-setup.md` §3 has both settings and the three ways of working they combine into.

**PR titles do NOT include issue #s** — same rationale as branch names. A multi-issue PR with one number in the title misrepresents itself. Linkage lives in the body's `Closes #N` line, which is sufficient. Rule codified in `.claude/commands/open-pr.md` Step 3.

**Board lifecycle (four states):**

| State | Trigger | Mechanism |
|-------|---------|-----------|
| Todo | Board default — no gitflow command fires this | — |
| In Progress | `/work <N[,N…]>` | `move_issue_to_in_progress` in `issue_helpers.sh` |
| Staged | `/commit` or `/ship-main`, for each issue answered code complete; `/open-pr`, for every linked issue | `move_issue_to_staged` after the push lands / after successful PR create |
| Deploy status (`Done`, `Deployed`, …) | `/deploy` (after tag push — shipped to production) | `move_issue_to_deployed`, sourced from `git log "$LAST_TAG..HEAD"` parsed for `Closes`/`Fixes`/`Resolves #N` |

`/merge` intentionally does NOT transition. "Staged" spans everything from code complete through PR, CI, review and merge; the deploy status is reserved for the deploy boundary. If a consumer's flow decouples merge from deploy (long-lived release branches, multi-stage rollouts), the conventions still hold — the deploy status lands when `/deploy` fires, not before.

**Config surface** — `.claude/gitflow-project.conf` (substituted from `sync-substitutions.json` at sync time):

- `GITFLOW_PROJECT_ID` — GraphQL node ID of the project. Empty = feature off (silent skip everywhere).
- `GITFLOW_STATUS_FIELD_ID` — Status single-select field ID on that project.
- `GITFLOW_STATUS_IN_PROGRESS_ID` — option ID for In Progress.
- `GITFLOW_STATUS_STAGED_ID` — option ID for Staged.
- `GITFLOW_STATUS_DEPLOYED_ID` — option ID for the deploy status, whatever the column is named.

With `GITFLOW_PROJECT_ID` set, all four are required.

**Failure semantics (Zero Tolerance — fail-loud-when-configured):**

| Condition | Behavior |
|-----------|----------|
| `GITFLOW_PROJECT_ID` empty | Silent skip — feature disabled, kit default |
| `GITFLOW_PROJECT_ID` set + `GITFLOW_STATUS_FIELD_ID` empty | ERROR + return 1 (config gap) |
| `GITFLOW_PROJECT_ID` set + a specific status option ID empty | ERROR + return 1 — populate the key; every status is required once a board is configured |
| Issue not on the configured project | Added with `addProjectV2ItemById`, then a WARNING that the board's auto-add workflow is not catching this repository's issues; the status is set as normal. A failed add → ERROR + return 1 (wrong PROJECT_ID, or missing scope) |
| GraphQL mutation fails | ERROR + return 1 — almost always missing `project` scope on gh auth (`gh auth refresh -s project`) |

Caller scripts run under `set -e`; a non-zero return from any helper propagates to script exit. All transitions are idempotent — retry after fixing the cause.

A board failure after the push has landed exits 11, so the caller can tell "nothing happened" from "the git side is done": `commit.sh` (commit and push landed; `/open-pr` sets every linked issue to Staged again), `ship-main.sh` (commit live; the next `/deploy` still moves the named issues), `open-pr.sh` (PR open; set the status on the board once the cause is fixed). A Staged comment that fails to post after the board has moved exits 13, and the script prints the exact `gh issue comment` that posts it.

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
#       the deploy column's option id → GITFLOW_STATUS_DEPLOYED_ID
```

Then populate the five `GITFLOW_*` keys in `.claude/sync-substitutions.json` (via the `/sync-dev-kit` walkthrough, which offers to run the discovery commands above and parse the output for you). Re-run sync to substitute into `gitflow-project.conf` on disk.

Kit ships a placeholder template at `_claude-project/gitflow-project.conf` with empty values. Each consumer project fills in their own IDs once (committed to the repo). There is no per-transition opt-out: a board gitflow drives has all four statuses. A project with no board leaves all five keys empty and lists them in `_intentionally_empty`.

### 11.2. Dev server protocol (`rules/dev-server.md` + `hooks/dev-server-guard.sh`)

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

### 11.3. UI inventory rule (synced as `merge` mode)

**What it is.** A per-project rule at `.claude/rules/project/ui-inventory.md`, path-targeted to `{**/*.tsx,**/*.jsx}` so it auto-loads on every UI edit. It enumerates, as content rather than as references: the project's list/detail patterns and which to use when, every pattern reference file and what it governs, the components that already exist, and the standing prohibitions.

**Why it is not just another pointer.** `rules/ui-patterns.md` and `rules/ui-design.md` already auto-load on the same globs, and both tell the reader to go and open a skill. Following a pointer is a separate act, taken at the moment you already feel ready to write — so it is the step that gets skipped, and a screen ships that reinvents a list pattern and hand-rolls a submit control whose component was one import away. The inventory carries the names themselves, in the forced read, which is what removes "I did not know it existed" as a possibility.

**Why it ships from `templates/`.** `is_skipped` excludes `_claude-project/rules/project/*` from the scan entirely — that tree is the consumer's own, and the kit never compares against it. So a seed placed there would reach nobody. `_claude-project/templates/ui-inventory.md` plus an explicit `dest_for_kit_path` entry is what lets the kit put one file into a directory it otherwise never writes to.

**Mode is `merge`.** Every enumeration — the list patterns, the pattern references, the components, the hooks, the prohibitions — is a project region; the headings, the instructions and "Keeping this file true" are the kit's. It arrives once as `new-kit`, the project fills its regions, and later kit changes to the text around them arrive as `kit-only` and apply without touching the project's lists (§9.10).

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

`/dev` is the structural fix: a spawned tab with the correct `cd`, plus an `lsof` pre-check with a `+10` port-step on collision. Which terminal opens that tab is the backend ladder in §12.2.2.

### 12.2. Layout

| Path | Purpose |
|------|---------|
| `_claude-project/skills/dev-server/SKILL.md` | Natural-language routing layer (same shape as gitflow skill). |
| `_claude-project/skills/dev-server/scripts/dev.sh` | Implementation: project-root detection, port probing, and the tab-launch backend ladder (§12.2.2). Supports `--tunnel` flag (§12.3.2). |
| `_claude-project/skills/dev-server/scripts/dev-with-tunnel.mjs` | Implementation for `--tunnel`: spawns `cloudflared tunnel run` + `npm run dev:<app>` in one tab. Hostname `<subdomain>.thenextage.com`, subdomain defaulting to `<app>` (shop-standard parent). Byte-identical across consumer projects. See §12.3.2. |
| `_claude-project/skills/dev-server/templates/DevServer.json` | iTerm DynamicProfile template. Installed once per dev machine to `~/Library/Application Support/iTerm2/DynamicProfiles/DevServer.json`. Applies to the iTerm backend only. See §12.2.1. |
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

### 12.2.2. Where the tab opens (backend ladder)

`stage_app` tries four backends in a fixed order. **The order is load-bearing** — it decides which terminal a user's dev server appears in, and rearranging it silently changes that.

| Order | Condition | Backend | Why here |
|---|---|---|---|
| 1 | `$TMUX` is set | `tmux new-window` in the current session | tmux sets it in every shell it spawns, so when it is present it is proof rather than inference. |
| 2 | a tmux client is attached | `tmux new-window -t <that session>` | Same class of signal as 1 and it belongs at the same rank: an ATTACHED client is a person with their eyes on that session. Prefers the focused client; with several attached and none focused, the first is as good a guess as exists. |
| 3 | otherwise | `osascript` → iTerm2 tab | Reads no environment at all, which is why it survives the Agents-view gap below. |
| 4 | `tmux` on PATH, nobody attached | `tmux new-window -t dev`, session created if absent | Last resort. A detached tmux server says nothing about which window the user is looking at. |
| — | none of the above | refuse, printing the intended command and path | |

**Why 2 exists, and why it is not redundant with 1.** `$TMUX` is a *proxy* for "the user is in tmux", and the proxy leaks. A Claude Code session running inside tmux hands its Bash tool an environment with `$TMUX` stripped, so 1 misses the exact case it was written for; with no iTerm2 installed the run then falls all the way to 4 and the server lands in a detached `dev` session the user never sees. That was the observed failure: a tmux-only Mac user ran `/dev web`, the server started correctly, and it was invisible to them. Order 2 asks tmux which client is attached, which answers the same question without depending on inherited environment.

**Why 4 must stay below 3.** Ranked above `osascript`, any macOS user who happens to have a detached tmux server running would silently stop getting iTerm tabs and start accumulating windows in a session they are not watching.

**There is no `uname` branch.** The platform is never the question: Linux never satisfies 3, and macOS reaches 4 only once iTerm2 has already failed.

A `new-window` failure in 1 or 2 refuses rather than falling through — in both cases we know where the user is sitting, so another terminal would put the server where they are not looking.

**Every `new-window` passes `-d`.** tmux otherwise makes the new window active, so staging a server yanks the user's view off whatever they were doing. When that thing is the Claude Code session they ran `/dev` from, Claude simply vanishes and there is no affordance telling them how to get back — the observed report was "it opened the server and I lost Claude". `-d` creates the window in the background; the `where:` line already tells the user `Ctrl-b n` reaches it. Staging a server is not a request to be looked at.

The iTerm2 backend's `create tab` does also make its new tab active, and that is deliberately left alone: iTerm draws a labelled tab bar, so the user can see both where they landed and the tab they came from. tmux gives a window number in a status line a non-tmux user does not read, which is why the same behaviour is harmless in one and disorienting in the other.

The tmux window is titled with the same `<app> @ <project-name> (:<port>)` string as the iTerm tab, and `automatic-rename` is pinned off on that window so a long-running dev server cannot relabel it from its own process name. The staged command is followed by `exec $SHELL`, so the window outlives a crashing server and keeps its output on screen — matching the iTerm tab, where `write text` runs the command in a shell that survives it.

### 12.2.3. The Agents-view environment gap

§12.1 names the cwd half of this: Agents view spawns its host shell from `~/projects` with no project context. The same gap drops terminal identity.

An Agents-view session's host is spawned by launchd (`LAUNCHCTL_ENV_REEXEC`, `XPC_SERVICE_NAME` and `INVOCATION_ID` are present in its environment), so it does not inherit the interactive shell's. `TERM_PROGRAM`, `ITERM_SESSION_ID` and `LC_TERMINAL` are therefore absent. `ITERM_PROFILE` and `LC_TERMINAL_VERSION` survive, but only because a fresh login shell re-sources `~/.iterm2_shell_integration.zsh` — they are not evidence of inheritance.

**So terminal identity must never be detected from the environment in this subsystem.** A gate on `TERM_PROGRAM` would make `/dev` refuse in exactly the sessions it was written for. `osascript` works there because it asks iTerm over Apple Events and consults no variable. `$TMUX` is trustworthy in one direction only: tmux sets it directly in the shell the script runs in, so when it is present it is true. **Its absence proves nothing**, which is the trap — Claude Code strips it from the Bash tool's environment even when the session is running inside tmux, so a missing `$TMUX` is not evidence that the user is outside tmux. That is why order 2 asks tmux directly rather than trusting the fall-through.

### 12.3. Invocations

| Input | Effect |
|-------|--------|
| `/dev` | List `dev*` scripts from the resolved project's `package.json`. Await user choice. |
| `/dev <app>` | Stage `npm run dev:<app>` at the project root on the detected port (auto-bumped on collision). |
| `/dev <app1> <app2>` | One iTerm tab per app. |
| `/dev <app> --tunnel` | Stage `npm run dev:tunnel:<app>` — cloudflared + vite in one tab, public at `<subdomain>.thenextage.com` (default `<app>`). Mutually exclusive with `--main`. See §12.3.2. |
| `/dev --status` | List listening processes on `:3000-:3099` (pid, port, cwd, cmd). Never kills. |

### 12.3.2. Cloudflare tunnel mode (`--tunnel`)

`/dev <app> --tunnel` swaps the staged script from `dev:<app>` to `dev:tunnel:<app>`. Consumer projects wire that script in `package.json`:

```json
"dev:tunnel:shop":   "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs shop",
"dev:tunnel:dealer": "node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs dealer"
```

The kit ships `dev-with-tunnel.mjs` at `_claude-project/skills/dev-server/scripts/dev-with-tunnel.mjs`. **Byte-identical across all consumer projects.** Hostname convention is `<subdomain>.thenextage.com`. The parent is this shop's standard tunnel domain and is fixed: every consumer's apps live under it. The subdomain is the script's optional second argument, defaulting to `<app>`; a project whose app folder has a generic name (`web`) passes its product name there, because the script name must match the folder for `/dev` to find the app's `vite.config.ts` while the hostname must be unique across projects.

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
- A session with neither tmux nor iTerm2 has no backend (§12.2.2). The skill exits with a clear message and prints the intended command and path for the user to run by hand.

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

The skill REFUSES to proceed if `<project-root>/design.md` is not present. It surfaces the gap to the user verbatim and offers to **generate `design.md`** from the codebase — a one-time bootstrap per project. The CSS `@theme` block is the source data; the resulting `design.md` is its documented superset.

The hard stop exists because ad-hoc styling without a design system spec is how token drift starts. There is no per-task opt-out.

### 12a.4. Spec-compliance validation

`design.md` MUST conform to the google-labs-code spec. The skill instructs Claude to run the linter whenever `design.md` is modified:

```bash
npm run lint:design
```

The linter is wired as a **declared** dev tool, not run ad-hoc: each consumer adds `@google/design.md` to `devDependencies` and a `"lint:design": "design.md lint design.md"` script. Declaring it (rather than `npx @google/design.md …`) keeps the lint reproducible and avoids agent sandboxes blocking an undeclared external download. `package.json` is consumer-owned (not a kit-synced file), so this dep + script are added per project at setup.

Lint must pass before the change is committed. In CI the `biome` job runs `lint:tokens` and `lint:design` whenever a `design.md` exists at the repository root, and a missing script fails the job. The spec defines: optional YAML frontmatter token block (`colors`, `typography`, `rounded`, `spacing`, `components`), markdown body with required-order sections (Overview, Colors, Typography, Layout, Elevation & Depth, Shapes, Components, Do's and Don'ts), atom-level component definitions with property tokens.

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

### 12a.8. Claude Design — the `claude-design` skill

Claude Design is a prototyping tool a project reaches for, from Claude Code or claude.ai,
whenever a screen is worth working out visually first. The design system wires it in:
the system is published from code, a design is built from the project's own components,
and the design comes back into code as the reference the real screens are built from.
The `claude-design` skill is AI reference, and `/ui-design` is that skill invoked
directly, the way the gitflow commands are the gitflow skill's. The skill carries the
engine that builds a Claude Design "Design System" from the UI package
(`scripts/build.mjs`, driven by a per-project `design-system.config.mjs`), the render
check that mounts every component the way a design page and a canvas do, and the
actions of a design's life: `start` (a folder under
`project-documentation/temporary/design-<name>/` and the design conversation),
`create-design` (the brief, then the design — once), `work` (pick a design back up from its
folder and keep changing it in conversation), `feedback` (`work` with the reviewers'
comments as its agenda, the way `/work <N>` is `/work` with an issue), `implement` (gated
on every design-system gap being landed or rejected — `check-design.mjs --implement` —
then the design exported into its folder and built into screens, its link kept in
permanent docs),
`publish-system` (build, verify, publish the design system) and `apply-system` (bring
designs onto the current system). Every action that opens an existing design takes its
address from the folder's `README.md`, so nobody pastes a link, and first checks the
design's copy of the system against the published version, asking whether to apply the current
one when it is behind. Every change settled in `work` or `feedback` is appended to `brief.md`'s
`## Decisions`: the design's history, which lives only as long as the transient folder.
The config's required `timeZone` dates each sync in the project's zone.

Two rules follow from it and live in the `design-system` skill: every token resolvable
and commented ("Tokens must survive the trip to Claude Design"), and design-system
components kept inside what React 18 and 19 share, because design pages run React 18.

Project-specific values live in three places only. The project's paths are the ten
`DESIGN_*` substitution keys (§9.7). The content — title, namespace, the Design System
artifact's address, components and previews, cover — is the UI package's
`design-system/design-system.config.mjs`, which `scripts/config.mjs` validates on every
run: an unknown key, a missing required key or an unset substitution fails by name, and
a path key that belongs in the substitutions names the key it moved to. Each design's
`project-documentation/temporary/design-<name>/` folder holds it while it is in progress.
The engine's scripts hold nothing project-specific; `references/config-example.mjs`
documents every key the engine reads, and a project's config carries a one-line pointer
to it rather than a copied header.

**The engine generates two files the UI package commits:**
`design-system/safelist.generated.css`, which the feed stylesheet imports so Tailwind
ships every class the README promises a design, and `src/lib/design-tokens.generated.ts`,
whose `designClassGroups` the package's `cn()` passes to `extendTailwindMerge` so two
classes of one role merge to the later one. The token checker fails while either is out
of date or not imported.

**Releases.** `publish-system` numbers each publish: the number after the one the
system's `lastChange.note` opens with, or 1. `build.mjs --release <n>` stamps
`Release <n> · built <date> from <sha>` on the system's README, on its cover where the
cover marks `<!-- ds-stamp -->`, and in `lastChange.note`. Claude Design's own version
ids are opaque, so this line is what a design's folder `README.md` records as the
release it uses, and what tells a reader whether a design is behind the system.

**The token checker** is kit-owned: `skills/design-system/scripts/check-design-tokens.mjs`,
run as `npm run lint:tokens`. It reads its paths from the `DESIGN_*` keys, checks
classes, call sites, token resolution and light/dark parity, `design.md`'s references,
and the generated files, prints how many files and classes it inspected, and fails when
that is nothing. A project's own extra checks go in
`<DESIGN_UI_PACKAGE>/design-system/checks/*.mjs`, each a default-exported function the
checker runs with the API its header documents.

`skills/claude-design/references/working-with-claude-design.md` is the reference the
skill reads before any design work: what Claude Design is for, what a design is (an
interactive prototype), how a design is driven and shared — from Claude Code or its
chat, and from Claude Code by link for an editor in another organization — what the
engine handles, and the
review and two-person processes.

`project-documentation/designer-handbook.md` is the human introduction, and
`project-documentation/ui-design-cheatsheet.md` the one-page user reference, the
companion to `gitflow-cheatsheet.md`.

Template-only, like the rest of this subsystem.

---

## 12b. Autonomous mode

`/autonomous <what to work on>` is the only way a turn becomes autonomous when a human launched it. The mode itself is defined in `rules/autonomous-sessions.md`; the command exists to enter it reliably.

The argument is free-form natural language. Scope resolves from a named plan file (`/autonomous execute plan @<path>`), from the conversation (`/autonomous I'm stepping away — finish what we've been discussing`), or from the argument itself (`/autonomous fix the failing integration tests and open a PR`).

Every invocation converges on the same steps: resolve scope, get it into a plan document under `project-documentation/temporary/`, stamp an autonomous line with the date into that document, run to completion without check-ins, then clear the stamp and produce the final report.

The stamp is the point. The mode is declared mid-conversation, and a long turn gets summarized — taking the sentence that set the mode with it. A line in a file survives compaction; the conversation does not.

Dogfooded: the command lives in both `_claude-project/commands/autonomous.md` and the kit's own `.claude/commands/`.

Full spec: `commands/autonomous.md`.

## 12c. Session handoff

`/handoff` writes `project-documentation/temporary/handoff-<login>.md`; `/work` reads it. Together they are the continuity mechanism across sessions — the file survives compaction and a closed terminal, which the conversation does not.

**The handoff is per developer, keyed by GitHub login (`gh api user`).** It is one person's continuity between their own sessions, not a baton passed between people. A single shared file broke as soon as a project had two active developers: one person's items landed in the other's session start, flagged as unmoved in a session that could do nothing about them, and two people rewriting one committed file conflicted on every merge. So tasks live in GitHub issues, where an owner is explicit; project context lives in the topic docs; and the handoff keeps only the messy middle — what you were doing, where you left it, and what you are waiting on. The commands never edit another developer's file on their own initiative. At the human's direction they do: another developer's handoff is how you reach them at the start of their next session — "ask Sam to look at xyz" — so the item goes into their file under From others, signed and dated, created if they have none, and nothing else there changes. Their `/work` raises it. A login that cannot be resolved stops `/handoff` rather than writing under a guess.

The document is written for the next session's AI, rewritten in full every time, and holds no git state. Branch names, file counts and last commits are stale the moment the next `/commit` runs, and `git log` returns them for free.

**Continuity is enforced by classification, not by memory.** `/handoff` reads the outgoing document before writing the new one, and every open item in it resolves to exactly one of four outcomes: done (needs evidence from the session), dropped (needs a stated reason), carried (the default), or waiting on (released by an event outside the developer's sessions, and naming the issue or doc that tracks it). Silence is not a resolution — that is what stops a session that worked three of four items from dropping the fourth. The counter-pressure against the document growing into an unpruned backlog is the unmoved flag: an item carried unchanged into a third consecutive handoff is surfaced to the human with its age, since they are the one who can say whether it still matters. A waiting-on item never counts toward it: no session can move it, so raising it every session is noise.

**Every item is checked against its source before it is carried or raised.** A carried line gets repeated to the human as fact, and the drift usually starts upstream — a topic doc still listing a step as open after it was done, which the handoff then copies forward session after session. Both commands check the tree, the doc or the issue first, and fix the source when it is the source that went stale.

**Empty sections are absent, not empty.** Only the date, the summary of what happened, and the document index are mandatory. A session can finish clean with no blockers, no open questions and no next step, and that is a complete handoff. Manufacturing a next step to fill a heading is worse than omitting the heading, because the next session acts on it.

`/handoff` also sweeps the rest of `temporary/`, applying the spent-plan rule from `rules/development-guidelines.md`: durable content promoted present-tense into the right permanent doc, the plan file deleted. A file named in another developer's handoff, or whose header names someone else as its reader, is theirs and never swept — one developer's handoff not mentioning a file says nothing about whether it is spent. The `handoff-*.md` files are exempt — they are the folder's permanent residents, replaced rather than retired.

`/work` reads the handoff once per session, on whichever invocation came first, including `--issue` and free-text forms. What the human pointed the session at leads the orientation summary; the handoff folds in where it bears on that, or trails as a marked note when it does not.

`/autonomous` ends by invoking `/handoff` rather than doing the sweep inline. The run's final report and the handoff are different artifacts: the report is the account of the run, delivered in the conversation; the handoff is the next session's starting context, on disk.

Dogfooded: the command lives in both `_claude-project/commands/handoff.md` and the kit's own `.claude/commands/`.

Full spec: `commands/handoff.md`.

## 12d. Analysis and discussion pages

The `analysis` skill publishes a shared analysis as a claude.ai Artifact that readers discuss in comments, and `/work --discussion <slug or artifact link>` pulls that discussion back into an action plan. When to use it, what readers see and the discussion folder: `analysis-and-discussions.md`.

**Where it lives in the kit:**

| Piece | Kit source | Role |
|---|---|---|
| Format decision and publishing | `_claude-project/skills/analysis/SKILL.md` | writes the folder, builds and publishes the page, writes the pointer |
| Page generator | `_claude-project/lib/gen-report.mjs` | discussion and report pages, and E2E reports |
| Pull-back | `_claude-project/commands/work.md` Step 3b | reads the page, the comments and the feedback; writes the plan |
| Folder lookup | `_claude-project/skills/gitflow/scripts/work.sh` (`--discussion`) | resolves slug or link to the folder and prints the pointer; `work.test.sh` covers it |
| When to build a page | `_claude-project/rules/communication.md` | the cue words, and Artifacts as the way to share |
| Sweep exemption | `_claude-project/commands/handoff.md`, `rules/development-guidelines.md` | keeps open discussion folders out of the `temporary/` sweep |

The skill and the generator are template-only: the kit has no stakeholders to share with, so it does not run them itself (`.claude/rules/project/dev-kit-workflow.md`). `/work`, `/handoff` and the rules are dogfooded.


## 13. Troubleshooting

### 13.1. Sync shows files I don't recognize as kit-only

Kit added new files since your last sync. The lockfile's `lastSyncedCommit` is behind kit HEAD. Run through the diff review normally; accept or reject each.

## 14. Testing the kit's hooks

How: `.claude/rules/project/hook-testing.md`, which loads when a hook is edited. Why it looks nothing like an app's test suite:

**A broken guard fails open, and silence is also what success looks like.** Every guard allows by printing nothing and exiting 0 — byte-for-byte what a guard that crashed, mis-parsed its input or matched nothing produces. A hook can be inert for months with no symptom but a block nobody was expecting.

**The blast radius is every project at once,** arriving at each one's next sync with the authority of shared tooling nobody re-reads.

**The environment is the bug.** The defects found in practice were portability and encoding errors, not logic. A guard matching with `\b` in `sed` was inert on every Mac — BSD `sed` has no `\b` — and a Linux CI runner would have certified it healthy indefinitely. That is why suites run on edit, on the machine, through `test-on-edit.sh`: CI on Linux conceals exactly this class, and running at sync time lands a failure on whoever synced next, with no context for it.

**Allow cases come first** because a guard that blocks legitimate work gets routed around within a day, and then protects nothing. **Deny payloads go through a JSON encoder** because four guards built theirs by interpolating the command into a heredoc; any command with a double quote produced unparseable JSON, which is discarded, and the command ran. **Escape hatches are tested from the command string** because two hooks checked `SKIP_X=1` in their own environment, where a command prefix never sets it — the documented override had never worked. **Environment-dependent hooks point at temp fixtures** because a `block-kit-edit.sh` suite inheriting the maintainer's `HOME` passes every case by doing nothing.

Every one of those defects passed a reading. None survived a test.

**The shared pieces:**

| File | Role |
|---|---|
| `hooks/guard-lib.sh` | Sourced by every guard. `require_tools` refuses the action (deny, block or warning, by event) when `jq` or `python3` does not actually run, naming the tool and this platform's install line — a guard that cannot read its input never allows. A passing check is remembered per `PATH` for the session. `normalize_path` / `path_rel_to` give one spelling per file across `\`, drive letters (`C:/`, `/c/`, `/cygdrive/c/`) and symlinks. `sha256_file` uses `sha256sum` or `shasum`. On Windows it wraps `jq` in `--binary` mode (jq 1.7+) so output is LF. Plain bash 3.2, no `jq` or `python3`, because its first job is to report them missing. |
| `hooks/toolchain-check.sh` | First `SessionStart` hook. Checks `jq` and `python3` run, that the commit gate can typecheck (a `check-types` script where the repository has TypeScript sources; pyright or mypy for a root `pyproject.toml` or `pyrightconfig.json`), and on Windows refreshes once per `.gitattributes` change every tracked file whose disk copy is CRLF and otherwise identical to Git's (marker `kit-eol-checked` in the git dir). It warns the human and tells Claude when something is missing. |
| `hooks/test-helpers.sh` | Fixtures for the suites: `path_without <tool>` (a `PATH` missing a tool), `path_with_store_python` (the Windows Store `python3` stub) and `assert_refuses_without`, which proves a guard refuses rather than allows when its tool is gone. |

**`bash_edit_replay`.** `bash-edit-guard.sh` replays a shell command's file changes through the Edit/Write guards, with `bash_edit_replay: true` in the payload. A guard that needs the whole change reads it from that flag: `block-kit-edit.sh` then compares the file on disk with its committed (`HEAD`) version, because the change has already landed. A guard that could not run on a replay is reported, not counted as an allow.

---

## 15. Pipeline roadmap

What the kit's pipeline does today and what is deliberately deferred. The design itself is `pipeline.md`.

**Phases 1–6: DONE** (current capabilities). **Phases 7–10 + follow-ups: DEFERRED** roadmap.

### Done (current capabilities)

| Phase | Capability |
|-------|------------|
| 1 | GitHub config (squash-only, auto-delete branches) + basic CI (type-check + Biome + Semgrep, parallel jobs, concurrency-cancel). |
| 2 | gitflow subsystem (`/work` `/commit` `/checkpoint` `/open-pr` `/merge` `/catchup`), commitlint title gate, issue↔branch↔PR linking, raw-git hook guard. |
| 3 | Release automation via local `/deploy` (bump + changelog + tag + push + dispatch deploy), direct-push of the version bump to `main`, deploys dispatched only by `/deploy` (CodeBuild by default). |
| 4 | Quality/security: Gemini advisory review, Dependabot (monthly + cooldown + grouping), Dependabot surfacing, Node LTS check, Semgrep + `.semgrepignore`. |
| 5 | Test infrastructure: Vitest config (unit + integration projects), one-branch-per-run ephemeral Neon harness with transaction-per-test isolation, migration-during-PR, test dir structure + auth/util scaffolding, Vitest in CI. |
| 6 | Unit + foundational integration tests for the complex-logic functions (pricing, packing, totals); all green in CI as a required check. |

### Deferred roadmap

#### Phase 7 — Integration tests (server-function scope)

Builds on the Phase-6 `dbTest` / one-branch-per-run wiring; the per-PR migration pattern is in place. Scope is the server-function-file layer — none written yet.

| What | Priority | Blocker |
|------|----------|---------|
| Checkout flows (money path) | CRITICAL | Stripe test keys as CI secrets + Mailpit |
| Product/listing, account/approval, price-list generation functions | HIGH | None (DB branch in place) |
| Init/cache, order retrieval | MEDIUM | None |
| Contact, admin | LOW | None |

- **Shared blockers:** Stripe Test Mode keys promoted to CI secrets; Mailpit in the test docker-compose (Phase 5D below); auth mocked (the one acceptable mock — shape stubs already exist).
- **How written:** dedicated session per function file; Claude generates tests following the project's testing patterns. Review gate per test: *"if this function changed and produced wrong results, would this test catch it?"*
- **Effort:** initial batch ≈ 3–5 days. Neon cost variable, budget ~$5–15/mo once integration tests are the main consumer.

#### Phase 8 — E2E hardening

The E2E model (Claude-as-tester via `agent-browser`, flow files, standalone `/e2e` command) is **shipped and exercised**. What remains is hardening, not building.

| Item | What | Blocker / effort |
|------|------|------------------|
| Substantive behavioral assertions | Move beyond render-checks to correctness: price-math, cart+shipping recalculation, payment elements mount + accept input, post-login tier reflects correctly. | Per-flow, accretion-on-demand |
| New-flow expansion | Confirmation-email verification (needs Mailpit); generation flows. | Mailpit (Phase 5D) for the email flow |

#### Phase 9 — Production monitoring

Fully independent — can start anytime. None of the three pieces started.

| Item | What | Cost | Notes |
|------|------|------|-------|
| Error tracking (Sentry) | Account (Team plan, **flat / unlimited users**, not per-seat); install client + server SDKs in each app; source maps; perf monitoring; alert rules. | ~$26/mo | Multiple devs need access (free tier = 1 user). Decision locked. |
| Uptime monitoring (UptimeRobot) | Account + per-URL HTTP monitors (5-min interval) + alert contacts. | $0 | ~5-min setup. |
| Log viewer | Browser-accessible Pino-aware admin log viewer (level/namespace/search filter, file selection, pagination, context view, download, admin-gated). | $0 | **Decision still open:** port an existing in-house admin viewer (~1 day; parses Pino JSON natively) vs. Dozzle (10-min, but raw stdout — no Pino-field parsing, no filter, no download). The in-house port is recommended; pick before starting. |

**Effort:** Sentry ~half-day (apps + source maps); UptimeRobot minutes; log viewer ~1 day if porting.

#### Follow-up optimizations (cross-cutting)

| Item | What | Why deferred |
|------|------|--------------|
| Mailpit (Phase 5D) | Add Mailpit to the test docker-compose; configure app to use Mailpit SMTP in test mode. | Unit tests don't need email; needed by Phase 7 integration tests. |
| Test-enforcement rule (Phase 5E) | A project rule: editing complex-logic dirs verifies corresponding tests exist + pass; flag if missing. | Deferred until real tests landed (now done); the advisory-review styleguide already covers the PR side. |
| Surfacing `workflow_run` filter | Filter the surfacing trigger to fire only on dependency-merge deploys (author-based). | Advisory-refresh value applies only when a new dep version shipped; current cadence works, just noisier. |
| Autonomous-gitflow invocation guard | A `PreToolUse` hook on gitflow invocations that blocks when the latest user prompt contains no authorization keyword. | Text rules ("never proactively invoke git") aren't load-bearing — rule-reading and tool-calling are decoupled. Structural fix (same class as the destructive-git guard). Not yet scoped. |
| Evaluate fallow.tools | [fallow.tools](https://fallow.tools/) — "codebase intelligence for typescript and javascript." Assess as a CI codebase-analysis step (quality/dead-code/dependency signal). Not yet trialed. | Candidate flagged 2026-06; needs hands-on eval before adopting into CI templates. |

---

## 16. What's deliberately NOT here

- **Automated kit-update PRs.** Single-user kit. No need for GitHub Actions that PR kit updates to consumer projects. The maintainer runs `/sync-dev-kit` when ready.
- **Kit versioning / releases.** The kit repo is public, but is not distributed as a versioned artifact — there is no package, tag, or release to depend on. Syncs point at kit HEAD commit SHA, not a version.
- **A maintainer-setup command.** Setting up a maintainer machine is prose in §0.1, not a slash command. It happens twice in the kit's life, and a command run that rarely can never be trusted to deliver a change — the temptation to use it as a propagation step is exactly the failure. `/install-statusline` and `/install-cpl` remain commands because they build or fetch something rather than copying files.
- **Global sync.** Dropped, and consumers now receive nothing globally at all. The only global artifacts are the maintainer surface and the statusline, both installed once per machine. A global command file outranks a project's copy and cannot be reached by `/sync-dev-kit`, so anything shipped there diverges silently — see §0.

---

## 17. References

- `skills/gitflow/SKILL.md` — gitflow skill, trigger metadata and routing
- `skills/gitflow/references/commit-types.md` — commit type emoji/format reference
- `skills/gitflow/references/changelog-rules.md` — changelog entry rules
- `skills/gitflow/scripts/*.sh` — the scripts that actually do git operations
- `.claude/rules/git.md` — git workflow rule (reminder layer)
- `.claude/hooks/git-guard.sh` — raw-git blocker (commit + destructive ops)
- `.claude/hooks/bash-edit-guard.sh` — replays every Edit-matched hook over the files a Bash command changed (`tool_response.bashEditDiff`)
- `.claude/hooks/bash-edit-diff-check.sh` — SessionStart warning when `bashEditDiffEnabled` is not on. Only user or managed settings, or `CLAUDE_CODE_BASH_EDIT_DIFF` in the launch environment, turn it on; Claude Code ignores both from a project's settings
- `.claude/hooks/rule-prose.sh` — the one definition of rule prose, shared by `rule-authoring-guard.sh` and `rule-review.sh`
- `templates/settings.base.json` — settings.json starting point for new projects
- `templates/.mcp.json` — MCP template for new projects
- `developer-onboarding.md` — second-dev setup doc
- Anthropic docs: https://code.claude.com/docs/en/claude-code-on-the-web.md (cloud session behavior)
- Anthropic docs: https://code.claude.com/docs/en/mcp.md (MCP config, env var expansion)
- Exa docs: https://docs.exa.ai/reference/exa-mcp (Exa MCP HTTP transport for Claude Code)
