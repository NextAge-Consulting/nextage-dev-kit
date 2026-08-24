# Gitflow Cheat Sheet

One-page reference for day-to-day work in a kit-enabled project. For internals and architecture, see `handbook.md`.

---

## Starting a session

Every coding session starts with `/work`. It puts you on the branch your work belongs on, in the project checkout.

```
/work                              # on main: cut a fresh wip/<abbrev>-<timestamp> branch. On a branch: resume it.
/work 23                           # on main: cut a branch derived from issue #23's title, and link the issue
/work --retrieve feat/teammate-fix # fetch a teammate's branch and switch to it (refuses if your tree is dirty)
```

What happens automatically (issue mode, on `main`):
- **Local main is fast-forwarded from `origin/main` first**, so the branch starts from current code.
- A branch is cut from the issue title (e.g. `feat/add-email-to-users`).
- Issue **linked to the branch** (stored in git config), **assigned to you**, **moved to "In Progress"** on the project board.
- Claude **reads the issue body + comments** and proposes an approach before any code is written.

What happens automatically (issue mode, already on a feature branch):
- Behaves like `/link`: the issue is added to the branch you are on. No new branch.

What happens automatically (no issue, on `main`):
- **Local main is fast-forwarded from `origin/main` first.**
- A `wip/<abbrev>-<timestamp>` branch is cut off fresh `origin/main`.
- The branch keeps its `wip/` name until your first `/commit`, which renames it to `<type>/<slug>` derived from the commit message (e.g. `wip/lg-2026-05-12-153000Z` → `feat/dealer-filter-fix`).
- `<abbrev>` resolves from `PROJECT_ABBREV` in `.claude/sync-substitutions.json` (e.g. `lg`, `kit`, `ms`); falls back to the project's directory basename if unset. Run `/sync-dev-kit` to populate. Lets the Agents view distinguish concurrent wip/ branches across projects.

What happens automatically (no issue, already on a feature branch):
- Resume it. Same body of work continues, nothing refreshed — use `/catchup` when you want the latest main.

**Edits already in the tree come along.** If you started editing before typing `/work`, `git checkout -b` carries those changes onto the new branch. The one consequence is that `main` is not refreshed in that case (a fast-forward on a dirty tree would either fail or strand the edits) — `/work` says so, and `/catchup` closes the gap.

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
                # does NOT touch changelog.md — single-writer model, /deploy owns it (handbook §6.4)
/catchup      # on main: fast-forward local main from origin/main (just want latest code)
                # on a feature branch: merge updated origin/main INTO the feature branch
/e2e          # behavioral E2E via agent-browser (asks a scope question — see next section)
/merge        # local prod build gate, verify CI green, squash-merge, land back on main,
                # delete the merged branch
                # does NOT transition the project board (Staged stays until /deploy)
                # post-merge: if landing on main changed package*.json, merge.sh runs `npm ci`
                #   so node_modules isn't left stale (bites the next /merge build gate)
/deploy       # bump version, tag, push, trigger deploy workflow(s)
                # transitions every closed issue in the release → "Done" on the project board

/ship-main    # THE EXCEPTION: conventional commit straight onto main — no branch, no PR, no CI
                # for quick infra / config / emergency work you accept shipping unreviewed
                # fires only on its own triggers ("ship to main", "infra commit"); a bare
                #   "commit" always routes to /commit, which auto-branches instead
                # the message still must be conventional — the next /deploy reads it
```

`/catchup` is the single "refresh from origin" command — behavior depends on the branch you're on. On main, it fast-forwards local main (use this when starting a session after someone else has merged + deployed and you want your local code current). On a feature branch, it merges `origin/main` INTO the branch via `--no-ff` (use when `gh pr view <N>` reports `mergeable: CONFLICTING`). On conflicts: edit the affected files, then `/catchup --continue` — or `/catchup --abort` to back the merge out entirely. See handbook §4.6.

**Project board lifecycle:**

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
/work 23             ← start session (local main fast-forwarded; branch cut, issue linked, board → In Progress)
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

Picking up tomorrow on unfinished work: same launch, just `/work` (no args). You are still on yesterday's branch; `/work` sees that and resumes exactly where you left off.

---

## What NOT to do

- Raw `git commit`, `git push`, `git merge`, `git checkout <file>`, `git reset`, `git revert`, `git clean`, `git restore` — **blocked by `git-guard.sh`**. If you genuinely need one, prefix with `SKIP_GIT_GUARD=1` and state the reason.
- Cherry-pick specific files into a commit — gitflow always commits ALL changes. If you need to split, ask.
- Run `/sync-dev-kit` if you're a consumer developer — that's maintainer-only.
- Run database migrations from Claude — always human-driven.

---

## Troubleshooting quickies

| Symptom | Fix |
|---------|-----|
| "Not on a feature branch" from `/commit` | You are on `main`. `/commit` auto-branches from there, so this should not block you — if it does, run `/work` to cut the branch explicitly. |
| `/merge` refuses — "CI not green" | Open the Actions tab, find the failure, fix, `/commit`, re-run `/merge`. |
| `/e2e` — "no flows match this diff" | Expected for pure-docs / workflow-only PRs on the diff-scoped option. Reports clean, runs nothing. |
| `/e2e` — dev server not reachable | Claude checks port first and starts if free. If that fails, the project's dev-server command may differ; check `.claude/rules/dev-server.md` for the project's convention. |
| `/open-pr` — "no commits ahead of main" | You haven't committed yet. Run `/commit` or `/checkpoint` first. |
| `/link` refuses on main | Correct — linking only makes sense on a feature branch. Use `/work <issue>` to start a feature branch first. |
| Issue didn't move on the project board (In Progress / Staged / Done) | Board transitions are now **fail-loud**. If `GITFLOW_PROJECT_ID` is set and the transition didn't fire, the script exited non-zero with the cause. Most common cause is the gh token missing `project` scope (`gh auth refresh -s project`), then the issue not being on the configured project (enable the project's "Auto-add to project" workflow). Empty `GITFLOW_PROJECT_ID` = feature off, silent skip. |
| `/work` says it could not refresh main | The pre-branch fast-forward failed (usually `gh` auth scope or network). `/work` does not block — it cuts the branch off local `main` and tells you. Fix `gh auth status`, then `/catchup` to pull the latest into your branch. |
| `/catchup` aborts: "local main is AHEAD" or "DIVERGED" | Local main has commits not on origin/main. Anomalous under gitflow's model (primary is read-only). Inspect with `git log origin/main..HEAD`. Most likely cause is a `/ship-main` commit that has not been pushed, or a commit made outside gitflow. Inspect, push or resolve manually, then retry `/catchup`. |
| `current/` doesn't exist yet | Run `/work` (no args). It creates `current/` on a fresh `wip/<abbrev>-<timestamp>` branch and enters it. |
| `/sync-dev-kit` keeps flagging `.claude/settings.json` as `kit-only` (or `conflict`) every sync even though you haven't touched it | settings.json is compared as jq-canonicalized JSON (handbook §9.6), so key order and indentation should never surface as a diff. If it still flags with no real difference, the canonicalization in `sync-dev-kit.sh` (`canonicalize_settings` / `sha256_settings_kit`) is broken — open a kit bug. |
| `/commit` succeeded at commit but failed at push with "upstream branch ... does not match the name of your current branch" | The branch is tracking `origin/main` rather than its own remote ref. Re-trigger just the push: `.claude/skills/gitflow/scripts/commit.sh --push-only`. `safe_push` (in `branch_helpers.sh`) corrects the upstream and pushes. See handbook §4.5. |
| `gh pr view <N>` reports `mergeable: CONFLICTING` after another PR shipped | Run `/catchup` on the affected branch. It merges `origin/main` in via an explicit merge commit and pushes. On conflicts, edit the affected files, then `/catchup --continue`. See handbook §4.6. |
