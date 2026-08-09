# /link

Link one or more GitHub issues to the CURRENT branch mid-work. Part of the gitflow subsystem. Use when you're already on a feature branch and discover the work also addresses issue(s) you didn't link at branch-creation time.

$ARGUMENTS

## DO NOT recommend splitting work into separate PRs

When the user `/link`s an additional issue to a branch already addressing other issues, this IS the user's explicit decision to bundle multiple issues into one PR. Do NOT respond by:

- Suggesting they `/open-pr` + `/merge` the prior work first.
- Suggesting `/work --new <name>` for the new issue to "keep things clean."
- Framing the bundling as a scope concern, clean-history tradeoff, or review-cycle hygiene issue.
- Asking whether they'd prefer to split.

This shop bundles freely and ships when the user says ship. See `skills/gitflow/SKILL.md` § "Workflow philosophy: bundle freely" for the full rule. The act of invoking `/link` is the answer — do not re-litigate it.

## When to use

- Work in flight on a branch already opened via `/work <issue>`, and you realize another issue is in scope.
- Work started on a `wip/*` branch without explicit issue linking, and you want to backfill.
- Any time the set of issues a branch addresses changes.

Equivalent to the issue-linking side-effects of `/work <issue#>` but always operates on the existing branch instead of creating one.

## Supported invocations

| Input | What happens |
|-------|--------------|
| `/link #27` | Links issue #27 to current branch, moves to In Progress on project, assigns to current user, dumps body + comments. |
| `/link #27,#28,#29` | Same for multiple issues. All get linked, transitioned, assigned, dumped. |
| `/link 27 28` | Space-separated also accepted. `#` is optional. |

## Procedure

### Step 1: Parse `$ARGUMENTS`

Extract issue numbers (comma or space separated, `#` prefix optional). Build a CSV.

### Step 2: Invoke the script

```bash
.claude/skills/gitflow/scripts/link.sh --issues "27,28,29"
```

### Step 3: Read issue context and respond

The script prints issue bodies + comments to stdout. Claude MUST read that output and:

1. Summarize what the additional issue(s) ask for.
2. Check whether the work already done on this branch covers them or needs adjustment.
3. Propose next steps — same plan-before-code discipline as `/work <issue>`.

### Step 4: Report

- Linked issues: report each by number, with status-transition and assignment outcomes.
- Script exited non-zero: surface the reason.

## Blocking conditions

- Current branch is `main` or `master` — can't link issues to the protected branch. Start a feature branch first with `/work <issue>`.
- `--issues` missing or value has no valid issue numbers.
- Any issue in the list is inaccessible — the script validates all issues up front and aborts the entire call before applying any side-effects (avoids half-linked state).

## What this command does NOT do

- Does not create or switch branches — operates on whatever branch you're on.
- Does not unlink issues — git config for the branch is append-only here. To unlink, edit `.git/config` manually (`[branch "<name>"]` → remove the number from `gitflow-issues`) or let the branch die on merge (config gets cleaned up).
- Does not push or commit — it's a metadata-only command.

## Side-effect summary

When `/link #27` fires:

1. **Git config write** (local only): `branch.<current>.gitflow-issues` gains `27`. Survives branch switch; wiped on branch delete.
2. **Project status** (best-effort): issue #27 moves to In Progress on the configured project board. Skipped silently if the issue isn't on the project or if the current `gh` auth lacks project-write scope.
3. **Issue assignment** (best-effort): issue #27 gets the current user added to assignees. Idempotent.
4. **Issue context dump** (stdout): body + comments so Claude reads them as part of this turn.

Downstream: `/open-pr` reads `branch.<current>.gitflow-issues` and prepends `Closes #27, #28, #29` to the PR body, which fires GitHub's native auto-close on merge. No further action needed.

## Related

- `/work <issue#>` — start a new branch linked to the issue (same link side-effects, plus branch creation when on `main`).
- Project's built-in "Pull request merge - closes linked issues" workflow also fires on merge via the Development-panel link, giving belt-and-suspenders closure.
