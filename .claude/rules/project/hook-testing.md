---
paths: "{_claude-project/hooks/**,.claude/hooks/**}"
---

# Hook Testing

**A hook change without a green sibling suite is not done.** `X.sh` is tested by `X.test.sh` beside it — plain bash, `python3` only, exit 0 green. `test-on-edit.sh` runs it on every edit; a new hook's suite is written in the same change.

**Every suite covers these sections, allow cases first:**

- **Must allow** — the legitimate work the guard sits in front of: `git checkout -b`, `npm ci`, `npm run dev`, editing a `template`-mode file.
- **Must deny** — one case per pattern, plus compound forms (`cd x && <bad thing>`).
- **Deny payload is valid JSON** — including a command containing double quotes.
- **Degenerate input** — malformed JSON, empty payload, missing keys, nulls. Each exits cleanly.

**Emit a deny payload through `python3 -c 'json.dumps(...)'`, never a heredoc.**

**Check an escape hatch in the command string as well as the environment.** `SKIP_X=1 cmd` sets the variable for `cmd`, not for the hook:

```bash
if [ "${SKIP_NPM_GUARD:-}" = "1" ] || printf '%s' "$COMMAND" | grep -q "^SKIP_NPM_GUARD=1"; then
    exit 0
fi
```

**Assert the behaviour the hook documents, not what its code does.**

**Point a hook's environment at temp fixtures, never the repo or the real `$HOME`,** and test every branch machine state selects. `block-kit-edit.test.sh` redirects `HOME` to cover both a maintainer and a consumer machine.

**Write shell for macOS userland.** BSD `sed` has no `\b`.

**Register a new hook in `_claude-project/settings.json` and make its dogfood decision** (`dev-kit-workflow.md`). Async vs sync and token-based bypasses: `project-documentation/hook-patterns.md`. Why hooks are tested this way: `kitmaintainer-handbook.md`, "Testing the kit's hooks".
