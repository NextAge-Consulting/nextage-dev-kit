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

(If the project has not been synced before, the script is read from the kit location — confirm the config file at `~/.claude/dev-kit-config.json` exists, else point the user at `kitmaintainer-handbook.md` §0.1.)

Parse the JSON output. Top-level fields:

- `kit_clean` — `false` means the kit repo has uncommitted changes. Warn the user; suggest they commit kit work before syncing (otherwise the baseline they establish now will drift).
- `kit_behind_remote` — `true` means the kit repo is behind its remote. Warn the user to `git pull` the kit before syncing.
- `kit_commit` — the kit HEAD SHA at scan time. This becomes the new lockfile baseline after `--finalize`.
- `files` — array of per-file state entries.
- `gitignore_additions_missing` — array of `.gitignore` lines the kit wants present in the project that are not yet.
- `unmapped_templates` — kit files under `_claude-project/templates/` with no destination mapping. Non-empty is a kit defect: tell the user the kit is missing a `dest_for_kit_path` entry for each.
- `skipped_unconfigured` — `{kit_path, key}` for each kit file skipped because its destination key (`SHARED_MODULE_DIR`, `DESIGN_UI_PACKAGE`) is empty. List them once, so the user knows what an empty key costs.
- `stale_patches` — patch register entries that sanction nothing, each with the file's `current_state` (Step 2.2).

The scan also bootstraps `.claude/sync-substitutions.json` from the kit template if it doesn't exist. Look for `sync-dev-kit.sh: bootstrapped .claude/sync-substitutions.json` on stderr — that's the signal that this is a first-time sync and Step 1.5 is going to have work to do.

### Step 1.5: Substitutions walkthrough

**Purpose:** populate `.claude/sync-substitutions.json` BEFORE the file-diff loop. Kit `{{KEY}}` placeholders get resolved against this file during scan, so populating values now eliminates false-positive diffs on every file that gates on a key.

**Read these:**

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
4. **If no discovery command is present**:
   - Show the description's example/format hint and ask the user directly: "Value for <KEY>?"
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

### Step 2: Interpret states

For each file entry, the `state` field is one of:

| State | Meaning | Recommendation |
|-------|---------|----------------|
| `clean` | Kit and project both match baseline | Silent skip — do not list |
| `clean-first` | First-ever sync; project and kit already match | Silent skip — establish baseline only |
| `clean-converged` | Both changed from baseline to the same content | Silent skip — establish new baseline |
| `kit-only` | Kit changed, project did not | Recommend apply |
| `patched` | `owned` or `merge` file: the project changed kit-owned text, and `.claude/.kit-patches.json` sanctions it | Report every sync with both issues and the `patch.recommendation` (Step 2.2) |
| `unsanctioned` | `owned` or `merge` file: the project changed kit-owned text with no register entry | Report loudly every sync. Recommend reverting to the kit (`--apply-file`) or registering it as a patch (Step 2.2) |
| `conflict` | `owned` file, no register entry: both changed to different content from baseline | Three-way diff; compare `kit_sha`, `project_sha`, `baseline_sha`; recommend taking the kit's version. A project change that must stay is a patch: register it, then ACK (Step 2.2) |
| `conflict-first` | First-ever sync; project and kit differ | Show both, ask user which direction |
| `new-kit` | Kit has a new file not in project | Recommend apply. If the user does not want it, **decline it** (below) — never leave it unanswered |
| `declined` | The project refused this file at its current content | Silent skip — do not list |
| `removed-kit` | Kit deleted a file that still exists in project | Ask: delete from project or keep as project-owned? |
| `project-deleted` | Baseline + kit still have file, but project deleted it | Ask: re-add from kit, or accept deletion? |
| `template-kept` | A `template` seed the project already has, adapted, or deleted, which the kit has since changed | Silent skip — do not list. A seed is the project's from the moment it lands |
| `merge-unmarked` | `merge` file whose project copy has no region markers | Never apply — it would discard the project's content. Move the project's content into the kit's regions by hand (Step 2.3), then re-scan |
| `merge-invalid` | `merge` file whose project markers are malformed, or that has a region the kit lacks | Show `detail`. Fix the markers or move the orphan region's content into a kit region, then re-scan. Apply refuses until then |

### Step 2.05: file modes — `owned`, `merge`, `template`

Every entry also carries a `mode` field, declared kit-side by `mode_for_kit_path()` and copied into the consumer's lockfile on apply:

- **`owned`** (default, nearly everything) — the kit owns the content. `block-kit-edit.sh` denies consumer edits. A project edit is `patched` or `unsanctioned`, never a silent skip; a two-sided divergence with no register entry is a `conflict` to reconcile toward the kit.
- **`merge`** — owned, except inside the file's named project regions. Sync writes the kit's text around the project's region bodies, so `kit-only` is always safe to apply and a region edit is never a conflict. An edit outside the regions is `patched` or `unsanctioned`.
- **`template`** — a SEED: the project's own content from the start. It is offered once, as `new-kit`, to a project that has never had it. Once the project has it — untouched, adapted or deleted — or declined it, a kit change never offers it again (`template-kept`, `declined`). The hook permits consumer edits.

**Acking an `owned` file — the test is whether the kit's current content has been INCORPORATED.** `--ack-file` accepts any file: it advances the baseline to what the kit ships today and leaves the project file untouched.

- **Forbidden — ack INSTEAD of applying.** The project never took the kit's change, and the ack hides it.
- **Right — ack AFTER hand-merging the kit's change into a registered patch** (`patch.recommendation` `merge-kit-keep-patch`). The kit's change is in the file and the register sanctions what still differs, so the file reports `patched` with `kit_changed: false` until the kit moves again.

An ack never sanctions an edit. An `owned` file that still differs from the kit after an ack is `unsanctioned` unless the register lists it.

The lockfile tolerates both schemas: a legacy bare-string value means `owned`. Entries are upgraded to `{sha, mode}` as each file is applied; there is no migration step.

### Step 2.1: settings.json canonicalization (silent, handled by the script)

`.claude/settings.json` uses 3-way comparison like every other file, with one wrinkle: both sides are compared as jq-canonicalized JSON rather than raw bytes, so a reordered key or reindented block does not surface as a diff on content that is semantically identical.

The helpers live in `sync-dev-kit.sh` (`canonicalize_settings` + `sha256_settings_kit` + `sha256_settings_proj`). Every field — hooks, permissions, env — flows through normal 3-way state; the kit owns them all. The lockfile baseline SHA tracks the canonicalized content, matching subsequent scans.

You (Claude) don't need to invoke anything special — the script handles it. See kitmaintainer-handbook.md §9.6.

### Step 2.2: patches — `patched`, `unsanctioned`, stale entries

`.claude/.kit-patches.json` is the project's register of sanctioned edits to kit-owned text: `{"patches":[{"path","kitIssue","projectIssue","reason"}]}`, keyed by destination path. Sync reads it and never writes it, except through `--remove-patch`.

Present every `patched` entry, every sync, with its `reason`, both issues and their states (`kit_issue_state`, `project_issue_state`; `unknown` means `gh` could not answer — say so). Then follow `patch.recommendation`:

| Recommendation | Means | Offer |
|---|---|---|
| `keep` | The kit has not moved; the kit issue is still open | Nothing to do — the patch stands |
| `merge-kit-keep-patch` | The kit changed the file, but its issue is still open | Hand-merge the kit's change into the patched file, then `--ack-file` |
| `take-kit` | The kit changed the file and its issue is closed | Take the kit's version (`--apply-file`), then remove the entry and close the project issue |
| `kit-issue-closed-file-unchanged` | The kit issue closed without changing this file | Ask whether the fix landed elsewhere or was declined; the patch stays until the user decides |

Present every `unsanctioned` file loudly, every sync, with its diff against the kit. Offer: **revert to the kit** (`--apply-file`; on a `merge` file this keeps the regions), or **register it as a patch** — file a kit issue and a project issue, then add the entry. Never leave it unanswered.

For each `stale_patches` entry, and after a `take-kit` apply:

```bash
~/.claude/scripts/sync-dev-kit.sh --remove-patch <dest_path>
gh issue close <projectIssue number> --comment "Kit fix landed via /sync-dev-kit; the temporary patch is removed."
```

`--remove-patch` prints the removed entry, which names the project issue to close. Close it only once the user agrees.

### Step 2.3: `merge` files — regions

A `merge` file marks each project region in its own comment syntax: `<!-- project:begin <name> -->` … `<!-- project:end <name> -->` in Markdown, `# project:begin <name>` … `# project:end <name>` in YAML and `.gitattributes`. Names are unique per file and regions do not nest.

**`merge-unmarked`** — the project's copy predates the regions. Show the user the kit file and the project file side by side, move each piece of project content into the kit region that matches it, take the kit's text everywhere else, and re-scan. Content that fits no region is either kit-shared (raise a kit issue) or a patch (register it) — never invent a region the kit does not have.

**`merge-invalid`** — read `detail`: an unclosed or nested region, a duplicate name, or a region the kit does not have. Fix it by hand and re-scan.

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

### Step 3.5: A `new-kit` the user does not want

```bash
~/.claude/scripts/sync-dev-kit.sh --decline-file <kit_path>
```

Records the kit's current content as a refusal WITHOUT creating the project file, so the entry reports `declined` and stops being listed.

**"Skip" is not an answer here.** A skipped `new-kit` has no lockfile entry at all, so it is offered again on the next sync, and every sync after that — the user ends up declining the same two files forever and learns to scroll past the list. Offer: **take it** (`--apply-file`), **decline it** (`--decline-file`), or **decide later** (genuinely skip, and say it will be asked again).

**Do NOT use `--ack-file` for this.** Ack records a baseline for a file that does not exist locally, so the next scan reports `project-deleted` — one recurring nag traded for another. The script refuses `--decline-file` on a file the project HAS, for the mirror-image reason; that case is `--ack-file`.

Declining is per kit VERSION. When the kit changes that file it is offered again, because refusing one version is not refusing everything the file might later become. Undo is just `--apply-file` — applying overwrites the entry and the refusal disappears with it.

### Step 4: Apply accepted changes

For each `y` response, invoke the script:

```bash
~/.claude/scripts/sync-dev-kit.sh --apply-file <kit_path>
```

The `kit_path` field comes from the file entry (e.g., `_claude-project/hooks/git-guard.sh`). The script copies the file to the correct destination and updates the lockfile's per-file SHA entry.

On a `merge` file the script writes the kit's text around the project's region bodies, so applying never costs the project its regions. It refuses (exit 4) on `merge-unmarked` and `merge-invalid`.

For `removed-kit` state accepted, pass the entry's **`dest_path`** instead. The kit file is gone, so `kit_path` is empty in the report and there is nothing else to name it by:

```bash
~/.claude/scripts/sync-dev-kit.sh --apply-file <dest_path>
```

The script confirms nothing in the kit still maps to that destination, then deletes the file from the project and drops its lockfile entry. If the kit DOES still supply it, the call fails and names the kit path to use — which means the entry was not `removed-kit` and you misread the report.

Do NOT try to reconstruct the kit path yourself. The kit→destination map is not invertible: `templates/` sends several kit paths to root-level and `SHARED_MODULE_DIR` destinations, so a guessed kit path either exits 4 or names the wrong file.

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
- **Mid-feature sync**: expected and supported. Sync runs on whatever branch you are on, so a rule fixed mid-session is live in context for the rest of it. The applied changes ride the same commit as the rest of the body of work, which is the house model (rules/git.md), not something to avoid.
- **Script missing (`~/.claude/dev-kit-config.json` not found)**: point at `kitmaintainer-handbook.md` §0.1

## What this command does NOT do

- **Does not change the project's code.** A check the sync just landed may fail on code
  that predates it — a new lint plugin, a stricter tier rule, a new gate. List each such
  failure in the Step 7 report and stop: fixing it is the project work the maintainer
  starts next (a kit migration prompt, or the next task), in this same project, under
  §XII. The sync's body of work ends at `--finalize`.
- Does not push the kit itself — user handles kit repo separately.
- Does not edit files in the kit — purely a pull-from-kit operation. Kit-shared changes are made in the kit source and arrive here on the next sync.
- **Does not commit or push anything.** Sync applies kit updates to the working tree and stamps the lockfile; the user lands the result with `/ship-main` (or `/commit`). This keeps committing as gitflow's job and avoids the bootstrap problem of sync modifying the very commands that would commit it — sync now runs zero git operations.
