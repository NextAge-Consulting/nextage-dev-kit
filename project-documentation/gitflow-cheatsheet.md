# Gitflow Cheat Sheet

One-page reference for day-to-day work in a kit-enabled project. For internals and architecture, see `handbook.md`.

---

## Starting a session

Every coding session starts with `/work`. It puts you on the branch your work belongs on, in the project checkout.

```
/work                              # on main: refresh main and stay there. On a branch: resume it.
/work 23                           # link issue #23 to wherever you are standing. No branch is cut.
/work --retrieve feat/teammate-fix # fetch a teammate's branch and switch to it (refuses if your tree is dirty)
```

**`/work` never cuts a branch.** At session-init nobody knows yet whether this is a feature, an infra change, or a question answered from the handoff — and because `/ship-main` runs only on `main`, cutting a branch here would block the infra path before the session began. The branch arrives from the command that actually declares the path: `/commit` names it from your commit message, `/checkpoint` cuts a `wip/` one.

What happens automatically (no issue, on `main`):
- **Local main is fast-forwarded from `origin/main`**, unless the tree is dirty or the fetch fails — both say so plainly rather than blocking.
- You stay on `main`. Any issue link parked by an earlier session is surfaced.

What happens automatically (issue mode, anywhere):
- Issue **linked to the branch you are on** (stored in git config), **assigned to you**, **moved to "In Progress"** on the project board.
- Claude **reads the issue body + comments** and proposes an approach before any code is written.
- On `main` the link parks there and rides onto whichever branch your first `/commit` creates; `/ship-main` instead names it in a `Closes #N` line once you answer that it is code complete.

Where `wip/<abbrev>-<timestamp>` comes from: `/checkpoint` on `main` cuts it. The branch keeps that name until your first `/commit`, which renames it to `<type>/<slug>` from the commit message (e.g. `wip/lg-2026-05-12-153000Z` → `feat/dealer-filter-fix`). `<abbrev>` resolves from `PROJECT_ABBREV` in `.claude/sync-substitutions.json` (e.g. `lg`, `kit`, `ms`), falling back to the project's directory basename if unset. Run `/sync-dev-kit` to populate. Lets the Agents view distinguish concurrent wip/ branches across projects.

What happens automatically (no issue, already on a feature branch):
- Resume it. Same body of work continues, nothing refreshed — use `/catchup` when you want the latest main.

**Edits already in the tree come along.** If you started editing before typing `/work`, those changes stay exactly where they are and follow you onto whichever branch the first `/commit` or `/checkpoint` creates. The one consequence is that `main` is not refreshed in that case (a fast-forward on a dirty tree would either fail or strand the edits) — `/work` says so, and `/catchup` closes the gap.

**Distinguishing concurrent sessions in the Agents view.** The `wip/<abbrev>-<timestamp>` branch name does NOT surface as the session title in the Agents view or the Claude desktop/web view — those views show the session summary, not the branch. To label a session so concurrent work across projects is easy to tell apart, use the built-in `/rename <name>` slash command. The rename is reflected in both the Agents view and the Claude views.

---

## While working

```
/checkpoint      # fast WIP save — validation, push, no fuss
/commit          # full conventional commit with AI-generated message
npm test         # run vitest (if the project has test scaffolding)
npm run check-types  # tsc across all workspaces
npm run lint     # biome lint across the repo
semgrep scan --config auto --error <files>   # the CI security scan, on demand
```

Use `/checkpoint` freely for in-progress snapshots. Use `/commit` when a unit of work is coherent.

**`/commit` asks which linked issues are code complete** — finished, waiting for deployment. Each yes is marked on the branch and moves to Staged once the push lands. Answer in prose, or pass `/commit --complete 42,43`. `/checkpoint` never asks: a checkpoint is partway by definition.

**Every issue reaching Staged gets one comment for its author** — what was built, what they will see, and where it differs from what they asked. Claude writes it (shape: `skills/gitflow/references/staged-comment.md`) and the script posts it once the board has moved; you are not asked to approve the wording. It is posted once per issue, so `/open-pr` re-staging an issue `/commit` already staged posts nothing.

**An autonomous run may `/checkpoint`** as each deliverable finishes — the one git operation `/autonomous` authorizes without a fresh instruction. `/commit`, `/open-pr`, `/merge`, `/ship-main` and `/deploy` still wait for you.

`/commit` runs check-types, biome and semgrep itself before staging, so the CI equivalents of all three fire locally first — semgrep scoped to the files the commit touches, where CI scans the whole repo. `/checkpoint` deliberately does not: it is the fast WIP save, and a scan on every snapshot is friction on the one path built to have none.

---

## Found another issue that belongs on this branch?

```
/work #42
/work #42,#43
```

Adds the issue(s) to the current branch — including `main`, where the link parks until the first commit carries it onto a branch, or a `/ship-main` names it as code complete. Same side effects as `/work <issue>`: status transition, assignment, context dump. A PR body auto-prepends `Closes #42, #43`; a `/ship-main` commit gets the same line in its body for the issues marked code complete.

No new branch, no stash. Just link and keep working.

---

## Shipping

```
/open-pr      # push branch, create PR, auto-prepends `Closes #N` from linked issues
                # a gate: every linked issue must be code complete — any not yet marked is
                #   confirmed first ("Opening this PR marks #42 as Staged. Proceed?"); no → no PR
                # transitions every linked issue → "Staged" on the project board, and posts
                #   the Staged comment on each that has not had one
                # does NOT touch changelog.md — single-writer model, /deploy owns it (handbook §6.4)
/catchup      # on main: fast-forward local main from origin/main (just want latest code)
                # on a feature branch: merge updated origin/main INTO the feature branch
/e2e          # behavioral E2E via agent-browser (asks a scope question — see next section)
/merge        # local prod build gate, verify CI green, squash-merge, land back on main,
                # delete the merged branch
                # the squash commit is the PR's own title + body, so the `Closes #N`
                #   line reaches main whatever the repo's squash setting
                # does NOT transition the project board (Staged stays until /deploy)
                # post-merge: if landing on main changed package*.json, merge.sh runs `npm ci`
                #   so node_modules isn't left stale (bites the next /merge build gate)
/deploy       # bump version, tag, push, dispatch the deploy build(s)
                # moves every issue named by `Closes #N` in the release → the deploy status

/ship-main    # THE EXCEPTION: conventional commit straight onto main — no branch, no PR, no CI
                # for quick infra / config / emergency work you accept shipping unreviewed
                # fires only on its own triggers ("ship to main", "infra commit"); a bare
                #   "commit" always routes to /commit, which auto-branches instead
                # the message still must be conventional — the next /deploy reads it
                # asks which linked issues are code complete; only those get `Closes #N`,
                #   move to Staged (with their Staged comment) and are unlinked — the rest
                #   stay parked on main
```

`/catchup` is the single "refresh from origin" command — behavior depends on the branch you're on. On main, it fast-forwards local main (use this when starting a session after someone else has merged + deployed and you want your local code current). On a feature branch, it merges `origin/main` INTO the branch via `--no-ff` (use when `gh pr view <N>` reports `mergeable: CONFLICTING`). On conflicts: edit the affected files, then `/catchup --continue` — or `/catchup --abort` to back the merge out entirely. See handbook §4.6.

**Project board lifecycle:**

| State | Trigger |
|-------|---------|
| Todo | board default |
| In Progress | `/work <N[,N…]>` |
| Staged | `/commit` / `/ship-main` (issues answered code complete), `/open-pr` (every linked issue) — each gets its Staged comment |
| the deploy status (`Done`, `Deployed`, …) | `/deploy` (NOT `/merge`) |

Watch for:
- GitHub notification emails
- Repo → **Actions** tab for CI runs
- Whether a linked issue closes, and when, is GitHub configuration, not gitflow — see `github-project-board-setup.md` §3

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
- `Closes #N` is auto-injected by `/open-pr`. gitflow never closes an issue: with no board, GitHub closes it on merge; with a board, the board's "Auto-close issue" workflow closes it when it reaches the column you chose (`github-project-board-setup.md` §3). The board card moves to the deploy status at `/deploy`, not at `/merge`.
- Board lifecycle: Todo → **In Progress** (`/work <N>`) → **Staged** (code complete: `/commit`, `/ship-main`, `/open-pr`) → **deploy status** (`/deploy`).
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

Each run writes one self-contained report — screenshots embedded, no other files — named `logs/e2e/<project>-e2e-<YYYYMMDD>.html` (the repo directory lower-cased, the run's local date), so a report sent outside the repo still says what it is and the next day's run does not overwrite it.

Dev server lifecycle governed by `.claude/rules/dev-server.md` — Claude checks port first, uses it if occupied, starts it if free, never kills a server it didn't start. Run `/e2e` locally when you want behavioral verification; cloud sessions can't run it (no browser).

---

## The whole flow at a glance

```
/work 23             ← start session (local main fast-forwarded; issue linked, board → In Progress)
... work ...
/checkpoint          ← save progress (repeat as needed)
... more work ...
/work 42             ← another issue joins this branch (board → In Progress for #42)
... finish ...
/commit              ← coherent final commit; answer "#23, #42 code complete? → yes" (board → Staged for both, each with its Staged comment)
/open-pr             ← submit for review (Closes #23, #42 auto-added; both already complete, so no question)
... CI runs, Gemini reviews ...
/triage              ← walk Gemini items one at a time (fix or skip, your call)
/e2e                 ← optional manual verification
/merge               ← ship after CI green: squash-merge, land back on main, delete the merged branch. Board state unchanged (still Staged).
/deploy              ← release: bump version, tag, dispatch the deploy build(s). Board → the deploy status for every issue this release names in `Closes #N`.
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
| "Not on a feature branch" from `/commit` | You are on `main`. `/commit` auto-branches from there, naming the branch from your commit message, so this should not block you — if it does, `/checkpoint` cuts a `wip/` branch. |
| `/merge` refuses — "CI not green" | Open the Actions tab, find the failure, fix, `/commit`, re-run `/merge`. |
| `/e2e` — "no flows match this diff" | Expected for pure-docs / workflow-only PRs on the diff-scoped option. Reports clean, runs nothing. |
| `/e2e` — dev server not reachable | Claude checks port first and starts if free. If that fails, the project's dev-server command may differ; check `.claude/rules/dev-server.md` for the project's convention. |
| `/open-pr` — "no commits ahead of main" | You haven't committed yet. Run `/commit` or `/checkpoint` first. |
| Linked an issue while on main | Fine. The link parks on `main` and rides onto whichever branch your first `/commit` creates; `/ship-main` names it in `Closes #N` once you answer it is code complete, and an incomplete one stays parked. `/work` surfaces any link left parked by an abandoned session. |
| Issue didn't move on the project board (In Progress / Staged / deploy status) | Board transitions are **fail-loud**. If `GITFLOW_PROJECT_ID` is set and the transition didn't fire, the script exited non-zero with the cause. Most common cause is the gh token missing `project` scope (`gh auth refresh -s project`), then the issue not being on the configured project (enable the project's "Auto-add to project" workflow), then an empty `GITFLOW_STATUS_*` key — all four are required once a board is configured. Empty `GITFLOW_PROJECT_ID` = feature off, silent skip. |
| Exit 11 from `/commit`, `/ship-main` or `/open-pr` | The git side landed; only the board update failed. After `/commit`, `/open-pr` sets every linked issue to Staged again; after `/ship-main`, the next `/deploy` still moves the named issues; after `/open-pr`, set the status on the board once the cause is fixed. |
| `/open-pr` exits 12 | A linked issue is not code complete and was not confirmed. Nothing was pushed. Confirm it, or keep working and `/commit` when it is done. |
| `--complete` exits 2 | It named an issue not linked on this branch, or an issue reaching Staged has no Staged comment in `--notes`. Nothing was committed or pushed — link it with `/work <N>`, fix the number, or write the missing comment. |
| Exit 13 from `/commit`, `/ship-main` or `/open-pr` | Everything landed — commit, push, board — except a Staged comment. The script printed the exact `gh issue comment` that posts it. |
| Issue closed too early, or never closed | GitHub configuration, not gitflow: the repository's auto-close setting and the board's "Auto-close issue" workflow. See `github-project-board-setup.md` §3. |
| `/work` says it could not refresh main | The fast-forward failed (usually `gh` auth scope or network) or the tree was dirty. `/work` does not block — you stay on local `main` and it tells you. Fix `gh auth status`, then `/catchup`. |
| `/catchup` aborts: "local main is AHEAD" or "DIVERGED" | Local main has commits not on origin/main. Anomalous under gitflow: work lands on `main` only through `/merge` or `/ship-main`. Inspect with `git log origin/main..HEAD`. Most likely cause is a `/ship-main` commit that has not been pushed, or a commit made outside gitflow. Inspect, push or resolve manually, then retry `/catchup`. |
| `/sync-dev-kit` keeps flagging `.claude/settings.json` as `kit-only` (or `conflict`) every sync even though you haven't touched it | settings.json is compared as jq-canonicalized JSON (handbook §9.6), so key order and indentation should never surface as a diff. If it still flags with no real difference, the canonicalization in `sync-dev-kit.sh` (`canonicalize_settings` / `sha256_settings_kit`) is broken — open a kit bug. |
| `/commit` succeeded at commit but failed at push with "upstream branch ... does not match the name of your current branch" | The branch is tracking `origin/main` rather than its own remote ref. Re-trigger just the push: `.claude/skills/gitflow/scripts/commit.sh --push-only`. `safe_push` (in `branch_helpers.sh`) corrects the upstream and pushes. See handbook §4.5. |
| `gh pr view <N>` reports `mergeable: CONFLICTING` after another PR shipped | Run `/catchup` on the affected branch. It merges `origin/main` in via an explicit merge commit and pushes. On conflicts, edit the affected files, then `/catchup --continue`. See handbook §4.6. |
