---
description: Release the Design Packs repository — check it for anything private, prove every piece, then commit, push and tag the version projects install
argument-hint: "<the project the pieces were cut from>"
---

# /shippack

Release the Design Packs repository: everything in its checkout becomes one tagged version, the one `/design-pack install` takes and an installed file records.

$ARGUMENTS

**Run it only when the human types `/shippack`.** That one instruction authorizes the commit, the push and the tag below, for this release and no other. The packs repository is public.

## Step 1: Plan the release

```bash
.claude/scripts/shippack.sh --plan
```

It prints the `packs` checkout, the `version`, `files_changed` since the last release, the pieces `to_prove`, the `coverage` of its reference pages, and every `private_hits` line.

- **`files_changed` is 0:** say there is nothing to release, and stop.
- **`behind_origin` is true, or `branch` is not `main`:** say which, and stop.
- **`private_hits`:** read every one. Take a project's, client's or person's name, a real email address, an account, a host or a key out of the piece's folder; leave a word that only happens to match. Run the plan again until every hit left is one you have read.

## Step 2: Prove what changed

Skip this step when `to_prove` is empty.

```bash
.claude/scripts/shippack.sh --prove --source <the project the pieces were cut from>
```

The project is the argument above; ask the human which one when they gave none. It proves each piece in `to_prove` — one that changed since its proof, or is built on one that did — and records the proof.

**A piece that does not prove stops the release.** Fix what it names in that piece's folder (the `design-packs` skill, "Extract") and prove again.

## Step 3: Say what the release holds

Tell the human, in a few lines: the version, how many files and pieces, which pieces were proved now, the coverage line, and what you took out in Step 1. Then go on to Step 4.

## Step 4: Release

```bash
.claude/scripts/shippack.sh --release --version <version>
```

With `version` from Step 1. On a non-zero exit, relay its message: each code says what is already pushed and what to run next.

## Step 5: Report

The version, the commit, how many pieces it holds, and the coverage line.
