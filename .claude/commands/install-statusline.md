# Install Statusline

Install or update the custom Claude Code statusline from the dev kit repo.

This command should only be run from within the dev kit repo itself.

## Step 1: Verify we're in the dev kit

Check for `_statusline/statusline.sh` in the current directory. If it doesn't exist, tell the user this command must be run from the dev kit repo.

## Step 2: Compare versions

```bash
if [ -f "$HOME/.claude/statusline.sh" ]; then
  KIT_HASH=$(md5 -q "$PWD/_statusline/statusline.sh")
  INSTALLED_HASH=$(md5 -q "$HOME/.claude/statusline.sh")
  if [ "$KIT_HASH" = "$INSTALLED_HASH" ]; then
    echo "Statusline is already up to date."
    exit 0
  fi
fi
```

## Step 3: Install

```bash
cp "$PWD/_statusline/statusline.sh" "$HOME/.claude/statusline.sh"
chmod +x "$HOME/.claude/statusline.sh"
```

## Step 4: Report

Tell the user:
- Statusline installed/updated at `~/.claude/statusline.sh`
- If their `~/.claude/settings.json` doesn't have a statusLine config, suggest adding:
```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 0
  }
}
```
- Restart Claude Code session for changes to take effect
