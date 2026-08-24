# Developer Onboarding

This document is the reference a developer's Claude Code session follows to configure their machine for working on the maintainer's projects. Hand this doc to the developer; their Claude reads it end-to-end and walks them through current-state-vs-desired-state comparison.

---

## Purpose

A second developer works on projects that use the `nextage-dev-kit`. The developer never runs the dev kit directly — they get the project's opinions, rules, hooks, skills, and commands from the project's repo (committed `.claude/` directory). The developer only needs a minimal global setup on their own machine to:

1. Have Claude Code itself installed and configured
2. Have API keys for per-developer MCP servers (Ref, Exa)
3. Optionally install the maintainer's statusline script (cosmetic; doesn't affect workflow)
4. Optionally install CPL (the maintainer's launcher tool; optional)

The developer does NOT install the dev kit. The developer does NOT run `/sync-dev-kit`. The developer does NOT run `/install-kit`. Those are maintainer-only tools.

---

## Claude's procedure for the onboarding session

When the developer's Claude session is given this doc, do not attempt everything at once. Work through the sections in order. For each section:

1. Check the developer's current state (read files, check env vars, run commands that show state)
2. Compare against the "desired state" described below
3. Report the delta in one concise paragraph
4. Ask the developer: "Fix this delta now?" — wait for explicit yes before writing
5. Move to next section

Never silently modify the developer's machine. Every change is surfaced, proposed, and confirmed.

---

## Section 1: Claude Code installation

### Desired state

- Claude Code CLI installed and working (`claude --version` succeeds)
- `~/.claude/` directory exists
- The developer has signed in (`~/.claude/oauthAccount` or equivalent present)

### Check

```bash
claude --version
ls -la ~/.claude/
```

### If missing

The developer installs Claude Code per Anthropic's current instructions at https://docs.claude.com/en/docs/claude-code/quickstart. Sign in with their Anthropic account.

---

## Section 2: Shell environment (API keys)

### Desired state

Two environment variables exported in the developer's shell rc (`~/.zshrc` or `~/.bashrc` — detect which shell they use via `echo $SHELL`):

```bash
export REF_API_KEY="ref-..."      # the developer's own Ref API key
export EXA_API_KEY="..."          # the developer's own Exa API key
```

These are per-developer. The developer does not use the maintainer's keys. They get their own:

- **Ref**: https://ref.tools — sign up, create API key
- **Exa**: https://exa.ai — sign up, create API key

### Check

```bash
echo "REF_API_KEY set: $([ -n \"$REF_API_KEY\" ] && echo yes || echo NO)"
echo "EXA_API_KEY set: $([ -n \"$EXA_API_KEY\" ] && echo yes || echo NO)"
grep -E "^export (REF|EXA)_API_KEY" ~/.zshrc ~/.bashrc 2>/dev/null
```

### If missing

Claude prompts the developer to get their keys from Ref and Exa, then writes the `export` lines to the appropriate shell rc. The developer runs `source ~/.zshrc` (or opens a new terminal) to apply.

---

## Section 3: Global Claude Code settings (~/.claude/settings.json)

### Desired state

Certain user-level settings reduce friction with the project-level gitflow subsystem. The developer's `~/.claude/settings.json` should include:

```json
{
  "includeGitInstructions": false
}
```

**Why**: `includeGitInstructions: false` removes Claude's native git instructions from the system prompt. Without this, Claude defaults to raw `git commit` / `git push` on git-related requests, which the project's `git-guard.sh` hook will block. The hook backstop catches the error, but the setting prevents the fallback in the first place. Reduces noise.

This setting is user-level and does NOT load in Anthropic cloud sessions. It helps local Claude only.

### Check

```bash
cat ~/.claude/settings.json 2>/dev/null | jq '.includeGitInstructions'
```

### If different or missing

Claude proposes the setting edit (read-modify-write the JSON). The developer confirms before writing.

Preserve the developer's other settings — only modify `includeGitInstructions`.

---

## Section 4: Global MCP servers (~/.claude.json)

### Desired state

The developer's **global** MCP config is EMPTY. MCP servers (Ref, Exa) are configured per-project via repo `.mcp.json`, not globally.

If the developer's `~/.claude.json` has `mcpServers` at top-level with Ref or Exa, those should be REMOVED from global config. They conflict with project-level config and leak the developer's keys into a user-level file.

### Check

```bash
jq '.mcpServers' ~/.claude.json 2>/dev/null
```

### If non-empty

Claude shows the developer what's there. Recommends removing `Ref` and `exa` entries (they're duplicated at project level via `.mcp.json`). Keep any developer-specific MCP servers that aren't project-owned.

---

## Section 5: Statusline (optional)

### Desired state

If the developer wants the maintainer's custom statusline (shows directory, branch, context usage, rate limits):

- `~/.claude/statusline.sh` exists and is executable
- `~/.claude/settings.json` has:
  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "~/.claude/statusline.sh",
      "padding": 0
    }
  }
  ```

### Check

```bash
ls -l ~/.claude/statusline.sh 2>/dev/null
jq '.statusLine' ~/.claude/settings.json 2>/dev/null
```

### If the developer wants it installed

The maintainer will provide `statusline.sh` (or the developer clones the dev-kit repo read-only and copies `_statusline/statusline.sh` to `~/.claude/statusline.sh`). Claude guides the copy + settings update.

This is entirely optional. The developer can skip.

---

## Section 6: CPL launcher (optional)

CPL is the maintainer's custom launcher tool. The developer's machine does not need it unless they want it. Deferred to the maintainer when the developer wants in.

---

## Section 7: Cloning a project

### Procedure

When the developer clones a project that uses the dev kit:

1. `git clone <repo-url>`
2. Change into the project directory
3. Verify the project has the expected structure:
   - `.claude/settings.json` (if missing — project was never synced with the new dev kit; the maintainer needs to run `/sync-dev-kit` in the project first)
   - `.claude/hooks/` with `git-guard.sh`, `block-db-commands.sh`, etc.
   - `.claude/skills/gitflow/` with `SKILL.md` + scripts
   - `.claude/commands/` with `commit.md`, `checkpoint.md`, `open-pr.md`, `merge.md` (the per-project gitflow commands; `/work` and `/sync-dev-kit` are global, installed in `~/.claude`, not in the project repo)
   - `.mcp.json` at repo root
4. Start Claude Code in the project directory — the developer's setup should "just work"

### Verification

Once in the project, ask Claude to:
1. List available slash commands (should include `/commit`, `/checkpoint`, `/open-pr`, `/merge`)
2. Verify MCP servers load (Ref + Exa should be available — check with a trivial `mcp__Ref__ref_search_documentation` call)
3. Try a trivial checkpoint: the developer runs `/checkpoint test` on a throwaway file change (then reverts)

If any verification fails, report to the maintainer with the specific failure.

---

## Section 8: Working with the gitflow subsystem

The developer's day-to-day git interactions go through the gitflow subsystem. **See `project-documentation/GITFLOW-CHEATSHEET.md` for the one-page day-to-day reference** — it covers `/work`, `/link`, `/checkpoint`, `/commit`, `/open-pr`, `/merge` with examples.

Short version:

| The developer says | What happens |
|--------------------|--------------|
| "start work on #23" | `/work #23` — cuts the branch, links the issue, assigns it, moves it to In Progress |
| "also works on #25" (mid-branch) | `/link #25` — links additional issue to current branch |
| "checkpoint" or "save progress" | `/checkpoint` — fast WIP commit + push |
| "commit this" | `/commit` — full conventional commit with AI-generated message |
| "open a pr" | `/open-pr` — push branch, create PR, auto-prepends `Closes #N` from linked issues |
| "merge to main" | `/merge` — verify CI passed, squash-merge, pull main |

The developer never runs raw `git commit`, `git push`, `git merge`, `git checkout <file>`, `git reset`, `git revert`, `git clean`, `git restore`. Those are blocked by the project's `git-guard.sh` hook. If the developer needs one legitimately, use the `SKIP_GIT_GUARD=1` prefix with explicit reason.

Claude handles the commit message generation, PR title, PR body. The developer provides the trigger. For internals and the full architecture, see `project-documentation/HANDBOOK.md`.

---

## Section 9: When the maintainer pushes kit updates

When the maintainer pushes rule updates, new skills, or hook changes to a project the developer works on:

1. The maintainer runs `/sync-dev-kit` in the project, reviews changes interactively, then lands them with `/ship-main` (sync itself does no git)
2. The maintainer pushes the project repo
3. The developer pulls the project repo
4. The developer's Claude sessions in that project automatically pick up the updated `.claude/` config on next session start

The developer never runs `/sync-dev-kit` themselves. That's maintainer-only.

---

## Section 10: Reporting back

When the developer's Claude completes this onboarding, produce a short summary for the developer to send to the maintainer:

- Each section: ✓ complete, ✗ skipped (why), ⚠ partial (what's left)
- Any unexpected findings (existing config the developer doesn't recognize, conflicts, etc.)
- Confirm: can the developer successfully run `/commit`, `/checkpoint`, `/open-pr`, `/merge` in a test project?

The maintainer uses this summary to verify the setup and file follow-ups if anything is off.
