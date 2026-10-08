# Pipeline

The DevOps reference for a kit-enabled project: how code gets from a merged PR to
production, the CI that gates it, and why it is built this way. The short version is
`devops-handbook.md`; this is what you or your AI read when setting something up or when it breaks.

- **Design rationale** → Part 1
- **Deploy** → Part 2 — `/deploy`, versions, the changelog, the trigger contract, buildspecs, failures
- **CI and repository config** → Part 3 — commitlint, Semgrep, Dependabot, dependency gates, Gemini, notification noise

**No branch protection.** This pipeline does not use GitHub branch protection. `/merge` self-gates by reading the PR's CI check-runs directly — it never depends on GitHub's "required checks" config — so the gate behaves identically on every repo regardless of plan, including a brand-new one with nothing configured. The one hard requirement: **`main` must not require a PR**, or the direct-push paths (`/ship-main`, `/deploy`) get rejected. A fresh repo has require-PR off by default, so there is nothing to set up — just don't turn it on.

---

# Part 1 — Pipeline Design

The pipeline is a layered gate between "code written" and "code in production." Each layer catches a different defect class; none subsumes another.

| Layer | Catches | Where |
|-------|---------|-------|
| Local (gitflow pre-commit, Claude rules) | Fast feedback; bypassable | Dev machine |
| CI on PR | Type errors, lint, SAST, unit + integration tests; **hard gate** | GitHub Actions |
| AI review (advisory) | Structural diff defects, caller mismatches | Gemini on PR |
| E2E verification | "Whole app is broken" before a release | Claude-driven, manual `/e2e` |
| Production monitoring | Runtime throws, downtime (post-deploy catch-up) | Sentry / UptimeRobot |

## 1.1 Squash merge + self-gating (no branch protection)

The pipeline does not rely on GitHub branch protection. The merge gate lives in `/merge`, which reads the PR's CI check-runs directly and refuses to land a red PR — independent of any GitHub "required checks" config. That is why the gate behaves identically on every repo, including a brand-new one with nothing configured.

| Choice | Rationale |
|--------|-----------|
| Squash merge only (merge + rebase disabled) | One commit per feature on `main`. Clean history, trivial rollback (revert one commit = undo the feature). Branch commits (checkpoints, WIP) survive on the closed PR page. |
| `/merge` self-gates on CI | `/merge` reads the PR's check-runs and blocks on red. The gate is in the command, not in GitHub — it needs no branch-protection config to exist and can't be skipped from within gitflow. |
| No required human approval | CI + advisory AI review is the gate, not a human. A 2-dev shop reviewing each other's every PR is theater or a bottleneck. Tag a reviewer by hand when a change genuinely warrants it. |

**`main` must not require a PR.** This is the one hard requirement on the GitHub side, and it is the default on a fresh repo — so there is nothing to configure, just don't turn it on. The direct-push paths (`/ship-main`, `/deploy`'s bump push, the changes `/sync-dev-kit` leaves for you to land) push straight to `main`, and GitHub rejects those if require-PR is on. CI, commitlint, and Gemini still RUN on every PR (they fire on `pull_request` / gitflow triggers, not on protection) — they're simply not GitHub-merge-blocking, because `/merge` is the gate. `enforce_admins` is irrelevant — nothing admin-merges.

**Coordinated / delayed releases** use the PR as a parking lot: open it, let CI go green, don't merge until the timing is right (after-hours, sign-off, campaign launch). No release branch needed at this scale.

### `/ship-main` — the deliberate direct-to-main exception

For quick infra / emergency / "get it in and back to clean" work, a full branch→PR→CI→merge cycle is theater. `/ship-main` commits a conventional message **directly on `main`** and pushes — no branch, no PR, no CI (a push to `main` triggers nothing; CI is `pull_request`-only, and deploys start only when `/deploy` dispatches them). It runs the same local typecheck + lint as `/commit` (the assist that stays). Works as long as `main` does not require a PR (§1.1) — the default.

**The gate is explicit invocation, never inference.** A bare `/commit` on `main` still auto-branches (the safety for accidental-on-main); `/ship-main` is the opposite, on purpose, and only when asked for by name. Its commits land on `main` and feed the next `/deploy`'s bump + changelog exactly like a merged-PR squash commit. See `.claude/commands/ship-main.md`.

## 1.2 The gitflow subsystem (the workflow model)

Git operations route exclusively through gitflow — slash commands backed by scripts, fronted by a skill for natural-language routing, with a hook blocking raw destructive git. Four layers of defense: rule → skill → command → hook. Full subsystem in kitmaintainer-handbook.md §3–§6.

| Command | Role |
|---------|------|
| `/work [#issue]` | Start or resume the body-of-work branch; optionally link issues (status → In Progress, assign, dump context for Claude). |
| `/checkpoint` | Local save point; folded into the next `/commit` or `/ship-main`, never pushed. |
| `/commit` | Conventional commit (emoji + type), typecheck-gated, push. Asks which linked issues are code complete (status → Staged). |
| `/catchup` | Pull `main` into the feature branch. |
| `/open-pr` | Gate: every linked issue must be code complete. Push, open PR with `Closes #N` (status → Staged), trigger advisory review. |
| `/merge` | Verify gate green, squash-merge, land on `main`. **Does not deploy.** |
| `/deploy` | The release boundary — see §1.3. |

Design choices baked in:

- **Changelog is local, not a CI action.** Claude composes it during `/deploy` from commit subjects since the last tag, applying editorial rules (filter `refactor`/`style`/`test`/`docs`/`chore`, rewrite internals as user-facing prose) that template tools (release-please) can't. Single-writer (`/deploy` only) eliminates duplicate-bullet bugs. No `ANTHROPIC_API_KEY` secret, no runner. §2.3 / §2.4.
- **Version bump is local, not auto-on-merge.** See §1.3 — auto-bump-on-merge is a NEVER-restore anti-pattern.
- **PR title is the conventional-commit source.** Squash merge sets the squash commit = PR title; `commitlint` validates the **title only** (not branch commits — machine-generated PRs produce malformed branch commits with clean titles). The title drives the bump level. §3.1 / §3.1.
- **No persistent working branch.** After merge you're on `main`; next task gets a fresh descriptively-named branch. Branch-per-body-of-work is the entry model; kitmaintainer-handbook.md §3.2.

## 1.3 `/deploy` as a human-serialized release boundary

**`/merge` is not `/deploy`.** Multiple merges accumulate on `main`; a release ships everything since the last tag in one deliberate invocation.

`/deploy` does bump → changelog → tag → push → trigger-deploy in **one human-in-the-loop CLI run**, so the source-of-truth version field and the deployed artifact match **by construction**. The bump commit is **pushed directly to main** (require-PR off, the default — §1.1) — no release branch, no PR, no admin-merge; the bump commit + tag are the release record. Deploys are fired explicitly against post-bump HEAD — `aws codebuild start-build` under the `codebuild` backend, the fleet dispatched concurrently and polled together (§2.1). Full procedure in §2.1; trigger contract in §2.5.

**Why not auto-bump-on-merge** (the rejected pattern, NEVER restore):

| Failure | Cause |
|---------|-------|
| Pre-bump deploy | A push-to-main deploy ran parallel to the bump workflow and read `package.json` pre-bump → shipped wrong version. |
| Merge-vs-release lag | Tags landed after the merge on workflow scheduling; deploy fired on the bump commit, masking which change went live. |
| Adversarial commit-body parsing | Auto-bump scanning squash-commit bodies false-matched conventional markers / `BREAKING CHANGE` prose embedded in PR descriptions and upstream changelogs → wrong bump level shipped before a human could intervene. |

The lesson encoded throughout: **pipeline control signals read STRUCTURED metadata (commit subject line, `author.name`), never freeform body prose.** When a trap surfaces, fix the class, not the instance.

### Migration phase (gated, deploy step 1)

If a `MIGRATE_WORKFLOW` is configured, `/deploy` runs it **once, first, watched, and gated** before any app deploy fires — a real migration failure aborts the deploy before shipping app images against a half-applied schema. Solves two shapes:

- **Split-deploy monorepo** (e.g. a multi-app repo): the schema migration was duplicated inside all N app deploy workflows (no-op in the trailing N−1). Pulling it to one gated pre-step runs it exactly once.
- **Migrate-only repo** (a DB-maintenance service with no app artifact): `MIGRATE_WORKFLOW` set + `DEPLOY_WORKFLOWS` empty → deploy migrates with zero app workflows.

The migrate workflow body is project-owned and MUST exit 0 on a no-op and non-zero only on genuine failure (the orchestrator gates on run conclusion). **Never blanket `|| true`** — trap a specific no-op signal and re-raise everything else. Forward-only migrations keep old and new code compatible with the same schema (add column → use column → later remove column). See §2.1 "Migration phase" + the no-op-tolerant reference pattern.

## 1.4 Quality + security tools

| Tool | Role | Why |
|------|------|-----|
| **Biome** (CI lint) | Lint-only (formatter disabled), `recommended` preset. The kit owns `biome.base.json`; a project's `biome.json` extends it and adds its own plugins and settings. The base carries the kit's GritQL plugin `biome-plugins/server-fn-logging.grit`, which fails a TanStack Start server-function handler not wrapped in `logFailures`. | AI-authored JSX omits a11y patterns (training data omits them); `any` blinds the type info AI reasons from. Formatter off because a 100%-AI codebase has no human formatting concern and enabling it produces a giant normalization diff. Fix violations in source, suppress only as last resort (constitution §XIII). |
| **Semgrep CE** (CI SAST) | `--config auto`, ~10s. Mandatory `.semgrepignore`. | Free, 1000+ rules. The ignore file is mandatory, not optional — generic secret-regex rules false-match base64 runs inside binary assets (PDF/EPS) and time out CI per file. Ship it with Semgrep, don't wait for the incident. §3.2. |
| **Gemini Code Assist** (advisory PR review) | Inline + summary on every PR, free for private repos. Triage via `/triage`. | Independent model family (most distinct second opinion from Claude). Reads `.claude/rules/*.md` + `.gemini/styleguide.md` as review context — cites constitution rules unprompted. Catches the structural-diff-defect class; complements (does not replace) tests. `/triage` walks its findings; config in §3.7. |
| **Dependabot** | Version + security PRs, monthly + cooldown + grouping. | Monthly batching (not weekly) because weekly is noise-dominant for a small shop. Cooldown (patch 3d / minor 7d / major 30d) dodges the 48–72h window where supply-chain attacks get caught and the bad version yanked; security fixes skip cooldown automatically. §3.3. |
| **Dependency policy** (`project-documentation/dependency-policy.md`) | One page: severity→timeline table, who owns it, exceptions with review dates, and the weekly triage runbook. | The kit shipped Dependabot config and a triage skill but never the operating procedure — so nobody knew what to do with the output, and nobody did anything. Synced `merge` mode: the owners, timelines and project-notes regions are each client's own. §3.5. |
| **dep-alignment** (CI gate, Node-only) | Fails a PR if any shared dependency is declared at more than one version across workspaces. Node-gated in `ci.yml`, no-op on single-package / Python-only repos. | A monorepo runs ONE stack; cross-app version skew causes "works in one app, breaks in another" outages Dependabot *creates* (it bumps each manifest independently). Reads `package.json` only, no install. §3.6 / dependency-management.md. |
| **knip** (CI gate, Node-only, per project) | Fails a PR on unused files, exports, types and dependencies, and on imports of packages a workspace never declares. One kit-owned `knip.config.ts`; the project turns the gate on with `KNIP_GATE`. | AI-written code accretes exports, files and dependencies nothing uses, and every one is context the next change reads as live. Neither the type-checker nor Biome sees across workspaces. §3.9. |

**Rejected, and why** (terse — empirical, not theoretical):

| Rejected | Why |
|----------|-----|
| CodeRabbit (Pro or free-CLI) | Pro's one paid-worthy feature (cross-file code-graph) is made redundant by constitution §XIV (every signature change updates all callers in the same edit). Free tier degrades to summary-only post-trial + manual CLI invocation. |
| Sourcery | Paid, yet missed defects the free options caught; high false-positive rate; broken-on-push re-review; bundled security scan duplicates Dependabot. |
| Snyk | Redundant with Dependabot + surfacing + Semgrep at small-shop scale. Upgrade path is a 5-seat-minimum cliff. |
| Socket.dev | Zero unique signal above Dependabot on a clean codebase; free tier truncates the dep tree; adds per-release triage cost. |

**CI (`ci.yml`) runs every check that can tell, and fails rather than passing unlooked.** A `detect` job names the stacks present and notes the ones it skips. The `check-types` job applies when `package.json` declares `check-types` or the repository has TypeScript sources (`.ts`, `.tsx`, `.mts`, `.cts` outside `node_modules`, `.claude` and `dist`; the kit's `knip.config.ts` does not count) — then a missing script fails it; otherwise it passes saying check-types does not apply, and the commit gate does the same. The `biome` job runs `lint:tokens` and `lint:design` whenever `design.md` exists at the repository root, and a missing script fails it. The `vitest` job always runs a declared `test` script; without one it fails when the root package or a workspace holds a vitest config or a `*.test.*` / `*.spec.*` file, and otherwise passes saying it does not apply — tests inside a nested directory with its own `package.json` that is no workspace belong to that package. It also fails when the repository has `*.integration.test.ts` files and the `NEON_API_KEY` or `NEON_PROJECT_ID` secret is empty, because the integration project would otherwise drop out and the run pass green; Dependabot PRs, which GitHub runs without secrets, are the exception. The `python` job typechecks from the repository root whenever a root `pyproject.toml` or `pyrightconfig.json` exists, with the commit gate's choice of checker — pyright, else mypy — and fails on any error. Pyright is the stack manifest's pin (`pyright`, `installedBy: ci`), installed over any version the project declares; the commit gate runs the pyright installed locally and warns when it differs from the pin. The `knip` job runs knip when `KNIP_GATE` is `"true"`, passes with a notice when the project has decided against the gate, passes with a warning while the key is undecided, and fails on any other value (§3.9). The `project` job holds the repository's own CI steps in its `project-steps` region, which sync carries across kit updates.

**Revisit threshold for the rejected dep-security tools:** a real supply-chain incident slipping through Dependabot + cooldown + surfacing + Semgrep. The kit's cross-file caller analysis (what paid review vendors charge for) is handled in-house by constitution §XIV at edit time.

## 1.5 Testing model

**Philosophy:** test real code against real data. Mocks only where unavoidable (auth — a session concern, not business logic). Priority on logic that produces predictable, verifiable output where a silent change ships wrong results — not "feel-good" coverage.

| Tier | Tooling | What | Gate |
|------|---------|------|------|
| Unit | Vitest | Pure functions with complex, predictable output (pricing math, packing algorithms, financial totals). Synthetic fixtures, in-memory. | CI hard gate |
| Integration | Vitest (`integration` project) | Real server functions against a **real ephemeral Postgres branch** — one branch per run, forked copy-on-write from production, deleted after. Each test runs in an always-rolled-back transaction (`dbTest`), so tests run in parallel MVCC-isolated on the shared branch. Catches wrong queries, missing columns, constraint violations, broken joins. | CI hard gate |
| Migration-during-PR | drizzle-kit in `globalSetup.ts` | A PR's pending migration runs once against the prod-schema branch before tests — the same drizzle-kit migrate that the deploy's migration build runs against production, validated in the same CI pass. | CI hard gate |
| E2E | Claude + `agent-browser` | Standalone `/e2e` **manual verification** — see below. | NOT a hard gate |

**Why real DB branches over mocks:** mocks drift from real database behavior — the exact failure the model is meant to catch. A branch is a copy-on-write clone of prod schema + data; tests insert/update/delete freely, prod is never touched. External services follow the same "real not mock" rule: Stripe Test Mode (real Stripe, no money — not a mock) and Mailpit (real SMTP capture) rather than network interception that drifts.

**E2E is a manual verification, not a hard gate (current reality).** The model is **Claude-as-intelligent-tester**: Claude drives `agent-browser` (via Bash, never MCP — MCP pollutes context with browser state) through plain-English flow files. Failure is **behavioral** — if Claude can't complete a flow (blank page, broken button, 404, hydration crash), that's the test. No `.spec.ts`, no test runner, no committed selectors. Flows are run by the `/e2e` skill and written + maintained by a companion `/e2e-author` skill (flow-file format + the agent-browser recipe library).

| Decision | Rationale |
|----------|-----------|
| NOT scripted Playwright/Cypress in CI | Maintenance tax: selectors break on every UI change; ~full-time job at scale; unrealistic for a small team. Infra (containerized app + branch + secrets) is significant and not load-bearing at this scale. |
| Manual verification, not hard gate | Cloud sessions can't run `agent-browser`, so a hard gate would be impassible. `/e2e` is a standalone command the user runs when they want it — it is not wired into `/merge`. Flow files declare `triggers:` globs; the `/e2e` skill scopes which flows run by intersecting with the current diff (docs-only diff → zero flows). |
| Behavioral failure detection | Tests the real stack (real Stripe test mode, real DB branch, real auth, real runtime) — catches the "all functions work but the page doesn't render" class scripted unit/integration tests miss. |
| Paired with production monitoring | Because E2E is a manual verification not an enforced barrier, Sentry + UptimeRobot provide post-deploy catch-up. |

Structured assertions are added by **accretion** — only when a specific failure class keeps slipping through does that step get codified as a structured `agent-browser eval` check. Default is behavioral. testing.md §2.

---

# Part 2 — Deploy

## 2.1 `/deploy` procedure (direct-push to main)

> **`/deploy` pushes the version bump DIRECTLY to `main`** — no release branch, no PR, no admin-merge. It reuses the same direct-to-main mechanism as `/ship-main` (`.claude/commands/ship-main.md`). The bump commit + tag ARE the release record. This works because the pipeline uses no branch protection and `main` does not require a PR (§1.1, new-project-setup.md step 3). No command admin-merges: `/deploy` direct-pushes the bump, and `/sync-dev-kit` does no git at all (it stamps the lockfile and leaves the synced files for the user to land via `/ship-main`). So `enforce_admins: false` is not required by anything.

`/deploy` is the **human-serialized release boundary**: bump and deploy fire in one invocation, in order, so the source-of-truth version and the deployed artifact match by construction — no skew. The bump commit lands on `main` moments before the deploy is dispatched; the deploy reads the just-bumped source. (See §2.6 for why auto-bump-on-merge is forbidden.)

File: `.claude/skills/gitflow/scripts/deploy.sh`. Slash command spec: `.claude/commands/deploy.md`.

**Procedure:**

1. **State gates** (refuse to run if any fail):
   - On `main`
   - Working tree clean
   - Local `main` == `origin/main` (no stale local; nothing un-pushed)
   - HEAD's required check-runs are not `failure` / `timed_out` / `cancelled`
   - At least one commit since the last `v*.*.*` tag

2. **Bump-level inference** (Claude does this in `/deploy` Step 2 before invoking the script):
   - Scan SUBJECT lines of commits since last tag
   - `<type>!:` or `BREAKING CHANGE:` footer → major
   - `feat(...):` → minor
   - `fix(...):` / `perf(...):` / `refactor(...):` → patch
   - `chore(...):` / `docs(...):` / `test(...):` / `style(...):` / `ci(...):` / `build(...):` → patch (Option B — chore counts as a release)
   - Highest wins. NEVER skip the bump when there are commits to deploy.

3. **Changelog entry** (Claude generates from commit subjects since last tag, applying `references/changelog-rules.md`): one or more bullets in `- **<emoji> <Title Case>** - <user-impact>` form. Group related fixes. Pure infra commits get a single `Dependency Updates` / `Internal Tooling` line.

4. **Script execution** (`deploy.sh --level <patch|minor|major> --changelog-file <path>`):
   - `npm version <level> --no-git-tag-version` (Node) or `sed` rewrite of `version = "x.y.z"` (Python)
   - Insert changelog entry under today's date header in `changelog.md`
   - Commit bump + changelog ON `main` as `🚀 release: v<NEW>` (`--no-verify`; validation already ran)
   - **Push `main` directly** to origin. If `origin/main` advanced, rebase the bump commit onto it and re-push; on conflict, stop and surface for resolution. The bump commit + tag are the release record — no release branch, no PR, no admin-merge.
   - `git tag v<NEW> <bump-sha>` and `git push origin v<NEW>` (tags aren't gated by `branches/*` protection rules; tag-protection rules are separate and only need configuration if cross-account tag pollution is a concern)
   - **Migration phase (if `MIGRATE_WORKFLOW` is set):** dispatch the migration — `aws codebuild start-build` on the migrate project under the default `codebuild` backend, `gh workflow run <migrate-wf> --ref main` under `github` — then watch it to completion **gated**: a real migration failure aborts the deploy here (exit 18 trigger / 19 run) BEFORE any app deploy is dispatched. Always watched, even under `--no-watch` (that flag only governs the app-deploy watch). Deploying app images against a failed/half-applied schema is the failure mode this gate exists to prevent. **Skipped entirely** when `MIGRATE_PATHS` is set and `git diff --name-only <last-tag>..HEAD -- <MIGRATE_PATHS>` is empty (no migration files changed since the last deploy) — no build is started. See the **Migration phase** subsection below.
   - For each service in `DEPLOY_WORKFLOWS` (resolved via the per-project `.claude/sync-substitutions.json`; falls back to `deploy.yml` if unset AND no `MIGRATE_WORKFLOW`), dispatch its deploy against post-bump HEAD — `aws codebuild start-build` on `<CODEBUILD_PROJECT_PREFIX><service>` under `codebuild`, `gh workflow run <wf> --ref main` under `github`. A migrate-only repo (`MIGRATE_WORKFLOW` set, `DEPLOY_WORKFLOWS` empty) stops after the migration phase — no `deploy.yml` fallback.
   - Watch the deploys (unless `--no-watch`): under `codebuild` the fleet is polled together and every build's status is reported before a failure exits; under `github` each run is watched in turn with `gh run watch`.

5. **Reporting**: success → report `v<NEW>` + the build (or workflow run) URL. Failure modes (state gates, bump, push, tag push, deploy dispatch, deploy build, migration trigger/run) all exit non-zero with specific codes — Claude surfaces the code + stderr and stops. Exits 18 (migration trigger failed) / 19 (migration run failed or run-id unresolved) abort before any app deploy.

**What `/deploy` does NOT do:**
- Does NOT run a CI, lint, typecheck or build pass — those gates already fired on the merged feature PRs, and `/merge` owns the production build gate while the PR is still open. A `/ship-main` commit reaches `/deploy` with no gate by design.
- Does NOT open a release PR or admin-merge anything — the bump commit pushes straight to `main` (require-PR off, the default). `/deploy` no longer needs `enforce_admins: false`.
- Does NOT auto-bump on every feature-PR merge (the bot-PR pattern caused version-skew; see §2.6).
- Does NOT infer the changelog from PR descriptions — uses commit subjects since last tag.

**`/sync-dev-kit` does NO git.** Sync only applies the accepted kit updates to the working tree and stamps the lockfile — it does not commit or push. The synced files are left uncommitted; the user lands them with `/ship-main` (or `/commit`). Committing is gitflow's job, not sync's — see kitmaintainer-handbook.md §9.4.1.

**Migration audit when adopting direct-push deploy:** `/sync-dev-kit` brings `deploy.sh` (direct-push, no release branch / PR / admin-merge) + `commands/deploy.md`. Consumer-side checks:
1. Confirm `main` does not require a PR (the default — pipeline.md §1.1). With require-PR on, the direct push to main is rejected.
2. Confirm `.commitlintrc.json` includes `"release"` in `type-enum` (the `🚀 release:` subject still flows through the bump-level scan).
3. Confirm every name in `DEPLOY_WORKFLOWS` has a dispatch target: under `codebuild`, a CodeBuild project named `<CODEBUILD_PROJECT_PREFIX><service>`; under `github`, a workflow whose ONLY trigger is `workflow_dispatch:` (§2.5) — push-to-main and tag-push triggers would double-fire.

**Split-deploy consumers (`DEPLOY_WORKFLOWS` substitution).** The substitution lives in `.claude/sync-substitutions.json` (runtime-read by `deploy.sh` via `jq`, NOT placeholder-substituted into any kit template). Format: space-separated workflow filenames, e.g. `"deploy-shop.yml deploy-dealer.yml"`. Behavior:
- Empty / missing → `deploy.sh` falls back to `deploy.yml`.
- Populated → `deploy.sh` dispatches every listed service: concurrently under `codebuild`, one watched run at a time under `github`.
- Bare service names on the command line (`/deploy worker`) or the repeatable `--workflow <name>` flag override the substitution for one invocation — useful for re-firing a single service after a partial failure.

**Migration phase (`MIGRATE_WORKFLOW` substitution).** A single workflow that `/deploy` runs as **step 1** — once, before any app deploy, watched to completion and gated. Solves two problems: (a) in a split-deploy monorepo, the schema migration was duplicated inside all N app deploy workflows (no-op in the trailing N−1, but present "in case one runs alone"); pulling it to a single gated pre-step runs it exactly once; (b) a DB-only repo (no UI / no app artifact — e.g. a service that maintains a database for a legacy app) can `/deploy` to migrate with zero app deploys.

- Substitution lives in `.claude/sync-substitutions.json` (runtime-read by `deploy.sh` via `jq`, NOT placeholder-substituted). A single `migrate.yml`-shaped name: under `codebuild` it maps to the migrate project by prefix (or `CODEBUILD_MIGRATE_PROJECT`), under `github` it is the workflow filename. `--migrate-workflow <file>` CLI flag overrides it.
- Empty / missing → no migration phase (prior behavior; any migration stays inline in the app deploy workflows).
- Set → `deploy.sh` dispatches it and waits for it to finish. Real failure → exit 19, deploy aborts before any app deploy.
- `MIGRATE_WORKFLOW` set + `DEPLOY_WORKFLOWS` empty → **migration-only deploy** (no `deploy.yml` fallback). This is the DB-maintenance-repo shape.
- Migration is **never invoked on its own** — there is no `/migrate` command. It exists only as deploy's first phase (you would never migrate without deploying). The migrate project (or, under `github`, the migrate workflow's `workflow_dispatch:` trigger) is purely the mechanical hook `deploy.sh` uses to fire it.

**Migration-skip (`MIGRATE_PATHS` substitution).** The migration *step* is already idempotent (drizzle-kit skips applied migrations), but dispatching it at all costs ~2 min — build boot + `npm ci` just to reach a no-op. `MIGRATE_PATHS` lets `deploy.sh` decide *locally, before starting any build* whether the migration is worth dispatching.

- Space-separated git pathspec(s) naming where migration files live (drizzle: `apps/shared/src/db/migrations`; Prisma: `prisma/migrations`; Alembic: `alembic/versions`). **Multiple paths supported** — a repo with several databases lists every migration dir; the workflow fires if *any* changed. Runtime-read from `.claude/sync-substitutions.json`; `--migrate-paths <path>...` overrides.
- Before firing `MIGRATE_WORKFLOW`, `deploy.sh` runs `git diff --name-only "$LAST_TAG"..HEAD -- $MIGRATE_PATHS`. **Empty → skip the workflow entirely** (nothing to apply). Non-empty → fire as normal.
- **The reference is `LAST_TAG` — the PREVIOUS deploy's tag, captured at the state gate before this run creates its own tag.** This is load-bearing: a fresh `git describe` at the migrate step would return *this run's* just-pushed tag, making the diff empty every time → always-skip (silently broken). Never recompute it.
- Empty / missing `MIGRATE_PATHS` → **no skip; the workflow always fires** (prior behavior). The skip is strictly opt-in per project.
- **Safe under the failed-migration recovery model.** If a prior deploy's migration failed, that deploy's tag still exists → re-running `/deploy` stops at the "no commits since tag" gate, forcing the documented manual recovery (which applies the migration); the migrate workflow stays idempotent as the backstop. The only way to skip a genuinely-pending migration is to actively ignore a failed deploy and force past its abort — operator error, not a design hole. `git diff` failure → exit 20 (fail-loud, never skip on an errored check).
- Does **not** reorder anything: the bump/changelog/tag block stays before the deploy, exactly as it must (the app image bakes in `package.json`'s version + changelog, so the bump has to precede the build). The skip is a guard in front of the migrate trigger, nothing more.

**Dispatch backend (`DEPLOY_BACKEND` substitution).** Which compute `/deploy` dispatches to. **`codebuild` is the default and the stance.** It starts AWS CodeBuild projects via `aws codebuild start-build`, so everything that touches AWS runs on AWS compute — no workflow holds an AWS credential, and the only remaining GitHub dependency is the git clone. `github` fires GitHub Actions workflows via `gh workflow run`, and stays in the script because a repo deploying somewhere with no AWS account behind it has nowhere to put a build project.

Two more values exist so a project can state the truth rather than be read as an unprovisioned `codebuild`. **`custom`** means the project DOES deploy, by a procedure `/deploy` does not dispatch — an SSH push to a box, a hosting provider's own CLI, a hand-run script. **`none`** means it does not deploy at all; the kit itself is the example. Both stop `deploy.sh` at exit 2 before any bump, commit or tag, so nothing is released and the message says which of the two it was.

The key answers exactly one question — what else must be set — and nothing more. `codebuild` needs the `aws` CLI, `CODEBUILD_PROJECT_PREFIX` and `AWS_REGION`; `github` needs `gh` and real `workflow_dispatch:` workflows; `custom` and `none` need nothing. That is why `custom` is not split by transport: the shape of a bespoke deploy belongs in the project's own deploy script and its rule under `rules/project/`, where it can actually be run, not in a config value that only ever gets compared for equality.

- **`DEPLOY_WORKFLOWS` stays the single service list on both dispatching backends.** Under `codebuild` a filename maps to a project by `CODEBUILD_PROJECT_PREFIX` — `deploy-worker.yml` with prefix `myapp-deploy-` is project `myapp-deploy-worker`. There is deliberately no second list to drift out of step with the first. `CODEBUILD_MIGRATE_PROJECT` names the migration project when it does not follow that pattern.
- **The backend is read from a per-consumer substitution, never sniffed from the repo.** A release boundary must not guess where it is shipping from. An unset or empty key lands on `codebuild` and then fails loud (exit 2, before any bump) if the project has not provisioned for it — it never silently ships through the other backend.
- **Under `codebuild` the fleet is dispatched concurrently and polled together**, where `github` watches each run in turn — a six-service release costs the slowest service rather than the sum of all six. A single non-`SUCCEEDED` build fails the release (exit 13), and every build's status is reported first so one broken service does not hide the others'.
- **The migrate gate is identical on both dispatching backends:** watched to completion, a real failure aborts (exit 18 trigger / 19 run) before any app ships.
- `codebuild` requires the `aws` CLI (exit 8 without it) and `CODEBUILD_PROJECT_PREFIX` (exit 2 without it). Any other value for the key fails loud with exit 2 — before any bump, tag or push.

**The migrate-build body contract (project-owned).** The kit owns the *orchestration*; the migration's *body* — the migrate buildspec under `codebuild` — is project-specific (the kit ships none — deploys aren't generalizable). The body MUST:

1. Run the project's migration command against the **production** database (e.g. `drizzle-kit migrate` with the prod `DATABASE_URL` read from Parameter Store by the CodeBuild service role). Run it standalone — `drizzle-kit migrate` needs only the DB URL and the migration files, not a running app container. On Neon, read the **direct** (non-pooled) endpoint: the pooler runs in transaction mode and does not hold the session-level advisory lock drizzle-kit takes, so a pooled URL can half-apply a migration instead of failing cleanly. Validate the value's shape before using it, and never echo it.
2. **Exit 0 on a no-op** (no pending migrations) and **non-zero only on a genuine failure.** `drizzle-kit migrate` is idempotent and on the documented happy path exits 0 when there's nothing to apply — but verify your `drizzle-kit` version's actual no-op exit behavior, because the orchestrator gates purely on the build's conclusion: a spurious non-zero will (correctly, per the contract) abort the deploy. If your command false-fails on no-op, trap it in the command rather than letting the build report failure:

   ```yaml
   # buildspec reference pattern — adapt the no-op signal to YOUR command/version (verify first)
   build:
     commands:
       - |
         if ! out=$(npm run db:migrate 2>&1); then
           # only swallow the verified no-op signal; re-raise everything else
           if printf '%s' "$out" | grep -qiE 'no (pending )?migrations|nothing to (migrate|apply)|already applied|up to date'; then
             printf '%s\n' "$out"; echo "no pending migrations — treating as success"
           else
             printf '%s\n' "$out" >&2; exit 1
           fi
         else
           printf '%s\n' "$out"
         fi
   ```

   Do NOT blanket `|| true` the migration — that swallows real failures and defeats the gate. The trap must match a *specific* no-op signal and re-raise anything else.

See `commands/deploy.md` for the full slash-command spec.

## 2.2 Version bump semantics

Applied at `/deploy` time across the SUBJECT lines of all commits since the last `v*.*.*` tag. Highest match wins.

| Subject pattern | Bump |
|-----------------|------|
| `<type>!:` or `BREAKING CHANGE:` footer | major |
| `feat(...):` | minor |
| `fix(...):`, `perf(...):`, `refactor(...):` | patch |
| `chore(...):`, `docs(...):`, `test(...):`, `style(...):`, `ci(...):`, `build(...):` | patch (Option B — chore counts as a release) |
| Anything else | patch |

Option B intentionally treats `chore` as patch-bumping. Rationale: `chore(deps): bump foo` IS a release-worthy change — the deployed artifact has new dependencies. Skipping bump on `chore` would ship a new artifact under an unchanged version, breaking version-as-build-identity.

NEVER skip the bump when there are commits to deploy. "Deploy + no version change = lie."

## 2.3 Changelog ownership (single writer = `/deploy`)

**`changelog.md` has exactly one writer: `/deploy`.** No CI workflow, no `changelog.yml`, no per-PR entries on feature branches. Claude composes the consolidated release entry locally during `/deploy` from commit subjects since the last `v*.*.*` tag and applies `skills/gitflow/references/changelog-rules.md` to filter and rewrite. `deploy.sh` then inserts that entry under today's date header in `changelog.md` as part of the bump commit pushed directly to `main`.

**Why single-writer.** Feature-PR scripts do not touch `changelog.md` at all — the only place a `--changelog-file` is consumed is `deploy.sh` (there is no such flag on `open-pr.sh`). A single writer is what prevents duplicate bullets landing under the same date header.

**What this means for slash-command flow.**
- `/open-pr` does not write to `changelog.md`. It pushes the branch and creates the PR, full stop.
- `/merge` does not write to `changelog.md`. It squash-merges the feature PR.
- `/deploy` is the only command that touches `changelog.md`. The entry covers every commit since the last tag — typically multiple feature PRs grouped into one release.

**Cost vs. value.** Per-PR entries had no consumer (the only readers of `changelog.md` see the consolidated release entries). The CI cost was nonzero (Claude API per PR) and the duplication tax compounded across every release. Removing it loses no information.

## 2.4 Changelog generation (not a workflow)

Changelog generation is NOT a GitHub Action and has exactly one writer: `/deploy`. Claude composes the consolidated release entry locally during `/deploy` from commit subjects since the last `v*.*.*` tag. `deploy.sh` inserts that entry under today's date header in `changelog.md` as part of the bump commit pushed directly to `main`. Feature-PR scripts (`commit.sh`, `open-pr.sh`, `merge.sh`) do not touch `changelog.md`.

Rationale:
- Zero CI infrastructure (no `changelog.yml`, no `ANTHROPIC_API_KEY` secret, no runner dependency).
- `changelog-rules.md` requires editorial intelligence (filter `refactor/style/test/docs/chore`, rewrite internals as user-facing prose) that template tools like release-please cannot provide.
- Single-writer eliminates the duplicate-bullet bug from the earlier two-writer design (one entry per feature PR + one per release = two copies of the same line in main). See §2.3.

**Procedure (`/deploy`):**
1. `/deploy` lists conventional commit subjects since the last `v*.*.*` tag.
2. Claude applies `changelog-rules.md` to generate one or more bullets in `- **<emoji> <Title Case>** - <user-impact>` form. Pure infra commits collapse to a single `Internal Tooling` / `Dependency Updates` line.
3. Claude writes the entries to a tempfile and invokes `deploy.sh --changelog-file <path>`.
4. The script inserts the entry under today's date header in `changelog.md`, bumps the manifest version, commits everything as `🚀 release: v<NEW>` on `main`, and pushes `main` directly (require-PR off, the default — no release branch, no PR; see §2.1).
5. The script deletes the tempfile on success.

There is no `--no-changelog` mode and no `--changelog-file` flag on `open-pr.sh`. Releases without user-facing entries still get a one-line `Internal Tooling` bullet — every release commits exactly one new bullet, never zero.

**MANDATORY changelog format — Keep-a-Changelog:**

`deploy.sh` inserts entries by anchoring on standard Keep-a-Changelog landmarks. The consumer project's changelog MUST conform on adoption:

```markdown
# <Project> Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## 2026-05-06

- **🐛 Tracking Number Whitespace** - User-facing description of the fix.

## 2026-04-28

- ...
```

Required:
- An `## [Unreleased]` h2 placeholder after the preamble. `open-pr.sh` anchors new dated sections after this line.
- Date headers as **h2 with ISO-8601 dates**: `## YYYY-MM-DD` (e.g., `## 2026-05-06`). An `### Month Day, Year` (h3, long-form) format is NOT supported — `open-pr.sh`'s Python insertion falls through and appends at EOF, producing an out-of-order changelog.
- Entries as `- **<emoji> <Title Case>** - <user-impact>` bullets.

Adoption migration for projects with non-conforming changelogs: convert all date headers to `## YYYY-MM-DD`, add `## [Unreleased]` placeholder. The renderer (if any) can preserve the prior visual style by swapping the h2/h3 component CSS.

See `commands/open-pr.md`, `commands/deploy.md`, and `skills/gitflow/references/changelog-rules.md`.

## 2.5 Deploy trigger contract (MANDATORY)

**A deploy starts only when `/deploy` dispatches it.** Nothing about a push, a tag, a merge or a schedule may start one.

- **`codebuild` (the default):** every deploy and migrate CodeBuild project has **no source webhook and no schedule**. `deploy.sh` starts it with `aws codebuild start-build` against post-bump `main`.
- **`github`:** every deploy and migrate workflow's ONLY trigger is `workflow_dispatch:`. `deploy.sh` fires it with `gh workflow run <wf> --ref main`.

```yaml
on:
  workflow_dispatch:
```

**Why dispatch ONLY:**

A trigger on tag push double-fires: `/deploy` creates the tag AND dispatches the deploy, so a tag-triggered build runs twice.

A trigger on push to `main` reintroduces the pre-bump race (the deploy reads `package.json` before the bump) and makes *every* `/merge` ship, not just the merges the user intends as a release. `/merge` is not `/deploy` (§2.1).

**The contract:**

```
/merge       → squash commit lands on main           → NOTHING fires
/merge       → squash commit lands on main           → NOTHING fires
/deploy      → bump + tag + push + dispatch          → each deploy fires once
                                                        against post-bump HEAD
                                                        with correct version
```

Multiple merges between deploys are normal. The deploy ships everything since the last release tag in one bump.

**What goes inside the deploy is consumer-specific** — build, ECR push, host rollout, verification. The kit ships no buildspec or `deploy.yml`, only this contract and the body pattern in §2.7.

**Audit when adopting `/deploy`:** a CodeBuild project with a webhook or an EventBridge schedule attached, or a workflow with any of these, must lose it:

- `on: push:` (any branches or tags)
- `on: schedule:`
- `on: workflow_run:`
- `if: !contains(github.event.head_commit.message, 'chore: bump version')` — dead code under dispatch-only; remove it

If the deploy does anything that needs a "fire automatically on X" hook, that work belongs somewhere else, not in the deploy.

## 2.6 Anti-pattern: never auto-bump the version on merge

Version bump + tag live in the local `/deploy` command (§2.1), never in a CI workflow or a release-bot. Do NOT introduce auto-bump-on-merge — a `version-bump.yml` workflow or a release-bot PR. It fails three ways:

- **Version skew** — the bump trails the feature merge by a cycle, so the version on `main` doesn't match the deployed code.
- **Pre-bump deploys** — a push-triggered deploy races the bump workflow and ships the wrong version.
- **Adversarial body parsing** — scanning commit *bodies* for `BREAKING CHANGE` / conventional markers false-matches prose embedded in PR descriptions. Pipeline control signals read STRUCTURED metadata (commit subject, `author.name`), never freeform body text.

## 2.7 Deploy buildspec body pattern (build → push → roll out)

The kit ships no buildspec — deploy targets vary per project — so each consumer authors its own, dispatched only by `/deploy` (§2.5, §2.1).

**One deploy buildspec per project, one CodeBuild project per service.** Every service's project points at the same `infra/codebuild/buildspec.yml` and sets its own environment variables (service, image name, Dockerfile, SSM path, health port). A change to the build shape is made once; each service still fails in isolation.

Body shape:

- **`install`** — the session-manager-plugin (the rollout reaches the host through SSM), and a `docker buildx` builder.
- **`pre_build`** — assert the ECR repository and its lifecycle policy exist (§2.7.1, `new-project-setup.md` §7a), verify the client build-time variables (`infrastructure.md`), log in to ECR.
- **`build`** — `docker buildx build --target production`, pushed tagged `latest`, the short sha and a timestamp, with a registry build cache. Base images come from the ECR Public mirror (`infrastructure.md`).
- **`post_build`** — reach the host by **instance id** over SSH with an `aws ssm start-session` `ProxyCommand` (no inbound `:22`), take a host-side `flock` so concurrent service rollouts serialize, `docker compose pull <service>` then `docker compose up -d --force-recreate --no-deps <service>`, and poll the service's `/health` until it answers, dumping its logs if it never does.

Selective per-app deploy (rebuild only apps whose files changed) is NOT part of the model — `/deploy` ships everything since the last tag in one intentional release; `/deploy <service>` is the explicit way to ship less.

### 2.7.1 New-container provisioning checklist (ECR)

Adding a NEW container/service to a consumer's docker-compose has TWO AWS-side
prerequisites that fail with the same opaque error when missed — a `403 Forbidden`
on a blob/manifest HEAD during push or pull (ECR returns 403, not 404, for both
missing repos and unauthorized ones):

1. **Create the ECR repository together with its lifecycle policy (one-time, manual — the
   CodeBuild service role intentionally lacks `ecr:CreateRepository` and
   `ecr:PutLifecyclePolicy`):**

   ```bash
   aws ecr create-repository --repository-name <prefix>-<service> --region <region>
   ```

2. **IAM policies must be PREFIX-scoped, never enumerated.** Both the CodeBuild
   service role's push policy AND the host's pull role must use
   `arn:aws:ecr:<region>:<acct>:repository/<prefix>-*` as the resource — an
   enumerated ARN list means every new container needs TWO policy edits that
   nobody remembers — producing a push 403 from the enumerated push policy and a
   pull 403 from the enumerated EC2 pull role.
   Include `ecr:DescribeRepositories` in both so the guard step below works.

3. **The deploy buildspec asserts both in `pre_build`**, before ECR login, so a
   missing repository or policy surfaces as an actionable error instead of the 403.
   The guard, the read-only grants it needs and why it must tell a missing policy
   from a missing permission are in `new-project-setup.md` §7a.

The kit ships no buildspec (§2.5), so this is adoption guidance: audit existing
consumers' push/pull policies for enumerated ARNs once, and keep the guard in every
deploy buildspec. Checklist row: E67.

## 2.8 `/deploy` failed or didn't ship

`/deploy` is fully local. If it exits non-zero, the script reports the exit code:

- `2`: bad args
- `3`: not on main → `git checkout main`
- `4`: dirty working tree → `/commit` first
- `5`: out of sync with origin → `git pull` or push pending work
- `6`: HEAD has failed CI check-runs on GitHub → fix CI on main first
- `7`: no commits since last `v*.*.*` tag → nothing to deploy
- `8`: a required CLI is missing — `gh`, or `aws` under the default `codebuild` backend
- `9`: `npm` / `python3` missing
- `10`: `npm version` / manifest-mutation failed
- `11`: push rejected → is require-PR off for this repo? (require-PR on `main` rejects direct pushes; the pipeline expects it off — pipeline.md §1.1)
- `12`: dispatching a deploy failed → under `codebuild`, does the CodeBuild project `<CODEBUILD_PROJECT_PREFIX><service>` exist and may the deploy-trigger credential start it? Under `github`, does the workflow exist on the default branch with `workflow_dispatch:`?
- `13`: a deploy build failed → open the build URL the script printed (CodeBuild console, or the Actions run under `github`) and read its log
- `17`: tag push failed → check tag-protection rules
- `18`: the migration could not be dispatched → same checks as `12`, for the migrate project
- `19`: the migration failed → nothing app-side shipped; fix the migration, then re-dispatch the migration and the deploys by hand (`commands/deploy.md` Recovery) — never deploy apps against a failed migration
- `20`: the `MIGRATE_PATHS` diff failed → the skip check errored, so nothing was skipped silently
- `21`: the deploy-trigger AWS credential in `.env` is missing or invalid → fix it (`new-project-setup.md` §7c); caught before anything mutated

A deploy build that fails after the migration ran leaves the new schema under the old code. Read the build log first: a failure outside the code — a registry rate limit, a transient network error — is fixed by re-dispatching the same builds, with no new bump and no second migration.

---

# Part 3 — CI and repository config

The workflow and config templates reach a project with the kit and land in `.github/`, `.gemini/` and the repo root. The files in the project are authoritative; the snippets here are documentation.

## 3.1 `commitlint.yml`

**PR-title validator (conventional commits). Title ONLY — not branch commits.**

Fires on `pull_request: opened/edited/synchronize/reopened`. Pipes the PR title through `@commitlint/cli` with the repo's `.commitlintrc.json` config. No third-party action — just `actions/checkout` + `actions/setup-node` + an inline `npx commitlint`.

**Why title-only:**
- Consumer repos squash-merge with `commit title = PR_TITLE`. The squash commit that lands on `main` IS the PR title; branch commits are discarded.
- Nothing local validates a commit message: `/commit` and `/ship-main` compose a conventional one from `references/commit-types.md`, and the scripts commit what they are given. A `/ship-main` commit reaches `main` with no PR, so this check never sees it.
- Machine-generated PRs (Dependabot, Renovate) produce malformed branch commits on a regular basis. Dependabot specifically double-scopes `chore(deps)(deps):` even when `include: scope` is absent from `dependabot.yml`. Linting those branch commits blocks merges that would land as clean squashes.

**Do NOT swap in a commitlint action that lints every commit in the PR** (`wagoid/commitlint-github-action` and similar do this by default). It rejects Dependabot PRs whose branch commits don't conform even when the PR title is clean, and the branch commits never reach `main`.

**Required `permissions:` block.** The workflow declares `permissions: { contents: read, pull-requests: read }`. Kept even though the inline approach only reads `github.event.pull_request.title` — cheap, documented, explicit.

**Job name kept as `lint`** so the GitHub status check name stays `commitlint / lint`. `/merge` self-gates by reading the PR's check-runs by name; renaming the job changes the check name and can let a merge slip through without the gate seeing it.

**`.commitlintrc.json` requires a custom `parserPreset`.** The gitflow commit format is emoji-prefix (`✨ feat: ...`, `🐛 fix: ...`), which stock `@commitlint/config-conventional` rejects because its default `headerPattern` expects the type token at position 0. The template ships a `parserOpts.headerPattern` that tolerates an optional leading emoji cluster before the type. Keep this in sync with the commit format in the gitflow skill's `references/commit-types.md` — if the commit format changes, the parser regex must change too.

## 3.2 `.semgrepignore` (MANDATORY when adopting Semgrep)

Semgrep walks every tracked path by default. In any repo with design assets, reference documents, or other binaries under version control, generic secret-regex rules (`detected-private-key`, `detected-github-token`) match base64-ish noise inside EPS/PDF/PSD binary streams and fire per-file timeouts. A repo carrying a few hundred PDF/EPS brand assets times out on every Semgrep CI run until `.semgrepignore` excludes them.

The kit seeds `/.semgrepignore` when a project is set up. Scope includes `project-documentation/`, `docs/`, design binaries (pdf/eps/ai/psd/indd/sketch/fig/xd), raster/vector images, video/audio, archives, fonts, build outputs, and lockfiles. Lockfiles excluded because Dependabot owns dep security — Semgrep scanning them is noise.

Ship this as part of Semgrep adoption. Do NOT wait for a timeout-warning incident to discover the need.

## 3.3 `dependabot.yml` (monthly + cooldown + grouping)

`dependabot.yml` schedules the PRs that Dependabot opens for version + security updates. Acting on those PRs is the `dependency-triage` pass (§3.4), under the policy in §3.5.

**Lives at** `.github/dependabot.yml`, arriving with the kit.

**Ecosystem coverage out of the box:**

| Ecosystem | Directory | Cadence | Cooldown (patch/minor/major days) | Grouping |
|---|---|---|---|---|
| `npm` | `/` (workspaces auto-detected) | monthly Monday | 3 / 7 / 30 | `npm-patch` + `npm-dev-minor` + `npm-security` — runtime majors open individually |
| `github-actions` | `/` (scans `.github/workflows/*.yml`) | monthly Monday | 3 / 7 / 14 | `actions-minor-patch` |
| `docker` | `/` (scans root for `Dockerfile*`) | monthly Monday | 3 / 7 / 30 | `docker-minor-patch` |

**Why monthly + cooldown** (design rationale — critical for a 2–10 engineer shop to understand before tuning):

Weekly cadence produces waves of ~9 PRs in a single day (majors, dev-majors, grouped batches, framework-track minors) — unsurvivable for a 2-person shop. Research evidence:

- **Matthew Hou (6-engineer team) — dev.to case**: weekly Dependabot = 40–60 PRs/week → turned it off, switched to monthly batched review + quarterly major audits. Post-change: dep incidents 3→0, review time 8hr/wk → 4hr/mo.
- **HN 647-pt thread** on Filippo's "Turn Dependabot off": mainline sentiment is "merge relentlessly OR turn off + do quarterly audits." Weekly is the worst of both.
- **GitHub's own `cooldown` feature** (introduced 2025): explicitly designed to delay PRs N days after a version ships so supply-chain attacks get caught and attacked versions get yanked before you merge them (Shai-Hulud / tinycolor incidents). Phoenix Security recommends 48–72h post-tinycolor. `semver-patch-days: 3, semver-minor-days: 7, semver-major-days: 30` is a defensible default.

Result: one monthly grouped wave per ecosystem + majors individually after 30-day cooldown. Review burden ~1 defined session/month, security-fix lane still fires immediately (Dependabot security updates skip cooldown automatically).

**Commit-message prefix discipline** (unchanged):
- `chore(deps)` / `chore(deps-dev)` / `chore(ci)` / `chore(docker)` are subject-only `chore` types — `deploy.sh`'s bump-level inference (§2.1 Step 2) treats them as patch under Option B (chore counts as a release-worthy bump).
- `include: scope` is INTENTIONALLY ABSENT from all three blocks. With it set, Dependabot appends its own `(deps)` scope on top of the prefix — titles render as `chore(deps)(deps): bump foo`. The prefix already carries the scope; don't double it.

**Interaction with `/deploy` (§2.1)**: dep PRs land on main via `/merge` like any other PR, but do not fire deploys on their own. They ride the next `/deploy` invocation alongside whatever else has accumulated. The monthly cadence + cooldown limits the dep-PR wave per ecosystem; whether a wave triggers a release is the maintainer's call at `/deploy` time. Cadence solves review burden; `/deploy` solves "when does it ship."

**Ignore rules — one ships by default:**

- `update-types: ["version-update:semver-major"]` for Node in the docker block, listed under both names Dependabot gives the image: `node` (Docker Hub) and `docker/library/node` (the ECR Public mirror, `public.ecr.aws/docker/library/node`). An image matching neither name is not held back. **Why:** Dependabot doesn't understand Node's LTS policy. Odd-numbered Node releases (25, 27, …) never become LTS; even-numbered ones enter Active LTS ~6 months after release. Without this ignore, every 6 months we'd get a wave of Node-major PRs we don't want to merge. Patches (24.x.y security fixes) still flow through. The ONE major bump we DO care about — the Active-LTS transition — is checked during the `dependency-triage` pass (§3.4), not by Dependabot.

If a project adds other framework-specific holds (pinned transitive dep, known-broken major), add them in the consumer's `.github/dependabot.yml` as `locally-modified` overrides. Document the hold reason as a comment in the consumer's `.github/dependabot.yml`.

**Auto-review skip coordination**: dep PR prefixes (`chore(deps):` etc.) are the same prefixes used by other pipeline-generated PRs. Gemini Code Assist (§3.7) does not have a built-in `ignore_title_keywords` equivalent at the consumer-config tier; if review noise on dep PRs becomes an issue, switch the dependabot prefix or open a Gemini config feature request.

## 3.4 `dependency-triage` skill (the weekly dependency + vulnerability pass)

The weekly dependency **process** is a kit skill (`.claude/skills/dependency-triage/`); the per-project **policy** — timelines, owner, exceptions — is `dependency-policy.md` (§3.5). Claude runs the analysis + verification; the human authorizes every main-landing merge.

**Why a skill, not a doc:** you want Claude to *execute* the same triage everywhere, identically — reading prose and re-deriving the process each time is exactly what drifts. The skill encodes the load-bearing facts so they don't have to be re-argued per project.

**The pipeline assumption is the simplification.** The skill *assumes* the kit pipeline (gitflow + `/deploy` + CI-does-not-build) rather than parameterizing a build-gate — because if you're triaging Dependabot you're on the full pipeline by definition (the build-runs-at-`/deploy`, PR-CI-doesn't-build property is uniform across consumers; testing.md §1 "Wiring CI" + §2.1). A project that broke from the pipeline owns the subtraction.

**What's universal (in the skill) vs project-specific (discovered):**
- Universal: the "PR-CI doesn't build" fact; the three blast-radius tiers; rebase-before-trusting-red; toolchain-build-before-merge; the verification standard; the guardrails.
- Project-specific, **discovered at runtime** (not configured): which packages are Tier 3 (read the `npm-toolchain` group in `dependabot.yml` — §3.3); the build/run commands and app ports (read the project's `Dockerfile.*` + deploy workflows). This is deliberate — the values vary and AI reads them from the repo; a config surface would be over-engineering.

**Pairs with** the `npm-toolchain` / `npm-patch` split in `dependabot.yml` (§3.3, now kit-standard) and the `dep-alignment` gate (§3.6). Deeper dependency discipline: `dependency-management.md`.

## 3.5 `dependency-policy.md` (synced as `merge` mode)

The operating procedure for dependency and vulnerability work — what to do with what
Dependabot produces. The kit long shipped the configuration (§3.3) and the triage
skill (§3.4) but never the procedure, so the answer to "who acts on this, and by
when" was undefined in every consumer.

**Lives at** `project-documentation/dependency-policy.md`, seeded by the kit. It lands in the project's
docs rather than `.claude/` because it is read by a human on a cadence, not loaded as
a rule on every turn.

**Mode `merge`.** The `owners`, `timelines` and `project-notes` regions are each
client's own; the kit owns every line around them. A consumer tunes its regions freely,
and a kit change to the surrounding text applies without touching them
(kitmaintainer-handbook.md §9.10).

**The timelines table is the only dial.** Tightening toward a formal standard —
ISO 27001 Annex A 8.8 wants a documented discover → prioritise → treat → review
process with defined roles, timelines and evidence — is editing that table and adding
a sign-off, not writing a different document. A 8.8 does not require zero
vulnerabilities; it requires them managed deliberately and defensibly, which is what
the exceptions-with-expiry-dates section provides.

**Why there is no enforcing gate.** A gate assumes whoever hits it can resolve it.
Build-graph updates can cost hours and the person holding the keys after handover has
less context than the person who built it, so a gate either stops them shipping or
teaches them to bypass it. The cadence is honour-system by design; the document's job
is to make "did we do it" answerable, not enforced.

## 3.6 `dep-alignment` job + `scripts/check-dep-alignment.mjs` (cross-workspace dependency-version gate)

Monorepo invariant enforcement: every shared dependency is declared at **one** version across all workspaces. Version skew across apps produces runtime failures no other check catches, and Dependabot *creates* that skew because it bumps each manifest independently. This gate is the safety net. Full discipline (trust-but-verify, solid-version philosophy, the "logged-in not 200" verification standard, accepted-residuals handling) lives in **`dependency-management.md`**.

**The script.** `scripts/check-dep-alignment.mjs` reads the root `package.json`, expands `workspaces` (literal dirs and trailing-glob `apps/*`; also the `{ packages: [...] }` form), and fails (exit 1) if any dependency name is declared at more than one version-range across the manifests. No install — it reads `package.json` files only. A single-package repo (no `workspaces`) has one manifest, so it's a guaranteed pass: **safe to run on any Node repo.** Fails loud on an unreadable *declared* workspace manifest (never reports "aligned" while a manifest is broken — constitution §X).

**Lives at** `scripts/check-dep-alignment.mjs`, arriving with the kit.

**CI wiring.** The `dep-alignment` job in `ci.yml` is Node-gated (`needs: detect`, `if: needs.detect.outputs.node == 'true'`), so a Python-only consumer skips it cleanly — it never blocks a non-Node repo (testing.md §1 "Wiring CI"; a skipped job is neutral, and `/merge` self-gates only on the check-runs that actually report). The job runs `node scripts/check-dep-alignment.mjs` directly (no `npm ci`).

**Local convenience.** Consumers add to root `package.json`:

```json
"scripts": { "check:deps": "node scripts/check-dep-alignment.mjs" }
```

so `npm run check:deps` reproduces the CI gate locally. The CI job calls the script directly and does NOT depend on this npm script existing, but adopting it is the documented convention (the script's failure message and `dependency-management.md §1` both assume `npm run check:deps`).

**Updating a shared dep:** bump it to the same version in *every* workspace that declares it in one change, run `npm run check:deps` (must be ✓), then verify per `dependency-management.md §5`. Never bump one workspace and not the others — the gate fails the PR, by design.

## 3.7 `.gemini/config.yaml` + `.gemini/styleguide.md` (Gemini Code Assist config)

Gemini Code Assist is the kit's chosen AI PR reviewer (consumer / free tier). Install via [github.com/marketplace/gemini-code-assist](https://github.com/marketplace/gemini-code-assist) at the org level. **Reviews are comment-triggered, not auto-fired on PR open** (see §3.7.1 below). The kit's `.gemini/config.yaml` disables Gemini's auto-trigger and the gitflow scripts post `/gemini review` comments at the deliberate moments where review is wanted.

The kit ships two files:
- `.gemini/config.yaml` — reviewer behavior knobs
- `.gemini/styleguide.md` — project-specific rules Gemini reads on every review

`config.yaml` is `owned` — the same in every project. `styleguide.md` is `merge` mode: a project's own review rules go in its `project-rules` region, under "Project rules", and the kit owns every line around it.

**What `config.yaml` sets:**

| Setting | Why |
|---|---|
| `have_fun: false` | No flair / poems in PR summaries. Operational tone. |
| `ignore_patterns` | Skip generated code (`*.gen.ts`, `routeTree.gen.ts`, `*.generated.*`) and lockfiles. Note: Gemini already skips `.github/workflows/**` by Google policy and skips markdown by default — those are not in this list because they're vendor-side. |
| `code_review.comment_severity_threshold: LOW` | Surface everything; consumer triages via `/triage`. Tighten to `MEDIUM`/`HIGH` if review noise becomes excessive. |
| `code_review.max_review_comments: -1` | Unlimited per-PR. The threshold above is the noise control. |
| `code_review.pull_request_opened.summary: false` | Disabled 2026-05-12. `/open-pr` writes the structured PR body; Gemini's auto-summary was duplication. |
| `code_review.pull_request_opened.code_review: false` | **Disabled 2026-05-28.** Reviews are comment-triggered exclusively — gitflow scripts post `/gemini review` at controlled points (see §3.7.1). |
| `code_review.pull_request_opened.include_drafts: false` | Don't review draft PRs. Mirrors the prior reviewer's behavior. |

**What `styleguide.md` adds:**

The styleguide is project-context Gemini reads on every review. The kit template includes:
- Constitution §XIV (caller-scan attestation requirement) — surfaces if the actor forgot the attestation
- Constitution §X (fail-fast / fail-loud) — flags new silent error handlers
- Constitution §VI (timezone-aware code) — flags `new Date()` without explicit tz
- Constitution §XIII (suppression discipline) — flags new lint suppressions without specific reasons
- Severity guidance (`Critical | High | Medium | Low`)
- A "what NOT to flag" section (test files, generated files)
- A "Project rules" section whose `project-rules` region holds this repository's own rules

The kit's text assumes the kit's stack (TanStack Start). A rule that does not fit one project is a kit issue, not a local edit outside the region.

**Why Gemini and not a paid alternative**: see `pipeline.md` §1.4 (rejected tools). Short version: Gemini's consumer / free tier matches CR Pro's catch quality on the bake-off seed defects, reads in-repo `.claude/rules/*.md` as review context out of the box, and runs at $0/seat. The 33 PR/day quota is far above typical 2-dev-shop cadence.

**Pairs with `.github/dependabot.yml` (§3.3):** Gemini's `include_drafts: false` plus dependabot's commit-prefix conventions keep mechanical PRs from triggering review cycles.

### 3.7.1 Comment-driven Gemini triggers (2026-05-28 redesign)

Prior model (pre-2026-05-28): Gemini auto-reviewed on PR open + `commit.sh` posted `/gemini review` on every push. `wait-for-pr-ready.sh` blocked until Gemini reviewed the current HEAD on every call. Problems: (a) deploy.sh's release PR triggered Gemini despite having no code to review — wasted quota + hung merge; (b) late-triage commits re-triggered Gemini reviews the user had already decided to ship without; (c) the trigger side and wait side operated in separate vacuums — a silently-failed `gh pr comment` left `/merge` hanging forever waiting for a review that was never coming.

Current model: **trigger reality drives wait reality.** A single observable — the presence of a `/gemini review` comment on the PR scoped to the current HEAD's committer date — couples both sides.

| Site | Trigger behavior |
|---|---|
| `/open-pr` | Always posts `/gemini review` after `gh pr create`. Fail-loud if post fails. |
| `/commit --review` | Posts `/gemini review` after push. Fail-loud if post fails. |
| `/commit --no-review` | Does NOT post. The wait at `/merge` sees no trigger and proceeds CI-only. |
| `/commit` (PR open, no flag) | `.claude/commands/commit.md` prompts the user via `AskUserQuestion`; result determines `--review` / `--no-review`. |
| `/commit` (no PR open) | Nothing to comment on; skips silently. |
| `/checkpoint` | Never posts. Checkpoints are mid-flight saves below the review threshold; `/commit` is the signal that work is review-ready. |
| `/deploy` | Never posts. The bump commit pushes directly to `main` — no PR exists for Gemini to review. (Under the earlier release-PR design, deploy likewise never triggered Gemini; the direct-push model removes the PR entirely.) |

The wait side reads truth, not intent. `wait-for-pr-ready.sh` queries the PR's top-level comments (via `gh api repos/{owner}/{repo}/issues/{pr}/comments`), filters to `/gemini review` body (case-insensitive, exact match — not prose like "I'll run /gemini review later"), and scopes to comments created AFTER the HEAD's committer date. If such a comment exists → wait for a Gemini review on HEAD. If absent → CI-only readiness. No author filter — manual triggers from the user (or from a consumer developer, or from any maintainer) are honored identically to scripted triggers.

This removes the "vacuum" failure mode: a silently-failed `gh pr comment` is now fail-loud at the trigger site (`commit.sh` exits 10, `open-pr.sh` exits 9), and the downstream wait never assumes Gemini is coming when it isn't.

Posting via `gh pr comment` lands the trigger under the developer's GitHub identity (gh CLI auth, not a `[bot]`-suffix account), so Gemini's loop-prevention filter (per Google's own gemini-cli PR #16746, which ignores `[bot]` commenters) does not suppress it.

`GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` short-circuits the entire path: trigger scripts skip posting, and the wait skips the Gemini check entirely (treats it as `Gemini=skipped`). Use only on repos where the Gemini App is genuinely absent — the value records a fact about the repo, not a preference.

## 3.8 GitHub email noise — what triggers what, and how to silence it

Each dev's noise tolerance differs. This section maps every email GitHub sends on a project running this pipeline to the setting that controls it, so each dev can decide for themselves what to keep and what to mute. **All settings are per-account, not per-repo or per-org** — your tuning doesn't affect anyone else.

**Settings live in three places (override priority: thread > repo > account):**

1. **Account settings** — `https://github.com/settings/notifications`. Global routing rules, default email, Actions/Dependabot scope, comment subscriptions.
2. **Repo Watch dropdown** — top-right of any repo page. Choose `All Activity` / `Participating and @mentions` / `Ignore` / `Custom`. `Custom` lets you check Issues / Pull requests / Releases / Discussions / Security alerts independently.
3. **Per-thread mute** — on a single PR / issue / discussion: `Unsubscribe` link in the right sidebar. Only stops that one thread.

**Trigger → setting map:**

| Email trigger | Source | Where to silence |
|---|---|---|
| New PR opened on a watched repo | Repo Watch | Repo Watch → Custom → uncheck Pull requests, OR set Watch to `Participating and @mentions` |
| New issue opened on a watched repo | Repo Watch | Repo Watch → Custom → uncheck Issues, OR drop to Participating |
| Comment on a PR/issue you're not subscribed to | Repo Watch | Same as above |
| Comment on a PR you authored / commented on | Account: Participating | Account → Notifications → Participating → uncheck Email (rare — most devs keep this on) |
| @mention of you anywhere | Account: Participating | Same as above. Note: Participating ALSO covers PRs you reviewed, issues you assigned yourself, etc. |
| PR review submitted on your PR | Account: Participating | Same. Or per-thread mute. |
| PR you authored was merged | Account: Participating | Same. Most devs want this one. |
| New release published | Repo Watch | Repo Watch → Custom → uncheck Releases |
| Discussion created/replied | Repo Watch | Repo Watch → Custom → uncheck Discussions |
| GitHub Actions workflow failed | Account: Actions | Account → Notifications → Actions → set to `Only notify for failed workflows` (default) or `Off` |
| GitHub Actions workflow succeeded after failing | Account: Actions | Same. Setting also controls this. |
| GitHub Actions workflow first-time failure / restored success | Account: Actions | Same setting; granular sub-options in the same panel. |
| Dependabot security alert opened | Account: Dependabot alerts | Account → Notifications → Dependabot alerts → toggle Email/Web. Repo-level kill switch: Settings → Code security → Dependabot alerts. |
| Dependabot version-update PR opened | Repo Watch (it's a PR) | Repo Watch → Custom → uncheck Pull requests, OR drop to Participating. Dependabot PRs you don't review never fire Participating. |
| Gemini PR summary / code review | Repo Watch | Posted as PR comments — Repo Watch / Participating. Gemini does not have a separate noise-suppression knob like CR's `review_status`. |
| Gemini replied to your inline comment | Account: Participating | Same as any reply. |
| Vulnerability alert (org-wide) | Org settings | `https://github.com/organizations/<org>/settings/security_analysis` — owner only. |
| Workflow run cancelled / skipped | Not emailed by default | Only `Only notify for failed workflows` produces emails; cancels/skips are silent. |

**Common scope-down patterns:**

- **"Just deploy failures, nothing else"** → set every repo's Watch to `Participating and @mentions` (or `Ignore` if you don't want even those); Account → Actions → `Only notify for failed workflows`. You'll still see PRs you author / review / get mentioned in, plus any deploy-failure email.
- **"PRs I'm involved in only"** → Watch all repos as `Participating and @mentions`. No `All Activity` anywhere. Most signal-heavy devs land here.
- **"Watch the team's repo, ignore my own"** → mix Watch settings per repo; account-level rules are global, repo Watch is per-repo.

**Per-org email routing:** Account → Notifications → "Custom routing" lets you send each org's emails to a different address (e.g. `work@`, `personal@`). Useful if you contribute across multiple orgs and want filtering at your mail client.

**What you cannot disable:**
- Account security emails (login from new device, password change, 2FA changes) — always on, by design.
- Direct repository invitations.
- Org membership invitations.

**Verifying your config:** check `https://github.com/notifications` shortly after a known-noisy event (open a draft PR, push to it). If something showed up that you tried to mute, the relevant setting is one of the rows above; trace the trigger column to the source.

## 3.9 `knip` job + `knip.config.ts` (unused-code gate)

**What it catches.** Unused files, exports, types and dependencies, and imports of packages a workspace never declares — across workspaces, which neither `tsc` nor Biome sees.

**One configuration, owned by the kit.** `knip.config.ts` lands at the repo root, `owned`. It reads the project's layout at run time — the workspaces in the root `package.json`, the `schema` each `drizzle*.config.*` names, the stylesheet a package script hands to the Tailwind CLI, and `SHARED_MODULE_DIR`, `DESIGN_UI_PACKAGE`, `DESIGN_FEED_BARREL` and `DESIGN_VENDORED_DIR` — so it never needs editing. Its entries are the kit's conventions: `server-start.mjs`, `src/server.ts`, `src/{start,router}.{ts,tsx}`, `design-system/**`, `public/**/*.js`, every file under a `static/` directory, root `scripts/*`, the testing template's harness files, and the feed barrel. A nested directory with its own `package.json` that is no root workspace — a test harness, a tool — is analysed as its own package, so its imports count against its own manifest.

**Browser JavaScript served by a non-JavaScript server goes in a `static/` directory** (python-rules.md): knip has no import to follow from a Python page to its script, and treats everything there as a served asset whose exports the page may call. Drizzle configs are read, never executed: they throw without a database URL, which is every CI run.

**There is no per-project ignore list.** A finding that is not dead code is a gap in `knip.config.ts`: raise it on the kit and fix it there, for every project. The exemptions the file does carry are kit-wide — the vendored shadcn atoms and the test harness are API surfaces, and the exports of `src/server.ts`, the design-system config and the Drizzle schema are consumed by a tool, not an import.

**The gate is the project's call, `KNIP_GATE`.** A codebase reaches zero findings once, in a cleanup, and the gate holds it there.

| `KNIP_GATE` | The `knip` job |
|---|---|
| `"true"` | Runs knip, prints each finding type with its count and annotates the PR; any finding fails the job |
| empty, listed in `_intentionally_empty` | Passes with a notice that the gate is off |
| missing, or empty and unlisted | Passes with a warning naming the key — undecided, and re-surfaced every sync |
| anything else | Fails |

**The version is the stack manifest's** (`knip`, `installedBy: ci`). The job runs `npx --yes knip@<version>`, and `stack-standard` fails when the workflow names any other.

**Run it locally** from the repo root, after `npm install`:

```bash
npx --yes knip@5.88.1 --no-config-hints
```
