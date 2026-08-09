## CRITICAL: Never Initiate Git Operations Without Explicit Request

**ABSOLUTE RULE**: NEVER proactively invoke any git operation (via gitflow skill, slash command, or direct git) without the user explicitly asking for it in the current message.

This applies to:
- The `gitflow` skill (commits, checkpoints, PRs, merges, branch operations)
- Slash commands `/commit`, `/checkpoint`, `/open-pr`, `/merge`
- Direct git commands (blocked anyway by hook, but the principle holds)

**Forbidden Behaviors**:
- Invoking gitflow after completing work unless asked
- Suggesting "let me commit/checkpoint this"
- Auto-committing after finishing a task
- Any git operation triggered by Claude's own judgment about "good stopping points"

**Why This Rule Exists**: The user controls the git timeline. Even after multiple user-initiated commits/checkpoints in a session, you do NOT have blanket permission to continue. Each git operation requires fresh explicit instruction.

**What Counts as Explicit Request**:
- User says "commit", "checkpoint", "push", "open pr", "merge", etc.
- User asks you to save/preserve work via git
- User explicitly delegates git timing to you (rare)

**What Does NOT Count**:
- Completing a task (does not imply commit)
- User saying "done" or "looks good" (does not imply commit)
- Previous commits/checkpoints in the session (does not grant ongoing permission)
- Your assessment that work should be saved
- "do this in main" / "in the main checkout" — means edit files in the main checkout, NOT `/commit` or `/ship-main`. `/ship-main` and `/deploy` are human-triggered and fire only on their explicit triggers; never initiate either.

---

## CRITICAL: Never Modify `.gitignore` Without Explicit Request

**ABSOLUTE RULE**: Never add, remove, or change `.gitignore` entries on your own judgment. Gitignoring a file changes what the repo tracks and shares with the team — a real decision, not housekeeping. Propose the change and the reason; the human decides.

---

## CRITICAL: Git Reset/Checkout/Revert Forbidden

**ABSOLUTE RULE**: You are FORBIDDEN from running ANY of these commands without EXPLICIT user instruction:
- `git checkout <file>` — Reverts file changes
- `git reset` — Resets commits or staging
- `git revert` — Reverts commits
- `git restore` — Restores working tree files
- `git clean` — Removes untracked files

**Why This Rule Exists**: These commands DESTROY WORK. Using `git checkout` to "fix" a mistake has repeatedly deleted hours of completed work.

**What To Do Instead**:
- If you make a mistake in a file: Use Read/Edit/Write tools to fix it
- If you're unsure about changes: Ask the user what they want
- If the user says "stop": STOP. Do not touch anything
- NEVER assume reverting code is the solution

**ONLY Exception**: User explicitly says "revert the file" or "checkout the file" or "reset the changes"

**Enforcement**: A PreToolUse hook (`git-guard.sh`) BLOCKS these operations. Emergency bypass only via `SKIP_GIT_GUARD=1` prefix when user explicitly authorizes.

**Violation Consequences**: Using these commands without explicit instruction is a CRITICAL ERROR equivalent to data loss.

---

## ABSOLUTE RULE: Always Commit ALL Changes

When the user says "commit", "checkpoint", or any commit operation, ALWAYS commit ALL uncommitted changes (staged, unstaged, and untracked). NEVER do a partial commit by selectively staging files. The gitflow scripts handle staging everything automatically.

**FORBIDDEN**: Cherry-picking specific files to commit while leaving others uncommitted, unless the user explicitly says "only commit X" or "commit just the constitution file".

---

## ABSOLUTE RULE: Git Operations via gitflow Subsystem ONLY

**FORBIDDEN**: You are FORBIDDEN from running ANY of these git commands directly:
- `git commit` — ALWAYS use gitflow (skill or `/commit` or `/checkpoint`)
- `git add` — gitflow handles staging as part of its workflow
- `git push` — gitflow pushes automatically after commits
- `git merge` — `/merge` ships PRs to main; `/catchup` pulls main into a feature branch; both go through the gitflow subsystem
- `git checkout -b` / `git switch -b` — create branches via `/work <issue>` (issue-mode) or let `/commit`/`/checkpoint` auto-create
- `git branch -m` — branch renames happen automatically inside `/commit` when on a `wip/*` branch

**Carve-out for gitflow scripts**: the scripts under `.claude/skills/gitflow/scripts/` ARE authorized to run `git checkout` / `git checkout -b`, `git branch -m`, `git branch -D`, `git merge` (for /catchup and /merge), `git merge --abort` (for /catchup only), `git commit` + `git push origin main` + `git pull --rebase origin main` (for `ship-main.sh` only — the deliberate direct-to-main exception path) as part of their internal logic. This carve-out is scoped to the scripts — it does NOT grant Claude permission to run these commands directly.

**REQUIRED**: The gitflow subsystem has four layers of defense. Always operate within them:

| Natural language trigger | Invokes | Layer |
|--------------------------|---------|-------|
| "work on this", "open the project", "pick up where I left off", "start work" | `/work` slash command (via gitflow skill routing) | 2–3 |
| "start work on #N", "work issue N" | `/work <N>` | 2–3 |
| "retrieve branch", "pull a teammate's branch" | `/work --retrieve <branch>` | 2–3 |
| "commit", "commit this", "commit the changes" | `/commit` | 2–3 |
| "checkpoint", "save progress", "wip commit" | `/checkpoint` | 2–3 |
| "link issue", "also works on #N" | `/link` | 2–3 |
| "catch up with main", "catch my branch up", "get latest main", "pull main into my branch", "update my branch with main" | `/catchup` | 2–3 |
| "continue the merge", "finish catching up" | `/catchup --continue` | 2–3 |
| "abort the catchup", "bail on the merge" | `/catchup --abort` | 2–3 |
| "open pr", "open a pull request", "submit for review" | `/open-pr` | 2–3 |
| "merge", "merge to main", "ship it" | `/merge` | 2–3 |
| "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main" | `/ship-main` | 2–3 |

Claude must invoke the corresponding slash command on any of these natural-language triggers. Direct git is blocked at the hook layer (layer 4).

**`/ship-main` vs `/commit` — the distinction is load-bearing.** Bare "commit"/"commit this" ALWAYS routes to `/commit` (which auto-branches off main — the safety for accidental-on-main). `/ship-main` is the deliberate direct-to-main exception and fires ONLY on the explicit triggers above. Never route a bare "commit" to `/ship-main`, and never infer `/ship-main` from the user being on `main`.

**Why This Rule Exists**: The gitflow subsystem ensures:
- Conventional commit format (emoji + type)
- Validation before commit (typecheck via `pre-commit-validation.sh`)
- Consistent commit behavior local and cloud
- Changelog + version bump are handled locally by `/deploy` (human-serialized release), not by any GitHub Action
- Destructive git commands are blocked before execution

**Violation Consequences**:
- Hook `git-guard.sh` will BLOCK raw git commit/push/merge — you will receive a denial message
- Bypassing the hook requires `SKIP_GIT_GUARD=1` and user authorization

**Emergency Override**: If the gitflow subsystem has a bug and you need to bypass:
1. Request user to authorize with `SKIP_GIT_GUARD=1`
2. Only then run git commands directly
3. Immediately inform user that gitflow was bypassed and why

**Read-Only Operations ALLOWED** (without gitflow):
- `git status` — Check repository state
- `git log` — View commit history
- `git diff` — View changes
- `git show` — Show commit details
- `git branch` (no flags) — List branches
- `git fetch` — Fetch from remote
- `git stash list` — View stashes
- `git ls-files` — List tracked files
- `git config` — Read config
- `git remote` — View remotes
- `git rev-parse` — Parse refs

**ONLY Exception**: User explicitly instructs you to use direct git commands (extremely rare edge cases).

---

## Proactive Use of Subagents and Skills

**Use subagents and skills proactively** to improve efficiency, preserve context, and leverage specialized capabilities:

### When to Use Subagents:
- **Codebase exploration**: Use `Explore` agent for understanding structure, finding patterns, or answering architectural questions
- **Isolated investigations**: Launch agents for self-contained tasks to preserve main conversation context
- **Parallel work**: Use `dispatching-parallel-agents` skill when multiple independent tasks can run concurrently
- **Planning**: Use `Plan` agent for breaking down complex features
- **Code review**: Use `requesting-code-review` skill after completing major work

### When to Use Skills:
- **Debugging workflows**: Use `systematic-debugging` or `root-cause-tracing` for structured investigation
- **Development workflows**: Use `subagent-driven-development` for spec-kit task execution
- **Git operations**: Use `gitflow` — the ONLY authorized path for commits, checkpoints, PRs, and merges

**Principle**: Skills and agents handle their own orchestration. Use them proactively to save context, enable parallelism, and leverage specialized workflows.
