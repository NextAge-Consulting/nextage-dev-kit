# /work

Start or resume a body of work on a branch in this checkout. Part of the gitflow subsystem. This is the session-init command — invoke it first in any session that will edit code.

$ARGUMENTS

## The model

One checkout, one branch at a time. `/work` puts you on the branch your work belongs on and gets out of the way.

- **On `main`** — refresh `main` from origin, then create the body-of-work branch and switch to it. Any edits already sitting in the tree come along.
- **On a feature or `wip/*` branch** — resume it. This is the re-entry path across consecutive sessions: same branch, same body of work, nothing recreated.

The branch starts as `wip/<abbrev>-<timestamp>` when there is no issue to name it. First `/commit` renames it to a real feature name derived from the commit message (`feat/…`, `fix/…`). You never type the wip name — it is internal session state.

**Local main is refreshed before a new branch is cut.** The script fast-forwards `main` from `origin/main` via the shared `fast_forward_local_main` helper, so the branch starts from current code. Two cases skip the refresh and say so plainly rather than blocking: a dirty tree (your edits carry onto the new branch, which is based on local `main`), and a failed fetch (offline, expired auth, missing gh scope). Neither loses anything — run `/catchup` when you want the latest. Resuming an existing branch refreshes nothing by design; you are mid-body-of-work.

## Supported invocations

| Input | What happens |
|-------|--------------|
| `/work` | On `main`: refresh, cut a fresh `wip/<abbrev>-<timestamp>` branch, switch to it. On a feature branch: resume it. |
| `/work <free text>` | Same as bare `/work`, then handle the free text as the session's opening prompt. The command runs first; the text is the prompt, not a mode. |
| `/work <issue#>` | On `main`: cut a branch derived from the issue title (e.g. `feat/add-email-to-users`). On a feature branch: behaves like `/link` — adds the issue to the branch you are on. Either way, transitions the issue to In Progress, assigns to the current user, dumps body + comments. |
| `/work --retrieve <branch>` | Fetch `<branch>` from origin, fast-forward any local copy, and switch to it. Refuses on a dirty tree — `/checkpoint` first. Your own branch is untouched; `git switch` back when you are done. |

## Procedure

### Step 1: Parse `$ARGUMENTS`

**`/work` is an imperative command, not a suggestion.** It ALWAYS runs the branch action first. The command executing is never conditional on the content of `$ARGUMENTS`, and is never deferred or suppressed by any "answer the question first" reasoning — see the §II scope note below.

Identify the mode:
- No tokens → default mode.
- Single numeric token (`139` or `#139`) → `--issue 139`.
- `--retrieve <branch>` → branch retrieval.
- **Trailing free text matching no flag** (e.g. `/work what is the default retention for meter readings`) → default mode, AND the free text is captured as the session's **opening prompt**, handled in Step 5 *after* the branch action. Free text is never a mode and never suppresses execution.

Strip leading `#` from numeric tokens. Refuse if multiple *flag* modes are present (free text alongside a flag mode is allowed — it becomes the opening prompt).

**§II scope note (Constitution "Questions Before Code").** §II governs whether Claude writes/changes *code* in response to a prompt. It has NO jurisdiction over whether `/work` executes — that is session-init, not code. The correct ordering when free text is present is: (1) run the command; (2) handle the opening prompt, where §II still applies (answer the question, don't write code unless told to). Collapsing this into "the argument is a question, so defer the command" is backwards and forbidden.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/work.sh [flags...]
```

The script handles the branch mechanics. Do NOT call `EnterWorktree` — there is nothing to enter.

### Step 3: For `--issue` mode, read issue context and respond

The script dumps the issue's title, body, and comments to stdout. Claude MUST read that output and:

1. Summarize what the issue asks for in plain language.
2. Call out any ambiguity, missing context, or inconsistency.
3. Propose an approach before touching code.

This is the whole point of linking issues at session-init time — Claude consumes the context up front and the human can correct the plan before any implementation starts.

### Step 4: Report

- Branch: report the branch the session is now on, and whether it was created or resumed.
- Base freshness: if the script reported that `main` was not refreshed, say so and why.
- Issue side-effects (if `--issue` mode): report which issues were moved to In Progress / assigned / skipped (project status is best-effort).
- Script exited non-zero: surface the reason.

### Step 5: Handle the opening prompt (if free text was present)

If `$ARGUMENTS` carried trailing free text (Step 1), treat it as the session's first prompt now that the branch action is done. Respond to it normally — answer questions, investigate, or act per its content. §II still applies here: if the prompt is a question, answer it and do not write code until directed. This step runs AFTER the branch action, never instead of it.

## Blocking conditions

- Not in a git repository.
- Detached HEAD — there is no branch to start or resume.
- Conflicting modes (e.g. `--issue 3 --retrieve bar`).
- `--issue` with a non-numeric value.
- `--issue` referencing an inaccessible issue (404 / scope missing).
- `--retrieve` referencing a branch that doesn't exist on origin.
- `--retrieve` with uncommitted changes in the tree.

## What this command does NOT do

- Does not stage or commit changes — that's `/commit` / `/checkpoint`.
- Does not push — only `git fetch` for the base refresh and for `--retrieve`.
- Does not open a PR — `/open-pr` after first commit.
- Does not merge — `/merge` when the body of work is ready to ship.

## Branch creation timing

**A branch is cut the moment you start a body of work, never deferred.**

- `/work` (no args) on `main` → `wip/<abbrev>-<timestamp>`. First `/commit` renames it to a real feature name.
- `/work <issue#>` on `main` → created directly on the issue-derived branch (`feat/…`). No rename needed at first commit.
- `/work` on a feature branch → resume, no branch change.

`/commit` and `/checkpoint` carry the same safety independently: invoked while on `main`, they auto-create a branch rather than committing to `main`. `/ship-main` is the deliberate, by-name exception for committing straight to `main`.

## Related

- `/link #N[,#N…]` — add additional issues to the current branch mid-work.
- `/commit`, `/checkpoint` — commit your changes; rename `wip/*` branches to their feature name at first commit.
- `/open-pr` — open a PR from the current branch. Closes-N's come from linked issues.
- `/merge` — squash-merge the PR, land this checkout back on `main`, delete the merged branch.
- `/ship-main` — commit straight to `main` with no branch and no PR, for infra and config work.
