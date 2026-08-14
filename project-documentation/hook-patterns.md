# Hook Patterns

Reference for Claude Code hook patterns. Covers async vs sync decisions and a token-based pattern for secure bypass mechanisms that AI cannot easily circumvent.

For how hooks are tested — the `X.sh` / `X.test.sh` sibling convention, why the suites
run on edit rather than in CI, and the failure modes that make an untested hook fail
silently open — see `hook-testing.md`.

---

## Part 1: Async vs Sync Hooks

Added in Claude Code 2.1.0, the `async: true` option on command hooks runs the hook in a background process instead of blocking Claude's execution.

### Key behaviors

- **Non-blocking**: Claude continues working immediately; does not wait for the hook to finish.
- **No decision control**: Response fields like `decision`, `permissionDecision`, and `continue` have **no effect** — the action they would control has already completed by the time the hook finishes.
- **Output delivery is deferred**: If the hook produces a JSON response with `systemMessage` or `additionalContext`, that content is delivered to Claude on the **next conversation turn**.
- **No deduplication**: Each firing creates a separate background process. If the same async hook fires 10 times, 10 processes run.
- **Only for command hooks**: Prompt-based (`type: "prompt"`) and agent-based (`type: "agent"`) hooks cannot be async.
- **Snapshot isolation**: Hooks are snapshotted at session startup. Mid-session edits to hook config do not take effect until the next session.

### Configuration

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Write",
      "hooks": [{
        "type": "command",
        "command": "./my-script.sh",
        "async": true,
        "timeout": 120
      }]
    }]
  }
}
```

### Good use cases for async

- Logging and metrics collection
- Notifications (Slack, desktop alerts, etc.)
- Memory / knowledge-base storage operations
- Background test runners (informational, not gating)
- Any side-effect where the result does not need to influence Claude's next action

### Anti-patterns — never use async for

- **Blocking dangerous commands** (the command will already have executed)
- **Permission decisions** (`permissionDecision` is ignored on async hooks)
- **Prompt validation** (the prompt will have already been processed)
- **Any hook whose purpose is to PREVENT an action**

### Decision rule

If the hook's purpose is to GATE or PREVENT something, use sync. If the hook's purpose is to LOG, NOTIFY, or RECORD something, consider async. When in doubt, default to sync.

### Risks of async

1. **Silent failures** — Async hooks fail silently. Crash is invisible unless in debug mode (`claude --debug` or `Ctrl+O`). Makes debugging harder.
2. **No deduplication** — Each firing spawns a process. Rapid tool use can exhaust resources or create race conditions.
3. **Deferred output timing** — Output arrives on the "next conversation turn." If the session is idle, output waits indefinitely.
4. **No control flow** — Async hooks cannot deny, block, or gate anything. All control-flow fields are silently ignored.
5. **Accidental async on safety hooks** — Copy/paste of hook config with `async: true` on a safety hook silently disables that safety. Add a comment near safety hooks: `// NEVER set async:true - safety critical`.

---

## Part 2: Token-Based Enforcement Pattern

Pattern for creating secure bypass mechanisms in Claude Code hooks that AI cannot easily circumvent. Not currently used in the dev kit, but documented here for future reuse.

### The problem

When a hook enforces a rule (e.g., "all git writes must go through a specific skill"), the authorized skill needs a way to bypass the enforcement. Naive approaches are discoverable by AI:

**Environment variable bypass (e.g., `SKILL_RUNNING=1`)**
- AI can read the skill documentation and learn the bypass
- AI can manually prefix commands with the bypass variable
- Bypass mechanism is documented and discoverable

**Pattern-based bypass (e.g., checking command prefix)**
- Any prefix breaking the pattern match works as a bypass
- Example: `SKILL_RUNNING=1 git commit` bypasses `^git ` match
- AI can discover accidentally or intentionally

### The solution

Use **component-scoped hooks** (Claude Code 2.1+) to create tokens that **global hooks** validate. The bypass mechanism is opaque to the AI — nothing in the skill documentation reveals how the bypass works.

### How it works

1. **Skill defines a component-scoped PreToolUse hook** that creates a token file.
2. **Global hook checks for a valid token** before allowing the command.
3. **Token includes session ID** for multi-session safety.
4. **Token has age validation** to prevent stale token reuse.

### Implementation

#### Component hook (skill creates token)

```bash
#!/bin/bash
# {skill-dir}/scripts/create-token.sh
# Path resolved at runtime via ${CLAUDE_SKILL_DIR} so the skill works
# whether installed at user-level or project-level.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TOKEN_FILE="/tmp/.{skill-name}-token-${SESSION_ID}"

echo "$(date +%s)" > "$TOKEN_FILE"
exit 0
```

#### Skill frontmatter (registers the component hook)

```yaml
---
name: {skill-name}
hooks:
  PreToolUse:
    - matcher: Bash
      hooks:
        - type: command
          command: ${CLAUDE_SKILL_DIR}/scripts/create-token.sh
          timeout: 5
---
```

#### Global hook (validates the token)

```bash
#!/bin/bash
# {hook-name}.sh

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id')
TOKEN_FILE="/tmp/.{skill-name}-token-${SESSION_ID}"

# Token-based bypass
if [ -f "$TOKEN_FILE" ]; then
    TOKEN_AGE=$(($(date +%s) - $(cat "$TOKEN_FILE")))
    if [ "$TOKEN_AGE" -lt 300 ]; then
        exit 0
    fi
fi

# Cleanup old tokens (>1 hour)
find /tmp -name ".{skill-name}-token-*" -mmin +60 -delete 2>/dev/null

# ... enforcement logic here
```

### Hook execution order

Both component and global hooks run in parallel on PreToolUse. Timing typically favors this pattern:

1. Both hooks start simultaneously.
2. Global hook does initial setup (jq parsing, variable extraction).
3. Component hook creates the token file.
4. Global hook checks for the token — finds it.

Works because the global hook's setup work (parsing JSON, extracting session_id) takes more time than the component hook's work (touch a file, write a timestamp). Not guaranteed — a stressed system could reverse the order.

### Multi-session safety

Using `session_id` from Claude Code's hook input ensures:
- Each session has its own token file
- Concurrent sessions don't interfere
- Token filename: `/tmp/.{skill-name}-token-{session_id}`

### Security properties

1. **Bypass mechanism is not documented** — The skill doesn't mention tokens.
2. **AI cannot fake tokens** — Would need to know the exact filename and format.
3. **Session-scoped** — Tokens are per-session, can't be shared.
4. **Time-limited** — Tokens expire after 5 minutes (configurable).
5. **Auto-cleanup** — Old tokens are deleted.

### When to use this pattern

- High-security enforcement where AI cheating is a concern.
- Skills that need to bypass global restrictions.
- Multi-step workflows where authorization should persist across tool calls.

### Limitations

- Relies on parallel hook execution timing (not strictly guaranteed).
- Slight complexity vs. simple env var bypass.
- Requires writable temp filesystem.

### Potential enhancements

For even stronger security:
1. **Cryptographic tokens** — Generate HMAC-signed tokens.
2. **Process validation** — Check the token was created by the legitimate hook process.
3. **One-time tokens** — Token deleted after first use.

---

## Sources

- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [Boris Cherny announcement on async hooks](https://www.threads.com/@boris_cherny/post/DT8obEVkiRI/)
