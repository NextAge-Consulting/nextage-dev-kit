# /ship-main

Commit straight to `main` — no branch, no PR, no CI. The **conscious exception** for quick infra / emergency / "just get it in there and get back to clean" work. Part of the gitflow subsystem. Invoked via `/ship-main` or natural-language triggers: "ship to main", "commit straight to main", "commit this directly to main", "infra commit", "emergency commit to main", "quick commit to main".

$ARGUMENTS

## When to use this (and when NOT to)

| Use `/ship-main` | Use `/commit` (the default) |
|---|---|
| Conscious infra / config / emergency change you want on main NOW | Real feature work |
| You accept no PR, no CI, no review — main's history is the trail | You want branch → PR → CI → review → merge |
| You're sitting on dirty `main` and want back to clean | Anything that deserves review |

**This is never inferred.** Being on dirty `main` is often *accidental* — you started editing before `/work`. So a bare `/commit` on `main` still auto-branches — that's the safety. `/ship-main` is the opposite, on purpose, and only when you ask for it by name.

## Procedure

### Step 1: Confirm this is genuinely a direct-to-main change

If there's any doubt it's a deliberate exception (it looks like feature work, or the user said "commit" not "ship to main"), STOP and use `/commit` instead. Direct-to-main skips CI and review — only proceed when the user explicitly wants that.

### Step 2: Compose a conventional commit message

Same rules as `/commit` — `<emoji> <type>(<scope>): <subject>`. **Conventional format is required**, not optional: `/ship-main` commits land on `main` and are read by the next `/deploy` (commit subjects since the last tag) to compute the bump level + changelog, exactly like a merged-PR squash commit. A malformed subject mis-classifies the release.

### Step 3: Invoke the script

```bash
.claude/skills/gitflow/scripts/ship-main.sh --message "<conventional message>" [--skip-typecheck]
```

The script:
- Refuses unless on `main`/`master` — a body of work in progress is on its own branch and cannot trip it.
- Runs `check-types` + `biome lint` (the assist that stays). Pass `--skip-typecheck` ONLY for a true emergency where you knowingly accept the risk.
- Stages all changes, commits directly on `main` with `--no-verify` (validation already ran).
- Pushes straight to `main`. If `origin/main` advanced, it rebases the commit onto it and re-pushes; on conflict it stops and tells you to resolve + push.

### Step 4: Report

- Success: confirm the commit is live on `main` (SHA + subject). No PR URL — there is none by design.
- Refused (not on main): tell the user they're on `<branch>`; use `/commit` for branch work.
- Typecheck/biome failure: surface the command to run; offer `--skip-typecheck` only if the user explicitly accepts shipping unverified.
- Rebase conflict: surface the conflict; the user resolves then `git push origin main`.

## Closing issues without a PR

`/work <issue#>` and `/link` park their issue links on the branch you are standing on and cut nothing, so on `main` those links are sitting right here. `ship-main.sh` reads them, appends a `Closes #N, #M` line to the commit body, and clears them once the push lands.

GitHub honours that keyword on a commit pushed to the default branch, not only in a PR body — so an issue closes itself with no PR, no CI and no review anywhere in the picture. That is the whole point: an issue that turns out to be a docs or infra change should not have to round-trip through a PR to get closed.

Project-board status is deliberately left alone, matching `/merge`, which also does not transition. Only `/deploy` marks Done.

The link is cleared only after a successful push. If the push fails the link stays put, so a retry still closes the issue.

## What this does NOT do

- Does NOT open a PR or run CI — `pull_request` workflows don't fire on a push to `main`, and that's the point.
- Does NOT deploy — deploy workflows are `workflow_dispatch:`-only; a main push triggers nothing. Run `/deploy` to ship.
- Does NOT bump version or write changelog — `/deploy` owns that; your ship-main commits get folded into the next release automatically.
- Does NOT auto-branch — that's `/commit`'s job and the whole reason `/ship-main` is separate.

## Prerequisite

`main` must NOT require a PR — the default on a new repo (the pipeline uses no branch protection; see `pipeline.md` §1.1). With require-PR set, GitHub rejects the direct push.
