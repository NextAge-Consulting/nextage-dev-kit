# Claude Code Setup

Installing Claude Code itself, managing plugins, and LSP configuration. Complementary to `handbook.md` — the handbook covers kit architecture and project-level config; this doc covers the Claude Code CLI install and plugin ecosystem.

---

## Installation

### macOS (Homebrew)

```bash
brew install claude-code
```

### npm (cross-platform)

```bash
npm install -g @anthropic-ai/claude-code
```

### Verify

```bash
claude --version
```

---

## First-time configuration

For a fresh machine:

1. Install Claude Code (above).
2. Clone the dev kit.
3. Run `/install-kit` from inside the kit repo — this installs the global bootstrap (`~/.claude/commands/sync-dev-kit.md` + script) and writes `~/.claude/dev-kit-config.json` pointing at the kit path.
4. Set `REF_API_KEY` and `EXA_API_KEY` in your shell rc (see handbook Section 10).
5. Optional: `/install-statusline` from the kit repo — installs the custom statusline to `~/.claude/statusline.sh`.
6. Optional: `/install-cpl` from the kit repo — builds and installs CPL launcher.
7. Open any project and run `/sync-dev-kit` to set up its `.claude/` from the kit.

---

## Plugins

Claude Code plugins are separate from the dev kit's skills/commands/hooks. Plugins come from Anthropic's plugin marketplace; they are managed via the `/plugin` slash command.

### Install a plugin

Inside a Claude Code session:

```
/plugin install frontend-design@claude-code-plugins
```

### Browse available plugins

```
/plugin
```

Navigate to the **Discover** tab.

### Useful official plugins

- `frontend-design@claude-code-plugins` — production-grade UI design guidance
- `typescript-lsp@claude-plugins-official` — TypeScript/JavaScript code intelligence (see LSP section below)
- `swift-lsp@claude-plugins-official` — Swift code intelligence
- `plugin-dev@claude-code-plugins` — plugin/skill development toolkit

### Auto-updates

Official Anthropic plugins auto-update at session start. To force an update of the marketplace index:

```
/plugin marketplace update claude-code-plugins
```

### Disable all Claude Code auto-updates

```bash
export DISABLE_AUTOUPDATER=1
```

---

## Updating Claude Code

Claude Code auto-updates by default. Manual update:

**Homebrew:**
```bash
brew upgrade claude-code
```

**npm:**
```bash
npm update -g @anthropic-ai/claude-code
```

---

## LSP support

Claude Code 2.0.74+ has native LSP support for go-to-definition, find-references, hover, and diagnostics. Setup requires both the language server binary and the official LSP plugin.

### TypeScript

1. Install the language server binary:
   ```bash
   npm install -g typescript-language-server typescript
   ```
2. Verify:
   ```bash
   which typescript-language-server
   typescript-language-server --version
   ```
3. Install the plugin:
   - Run `/plugin` in Claude Code
   - Go to **Discover** → **Code intelligence**
   - Install `typescript-lsp`
4. Test:
   Ask Claude to use LSP on a TypeScript file — e.g., "Use the TypeScript LSP to go to the definition of MyFunction in src/index.ts".

### Python

Verified working end-to-end (pyright-lsp + pyright-langserver) on Claude Code 2.0.74+ as of 2026-04-17.

1. Install the language server binary:
   ```bash
   npm install -g pyright
   # or: pip install pyright
   ```
2. Verify:
   ```bash
   which pyright-langserver
   pyright --version
   ```
3. Install the plugin:
   - Run `/plugin` in Claude Code
   - Go to **Discover** → **Code intelligence**
   - Install `pyright-lsp`
4. Test with `test-lsp.py` at the repo root (a minimal fixture — `User` dataclass + `create_user` / `verify_user` / `greet` / `main`). Ask Claude: "retest LSP on test-lsp.py". Expected results:
   - `documentSymbol` → full tree: `User` class with `userid`/`email`/`verified` + four functions with params
   - `hover` on `create_user` (line 13) → `(userid: str, email: str) -> User`
   - `findReferences` on `User` (line 7) → 6 references across the file

If any of those return empty or error, the plugin or binary is not wired up correctly — see troubleshooting below.

### Rust

- Install `rust-analyzer` (via `rustup component add rust-analyzer`)
- Plugin: `rust-lsp`

### Swift

- Install the `swift-lsp@claude-plugins-official` plugin; no separate server binary needed (uses Xcode's bundled sourcekit-lsp on macOS).

### LSP troubleshooting

If you see "No LSP server available for file type":
- Verify the language server binary is in PATH
- Check `/plugin` → **Errors** tab
- Disable and re-enable the plugin
- Restart Claude Code from a fresh shell

Historical note: LSP had initialization bugs in late 2025. Check [GitHub issues](https://github.com/anthropics/claude-code/issues?q=LSP) for current state.

---

## Common troubleshooting

### Plugin command not recognized

Ensure Claude Code version 1.0.33 or later:
```bash
claude --version
```

### Hooks not executing

Check hook file permissions:
```bash
chmod +x .claude/hooks/*.sh
```

Verify `settings.json` references the correct paths (relative to `$CLAUDE_PROJECT_DIR`).

### Skills not loading

Restart Claude Code after adding or modifying skills. Skills metadata is scanned at session start.

### Custom slash command not recognized

- Ensure the command file is in `.claude/commands/` or `~/.claude/commands/`
- Ensure Claude Code was restarted after adding the file
- Command name on disk must match the slash invocation (case-sensitive on filesystems that enforce it)

### Kit not syncing

If `/sync-dev-kit` reports "kit path invalid" or similar, your `~/.claude/dev-kit-config.json` is wrong. Re-run `/install-kit` from inside the kit to refresh the config.

---

## What this doc does NOT cover

- Kit architecture (`_claude-project/`, `_claude-global/`, `.claude/`) — see `handbook.md`
- Git workflow via gitflow — see `handbook.md` Sections 3-6
- MCP server config (Ref, Exa) — see `handbook.md` Section 10
- Second-dev onboarding path — see `developer-onboarding.md`
- Hook authoring patterns (async, token-based enforcement) — see `hook-patterns.md`
