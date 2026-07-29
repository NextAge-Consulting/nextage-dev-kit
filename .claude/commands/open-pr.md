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

## Caller-scan attestations

<EXACTLY ONE LINE PER SYMBOL — see "Attestation format" below>
```

Draw content from the diff and commit log. Do not invent features not in the diff.

### Attestation format (Zero Tolerance — Gemini regex-matches the literal string)

The "Caller-scan attestations" section is matched by Gemini Code Assist against a strict regex. Prose, narrative wording, or paraphrasing fails the gate even when the information is technically present. Each line MUST be one of these exact templates, character-for-character (including the `→` U+2192 RIGHTWARDS ARROW, the periods, the parentheses, and the spacing):

```
Callers scanned: <symbol> → <N> references across <M> files, all updated.
Callers scanned: <symbol> → 0 references (private to <file>).
No signature changes.
```

Substitute only the angle-bracketed tokens:
- `<symbol>` — exported name, no backticks, no quotes (e.g. `loadProductDetail`, not `` `loadProductDetail` `` and not `the loadProductDetail function`)
- `<N>` — integer count from `findReferences` / grep
- `<M>` — integer file count
- `<file>` — relative path from repo root (e.g. `apps/shared/src/productDetail/productDetailLoaders.ts`)

**Correct (Gemini passes):**
```
## Caller-scan attestations

Callers scanned: loadProductDetail → 7 references across 4 files, all updated.
Callers scanned: ProductDetailPayload → 3 references across 2 files, all updated.
Callers scanned: normalizeVariantId → 0 references (private to apps/shared/src/productDetail/productDetailLoaders.ts).
```

**WRONG — these all fail the gate even though content is present:**
```
## Caller-scan attestations

- loadProductDetail: scanned 7 callers across 4 files, all updated.        ← bullet + prose, no →
- The loadProductDetail signature was changed; all 7 callers updated.       ← narrative
- Callers scanned for `loadProductDetail`: 7 refs in 4 files.               ← backticks, "refs in", missing →
- Callers scanned: loadProductDetail -> 7 references...                     ← ASCII `->` instead of `→`
- Callers scanned: loadProductDetail → 7 references in 4 files, updated.    ← "in" not "across", missing "all"
```

If unsure how to count: re-run `findReferences` or grep once more — do not guess and do not soften the language.

**Caller-scan attestation (constitution §XIV).** Before composing the section above, grep the branch diff against main for renamed / removed / reshaped exported declarations:

```bash
git diff main..HEAD -- '*.ts' '*.tsx' '*.mts' '*.cts' \
  | grep -E '^[-+](export (function|const|class|interface|type|enum|default)|export \{|export \*|^[A-Za-z_]+:\s+(z\.)?[A-Za-z]+\()'
```

Also grep for Zod / database schema field renames or removals:

```bash
git diff main..HEAD -- 'apps/**/schema.ts' '*/schemas/*.ts' \
  | grep -E '^[-+]\s+[A-Za-z_]+:\s+(z\.|jsonb\(|text\(|integer\(|boolean\(|timestamp\(|uuid\()'
```

For every changed signature surfaced, run `findReferences` (LSP) or `grep -rn 'symbolName' --include='*.ts' --include='*.tsx'` against the post-edit codebase to confirm all callers are reconciled in this branch. Each surfaced symbol becomes one attestation line. If the greps return nothing, write `No signature changes.` — empty-scan attestation is REQUIRED, not optional. The PR body without this section is incomplete.

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

Status updates print every poll cycle (~30s). Pete is sitting at the keyboard during this — that's the point of the wait, no other infra needed.

Exit handling:
- `0` → PR is ready. Continue to Step 8.
- `2` → CI failed. Surface the failing check name and PR URL; stop. Pete fixes locally and pushes; the failing CI gate is the signal to act.
- `3` → timeout (default 15min). Surface the diagnostic message the script printed (likely Gemini queued/rate-limited, or CI legitimately slow). Pete decides: re-invoke with `--timeout-min <larger>`, or — only if Gemini is genuinely absent — set `GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` to opt out.
- `5` → user pressed Ctrl-C. Stop cleanly, no further steps.

### Step 7: Hand off based on Gemini findings count

The wait script's ready message includes a `findings=N` count whenever Gemini posted a review. Surface that count to Pete and tailor the handoff prompt to it:

| Wait output | Prompt |
|---|---|
| `Gemini=skipped` (GEMINI_NOT_INSTALLED=true) | `PR #<N> ready. /merge when you're set.` |
| `Gemini=no-trigger-for-HEAD` (post failed silently or repo opted out) | `PR #<N> ready (CI only). /merge when you're set.` |
| `Gemini=posted, findings=0` | `PR #<N> ready. Gemini reviewed clean — /merge when you're set.` |
| `Gemini=posted, findings=N` (N > 0) | `PR #<N> ready. Gemini raised <N> finding(s) — run /triage to walk them, or /merge to ship without triage.` |

Do NOT auto-invoke `/triage` and do NOT auto-invoke `/merge`. Pete decides per finding count. The explicit handoff prevents the "trapped in a flow" feeling and lets him abandon cleanly.

If Pete runs `/triage` and lands a fix commit via `/commit --review`, that push posts a fresh `/gemini review` comment which arms a new review cycle. The next `/merge` will re-run `wait-for-pr-ready.sh` (called from `merge.sh`) and gate on the new cycle automatically. If the fix commit went out via `/commit --no-review`, no trigger is posted and `/merge` proceeds on CI alone.

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
