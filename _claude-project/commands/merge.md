# /merge

Squash-merge the current branch's PR after CI passes. Part of the gitflow subsystem. Invoked directly (`/merge`) or via natural-language triggers ("merge", "merge to main", "ship it", "land this").

$ARGUMENTS

**In an org repo** (`REPO_KIND` is `org`) `/merge` refuses (exit 25): `/deploy` applies a Terraform PR and merges it, and a docs change goes to main with `/ship-main`. **In a combo repo** (`combo`) it refuses only a PR that changes Terraform, which `/deploy` on its branch applies and merges. Say which applies instead of running anything.

## Procedure

### Step 1: Identify the target PR

If `$ARGUMENTS` contains a PR number (e.g., `/merge 42`), use that. Otherwise let the script auto-detect from the current branch.

**In a worktree** (`git rev-parse --git-dir` differs from `git rev-parse --git-common-dir`), ask once, before the script runs, what happens to the worktree after the merge:

- **Remove it** (recommended) — the worktree and its local branch go as the last step of this `/merge`. Costs nothing; the next body of work starts with `/work`.
- **Keep it to deploy from** — it is left detached at the merged `main`, and `/deploy` run inside it removes it once the release ships. Buys deploying without switching sessions; the worktree stays on disk until that `/deploy` runs.

Keeping it adds `--deploy-from-worktree` to the script.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/merge.sh [--pr <number>] [--carry-uncommitted] [--deploy-from-worktree]
```

The script:
- Refuses on uncommitted changes FIRST (exit 26), before any build and before anything
  reaches GitHub — Step 2a.
- Finds the open PR for the current branch (or uses --pr)
- Checks the PR against its base FIRST (exit 23): when `origin/main` has moved, a trial
  merge (`git merge-tree`) decides — a conflict refuses before any build or wait, and drift
  that merges cleanly is reported and the merge goes ahead.
- Runs a **local production build gate** — every workspace with a `build` script (or the
  root, in a single-package repo), counted and printed; with none it says nothing was
  built — while the readiness wait below polls, and before the squash. Its output is
  printed whole when it finishes. A failed build stops the wait (exit 15); a failed wait
  stops the build and says where it stood (exit 11). CI does not build (it type-checks,
  lints and tests), so a build-only break is invisible until here. This is the last
  moment the PR is still OPEN, so a failure is fixed on the branch that caused it rather
  than in a follow-up PR repairing the first. Not in CI on purpose: CI fires on every
  push, and building there would tax every commit, `/open-pr` and triage fix. A build that
  passed records the code fingerprint it built (`code-fingerprint.mjs`), so a re-run of
  `/merge` on the same code — after a failed CI wait, say, or a change to comments only —
  skips the build, saying "code unchanged since the last pass". A failed build is never
  recorded.
- Invokes `wait-for-pr-ready.sh` which is **trigger-aware**: blocks until CI required checks pass AND — if a `/gemini review` comment was posted for the current HEAD — Gemini Code Assist has posted its review. If no trigger comment exists for the current HEAD (e.g. last `/commit` was `--no-review`), proceeds on CI-only. `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` short-circuits the entire Gemini path. When the project's `TEST_RUNNER` is `aws`, the PR is not ready until the `full-suite` commit status from the CodeBuild test project has reported too — it can arrive after GitHub's own checks finish. Polls every 30s, times out fail-loud after 15min.
- Squash-merges via `gh pr merge --squash` with the PR's own title and body as the commit message, whatever the repository's squash setting — the body carries the `Closes #N` line `/deploy` reads to move shipped issues — then deletes the remote branch as a separate best-effort step
- Switches this checkout to `main` and fast-forwards it to the merged tip
- Deletes the now-merged local branch
- Reinstalls dependencies if landing on the new `main` changed a package manifest

In a worktree the landing steps are skipped — nothing local changes — and the script prints
`WORKTREE-REMOVE: <path>` and `WORKTREE-BRANCH: <branch>` (Step 2b). With
`--deploy-from-worktree` it detaches the worktree at the merged `origin/main`, deletes the
merged local branch, and prints `WORKTREE-DEPLOY: <path>`.

### Step 2a: Uncommitted changes (exit 26)

Nothing was merged. The script listed each changed file, marked `(this PR changes it too)`
where it is, and printed `CARRY: offered` or `CARRY: not offered — <why>`. Ask what to do
with them, the way `/triage` asks before its commit:

- **Commit them with a review** — `/commit --review`, then `/merge`. The merge waits for CI
  and a fresh Gemini review of the new head. Costs the review wait; buys a reviewed change.
- **Commit them without a review** — `/commit --no-review`, then `/merge`. Waits for CI only.
  Quicker; the new commit lands unreviewed.
- **Merge without them** — only when the script printed `CARRY: offered`. Re-run with
  `--carry-uncommitted`; the PR merges and the edits carry onto `main`, uncommitted. Say so
  plainly: they are now edits on `main`, outside any PR.

Recommend committing when any file is marked as in the PR — merging without them is not
offered then. Never offer discarding them.

### Step 2b: Leave the worktree, then remove it

When the script printed `WORKTREE-REMOVE`, in this order:

1. **`ExitWorktree` with action `keep`** — first, always. Removing the folder a session
   stands in breaks every shell it starts afterwards.
2. From the primary checkout, where `ExitWorktree` returned the session:
   ```bash
   .claude/skills/gitflow/scripts/worktree-remove.sh <WORKTREE-REMOVE path> --branch <WORKTREE-BRANCH>
   ```
   It removes the worktree and its local branch only when the PR is merged and nothing
   uncommitted is in it, and says what it removed.

**A failed removal is not a failed merge.** Report the merge as done, then name the worktree
left behind and the script's reason. `/work` in the primary checkout raises it again.

When the script printed `WORKTREE-DEPLOY`, stay in the worktree: it is ready for `/deploy`,
which the human runs.

### Step 3: Report

- Merge succeeded: report the PR number and the commit SHA on main
- Uncommitted changes (exit 26): Step 2a
- Carried edits conflicted with the new `main` (exit 19): the merge landed; the edits are in
  the stash, and the files git named need resolving
- Multiple PRs on branch: script lists them and exits; ask user which one (then re-invoke with `--pr <number>`)
- Conflicts with its base (exit 23): the conflicting files are listed and nothing merged —
  run `/catchup`, resolve, then `/merge` again
- Production build failed (exit 15): surface the build error; nothing merged and the PR
  is still open, so the fix goes on this branch and into this PR
- CI checks failing: surface which check failed, link to PR checks page
- Readiness wait timeout (Gemini queued / rate-limited despite a posted trigger): surface the diagnostic message; user decides whether to opt this repo out of Gemini gating (`GEMINI_NOT_INSTALLED="true"` — only correct if Gemini is genuinely absent), extend timeout, or `--force-unchecked` for emergency. The "no triggers fired, ship on CI alone" case happens automatically — `/commit --no-review` is the user's explicit signal that `/merge` should not wait for Gemini.
- Merge conflict: rare with squash but possible; surface the conflict and stop

### Step 4: Note post-merge state

After `/merge` completes, the squash commit is on main and this checkout is standing on it — the next `/work` cuts a fresh branch from here. After a worktree's `/merge`, the session is back in the primary checkout, whose `main` the next `/work` refreshes. **No deploy fires automatically.** To ship to production, run `/deploy` (which bumps version, writes changelog, pushes, triggers the deploy workflow). Multiple merges can accumulate on main between deploys — `/deploy` ships all commits since the last release tag in one bump.

## What this command does NOT do

- Does not create the next working branch — `/work` does that when you start the next body of work
- Does not bump version — `/deploy` does this
- Does not create a tag — same
- Does not deploy to production — `/deploy` does this
- Does not regenerate the changelog — `/deploy` does this

## Blocking conditions

- Current branch is already `main`: nothing to merge
- Uncommitted changes: exit 26, nothing merged — Step 2a
- `--deploy-from-worktree` outside a worktree: exit 2, nothing merged
- No open PR for current branch: run `/open-pr` first
- CI has failing required checks: fix and push before merging
- `gh` CLI not available: squash-merge-via-API is not implemented in `merge.sh`; install gh or run the merge manually via GitHub web UI
- The PR's title or body cannot be read: exit 22, nothing merged
- The branch conflicts with its base: exit 23, nothing merged — `/catchup` first
- The PR is stacked on a branch whose PR has not merged: exit 24, nothing merged — merge
  that one first; this one then targets `main`

## Merging someone else's PR

`merge.sh` posts an approving review as you before it squashes a PR someone else wrote, so
the PR records who wrote it, who reviewed it and who merged it. If the approval fails it
says so and merges anyway. Your own PR gets no approval.

## Emergency bypass

`--force-unchecked` flag on the script bypasses the base-drift check, the production build and the CI wait. Use ONLY for hotfixes with explicit user authorization. Never use in automated flows.
