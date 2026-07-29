# Gitflow Cheat Sheet

One-page reference for day-to-day work in a kit-enabled project. For internals and architecture, see `HANDBOOK.md`.

---

## Starting a session

Every coding session starts with `/work`. It enters (or creates) the project's worktree at `<project>/.claude/worktrees/current/` so the session edits files there, not in the primary repo folder.

```
/work                              # re-enter current/ if it exists; otherwise create it on wip/<abbrev>-<timestamp>
/work 23                           # re-enter or create current/ on a branch derived from issue #23's title; link the issue
/work --new big-feature            # create a compartment at .claude/worktrees/big-feature/ on wip/big-feature for parallel work
/work --retrieve feat/alan-fix     # fetch and check out alan's branch (in current/ if clean, compartment if dirty)
/work --discard big-feature        # remove a compartment (refuses if dirty unless --force)
```

What happens automatically (issue mode, `current/` missing):
- **Local main is fast-forwarded from `origin/main` first** — fail-loud if dirty, offline, or diverged. Ensures the new worktree is based on the latest main.
- Worktree at `<project>/.claude/worktrees/current/` is created on a feature branch derived from the issue title (e.g. `feat/add-email-to-users`).
- Issue **linked to the branch** (stored in git config), **assigned to you**, **moved to "In Progress"** on the project board.
- Claude **reads the issue body + comments** and proposes an approach before any code is written.
- Claude session is moved into the worktree so subsequent edits land in the right place.

What happens automatically (issue mode, `current/` already exists):
- Behaves like `/link`: the issue is added to the existing branch in `current/`. No new worktree, no new branch.

What happens automatically (no issue, `current/` missing):
- **Local main is fast-forwarded from `origin/main` first** — fail-loud if dirty, offline, or diverged.
- Worktree at `current/` is created on a `wip/<abbrev>-<timestamp>` branch off fresh `origin/main`.
- The branch keeps its `wip/` name until your first `/commit`, which renames it to `<type>/<slug>` derived from the commit message (e.g. `wip/lg-2026-05-12-153000Z` → `feat/dealer-filter-fix`).
- `<abbrev>` resolves from `PROJECT_ABBREV` in `.claude/sync-substitutions.json` (e.g. `lg`, `kit`, `ms`); falls back to the project's directory basename if unset. Run `/sync-starter-kit` to populate. Lets the Agents view distinguish concurrent wip/ branches across projects.

What happens automatically (no issue, `current/` already exists):
- Re-enter the existing worktree on its existing branch. Same body of work continues.

**Primary repo folder always sits on `main`, untouched.** Open `<project>/.claude/worktrees/current/` in your editor — that's where source code lives during the session. Plain-CLI workflows like `/sync-starter-kit` operate against the primary; do not edit there manually.

**Why current/ is always on a non-main branch.** Git refuses to check out the same branch in two worktrees, and primary owns `main`. So `current/` is given its own branch (`wip/*` or feature) from the moment it's created. The branch starts as `wip/<abbrev>-<timestamp>` for no-issue invocations, gets renamed at first commit. There is no "current/ briefly on main" intermediate state.

**Distinguishing concurrent sessions in the Agents view.** The `wip/<abbrev>-<timestamp>` branch name does NOT surface as the session title in the Agents view or the Claude desktop/web view — those views show the session summary, not the branch. To label a session so concurrent work across projects is easy to tell apart, use the built-in `/rename <name>` slash command. The rename is reflected in both the Agents view and the Claude views.

---

## While working

```
/checkpoint      # fast WIP save — validation, push, no fuss
/commit          # full conventional commit with AI-generated message
npm test         # run vitest (if the project has test scaffolding)
npm run check-types  # tsc across all workspaces
npm run lint     # biome lint across the repo
```

Use `/checkpoint` freely for in-progress snapshots. Use `/commit` when a unit of work is coherent. Tests + check-types + lint also run in the pre-commit hook and CI — these are the local equivalents.

---

## Found another issue that belongs on this branch?

```
/link #42
/link #42,#43
```

Adds the issue(s) to the current branch. Same side effects as `/work <issue>`: status transition, assignment, context dump. The eventual PR body auto-prepends `Closes #42, #43`.

No new branch, no stash. Just link and keep working.

---

## Shipping

```
/open-pr      # push branch, create PR, auto-prepends `Closes #N` from linked issues
                # transitions every linked issue → "Staged" on the project board
                # does NOT touch changelog.md — single-writer model, /deploy owns it (HANDBOOK §6.4)
/sync         # on main: fast-forward local main from origin/main (just want latest code)
                # on a feature branch: merge updated origin/main INTO the feature branch
/e2e          # behavioral E2E via agent-browser (asks a scope question — see next section)
/merge        # verify CI green, squash-merge, pull main back
                # does NOT transition the project board (Staged stays until /deploy)
                # post-merge: Claude must invoke ExitWorktree({action:"keep"}) — the worktree
                # was deleted on disk but the session is still bound to it; first Bash call
                # otherwise fails with `posix_spawn '/bin/sh' ENOENT` (HANDBOOK §6.3 step 4)
                # post-merge: if the squash changed package*.json, merge.sh runs `npm install`
                #   in primary so its node_modules isn't left stale (bites /deploy's build gate)
                # post-merge: a burst of stale LSP errors pointing at the removed worktree path is
                #   EXPECTED + harmless (the LSP lost its root) — ignore, don't re-typecheck main
/deploy       # bump version, tag, push, trigger deploy workflow(s)
                # transitions every closed issue in the release → "Done" on the project board
```

`/sync` is the single "refresh from origin" command — behavior depends on the branch you're on. On main, it fast-forwards local main (use this when starting a session after someone else has merged + deployed and you want your local code current). On a feature branch, it merges `origin/main` INTO the branch via `--no-ff` (use when `gh pr view <N>` reports `mergeable: CONFLICTING`). On conflicts: edit the affected files, then `/sync --continue`. See HANDBOOK §4.6.

**Project board lifecycle (4 states):**

| State | Trigger |
|-------|---------|
| Todo | board default |
| In Progress | `/work <N>` or `/link <N>` |
| Staged | `/open-pr` |
| Done | `/deploy` (NOT `/merge`) |

Watch for:
- GitHub notification emails
- Repo → **Actions** tab for CI runs
- Linked issues **auto-close on merge** (via `Closes #N` in PR body); their board card moves to Done at `/deploy`

---

## After `/open-pr` — triaging the PR

CI (4 jobs) runs on every PR push. Gemini Code Assist runs only when a `/gemini review` comment is posted on the PR (auto-trigger is OFF in `.gemini/config.yaml`). `/open-pr` always posts the trigger; `/commit` asks you whether to post (or pass `--review` / `--no-review` to skip the prompt); `/deploy` never posts on release PRs.

| What | Gate? | Typical time |
|---|---|---|
| `check-types`, `biome`, `lint`, `semgrep` | **required** | <2 min total (parallel) |
| Gemini review | advisory, comment-triggered | ~5 min first pass, faster on incremental |

```
gh pr checks <N>            # snapshot of all checks
gh pr checks <N> --watch    # stream until terminal state
gh pr view <N> --web        # open the PR in your browser
/triage                     # walk Gemini items one at a time (see below)
```

**Triage order:**

1. **Required CI red?** Fix that first — everything else waits. Click the failing check → read the finding → commit a fix → push. CI re-runs. Gemini reviews only if the commit went out with `--review` (or you accepted the prompt).
2. **Gemini comments.** Severity labels (`Critical | High | Medium | Low`):
   - 🔴 Critical / High — usually act on these
   - 🟡 Medium — judgment call; act or reply declining
   - 🟢 Low — advisory; ignore or reply
3. **Every thread ends** with a fix-push OR a reply. Don't leave threads silent.

Gemini does NOT register a separate check entry on the PR — its review surface is inline comments + PR-level summary only. Required gates are the four CI jobs above.

### `/triage` — one-at-a-time Gemini walkthrough

When you want to work through Gemini's feedback methodically instead of scanning the PR page:

```
/triage           # current branch's PR
/triage 142       # specific PR number
```

Claude pulls the open Gemini items, then for each one presents: location, severity, the concern, the proposed fix, and a recommendation. **You decide per-item** — "fix", "skip", "reply with X", or ask questions. Claude acts only after your call, then advances to the next item. One commit at the END of triage batches every fix + every carve-out comment. At that final `/commit`, decide whether to trigger another Gemini pass via `--review` (early triage cycles) or `--no-review` (late cycles when you've decided to ship). No batching, no auto-classification.

**Declined findings get an inline source comment.** When you skip a Gemini item ("not applicable", "false positive"), Claude both posts a threaded PR reply AND stages a one-to-three-line inline comment at the flagged line stating the carve-out reason (e.g. `// §VI safe: absolute-instant audit timestamp, not user-facing`). The PR reply is the audit trail; the inline comment is the durable record. Without the inline comment, Gemini re-flags the same line on the next push (reviews are stateless across cycles) and you re-triage the same item.

Faster than scrolling the PR page when there are more than ~3 actionable items. Stop anytime; resume with `/triage` again.

### Gemini commands (comment on the PR)

| Command | Use when |
|---|---|
| `/gemini review` | Trigger a review (the gitflow scripts post this for you at `/open-pr` and `/commit --review`; post manually for ad-hoc reviews) |
| `/gemini summary` | Regenerate the PR summary |
| `@gemini-code-assist <question>` | Ask Gemini in-thread |
| `/gemini help` | List available commands |

### Project board / issue behavior

- A new PR appears on the project board as its own card (PRs and issues share GitHub's number sequence — PR #117 ≠ issue #117 being created).
- Linked issues (`Closes #N` auto-injected by `/open-pr`) close on **merge**, not on PR open. Their board card moves to **Done** at `/deploy`, not at `/merge`.
- Board lifecycle: Todo → **In Progress** (`/work`/`/link`) → **Staged** (`/open-pr`) → **Done** (`/deploy`).
- No issue is created automatically on merge — pass or fail.
- Board transitions are **fail-loud** when board integration is configured (`GITFLOW_PROJECT_ID` set). Missing scope, wrong option ID, or issue not on the board → script exits non-zero with the cause.

---

## E2E verification (`/e2e`)

Claude drives `agent-browser` through plain-English flow files; failure is detected behaviorally. Not a scripted test suite. Flow files live at `apps/shared/test/e2e/*.md` (monorepo layout) or `test/e2e/*.md` (flat layout).

```
/e2e               # ask the scope question: diff-scoped / all / select specific (multiselect)
/e2e all           # force-run every flow regardless of diff (no question)
/e2e <flow-name>   # run a single flow by `name:` frontmatter value (no question)
```

**`/e2e` is standalone.** It runs only when you invoke it — it is not wired into `/merge` and `/merge` never asks about it. A red flow is the signal to stop and fix before you ship; acting on it is your call. `/e2e all` skips the diff check; a docs-only diff matches zero flows on the diff-scoped option.

Dev server lifecycle governed by `.claude/rules/dev-server.md` — Claude checks port first, uses it if occupied, starts it if free, never kills a server it didn't start. Run `/e2e` locally when you want behavioral verification; cloud sessions can't run it (no browser).

---

## The whole flow at a glance

```
/work 23             ← start session (local main fast-forwarded; worktree entered, issue linked, branch created, board → In Progress)
... work ...
/checkpoint          ← save progress (repeat as needed)
... more work ...
/link 42             ← another issue joins this branch (board → In Progress for #42)
... finish ...
/commit              ← coherent final commit
/open-pr             ← submit for review (Closes #23, #42 auto-added; board → Staged for both)
... CI runs, Gemini reviews ...
/triage              ← walk Gemini items one at a time (fix or skip, your call)
/e2e                 ← optional manual verification
/merge               ← ship after CI green; current/ removed (NOT auto-recreated); primary syncs to new main. Board state unchanged (still Staged). Next /work creates a fresh current/.
/deploy              ← release: bump version, tag, trigger deploy workflow(s). Board → Done for every issue closed by this release.
```

Picking up tomorrow on unfinished work: same launch, just `/work` (no args). The worktree is still there with yesterday's branch checked out; you resume exactly where you left off.

---

## What NOT to do

- Raw `git commit`, `git push`, `git merge`, `git checkout <file>`, `git reset`, `git revert`, `git clean`, `git restore` — **blocked by `git-guard.sh`**. If you genuinely need one, prefix with `SKIP_GIT_GUARD=1` and state the reason.
- Cherry-pick specific files into a commit — gitflow always commits ALL changes. If you need to split, ask.
- Run `/sync-starter-kit` if you're Alan — that's Pete-only.
- Run database migrations from Claude — always human-driven.

---

## Troubleshooting quickies

| Symptom | Fix |
|---------|-----|
| "Not on a feature branch" from `/commit` | Shouldn't happen under the current model — worktrees never sit on `main`. If it does, you're inside the primary repo (which is on `main`). Stop, run `/work` from a parent directory to get into a worktree. |
| `/merge` refuses — "CI not green" | Open the Actions tab, find the failure, fix, `/commit`, re-run `/merge`. |
| `/e2e` — "no flows match this diff" | Expected for pure-docs / workflow-only PRs on the diff-scoped option. Reports clean, runs nothing. |
| `/e2e` — dev server not reachable | Claude checks port first and starts if free. If that fails, the project's dev-server command may differ; check `.claude/rules/dev-server.md` for the project's convention. |
| `/open-pr` — "no commits ahead of main" | You haven't committed yet. Run `/commit` or `/checkpoint` first. |
| `/link` refuses on main | Correct — linking only makes sense on a feature branch. Use `/work <issue>` to start a feature branch first. |
| Issue didn't move on the project board (In Progress / Staged / Done) | Board transitions are now **fail-loud**. If `GITFLOW_PROJECT_ID` is set and the transition didn't fire, the script exited non-zero with the cause. Most common cause is the gh token missing `project` scope (`gh auth refresh -s project`), then the issue not being on the configured project (enable the project's "Auto-add to project" workflow). Empty `GITFLOW_PROJECT_ID` = feature off, silent skip. |
| `/work` aborts: "local main could not be refreshed" | The pre-create main fast-forward failed. Check `gh auth status` — usually the gh auth scope is missing or the network is offline. If local main has DIVERGED (anomalous), inspect `git log origin/main..HEAD` in the primary repo. |
| `/sync` aborts: "local main is AHEAD" or "DIVERGED" | Local main has commits not on origin/main. Anomalous under gitflow's model (primary is read-only). Inspect with `git log origin/main..HEAD`. Likely cause: someone committed directly to main outside gitflow. Resolve manually before /sync retries. |
| Editor shows stale code | You opened the primary repo folder. Open `<project>/.claude/worktrees/current/` instead — that's where source lives during a session. |
| `current/` doesn't exist yet | Run `/work` (no args). It creates `current/` on a fresh `wip/<abbrev>-<timestamp>` branch and enters it. |
| `git status` shows a `.venv` (or other) symlink as a new file | Add it to `.gitignore`. Claude Code auto-symlinks listed dirs (`worktree.symlinkDirectories` in `settings.json`) and the symlink shouldn't be tracked. |
| Dev server crashes immediately in a worktree (missing `.env` / `process.env.X` undefined), or `npm run dev` reports missing modules | You're in a half-built worktree — created via `EnterWorktree` directly instead of `/work`. The canonical `/work` path runs `apply_worktree_symlinks` (which symlinks `.env` from primary) and `run_post_create` (which runs `npm install`); `EnterWorktree(name=...)` skips both empirically. Fix: `ExitWorktree({action:"keep"})` then `/work` — re-entry heals the symlinks; if `node_modules` is still missing, `cd` into the worktree and run the project's install command. The `worktree-guard.sh` PostToolUse hook surfaces a system-reminder when this happens — read it. See HANDBOOK §3.2 and `rules/worktree.md`. |
| `/sync-starter-kit` keeps flagging `.claude/settings.json` as `kit-only` (or `conflict`) every sync even though you haven't touched it | The silent-overlay reconciler in `sync-starter-kit.sh` (HANDBOOK §9.6) should keep populated `worktree.postCreate` from surfacing as a diff. (1) Verify `jq '.worktree.postCreate' .claude/settings.json` is a populated array (not `[]` or missing). If empty, populate via the §9.9 walkthrough (re-run `/sync-starter-kit` — Step 1.6 fires when postCreate is empty) or edit settings.json manually. (3) If postCreate IS populated and sync still flags settings.json, the overlay logic in `sync-starter-kit.sh` (`overlay_settings_project_owned` / `sha256_settings_kit`) is broken — open a kit bug. |
| `/commit` succeeded at commit but failed at push with "upstream branch ... does not match the name of your current branch" | Pre-fix worktree creation left the branch tracking `origin/main` instead of itself. Re-trigger just the push: `.claude/skills/gitflow/scripts/commit.sh --push-only` from inside the affected worktree. `safe_push` (in `branch_helpers.sh`) corrects the upstream and pushes. New worktrees created after the fix won't hit this (work.sh now passes `--no-track`). See HANDBOOK §4.5. |
| `gh pr view <N>` reports `mergeable: CONFLICTING` after another PR shipped | Run `/sync` on the affected branch. It merges `origin/main` in via an explicit merge commit and pushes. On conflicts, edit the affected files, then `/sync --continue`. See HANDBOOK §4.6. |
| `current/` is orphaned on an old branch (body of work shipped via a different compartment) | `/work --discard current --force` removes the worktree + lets the next `/work` recreate it fresh. The `--force` is required — `current/` is the persistent workspace and never auto-discards. |
