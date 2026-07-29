---
paths: "**/*.{sh,bash}"
---

# Bash Rules

<!--
Loaded only when editing bash/shell scripts. Universal rules in constitution.md.
The gitflow scripts under .claude/skills/gitflow/scripts/ are the primary
audience; consumer projects rarely author bash themselves.
-->

## I. Pipe Error Propagation (Zero Tolerance)

**NEVER rely on `set -o pipefail` for error propagation in error-check contexts.** Use explicit return-code checks. Pipes silently swallow earlier failures unless you opt out structurally — even when `pipefail` is set, future readers/editors miss it, and macOS default bash 3.2 has subtle gaps (`inherit_errexit` is 4.4+ and silently no-ops on 3.2).

| Forbidden | Why | Fix |
|-----------|-----|-----|
| `if ! <cmd> \| <filter>; then …` | Without `pipefail`, exit is `<filter>`'s — typically 0 for any input. `<cmd>`'s failure is silently swallowed and the `if` falls through. | Capture, check, then format. See patterns below. |
| `<cmd> \| <filter> \|\| handle` | Same problem — `handle` runs only on `<filter>` failure, not `<cmd>` failure. | Same. |
| Cosmetic `\| sed 's/^/  /' >&2` inside an error-check condition | Even with `pipefail` it works, but the next editor invariably forgets — pipes inside `if !` / `\|\|` are a trap. | Move the cosmetic filter out of the condition. |

**Correct patterns:**

```bash
# Option 1 — capture, then format on success path
FETCH_OUT=$(git fetch origin main 2>&1) || {
    printf '%s\n' "$FETCH_OUT" >&2
    echo "fetch failed" >&2
    exit 6
}

# Option 2 — drop the cosmetic filter; let the command's own output stand
if ! git fetch origin main; then
    echo "fetch failed" >&2
    exit 6
fi

# Option 3 — PIPESTATUS for cases where the filter genuinely belongs
git fetch origin main 2>&1 | sed 's/^/  /' >&2
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "fetch failed" >&2
    exit 6
fi
```

**Why this rule exists.** 2026-05-13: `sync.sh` shipped with `if ! git fetch … | sed 's/^/  /' >&2; then exit 6; fi`. Without `pipefail` (the script used `set -e` alone), `sed`'s exit always wins → fetch failure silently passes the gate and the merge proceeds against a stale `origin/main`. The fix is structural, not "add pipefail" — pipefail covers it locally but future edits remove the safety net invisibly.

**Existing scripts that set `set -eo pipefail`** (work.sh, merge.sh) are grandfathered, but new pipes added to those scripts SHOULD still follow the explicit-check pattern. `pipefail` is the safety net; the explicit check is the design.

## II. Bash Version Floor

**Target macOS default bash 3.2.** Apple does not upgrade bash (GPLv3); 3.2 ships everywhere on macOS. Any script in this codebase MUST run on it.

| Forbidden | Why | Fix |
|-----------|-----|-----|
| `shopt -s inherit_errexit` without `2>/dev/null \|\| true` | Bash 4.4+ feature. Silently no-ops on 3.2 — but if surrounded by `set -e` and a typo'd flag, errors out and aborts the script. | If you need it: `shopt -s inherit_errexit 2>/dev/null \|\| true`. Then DO NOT rely on its semantics for error propagation. |
| Associative arrays (`declare -A`) | Bash 4.0+. | Use parallel indexed arrays or process substitution. |
| `${VAR^^}` / `${VAR,,}` (case conversion) | Bash 4.0+. | `tr '[:lower:]' '[:upper:]'` / `tr '[:upper:]' '[:lower:]'`. |
| `mapfile` / `readarray` | Bash 4.0+. | `while IFS= read -r line; do …; done < <(cmd)` pattern. |
| `[[ … =~ … ]]` with `BASH_REMATCH` | Works on 3.2 (introduced in 3.0) — OK. | — |

**Test path:** if you're authoring or significantly modifying a script, run it under `/bin/bash --version` to confirm the environment, and prefer POSIX-ish constructs when there's no clear win from a 4.x feature.

## III. set -e Coverage Gaps

**`set -e` is not a complete error-handling strategy.** Common gaps:

| Gap | What slips through |
|-----|---------------------|
| Pipelines without `pipefail` | Earlier commands' failures (see §I). |
| `local var=$(cmd)` | The assignment masks `cmd`'s exit code. Split: `local var; var=$(cmd) \|\| return $?`. |
| Command substitution `$()` in arguments | Without `inherit_errexit`, errors inside `$()` don't propagate. Capture first, use second. |
| `cmd && other_cmd` as the LAST statement of a function | If `cmd` fails, the function returns non-zero — but `set -e` doesn't fire if the call site checks with `if`. Usually fine; flag it if the function name implies fire-and-forget. |
| Trap on ERR not inherited into subshells | Default; use `set -E` if you need ERR traps to apply in subshells / functions. Most scripts don't. |

When in doubt: explicit `if ! cmd; then handle; fi`. Verbose but unambiguous.

## IV. Shellcheck

Run `shellcheck <script>` before committing any meaningful bash change. The gitflow scripts pass shellcheck cleanly today — don't regress. Common false positives are fine to suppress with `# shellcheck disable=SCxxxx` accompanied by a one-line reason.

## V. BSD awk vs gawk Portability

**macOS ships BSD awk; Linux (CI runners, containers) ships gawk.** The two diverge on several points; one bites hard:

| Forbidden | Why | Fix |
|-----------|-----|-----|
| `awk -v var="$VAL"` where `$VAL` may contain newlines | BSD awk rejects with `awk: newline in string` and exits non-zero. gawk accepts silently. The script passes CI (Linux) and dies on the developer's macOS host. | Pass the value as a file path and read inside awk via `getline`. See pattern below. |
| Assuming `awk` == `gawk` (gawk extensions like `gensub`, `asorti`, `length(array)`, `\b` regex anchors) | Bug only manifests on macOS hosts; passes CI silently. | Stick to POSIX awk features. If a gawk extension is essential, invoke `gawk` explicitly and gate on `command -v gawk` first. |
| `awk 'BEGIN { ... }' < file` then expecting POSIX behavior on records | Both POSIX, but gawk and BSD awk differ on edge cases (RS handling, sub-second `systime()`). | Test multi-line / multi-bullet inputs explicitly on macOS before committing. |

**Correct pattern for multi-line strings into awk:**

```bash
# Forbidden — BSD awk dies on multi-line $ENTRY
ENTRY=$(cat /tmp/entry.md)
awk -v entry="$ENTRY" '{...}' input.txt

# Correct — pass file path, read with getline inside awk
awk -v entry_file="/tmp/entry.md" '
    BEGIN {
        entry = ""
        while ((getline line < entry_file) > 0) {
            entry = entry (entry == "" ? "" : "\n") line
        }
        close(entry_file)
    }
    {...}
' input.txt
```

**Why this rule exists.** 2026-05-15: `deploy.sh`'s changelog inserter shipped with `awk -v entry="$ENTRY"` and worked in CI / on first-line-only test entries. v2.4.0 was the first deploy with a multi-bullet changelog; macOS BSD awk choked, the script bailed mid-flight after `npm version`, leaving `package.json` bumped and uncommitted. Recovery was manual. The fix is structural — never pass user-controlled multi-line content via `-v`; always file-path + getline.

**Test path:** if you're about to add `awk -v var="..."` to a script, ask whether the value can contain a newline. If yes (or unknown), use the file-path pattern. CI (Linux gawk) cannot catch this class — verify locally on macOS.
