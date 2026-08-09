# /commit

Full conventional commit with AI-generated message. Part of the gitflow subsystem (layer 3). Invoked directly by the user (`/commit`) or by Claude in response to natural-language triggers ("commit this", "commit the changes") via the gitflow skill.

$ARGUMENTS

## Procedure

### Step 1: Analyze current changes

```bash
git status
git diff --stat
```

If nothing to commit, report and stop.

### Step 2: Categorize changes

Group related files. Identify distinct features, fixes, or chores. **Analyze ALL changes, not just what you worked on this session** — prior-session changes may still be uncommitted.

### Step 3: Build conventional commit message

Load `.claude/skills/gitflow/references/commit-types.md` for emoji/type mapping.

- Single feature: `<emoji> <type>: <description>`
- Multiple features: primary type on first line, bullet list in body
- Subject line: imperative mood, <72 chars
- Breaking change: use `!` after type (e.g., `✨ feat!:`) or `BREAKING CHANGE:` footer

### Step 4: Detect model name

Use the model you are currently running as (e.g., "Claude Opus 4.7", "Claude Sonnet 4.6"). Pass via `--model`.

### Step 5: Decide Gemini review trigger

Gemini Code Assist's auto-review on PR open is **disabled** (`.gemini/config.yaml: pull_request_opened.code_review: false`). Reviews fire only when a `/gemini review` comment is posted on the PR. `commit.sh` posts that comment after push **only when `--review` is passed**. This step decides which flag to pass.

Resolve in this order:

1. **User-specified flag in `$ARGUMENTS`.** If the user invoked `/commit --review` or `/commit --no-review`, honor it and skip the prompt.
2. **No open PR for the current branch.** Pass nothing — there's no PR to comment on. `commit.sh` short-circuits cleanly.
   ```bash
   PR_NUMBER=$(gh pr list --head "$(git branch --show-current)" --state open --json number --jq '.[0].number // empty' 2>/dev/null)
   ```
3. **PR is open and the user did NOT specify a flag.** Use `AskUserQuestion` to prompt:
   - Question: `Trigger Gemini review on this commit?`
   - Header: `Gemini`
   - Options:
     - `Review` — "Post `/gemini review` after push. Use early in the PR or when fixes substantively change behavior."
     - `Skip` — "Don't trigger Gemini. Use in late triage when you've already decided to ship; saves Gemini quota and lets /merge proceed on CI alone."
   - `multiSelect: false`

   Map answer to flag: `Review` → `--review`, `Skip` → `--no-review`.

`GEMINI_NOT_INSTALLED="true"` in `.claude/sync-substitutions.json` makes `--review` a no-op (script skips the post and logs it). The prompt still appears — the slash command doesn't read the substitution file. That's intentional: the flag is the contract; the runtime decides whether the contract is satisfiable.

### Step 6: Invoke the script

```bash
.claude/skills/gitflow/scripts/commit.sh \
  --message "<full conventional message>" \
  --model "<model name>" \
  <--review | --no-review | (nothing if no open PR)>
```

Pass `--skip-typecheck` ONLY if the user explicitly requested bypassing typecheck (rare).

### Step 7: Report result

- Commit succeeded: report the commit hash and branch
- Script exited non-zero: surface the exit code and stderr. Do NOT retry without direction.

## Branch behavior

The script resolves the target branch before committing:

| Current branch | Action |
|----------------|--------|
| `main` / `master` | Derive `<type>/<slug>` from the commit message, create and switch |
| `wip/<timestamp>` with no open PR | Rename to `<type>/<slug>` from the commit message (local + remote) |
| `wip/<timestamp>` with open PR | Commit in place (renaming would break the PR link) |
| Any other branch | Commit in place |

Collisions on the target name are resolved by appending `-2`, `-3`, etc.

## What this command does NOT do

- Does not update `CHANGELOG.md` — per-PR draft handled by `/open-pr`; consolidated release entry handled by `/deploy`
- Does not bump version — handled by `/deploy` (local, human-in-the-loop)
- Does not create a tag — same
- Does not open a PR — separate step via `/open-pr`

## Blocking conditions

The script will exit non-zero if:

- TypeScript or Python typecheck fails
- Nothing is staged (empty diff)
- `git commit` itself fails for any reason
- `--review` and `--no-review` both passed (mutually exclusive — exit 2)
- `--review` passed and the `/gemini review` comment failed to post (exit 10 — fail-loud so the user knows Gemini is NOT coming; downstream `wait-for-pr-ready.sh` would otherwise silently proceed CI-only)

When the script blocks, surface the reason to the user. Fix underlying issues per constitution section XVI (own all errors). Do not bypass.

## Recovery: `--push-only` mode

If a prior `/commit` succeeded at the commit step but failed at push (typical cause: a branch left tracking `origin/main` rather than its own remote ref — plain `git push` then fails under `push.default=simple`), re-trigger the push without re-running typecheck or staging:

```bash
.claude/skills/gitflow/scripts/commit.sh --push-only
```

Push-only:
- Refuses if the working tree has uncommitted changes (use the regular flow instead).
- Refuses on detached HEAD.
- Invokes `safe_push` which sets/corrects upstream to `origin/<branch>` on first push.
- No-op behavior when HEAD is already at the remote (git push reports "Everything up-to-date").

Use this when picking up a half-shipped /commit from a previous session.
