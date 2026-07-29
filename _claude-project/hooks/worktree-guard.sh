#!/bin/bash
# Worktree Guard Hook — PostToolUse advisory for direct EnterWorktree calls.
#
# Why this exists
# ---------------
# The project's canonical worktree-entry path is `/work` (gitflow), which runs:
#   1. git worktree add (with --no-track when branching from origin/main)
#   2. apply_worktree_symlinks — symlinks gitignored assets from primary
#      per .worktree.symlinkPaths / .worktree.symlinkDirectories
#   3. run_post_create — executes .worktree.postCreate commands (e.g. npm install)
#
# Claude Code's background-session system prompt nudges Claude toward calling
# the `EnterWorktree` tool directly to satisfy its edit-isolation guard. When
# Claude follows that nudge, `EnterWorktree(name=...)` SHOULD trigger the
# binary's built-in symlinkPaths/symlinkDirectories/postCreate logic — but in
# practice that path is unreliable across versions (empirically skipped in
# unreliable). The worktree is created, but step 2 and step 3
# never run. Dev servers crash on missing .env; tests fail on missing
# node_modules.
#
# This hook fires on the PostToolUse boundary for EnterWorktree and injects a
# system-reminder telling Claude to verify the setup steps ran (or run them
# now via work.sh's helpers, or fall back to /work). It is ADVISORY only —
# does not block, does not undo the call.
#
# Schema: outputs JSON with hookSpecificOutput.additionalContext (10k char cap).
# See https://code.claude.com/docs/en/hooks for PostToolUse contract.

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Only fire on EnterWorktree — let other tools through.
if [ "$TOOL_NAME" != "EnterWorktree" ]; then
    exit 0
fi

# Inspect what mode EnterWorktree was called in. name= = create new; path= = enter existing.
# Path-mode is /work's authorized entry mechanism and doesn't need the reminder.
WORKTREE_NAME=$(echo "$INPUT" | jq -r '.tool_input.name // ""')
WORKTREE_PATH=$(echo "$INPUT" | jq -r '.tool_input.path // ""')

if [ -n "$WORKTREE_PATH" ] && [ -z "$WORKTREE_NAME" ]; then
    # Pure path-mode — /work's entry pattern. No reminder needed.
    exit 0
fi

# Create-mode (name=) — verify the canonical setup steps ran. Inject reminder.
cat <<'REMINDER'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "⚠️ EnterWorktree was called directly (create mode). The project's canonical worktree-entry path is `/work` (gitflow), which runs apply_worktree_symlinks + postCreate after creating the worktree. EnterWorktree's built-in symlink+postCreate machinery is unreliable across Claude Code versions.\n\nBefore editing files in the new worktree, VERIFY:\n  1. .env (and other .worktree.symlinkPaths) are symlinked from primary into the worktree. Run `ls -la <worktree>/.env` — should show `-> <primary>/.env`.\n  2. node_modules (or the project's .worktree.postCreate equivalent) is real and populated. Run `ls <worktree>/node_modules | head -1`.\n\nIf either is missing, you have TWO options:\n  A) Exit the worktree and re-enter via `/work` (canonical — runs the helpers correctly).\n  B) Run the helpers manually: source `.claude/skills/gitflow/scripts/work.sh` and call `apply_worktree_symlinks <worktree-path>` + `run_post_create <worktree-path>` against the new worktree.\n\nSkipping this verification will produce a half-built worktree (dev servers crash on missing .env, tests fail on missing node_modules). See .claude/rules/worktree.md for the full model."
  }
}
REMINDER

exit 0
