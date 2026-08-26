# NextAge Dev Kit

A developer workflow blueprint for AI-assisted development. This repository contains standardized configurations for Claude Code — rules, hooks, skills, commands, and settings — that can be synced across multiple projects.

> **macOS only.** The kit is built and tested on Apple Silicon macOS and assumes it
> throughout: Homebrew paths under `/opt/homebrew`, hooks written for the bash 3.2 that
> Apple ships, BSD `sed` and `awk` rather than the GNU ones, `osascript` to drive iTerm2,
> and iTerm2 dynamic profiles for `/dev` tabs and the launcher.
>
> On **Linux** expect the shell tooling to mostly work and the terminal integration not to —
> `/dev` and the launcher are macOS-specific, and GNU/BSD differences cut the other way from
> the ones the hooks guard against. On **Windows** it does not apply at all; even under WSL
> the terminal and launcher pieces have no equivalent. Porting either is real work nobody
> has done. See `project-documentation/macbook-setup.md` for the machine this expects.

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
| `constitution.md` | Core enforcement (quality, naming, security, timezones, error handling) |
| `development-guidelines.md` | Documentation locations, env config, code health |
| `communication.md` | What to report and what to cut |
| `working-discipline.md` | Goals are fixed; judgment applies to the how |
| `autonomous-sessions.md` | The single definition of an unattended turn |
| `asking-questions.md` | Which mechanism carries a question, and what an option must carry |
| `git.md` | Git workflow rules (routes through the gitflow skill) |
| `testing-verification.md` | Who runs tests, and how the suite is invoked |
| `dependencies.md` | Lockfile installs and pinned node version |
| `typescript-rules.md` / `python-rules.md` | Language rules, loaded by path targeting |
| `postgres-drizzle.md` | The three silent failures on Postgres + Drizzle |
| `ui-design.md` / `ui-patterns.md` / `a11y-baseline.md` | UI tokens, composition, accessibility floor |
| `dev-server.md` | Dev servers are started by the human, via `/dev` |
| `cli-utilities.md` | AWS CLI account/region discipline |
| `memory-discipline.md` | Routing a fact to a rule, a doc, or memory |
| `bash-rules.md` | Shell script rules, loaded by path targeting |
| `integrations/agent-browser.md` | Browser automation |
| `project/**` | Project-owned rules; never synced from the kit |

### Hooks

| Hook | Purpose |
|------|---------|
| `git-guard.sh` | Blocks destructive git commands; routes the rest through gitflow |
| `block-db-commands.sh` | Blocks migration commands (requires human approval) |
| `block-drizzle-handroll.sh` | Blocks hand-authored migration bookkeeping |
| `block-kit-edit.sh` | Blocks consumer edits to kit-owned files |
| `dev-server-guard.sh` | Prevents AI from killing a dev server it did not start |
| `block-console-log.sh` | Enforces structured logging |
| `npm-guard.sh` | Blocks bare `npm install` when a lockfile exists |
| `rule-authoring-guard.sh` | Routes rule/skill/CLAUDE.md authoring through the `rule-authoring` skill |
| `test-on-edit.sh` | Runs the relevant tests after an edit |

### Skills

| Skill | Purpose |
|-------|---------|
| `gitflow` | Work sessions, commits, PRs, review triage, merges |
| `research` | The documentation/research ladder — WebSearch, WebFetch, Exa, ctx7 |
| `mfing-bible-of-tanstack` | TanStack Start/Router/Query/Table/Form house rules |
| `postgres-neon-drizzle` | Schema, migrations, collations, Neon branching |
| `design-system` | Tokens and atoms, backed by the project's `design.md` |
| `ui-patterns` | How surfaces are composed and how they behave |
| `shadcn` | shadcn/ui component management |
| `agent-browser` | Browser automation for testing |
| `e2e` / `e2e-author` | Running and authoring plain-English E2E flows |
| `analysis` | Written analyses packaged to share |
| `dependency-triage` | The weekly dependency and vulnerability pass |
| `dev-server` | Routes dev-server requests to `/dev` |
| `rule-authoring` | How a rule is written so that it binds |

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
| `project-documentation/macbook-setup.md` | Fresh Apple Silicon MacBook, end to end: Xcode CLT, Homebrew, shell, the CLI toolchain, editors, GUI apps, Parallels for legacy WINDEV work, launcher and statusline. |
| `project-documentation/zshrc.example` | Reference `~/.zshrc` — Homebrew ordering, Node LTS pin, the secrets pattern. |
| `project-documentation/developer-onboarding.md` | Second-dev setup procedure, once the machine is ready. |
