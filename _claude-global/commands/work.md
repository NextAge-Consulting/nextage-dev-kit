# /work

Enter or create the working area (a git worktree) for the current project. Part of the gitflow subsystem. This is the session-init command — invoke it first in any session that will edit code.

$ARGUMENTS

## The model

Every project has a primary repo folder (e.g. `~/projects/<project>/`) that always sits on `main`, clean. The primary is reserved for git substrate and for plain-CLI workflows that need `main` (notably `/sync-dev-kit`). Work does NOT happen there. All editing happens in worktrees under `<project>/.claude/worktrees/`:

- **`current/`** — the default worktree for a body of work. Same path used across consecutive sessions until `/merge` ships the branch. Always sits on a `wip/*` or feature branch (NEVER on `main`, because `main` is owned by the primary). Created on first `/work` after a merge; removed by `/merge`.
- **Compartments** (`<project>/.claude/worktrees/<name>/`) — opt-in additional worktrees for parallel bodies of work or for retrieving someone else's branch without disturbing `current/`. Each compartment sits on its own `wip/<name>` or feature branch.

`/work` brings the Claude session into whichever worktree applies. The script emits `WORKTREE_PATH=<absolute-path>` on its last line; Claude then calls `EnterWorktree` with that path so subsequent edits land in the worktree, not the primary.

**Why current/ is never on main.** Git refuses to check out the same branch in two worktrees. Primary holds `main`. A second worktree asking for `main` is rejected. Therefore `current/` is created on a fresh `wip/<timestamp>` branch off `origin/main` from day one — content is identical to main at creation time, the only difference is the branch label. First `/commit` renames `wip/<timestamp>` to a real feature branch (`feat/...`, `fix/...`, etc.) per `/commit`'s existing rename logic.

**Local main is refreshed before any worktree create.** When `/work` is about to create a NEW worktree (no `current/` yet, or `--new <name>`, or `--retrieve <branch>`), the script first fast-forwards the primary repo's `main` from `origin/main` via the shared `fast_forward_local_main` helper. **Fail-loud:** if the fetch fails (offline, expired auth, missing gh scope) or local main has diverged, worktree creation aborts with a clear error — better than silently creating a worktree off a stale base. Re-entering an existing `current/` does NOT refresh anything; that's by design (you're in the middle of a body of work, use `/catchup` when you want to integrate latest main).

## Supported invocations

| Input | What happens |
|-------|--------------|
| `/work` | If `current/` exists, re-enter it (resume same body of work across sessions). If missing, create it on a fresh `wip/<timestamp>` branch off `origin/main` and enter it. |
| `/work <free text>` | Same as bare `/work` (enter/re-enter `current/`), then handle the free text as the session's opening prompt. The command runs first; the text is the prompt, not a mode. |
| `/work <issue#>` | If `current/` is missing, create it on a branch derived from the issue title (e.g. `feat/add-email-to-users`). If `current/` already exists, behaves like `/link` — adds the issue to the existing branch. Either way, transitions the issue to In Progress, assigns to current user, dumps body + comments. |
| `/work --new <name>` | Create a new compartment at `.claude/worktrees/<name>/` on a fresh `wip/<name>` branch off `origin/main` and enter it. If `<name>` already exists, just enter it. Use when you need a second body of work in parallel without disturbing `current/`. |
| `/work --retrieve <branch>` | Fetch `<branch>` from origin. If `current/` is clean or absent, check out `<branch>` there. If `current/` is dirty, create a compartment named after the branch (sanitized) and check it out there instead — preserves your WIP. |
| `/work --discard <name>` | Remove compartment `<name>`. Refuses if the compartment has uncommitted changes. Refuses on `current` without `--force`. |
| `/work --discard <name> --force` | Same, but skip the uncommitted-changes refusal. Required to discard `current` (the persistent workspace). Use when you knowingly want to throw away unrelated WIP, or to reset an orphaned `current/` (e.g. body of work was shipped through a different compartment). |

## Procedure

### Step 1: Parse `$ARGUMENTS`

**`/work` is an imperative command, not a suggestion.** It ALWAYS runs the worktree action first (enter/re-enter or create). The command executing is never conditional on the content of `$ARGUMENTS`, and is never deferred or suppressed by any "answer the question first" reasoning — see the §II scope note below.

Identify the mode:
- No tokens → default mode (enter `current/`).
- Single numeric token (`139` or `#139`) → `--issue 139`.
- `--new <name>` → compartment creation.
- `--retrieve <branch>` → branch retrieval.
- `--discard <name>` (with optional `--force`) → compartment removal.
- **Trailing free text matching no flag** (e.g. `/work what is the default retention for meter readings`) → default mode (enter `current/`), AND the free text is captured as the session's **opening prompt**, handled in Step 6 *after* the worktree is entered. Free text is never a mode and never suppresses execution.

Strip leading `#` from numeric tokens. Refuse if multiple *flag* modes are present (free text alongside a flag mode is allowed — it becomes the opening prompt).

**§II scope note (Constitution "Questions Before Code").** §II governs whether Claude writes/changes *code* in response to a prompt. It has NO jurisdiction over whether `/work` executes or whether the worktree is entered — those are session-init, not code. The correct ordering when free text is present is: (1) run the command, enter the worktree; (2) handle the opening prompt, where §II still applies (answer the question, don't write code unless told to). Collapsing this into "the argument is a question, so defer the command" is backwards and forbidden.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/work.sh [flags...]
```

The script handles the worktree mechanics and exits with `WORKTREE_PATH=<absolute-path>` on its last stdout line (unless `--discard`, which has no path to emit).

### Step 3: Enter the worktree (Claude action)

Read the `WORKTREE_PATH=<path>` line from the script's stdout. Invoke the `EnterWorktree` tool with that exact path. This switches the session's working directory into the worktree so subsequent file operations land in the right place.

If the script emitted no `WORKTREE_PATH` line (e.g. `--discard` mode), skip the EnterWorktree call — there's nothing to enter.

### Step 4: For `--issue` mode, read issue context and respond

The script dumps the issue's title, body, and comments to stdout (after the `WORKTREE_PATH` line). Claude MUST read that output and:

1. Summarize what the issue asks for in plain language.
2. Call out any ambiguity, missing context, or inconsistency.
3. Propose an approach before touching code.

This is the whole point of linking issues at session-init time — Claude consumes the context up front and the human can correct the plan before any implementation starts.

### Step 5: Report

- Mode + path: report which worktree the session is now in (or which compartment was discarded).
- Branch state: report the branch currently checked out in that worktree.
- Issue side-effects (if `--issue` mode): report which issues were moved to In Progress / assigned / skipped (project status is best-effort).
- Script exited non-zero: surface the reason.

### Step 6: Handle the opening prompt (if free text was present)

If `$ARGUMENTS` carried trailing free text (Step 1), treat it as the session's first prompt now that the worktree is entered. Respond to it normally — answer questions, investigate, or act per its content. §II still applies here: if the prompt is a question, answer it and do not write code until directed. This step runs AFTER worktree entry, never instead of it.

## Blocking conditions

- Not in a git repository (script can't find a `.git/`).
- Conflicting modes (e.g. `--new foo --retrieve bar`).
- `--issue` with a non-numeric value.
- `--issue` referencing an inaccessible issue (404 / scope missing).
- `--retrieve` referencing a branch that doesn't exist on origin.
- `--discard` on a worktree with uncommitted changes, without `--force`.
- `--discard current` without `--force` (refused to prevent accidental wipeout; `--force` is the explicit confirmation).

## What this command does NOT do

- Does not stage or commit changes — that's `/commit` / `/checkpoint`.
- Does not push or pull — only `git worktree add` / `git fetch` for retrieve.
- Does not open a PR — `/open-pr` after first commit.
- Does not merge — `/merge` when the body of work is ready to ship.

## Branch creation timing

**Every `/work` that creates a worktree also creates a branch.** This is a change from earlier iterations where the worktree would briefly sit on `main` and the branch was deferred to first `/commit` — that model caused collisions with the primary repo's `main` checkout and is gone.

- `/work` (no args), fresh `current/` → created on `wip/<timestamp>` branch off `origin/main`. First `/commit` renames the `wip/` branch to a real feature name (per `/commit`'s existing rename logic for `wip/*` branches).
- `/work <issue#>`, fresh `current/` → created directly on the issue-derived branch (`feat/...`). No rename needed at first commit.
- `/work --new <name>` → compartment created on `wip/<name>` branch. First `/commit` renames per the standard path.
- `/work` when `current/` already exists → re-enter, no branch change.

## Related

- `/link #N[,#N…]` — add additional issues to the CURRENT branch mid-work. Works inside any worktree.
- `/commit`, `/checkpoint` — commit your changes; rename `wip/*` branches to their feature name at first commit.
- `/open-pr` — open a PR from the current worktree's branch. Closes-N's come from linked issues.
- `/merge` — squash-merge the PR, sync the primary repo's `main`, and clean up the worktree.

## Worktree lifecycle reference

| Event | Effect on `current/` | Effect on compartments |
|-------|---------------------|------------------------|
| `/work` first run after merge | Created on `wip/<timestamp>` branch | — |
| `/work <issue#>` first run after merge | Created on issue-derived branch | — |
| `/work` while `current/` exists | Re-enter, no change | — |
| `/work --new <name>` | — | Created on `wip/<name>` branch |
| `/commit` (first one on a `wip/*` branch) | `wip/<…>` renamed to feature name | Same |
| `/merge` from `current/` | Removed. NOT auto-recreated. Next `/work` recreates fresh. | Untouched |
| `/merge` from compartment | If empty (no uncommitted changes AND no commits ahead of new `origin/main`) → removed and the orphaned `wip/*` branch deleted. If has work → left alone with a clear warning that it is out of sync with new main. | Active compartment removed; others untouched |
| `/work --discard <name>` | — | Removed (refuses if dirty unless `--force`) |
| `/work --discard current --force` | Removed. Next `/work` recreates fresh. | — |

## Why primary stays on main

`/sync-dev-kit` and other plain-CLI workflows expect the primary repo on a clean `main`. The earlier worktree design briefly considered "parking" the primary on a placeholder ref so `current/` could hold `main` — that created chicken-and-egg problems for kit sync and any other workflow that branches off `main` in the primary. The current model resolves the collision by giving `current/` its own branch from day one, leaving primary undisturbed forever.
