# Claude Code Cloud Sessions

Guide for using Claude Code sessions via claude.ai web interface.

## How Cloud Sessions Work

Each cloud session runs in an isolated, Anthropic-managed Ubuntu container. Key characteristics:

- **Fresh container per session** - No persistence between sessions
- **Pre-installed toolchains** - Python, Node.js, Ruby, Go, Rust, Java, PostgreSQL, Redis
- **Limited network access** - Allowlisted domains by default (GitHub, npm, PyPI, etc.)
- **GitHub proxy authentication** - Git operations work via secure proxy

## What's Available vs Not Available

| Component | Local CLI | Cloud Session |
|-----------|-----------|---------------|
| `~/.claude/` global config | Yes | No |
| `~/.claude/hooks/` | Yes | No |
| `~/.claude/skills/` | Yes | No |
| `~/.claude/settings.json` | Yes | No |
| User-scoped MCP servers | Yes | No |
| Project `.claude/` config | Yes | Yes |
| Project `.claude/settings.json` | Yes | Yes |
| Project `.claude/skills/` | Yes | Yes |
| Project `.claude/hooks/` | Yes | Yes |
| Project `.mcp.json` | Yes | Yes |
| `CLAUDE.md` | Yes | Yes |
| Installed CLI tools (npm -g) | Persists | Reinstall each session |

## Environment Detection

Check if running in cloud:

```bash
if [ "$CLAUDE_CODE_REMOTE" = "true" ]; then
  echo "Running in cloud"
fi
```

## Making Workflows Work in Cloud

### 1. Move Global Config to Project

Copy global skills/hooks to project scope:

```bash
cp -r ~/.claude/skills .claude/skills/
cp -r ~/.claude/hooks .claude/hooks/
```

Merge relevant settings from `~/.claude/settings.json` into `.claude/settings.json`.

### 2. SessionStart Hook for Tool Installation

`.claude/settings.json`:
```json
{
  "hooks": {
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/scripts/cloud-init.sh"
      }]
    }]
  }
}
```

`.claude/scripts/cloud-init.sh`:
```bash
#!/bin/bash
set -e

# Only run in cloud sessions
[ "$CLAUDE_CODE_REMOTE" != "true" ] && exit 0

# Install project dependencies
npm install

# Install global CLI tools needed for workflow
npm install -g some-cli-tool

# Set environment variables for session
echo "export NODE_ENV=production" >> "$CLAUDE_ENV_FILE"

exit 0
```

Make executable: `chmod +x .claude/scripts/cloud-init.sh`

### 3. MCP Servers at Project Scope

User-scoped MCP servers (`~/.claude.json`) don't sync to cloud. Use project scope:

```bash
claude mcp add --scope project --transport http myserver https://api.example.com/mcp
```

Creates/updates `.mcp.json` in project root (commit to git).

#### Authentication via Environment Variables

Store API keys in cloud environment config (claude.ai/code → environment settings), reference in `.mcp.json`:

```json
{
  "mcpServers": {
    "ref": {
      "type": "http",
      "url": "https://ref.example.com/mcp",
      "headers": {
        "Authorization": "Bearer ${REF_API_KEY}"
      }
    },
    "exa": {
      "type": "http",
      "url": "https://api.exa.ai/mcp",
      "headers": {
        "x-api-key": "${EXA_API_KEY}"
      }
    }
  }
}
```

### 4. Environment Variables

Two options:

1. **Cloud environment UI** - Set in claude.ai/code → environment settings (for secrets)
2. **`.claude/settings.json`** - For non-sensitive values (committed to git):

```json
{
  "env": {
    "NODE_ENV": "production",
    "LOG_LEVEL": "debug"
  }
}
```

## Recommended Project Structure for Cloud Compatibility

```
your-repo/
├── .claude/
│   ├── settings.json      # Hooks, permissions, env vars
│   ├── scripts/
│   │   └── cloud-init.sh  # Tool installation on session start
│   ├── skills/            # Project-scoped skills (copied from global)
│   ├── hooks/             # Project-scoped hooks (copied from global)
│   └── commands/          # Custom slash commands
├── .mcp.json              # Project-scoped MCP servers
├── CLAUDE.md              # Project instructions
└── ...
```

## Network Access Configuration

Cloud sessions have limited network by default. Allowed domains include:

- GitHub, GitLab, Bitbucket
- npm, PyPI, RubyGems, Cargo
- Docker Hub, container registries
- Major cloud providers (AWS, GCP, Azure)

To expand access:
1. Go to claude.ai/code
2. Select environment → Settings
3. Choose network access level:
   - **Limited** (default) - Allowlisted domains only
   - **Trusted** - Expanded access
   - **Full Internet** - All outbound traffic

## Limitations

1. **No tool persistence** - Every session reinstalls via SessionStart hook
2. **Session startup time** - Hook installation adds 30-60s+ depending on tools
3. **Secrets management** - API keys must be set in cloud environment UI (can't commit)
4. **stdio MCP servers** - Work but require installation; HTTP MCPs are cleaner
5. **Session timeouts** - Long tasks may timeout; use background tasks feature

## Moving Between Cloud and Local

Click "Open in CLI" in web interface to:
1. Stash local changes
2. Load remote session state
3. Continue work locally

Requires same GitHub account authentication.

## Current Pain Points (Known Issues)

- MCP server persistence between sessions (GitHub issue #11903)
- No sync of user-scoped config to cloud
- Must duplicate config between global and project

## Recommended Usage Strategy

**Use local CLI for:**
- Workflows depending on custom CLI tools
- Heavy MCP server usage
- Long-running tasks

**Use cloud sessions for:**
- Quick tasks from mobile/web
- Parallel background tasks
- Code review when away from workstation
- Tasks that don't need custom tooling

## Future Considerations

- Publish custom CLI tools to npm for easier cloud installation
- Migrate to HTTP-based MCP servers where possible
- Watch for Anthropic updates on MCP persistence
