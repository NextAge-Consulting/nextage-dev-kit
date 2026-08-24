# Verify Before Recommending: Sync System Pre-Read (Zero Tolerance)

> **Companion:** `dev-kit-workflow.md` — the three source surfaces, the kit's own `.claude/` mirror, and propagation. This file covers what to read BEFORE proposing anything. Read both when working on the kit.

## Load these before touching the sync system

Before proposing or executing any change to `_claude-project/**`, `_github-project/**`, `_claude-global/**`, `sync-substitutions.json`, any kit-shipped script, config, workflow or rule, `handbook.md` content documenting sync or placeholders or templates, or `gitflow-cheatsheet.md` — read the following. Paths are relative to the kit root. Items 1, 2 and 4 are read end to end; the handbook is read by the sections named:

1. **`_claude-maintainer/scripts/sync-dev-kit.sh`** — the modes (`--scan` / `--apply-file` / `--apply-gitignore` / `--finalize`), the state classification, the substitution engine (`apply_substitutions`, `sha256_substituted`), the `dest_for_kit_path` mapping table, the `is_skipped` patterns, and the `SKIP_LIST`.
2. **`_claude-maintainer/commands/sync-dev-kit.md`** — the Step 1.5 substitutions walkthrough, the per-state recommendation table, and the finalize semantics.
3. **`project-documentation/handbook.md`** — §0 (kit source layout), §9 (sync workflow) and especially §9.7 and §9.8 including its full `{{KEY}}` placeholder table, plus §11 for whichever workflow template you are touching. More if the change reaches further.
4. **`_claude-project/sync-substitutions.json`** — the authoritative key catalog: `_placeholders_referenced_by_kit`, `_documented_behavior`, and `_intentionally_empty_doc`.

Name which of the four you have loaded, in the reply, in the sentence before the proposal. If any are not loaded, load them first — not after a wrong proposal gets corrected.

## The design points that bite

**Substitution is build-time, not runtime.** `apply_substitutions` runs during `--scan` (to compute the SHA) and during `--apply-file` (to write). The synced consumer file contains real values, never `{{KEY}}` markers. A proposal to "resolve at runtime" rewrites the engine and breaks the SHA-comparison contract.

**A substitution key has three states, each deliberate.** Missing from the JSON means no substitution, so `{{KEY}}` survives into the synced file as a "you haven't decided yet" signal and a perpetual diff that nags. Present but empty substitutes to empty — "intentionally disabled". Present and populated is normal substitution. The `_intentionally_empty` sidecar array is what distinguishes an informed disable from a deferred decision, since both store `""`.

**Defensive guards that pattern-match `{{...}}` are not dead code.** They catch the rare path where a key is missing and the marker survived sync, failing loud instead of running with a literal `{{KEY}}` as a value. Before removing or rewriting any code that handles those markers, prove the design does not rely on it.

**The kit has two `.claude` surfaces.** `_claude-project/.claude/…` is the template that ships to consumers; `<kit_root>/.claude/…` is the kit's own dogfood. Whether a given item is dogfooded at all is governed by the manifest in `dev-kit-workflow.md`. Either way, `/sync-dev-kit` only ever compares a consumer's `.claude/` against the kit's `_claude-project/`, never against the kit's own `.claude/`.

**Sync state names are exact terms with exact meanings** — `clean`, `kit-only`, `project-only`, `conflict`, `clean-converged`, `clean-first`, `conflict-first`, `new-kit`, `removed-kit`, `project-deleted`. Use them as written, from handbook §9.3 and the recommendation table in `sync-dev-kit.md` Step 2. Don't paraphrase.

**The lockfile baseline SHA tracks substituted content, not raw kit bytes.** A consumer's lockfile entry equals the SHA of what was written to disk, which equals the SHA of `apply_substitutions(kit_file)` at the time of apply.

When a proposal touches markers, missing-vs-empty, the walkthrough, or `_intentionally_empty`, cite the specific paragraph in §9.7, §9.8 or `_documented_behavior` you are working from.
