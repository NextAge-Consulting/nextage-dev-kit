# /sync-dev-kit

Interactive three-way sync of kit templates into this consumer project. Nothing is ever full-replaced — every difference is shown as a diff, you recommend a resolution, the user decides per file. Resumable via the `.claude/.kit-sync.json` lockfile.

$ARGUMENTS

## When to invoke

User says "sync dev kit", "sync the kit", "pull latest kit updates", or types `/sync-dev-kit` explicitly.

**Never invoke proactively.** User must explicitly request the sync.

## Procedure

### Step 1: Scan

Run the scan mode of the sync script:

```bash
~/.claude/scripts/sync-dev-kit.sh --scan
```

(If the project has not been synced before, the script is read from the kit location — confirm the config file at `~/.claude/dev-kit-config.json` exists, else instruct the user to follow the install-kit handbook steps.)

Parse the JSON output. Top-level fields:

- `kit_clean` — `false` means the kit repo has uncommitted changes. Warn the user; suggest they commit kit work before syncing (otherwise the baseline they establish now will drift).
- `kit_behind_remote` — `true` means the kit repo is behind its remote. Warn the user to `git pull` the kit before syncing.
- `kit_commit` — the kit HEAD SHA at scan time. This becomes the new lockfile baseline after `--finalize`.
- `files` — array of per-file state entries.
- `gitignore_additions_missing` — array of `.gitignore` lines the kit wants present in the project that are not yet.

The scan also bootstraps `.claude/sync-substitutions.json` from the kit template if it doesn't exist. Look for `sync-dev-kit.sh: bootstrapped .claude/sync-substitutions.json` on stderr — that's the signal that this is a first-time sync and Step 1.5 is going to have work to do.

### Step 1.5: Substitutions walkthrough

**Purpose:** populate `.claude/sync-substitutions.json` BEFORE the file-diff loop. Kit `{{KEY}}` placeholders get resolved against this file during scan, so populating values now eliminates false-positive diffs on every file that gates on a key.

**Read three things:**

1. The consumer's substitutions file:
   ```bash
   .claude/sync-substitutions.json
   ```
2. The kit's authoritative key catalog:
   ```bash
   <kit_path>/_claude-project/sync-substitutions.json
   ```
   The `_placeholders_referenced_by_kit` block has per-key descriptions and (for discoverable values) the `gh api graphql ...` command to fetch them.
3. The consumer's `_intentionally_empty` array (top-level, may not exist yet):
   ```bash
   jq '._intentionally_empty // []' .claude/sync-substitutions.json
   ```

**Identify empty keys to walk through:**

```bash
jq -r 'to_entries[] | select(.key | startswith("_") | not) | select(.value == "") | .key' .claude/sync-substitutions.json
```

Filter out any key that's in `_intentionally_empty` — the user already decided to leave those off. The remainder is the walkthrough list.

If the list is empty, skip Step 1.5 entirely and proceed to Step 2.

**Per-key flow** (one at a time, sequentially — don't batch):

1. Load the description from the kit catalog's `_placeholders_referenced_by_kit[<KEY>]`.
2. Show: `<KEY> — <description>`.
3. **If the description contains a `gh api graphql` command** (typical: `GITFLOW_*`):
   - Offer: "Run discovery for this key? [y/n/skip/disable]"
   - On `y`: extract the command from the description (it's quoted with `gh api graphql -f query='...'`), run it via Bash, parse the JSON output. Show candidate values (e.g. project list with IDs and titles). Ask user to pick one or paste a value directly. Confirm.
   - On `n`: ask user to paste the value directly.
4. **If no discovery command is present** (typical: `OWNER_REPO`, `ORG`, `RELEASE_BOT_APP`):
   - Show the description's example/format hint and ask the user directly: "Value for <KEY>?"
   - **If the description contains a `Suggested default:` line with an embedded shell command** (typical: `PROJECT_ABBREV`):
     - Extract the command (it appears between backticks after `Suggested default:`).
     - Run it via `Bash` from the consumer's project root (the cwd where `/sync-dev-kit` was invoked, since this command refuses from worktrees per §9.4.1).
     - Show the computed default value to the user and offer it as the prefill: "Suggested default: `<value>`. Accept with enter, or provide your own (e.g. a shorter abbrev)."
     - On accept-with-enter → write the suggested value. On user-provided value → write that. On "disable" / "skip" → fall through to the standard resolutions below.
5. **Resolutions:**
   - User provides a value → write it: `jq --arg k "<KEY>" --arg v "<VALUE>" '.[$k] = $v' .claude/sync-substitutions.json > /tmp/subs.json && mv /tmp/subs.json .claude/sync-substitutions.json`
   - User says "disable" / "leave empty" / "I don't use this feature" → add to `_intentionally_empty`: `jq --arg k "<KEY>" '._intentionally_empty = ((._intentionally_empty // []) + [$k] | unique)' .claude/sync-substitutions.json > /tmp/subs.json && mv /tmp/subs.json .claude/sync-substitutions.json`. Surface that this suppresses the prompt on future syncs.
   - User says "skip" / "later" / "defer" → leave the key empty AND not in `_intentionally_empty`. Walkthrough re-prompts on next sync.

**After the walkthrough:**

- Re-run `--scan` if any values were populated. Kit `{{KEY}}` SHAs now substitute against the new values, so files that were going to surface as `kit-only` (because their kit template had `{{KEY}}` and the project file had the literal `{{KEY}}` from a prior pre-bootstrap sync) may now reconcile to `clean` or `clean-converged`. Without re-scan, the file loop runs against stale state.
- If the user populated nothing (all empty/disable/defer), no re-scan needed.

**Edge cases:**

- Discovery command fails (insufficient `gh` scope, network down, project doesn't exist): surface the failure, ask user to either provide the value directly or defer.
- User provides a value that has shell-special characters (`&`, `\`, `/`, etc.): the substitution engine handles escaping (see `apply_substitutions` in the script). Don't pre-escape.
- `_intentionally_empty` already contains the key but user wants to populate now: remove from the list AND set the value in the same `jq` pass.

### Step 1.6: postCreate auto-suggest

After the substitutions walkthrough (§1.5) and BEFORE the per-file diff loop, check whether the consumer's `.claude/settings.json` has an empty `worktree.postCreate` array. If so, detect the consumer's package manager from lockfiles in the project root and offer a suggested default.

**Read current value:**

```bash
jq '.worktree.postCreate // []' .claude/settings.json
```

**Skip the prompt entirely if any of:**

- The array is non-empty (user already configured it).
- The settings file is missing or malformed.
- The project has no `package.json`, `Gemfile`, `pyproject.toml`, or `requirements.txt` at root (not a typical worktree-install scenario).

**Detection (first match wins, highest specificity first):**

| Lockfile / marker at project root | Suggested command |
|---|---|
| `pnpm-lock.yaml` | `pnpm install` |
| `yarn.lock` | `yarn` |
| `bun.lockb` | `bun install` |
| `package-lock.json` | `npm ci` |
| `package.json` with no lockfile | `npm install` (bootstrap — no lockfile to install from yet) |
| `Gemfile.lock` OR `Gemfile` | `bundle install` |
| `uv.lock` | `uv sync` |
| `poetry.lock` | `poetry install` |
| `requirements.txt` (without uv.lock or poetry.lock) | `pip install -r requirements.txt` |

**Prompt the user:**

> "`worktree.postCreate` is empty. Detected `<lockfile>` → suggest running `<command>` after each `/work` creates a new worktree. This ensures each worktree gets its own real `node_modules` (or equivalent) — required for vite/TanStack Start compatibility, see HANDBOOK §3 / TanStack Router #6588. Accept (`[command]`), provide your own command, or skip (leave empty)?"

**Resolutions:**

- User accepts → write the suggestion: `jq --arg c "<command>" '.worktree.postCreate = [$c]' .claude/settings.json > /tmp/settings.json && mv /tmp/settings.json .claude/settings.json`. Inform that the next `/work` will run this command in the new worktree dir.
- User provides their own command → same write, with their value.
- User wants multiple commands → accept comma-separated input, parse to array, write.
- User says "skip" / "later" / "I'll handle it manually" → leave empty; the walkthrough re-prompts on next sync. No `_intentionally_empty` equivalent for settings keys — keep it simple, re-prompt is cheap.

**Edge cases:**

- Multiple package managers detected (e.g., `package-lock.json` AND `Gemfile`): use the table's specificity order, surface the secondary one in the prompt as a note ("also detected Gemfile — add `bundle install` separately if needed").
- Consumer overrides via custom (non-table) command: write verbatim; no validation. Trust the user.
- The walkthrough does NOT auto-run the postCreate command — that fires on the next `/work` invocation via `work.sh:run_post_create()`.

### Step 2: Interpret states

For each file entry, the `state` field is one of:

| State | Meaning | Recommendation |
|-------|---------|----------------|
| `clean` | Kit and project both match baseline | Silent skip — do not list |
| `clean-first` | First-ever sync; project and kit already match | Silent skip — establish baseline only |
| `clean-converged` | Both changed from baseline to the same content | Silent skip — establish new baseline |
| `kit-only` | Kit changed, project did not | Recommend apply |
| `project-only` | Project changed, kit did not | Inform user of project customization; do NOT apply. If the change is kit-shared, make it in the kit and re-sync |
| `conflict` | Both changed to different content from baseline | Three-way diff; compare `kit_sha`, `project_sha`, `baseline_sha`; recommend merge or pick |
| `conflict-first` | First-ever sync; project and kit differ | Show both, ask user which direction |
| `new-kit` | Kit has a new file not in project | Recommend apply |
| `removed-kit` | Kit deleted a file that still exists in project | Ask: delete from project or keep as project-owned? |
| `project-deleted` | Baseline + kit still have file, but project deleted it | Ask: re-add from kit, or accept deletion? |
| `template-drift` | Template file; kit and project both changed | The project OWNS this file. Show the kit's delta as information, recommend nothing. Never reconcile toward the kit. |

### Step 2.05: file modes — `owned` vs `template`

Every entry also carries a `mode` field, declared kit-side by `mode_for_kit_path()` and copied into the consumer's lockfile on apply:

- **`owned`** (default, nearly everything) — the kit owns the content. `block-kit-edit.sh` denies consumer edits, and a two-sided divergence is a `conflict` to reconcile toward the kit.
- **`template`** — the kit ships a STARTING POINT; the project owns the file and has final say. The hook permits consumer edits, and a two-sided divergence reports as `template-drift` rather than `conflict`.

Only the two-sided-divergence state changes. `kit-only` still recommends apply (the project has not customized), and `project-only` is still a silent skip.

**Presenting a `template-drift` is a different conversation.** Do NOT recommend applying, and do NOT frame the project's content as something to reconcile. Show what the kit changed and let the user decide whether any of it is worth adopting; "keep ours" is a perfectly good answer that needs no justification. Applying is still available via `--apply-file`, but it overwrites a file the project owns — so it happens only on an explicit request, never on your recommendation.

**When the user keeps theirs, ACK it — this is not optional.**

```bash
~/.claude/scripts/sync-dev-kit.sh --ack-file <kit_path>
```

This records the kit's current content as the new baseline WITHOUT touching the project file, so the file reports `project-only` (a silent skip) from then on. Skip it and the baseline stays behind the kit, the identical drift re-reports on **every** subsequent sync forever, and the user learns to scroll past a signal that was supposed to mean something. Ack is not a permanent mute: the next time the kit changes that file, drift surfaces again — which is exactly the behaviour wanted.

Offer three outcomes on a template-drift, in this order: **keep ours** (ack), **take the kit's version** (`--apply-file`, overwrites), or **merge by hand** (the user edits, then ack). Never present it as a two-way apply/skip choice — "skip" without an ack is the option that quietly creates the recurring noise.

`--ack-file` deliberately accepts any file, so do NOT offer it for an `owned` file: acking one silences a real enforced update. The guard lives here in the walkthrough, where the user can see what they are choosing, not in the script.

The lockfile tolerates both schemas: a legacy bare-string value means `owned`. Entries are upgraded to `{sha, mode}` as each file is applied; there is no migration step.

### Step 2.1: settings.json reconciliation (silent, handled by the script)

`.claude/settings.json` uses 3-way comparison like every other file with ONE silent overlay: `worktree.postCreate`. The kit ships `postCreate: []` as the empty default; the consumer's populated value (typically set via §1.6 walkthrough) is operational config the kit must NEVER overwrite.

The reconciler lives in `sync-dev-kit.sh` (`overlay_settings_project_owned` + `sha256_settings_kit` + `sha256_settings_proj`). Behavior:

- Before scan-time SHA comparison, kit's settings.json content has the project's populated `worktree.postCreate` spliced in. Both kit and project SHAs are computed against jq-canonicalized JSON so whitespace / key-order differences don't surface either.
- Result: project has `postCreate: ["npm ci"]` + kit has `postCreate: []` + nothing else differs → state evaluates `clean` (or `clean-converged` first time after this logic ships) → silent skip. The file is NOT presented in Step 3.
- Result: any OTHER field differs (hooks, permissions, env, symlinkDirectories, symlinkPaths) → normal 3-way state still surfaces. Reconciler only suppresses the postCreate axis.
- Apply path (`--apply-file _claude-project/settings.json`) uses the same overlay so an accepted apply preserves the project's populated postCreate.
- Lockfile baseline SHA for settings.json tracks the canonicalized + overlaid content — matching subsequent scans.

You (Claude) don't need to invoke anything special — the script handles it. If you ever see settings.json show up as `kit-only` because the kit ships an empty postCreate default, that's a bug in the reconciler. See HANDBOOK §9.6 (policy) + §9.9 (the §1.6 walkthrough that populates the value).

### Step 3: Present each non-clean file

For each file whose state is not `clean*`, show:

- The destination path (`dest_path`)
- The state and one-line recommendation
- The diff — obtain with `git diff --no-index <baseline-or-project> <kit>` OR `diff -u` for clarity
- For conflicts, show BOTH diffs: `baseline → kit` and `baseline → project`

Example presentation:

```
.claude/hooks/git-guard.sh (kit-only)

Kit changed this file since your last sync; you haven't touched it.
Recommendation: apply kit changes.

--- baseline
+++ kit
@@ -12,3 +12,5 @@
 # ... diff content ...

Apply? [y/n/skip/quit]
```

Process files in batches of 5-10 at a time to avoid overwhelming the user. Let them stop anytime; lockfile preserves state per-file so they resume later.

### Step 4: Apply accepted changes

For each `y` response, invoke the script:

```bash
~/.claude/scripts/sync-dev-kit.sh --apply-file <kit_path>
```

The `kit_path` field comes from the file entry (e.g., `_claude-project/hooks/git-guard.sh`). The script copies the file to the correct destination and updates the lockfile's per-file SHA entry.

For `removed-kit` state accepted: the kit_path is empty in the report; the script detects kit file missing and removes from project + lockfile.

### Step 5: Handle .gitignore

If `gitignore_additions_missing` is non-empty:

- List missing entries
- Ask: "Add these to `.gitignore`?"
- On accept: `~/.claude/scripts/sync-dev-kit.sh --apply-gitignore`

### Step 6: Finalize

After all decisions processed, ALWAYS run:

```bash
~/.claude/scripts/sync-dev-kit.sh --finalize
```

`--finalize` does ONE thing: **stamps the lockfile** — sets `lastSyncedCommit` and `lastSyncedAt` (the per-file SHAs are already current because `--apply-file` updated them incrementally).

**Sync does NOT commit or push.** It applies kit updates to the working tree and stamps the lockfile — that's all. Committing is gitflow's job, not sync's. After `--finalize`, the synced `.claude/` files plus the lockfile bump are a normal uncommitted change in the working tree.

**Then tell the user to land it with `/ship-main`** — that's the natural fit (commits + pushes straight to `main` in one step). The user may also `/commit` it as a feature branch + PR if they prefer review; sync is agnostic. Do NOT auto-commit (per `git.md` — no git operation without explicit instruction); surface that the sync is applied and `/ship-main` will land it.

**Do NOT finalize if the user stopped intending to resume later** — the lockfile per-file SHAs are still current, and the next `--scan` will correctly identify what remains to review. Finalizing now would mark the current kit HEAD as the baseline even for files the user hasn't reviewed yet.

Finalize ONLY when:
- All non-clean files have been reviewed and decided (even if decision was "skip")
- OR the user explicitly says "finalize anyway" despite pending reviews

### Step 7: Report

Summarize:
- Files applied (count + list)
- Files skipped with state
- .gitignore entries added
- Lockfile kit commit SHA (before vs after)
- That the synced files are **uncommitted in the working tree** — and that `/ship-main` will land them (sync does not commit)

## Edge cases

- **Kit repo not clean**: report warn, proceed if user insists
- **Kit behind remote**: refuse to proceed; user must `git pull` in kit first (their baseline would diverge otherwise)
- **Running from inside the kit repo**: script refuses with exit code 4; surface message
- **Running from inside a worktree**: script refuses with exit code 4; sync must run from primary. Surface the primary path and tell user to `cd` there. See HANDBOOK §9 for the bootstrap-problem rationale.
- **Primary not on `main`**: script refuses with exit code 4. Sync runs only on `main` (the kit model keeps primary on a clean main). Tell the user to switch to `main` and re-run.
- **Any worktree open**: script refuses with exit code 4. Sync requires a clean slate — no open worktrees — regardless of whether a worktree touches kit files. A sibling worktree can be carrying kit files on a feature branch; syncing into main while that work is in flight double-applies and races the merge. Tell the user to merge or discard all worktrees first, then re-run.
- **Script missing (`~/.claude/dev-kit-config.json` not found)**: surface install-kit handbook steps

## What this command does NOT do

- Does not run from a worktree — must be invoked from primary repo root, on `main`, with no worktrees open.
- Does not push the kit itself — user handles kit repo separately.
- Does not edit files in the kit — purely a pull-from-kit operation. Kit-shared changes are made in the kit source and arrive here on the next sync.
- **Does not commit or push anything.** Sync applies kit updates to the working tree and stamps the lockfile; the user lands the result with `/ship-main` (or `/commit`). This keeps committing as gitflow's job and avoids the bootstrap problem of sync modifying the very commands that would commit it — sync now runs zero git operations.
