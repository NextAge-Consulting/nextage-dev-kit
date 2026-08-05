# Verify-Before-Recommending: Sync System Pre-Read (Zero Tolerance)

> **Companion rule:** `dev-kit-workflow.md` (this folder) — covers the three source surfaces (`_claude-project/`, `_claude-global/`, `_statusline/`), kit's own `.claude/` mirror behavior, and propagation rules. This file covers what must be read BEFORE proposing changes. Read both when working on the kit.

The dev kit's sync system has many exceptions and special-handling cases. Recommendations made WITHOUT reading the design have repeatedly contradicted it (proposing runtime substitution when the system is build-time; proposing removal of defensive guards labelled "dead code" without understanding their role; conflating kit's `.claude/` with `_claude-project/` during sync scope).

**Before proposing or executing ANY change to:**

- `_claude-project/**` (templates that ship to consumers)
- `_github-project/**` (GitHub workflow templates that ship to consumers)
- `_claude-global/**` (sync script + bootstrap commands)
- `_claude-project/sync-substitutions.json` (placeholder catalog)
- Any kit-shipped script, config, workflow, or rule
- `project-documentation/HANDBOOK.md` content that documents sync, placeholders, or templates
- `project-documentation/GITFLOW-CHEATSHEET.md`

…Claude MUST first load the following into context end-to-end:

1. **`_claude-maintainer/scripts/sync-dev-kit.sh`** — sync logic, modes (`--scan` / `--apply-file` / `--apply-gitignore` / `--finalize`), state classification (`clean` / `kit-only` / `project-only` / `conflict` / `clean-converged` / `clean-first` / `conflict-first` / `new-kit` / `removed-kit` / `project-deleted`), the substitution engine (`apply_substitutions`, `sha256_substituted`), the `dest_for_kit_path` mapping table, the `is_skipped` patterns, and the `SKIP_LIST`.

2. **`_claude-maintainer/commands/sync-dev-kit.md`** — the skill including Step 1.5 substitutions walkthrough, the per-state recommendation table, and the finalize semantics.

3. **`project-documentation/HANDBOOK.md`** — at minimum:
   - §0 (kit source layout — `_claude-project/` vs `_claude-global/` vs `.claude/`)
   - §9 (sync workflow), particularly **§9.7 (placeholder substitutions)** and **§9.8 (substitutions walkthrough)**
   - §11 (workflow file templates) — read the relevant subsection for whichever template is being touched
   - The full table of currently-defined `{{KEY}}` placeholders in §9.7 (consumed-by + value-shape)

4. **`_claude-project/sync-substitutions.json`** — the authoritative key catalog: `_placeholders_referenced_by_kit` descriptions, `_documented_behavior` (the missing-vs-empty-vs-populated semantics), `_intentionally_empty_doc` (the sidecar-array convention).

## The non-obvious design points that bite

These are the design decisions that have been mis-handled in past sessions. Memorize them:

- **Substitution is build-time, not runtime.** `apply_substitutions` runs during `--scan` (for SHA computation) AND `--apply-file` (for writing). The synced consumer file contains real values, never `{{KEY}}` markers. Proposals to "resolve at runtime" rewrite the substitution engine and break the SHA-comparison contract.
- **Three states for a substitution key, each deliberate**:
  - **Missing from JSON** → no substitution → `{{KEY}}` survives in synced file → "you haven't decided yet" signal, perpetual diff to nag.
  - **Present, empty string** → substitutes to empty → "intentionally disabled" signal.
  - **Present, populated** → normal substitution.
  - The `_intentionally_empty` sidecar array distinguishes "informed disable" from "deferred decision" when both are stored as `""`.
- **Defensive guards in templates that pattern-match `{{...}}` are NOT dead code.** They catch the rare path where a key is missing from substitutions and the marker survived sync — they fail loud with a clear error instead of running with literal `{{KEY}}` as a value. Removing them is wrong.
- **Kit has TWO `.claude` surfaces:** `_claude-project/.claude/...` (template that ships to consumers) and `<kit_root>/.claude/...` (kit's own dogfood). Edits to the template MAY also need mirroring into the kit's own dogfood — but **whether a given item is dogfooded at all is governed by the "Kit dogfood manifest" table in `dev-kit-workflow.md` (the single source of truth); template-only items listed there are deliberately NOT mirrored.** Either way, `/sync-dev-kit` only ever compares consumer's `.claude/` against kit's `_claude-project/`, never against kit's own `.claude/`.
- **Sync state names are exact terms with exact meanings.** Don't paraphrase. Use the table at §9.3 of HANDBOOK and the recommendation table in `_claude-maintainer/commands/sync-dev-kit.md` Step 2.
- **Lockfile baseline SHA tracks substituted content**, not raw kit bytes. A consumer's lockfile entry equals the SHA of what was written to disk, which equals the SHA of `apply_substitutions(kit_file)` at the time of apply.

## How to apply this rule

When you (Claude) are about to propose a kit change:

1. Explicitly state which of the four sources above are loaded into context.
2. If any are not loaded, **load them BEFORE making the proposal**, not after the user corrects a wrong proposal.
3. If your proposal touches a substitution-related concept (markers, missing-vs-empty, walkthrough, `_intentionally_empty`), cite the specific paragraph in §9.7 / §9.8 / `_documented_behavior` you're working from.
4. If your proposal removes or rewrites code that handles `{{...}}` markers, prove first that the design doesn't rely on it (don't assume "dead code" — defensive guards are not dead).

## Why this rule is zero-tolerance

The maintainer is the sole human consumer of this kit. Every wrong recommendation costs them cycles to identify and correct. The kit's design is heavily commented and well-documented — there is no excuse for proposing changes that contradict comments or HANDBOOK sections that are already in the repo. Read first.
