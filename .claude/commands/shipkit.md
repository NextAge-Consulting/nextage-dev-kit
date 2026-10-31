# /shipkit

Release the kit: gate everything outstanding, commit it, open the PR with the release notes, merge it, then version, tag and publish the release that every project's `/sync-dev-kit` takes. This is the only way anything reaches the kit's `main`.

$ARGUMENTS

**Run it only when the human types `/shipkit`.** That one instruction authorizes every git operation below, for this release and no other.

## Step 1: Plan the release

```bash
.claude/scripts/shipkit.sh --plan
```

It prints the `version`, the `base` the release is measured from, the `title`, the `migrations` it adds with each one's Kind, every migration in `missing_estimate`, and every `consumer_name_hits` line.

- **`missing_estimate` not empty:** stop. Write each one's Estimate (`.claude/rules/project/migrations.md`), test its commands against a real project, and run `/shipkit` again.
- **`consumer_name_hits`:** the kit is public. Read each hit. A real name of a project, client or person is rewritten generically before anything is committed (`kit-maintainer.md`, "THE KIT IS PUBLIC"); a common word that happens to match is left. Then run the plan again.

## Step 1a: Bring the actions up to date

```bash
.claude/scripts/bump-action-pins.sh
```

It moves every action the kit's workflows pin to the newest release in its major that is at least seven days old, and names each newer major it left. For each one named:

1. Read the release notes of every major up to it (`gh api repos/<owner>/<repo>/releases`) against the `with:` inputs and outputs the kit's workflows use for that action.
2. Change the workflows where the notes require it; often nothing needs changing.
3. Take it: `.claude/scripts/bump-action-pins.sh --major <action>`.

A non-zero exit from either run wrote nothing: relay its message and stop the release.

## Step 2: Write the release notes

Write them to a scratch file outside the repository. They are what a project's kit syncer reads to decide when to sync, so write for someone who knows the kit only as a user:

```markdown
## What changed

- <one line per change a project will notice, grouped by area, in plain words>

## Migrations

### <migration name> — <its Kind>

<What it changes in a project, in a sentence or two. Its `Your time` line. How much of a
project it touches.>
```

Read every commit since `base` (`git log <base>..HEAD`) and the outgoing diff to write "What changed". Leave out what only the kit's own maintenance sees. With no migrations, the Migrations section says "None — this release can be synced any time." Nothing in the notes names a project, client, person or deployment.

## Step 3: Commit, open the PR, triage, merge

Carry out each command's own procedure, in order:

1. **`/commit`**, with a conventional message summing up the release. It cuts the branch from `main` and runs every gate, the kit's pre-ship gate included.
2. **`/open-pr`**, with the plan's `title` as the title and the notes as the body.
3. **Triage Gemini's review yourself**, below.
4. **`/merge`**, which lands this checkout back on `main`.

A gate that fails stops the release there. Fix it and continue from that command.

### Triage Gemini's review yourself

Run `.claude/skills/gitflow/scripts/wait-for-pr-ready.sh --pr <N>`, with the PR `/open-pr` opened.

- **Exit 0, its ready line showing no findings** — no `findings=`, or `findings=0`: go to `/merge`.
- **Exit 2, CI failed:** fix it in the tree, uncommitted. When the wait says the review is still due, run it again with `--review-only`, then go on from its result; the one `/commit --no-review` below carries the CI fix with the findings' fixes. When no review is due, `/commit --no-review` the fix and wait again.
- **Exit 3, timed out:** ask the human whether to release without Gemini's review.
- **Any other exit:** relay its message and stop.
- **Exit 0 with `findings=` above zero, or `findings=error`:** fetch and work them by `/triage`'s Step 2 and its Step 4 Hard Rules, but make every fix-or-skip call yourself, without the one-at-a-time walk-through. Then `/commit --no-review` once with every fix and carve-out comment.

**Put a finding to the human only when the call is theirs:** the fix changes what projects experience beyond correcting a defect, reverses a decision the kit's docs record, or rests on a preference nothing in the kit settles. Decide the rest first, then ask about these together, each with its options and your recommendation.

## Step 4: Release

```bash
.claude/scripts/shipkit.sh --release --version <version> --base <base> --notes-file <notes>
```

With `version` and `base` from Step 1. It commits `VERSION`, pushes `main`, tags the version and creates the GitHub release with the notes. On a non-zero exit, relay its message: each code says exactly what is already pushed and what to run next.

## Step 5: Report

The release's title and URL, the migrations it carries, each with its Kind, and Gemini's findings, each fixed or declined with its reason.
