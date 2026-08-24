# NextAge Dev Kit

A developer workflow blueprint for AI-assisted development. This repository contains standardized configurations for Claude Code — rules, hooks, skills, commands, and settings — that can be synced across multiple projects.

## What This Is

- **Blueprint Repository**: Defines your standard development setup and AI agent behaviors
- **Sync Source**: Central location for configurations that should be consistent across projects
- **Cloud-Ready**: All enforcement config lives at the project level, visible to cloud agents and scheduled triggers

## Quick Start

### First Time Setup (One Time)

```bash
# 1. Clone this dev kit
git clone https://github.com/youruser/nextage-dev-kit.git

# 2. From the dev kit directory, run /install-kit in Claude Code
cd nextage-dev-kit
# Then in Claude Code: /install-kit
```

This installs bootstrap commands to `~/.claude/` so `/sync-dev-kit` is available in all projects.

### For New/Existing Projects

From any project directory in Claude Code:
```
/sync-dev-kit
```

This command interactively syncs:
- `.claude/settings.json` — hooks, permissions, environment variables
- `.claude/hooks/` — enforcement hook scripts
- `.claude/rules/` — constitution, guidelines, integration rules
- `.claude/skills/` — gitpro, shadcn, agent-browser, etc.
- `.claude/commands/` — shared commands
- `.claude/scripts/` — shared scripts
- MCP dependencies — checks Ref, Exa are installed
- CLAUDE.md — legacy import warnings
- Creates `.claude/rules/project/` for project-specific rules

It also self-updates the bootstrap commands in `~/.claude/` and warns if the kit repo has remote updates.

### Optional Utilities

From the dev kit directory:
```
/install-cpl          # Install Claude Project Launcher
/install-statusline   # Install custom statusline to ~/.claude/
```

## Architecture

### Template (`_claude-project/`)

Source of truth for what syncs to consumer projects.

```
_claude-project/
├── settings.json          # Hooks, permissions, env vars
├── CLAUDE.md              # Minimal project entry point
├── rules/                 # Rule templates
│   ├── constitution.md    # Core enforcement rules
│   ├── git.md             # Git workflow rules
│   ├── (other rules)
│   ├── integrations/      # MCP-dependent rules
│   └── project/           # Empty — project-specific rules go here
├── hooks/                 # Claude Code enforcement hooks
│   ├── git-guard.sh       # Blocks dangerous git commands
│   ├── block-db-commands.sh
│   ├── dev-server-guard.sh
│   ├── block-console-log.sh
│   ├── pre-gitpro.sh
│   └── architect_enforcer.sh
├── skills/                # Claude Code skills
│   ├── gitpro/            # Conventional commits, changelog, versioning
│   ├── shadcn/            # shadcn/ui component management
│   ├── agent-browser/     # Browser automation
│   └── mfing-bible-of-tanstack/
├── commands/              # Slash commands
│   ├── sync-dev-kit.md  # Shared (syncs to all projects + global)
│   ├── install-kit.md       # Kit-only
│   ├── install-cpl.md       # Kit-only
│   └── install-statusline.md # Kit-only
└── scripts/
    └── sync-dev-kit.sh   # Shared
```

### Consumer Project (after sync)

```
project/
├── .claude/
│   ├── settings.json      # Hooks, permissions, env
│   ├── rules/             # Synced rules
│   │   ├── constitution.md
│   │   ├── (shared rules)
│   │   └── project/       # YOUR project-specific rules (never synced)
│   ├── hooks/             # Enforcement hook scripts
│   ├── skills/            # Synced skills
│   ├── commands/          # Shared commands only
│   └── scripts/           # Shared scripts only
└── CLAUDE.md              # Optional
```

The kit does NOT manage `.git/hooks/`. Git hooks cannot be tracked in git and do
not survive a clone, so enforcement lives entirely in the Claude Code hooks under
`.claude/hooks/` (which do sync) plus the CI gates. See handbook §3.

### Global `~/.claude/` (minimal)

The kit installs only bootstrap commands globally. Everything else is project-level.

```
~/.claude/
├── settings.json              # Your UI prefs (unmanaged by kit)
├── statusline.sh              # Optional (install via /install-statusline)
├── dev-kit-config.json    # Pointer to kit repo
├── commands/
│   └── sync-dev-kit.md    # Bootstrap (self-updating)
└── scripts/
    └── sync-dev-kit.sh    # Bootstrap (self-updating)
```

## Project-Specific Rules

Each project can have custom rules that won't be overwritten by sync:

```
.claude/rules/project/
└── my-custom-rules.md    # Never synced, never touched
```

The `project/` subfolder is created automatically by `/sync-dev-kit` if it doesn't exist.

## Key Components

### Rules

| File | Purpose |
|------|---------|
| `constitution.md` | Core enforcement (TypeScript quality, naming, security, timezones) |
| `development-guidelines.md` | Code quality, logging, UI patterns |
| `git.md` | Git workflow rules (mandates gitpro skill) |
| `bashtools.md` | Shell tooling standards |
| `projectrules.md` | Project-specific template (customized per project) |
| `integrations/ref.md` | Library docs via Ref MCP |
| `integrations/exa.md` | Deep research via Exa MCP |
| `integrations/agent-browser.md` | Browser automation |

### Hooks

| Hook | Purpose |
|------|---------|
| `git-guard.sh` | Blocks dangerous git commands, enforces gitpro skill |
| `block-db-commands.sh` | Blocks migration commands (requires human) |
| `dev-server-guard.sh` | Prevents AI from starting/killing dev server |
| `block-console-log.sh` | Enforces structured logging (Pino) |
| `pre-gitpro.sh` | TypeScript/Python validation before commits |
| `architect_enforcer.sh` | Enforces principal engineer persona |

### Skills

| Skill | Purpose |
|-------|---------|
| `gitpro` | Git operations with conventional commits and changelog |
| `shadcn` | shadcn/ui component management |
| `agent-browser` | Browser automation for testing |
| `mfing-bible-of-tanstack` | TanStack Start/Router/Query reference |

## Commands

| Command | Available | Purpose |
|---------|-----------|---------|
| `/sync-dev-kit` | All projects + global | Sync project with kit |
| `/install-kit` | Kit only | One-time consumer setup |
| `/install-cpl` | Kit only | Install Claude Project Launcher |
| `/install-statusline` | Kit only | Install custom statusline |


## Tech Stack Context

Optimized for TypeScript/React but adaptable. Includes Python variants of constitution and guidelines (`*-py.md` files). The sync system auto-detects project type and filters language-specific rules.

## Migration from Legacy Structure

If your project uses the old AGENTS.md/AIRules pattern or the old `_claude-global/` structure:

1. Run `/sync-dev-kit` — it warns about legacy files
2. Move custom rules to `.claude/rules/project/`
3. Delete `AGENTS.md` and `AIRules/` if present
4. Delete `_claude-global/` references if present

## For AI Agents

This is a **meta-repository** — it defines configurations for OTHER projects.

**Key principle**: `_claude-project/` is the template (syncs OUT). `.claude/` is this project's own config (managed independently). When changing either, consider if the change belongs in the other.

See `.claude/rules/project/dev-kit-workflow.md` for details.

## Documentation Map

| Doc | Purpose |
|-----|---------|
| `project-documentation/handbook.md` | Full architecture, sync flow, three-surface layout. The authoritative reference. |
| `project-documentation/gitflow-cheatsheet.md` | Day-to-day developer reference for `/branch`, `/link`, `/checkpoint`, `/commit`, `/open-pr`, `/merge`. |
| `project-documentation/kit-repo-github-config.md` | How THIS repo is configured on GitHub and why it differs from consumer projects. Pre-flight sanity checklist before changes that might need GitHub-side config. |
| `project-documentation/dependency-management.md` | The monorepo "one stack" discipline + the `dep-alignment` CI gate: trust-but-verify on old workarounds, solid-version philosophy, the "logged-in not 200" verification standard, accepted-residuals handling. |
| `project-documentation/developer-onboarding.md` | Second-dev setup procedure. |
