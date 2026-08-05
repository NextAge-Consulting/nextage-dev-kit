# Kit Repo GitHub Configuration

How **this** repository (`NextAge-Consulting/nextage-dev-kit`) is configured on GitHub and why it differs from the consumer projects the kit ships to.

**Use this as:**
1. The answer to "do I need to change anything on GitHub to ship X?" when adding features
2. A pre-flight sanity checklist when making workflow, hook, or gitflow changes
3. A reference for onboarding a new kit contributor

---

## 1. Repo facts

| Setting | Value | Source |
|---------|-------|--------|
| Visibility | **private** | `gh repo view` |
| GitHub Pro / org | **no** | branch protection API returns 403 — immaterial, the pipeline uses none |
| Default branch | `main` | |
| Merge methods | **squash only** (merge-commit and rebase disabled) | `gh repo view --json squashMergeAllowed,mergeCommitAllowed,rebaseMergeAllowed` |
| Delete branch on merge | ✅ enabled | |
| Default merge method (viewer) | SQUASH | |
| Branch protection on `main` | **none** — the pipeline uses no branch protection (`/merge` self-gates) | n/a (also unavailable on this repo: API returns 403) |
| Installed workflows | **none** — `.github/` does not exist | `ls .github` |
| Manifests | **none** — no `package.json`, no `pyproject.toml`, no `biome.json` | docs/config-only repo |

---

## 2. What this means for gitflow

The kit repo is a **degenerate case** for the gitflow subsystem — every optional gate auto-skips because the gating files don't exist.

### `/commit` — all validation short-circuits

| Gate | Gated on | Kit repo? | Result |
|------|----------|-----------|--------|
| Typecheck (Node) | `package.json` + `check-types` script | ❌ absent | no-op |
| Typecheck (Python) | `pyproject.toml` + pyright/mypy | ❌ absent | no-op |
| Biome lint | `biome.json` / `biome.jsonc` | ❌ absent | no-op |

Net: `/commit` just stages all changes and commits with a conventional message.

### `/open-pr` — runs unconditionally

Pushes branch, creates PR, prepends `Closes #N` from any branch-linked issues. Nothing to gate.

### `/merge` — CI gate auto-skips

`merge.sh` probes `repos/:owner/:repo/branches/main/protection/required_status_checks`. Private repo without Pro returns **403**, which the script interprets as "no gate configured" and proceeds to squash-merge. Logs: `"no required checks configured on main — CI gate skipped"`.

**Consequence:** `/merge` on the kit repo is effectively "squash-merge the PR immediately" with no CI wait — and the kit repo has no CI workflows anyway. This is the same as every project: the pipeline uses no branch protection (PIPELINE.md §1.1, NEW-PROJECT-SETUP.md step 3), and `/merge` self-gates by reading the PR's check-runs directly. The only requirement is that `main` not require a PR — the default — so the direct-push paths work: `/deploy` pushes the version bump directly to `main`, `/ship-main` pushes infra/emergency commits, and `/sync-dev-kit` leaves its applied changes for you to land with `/ship-main` (it does no git itself). `enforce_admins` is irrelevant — nothing admin-merges. Normal `/merge` always goes through a PR.

---

## 3. Workflow templates NOT installed here (and why each is correct)

`_github-project/workflows/` contains four workflow templates that SHIP to consumer projects via `/sync-dev-kit`. None are installed in this repo:

| Workflow | Why not installed here |
|----------|------------------------|
| `commitlint.yml` | Optional. Local `/commit` already enforces conventional format. Would need `.commitlintrc.json` at root. Install if PR-title backstop is wanted. |
| `version-bump.yml` | Requires `package.json` or `pyproject.toml`. Kit has neither — would no-op on every merge. |
| `tag-release.yml` | Depends on `version-bump.yml` producing a bump PR. Nothing to tag without a version manifest. |
| `dependabot-surfacing.yml` | No dependency manifests to scan. |

If the kit ever grows a version manifest (e.g., a versioned CLI), reconsider `version-bump.yml` + `tag-release.yml`.

---

## 4. Sanity checklist — "does this change need GitHub config on the kit repo?"

Run through this when adding/modifying anything in the kit. If any row answers **yes**, the kit repo itself needs a GitHub-side adjustment (not just `_claude-project/` updates).

| Change you're making | Affects kit repo's GitHub? | If yes: what to do |
|----------------------|----------------------------|--------------------|
| Adding a new rule, skill, command, or hook under `_claude-project/` | ❌ No | Template-only — ships to consumers. Kit repo runs its own mirror copy. |
| Adding a new workflow to `_github-project/workflows/` | ❌ No (ships to consumers) | Only install in kit if it's useful on a manifest-less repo (rare). |
| Adding a `package.json` / `pyproject.toml` / `biome.json` to the kit root | ✅ **Yes** | `/commit` typecheck + biome gates now fire locally. Also enables `version-bump.yml` if installed. |
| Adding `.github/workflows/commitlint.yml` to kit | ✅ **Yes** | Needs `.commitlintrc.json` at kit root. |
| Making kit public OR moving to a paid plan | ⚠️ Mostly no | Branch protection would become *available*, but the pipeline uses none — so there is nothing to apply. The only thing to watch: don't enable require-PR, or the direct-push paths (`/ship-main`, and `/deploy` if ever run against the kit's own repo) break. `/sync-dev-kit` does no git (you land its changes with `/ship-main`). `enforce_admins` is irrelevant — nothing admin-merges. |
| Changing kit's merge method away from squash | ✅ **Yes** | `merge.sh` calls `gh pr merge --squash`. Repo must keep squash-merge enabled. |
| Disabling delete-branch-on-merge | ⚠️ Cosmetic | `merge.sh` passes `--delete-branch` explicitly, so local merges still delete. Repo-wide hygiene only. |
| Adding a new slash command that touches GitHub (issues, PRs, projects) | Depends | If it requires App tokens or org-scoped PATs: document secret requirements here and in the command's `.md`. |
| Adding a new status check or CI job to consumer projects | ❌ No (for kit itself) | `/merge` picks up new check-runs automatically (it self-gates by reading them); no branch-protection wiring to update. |

---

## 5. If you ever DO install workflows here

1. Commit the workflow file under `.github/workflows/` (triggers on PR).
2. Verify it runs green on a throwaway PR.
3. Install any needed config (e.g., `.commitlintrc.json`) at kit root.

That's it — `/merge` self-gates by reading the workflow's check-runs directly. No branch protection to configure (the pipeline uses none); just don't enable require-PR, or the direct-push paths break.

---

## 6. Related docs

- `HANDBOOK.md` — full architecture, sync flow, three-surface layout
- `GITFLOW-CHEATSHEET.md` — day-to-day developer reference (applies to all projects)
- `DEVELOPER-ONBOARDING.md` — second-dev setup procedure

---

## 7. Revision log

Update this file when any row in §1, §3, or §4 changes. This is the kit's own "current state of GitHub config" source of truth — if it drifts from reality, every sanity check based on it is wrong.
