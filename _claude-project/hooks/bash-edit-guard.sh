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
# known to be on disk, also leaves each guard's once-per-session stop unspent for the
# edit that follows. A real Edit cannot be skipped this way: its guards run before the
# change lands.
#
# Process starts are what a run costs on Windows, a fraction of a second each, so the
# work is shaped around them: one kit-delivered.sh run for the whole list, one git
# ls-files and one git diff for every file in the project repository, and each guard
# command in its own lane, walking the files in order. Lanes run at the same time; a
# guard never judges two files at once, so one that keeps session state sees what a
# series of Edits would show it.
#
# The hook gives itself three quarters of the timeout settings.json sets on it. Files
# the guards have not finished when that runs out are reported as not checked, by name,
# before Claude Code would kill the hook and leave them unchecked in silence.
#
# Claude Code records the changed files in auto and bypassPermissions mode, and in
# every mode when the user setting `bashEditDiffEnabled` is true. With no list, this
# hook does nothing; bash-edit-diff-check.sh warns at session start when that is so.
#
# No shell text crosses Python's argv: on Windows, Python flattens argv into one command
# line and Git Bash re-splits it by other rules, so quotes inside a `bash -c` string
# arrive unbalanced. kit-delivered.sh is run as a script with the project and the paths,
# and each replayed command is written to a script file. On Windows the bash running this hook is
# named by its full path, because a bare "bash" from native Python finds the WSL
# launcher in System32 before Git Bash on PATH.
#
# A replayed guard that does not run — it times out, fails to start, or is not found —
# has not passed the file, and is reported as a finding naming the guard.
#
# Override (user-authorized only): SKIP_BASH_EDIT_GUARD=1.
# BASH_EDIT_GUARD_TIMEOUT sets the per-guard replay limit in seconds (default 60), and
# BASH_EDIT_GUARD_BUDGET the whole run's, in place of the one settings.json implies;
# the suite shortens both.

[ "${SKIP_BASH_EDIT_GUARD:-}" = "1" ] && exit 0

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=guard-lib.sh
source "$HOOK_DIR/guard-lib.sh"

INPUT=$(cat)
require_tools PostToolUse python3

KIT_LIB="$HOOK_DIR/kit-delivered.sh"
GUARD_BASH=bash
if kit_is_windows && command -v cygpath >/dev/null 2>&1; then
    GUARD_BASH=$(cygpath -m "$BASH")
    KIT_LIB=$(cygpath -m "$KIT_LIB")
fi

printf '%s' "$INPUT" | PROJECT_DIR="${CLAUDE_PROJECT_DIR:-}" KIT_LIB="$KIT_LIB" GUARD_BASH="$GUARD_BASH" python3 -c '
import atexit, json, os, re, shutil, signal, subprocess, sys, tempfile, time
from concurrent.futures import ThreadPoolExecutor

start = time.monotonic()

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
bash = os.environ.get("GUARD_BASH") or "bash"

def matches(entry, tool):
    matcher = entry.get("matcher") or ""
    try:
        return matcher in ("", "*") or bool(re.fullmatch(matcher, tool))
    except re.error:
        return False

# The time this hook gives itself: three quarters of the timeout settings.json sets on
# it (Claude Code default 60s), so a slow run stops and says what it did not reach
# before Claude Code kills it and the rest goes unchecked in silence.
def own_timeout():
    for entry in ((settings.get("hooks") or {}).get("PostToolUse") or []):
        if matches(entry, "Bash"):
            for h in entry.get("hooks") or []:
                t = h.get("timeout")
                if "bash-edit-guard.sh" in (h.get("command") or "") and isinstance(t, (int, float)) and t > 0:
                    return t
    return 60

try:
    budget = float(os.environ.get("BASH_EDIT_GUARD_BUDGET") or 0) or own_timeout() * 0.75
except ValueError:
    budget = own_timeout() * 0.75
deadline = start + budget

# Argument lists stay well under the Windows command-line limit (32,767 characters).
def chunks(items, limit=16000):
    out, size = [], 0
    for it in items:
        if out and size + len(it) + 3 > limit:
            yield out
            out, size = [], 0
        out.append(it)
        size += len(it) + 3
    if out:
        yield out

def kit_delivered(paths):
    if not os.path.isfile(kit_lib):
        return set()
    found = set()
    for part in chunks(paths):
        try:
            r = subprocess.run([bash, kit_lib, project, *part], capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
        except Exception:
            continue
        if r.returncode == 0:
            found.update(r.stdout.splitlines())
    return found

delivered = kit_delivered(files)
files = [f for f in files if f not in delivered]
if not files:
    sys.exit(0)

pre = [h for e in ((settings.get("hooks") or {}).get("PreToolUse") or []) if matches(e, "Edit")
       for h in (e.get("hooks") or []) if h.get("type") == "command" and h.get("command")]
post = [h for e in ((settings.get("hooks") or {}).get("PostToolUse") or []) if matches(e, "Edit")
        for h in (e.get("hooks") or []) if h.get("type") == "command" and h.get("command")]
pre, post = [h["command"] for h in pre], [h["command"] for h in post]
if not pre and not post:
    sys.exit(0)

MAX_FILES = 40
unchecked = files[MAX_FILES:]
files = files[:MAX_FILES]

def git(args, cwd):
    return subprocess.run(["git", "-c", "core.quotepath=off", "--literal-pathspecs", *args], cwd=cwd,
                          capture_output=True, text=True, encoding="utf-8", errors="replace")

def c_unquote(name):
    esc = {"n": 10, "t": 9, "\"": 34, "\\": 92, "a": 7, "b": 8, "f": 12, "r": 13, "v": 11}
    s, out, i = name[1:-1], bytearray(), 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            if s[i + 1] in "01234567":
                out.append(int(s[i + 1:i + 4], 8) & 0xFF)
                i += 4
            else:
                out.append(esc.get(s[i + 1], ord(s[i + 1]) & 0xFF))
                i += 2
        else:
            out += s[i].encode("utf-8")
            i += 1
    return out.decode("utf-8", "replace")

# Added lines per file from one git diff -U0, keyed by the path after "b/". A line is
# header until the first @@ of its file, so added content that itself begins "++ " is
# still content.
def parse_diff(text):
    added, cur, in_hunks = {}, None, False
    for line in text.split("\n"):
        if line.startswith("diff --git "):
            cur, in_hunks = None, False
        elif not in_hunks:
            if line.startswith("+++ "):
                name = line[4:]
                if name.startswith("\""):
                    name = c_unquote(name)
                cur = name[2:] if name.startswith("b/") else None
                if cur is not None:
                    added.setdefault(cur, [])
            elif line.startswith("@@"):
                in_hunks = True
        elif cur is not None and line.startswith("+"):
            added[cur].append(line[1:])
    return {k: "\n".join(v) for k, v in added.items()}

def read_whole(path):
    try:
        return open(path, encoding="utf-8", errors="replace").read(400_000)
    except OSError:
        return ""

def added_lines_alone(path):
    cwd = os.path.dirname(path)
    if git(["ls-files", "--error-unmatch", "--", path], cwd).returncode != 0:
        return read_whole(path)
    d = git(["diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--src-prefix=a/",
             "--dst-prefix=b/", "HEAD", "--", path], cwd)
    return next(iter(parse_diff(d.stdout).values()), "") if d.returncode == 0 else ""

top = os.path.normcase(os.path.abspath(project))

def in_project_repo(path):
    a = os.path.abspath(path)
    try:
        if os.path.commonpath([top, os.path.normcase(a)]) != top:
            return False
    except ValueError:
        return False
    d = os.path.dirname(a)
    while os.path.normcase(d) != top:
        if os.path.exists(os.path.join(d, ".git")):
            return False
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent
    return True

# One ls-files and one diff for every file in the project repository; a file outside it,
# or inside a nested repository, is asked about on its own.
added = {}
present = [p for p in files if os.path.isfile(p)]
batch = [p for p in present if in_project_repo(p)]
rel = {p: os.path.relpath(os.path.abspath(p), os.path.abspath(project)).replace(os.sep, "/") for p in batch}
tracked = set()
for part in chunks(list(rel.values())):
    r = git(["ls-files", "-z", "--", *part], project)
    if r.returncode == 0:
        tracked.update(x for x in r.stdout.split("\0") if x)
folded = {t.casefold(): t for t in tracked}
in_index = {p: (rel[p] if rel[p] in tracked else folded.get(rel[p].casefold())) for p in batch}
diffs = {}
for part in chunks([t for t in in_index.values() if t]):
    r = git(["diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--src-prefix=a/",
             "--dst-prefix=b/", "--relative", "HEAD", "--", *part], project)
    if r.returncode == 0:
        diffs.update(parse_diff(r.stdout))
for p in batch:
    added[p] = diffs.get(in_index[p], "") if in_index[p] else read_whole(p)
for p in present:
    if p not in added:
        added[p] = added_lines_alone(p)

def guard_name(cmd):
    toks = re.findall(r"[^\s\"\x27]+", cmd)
    return os.path.basename(toks[-1]) if toks else cmd

try:
    per_guard = max(1, int(os.environ.get("BASH_EDIT_GUARD_TIMEOUT") or 60))
except ValueError:
    per_guard = 60

env = dict(os.environ, CLAUDE_PROJECT_DIR=project)

# Each command becomes a script file, LF-terminated so Windows Python writes no CR.
scripts_dir = tempfile.mkdtemp(prefix="bash-edit-guard-")
atexit.register(shutil.rmtree, scripts_dir, True)
commands = list(dict.fromkeys(pre + post))
scripts = {}
for i, cmd in enumerate(commands):
    scripts[cmd] = os.path.join(scripts_dir, str(i) + ".sh").replace(os.sep, "/")
    with open(scripts[cmd], "w", encoding="utf-8", newline="\n") as fh:
        fh.write(cmd + "\n")

# On POSIX the guard runs in its own process group, so a timeout stops everything it
# started, not only the outer bash.
def run_guard(cmd, stdin, limit):
    own_group = os.name != "nt"
    p = subprocess.Popen([bash, scripts[cmd]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, env=env, cwd=project,
                         start_new_session=own_group)
    try:
        out, err = p.communicate(stdin, timeout=limit)
    except subprocess.TimeoutExpired:
        if own_group:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except OSError:
                p.kill()
        else:
            p.kill()
        p.communicate()
        raise
    return subprocess.CompletedProcess(p.args, p.returncode, out, err)

def judge(cmd, r):
    reason, blocked = "", False
    try:
        out = json.loads(r.stdout) if r.stdout.strip() else {}
    except Exception:
        out = {}
    hso = out.get("hookSpecificOutput") or {} if isinstance(out, dict) else {}
    if hso.get("permissionDecision") == "deny":
        blocked, reason = True, hso.get("permissionDecisionReason") or ""
    elif isinstance(out, dict) and out.get("decision") == "block":
        blocked, reason = True, out.get("reason") or ""
    elif r.returncode == 2:
        blocked, reason = True, r.stderr
    # A block with no words is still a block: name the guard so it can be run by hand.
    if blocked and not reason.strip():
        reason = ("Guard " + guard_name(cmd) + " objected to this file without saying why. "
                  "Run it on the file yourself to see the objection.")
    return reason.strip() if blocked else None

base = {k: event.get(k) for k in ("session_id", "transcript_path", "cwd") if event.get(k)}

# One lane per guard command, walking the files in order: different guards run at the
# same time, and no guard ever judges two files at once, so a guard that keeps state
# across a session sees the same sequence a series of Edits would give it.
def lane(ci, cmd):
    found, missed = [], set()
    for fi, path in enumerate(files):
        tool_input = {"file_path": path, "old_string": "", "new_string": added.get(path, "")}
        for phase, event_name in ((0, "PreToolUse"), (1, "PostToolUse")):
            if cmd not in (pre if phase == 0 else post):
                continue
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                missed.add(fi)
                continue
            payload = dict(base, hook_event_name=event_name, tool_name="Edit", tool_input=tool_input,
                           bash_edit_replay=True)
            if phase == 1:
                payload["tool_response"] = {"filePath": path, "success": True}
            limit = min(per_guard, remaining)
            key = (fi, phase, ci)
            # A guard that did not run has not passed the file: say so, never count it an allow.
            try:
                r = run_guard(cmd, json.dumps(payload), limit)
            except subprocess.TimeoutExpired:
                if limit < per_guard:
                    missed.add(fi)
                else:
                    found.append((key, path, "Guard " + guard_name(cmd) + " could not run on this file: it did "
                                  "not finish within " + str(per_guard) + " seconds. Check the file against that "
                                  "guard yourself."))
                continue
            except Exception:
                found.append((key, path, "Guard " + guard_name(cmd) + " could not run on this file: it failed "
                              "to start. Check the file against that guard yourself."))
                continue
            if r.returncode in (126, 127):
                found.append((key, path, "Guard " + guard_name(cmd) + " could not run on this file: it was not "
                              "found or is not executable. Check the file against that guard yourself."))
                continue
            reason = judge(cmd, r)
            if reason is not None:
                found.append((key, path, reason))
    return found, missed

results, out_of_time = [], set()
with ThreadPoolExecutor(max_workers=min(8, len(commands))) as pool:
    for found, missed in pool.map(lambda a: lane(*a), enumerate(commands)):
        results += found
        out_of_time |= missed

findings = [(path, reason) for _, path, reason in sorted(results, key=lambda x: x[0])]
for fi in sorted(out_of_time):
    findings.append((files[fi], "Not checked: the guards ran out of time (" + ("%g" % budget) + " seconds) "
                     "before finishing these files. Check them against the project rules yourself, or make "
                     "changes in smaller commands."))
for p in unchecked:
    findings.append((p, "Not checked: the guards replay at most " + str(MAX_FILES) + " changed files per "
                     "command. Check these against the project rules yourself, or make changes in smaller "
                     "commands."))

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
