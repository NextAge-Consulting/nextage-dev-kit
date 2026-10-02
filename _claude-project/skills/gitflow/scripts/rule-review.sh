#!/bin/bash
# rule-review.sh <base-ref> — the rule-prose review gate for /commit and /ship-main.
#
# Every rule-prose file (.claude/hooks/rule-prose.sh defines the set) changed since
# <base-ref> — committed checkpoints, the working tree and untracked files alike — is
# reviewed by a headless Claude against the rule-authoring standard. A finding fails
# the gate. A file exactly as `/sync-dev-kit` delivered it (hooks/kit-delivered.sh) is
# not reviewed: the kit's review covered it where it was authored.
#
# The reviewer sees only the diff and the criteria below: no tools, no settings, no
# CLAUDE.md. It judges added lines only, against three violations, and reports nothing
# it is unsure of.
#
# Exit 0: nothing to review, or clean. Exit 1: findings, or the gate could not run.
# Override (user-authorized only): SKIP_RULE_REVIEW=1.
#
# RULE_REVIEW_CLAUDE names the CLI to run (default `claude`); the suite points it at a stub.

set -uo pipefail

BASE="${1:-HEAD}"

if [ "${SKIP_RULE_REVIEW:-}" = "1" ]; then
    echo "gitflow: rule review skipped (SKIP_RULE_REVIEW=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: rule review: not in a git repository." >&2; exit 1; }
# The classifier ships beside this script: .claude/skills/gitflow/scripts → .claude/hooks.
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../hooks" 2>/dev/null && pwd)/rule-prose.sh"
if [ ! -f "$LIB" ]; then
    echo "gitflow: rule review cannot run — rule-prose.sh is missing from .claude/hooks/. Run /sync-dev-kit." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$LIB"
# Without it every file is reviewed, which is the safe direction.
KIT_LIB="$(dirname "$LIB")/kit-delivered.sh"
if [ -f "$KIT_LIB" ]; then
    # shellcheck source=/dev/null
    source "$KIT_LIB"
else
    is_kit_delivered() { return 1; }
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# NUL-separated, so a path git would quote is read as itself. A failing diff —
# a base that does not resolve — fails the gate rather than reading as "nothing
# changed".
if ! (cd "$ROOT" && git diff -z --name-only --diff-filter=d "$BASE" && git ls-files -z --others --exclude-standard) >"$WORK/changed" 2>"$WORK/err"; then
    echo "gitflow: rule review cannot list the changed files (git diff against $BASE failed):" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

FILES=()
while IFS= read -r -d '' f; do
    [ -n "$f" ] && is_rule_prose "$f" && ! is_kit_delivered "$ROOT" "$f" && FILES+=("$f")
done < <(sort -zu "$WORK/changed")

if [ ${#FILES[@]} -eq 0 ]; then
    echo "gitflow: rule review: no rule-prose files changed." >&2
    exit 0
fi

# The reviewer's answer is parsed by python3. Without a working one every answer
# would read as "no findings" — so a missing python3, or a stub that is not a real
# interpreter, fails here, before the review is paid for.
if [ "$(python3 -c 'print(1)' 2>/dev/null)" != "1" ]; then
    echo "gitflow: ${#FILES[@]} rule-prose file(s) changed, and the rule review needs a working python3, which is missing or not a real interpreter." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

CLAUDE_BIN="${RULE_REVIEW_CLAUDE:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "gitflow: ${#FILES[@]} rule-prose file(s) changed, and the rule review needs the Claude Code CLI, which is not on PATH." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

DIFF=$(cd "$ROOT" && for f in "${FILES[@]}"; do
    if git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
        git diff "$BASE" -- "$f"
    else
        git diff --no-index -- /dev/null "$f"
    fi
done)

echo "gitflow: reviewing ${#FILES[@]} rule-prose file(s) against the rule-authoring standard..." >&2

read -r -d '' SYSTEM <<'EOF'
You review diffs of instruction files — rules, skills, commands, pattern references — that an AI loads and follows as law. They say WHEN something applies and HOW to do it. Nothing else belongs in them.

Judge ONLY lines the diff adds (lines starting with "+", excluding "+++" headers). Report a finding only for a clear case of one of these:

1. HISTORY — a date, a person's name or an attribution of who decided; an incident or story of what happened; what shipped, existed before, was removed, replaced, renamed or retired; "originally", "this rule was written after", "we tried".
2. JUSTIFICATION — text arguing why the rule or the file exists, evidence, measurements or counts of past failures, or how a decision was reached, instead of stating what to do and when.
3. COUNTED LIST — prose that counts its own list ("these four options", "R1–R6", "the three rules below").

Out of scope, never report: wording, style, length, tone, formatting, missing detail, whether the rule is wise, examples that illustrate how to apply a rule, and code blocks.

When unsure, do not report. A clean diff returns {"findings": []}.
For each finding give the file, the exact added text quoted, which category, and a present-tense rewrite (or "delete").
EOF

SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"quote":{"type":"string"},"category":{"type":"string","enum":["HISTORY","JUSTIFICATION","COUNTED LIST"]},"fix":{"type":"string"}},"required":["file","quote","category","fix"]}}},"required":["findings"]}'

OUT=$(cd "$WORK" && printf '%s\n' "$DIFF" | "$CLAUDE_BIN" -p \
    --model sonnet --tools "" --system-prompt "$SYSTEM" --json-schema "$SCHEMA" \
    --output-format json --no-session-persistence --disable-slash-commands \
    --strict-mcp-config --setting-sources "" 2>"$WORK/err")
STATUS=$?

REPORT=$(printf '%s' "$OUT" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    if d.get("is_error"):
        raise ValueError
    findings = d["structured_output"]["findings"]
except Exception:
    print("ERROR"); sys.exit(0)
print("PARSED")
for f in findings:
    print("  " + f["file"] + " — " + f["category"])
    print("    \"" + f["quote"].strip() + "\"")
    print("    → " + f["fix"].strip())
' 2>/dev/null)

# The first line is PARSED only when python3 read a well-formed answer; anything
# else — ERROR, or nothing at all — is a review that did not happen.
if [ "$STATUS" -ne 0 ] || [ "$(printf '%s\n' "$REPORT" | head -1)" != "PARSED" ]; then
    echo "gitflow: the rule review could not run (claude exited $STATUS)." >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

REPORT=$(printf '%s\n' "$REPORT" | sed '1d')
if [ -n "$REPORT" ]; then
    echo "gitflow: rule review found text that does not belong in rule prose:" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  Fix the files and commit again. A finding that is wrong: the human may run with SKIP_RULE_REVIEW=1." >&2
    exit 1
fi

echo "gitflow: rule review clean — ${#FILES[@]} rule-prose file(s) reviewed." >&2
exit 0
