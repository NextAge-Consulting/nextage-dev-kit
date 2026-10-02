#!/bin/bash
# bash-edit-guard.sh — runs the Edit guards over files a shell command changed.
#
# PostToolUse on Bash. Claude Code steers file edits through Bash in some permission
# modes, and a hook matched on Edit|Write never sees those. Claude Code reports the
# files a Bash command changed in `tool_response.bashEditDiff.changedFiles`; this hook
# replays each one, as an Edit, through every hook the project's settings.json matches
# on Edit — PreToolUse guards and PostToolUse hooks alike. So any Edit guard, the kit's
# or a project's own, covers shell edits without being changed.
#
# The payload's `new_string` is the file's lines added since HEAD (the whole file when
# it is untracked; empty when deleted), which is what a content guard judges. It also
# carries `bash_edit_replay: true`, so a guard that needs the whole change (the region
# check in block-kit-edit.sh) knows the file on disk is already the new version.
#
# The change is already on disk, so nothing is refused: every objection is returned to
# Claude as a PostToolUse block, to fix or undo.
#
# A file exactly as `/sync-dev-kit` delivered it (kit-delivered.sh) is the kit's own
# content, judged in the kit, and is not replayed. Skipping it here, where the change is
# known to be on disk, also leaves each
# guard's once-per-session stop unspent for the edit that follows. A real Edit cannot
# be skipped this way: its guards run before the change lands.
#
# Claude Code records the changed files in auto and bypassPermissions mode, and in
# every mode when the user setting `bashEditDiffEnabled` is true. With no list, this
# hook does nothing; bash-edit-diff-check.sh warns at session start when that is so.
#
# A replayed guard that does not run — it times out, fails to start, or is not found —
# has not passed the file, and is reported as a finding naming the guard.
#
# Override (user-authorized only): SKIP_BASH_EDIT_GUARD=1.
# BASH_EDIT_GUARD_TIMEOUT sets the per-guard replay limit in seconds (default 60; the
# suite shortens it).

[ "${SKIP_BASH_EDIT_GUARD:-}" = "1" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=guard-lib.sh
source "$HOOK_DIR/guard-lib.sh"

INPUT=$(cat)
require_tools PostToolUse python3

KIT_LIB="$HOOK_DIR/kit-delivered.sh"

printf '%s' "$INPUT" | PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}" KIT_LIB="$KIT_LIB" python3 -c '
import json, os, re, subprocess, sys

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(event, dict):
    sys.exit(0)

diff = ((event.get("tool_response") or {}) if isinstance(event.get("tool_response"), dict) else {}).get("bashEditDiff") or {}
files = [f for f in (diff.get("changedFiles") or []) if isinstance(f, str) and f]
if not files:
    sys.exit(0)

project = os.environ.get("PROJECT_DIR") or (event.get("cwd") if isinstance(event.get("cwd"), str) else "")
if not project:
    sys.exit(0)
try:
    settings = json.load(open(os.path.join(project, ".claude", "settings.json"), encoding="utf-8"))
except Exception:
    sys.exit(0)

kit_lib = os.environ["KIT_LIB"]

def kit_delivered(path):
    if not os.path.isfile(kit_lib):
        return False
    r = subprocess.run(["bash", "-c", "source \"$0\"; is_kit_delivered \"$1\" \"$2\"", kit_lib, project, path],
                       capture_output=True)
    return r.returncode == 0

files = [f for f in files if not kit_delivered(f)]
if not files:
    sys.exit(0)

def edit_hooks(event_name):
    out = []
    for entry in ((settings.get("hooks") or {}).get(event_name) or []):
        matcher = entry.get("matcher") or ""
        try:
            hit = matcher in ("", "*") or re.fullmatch(matcher, "Edit")
        except re.error:
            hit = False
        if hit:
            out += [h["command"] for h in (entry.get("hooks") or []) if h.get("type") == "command" and h.get("command")]
    return out

pre, post = edit_hooks("PreToolUse"), edit_hooks("PostToolUse")
if not pre and not post:
    sys.exit(0)

def git(args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)

def added_lines(path):
    if not os.path.isfile(path):
        return ""
    cwd = os.path.dirname(path)
    if git(["ls-files", "--error-unmatch", path], cwd).returncode != 0:
        try:
            return open(path, encoding="utf-8", errors="replace").read(400_000)
        except OSError:
            return ""
    d = git(["diff", "-U0", "HEAD", "--", path], cwd).stdout
    return "\n".join(l[1:] for l in d.splitlines() if l.startswith("+") and not l.startswith("+++"))

MAX_FILES = 40
unchecked = files[MAX_FILES:]
files = files[:MAX_FILES]

def guard_name(cmd):
    toks = re.findall(r"[^\s\"\x27]+", cmd)
    return os.path.basename(toks[-1]) if toks else cmd

try:
    timeout = max(1, int(os.environ.get("BASH_EDIT_GUARD_TIMEOUT") or 60))
except ValueError:
    timeout = 60

env = dict(os.environ, CLAUDE_PROJECT_DIR=project)
findings = []
for path in files:
    base = {k: event.get(k) for k in ("session_id", "transcript_path", "cwd") if event.get(k)}
    tool_input = {"file_path": path, "old_string": "", "new_string": added_lines(path)}
    for event_name, commands in (("PreToolUse", pre), ("PostToolUse", post)):
        payload = dict(base, hook_event_name=event_name, tool_name="Edit", tool_input=tool_input,
                       bash_edit_replay=True)
        if event_name == "PostToolUse":
            payload["tool_response"] = {"filePath": path, "success": True}
        for cmd in commands:
            # A guard that did not run has not passed the file: say so, never count it an allow.
            try:
                r = subprocess.run(["bash", "-c", cmd], input=json.dumps(payload), capture_output=True,
                                   text=True, env=env, cwd=project, timeout=timeout)
            except subprocess.TimeoutExpired:
                findings.append((path, "Guard " + guard_name(cmd) + " could not run on this file: it did not "
                                 "finish within " + str(timeout) + " seconds. Check the file against that guard yourself."))
                continue
            except Exception:
                findings.append((path, "Guard " + guard_name(cmd) + " could not run on this file: it failed "
                                 "to start. Check the file against that guard yourself."))
                continue
            if r.returncode in (126, 127):
                findings.append((path, "Guard " + guard_name(cmd) + " could not run on this file: it was not "
                                 "found or is not executable. Check the file against that guard yourself."))
                continue
            reason = ""
            try:
                out = json.loads(r.stdout) if r.stdout.strip() else {}
            except Exception:
                out = {}
            hso = out.get("hookSpecificOutput") or {} if isinstance(out, dict) else {}
            if hso.get("permissionDecision") == "deny":
                reason = hso.get("permissionDecisionReason") or ""
            elif isinstance(out, dict) and out.get("decision") == "block":
                reason = out.get("reason") or ""
            elif r.returncode == 2:
                reason = r.stderr.strip()
            if reason:
                findings.append((path, reason))

if unchecked:
    findings.append((unchecked[0], str(len(unchecked)) + " more changed files were not checked. "
                     "Review them against the project rules, or make changes in smaller commands."))

if not findings:
    sys.exit(0)

# Files sharing an identical objection are listed together under one copy of it.
grouped = {}
for p, r in findings:
    grouped.setdefault(r, []).append(os.path.relpath(p, project))
body = "\n\n".join("── " + ", ".join(ps) + "\n" + r for r, ps in grouped.items())
print(json.dumps({"decision": "block", "reason":
    "⚠️ This shell command changed files that the file-edit guards cover. The changes are "
    "already on disk; each objection is below. Fix or undo your own changes. (The changed-file "
    "list is best effort: a file another process changed at the same moment can appear here.)\n\n"
    + body}))
'
exit 0
