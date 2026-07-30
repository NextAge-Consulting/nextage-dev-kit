# Pipeline

Kit-level CI/CD pipeline design and roadmap. **Generic** — no project specifics.

This doc owns the **why** (durable design rationale) and the **roadmap** (what's done, what's deferred). The **how** — workflow templates, scripts, settings, gotchas — lives in `HANDBOOK.md`. Where a procedure is referenced below, the HANDBOOK section is cited; this doc does not duplicate it.

- **Design rationale** → Part 1 (this doc)
- **Phase roadmap** → Part 2 (this doc)
- **Implementation / templates / setup** → `HANDBOOK.md`

**No branch protection.** This pipeline does not use GitHub branch protection. `/merge` self-gates by reading the PR's CI check-runs directly — it never depends on GitHub's "required checks" config — so the gate behaves identically on every repo regardless of plan, including a brand-new one with nothing configured. The one hard requirement: **`main` must not require a PR**, or the direct-push paths (`/ship-main`, `/deploy`, `/sync-dev-kit`) get rejected. A fresh repo has require-PR off by default, so there is nothing to set up — just don't turn it on.

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

For quick infra / emergency / "get it in and back to clean" work, a full branch→PR→CI→merge cycle is theater. `/ship-main` commits a conventional message **directly on `main`** in the primary repo and pushes — no branch, no PR, no CI (a push to `main` triggers no workflows; CI is `pull_request`-only, deploys are `workflow_dispatch`-only). It runs the same local typecheck + lint as `/commit` (the assist that stays). Works as long as `main` does not require a PR (§1.1) — the default.

**The gate is explicit invocation, never inference.** A bare `/commit` on `main` still auto-branches (the safety for accidental-on-main); `/ship-main` is the opposite, on purpose, and only when asked for by name. Its commits land on `main` and feed the next `/deploy`'s bump + changelog exactly like a merged-PR squash commit. See HANDBOOK / `commands/ship-main.md`.

## 1.2 The gitflow subsystem (the workflow model)

Git operations route exclusively through gitflow — slash commands backed by scripts, fronted by a skill for natural-language routing, with a hook blocking raw destructive git. Four layers of defense: rule → skill → command → hook. Full subsystem in HANDBOOK §3–§6.

| Command | Role |
|---------|------|
| `/work [#issue]` | Enter a worktree; optionally link issues (status → In Progress, assign, dump context for Claude). |
| `/checkpoint` | Fast WIP commit + push. |
| `/commit` | Conventional commit (emoji + type), typecheck-gated, push. |
| `/link #N` | Link additional issues mid-work. |
| `/sync` | Pull `main` into the feature branch. |
| `/open-pr` | Write + commit changelog locally, push, open PR with `Closes #N`, trigger advisory review. |
| `/merge` | Verify gate green, squash-merge, land on `main`. **Does not deploy.** |
| `/deploy` | The release boundary — see §1.3. |

Design choices baked in:

- **Changelog is local, not a CI action.** Claude composes it during `/deploy` from commit subjects since the last tag, applying editorial rules (filter `refactor`/`style`/`test`/`docs`/`chore`, rewrite internals as user-facing prose) that template tools (release-please) can't. Single-writer (`/deploy` only) eliminates duplicate-bullet bugs. No `ANTHROPIC_API_KEY` secret, no runner. HANDBOOK §6.4 / §11.5.
- **Version bump is local, not auto-on-merge.** See §1.3 — auto-bump-on-merge is a NEVER-restore anti-pattern.
- **PR title is the conventional-commit source.** Squash merge sets the squash commit = PR title; `commitlint` validates the **title only** (not branch commits — machine-generated PRs produce malformed branch commits with clean titles). The title drives the bump level. HANDBOOK §6.6 / §11.1.
- **No persistent working branch.** After merge you're on `main`; next task gets a fresh descriptively-named branch. Worktree-per-session is the entry model; HANDBOOK §3.2.

## 1.3 `/deploy` as a human-serialized release boundary

**`/merge` is not `/deploy`.** Multiple merges accumulate on `main`; a release ships everything since the last tag in one deliberate invocation.

`/deploy` does bump → changelog → tag → push → trigger-deploy in **one human-in-the-loop CLI run**, so the source-of-truth version field and the deployed artifact match **by construction**. The bump commit is **pushed directly to main** (require-PR off, the default — §1.1) — no release branch, no PR, no admin-merge; the bump commit + tag are the release record. Deploy workflows are `workflow_dispatch:`-ONLY and fired explicitly via `gh workflow run` against post-bump HEAD. Full procedure + history in HANDBOOK §6.5; trigger contract in §11.4.

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

The migrate workflow body is project-owned and MUST exit 0 on a no-op and non-zero only on genuine failure (the orchestrator gates on run conclusion). **Never blanket `|| true`** — trap a specific no-op signal and re-raise everything else. Forward-only migrations keep old and new code compatible with the same schema (add column → use column → later remove column). See HANDBOOK §6.5 "Migration phase" + the no-op-tolerant reference pattern.

## 1.4 Quality + security tools

| Tool | Role | Why |
|------|------|-----|
| **Biome** (CI lint) | Lint-only (formatter disabled). `recommended` ruleset, all `a11y/*` on, `noExplicitAny` error. | AI-authored JSX omits a11y patterns (training data omits them); `any` blinds the type info AI reasons from. Formatter off because a 100%-AI codebase has no human formatting concern and enabling it produces a giant normalization diff. Fix violations in source, suppress only as last resort (constitution §XIII). |
| **Semgrep CE** (CI SAST) | `--config auto`, ~10s. Mandatory `.semgrepignore`. | Free, 1000+ rules. The ignore file is mandatory, not optional — generic secret-regex rules false-match base64 runs inside binary assets (PDF/EPS) and time out CI per file. Ship it with Semgrep, don't wait for the incident. HANDBOOK §11.8. |
| **Gemini Code Assist** (advisory PR review) | Inline + summary on every PR, free for private repos. Triage via `/triage`. | Independent model family (most distinct second opinion from Claude). Reads `.claude/rules/*.md` + `.gemini/styleguide.md` as review context — cites constitution rules unprompted. Catches the structural-diff-defect class; complements (does not replace) tests. HANDBOOK §6.7 / §11.11. |
| **Dependabot** | Version + security PRs, monthly + cooldown + grouping. | Monthly batching (not weekly) because weekly is noise-dominant for a small shop. Cooldown (patch 3d / minor 7d / major 30d) dodges the 48–72h window where supply-chain attacks get caught and the bad version yanked; security fixes skip cooldown automatically. HANDBOOK §11.10. |
| **Dependabot surfacing** | One tracking issue per vulnerable package, onto the project board, self-closing. | The Security tab is storage, not surfacing — small teams never open it. Anything needing action must land on the board (the one surface that's actually watched). Constitution §X "fail loud." HANDBOOK §11.6. |
| **Node LTS check** | Monthly cron; opens a tracking issue on a new Active-LTS major. | Dependabot can't tell LTS from non-LTS (odd majors are never LTS) → either PR spam on non-LTS majors or blind to the LTS transition you DO want. HANDBOOK §11.14. |
| **dep-alignment** (CI gate, Node-only) | Fails a PR if any shared dependency is declared at more than one version across workspaces. Node-gated in `ci.yml`, no-op on single-package / Python-only repos. | A monorepo runs ONE stack; cross-app version skew causes "works in one app, breaks in another" outages Dependabot *creates* (it bumps each manifest independently). Reads `package.json` only, no install. HANDBOOK §11.13a / DEPENDENCY-MANAGEMENT.md. |

**Rejected, and why** (terse — empirical, not theoretical):

| Rejected | Why |
|----------|-----|
| CodeRabbit (Pro or free-CLI) | Pro's one paid-worthy feature (cross-file code-graph) is made redundant by constitution §XIV (every signature change updates all callers in the same edit). Free tier degrades to summary-only post-trial + manual CLI invocation. |
| Sourcery | Paid, yet missed defects the free options caught; high false-positive rate; broken-on-push re-review; bundled security scan duplicates Dependabot. |
| Snyk | Redundant with Dependabot + surfacing + Semgrep at small-shop scale. Upgrade path is a 5-seat-minimum cliff. |
| Socket.dev | Zero unique signal above Dependabot on a clean codebase; free tier truncates the dep tree; adds per-release triage cost. |

**Revisit threshold for the rejected dep-security tools:** a real supply-chain incident slipping through Dependabot + cooldown + surfacing + Semgrep. The kit's cross-file caller analysis (what paid review vendors charge for) is handled in-house by constitution §XIV at edit time.

## 1.5 Testing model

**Philosophy:** test real code against real data. Mocks only where unavoidable (auth — a session concern, not business logic). Priority on logic that produces predictable, verifiable output where a silent change ships wrong results — not "feel-good" coverage.

| Tier | Tooling | What | Gate |
|------|---------|------|------|
| Unit | Vitest | Pure functions with complex, predictable output (pricing math, packing algorithms, financial totals). Synthetic fixtures, in-memory. | CI hard gate |
| Integration | Vitest (`integration` project) | Real server functions against a **real ephemeral Postgres branch** — one branch per run, forked copy-on-write from production, deleted after. Each test runs in an always-rolled-back transaction (`dbTest`), so tests run in parallel MVCC-isolated on the shared branch. Catches wrong queries, missing columns, constraint violations, broken joins. | CI hard gate |
| Migration-during-PR | drizzle-kit in `globalSetup.ts` | A PR's pending migration runs once against the prod-schema branch before tests — migration validated in the same CI pass, same runner as prod deploy. | CI hard gate |
| E2E | Claude + `agent-browser` | Standalone `/e2e` **manual verification** — see below. | NOT a hard gate |

**Why real DB branches over mocks:** mocks drift from real database behavior — the exact failure the model is meant to catch. A branch is a copy-on-write clone of prod schema + data; tests insert/update/delete freely, prod is never touched. External services follow the same "real not mock" rule: Stripe Test Mode (real Stripe, no money — not a mock) and Mailpit (real SMTP capture) rather than network interception that drifts.

**E2E is a manual verification, not a hard gate (current reality).** The model is **Claude-as-intelligent-tester**: Claude drives `agent-browser` (via Bash, never MCP — MCP pollutes context with browser state) through plain-English flow files. Failure is **behavioral** — if Claude can't complete a flow (blank page, broken button, 404, hydration crash), that's the test. No `.spec.ts`, no test runner, no committed selectors. Flows are run by the `/e2e` skill and written + maintained by a companion `/e2e-author` skill (flow-file format + the agent-browser recipe library).

| Decision | Rationale |
|----------|-----------|
| NOT scripted Playwright/Cypress in CI | Maintenance tax: selectors break on every UI change; ~full-time job at scale; unrealistic for a small team. Infra (containerized app + branch + secrets) is significant and not load-bearing at this scale. |
| Manual verification, not hard gate | Cloud sessions can't run `agent-browser`, so a hard gate would be impassible. `/e2e` is a standalone command the user runs when they want it — it is not wired into `/merge`. Flow files declare `triggers:` globs; the `/e2e` skill scopes which flows run by intersecting with the current diff (docs-only diff → zero flows). |
| Behavioral failure detection | Tests the real stack (real Stripe test mode, real DB branch, real auth, real runtime) — catches the "all functions work but the page doesn't render" class scripted unit/integration tests miss. |
| Paired with production monitoring | Because E2E is a manual verification not an enforced barrier, Sentry + UptimeRobot provide post-deploy catch-up. |

Structured assertions are added by **accretion** — only when a specific failure class keeps slipping through does that step get codified as a structured `agent-browser eval` check. Default is behavioral. HANDBOOK §11.15.

---

# Part 2 — Phase Roadmap

**Phases 1–6: DONE** (current capabilities). **Phases 7–10 + follow-ups: DEFERRED** roadmap.

## Done (current capabilities)

| Phase | Capability |
|-------|------------|
| 1 | GitHub config (squash-only, auto-delete branches) + basic CI (type-check + Biome + Semgrep, parallel jobs, concurrency-cancel). |
| 2 | gitflow subsystem (`/work` `/commit` `/checkpoint` `/open-pr` `/merge` `/sync` `/link`), commitlint title gate, issue↔branch↔PR linking, raw-git hook guard. |
| 3 | Release automation via local `/deploy` (bump + changelog + tag + push + dispatch deploy), direct-push of the version bump to `main`, `workflow_dispatch:`-only deploy contract. |
| 4 | Quality/security: Gemini advisory review, Dependabot (monthly + cooldown + grouping), Dependabot surfacing, Node LTS check, Semgrep + `.semgrepignore`. |
| 5 | Test infrastructure: Vitest config (unit + integration projects), one-branch-per-run ephemeral Neon harness with transaction-per-test isolation, migration-during-PR, test dir structure + auth/util scaffolding, Vitest in CI. |
| 6 | Unit + foundational integration tests for the complex-logic functions (pricing, packing, totals); all green in CI as a required check. |

## Deferred roadmap

### Phase 7 — Integration tests (server-function scope)

Builds on the Phase-6 `dbTest` / one-branch-per-run wiring; the per-PR migration pattern is in place. Scope is the server-function-file layer — none written yet.

| What | Priority | Blocker |
|------|----------|---------|
| Checkout flows (money path) | CRITICAL | Stripe test keys as CI secrets + Mailpit |
| Product/listing, account/approval, price-list generation functions | HIGH | None (DB branch in place) |
| Init/cache, order retrieval | MEDIUM | None |
| Contact, admin | LOW | None |

- **Shared blockers:** Stripe Test Mode keys promoted to CI secrets; Mailpit in the test docker-compose (Phase 5D below); auth mocked (the one acceptable mock — shape stubs already exist).
- **How written:** dedicated session per function file; Claude generates tests following the project's testing patterns. Review gate per test: *"if this function changed and produced wrong results, would this test catch it?"*
- **Effort:** initial batch ≈ 3–5 days. Neon cost variable, budget ~$5–15/mo once integration tests are the main consumer.

### Phase 8 — E2E hardening

The E2E model (Claude-as-tester via `agent-browser`, flow files, standalone `/e2e` command) is **shipped and exercised**. What remains is hardening, not building.

| Item | What | Blocker / effort |
|------|------|------------------|
| Substantive behavioral assertions | Move beyond render-checks to correctness: price-math, cart+shipping recalculation, payment elements mount + accept input, post-login tier reflects correctly. | Per-flow, accretion-on-demand |
| New-flow expansion | Confirmation-email verification (needs Mailpit); generation flows. | Mailpit (Phase 5D) for the email flow |

### Phase 9 — Production monitoring

Fully independent — can start anytime. None of the three pieces started.

| Item | What | Cost | Notes |
|------|------|------|-------|
| Error tracking (Sentry) | Account (Team plan, **flat / unlimited users**, not per-seat); install client + server SDKs in each app; source maps; perf monitoring; alert rules. | ~$26/mo | Multiple devs need access (free tier = 1 user). Decision locked. |
| Uptime monitoring (UptimeRobot) | Account + per-URL HTTP monitors (5-min interval) + alert contacts. | $0 | ~5-min setup. |
| Log viewer | Browser-accessible Pino-aware admin log viewer (level/namespace/search filter, file selection, pagination, context view, download, admin-gated). | $0 | **Decision still open:** port an existing in-house admin viewer (~1 day; parses Pino JSON natively) vs. Dozzle (10-min, but raw stdout — no Pino-field parsing, no filter, no download). The in-house port is recommended; pick before starting. |

**Effort:** Sentry ~half-day (apps + source maps); UptimeRobot minutes; log viewer ~1 day if porting.

### Follow-up optimizations (cross-cutting)

| Item | What | Why deferred |
|------|------|--------------|
| Mailpit (Phase 5D) | Add Mailpit to the test docker-compose; configure app to use Mailpit SMTP in test mode. | Unit tests don't need email; needed by Phase 7 integration tests. |
| Test-enforcement rule (Phase 5E) | A project rule: editing complex-logic dirs verifies corresponding tests exist + pass; flag if missing. | Deferred until real tests landed (now done); the advisory-review styleguide already covers the PR side. |
| Surfacing `workflow_run` filter | Filter the surfacing trigger to fire only on dependency-merge deploys (author-based). | Advisory-refresh value applies only when a new dep version shipped; current cadence works, just noisier. |
| Autonomous-gitflow invocation guard | A `PreToolUse` hook on gitflow invocations that blocks when the latest user prompt contains no authorization keyword. | Text rules ("never proactively invoke git") aren't load-bearing — rule-reading and tool-calling are decoupled. Structural fix (same class as the destructive-git guard). Not yet scoped. |
| Evaluate fallow.tools | [fallow.tools](https://fallow.tools/) — "codebase intelligence for typescript and javascript." Assess as a CI codebase-analysis step (quality/dead-code/dependency signal). Not yet trialed. | Candidate flagged 2026-06; needs hands-on eval before adopting into CI templates. |