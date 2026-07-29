# /merge

Squash-merge the current branch's PR after CI passes. Part of the gitflow subsystem. Invoked directly (`/merge`) or via natural-language triggers ("merge", "merge to main", "ship it", "land this").

$ARGUMENTS

## Procedure

### Step 1: Identify the target PR

If `$ARGUMENTS` contains a PR number (e.g., `/merge 42`), use that. Otherwise let the script auto-detect from the current branch.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/merge.sh [--pr <number>]
```

The script:
- Finds the open PR for the current branch (or uses --pr)
- Invokes `wait-for-pr-ready.sh` which is **trigger-aware**: blocks until CI required checks pass AND — if a `/gemini review` comment was posted for the current HEAD — Gemini Code Assist has posted its review. If no trigger comment exists for the current HEAD (e.g. last `/commit` was `--no-review`), proceeds on CI-only. `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` short-circuits the entire Gemini path. Polls every 30s, times out fail-loud after 15min.
- Squash-merges via `gh pr merge --squash --delete-branch`
- Switches to main, pulls, fast-forward-only
- Removes the active worktree (`current/` or compartment) on disk

### Step 3: Release the deleted worktree from the session (MANDATORY)

If the merge ran from inside a worktree (the common case — `merge.sh` reports `active worktree: <path> (kind: current)` or `(kind: compartment)`), the script removed that directory **but the Claude session is still bound to it via the prior `EnterWorktree` call**. The next tool invocation will spawn its subprocess with cwd set to the deleted directory; the kernel cannot resolve `/bin/sh` from a non-existent inode and the spawn fails with `ENOENT: no such file or directory, posix_spawn '/bin/sh'`. Hooks fail loudly for the first 1–3 calls until the harness recovers cwd to a parent path.

**Immediately after `merge.sh` returns successfully, invoke `ExitWorktree` with `action: "keep"` BEFORE any other tool call.** This releases the session's binding to the deleted path. `keep` is correct (not `remove`) because the worktree is already gone — `remove` would error.

```
ExitWorktree({ action: "keep" })
```

If `merge.sh` reported `active worktree: primary` (rare — the user invoked `/merge` directly from the primary repo without going through `/work`), skip this step; there's no worktree binding to release.

**Expected post-merge LSP noise — DO NOT investigate.** Removing the worktree pulls the rug from under any language server (typescript-language-server, pyright, …) that had the worktree as a workspace root. For the next few tool calls the harness will inject a BURST of stale diagnostics — `Cannot find module './foo'`, `implicitly has an 'any' type` — all pointing at the now-deleted worktree path. These are HARMLESS artifacts of the LSP losing its root, not real errors: `main` is intact and already passed full CI on the feature PRs. Acknowledge them in at most one line ("stale LSP from the removed worktree, ignoring") and move on. Do NOT re-run `tsc` / typecheck / build "to verify main", do NOT open files to chase the errors — that wastes a cycle on a non-problem. The diagnostics clear on the LSP's next index pass.

### Step 4: Report

- Merge succeeded: report the PR number and the commit SHA on main
- Multiple PRs on branch: script lists them and exits; ask user which one (then re-invoke with `--pr <number>`)
- CI checks failing: surface which check failed, link to PR checks page
- Readiness wait timeout (Gemini queued / rate-limited despite a posted trigger): surface the diagnostic message; user decides whether to opt this repo out of Gemini gating (`GEMINI_NOT_INSTALLED="true"` — only correct if Gemini is genuinely absent), extend timeout, or `--force-unchecked` for emergency. The "no triggers fired, ship on CI alone" case happens automatically — `/commit --no-review` is the user's explicit signal that `/merge` should not wait for Gemini.
- Merge conflict: rare with squash but possible; surface the conflict and stop

### Step 5: Note post-merge state

After `/merge` completes, the squash commit is on main. **No deploy fires automatically.** To ship to production, run `/deploy` (which bumps version, writes changelog, pushes, triggers the deploy workflow). Multiple merges can accumulate on main between deploys — `/deploy` ships all commits since the last release tag in one bump.

## What this command does NOT do

- Does not create a new working branch after merge (wt-{username} dropped)
- Does not bump version — `/deploy` does this
- Does not create a tag — same
- Does not deploy to production — `/deploy` does this
- Does not regenerate the changelog — `/deploy` does this

## Blocking conditions

- Current branch is already `main`: nothing to merge
- No open PR for current branch: run `/open-pr` first
- CI has failing required checks: fix and push before merging
- `gh` CLI not available: squash-merge-via-API is not implemented in `merge.sh`; install gh or run the merge manually via GitHub web UI

## Emergency bypass

`--force-unchecked` flag on the script bypasses the CI gate. Use ONLY for hotfixes with explicit user authorization. Never use in automated flows.
