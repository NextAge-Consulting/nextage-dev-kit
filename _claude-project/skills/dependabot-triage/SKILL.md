---
name: dependabot-triage
description: Weekly Dependabot PR triage for kit-pipeline projects — clear dependency PRs by blast-radius tier without re-deciding from scratch each time. Assumes the kit pipeline (gitflow + /deploy + CI-does-NOT-build). Use when the user asks to "triage dependabot", "clear the dependabot PRs", "do the weekly dependency cleanup", "dependabot triage", "weekly deps", or works through open Dependabot PRs. Triggers: "triage dependabot", "weekly deps", "clear dep PRs".
allowed-tools: Bash(gh:*), Bash(git pull:*), Bash(git status:*), Bash(git log:*), Bash(git fetch:*), Bash(npm:*), Bash(docker:*), Bash(lsof:*), Read, Glob, Grep
---

# dependabot-triage — weekly Dependabot cleanup

The repeatable process for clearing Dependabot PRs without re-deciding from scratch each time. Run ~weekly. Claude does the analysis + verification; **the human authorizes every main-landing merge** (merging a Dependabot PR squashes to `main`).

**Pipeline assumption.** This skill assumes the project is on the **kit pipeline**: gitflow tooling, `/deploy` as the release boundary, and CI that does **not** build the app. A project that broke from that pipeline owns the subtraction — this skill's gating logic won't fit it (and such projects don't run dependabot triage anyway).

## The one fact that drives everything

**PR-CI does not build the app.** `ci.yml` runs `dep-alignment` + `check-types` + `biome` + `vitest` (+ `semgrep`) — never the production build. The only automated build gate is in `/merge`, and **Dependabot PRs never touch it** — they land via `gh pr merge` (step 3–5 below), not through gitflow. So a dep PR reaches `main` with nothing having built it. So:

- **Green Dependabot CI ≠ build-safe** for anything in the bundler/SSR graph.
- A toolchain bump that breaks the build can merge on green CI and **poisons `main`** — every subsequent `/merge` on any branch then fails its build gate on damage it did not cause, until someone fixes it.
- Therefore: **toolchain bumps get a local prod build + app smoke before merge.** Leaf bumps don't.

## Tiers — triage by blast radius, NOT CI color

| Tier | What | Gate before merge |
|---|---|---|
| **1 — CI/infra** | `github-actions`, `docker` (non-Node), `chore(ci)` | Green CI. Cannot touch the app build. |
| **2 — Leaf libs** | runtime/util libs NOT in the bundler/SSR graph | Green CI (rebase first if stale). |
| **3 — Toolchain** | bundler / React / framework / SSR adapter | Green CI **+ local prod build + app smoke**. One PR at a time, never batched. |

**The Tier-3 set is exactly the `npm-toolchain` group in `.github/dependabot.yml`** (kept separate from `npm-patch` for precisely this reason). **Read that group to know what's Tier 3 in THIS project — do not hardcode a package list.** `postcss` and anything else in the CSS/build pipeline is Tier 3 even if it arrives in a leaf group.

## Weekly procedure

1. **List + status.**
   ```bash
   gh pr list --author "app/dependabot" --state open \
     --json number,title,mergeable --jq '.[] | "#\(.number) \(.mergeable) \(.title)"'
   gh pr view <N> --json statusCheckRollup \
     --jq '.statusCheckRollup[] | select(.conclusion=="FAILURE") | .name'
   ```
   Old PRs failing on `check-types`/`biome` are almost always **stale base, not a broken dep** — rebase before trusting red.

2. **Baseline.** Confirm `main` builds clean first: `git pull --ff-only origin main` then the project's build command (discover it from `package.json` scripts — typically `npm run build --workspaces --if-present`). If main is already red, fix that before touching deps.

3. **Tier 1 — merge on green.** `gh pr merge <N> --squash --delete-branch`.

4. **Tier 2 — rebase → merge green.** `gh pr comment <N> --body "@dependabot rebase"`, then merge when green. No build needed.

5. **Tier 3 — apply to CURRENT MAIN, deploy-image verified, human-authorized.** NEVER test the PR's own branch (it's often weeks stale, missing current files; only the version bump matters, applied onto today's main). On clean main: `npm install <pkg>@<ver>` the target versions (regenerates the lockfile = current-main + bump), then **build + run the real deploy Docker image** and verify in a browser. **Discover the exact build/run commands and ports from the project's `Dockerfile.*` + deploy workflows** — do not assume. Verify the **heaviest / most-divergent app** (and any app whose config diverges, separately). Human authorizes commit+push to main; broken → fix or close.

6. **Close superseded.** When a group PR already contains a package that also has a standalone PR, close the standalone with a note once the group lands.

## Verification standard (Tier 3)

"Solid" means **build the real prod image, run it on the app's native port, and complete a real login** — NOT "200 on a route" and NOT "server ready" in the log (crypto/auth often loads lazily per request, so a boot can succeed while every request 500s). Full standard: the kit's **`DEPENDENCY-MANAGEMENT.md §5`**.

## Dependency discipline (read alongside)

- **One version per shared dependency** is CI-gated by `dep-alignment` (`npm run check:deps`). When a shared dep updates, bump it to the same version in every workspace that declares it.
- The deeper discipline — trust-but-verify on old workarounds/pins, solid-version philosophy, accepted-residuals handling — lives in the kit's **`DEPENDENCY-MANAGEMENT.md`**.

## Guardrails

- **Never `/deploy` or `/ship-main` as part of triage** — those are the human's to trigger.
- **Merges land on `main`** — the human authorizes each (or the batch) explicitly.
- **Never merge a Tier-3 PR on green CI alone.** The build gate is the whole point.
- **Node major bumps are blocked** in `dependabot.yml`; `node-lts-check.yml` surfaces real Active-LTS transitions. Don't override.
- `dependabot.yml` group definitions (the toolchain/leaf split) are kit-standard; cooldown / limits / ignore lists and pattern *extensions* are per-project tunables in its header.
