---
name: session-transcript
description: Turn one or more past Claude Code sessions into a human-readable transcript — only what the human typed and what Claude replied, no tool calls, tool output, thinking or system messages. Use when the human asks for a transcript of a session ("transcript of yesterday's session", "turn that session into a transcript", "give me the transcript of the setup session").
---

# Session Transcript

**Build the transcript with the script below, straight away.** The script fixes the format
and the destination, so a transcript request carries no format question.

1. List the project's sessions:

   ```bash
   node "$(git rev-parse --show-toplevel)"/.claude/skills/session-transcript/scripts/transcript.mjs list
   ```

2. Pick the sessions the human described, by date, time and first prompt, leaving out the
   one you are running in. **Sessions with the same title where each starts within minutes
   of the previous one ending are one working session** — include them all, oldest first. Ask only when the description fits
   unrelated sessions equally well.

3. Build it, passing the ids oldest first:

   ```bash
   node "$(git rev-parse --show-toplevel)"/.claude/skills/session-transcript/scripts/transcript.mjs build <sessionId>...
   ```

   It writes `~/Downloads/<project>-transcript-<date>.md`; add `--out <file>` when the
   human names another place.

4. Reply with the path, the sessions covered and their time span, and the prompt count
   the script prints.
