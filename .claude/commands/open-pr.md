# /open-pr

Push current branch and create a pull request against main. Part of the gitflow subsystem. Invoked directly (`/open-pr`) or via natural-language triggers ("open pr", "submit for review", "open a pull request").

$ARGUMENTS

## Procedure

### Step 1: Verify branch state

```bash
git status
git branch --show-current
```

If working tree is dirty, stop and prompt the user to `/commit` or `/checkpoint` first.

### Step 2: Analyze branch diff

```bash
git diff --stat main..HEAD
git log --oneline main..HEAD
```

If branch is identical to main, stop and report.

### Step 3: Generate PR title

Conventional format: `<emoji> <type>: <description>`. Must match commitlint rules — the CI `commitlint.yml` check will block merge if malformed. Subject <72 chars, imperative mood.

**Do NOT include issue numbers in the title** (no `#123`, no `(#123)`, no `123:` prefix). A PR may close multiple issues; embedding one number is misleading. Issue linkage lives in the `Closes #N` line auto-prepended to the PR body — that's what GitHub auto-closes on merge.

### Step 4: Generate PR body

Structure:

```markdown
## Summary

<one-paragraph description of what this PR does from a user perspective>

## Changes

- <bullet 1>
- <bullet 2>
- ...

## Testing

<how this was verified — if nothing, say so>

## Signature-change attestations

<see "Attestation format" below — one type-check line, plus one file:line line per compiler-blind seam change>
```

Draw content from the diff and commit log. Do not invent features not in the diff.

### Attestation format

§XIV splits by whether the compiler can SEE the change. Match it:

**1. Type-visible changes** (TS/TSX signatures, exported types/interfaces/enums, a Zod schema used as a TS type) — the compiler IS the caller scan; a stale caller fails `check-types`. Attest the type-check ONCE. Do not enumerate per-symbol counts:

```
Signature changes: type-checked clean — the compiler reconciles every type-visible caller.
```

**2. Compiler-blind seam changes** (DB / Zod / schema FIELD renames referenced by string key, raw-SQL column/table names, string-keyed dispatch, cross-process / RPC / serverFn / webhook payload shapes, cross-language) — the compiler is blind here; a rename compiles green and breaks at runtime. Enumerate the reconciled call sites as `file:line`:

```
Callers scanned: <symbol> → apps/x/foo.ts:42, apps/y/bar.ts:88 (compiler-blind: <reason>).
Callers scanned: <symbol> → 0 callers (compiler-blind; private to apps/x/foo.ts).
```

Rules: `<symbol>` bare (no backticks); every listed `file:line` MUST be a site you actually opened and reconciled — the list is auditable against the diff, so do not pad it; `<reason>` names the seam (e.g. "raw-SQL column rename", "serverFn payload field"). Do **NOT** write `N references across M files` counts — that unfalsifiable count is exactly what the old format rotted into.

**Before composing the section**, grep the diff for the compiler-blind seams only (type-visible changes need no grep — the type-check covers them):

```bash
# DB / Zod / drizzle schema field renames or removals
git diff main..HEAD -- '**/schema*.ts' '**/schema/*.ts' '*/schemas/*.ts' \
  | grep -E '^[-][[:space:]]+[A-Za-z_]+:\s+(z\.|jsonb\(|text\(|integer\(|boolean\(|timestamp\(|uuid\(|varchar\()'
# raw-SQL identifiers + string-keyed dispatch removed/changed in the diff
git diff main..HEAD -- '*.ts' '*.tsx' | grep -E '^[-].*(sql`|queryKey|"type":|action:)'
```

If either surfaces a renamed/removed identifier, grep it repo-wide (INCLUDING `.sql` / `.py` / config / other apps), reconcile each caller, and add its `file:line` line. If neither surfaces anything, the type-check line alone is the complete attestation — a compiler-blind enumeration is required ONLY when a seam actually changed.

Constitution §XIV is the rule; this section is its enforcement surface.

### Step 5: Invoke the script

`/open-pr` does NOT touch `changelog.md`. The changelog is owned exclusively by `/deploy`, which composes the consolidated release entry from commit subjects since the last tag at version-bump time. Earlier versions of this command wrote a per-PR entry here too, which produced duplicate bullets in main's changelog after `/deploy` ran (one from the feature-branch insertion, one from the release-branch insertion). Single-writer fixes the duplication structurally — there is no flag to opt back into per-PR changelog inserts.

```bash
.claude/skills/gitflow/scripts/open-pr.sh \
  --title "<conventional title>" \
  --body "<PR body markdown>"
```

Optional: `--draft` to open as draft PR, `--base <branch>` if targeting something other than main.

### Step 6: Wait for PR readiness

`open-pr.sh` has already posted an explicit `/gemini review` comment on the PR (Gemini's auto-review on PR open is disabled in `.gemini/config.yaml: pull_request_opened.code_review: false`; reviews are comment-driven). If the post failed, the script exited 9 — surface the failure; do not proceed to wait.

Invoke the readiness wait — blocks until CI required checks pass AND (unless `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json`) Gemini has posted a review against the current HEAD. The wait reads the trigger-comment history to decide whether a Gemini review is expected; for `/open-pr` it always is, because the script just posted the trigger.

```bash
.claude/skills/gitflow/scripts/wait-for-pr-ready.sh
```

Status updates print every poll cycle (~30s). The user is sitting at the keyboard during this — that's the point of the wait, no other infra needed.

Exit handling:
- `0` → PR is ready. Continue to Step 8.
- `2` → CI failed. Surface the failing check name and PR URL; stop. The user fixes locally and pushes; the failing CI gate is the signal to act.
- `3` → timeout (default 15min). Surface the diagnostic message the script printed (likely Gemini queued/rate-limited, or CI legitimately slow). The user decides: re-invoke with `--timeout-min <larger>`, or — only if Gemini is genuinely absent — set `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` to opt out.
- `5` → user pressed Ctrl-C. Stop cleanly, no further steps.

### Step 7: Hand off based on Gemini findings count

The wait script's ready message includes a `findings=N` count whenever Gemini posted a review. Surface that count to the user and tailor the handoff prompt to it:

| Wait output | Prompt |
|---|---|
| `Gemini=skipped` (GEMINI_NOT_INSTALLED=true) | `PR #<N> ready. /merge when you're set.` |
| `Gemini=no-trigger-for-HEAD` (post failed silently or repo opted out) | `PR #<N> ready (CI only). /merge when you're set.` |
| `Gemini=posted, findings=0` | `PR #<N> ready. Gemini reviewed clean — /merge when you're set.` |
| `Gemini=posted, findings=N` (N > 0) | `PR #<N> ready. Gemini raised <N> finding(s) — run /triage to walk them, or /merge to ship without triage.` |

Do NOT auto-invoke `/triage` and do NOT auto-invoke `/merge`. The user decides per finding count. The explicit handoff prevents the "trapped in a flow" feeling and lets them abandon cleanly.

If the user runs `/triage` and lands a fix commit via `/commit --review`, that push posts a fresh `/gemini review` comment which arms a new review cycle. The next `/merge` will re-run `wait-for-pr-ready.sh` (called from `merge.sh`) and gate on the new cycle automatically. If the fix commit went out via `/commit --no-review`, no trigger is posted and `/merge` proceeds on CI alone.

### Step 8: Report

- PR created: surface the PR URL
- Script failure modes (Step 5 — open-pr.sh):
  - No gh CLI and no $GITHUB_TOKEN: user setup issue
  - Branch not pushed / push rejected: git state issue
  - API error: surface GitHub's response
- Wait failure modes (Step 6 — wait-for-pr-ready.sh): see exit handling above

## What happens after

On PR open:
- `ci.yml` runs typecheck + Biome + Semgrep + tests (if installed)
- `commitlint.yml` validates the PR title format (if installed)

`changelog.md` is **not** modified on the feature branch. It receives one consolidated release entry at `/deploy` time, covering every commit since the last `v*.*.*` tag — see HANDBOOK §6.5.

Post-merge, **nothing fires automatically**. To ship to production, run `/deploy` — it bumps version, writes the consolidated changelog entry, tags, pushes, and triggers `deploy.yml` (which MUST be configured with `workflow_dispatch:` only — see HANDBOOK §11.4).

## Blocking conditions

- Working tree dirty: commit or checkpoint first
- Current branch is `main`: cannot open a PR against itself
- No remote configured: add `origin` remote
- Neither `gh` nor `$GITHUB_TOKEN` available: auth setup needed
