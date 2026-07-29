# /checkpoint

Fast WIP commit without deep analysis. Part of the gitflow subsystem. Use for mid-task save points. Checkpoints skip typecheck (speed over compliance — WIP commits are not shipped).

$ARGUMENTS

## Procedure

### Step 1: Invoke the script

Pass the user's optional message suffix (from `$ARGUMENTS`) as positional arguments. The script auto-formats as `🔖 wip: <timestamp> [- suffix]`.

```bash
.claude/skills/gitflow/scripts/checkpoint.sh [optional suffix text]
```

### Step 2: Report

- Checkpoint committed and pushed: report the timestamp
- Nothing to checkpoint: report
- Script exited non-zero: surface exit code and message

## What this command skips

- Typecheck — deliberate, checkpoints are WIP
- Changelog — WIP commits never appear in changelog
- Version bump — only main branch merges trigger bumps

## Branch behavior

If currently on `main` or `master`, the script auto-creates a `wip/<timestamp>` branch before committing. A later `/commit` on that branch renames it based on the real commit message.

If already on any other branch, the checkpoint happens in place.

## Blocking conditions

- Nothing staged (empty diff)
- `git push` failure
