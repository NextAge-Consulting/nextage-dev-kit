# The /sync-dev-kit procedure

A three-way sync of the kit into this project. Before anything changes, the user is told what this sync will ask of them and of the project, and says go or not. The kit-owned files then land in one mechanical pass, and only what needs a person is put to them, one item at a time. Nothing is ever full-replaced, and the `.claude/.kit-sync.json` lockfile makes it resumable.

The project's `/sync-dev-kit` has already run `.claude/scripts/sync-dev-kit.sh --prepare`, which brought this kit clone to the kit's latest main — or, on a maintainer's machine, left the working tree as it stands — and named this file. Every engine call below goes through `.claude/scripts/sync-dev-kit.sh`.

## Procedure

### Step 1: Scan

Run the scan. It writes nothing, so the go-ahead in Step 1.2 is decided on a project nothing has touched:

```bash
.claude/scripts/sync-dev-kit.sh --scan
```

Parse the JSON output. A syncer's clone is always clean and current here, because `--prepare` refuses otherwise; `kit_clean`, `kit_behind_remote` and `migrations_uncommitted` matter on a maintainer's machine. Top-level fields:

- `kit_clean` — `false` means the kit repo has uncommitted changes. Warn the user that this sync takes the kit's uncommitted files and migrations, as a test of them before they ship.
- `migrations_uncommitted` — migrations in the kit's working tree that its HEAD does not hold. Only a maintainer's machine has any: there, each one this project has not run yet is in `migrations_pending`, after the committed ones, in name order, so a kit change is tested with its migration before it ships. A syncer's clone is a clean release, so the list is empty; were it not, those migrations would not run, so name each one and say so in the briefing.
- `kit_behind_remote` — `true` means the kit repo is behind its remote. Warn the user to `git pull` the kit before syncing.
- `kit_commit` — the kit HEAD SHA at scan time. This becomes the new lockfile baseline after `--finalize`.
- `files` — array of per-file state entries.
- `gitignore_additions_missing` — array of `.gitignore` lines the kit wants present in the project that are not yet.
- `unmapped_templates` — kit files under `_claude-project/templates/` with no destination mapping. Non-empty is a kit defect: tell the user the kit is missing a `dest_for_kit_path` entry for each.
- `skipped_unconfigured` — `{kit_path, key}` for each kit file skipped because the setting its destination depends on (`SHARED_MODULE_DIR`, `DB_ENGINE`, `DESIGN_UI_PACKAGE`, `DESIGN_FEED_BARREL`, `TEST_RUNNER`) is empty or rules it out. List them once, so the user knows what the setting costs.
- `repo_kind` and `skipped_by_repo_kind` — the project's `REPO_KIND` and how many application-tooling files it skipped as an `org` repo. Say the count once; never list the files.
- `stale_patches` — patch register entries that sanction nothing, each with the file's `current_state` (Step 2.2).
- `migrations_pending` — `{name, prompt}` for each migration the kit added since this project last synced, oldest first, after any an earlier sync carried forward, and then, on a maintainer's machine, each uncommitted one not yet run here (Step 5.5). `prompt` is the file in the kit's working tree.
- `substitutions_bootstrap` — `true` on the project's first sync: `.claude/sync-substitutions.json` does not exist yet, and the scan read the kit template's values in its place.
- `substitutions_new_keys` — kit keys the project's file lacks. Step 1.5 writes them in.
- `substitutions_undecided` — the keys the Step 1.5 walkthrough will ask about.

### Step 1.2: Brief the user, then ask for the go-ahead

Before anything is written, tell the user what this sync asks of them and of the project. Assume they know little about the kit's files: give them decisions and consequences, never a tour of the files.

1. **What changes mechanically.** One line: how many kit-owned files it updates or adds (`kit-only` and `new-kit`, merge files included, whose project regions are always kept), and that none of them needs a decision. Name a file only when it would break something in this project (Step 2.04).
2. **Files that need a person** — every `patched`, `unsanctioned`, `conflict`, `conflict-first`, `merge-unmarked`, `merge-invalid`, `removed-kit` and `project-deleted` file, and each of `stale_patches`. One line each: what the choice is, and what you will recommend.
3. **Settings to decide** — each of `substitutions_undecided`, in plain words from the kit catalog (`<kit_path>/_claude-project/sync-substitutions.json`, `_placeholders_referenced_by_kit`), and whether a sensible default exists. With `substitutions_bootstrap` true, say this is the project's first sync, so every setting is asked once.
4. **Each migration** in `migrations_pending`, in order: its estimate (below). Say which are uncommitted — the kit has not shipped them yet.
5. **The total.** The user's interactive time across all of it, and the verdict: nothing needing a person means the sync runs straight through; anything else, say how long they will sit with it.

Then ask once whether to go ahead. On no, stop: nothing in the project has changed, and the next sync briefs again.

#### Estimating a migration

A migration is a prompt that adjusts the project to kit changes this sync has not applied yet, so it cannot be dry-run. Its estimate is not a rundown of its steps; it is the blast radius, measured against this project.

- **A migration with an `## Estimate` section** above its `---`: run each command its `Blast radius` line gives — they are read-only, and read new kit content from the clone — and read the counts through its `Kind` and `Your time` lines.
- **One without:** read its opening paragraph and every step, decide from them what it touches and where it stops for the user, and measure that with read-only commands of your own — count the files, components or call sites the steps would change. Call the result a cold estimate.
- Run nothing a step runs to make its change: no codemod outside `--dry-run`, no install, no write, no commit. A count that exists only once an earlier migration has run is reported as that, never guessed.
- **Across a backlog,** measure every migration against the project as it stands. One migration changing what the next one counts does not change the order of magnitude, and order of magnitude is what the estimate is for. A migration whose opening paragraph says it does not apply here gets one line saying why.

Report each migration as:

- **Kind** — mechanical, or asks for decisions, naming them;
- **Your time** — minutes the user spends in this session deciding: the number of decision points times a realistic time for each. A mechanical migration is "none — runs unattended", however much code it changes. Never estimate how long Claude's unattended work takes, and never in days or weeks;
- **Reach** — how much of the project it changes, as a share of the whole: "about 40 of 260 source files, all in the component folder", or "two config files";
- **What it proves at the end** — the checks, tests and builds its steps run.

### Step 1.5: Substitutions walkthrough

**Purpose:** populate `.claude/sync-substitutions.json` BEFORE the mechanical pass. Kit `{{KEY}}` placeholders get resolved against this file during scan, so populating values now eliminates false-positive diffs on every file that gates on a key.

**First, write the file:** bootstrap it on a first sync, or merge in the kit's new keys and comment blocks:

```bash
.claude/scripts/sync-dev-kit.sh --apply-substitutions
```

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

If the list is empty, skip the rest of Step 1.5 and proceed to Step 2.

**Ask `REPO_KIND` first when it is in the list.** It decides which other keys matter. For an `org` repo, offer to settle the application keys in one step: `DB_ENGINE` = `None`, `GEMINI_NOT_INSTALLED` = `true` (an org repo is reviewed through its plans, not Gemini), `ORG_REPO` = this repository, and `SHARED_MODULE_DIR`, `DESIGN_UI_PACKAGE`, `KNIP_GATE`, `FORM_LIB_EXEMPT_APPS`, `DEPLOY_BACKEND`, `DEPLOY_WORKFLOWS`, `MIGRATE_WORKFLOW`, `MIGRATE_PATHS`, `CODEBUILD_PROJECT_PREFIX`, `CODEBUILD_MIGRATE_PROJECT`, `CODEBUILD_PROMOTE_PREFIX` and `TEST_RUNNER` added to `_intentionally_empty`. A `combo` repo — a project that is its own org repo — keeps its application settings and sets `ORG_REPO` to itself. Then re-run `--scan`, because the kind changes which files are scanned.

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

- Re-run `--scan` if any values were populated. Kit `{{KEY}}` SHAs now substitute against the new values, so files that were going to surface as `kit-only` (because their kit template had `{{KEY}}` and the project file had the literal `{{KEY}}` from a prior pre-bootstrap sync) may now reconcile to `clean` or `clean-converged`. Without re-scan, the mechanical pass runs against stale state.
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
| `kit-only` | Kit changed, project did not | Mechanical pass (Step 3) |
| `patched` | `owned` or `merge` file: the project changed kit-owned text, and `.claude/.kit-patches.json` sanctions it | Report every sync with both issues and the `patch.recommendation` (Step 2.2) |
| `unsanctioned` | `owned` or `merge` file: the project changed kit-owned text with no register entry | Report loudly every sync. Recommend reverting to the kit (`--apply-file`) or registering it as a patch (Step 2.2) |
| `conflict` | `owned` file, no register entry: both changed to different content from baseline | Three-way diff; compare `kit_sha`, `project_sha`, `baseline_sha`; recommend taking the kit's version. A project change that must stay is a patch: register it, then ACK (Step 2.2) |
| `conflict-first` | First-ever sync; project and kit differ | Show both, ask user which direction |
| `new-kit` | Kit has a new file not in project | Mechanical pass, whether or not this repo uses it (Step 2.04). One the briefing named as breaking something goes to the user instead: take it or **decline it** (Step 3.5) — never leave it unanswered |
| `declined` | The project refused this file at its current content | Silent skip — do not list |
| `removed-kit` | Kit deleted a file that still exists in project | Ask: delete from project or keep as project-owned? |
| `project-deleted` | Baseline + kit still have file, but project deleted it | Ask: re-add from kit, or accept deletion? |
| `template-kept` | A `template` seed the project already has, adapted, or deleted, which the kit has since changed | Silent skip — do not list. A seed is the project's from the moment it lands |
| `merge-unmarked` | `merge` file whose project copy has no region markers | Never apply — it would discard the project's content. Move the project's content into the kit's regions by hand (Step 2.3), then re-scan |
| `merge-invalid` | `merge` file whose project markers are malformed, or that has a region the kit lacks | Show `detail`. Fix the markers or move the orphan region's content into a kit region, then re-scan. Apply refuses until then |

### Step 2.04: Take the kit, whether or not this repo uses it

**Recommend applying every kit file and every `.gitignore` line, including those this repo has no use for** — JS tooling in a repo with no JavaScript, Terraform lines in a repo with no Terraform. Recommend declining only when the file would actively break something in this repo, and name what it breaks.

### Step 2.05: file modes — `owned`, `merge`, `template`

Every entry also carries a `mode` field, declared kit-side by `mode_for_kit_path()` and copied into the consumer's lockfile on apply:

- **`owned`** (default, nearly everything) — the kit owns the content. `block-kit-edit.sh` denies consumer edits. A project edit is `patched` or `unsanctioned`, never a silent skip; a two-sided divergence with no register entry is a `conflict` to reconcile toward the kit.
- **`merge`** — owned, except inside the file's named project regions. Sync writes the kit's text around the project's region bodies, so `kit-only` is always safe to apply and a region edit is never a conflict. An edit outside the regions is `patched` or `unsanctioned`.
- **Workflows** (`.github/workflows/`, `owned` or `merge`) — sync writes each action pin at the newer of the kit's and the project's version, so a pin the project's Dependabot raised is not a project edit. Apply a `kit-only` workflow like any other: it keeps the newer pins and raises the older ones.
- **`template`** — a SEED: the project's own content from the start. It is offered once, as `new-kit`, to a project that has never had it. Once the project has it — untouched, adapted or deleted — or declined it, a kit change never offers it again (`template-kept`, `declined`). The hook permits consumer edits.

**Acking an `owned` file — the test is whether the kit's current content has been INCORPORATED.** `--ack-file` accepts any file: it advances the baseline to what the kit ships today and leaves the project file untouched.

- **Forbidden — ack INSTEAD of applying.** The project never took the kit's change, and the ack hides it.
- **Right — ack AFTER hand-merging the kit's change into a registered patch** (`patch.recommendation` `merge-kit-keep-patch`). The kit's change is in the file and the register sanctions what still differs, so the file reports `patched` with `kit_changed: false` until the kit moves again.

An ack never sanctions an edit. An `owned` file that still differs from the kit after an ack is `unsanctioned` unless the register lists it.

The lockfile tolerates both schemas: a legacy bare-string value means `owned`. Entries are upgraded to `{sha, mode}` as each file is applied; there is no migration step.

### Step 2.1: settings.json canonicalization (silent, handled by the script)

`.claude/settings.json` uses 3-way comparison like every other file, with one wrinkle: both sides are compared as jq-canonicalized JSON rather than raw bytes, so a reordered key or reindented block does not surface as a diff on content that is semantically identical.

The helpers live in `sync-dev-kit.sh` (`canonicalize_settings` + `sha256_settings_kit` + `sha256_settings_proj`). Every field — hooks, permissions, env — flows through normal 3-way state; the kit owns them all. The lockfile baseline SHA tracks the canonicalized content, matching subsequent scans.

**The project's own hooks live in `.claude/settings.project.json`**, which the project owns and sync never writes. The kit's `settings.json` is written with them composed in, each event's entries after the kit's, so a changed sidecar shows `settings.json` as `kit-only` and the mechanical pass applies it. A project that edited `settings.json` itself to add a hook is `unsanctioned`: move the hook into the sidecar, then apply the kit's file.

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
.claude/scripts/sync-dev-kit.sh --remove-patch <dest_path>
gh issue close <projectIssue number> --comment "Kit fix landed via /sync-dev-kit; the temporary patch is removed."
```

`--remove-patch` prints the removed entry, which names the project issue to close. Close it only once the user agrees.

### Step 2.3: `merge` files — regions

A `merge` file marks each project region in its own comment syntax: `<!-- project:begin <name> -->` … `<!-- project:end <name> -->` in Markdown, `# project:begin <name>` … `# project:end <name>` in YAML and `.gitattributes`. Names are unique per file and regions do not nest.

**`merge-unmarked`** — the project's copy predates the regions. Show the user the kit file and the project file side by side, move each piece of project content into the kit region that matches it, take the kit's text everywhere else, and re-scan. Content that fits no region is either kit-shared (raise a kit issue) or a patch (register it) — never invent a region the kit does not have.

**`merge-invalid`** — read `detail`: an unclosed or nested region, a duplicate name, or a region the kit does not have. Fix it by hand and re-scan.

### Step 3: The mechanical pass, then each file that needs a person

**Apply every `kit-only` and `new-kit` file with `--apply-file` (Step 4), without asking file by file** — the go-ahead covered them. The exception is a `new-kit` the briefing named as breaking something here (Step 3.5).

Then put each file that needs a person to the user, one at a time — the states the briefing listed under item 2. For each, show:

- the destination path (`dest_path`) and what the file is for, in a sentence;
- what happened, in plain words — "the kit changed this file, and so did this project" — and what you recommend;
- the diff when it is short, or on request; for a conflict, BOTH diffs: `baseline → kit` and `baseline → project`.

The user can stop at any point; the lockfile keeps every file already applied, and the next sync picks up the rest.

### Step 3.5: A `new-kit` the user does not want

```bash
.claude/scripts/sync-dev-kit.sh --decline-file <kit_path>
```

Records the kit's current content as a refusal WITHOUT creating the project file, so the entry reports `declined` and stops being listed.

**"Skip" is not an answer here.** A skipped `new-kit` has no lockfile entry, so it is offered again on every sync. Offer: **take it** (`--apply-file`), **decline it** (`--decline-file`), or **decide later** (genuinely skip, and say it will be asked again).

**Do NOT use `--ack-file` for this.** Ack records a baseline for a file that does not exist locally, so the next scan reports `project-deleted` — one recurring nag traded for another. The script refuses `--decline-file` on a file the project HAS, for the mirror-image reason; that case is `--ack-file`.

Declining is per kit VERSION. When the kit changes that file it is offered again. Undo is just `--apply-file` — applying overwrites the entry and the refusal disappears with it.

### Step 4: How a file is applied

For each file the mechanical pass takes, and each the user accepts:

```bash
.claude/scripts/sync-dev-kit.sh --apply-file <kit_path>
```

The `kit_path` field comes from the file entry (e.g., `_claude-project/hooks/git-guard.sh`). The script copies the file to the correct destination and updates the lockfile's per-file SHA entry.

On a `merge` file the script writes the kit's text around the project's region bodies, so applying never costs the project its regions. It refuses (exit 4) on `merge-unmarked` and `merge-invalid`.

For `removed-kit` state accepted, pass the entry's **`dest_path`** instead. The kit file is gone, so `kit_path` is empty in the report and there is nothing else to name it by:

```bash
.claude/scripts/sync-dev-kit.sh --apply-file <dest_path>
```

The script confirms nothing in the kit still maps to that destination, then deletes the file from the project and drops its lockfile entry. If the kit DOES still supply it, the call fails and names the kit path to use — which means the entry was not `removed-kit` and you misread the report.

Do NOT try to reconstruct the kit path yourself. The kit→destination map is not invertible: `templates/` sends several kit paths to root-level and `SHARED_MODULE_DIR` destinations, so a guessed kit path either exits 4 or names the wrong file.

### Step 5: Handle .gitignore

If `gitignore_additions_missing` is non-empty:

- List missing entries and recommend adding them all (Step 2.04).
- Ask: "Add these to `.gitignore`?"
- On accept: `.claude/scripts/sync-dev-kit.sh --apply-gitignore`

### Step 5.5: Run the migrations

Every migration in `migrations_pending` runs in this session, in order, once the files are applied. For each:

1. Read its `prompt` file in full. Tell the user, in a sentence, what it changes, and remind them of its estimate from the briefing.
2. Carry out everything below its `---` line as the user's instruction. Its Estimate section was for the briefing; skip it here.
3. When it is done, record it: `.claude/scripts/sync-dev-kit.sh --migration-done <name>`. An uncommitted one is recorded the same way.

A migration the user chooses to leave is not recorded. `--finalize` carries a committed one to the next sync, which lists it first; an uncommitted one is offered again while the kit's working tree still holds it.

### Step 6: Finalize

After all decisions processed, ALWAYS run:

```bash
.claude/scripts/sync-dev-kit.sh --finalize
```

`--finalize` **stamps the lockfile** — sets `lastSyncedCommit` and `lastSyncedAt` (the per-file SHAs are already current because `--apply-file` updated them incrementally) — and records in `pendingMigrations` any committed migration this sync listed and did not run. Each uncommitted migration run goes into `migrationsRunAhead`, so it does not run again when the kit commits it; the entry is dropped once the kit's history holds that migration, or on a maintainer's machine once the draft is gone. A first sync records every uncommitted migration there, since the project starts on the working tree.

**Sync does NOT commit or push.** It applies kit updates to the working tree and stamps the lockfile — that's all. Committing is gitflow's job, not sync's. After `--finalize`, the synced `.claude/` files plus the lockfile bump are a normal uncommitted change in the working tree.

**Then tell the user to land it with `/ship-main`** — that's the natural fit (commits + pushes straight to `main` in one step). The user may also `/commit` it as a feature branch + PR if they prefer review; sync is agnostic. Do NOT auto-commit (per `git.md` — no git operation without explicit instruction); surface that the sync is applied and `/ship-main` will land it.

**Do NOT finalize if the user stopped intending to resume later** — the lockfile per-file SHAs are still current, and the next `--scan` will correctly identify what remains to review. Finalizing now would mark the current kit HEAD as the baseline even for files the user hasn't reviewed yet.

Finalize ONLY when:
- All non-clean files have been reviewed and decided (even if decision was "skip")
- OR the user explicitly says "finalize anyway" despite pending reviews

### Step 7: Report

Summarize:
- Files the mechanical pass applied (count + list)
- Each file put to the user, and what they decided
- Files skipped with state
- .gitignore entries added
- Migrations run, and any carried to the next sync
- The kit release synced to (`release` from `--prepare`) and the lockfile kit commit SHA (before vs after)
- That the synced files are **uncommitted in the working tree** — and that `/ship-main` will land them (sync does not commit)

## Edge cases

- **Kit repo not clean** (maintainer's machine): warn, and proceed if the user insists
- **Kit behind remote** (maintainer's machine): refuse to proceed until the kit clone is pulled
- **Running from inside the kit repo**: script refuses with exit code 4; surface message
- **Mid-feature sync**: expected and supported. Sync runs on whatever branch you are on, so a rule fixed mid-session is live in context for the rest of it. The applied changes ride the same commit as the rest of the body of work, which is the house model (rules/git.md), not something to avoid.

## What this command does NOT do

- **Does not change the project's code beyond its migrations.** A check the sync just
  landed may fail on code that predates it — a new lint plugin, a stricter tier rule, a new
  gate — that no migration covers. List each such failure in the Step 7 report and stop:
  fixing it is the project work the maintainer starts next, in this same project, under
  §XII. The sync's body of work ends at `--finalize`.
- Does not push the kit itself — user handles kit repo separately.
- Does not edit files in the kit — purely a pull-from-kit operation. Kit-shared changes are made in the kit source and arrive here on the next sync.
- **Does not commit or push anything.** Sync applies kit updates to the working tree and stamps the lockfile; the user lands the result with `/ship-main` (or `/commit`). Sync runs no git operations in the project.
