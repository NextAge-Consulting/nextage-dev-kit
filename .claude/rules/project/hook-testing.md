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
- **Tool missing** — the hook refuses, naming the tool. `test-helpers.sh` provides the fixtures: `path_without`, `path_with_store_python` (the Windows `python3` stub) and `assert_refuses_without`.

**Source `guard-lib.sh` and call `require_tools` for every tool the hook runs before it parses its input,** so a missing `jq` or `python3` refuses instead of allowing. Compare paths through its `normalize_path` / `path_rel_to`.

**Emit a deny payload through a JSON encoder — `json.dumps` or `jq -n --arg` — never a heredoc.** `require_tools` is the one deny built without `python3` or `jq`, because its job is to report them missing.

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
