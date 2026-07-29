# templates/

Files and file-fragments that are installed at the **repo root** of consumer projects (outside the `.claude/` tree).

Sync behavior (`/sync-starter-kit`):

- **`.mcp.json`** — copied to consumer's `/.mcp.json` during bootstrap. Subject to diff/review on subsequent syncs like any other kit-owned file. Uses `${REF_API_KEY}` and `${EXA_API_KEY}` env var expansion so keys never land in the repo.
- **`.commitlintrc.json`** — copied to consumer's `/.commitlintrc.json`. Paired with `.github/workflows/commitlint.yml` (under `_github-project/`). Defines the conventional-commit types accepted by the commitlint CI gate; must match the gitflow skill's `references/commit-types.md`.
- **`biome.json`** — copied to consumer's `/biome.json` during bootstrap. Subject to diff/review on subsequent syncs. Opinionated default for AI-authored TS/JS projects: formatter disabled, linter on `"recommended": true`, scoped via `**/*.{ts,tsx,js,jsx,mjs,cjs,mts,cts,json}` with build outputs excluded via `vcs.useIgnoreFile` (trusts the project's `.gitignore`). See kit `PIPELINE.md` §1.4 for rationale.
- **`.gitignore-additions`** — NOT copied as a file. Sync script reads the entries and ensures each line is present in the consumer's `.gitignore`. Missing entries are appended; existing entries are left alone.
- **`.semgrepignore`** — copied to consumer's `/.semgrepignore` during bootstrap. Subject to diff/review on subsequent syncs. Mandatory companion to Semgrep adoption: without it, generic secret-regex rules match base64 noise inside design binaries (PDF / EPS / PSD / etc.) and lockfiles, fire per-file timeouts, and burn CI minutes on content that isn't source code. Scope includes `project-documentation/`, `docs/`, design binaries, images, video, archives, fonts, build outputs, and lockfiles (Dependabot owns dep security). See https://github.com/PeteHalsted/claude-project-starter-kit/blob/main/project-documentation/HANDBOOK.md#11-workflow-file-templates and kit `PIPELINE.md` §1.4 for rationale.

Add new root-level template files here when a future need arises (e.g., `.editorconfig`, CI workflow templates). After adding, register the file name mapping in `_claude-maintainer/scripts/sync-starter-kit.sh` (`dest_for_kit_path` function).
