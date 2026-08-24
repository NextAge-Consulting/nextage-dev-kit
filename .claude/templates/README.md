# templates/

Files whose destination is **not** the plain `_claude-project/` → `.claude/` mapping, and which therefore need an explicit entry in `dest_for_kit_path`. Most land at the consumer's repo root; `testing/` lands beside the shared module (from the `SHARED_MODULE_DIR` substitution); `ui-inventory.md` lands inside `.claude/rules/project/`, the one directory sync otherwise never writes to.

Sync behavior (`/sync-dev-kit`):

- **`.mcp.json`** — copied to consumer's `/.mcp.json` during bootstrap. Subject to diff/review on subsequent syncs like any other kit-owned file. Uses `${REF_API_KEY}` and `${EXA_API_KEY}` env var expansion so keys never land in the repo.
- **`.commitlintrc.json`** — copied to consumer's `/.commitlintrc.json`. Paired with `.github/workflows/commitlint.yml` (under `_github-project/`). Defines the conventional-commit types accepted by the commitlint CI gate; must match the gitflow skill's `references/commit-types.md`.
- **`biome.json`** — copied to consumer's `/biome.json` during bootstrap. Subject to diff/review on subsequent syncs. Opinionated default for AI-authored TS/JS projects: formatter disabled, linter on `"recommended": true`, scoped via `**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,json}` with build outputs excluded via `vcs.useIgnoreFile` (trusts the project's `.gitignore`). See kit `pipeline.md` §1.4 for rationale.
- **`.gitignore-additions`** — NOT copied as a file. Sync script reads the entries and ensures each line is present in the consumer's `.gitignore`. Missing entries are appended; existing entries are left alone.
- **`.semgrepignore`** — copied to consumer's `/.semgrepignore` during bootstrap. Subject to diff/review on subsequent syncs. Mandatory companion to Semgrep adoption: without it, generic secret-regex rules match base64 noise inside design binaries (PDF / EPS / PSD / etc.) and lockfiles, fire per-file timeouts, and burn CI minutes on content that isn't source code. Scope includes `project-documentation/`, `docs/`, design binaries, images, video, archives, fonts, build outputs, and lockfiles (Dependabot owns dep security). See https://github.com/NextAge-Consulting/nextage-dev-kit/blob/main/project-documentation/handbook.md#11-workflow-file-templates and kit `pipeline.md` §1.4 for rationale.

- **`ui-inventory.md`** — copied to consumer's `.claude/rules/project/ui-inventory.md`. Synced in **`template` mode**: the kit ships the shape, the project owns every line of the content. It cannot ship from `_claude-project/rules/project/`, which `is_skipped` excludes entirely. See handbook §11.18.
- **`scripts/`** — `check-dep-alignment.mjs`, `check-workspace-tiers.mjs`, `check-tanstack.mjs`, copied to the consumer's `/scripts/`.
- **`testing/`** — vitest scaffolding, `template` mode, destination from the `SHARED_MODULE_DIR` substitution. Skipped entirely when that value is empty. See handbook §11.13.

Add new root-level template files here when a future need arises (e.g., `.editorconfig`, CI workflow templates). After adding, register the file name mapping in `_claude-maintainer/scripts/sync-dev-kit.sh` (`dest_for_kit_path` function).
