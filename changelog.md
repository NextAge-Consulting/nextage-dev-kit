# Changelog

All notable changes to the Claude Project Starter Kit will be documented here.

### July 10, 2026

- **✨ `/e2e-author` skill** - Companion to the `/e2e` runner for writing and maintaining flow files. Carries the flow-file format, frontmatter spec, and a recipe library for the recurring agent-browser gotchas (off-screen click scroll, env-with-spaces loading, mouse-move arg split, viewport, OTP-from-DB), plus a dry-run-before-done rule so new flows can't rot unrun.
- **✨ `/e2e` HTML report** - Runs emit a self-contained HTML report with per-step ✅/❌, inline screenshots, and per-flow + suite runtimes, so a run can be fired off and reviewed async (and future runs have a time baseline).
- **🔧 `/e2e` viewport** - Startup viewport corrected to 1440×900 to match the canonical `agent-browser` rule; documented the scroll-then-click fallback for below-the-fold buttons.

### May 30, 2026

- **🔧 design.md linter is now a declared script** - The `design-system` skill validates via `npm run lint:design` instead of an ad-hoc `npx @google/design.md …`. Consumers declare `@google/design.md` in `devDependencies` plus a `"lint:design"` script (HANDBOOK §12a.4); declaring it keeps the lint reproducible and stops agent sandboxes from blocking an undeclared external download.

### May 15, 2026

- **✨ /dev Skill** - New skill launches dev servers in iTerm tabs with worktree-aware cwd, automatic port-collision detection via `lsof`, and `--tunnel` flag for Cloudflare named tunnels
- **✨ /deploy via PR Gate** - Releases now ship through the same protected-main PR gate as feature PRs; CI short-circuits release-typed PR titles so required checks emit success in seconds rather than re-running full suites
- **✨ Worktree postCreate Hooks** - `/work` now applies gitignored symlinks and runs `worktree.postCreate` commands declared in `.claude/settings.json` immediately after `git worktree add`

### May 13, 2026

- **✨ /sync command** - New gitflow primitive to merge updated `main` into a mid-flight feature branch when another PR has shipped. Supports `--continue` / `--abort` on conflict. Avoids the close-and-reopen workaround.
- **✨ Push recovery via `--push-only`** - `/commit --push-only` retries a half-shipped commit (commit succeeded, push failed) without re-running typecheck or staging.
- **🐛 Push reliability for new worktrees** - Branches created by `/work` no longer inherit `origin/main` as upstream, so the first `git push` from a `feat/...` branch no longer fails under `push.default=simple`.
- **✨ `/work --discard current --force`** - Allows removing the persistent `current/` worktree (previously refused unconditionally). Use when `current/` is orphaned after shipping through a separate compartment, or for a hard reset.
- **🐛 Starter-kit sync auto-merge race** - `/sync-starter-kit` now waits for required GitHub status checks to register before admin-merging the sync PR, avoiding the "N of N expected" failure.

### May 12, 2026

- **🐛 `/work` no longer collides with primary's `main`** - Worktrees are now created on a `wip/<timestamp>` branch (or issue-derived branch) from day one, instead of attempting to check out `main` (which the primary already owns). Eliminates a silent failure where the worktree was never created but the script reported success.
- **🐛 `/merge` cleanly deletes the merged branch** - `gh pr merge --delete-branch` is now invoked from outside the git tree so it skips its local-side checkout step, which would otherwise collide with primary's `main`. Local branch cleanup is done explicitly by the script after the active worktree is removed.
- **🐛 `/triage` no longer resurfaces stale Gemini comments** - Inline-comment freshness now filters on `original_commit_id` (immutable) instead of `commit_id` (which GitHub auto-bumps as comments re-anchor to current HEAD). Resolved comments stay resolved across subsequent triages.
- **🐛 Sync auto-merge bypass** - `/sync-starter-kit` now merges its own PR with admin bypass and fails loud if the merge is blocked, preventing a stale-main trap where primary returned to main while the sync PR sat unmerged behind branch-protection checks.
- **🐛 Sync Script Path Resolution** - Define `PROJECT_PATH` in the sync script so kit syncs resolve consumer-project paths correctly.
- **✨ Worktree-based Sessions** - New `/work` command boots each session into a project-local git worktree (`current/` or named compartments) so the primary repo folder stays reserved for git substrate. Supports issue-linked branch creation (`/work <issue#>`), parallel compartments (`--new`), branch retrieval (`--retrieve`), and cleanup (`--discard`).
- **✨ Human-in-the-Loop Deploys** - New `/deploy` command bumps version, writes the consolidated changelog, tags, pushes, and triggers `deploy.yml` via `workflow_dispatch` only when you explicitly invoke it. Multiple feature merges can accumulate on main between releases.
- **💥 Removed `/branch`** - Subsumed by `/work <issue#>`. Update muscle memory.
- **💥 Removed Auto Version-Bump CI** - `version-bump.yml` and `tag-release.yml` workflows are gone. Consumer projects must remove those files on next sync and configure `deploy.yml` with `on: workflow_dispatch:` only.

### May 6, 2026

- **🐛 Statusline Stays Two-Line On Narrow Terminals** - Long folder + branch combinations no longer push the metrics line off-screen. Path collapses to its basename and branch truncates with an ellipsis when terminal width is tight.
- **✨ Auto-Trigger Gemini Re-Review On Push** - `commit.sh` now posts `/gemini review` after pushing to a branch with an open PR, so Gemini re-reviews the new HEAD without manual intervention. Idempotent (skips if already reviewed) and respects `GEMINI_NOT_INSTALLED` opt-out.
- **🐛 Fix Silent Bypass Of CI Gate On Transient gh CLI Failures** - `wait-for-pr-ready.sh` now distinguishes a `gh` CLI failure (network/auth/rate-limit) from "no required checks configured" — the former retries on the next poll instead of falsely passing.

### May 1, 2026

- **🐛 CR Gate Default-ON Fix** - Renamed `CR_ENABLED` → `CR_NOT_INSTALLED` and flipped the runtime check. CR gating now defaults to ON for every repo (matching the shop's "assume CR installed, fail loud if not" stance); opt-out per-repo via `CR_NOT_INSTALLED="true"` only when the CodeRabbit App is genuinely absent. The previous semantics silently disabled CR enforcement on any repo that synced the new key without explicit configuration — opposite of the intended behavior.
- **✨ PR Readiness Gate** - New `wait-for-pr-ready.sh` blocks `/open-pr`, `/triage`, and `/merge` until CI passes and (when `CR_ENABLED="true"`) CodeRabbit has reviewed the current commit. Replaces the bare CI check that previously lived in `/merge`. Polls every 30s, fail-loud timeout after 15 minutes with diagnostic naming likely causes.
- **✨ CR_ENABLED Toggle** - New runtime-read substitution key in `sync-substitutions.json` records whether the CodeRabbit App is installed on a repo. Empty (default) = CR gating skipped silently. `"true"` = CR-on-HEAD required before triage/merge. Toggle without re-syncing.
- **🐛 version-bump.yml auto-merge restored** - Release PR now correctly queues for auto-merge via `gh pr merge --auto --squash` so branch protection's required checks can run before merge. Prior immediate-merge would be rejected by branch protection in any consumer project enforcing CI gates.
- **✨ /triage command** - Walk through CodeRabbit PR review comments one at a time, with fix/skip/discuss decisions per item.
- **🔧 ROLLBACK_REPO_DIR placeholder** - Rollback script's remote deploy directory is now per-project configurable instead of hardcoded.

### April 28, 2026

- **✨ CPL v1.5: Zed integration dropped** - The CPL launcher now offers two modes — Claude and Terminal — instead of four. The Zed editor integration (Claude+Zed, Zed Only, Zed close-on-exit, Accessibility-API window positioning) has been removed entirely. Existing `~/.cpl.conf` files keep working; the four Zed-specific keys are ignored. The standalone `cpl-close-zed` binary is auto-removed on next sync.
- **🐛 CPL: slot config respects `maxSlots` and cycles back when full** - `cpl-slot` now reads `maxSlots` from `~/.cpl.conf` and iterates dynamically instead of hardcoding three slots. Reducing `maxSlots` automatically removes orphan slot files on the next launch. When all slots are claimed, the next launch cycles back to slot 1 and overlaps the existing window instead of blocking with an "All slots in use" dialog. Releases are ownership-checked by project name, so a session whose slot was cycled-over won't accidentally delete the new occupant's file.
- **🐛 CPL: sync-cpl.sh kills running applet before install** - macOS caches AppleScript bytecode in memory once the CPL applet is running, so previously the new code wouldn't take effect until the user manually killed the applet. The sync script now stops the applet and any orphan picker process before writing the new build, so Spotlight launches pick up the fresh code immediately.
- **✨ Substitutions bootstrap on first sync** - `/sync-starter-kit` now auto-creates `.claude/sync-substitutions.json` from the kit template on first run for any consumer project. Closes the gap where the file was in the script's skip list and `/install-kit` didn't seed it either, leaving consumer projects with literal `{{KEY}}` placeholders in synced configs and no file to populate.
- **✨ Empty-string substitutions as explicit opt-out** - Substitution keys with empty string values now substitute to empty (was: skipped, leaving `{{KEY}}` literal). Three states per key: missing key forces attention, empty value signals informed disable, populated value behaves normally. Lets features like gitflow GitHub-Project integration ship disabled-by-default cleanly without misleading runtime warnings.
- **✨ First-run substitutions walkthrough** - `/sync-starter-kit` now walks the user through populating empty substitution keys before the file-diff loop runs. Pulls per-key descriptions from the kit catalog, runs `gh api graphql` discovery commands automatically when available, asks for values directly otherwise, and supports populate / disable / defer per key. Disabled keys are tracked in an `_intentionally_empty` sidecar so they don't re-prompt on subsequent syncs.

### April 24, 2026

- **✨ /triage command** - Walk CodeRabbit PR review items one at a time with per-item fix/skip/reply decisions, threaded replies, and one commit per accepted fix.
- **🐛 Changelog insertion ordering** - New date sections now anchor on `## [Unreleased]` or the first dated level-2 header instead of the first `---` divider, preserving reverse-chronological order in changelogs that use `---` as visual section separators.
- **🔧 agent-browser viewport default** - Default viewport is now 1440×900 (fits every mainstream laptop screen plus external monitors) with documented Stripe cross-origin iframe workaround and Playwright manual-resize caveat.

### April 20, 2026

- **✨ E2E verification skill** - New `/e2e` command runs agent-browser flows as a pre-merge gate, scoped to your PR diff
- **✨ Rollback template** - `scripts/rollback.sh` ships from the kit for consumer projects (docker-compose service rollback with health-port checks)
- **✨ CodeRabbit config template** - `.coderabbit.yaml` syncs to consumer projects out of the box
- **✨ Testing scaffolding template** - Drop-in vitest config, smoke test, and auth-mock utilities
- **✨ Dependabot + Node LTS check** - New `.github/dependabot.yml` and `node-lts-check.yml` workflow shipped as kit templates
- **🐛 Commitlint no longer blocks Dependabot PRs** - PR-title-only validation fixes false rejections from Dependabot's double-scoped branch commits
- **🐛 Dev-server hook no longer blocks legitimate starts** - Hook narrowed to kill-prevention only; `npm run dev` works without permission ping-pong during E2E

### April 19, 2026

- **✨ Placeholder substitutions in /sync-starter-kit** - Kit templates can now use `{{KEY}}` markers for per-project values (repo slug, org, release-bot App, gitflow project IDs). Each consumer defines real values in `.claude/sync-substitutions.json` and sync applies them transparently during both scan and write. Templates with placeholders match consumer files with real values as `clean` instead of surfacing as permanent conflicts. Backward compatible: missing or empty substitutions file behaves identically to pre-feature sync.
- **🐛 /open-pr changelog handling on case-insensitive filesystems** - Fixed a bug where `/open-pr` left the changelog modification uncommitted and opened a PR with a dirty working tree when the repo used a lowercase `changelog.md` on macOS APFS. The script now resolves the canonical tracked path via `git ls-files` and fails loud if `git add` ever leaves the workdir dirty, instead of silently producing an inconsistent PR.
- **🐛 Auto-branch type derivation with scoped commits** - Fixed a bug where `/commit`'s auto-branch naming picked the commit **scope** instead of the **type** when a scope was present. `fix(gitflow):` was producing `gitflow/...` branches instead of the correct `fix/...`. All scoped conventional commits (`feat(auth):`, `docs(readme):`, etc.) now derive the right branch prefix.
- **✨ GitHub issue linking in gitflow** - `/branch #23` (or `#23,#25,#26`) now creates a feature branch linked to the issue(s), assigns them to you, moves them to "In Progress" on the project board, and dumps issue context for Claude to read before touching code.
- **✨ /link command** - Link additional GitHub issues to the current branch mid-work. Same side effects as `/branch --issues` without creating a new branch.
- **✨ Auto-Closes in PR body** - `/open-pr` now prepends `Closes #N, #M…` to the PR body from branch-linked issues, so GitHub auto-closes them on merge.
- **✨ Developer documentation** - New `GITFLOW-CHEATSHEET.md` (one-page day-to-day reference) and `KIT-REPO-GITHUB-CONFIG.md` (kit repo's GitHub state + sanity checklist for future changes).

### April 18, 2026

- **✨ Suppression Discipline (Constitution §XIII)** - New zero-tolerance rule: a linter suppression comment (`biome-ignore`, `nosemgrep`, `ts-expect-error`) is the option of LAST resort. Before suppressing, prove no cheap real fix exists — checklist walks through the refactors that eliminate most flags. Captures the lesson that ~20 AI-written suppressions landed on a consumer CI backport with cheap real fixes available.
- **✨ Accessibility Baseline Rule (auto-loaded on TSX/JSX edits)** - New `a11y-baseline.md` rule auto-loads whenever Claude edits a `.tsx` / `.jsx` file. Covers every a11y rule that fires on AI-generated JSX: explicit `type=` on `<button>`, `<title>` or `aria-hidden` on inline SVG, `htmlFor`-linked labels, `<button>` (not `<div onClick>`) for click handlers, `<fieldset>`/`<legend>` for control groups, stable list keys, no `autoFocus`, `unknown` (not `any`) in catch blocks.
- **✨ shadcn Primitive A11y Rule** - New `a11y-primitives.md` in the shadcn skill: primitives in `components/ui/*` must be a11y-correct by default so downstream callers inherit correctness. Button primitive defaults to `type="button"`; icon-only buttons require `aria-label`; post-install audit is now a required step after every `shadcn add`.
- **✨ Biome Template for AI-Authored TS/JS Projects** - New `biome.json` ships at the consumer repo root via `/sync-starter-kit`. Formatter disabled (AI-authored code doesn't need formatting consistency churn), linter on `"recommended": true`, scoped with `vcs.useIgnoreFile` so build outputs are excluded via the project's `.gitignore`. Paired with a new commit-time Biome lint step in gitflow's `/commit` so failures fire in <1 second locally instead of 30 seconds on the PR.
- **✨ Expanded Conventional Commit Types** - Adds `🏗️ build` (build system / dependency manifests), `👷 ci` (CI/CD workflow changes), and `⏪ revert` (reverting a prior commit) to both the gitflow commit-types reference and the `.commitlintrc.json` template. Header-max-length lifted to 120 characters; body-max-line disabled.
- **🐛 Workflow Template Hardening** - Kit's `commitlint.yml`, `.commitlintrc.json`, and `version-bump.yml` templates absorbed three fixes discovered during a consumer's first pipeline deploy: commitlint now declares the `permissions` block required by the wagoid action; the commitlint parser preset accepts emoji-prefix headers (`✨ feat: …`, `🐛 fix: …`); the version-bump workflow reads commit messages via `env:` instead of inline substitution, closing a shell-injection path from commit-message content.
- **🐛 Version-Bump Auth via GitHub App** - Kit's `version-bump.yml` template now mints a short-lived installation token from a bot GitHub App (`actions/create-github-app-token@v2`) instead of using a personal access token. An App is an independent bypass identity on protected `main`, so the release bot can push through branch protection without making a human a bypass actor. Setup walkthrough added to HANDBOOK §11.3.

### April 17, 2026

- **✨ Auto-Branch Management in gitflow** - `/commit` on main auto-creates a `<type>/<slug>` branch derived from the commit message; `/checkpoint` on main auto-creates `wip/<timestamp>`; the first `/commit` on a `wip/*` branch renames it based on the real commit message (unless the branch has an open PR). New `/branch <name>` command for explicit branch creation.
- **✨ Local Changelog Generation in `/open-pr`** - Changelog entries are now written by Claude during `/open-pr` and committed to the feature branch before the PR opens. No `ANTHROPIC_API_KEY` or CI workflow required.
- **✨ Kit-Shipped GitHub Actions Templates** - New `_github-project/workflows/` directory ships `version-bump.yml` (TypeScript + Python support) and `commitlint.yml` to consumer projects via `/sync-starter-kit`. Convention: `_<name>/` maps 1:1 to `.<name>/` in the consumer.
- **✨ Tag-Triggered Deploy Contract** - Consumer deploy workflows must trigger on `push: tags: ['v*.*.*']` rather than `push: branches: [main]`. Eliminates the race condition where deploys shipped with pre-bump version numbers. Documented in HANDBOOK §11.4.
- **✨ Python LSP Verified** - Claude Code's LSP support for Python (pyright-lsp + pyright-langserver) verified end-to-end: `documentSymbol`, `hover`, and `findReferences` all return correct results. Setup docs updated in `claude-code-setup.md` §Python.
- **🐛 Kit Workflow Template Hardening** - Three fixes backported from a consumer's first deploy: `commitlint.yml` now declares `permissions: { contents: read, pull-requests: read }` (fixes "Resource not accessible by integration"); `.commitlintrc.json` ships a custom `parserPreset` so emoji-prefix headers (`✨ feat: …`) parse correctly; `version-bump.yml` reads the commit message via `env:` and `printf '%s'` instead of `${{ … }}` substitution, closing a shell-injection path from commit-message content.
- **🐛 Version-Bump Uses GitHub App, Not PAT** - `version-bump.yml` now mints a short-lived installation token via `actions/create-github-app-token@v2` from a bot GitHub App, replacing the prior `BOT_PAT`. A PAT on `main`'s bypass-actor list makes the PAT-owning human a bypass actor too, enabling accidental direct pushes from a shell. The App is an independent identity — humans always PR. Setup walkthrough: HANDBOOK §11.3.
