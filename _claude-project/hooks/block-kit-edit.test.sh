#!/usr/bin/env bash
# Regression suite for block-kit-edit.sh.
#
# TWO behaviours are load-bearing and pull in opposite directions, so both are pinned:
#
#   1. `mode` decides, never the presence of the manifest key. An `owned` file is the
#      kit's and is blocked; a `template` file was merely seeded by the kit and the
#      PROJECT owns it from there — blocking those would stop a project editing its
#      own ui-inventory or ci.yml.
#   2. The maintainer marker (~/.claude/kitmaster) makes the whole hook inert.
#
# And one escape: an owned file with an entry in .claude/.kit-patches.json naming both
# a kit issue and a project issue is a sanctioned temporary patch, and passes.
#
# A `merge` file sits between the two: an edit passes when it changes only the bodies
# of the file's project regions, whether it arrives as Edit, MultiEdit, Write or a
# shell edit replayed by bash-edit-guard.sh.
#
# HOME is redirected at a temp dir throughout so the suite tests real logic rather
# than whatever the machine running it happens to be. On the maintainer's own machine
# the marker exists, and without this the guarded cases would all vacuously "pass".
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/block-kit-edit.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

mkdir -p "$tmp/proj/.claude" "$tmp/consumer-home/.claude" "$tmp/maintainer-home/.claude"
touch "$tmp/maintainer-home/.claude/kitmaster"
cat > "$tmp/proj/.claude/.kit-sync.json" <<'JSON'
{"kitRepo":"example-org/example-kit","files":{
  ".claude/rules/constitution.md":      {"mode":"owned"},
  ".claude/hooks/git-guard.sh":         {"mode":"owned"},
  ".claude/rules/project/ui-inventory.md": {"mode":"template"},
  ".github/workflows/ci.yml":           {"mode":"template"},
  ".claude/legacy-bare-string.md":      "some-hash",
  ".claude/rules/patched.md":           {"mode":"owned"},
  ".claude/rules/half-patched.md":      {"mode":"owned"}
}}
JSON

decision(){  # $1 path  $2 tool  $3 home
  printf '{"tool_name":"%s","tool_input":{"file_path":%s}}' "$2" \
    "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$1")" \
  | HOME="$3" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
'
}
t(){ d=$(decision "$2" "${5:-Edit}" "${6:-$tmp/consumer-home}"); d=${d:-allow}
     if [ "$d" = "$1" ]; then echo "  ✓ $4"; else echo "  ✗ FAIL ($d, want $1) — $4"; fail=1; fi; }

echo "CONSUMER MACHINE — mode:owned is the kit's, must be denied:"
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule, absolute path'
t deny ".claude/rules/constitution.md"           x 'owned rule, relative path'
t deny "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook'
t deny "$tmp/proj/.claude/legacy-bare-string.md" x 'legacy bare-string entry means owned'
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule via Write' Write

echo "CONSUMER MACHINE — MultiEdit is a write path too:"
t deny "$tmp/proj/.claude/rules/constitution.md" x 'owned rule via MultiEdit' MultiEdit
t deny "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook via MultiEdit' MultiEdit

echo "CONSUMER MACHINE — Windows and symlinked spellings of an owned file are still denied:"
proj_phys=$(cd "$tmp/proj" && pwd -P)
win="${proj_phys//\//\\}\\.claude\\rules\\constitution.md"
t deny "$win"                                      x 'backslash separators'
t deny "${proj_phys}/.claude/./rules/../rules/constitution.md" x 'dot segments'
ln -s "$tmp/proj" "$tmp/proj-link"
t deny "$tmp/proj-link/.claude/rules/constitution.md" x 'file named through a symlinked project dir'
lr=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$tmp/proj/.claude/rules/constitution.md" \
     | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/proj-link" "$H" 2>/dev/null)
case "$lr" in *'"deny"'*) echo "  ✓ project dir given as the symlink, file as the target" ;;
              *) echo "  ✗ FAIL — symlinked CLAUDE_PROJECT_DIR let an owned file through"; fail=1 ;; esac

echo "CONSUMER MACHINE — the deny carries the script Claude puts to the human:"
msg=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$tmp/proj/.claude/rules/constitution.md" \
      | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" 2>/dev/null \
      | python3 -c 'import json,sys;print(json.load(sys.stdin)["hookSpecificOutput"]["permissionDecisionReason"])')
for want in 'I think .claude/rules/constitution.md needs to change because' 'example-org/example-kit' \
            'Not blocking' 'Blocking' '.claude/.kit-patches.json' 'kitIssue' 'projectIssue' 'naming both issues'; do
  case "$msg" in *"$want"*) echo "  ✓ carries: $want" ;;
                 *) echo "  ✗ FAIL — deny reason missing: $want"; fail=1 ;; esac
done

echo "CONSUMER MACHINE — the patch register sanctions a temporary patch:"
cat > "$tmp/proj/.claude/.kit-patches.json" <<'JSON'
{"patches":[
  {"path":".claude/rules/patched.md","kitIssue":"example-org/example-kit#12","projectIssue":"#34","reason":"blocks the build"},
  {"path":".claude/rules/half-patched.md","kitIssue":"example-org/example-kit#13","projectIssue":"","reason":"no project issue yet"}
]}
JSON
t allow "$tmp/proj/.claude/rules/patched.md"      x 'entry with both issues → allowed'
t deny  "$tmp/proj/.claude/rules/half-patched.md" x 'entry missing the project issue → still denied'
t deny  "$tmp/proj/.claude/rules/constitution.md" x 'no entry → still denied'
printf 'not json' > "$tmp/proj/.claude/.kit-patches.json"
t deny  "$tmp/proj/.claude/rules/patched.md"      x 'unreadable register → denied'
rm -f "$tmp/proj/.claude/.kit-patches.json"

echo "MERGE MODE — only project-region bodies are the project's:"
mkdir -p "$tmp/mp/.claude" "$tmp/mp/docs" "$tmp/mp/.github/workflows"
cat > "$tmp/mp/.claude/.kit-sync.json" <<'JSON'
{"kitRepo":"example-org/example-kit","files":{
  "docs/style.md":            {"mode":"merge"},
  ".github/workflows/ci.yml": {"mode":"merge"},
  "docs/not-yet.md":          {"mode":"merge"},
  "docs/registered.md":       {"mode":"merge"}
}}
JSON
md=$'# Style\nKit rule one.\n<!-- project:begin rules -->\nProject rule A.\n<!-- project:end rules -->\nKit footer.\n'
printf '%s' "$md" > "$tmp/mp/docs/style.md"; printf '%s' "$md" > "$tmp/mp/docs/registered.md"
printf '%s' $'jobs:\n  build:\n    steps:\n      - run: kit step\n      # project:begin steps\n      - run: project step\n      # project:end steps\n' > "$tmp/mp/.github/workflows/ci.yml"
cat > "$tmp/mp/.claude/.kit-patches.json" <<'JSON'
{"patches":[{"path":"docs/registered.md","kitIssue":"example-org/example-kit#7","projectIssue":"#9","reason":"blocks release"}]}
JSON
# mt <want> <desc> <python dict literal for tool_name + tool_input; FILE is the target>
mt(){ local want="$1" desc="$2" spec="$3" d
  d=$(python3 -c '
import json, sys
FILE = sys.argv[1]
print(json.dumps(eval(sys.argv[2])))
' "$tmp/mp/${4:-docs/style.md}" "$spec" \
  | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/mp" "$H" 2>/dev/null | python3 -c '
import json,sys
raw=sys.stdin.read().strip()
if not raw: print("allow"); raise SystemExit
try: print((json.loads(raw).get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
except Exception: print("malformed")
')
  if [ "$d" = "$want" ]; then echo "  ✓ $desc"; else echo "  ✗ FAIL ($d, want $want) — $desc"; fail=1; fi; }
# me <want> <desc> <old_string> <new_string> [file] — an Edit; `\n` in the strings is a newline.
me(){ mt "$1" "$2" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":FILE,\"old_string\":$(q "$3"),\"new_string\":$(q "$4")}}" "${5:-}"; }
q(){ python3 -c 'import json,sys; print(json.dumps(sys.argv[1].replace("\\n", "\n")))' "$1"; }
me allow 'Edit inside a region' 'Project rule A.' 'Project rule A, revised.'
me allow 'Edit adding lines inside a region' 'Project rule A.' 'Project rule A.\nProject rule B.'
me deny 'Edit outside the regions' 'Kit rule one.' 'Kit rule one, changed.'
me deny 'Edit renaming a marker' '<!-- project:end rules -->' '<!-- project:end other -->'
me deny 'Edit deleting an end marker' '<!-- project:end rules -->\n' ''
me deny 'Edit nesting a begin inside a region' 'Project rule A.' '<!-- project:begin inner -->'
me deny 'Edit adding a duplicate region' 'Kit footer.' 'Kit footer.\n<!-- project:begin rules -->\nx\n<!-- project:end rules -->'
me deny 'Edit whose old_string is not in the file' 'no such text' 'x'
mt allow 'MultiEdit, every edit inside regions' '{"tool_name":"MultiEdit","tool_input":{"file_path":FILE,"edits":[{"old_string":"Project rule A.","new_string":"A1"},{"old_string":"A1","new_string":"A2"}]}}'
mt deny  'MultiEdit with one edit outside'     '{"tool_name":"MultiEdit","tool_input":{"file_path":FILE,"edits":[{"old_string":"Project rule A.","new_string":"A1"},{"old_string":"Kit footer.","new_string":"F"}]}}'
mt allow 'Write that changes only a region'    '{"tool_name":"Write","tool_input":{"file_path":FILE,"content":"# Style\nKit rule one.\n<!-- project:begin rules -->\nAll new.\nMore.\n<!-- project:end rules -->\nKit footer.\n"}}'
mt deny  'Write that changes kit text'         '{"tool_name":"Write","tool_input":{"file_path":FILE,"content":"# Style\nKit rule CHANGED.\n<!-- project:begin rules -->\nProject rule A.\n<!-- project:end rules -->\nKit footer.\n"}}'
me allow 'hash markers: Edit inside a region' '- run: project step' '- run: project step two' .github/workflows/ci.yml
me deny 'hash markers: Edit outside' '- run: kit step' '- run: other' .github/workflows/ci.yml
me deny 'md markers do not count in a non-md file' '# project:begin steps' '<!-- project:begin steps -->' .github/workflows/ci.yml
me allow 'registered path: an edit outside its regions is allowed' 'Kit rule one.' 'Patched.' docs/registered.md
mt deny  'merge file not on disk yet (sync creates it)' '{"tool_name":"Write","tool_input":{"file_path":FILE,"content":"x"}}' docs/not-yet.md

echo "MERGE MODE — a shell edit replayed by bash-edit-guard is judged against HEAD:"
rp="$tmp/rp"; mkdir -p "$rp/.claude/hooks" "$rp/docs"
cp "$H" "$(dirname "$H")/guard-lib.sh" "$(dirname "$H")/kit-delivered.sh" "$rp/.claude/hooks/"
cp "$(dirname "$H")/bash-edit-guard.sh" "$rp/.claude/hooks/"
printf '{"kitRepo":"example-org/example-kit","files":{"docs/style.md":{"mode":"merge"}}}' > "$rp/.claude/.kit-sync.json"
printf '%s' '{"hooks":{"PreToolUse":[{"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/block-kit-edit.sh"}]}]}}' > "$rp/.claude/settings.json"
printf '%s' "$md" > "$rp/docs/style.md"
git -C "$rp" init -q; git -C "$rp" config user.email t@example.com; git -C "$rp" config user.name t
git -C "$rp" add -A 2>/dev/null; git -C "$rp" commit -qm init
replay(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_response":{"bashEditDiff":{"changedFiles":[sys.argv[2]]}}}))' "$rp" "$rp/docs/style.md" \
  | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$rp" "$rp/.claude/hooks/bash-edit-guard.sh" 2>/dev/null \
  | python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.loads(s).get("decision") if s else "allow")'; }
printf '%s' "${md/Project rule A./Shell-edited project rule.}" > "$rp/docs/style.md"
[ "$(replay)" = allow ] && echo "  ✓ shell edit inside a region passes the replay" || { echo "  ✗ FAIL — in-region shell edit flagged"; fail=1; }
printf '%s' "${md/Kit footer./Shell-edited footer.}" > "$rp/docs/style.md"
[ "$(replay)" = block ] && echo "  ✓ shell edit outside the regions is flagged" || { echo "  ✗ FAIL — out-of-region shell edit passed"; fail=1; }

echo "CONSUMER MACHINE — mode:template is the PROJECT'S, must be allowed:"
t allow "$tmp/proj/.claude/rules/project/ui-inventory.md" x 'template: ui-inventory'
t allow "$tmp/proj/.github/workflows/ci.yml"              x 'template: ci.yml'

echo "CONSUMER MACHINE — files the kit does not manage:"
t allow "$tmp/proj/apps/shared/src/index.ts"   x 'ordinary source file'
t allow "$tmp/proj/.claude/settings.local.json" x 'project-local settings'
t allow "/etc/hosts"                            x 'absolute path outside the project'
t allow "$tmp/proj/.claude/rules/constitution.md" x 'non-Edit/Write tool is out of scope' Bash

echo "MAINTAINER MACHINE — the kitmaster marker makes the hook inert:"
t allow "$tmp/proj/.claude/rules/constitution.md" x 'owned rule passes for the maintainer' Edit "$tmp/maintainer-home"
t allow "$tmp/proj/.claude/hooks/git-guard.sh"    x 'owned hook passes for the maintainer' Edit "$tmp/maintainer-home"

echo "NO MANIFEST — a non-kit project must be untouched:"
mkdir -p "$tmp/bare/.claude"
nm=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$tmp/bare/.claude/rules/x.md" \
     | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/bare" "$H" 2>/dev/null)
if [ -z "$nm" ]; then echo "  ✓ no .kit-sync.json → nothing guarded"; else echo "  ✗ FAIL — blocked in a non-kit project"; fail=1; fi

echo "DEGENERATE INPUT (never wedge the session):"
for p in 'not json' '' '{"tool_name":"Edit"}' '{"tool_name":"Edit","tool_input":{}}'; do
  printf '%s' "$p" | HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" >/dev/null 2>&1
  if [ $? -le 1 ]; then echo "  ✓ survives: ${p:-（empty）}"; else echo "  ✗ FAIL — crashed on: $p"; fail=1; fi
done

echo "TOOL MISSING — on a consumer machine the guard refuses, naming the tool:"
mkdir -p "$tmp/markers"
nojq=$(path_without jq)
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' \
      | PATH="$nojq" TMPDIR="$tmp/markers" HOME="$tmp/consumer-home" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" 2>/dev/null)
case "$out" in *'"deny"'*jq*) echo "  ✓ no jq on PATH → deny naming jq" ;;
               *) echo "  ✗ FAIL — no jq did not deny: $out"; fail=1 ;; esac
out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"src/a.ts"}}' \
      | PATH="$nojq" TMPDIR="$tmp/markers" HOME="$tmp/maintainer-home" CLAUDE_PROJECT_DIR="$tmp/proj" "$H" 2>/dev/null)
[ -z "$out" ] && echo "  ✓ maintainer machine stays inert without jq" || { echo "  ✗ FAIL — maintainer blocked: $out"; fail=1; }

exit "$fail"
