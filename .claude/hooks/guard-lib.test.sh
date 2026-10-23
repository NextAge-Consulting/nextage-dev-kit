#!/usr/bin/env bash
# Regression suite for guard-lib.sh — the toolchain check and path normaliser every
# kit hook relies on. A defect here is a defect in every guard at once, and the
# failure it exists to prevent is silent: a guard that cannot read its input allows.
set -uo pipefail
L="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/guard-lib.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp/markers"; mkdir -p "$TMPDIR"
# shellcheck source=guard-lib.sh
source "$L"
# shellcheck source=test-helpers.sh
source "$(dirname "$L")/test-helpers.sh"

eq(){ if [ "$2" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }

echo "PATH SPELLING — every spelling of a Windows path is one path:"
for p in 'C:\Users\dev\proj\a.md' 'c:\Users\dev\proj\a.md' 'C:/Users/dev/proj/a.md' \
         '/C/Users/dev/proj/a.md' '/c/Users/dev/proj/a.md' '/cygdrive/c/Users/dev/proj/a.md' \
         'C:\Users\dev\other\..\proj\.\a.md'; do
  eq '/c/Users/dev/proj/a.md' "$(path_spelling "$p")" "$p"
done
eq '/c' "$(path_spelling 'C:')"            'bare drive'
eq 'src/b.ts' "$(path_spelling 'src/./a/../b.ts')" 'relative path keeps relative'
eq '../x' "$(path_spelling '../x')"        'leading .. on a relative path is kept'
eq '/' "$(path_spelling '/a/..')"          'collapsing to the root'
eq '/tmp/a*b' "$(path_spelling '/tmp/./a*b')" 'a glob character is text, not a pattern'

echo "NORMALIZE — symlinks resolve, missing tails survive:"
mkdir -p "$tmp/real/sub"; ln -s "$tmp/real" "$tmp/link"
real=$(cd "$tmp/real" && pwd -P)
eq "$real/sub"         "$(normalize_path "$tmp/link/sub")"        'existing dir through a symlink'
eq "$real/sub/new.md"  "$(normalize_path "$tmp/link/sub/new.md")" 'file not yet created, parent through a symlink'
eq "$real/a/b/c"       "$(normalize_path "$tmp/link/a/b/c")"      'several missing segments'
eq '/c/Users/dev/x'    "$(normalize_path 'C:\Users\dev\x')"       'a drive path that does not exist here stays spelled'

echo "RELATIVE TO A ROOT:"
rel(){ path_rel_to "$1" "$2"; printf '|%s' "$?"; }
eq '.claude/x.md|0'    "$(rel 'C:\proj' 'c:/proj/.claude/x.md')"    'Windows root, mixed spellings'
eq '.claude/x.md|0'    "$(rel '/c/proj' 'C:\proj\.claude\x.md')"    'Git Bash root, backslash file'
eq 'sub/f|0'           "$(rel "$tmp/link" "$tmp/real/sub/f")"       'root through a symlink, file through the target'
eq 'sub/f|0'           "$(rel "$tmp/real" "$tmp/link/sub/f")"       'root as the target, file through the symlink'
eq 'a/b|0'             "$(rel '/x' 'a/b')"                          'relative path is already relative'
eq '|1'                "$(rel '/a/b' '/a/bc/d')"                    'a sibling sharing a prefix is outside'
eq '|1'                "$(rel '/a/b' '/a/b')"                       'the root itself is not a file in it'
eq '|1'                "$(rel '/a/b' '../escape')"                  'a relative path climbing out is outside'
eq '|1'                "$(rel '/a/b' '/etc/hosts')"                 'an unrelated absolute path is outside'

echo "HASHING — sha256sum or shasum, same digest:"
printf 'abc' > "$tmp/h"
want=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
eq "$want" "$(sha256_file "$tmp/h")" 'sha256_file'
eq "$want" "$(sha256_stdin < "$tmp/h")" 'sha256_stdin'
eq "$want" "$(PATH="$(path_without sha256sum)" bash -c 'source "$0"; sha256_file "$1"' "$L" "$tmp/h")" 'without sha256sum'
printf '' > "$tmp/odd\\name"
empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
eq "$want"$'\n'"$empty"$'\n'"$want" "$(sha256_files "$tmp/h" "$tmp/odd\\name" "$tmp/h")" 'sha256_files: one digest per file, in order, a backslash in a name'
eq "$want"$'\n'"$empty" "$(PATH="$(path_without sha256sum)" bash -c 'source "$0"; sha256_files "$1" "$2"' "$L" "$tmp/h" "$tmp/odd\\name")" 'sha256_files without sha256sum'
eq '|1' "$(out=$(sha256_files "$tmp/h" "$tmp/nope"); printf '%s|%s' "$out" "$?")" 'sha256_files: a missing file fails and prints nothing'

echo "EVENT NAME without jq:"
eq 'PostCompact' "$(hook_event_of '{"hook_event_name": "PostCompact","session_id":"x"}')" 'spaced JSON'
eq 'PreToolUse'  "$(hook_event_of '{"tool_name":"Edit","hook_event_name":"PreToolUse"}')" 'later key'
eq ''            "$(hook_event_of 'not json')" 'absent'

echo "CWD without jq:"
eq '/a/b c'      "$(hook_cwd_of '{"session_id":"x","cwd": "/a/b c","tool_name":"Bash"}')" 'spaced JSON'
eq 'C:\proj\x'   "$(hook_cwd_of '{"cwd":"C:\\proj\\x"}')"                                 'a Windows path, its backslashes unescaped'
eq '/a/"q"'      "$(hook_cwd_of '{"cwd":"/a/\"q\""}')"                                    'an escaped quote'
eq ''            "$(hook_cwd_of '{"tool_input":{"command":"echo \"cwd\":\"/x\""}}')"      'a "cwd" inside a string is not the key'
eq ''            "$(hook_cwd_of '{"cwd":"/caf\u00e9"}')"                                  'a \u escape is not guessed at'
eq ''            "$(hook_cwd_of 'not json')"                                              'absent'

echo "PROJECT ROOT — the checkout holding the path, a worktree's own root inside one:"
# A real repository with a worktree under .claude/worktrees, as gitflow's worktree mode
# lays it out. Claude Code keeps CLAUDE_PROJECT_DIR at the primary in a worktree session.
pr="$tmp/pr/primary"; mkdir -p "$pr/src"; : > "$pr/src/a.ts"
git -C "$pr" init -q; git -C "$pr" config user.email t@example.com; git -C "$pr" config user.name t
git -C "$pr" add -A; git -C "$pr" commit -qm init
git -C "$pr" worktree add -q "$pr/.claude/worktrees/x" -b wt-x 2>/dev/null
wt="$pr/.claude/worktrees/x"
root(){ CLAUDE_PROJECT_DIR="$1" project_root_for "$2"; }
eq "$wt" "$(root "$pr" "$wt/src/a.ts")"          'a file in the worktree → the worktree root'
eq "$wt" "$(root "$pr" "$wt/new/deep/b.ts")"     'a file not yet created in the worktree → the worktree root'
eq "$wt" "$(root "$pr" "$wt")"                   'the worktree root itself (a cwd)'
eq "$pr" "$(root "$pr" "$pr/src/a.ts")"          'a file in the primary → the primary'
eq "$pr" "$(root "$pr" "src/a.ts")"              'a relative path is taken from the project dir'
eq "$pr" "$(root "$pr" "")"                      'no path → the project dir'
eq "$pr" "$(root "$wt" "$pr/src/a.ts")"          'project dir is the worktree, file in the primary → the primary'
mkdir -p "$tmp/pr/plain"
eq "$tmp/pr/plain" "$(root "$tmp/pr/plain" "/etc/hosts")" 'a path in no checkout → the project dir'
ln -s "$pr" "$tmp/pr/link"
eq "$tmp/pr/link/.claude/worktrees/x" "$(root "$tmp/pr/link" "$wt/src/a.ts")" 'kept in the project dir'"'"'s own spelling through a symlink'
mkdir -p "$tmp/pr/outer/proj"; git -C "$tmp/pr/outer" init -q
eq "$tmp/pr/outer/proj" "$(root "$tmp/pr/outer/proj" "$tmp/pr/outer/proj/a.ts")" 'an enclosing repository the project is not a checkout of → the project dir'
eq "$tmp/pr/outer" "$(root "$pr" "$tmp/pr/outer/b.ts")" 'a file in another repository → that repository'

echo "REQUIRE_TOOLS — present tools pass silently and are remembered:"
out=$(require_tools PreToolUse jq python3; echo "returned")
eq 'returned' "$out" 'jq and python3 present: returns, prints nothing'
if ls "$TMPDIR"/kit-toolchain-ok-* >/dev/null 2>&1; then echo "  ✓ a passing check leaves a marker"; else echo "  ✗ FAIL — no marker"; fail=1; fi
kit_clear_tool_markers
ls "$TMPDIR"/kit-toolchain-ok-* >/dev/null 2>&1 && { echo "  ✗ FAIL — markers survive clearing"; fail=1; } || echo "  ✓ kit_clear_tool_markers removes them"

echo "REQUIRE_TOOLS — a missing or broken tool refuses, in the event's own form:"
mkdir -p "$tmp/hookdir"
{ printf '#!/bin/bash\nsource "%s"\n' "$L"; cat <<'EOF'
require_tools "$1" jq python3
echo UNREACHED
EOF
} > "$tmp/hookdir/my\"guard.sh"
chmod +x "$tmp/hookdir/my\"guard.sh"
form(){ # $1 PATH  $2 event → "<kind> <tool-named?> <unreached?>"
  PATH="$1" "$tmp/hookdir/my\"guard.sh" "$2" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read()
if "UNREACHED" in raw: print("UNREACHED"); raise SystemExit
try: d = json.loads(raw)
except Exception: print("malformed"); raise SystemExit
h = d.get("hookSpecificOutput") or {}
if h.get("permissionDecision") == "deny": k, t = "deny", h["permissionDecisionReason"]
elif d.get("decision") == "block": k, t = "block", d["reason"]
elif "systemMessage" in d: k, t = "warn", d["systemMessage"]
else: k, t = "other", ""
named = [x for x in ("jq", "python3") if x + ":" in t]
print(k, ",".join(named), "my\"guard.sh" in t)
'; }
nojq=$(path_without jq); store=$(path_with_store_python); nopy=$(path_without python3)
eq 'deny jq True'       "$(form "$nojq" PreToolUse)"   'no jq → PreToolUse deny naming jq and the guard'
eq 'block jq True'      "$(form "$nojq" PostToolUse)"  'no jq → PostToolUse block'
eq 'warn jq True'       "$(form "$nojq" SessionStart)" 'no jq → other events warn'
eq 'deny python3 True'  "$(form "$store" PreToolUse)"  'Windows Store python3 stub → deny naming python3'
eq 'deny python3 True'  "$(form "$nopy" PreToolUse)"   'no python3 → deny naming python3'
printf '#!/bin/sh\necho "jq: error while loading shared libraries" >&2\nexit 127\n' > "$tmp/brokenjq"; mkdir -p "$tmp/bj"; mv "$tmp/brokenjq" "$tmp/bj/jq"; chmod +x "$tmp/bj/jq"
eq 'deny jq True'       "$(form "$tmp/bj:$PATH" PreToolUse)" 'jq present but failing → deny'

echo "INSTALL LINES per platform:"
case "$(OSTYPE=darwin24 install_hint jq)" in *'brew install jq'*) echo "  ✓ macOS jq" ;; *) echo "  ✗ FAIL macOS jq"; fail=1 ;; esac
case "$(OSTYPE=msys install_hint jq)" in *'winget install jqlang.jq'*) echo "  ✓ Windows jq" ;; *) echo "  ✗ FAIL Windows jq"; fail=1 ;; esac
case "$(OSTYPE=msys install_hint python3)" in *'App execution alias'*) echo "  ✓ Windows python3 names the Store alias" ;; *) echo "  ✗ FAIL Windows python3"; fail=1 ;; esac
case "$(OSTYPE=linux-gnu install_hint jq)" in *'apt install jq'*) echo "  ✓ Linux jq" ;; *) echo "  ✗ FAIL Linux jq"; fail=1 ;; esac

echo "WINDOWS jq — native jq.exe writes CRLF; the wrapper asks for LF:"
got=$(bash -c 'OSTYPE=msys; source "$0"; type -t jq; printf "{\"a\":\"x\"}" | jq -r .a | od -An -c | tr -d " "' "$L")
eq "$(printf 'function\nx\\n')" "$got" 'on Windows jq is wrapped and its output ends in LF only'
got=$(bash -c 'OSTYPE=darwin24; source "$0"; type -t jq' "$L")
eq 'file' "$got" 'elsewhere jq is the plain binary'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
