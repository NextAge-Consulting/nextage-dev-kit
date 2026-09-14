# /work

Start or resume a body of work on a branch in this checkout. Part of the gitflow subsystem. This is the session-init command — invoke it first in any session that will edit code. It also loads the previous session's handoff, so the context comes with the branch.

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
- **Trailing free text matching no flag** (e.g. `/work what is the default retention for meter readings`) → default mode, AND the free text is captured as the session's **opening prompt**, handled in Step 6 *after* the branch action. Free text is never a mode and never suppresses execution.

Strip leading `#` from numeric tokens. Refuse if multiple *flag* modes are present (free text alongside a flag mode is allowed — it becomes the opening prompt).

**§II scope note (Constitution "Questions Before Code").** §II governs whether Claude writes/changes *code* in response to a prompt. It has NO jurisdiction over whether `/work` executes — that is session-init, not code. The correct ordering when free text is present is: (1) run the command; (2) handle the opening prompt, where §II still applies (answer the question, don't write code unless told to). Collapsing this into "the argument is a question, so defer the command" is backwards and forbidden.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/work.sh [flags...]
```

The script handles the branch mechanics. Do NOT call `EnterWorktree` — there is nothing to enter.

### Step 3: For `--issue` mode, read the issue context

The script dumps the issue's title, body, and comments to stdout. Read that output now. The response comes in Step 6, where it is combined with the handoff so the session gets one orientation rather than two summaries back to back.

This is the whole point of linking issues at session-init time — Claude consumes the context up front and the human can correct the plan before any implementation starts.

### Step 4: Report

- Branch: report the branch the session is now on, and whether it was created or resumed.
- Base freshness: if the script reported that `main` was not refreshed, say so and why.
- Issue side-effects (if `--issue` mode): report which issues were moved to In Progress / assigned / skipped (project status is best-effort).
- Script exited non-zero: surface the reason.

### Step 5: Read the handoff

**Once per session, on whichever `/work` came first** — every invocation shape, including `--issue`, free text and `--retrieve`. If a `/work` already ran this session, skip this step and Step 6; a second `/work` mid-session does not re-read or re-summarize.

Read `project-documentation/temporary/handoff.md` and open the documents its index points at where they bear on what you are about to do.

No handoff file — say so in one line and move on. That is not a problem to solve: new projects and mid-body-of-work resumes hit that path constantly, and noise there is what makes the step get skipped.

#### Trust, but verify — the handoff is a report, not the repository

**It was written by hand at the end of a session, and only if someone remembered to run `/handoff` at all.** So it can be days stale, it can predate commits that have already landed, and its "done" and "still to do" lines can each be wrong in either direction. Read it for orientation, then check it.

The cheap check, every time:

```bash
# UTC, to compare like-for-like against the handoff's UTC stamp
TZ=UTC git log -8 --date=format-local:'%F %H:%M' --format='%h %ad %s'
git status --short
```

The handoff's H1 carries the LOCAL date it was written; the italic line beneath it carries the same instant in UTC. **Compare against the UTC stamp, using the UTC-normalized log above** — comparing a local date against a log rendered in some other offset invents gaps and hides real ones, and the writer's timezone cannot be inferred from the project. **Commits dated after that UTC stamp mean work has landed that the handoff never saw** — say so in one line and treat the whole file as unverified, rather than discarding it. Uncommitted changes it does not mention are the same signal.

**Never repeat a handoff claim to the human as fact.** A line saying an item is finished, or that one thing remains, is a claim about the tree — confirm it against the tree before it reaches the TLDR. Confirming is usually one `ls`, one `grep` or one `jq`, and it is cheap next to the cost of being wrong: the session goes off to build something that already exists, or skips something that was never finished, and the human only finds out later.

Verify what you are about to act on, not the whole file. A claim you are not going to use this session needs no check.

### Step 6: Orient — one combined TLDR

**Whatever the human pointed the session at leads.**

- **`--issue`** — the issue leads: what it asks for, any ambiguity or missing context, and the proposed approach, before any code. The handoff then attaches to it. Related, fold it in — "the issue wants X; ABC from last session is half-done in the same file." Unrelated, a short trailing note marked as separate — "Also still open from last session: ABC, DEF. Neither touches this issue."
- **Free text** — the prompt leads, same shape. §II still applies: a question gets answered, and no code until directed.
- **Bare `/work`** — the handoff is the whole TLDR, with the claims you are reporting verified per Step 5.

The handoff never displaces what the human pointed at, and it never silently disappears into it.

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
- `/handoff` — writes the handoff this command reads. Run it at the end of the session.
