# /sync-dev-kit

Bring this project up to the dev kit's latest release. It first briefs the user on what the release will ask of them and of the project, and changes nothing until they say go.

$ARGUMENTS

**Run it only when the user asks for a sync by name.**

## Step 1: Prepare the kit clone

```bash
.claude/scripts/sync-dev-kit.sh --prepare
```

It brings this machine's kit clone to the kit's latest main and prints JSON naming the `procedure` to follow. On a non-zero exit, relay its message and stop — nothing in the project has changed.

## Step 2: Follow the kit's procedure

Read the file at `procedure` in full, then carry it out from the top. Every engine call it makes goes through `.claude/scripts/sync-dev-kit.sh <mode>`, which runs the kit clone's engine.
