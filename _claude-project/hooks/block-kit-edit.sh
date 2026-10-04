#!/bin/bash
#
# block-kit-edit.sh — PreToolUse guard (Edit, Write).
#
# Stops a CONSUMER machine's AI from modifying kit-OWNED files. The set is read
# from the committed `.claude/.kit-sync.json` manifest — present on every
# consumer, no kit repo needed — and it is the `mode` on each entry that
# decides, never the presence of the key: `owned` is guarded, `template` is the
# project's own file and passes through, and in a `merge` file only the lines inside
# marked project regions are the project's. See the mode table below.
#
# The kit MAINTAINER is exempt: if `~/.claude/kitmaster` exists the hook is
# inert. That marker exists only on the maintainer's machine (one-time
# `touch ~/.claude/kitmaster`), so consumers get teeth and the maintainer edits
# freely.
#
# A consumer edits an owned file only as a sanctioned temporary patch: an entry in
# `.claude/.kit-patches.json` naming the file, the kit issue that will fix it and the
# project issue that tracks the patch.
#
#   {"patches":[{"path":".claude/…","kitIssue":"owner/repo#N","projectIssue":"#M","reason":"…"}]}
#
# An entry with both issues filled in lets the edit through; /sync-dev-kit reads the
# same register and reports every such patch until the kit carries the fix.
#
# A `merge` file passes when the edit leaves every line outside its project regions
# exactly as it was. The file after the edit is built from the one on disk (Edit and
# MultiEdit replacements in order; Write is its content), both versions are blanked —
# each region body dropped, markers and everything outside kept — and the two must be
# byte-identical. Markers, as sync-dev-kit.sh reads them:
#
#   .md          <!-- project:begin NAME -->  …  <!-- project:end NAME -->
#   other files  # project:begin NAME         …  # project:end NAME
#
# Malformed markers after the edit (nested, duplicated, mismatched, unclosed) deny. A
# merge file not on disk yet denies: sync creates it.
#
# bash-edit-guard.sh replays a shell edit with `bash_edit_replay: true`. The change is
# then already on disk, so the file on disk is the new version and the committed
# (HEAD) version is the old one.
#
# Deny contract: emit hookSpecificOutput.permissionDecision=deny on stdout,
# exit 0. Allow: exit 0 with no output.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

INPUT=$(cat)

# Maintainer machine → inert.
[ -f "$HOME/.claude/kitmaster" ] && exit 0

require_tools PreToolUse jq

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name' 2>/dev/null)
# MultiEdit carries a file_path exactly like Edit/Write; omitting it here let a
# multi-edit rewrite a kit-owned file straight past this guard.
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

PROJECT_DIR=$(normalize_path "${CLAUDE_PROJECT_DIR:-$PWD}")
MANIFEST="$PROJECT_DIR/.claude/.kit-sync.json"
[ -f "$MANIFEST" ] || exit 0     # not a kit-managed project → nothing to guard

# Manifest keys are project-root-relative. A Windows path (`C:\…`, `/c/…`) and a path
# through a symlink are matched in their normalized form; outside the project → not kit.
REL=$(path_rel_to "$PROJECT_DIR" "$FILE_PATH") || exit 0

# Is this path kit-managed, and if so under which mode?
#
#   (absent)  → not kit-managed. Allow.
#   owned     → the kit owns the content. Deny, unless the patch register sanctions it.
#   template  → the kit ships a starting point; the project owns the file. Allow.
#   merge     → the kit owns everything outside the project regions. Allow an edit
#               that changes only region bodies.
#
# Tolerates both lockfile schemas: a legacy bare-string value means `owned`.
MODE=$(jq -r --arg p "$REL" '
    .files[$p] // empty
    | if type == "object" then (.mode // "owned") else "owned" end
' "$MANIFEST" 2>/dev/null)

[ -n "$MODE" ] && [ "$MODE" != "template" ] || exit 0

# A sanctioned temporary patch: both issues are filed and recorded.
PATCHES="$PROJECT_DIR/.claude/.kit-patches.json"
if [ -f "$PATCHES" ] && jq -e --arg p "$REL" '
    [.patches[]? | select(type == "object" and .path == $p
        and ((.kitIssue // "") | type == "string" and length > 0)
        and ((.projectIssue // "") | type == "string" and length > 0))] | length > 0
' "$PATCHES" >/dev/null 2>&1; then
    exit 0
fi

KIT_REPO=$(jq -r '.kitRepo // "" | if type == "string" then . else "" end' "$MANIFEST" 2>/dev/null)
[ -n "$KIT_REPO" ] || KIT_REPO="the kit's repository, kitRepo in .claude/.kit-sync.json"

# deny <what is wrong> — the shared script for every refusal of a kit file.
deny() {
    local reason="$1 Do not edit it another way. Put this to the human, with your reason filled in:

  \"I think $REL needs to change because <reason>. If you agree, I will file an issue on the kit ($KIT_REPO).\"

Then say which case this is:

  - Not blocking: \"This does not block our work, so we wait for the kit fix.\"
  - Blocking: \"This blocks our work. I can make a temporary change here, flagged for a permanent fix once the kit is updated, if you agree.\"

A temporary change needs the human's yes, then all three before the edit:
  1. The kit issue and a project issue, both filed.
  2. An entry in .claude/.kit-patches.json:
     {\"patches\":[{\"path\":\"$REL\",\"kitIssue\":\"owner/repo#N\",\"projectIssue\":\"#M\",\"reason\":\"…\"}]}
  3. Where the file's format allows comments, a comment at the change naming both issues.
With the entry in place this guard allows edits to $REL."
    jq -cn --arg r "$reason" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
}

if [ "$MODE" != "merge" ]; then
    deny "$REL is owned by the dev kit, so this project does not edit it."
fi

# --- merge: only region bodies are the project's ---
require_tools PreToolUse python3
TARGET="$PROJECT_DIR/$REL"
[ -f "$TARGET" ] || deny "$REL is a kit file with project regions, and it does not exist here yet: /sync-dev-kit creates it."

PROBLEM=$(printf '%s' "$INPUT" | python3 -c '
import json, re, subprocess, sys

target, rel, root = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    event = json.load(sys.stdin)
except Exception:
    print("its edit could not be read."); sys.exit(0)
ti = event.get("tool_input") or {}

def read(path):
    with open(path, encoding="utf-8", newline="") as f:
        return f.read()

if event.get("bash_edit_replay"):
    # The shell change is on disk: compare it with the committed version.
    new = read(target)
    r = subprocess.run(["git", "-C", root, "show", "HEAD:" + rel], capture_output=True)
    if r.returncode != 0:
        print("a shell command changed it, and there is no committed version to compare the change with."); sys.exit(0)
    old = r.stdout.decode("utf-8", "replace")
else:
    old = read(target)
    tool = event.get("tool_name")
    if tool == "Write":
        new = ti.get("content")
        if not isinstance(new, str):
            print("its new content could not be read."); sys.exit(0)
    else:
        edits = ti.get("edits") if tool == "MultiEdit" else [ti]
        new = old
        for e in edits or []:
            e = e or {}
            o, n = e.get("old_string"), e.get("new_string")
            if not isinstance(o, str) or not isinstance(n, str) or not o or o not in new:
                print("its edit does not apply to the file as it is on disk."); sys.exit(0)
            new = new.replace(o, n) if e.get("replace_all") else new.replace(o, n, 1)

if rel.endswith(".md"):
    MARK = re.compile(r"^[ \t]*<!-- project:(begin|end) ([A-Za-z0-9_-]+) -->[ \t\r]*$")
else:
    MARK = re.compile(r"^[ \t]*# project:(begin|end) ([A-Za-z0-9_-]+)[ \t\r]*$")

def blank(text, which):
    out, cur, seen = [], None, set()
    for n, line in enumerate(text.split("\n"), 1):
        m = MARK.match(line)
        if m and m.group(1) == "begin":
            name = m.group(2)
            if cur is not None:
                raise ValueError("%s line %d: region \"%s\" opens inside region \"%s\"" % (which, n, name, cur))
            if name in seen:
                raise ValueError("%s line %d: region \"%s\" appears twice" % (which, n, name))
            seen.add(name); cur = name; out.append(line); continue
        if m:
            if m.group(2) != cur:
                raise ValueError("%s line %d: region end \"%s\" does not close an open region" % (which, n, m.group(2)))
            cur = None; out.append(line); continue
        if cur is None:
            out.append(line)
    if cur is not None:
        raise ValueError("%s: region \"%s\" is never closed" % (which, cur))
    return "\n".join(out)

try:
    after = blank(new, "after the edit")
except ValueError as e:
    print("its project-region markers would be malformed (" + str(e) + ")."); sys.exit(0)
try:
    before = blank(old, "before the edit")
except ValueError as e:
    print("its project-region markers are already malformed (" + str(e) + ")."); sys.exit(0)
if after != before:
    print("this change reaches outside its project regions.")
' "$TARGET" "$REL" "$PROJECT_DIR" 2>/dev/null) || PROBLEM="its edit could not be checked."

PROBLEM=${PROBLEM%$'\r'}   # Python on Windows ends its line with CRLF
[ -z "$PROBLEM" ] && exit 0
deny "$REL is a kit file with project regions: the lines inside its project:begin/project:end markers are this project's, everything else is the kit's, and $PROBLEM"
