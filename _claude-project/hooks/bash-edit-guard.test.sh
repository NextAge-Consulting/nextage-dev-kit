#!/usr/bin/env bash
# Regression suite for bash-edit-guard.sh.
#
# Fixture: a throwaway git repo whose .claude/settings.json wires stub guards, so the
# suite tests the adapter's contract — which files it replays, through which hooks,
# with what payload — independent of the kit's real guards.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bash-edit-guard.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo/.claude/hooks" "$repo/src"
git -C "$repo" init -q && git -C "$repo" config user.email t@example.com && git -C "$repo" config user.name t

# Pre guard: denies any file whose path contains "forbidden", any new_string with "BAD(",
# and any replay whose bash_command is MARK-CMD (proves the command is passed through).
cat > "$repo/.claude/hooks/pre.sh" <<'EOF'
#!/bin/bash
python3 -c '
import json,sys
d=json.load(sys.stdin); ti=d["tool_input"]
why = "path is forbidden" if "forbidden" in ti["file_path"] else ("added BAD(" if "BAD(" in ti["new_string"] else "")
if not why and d.get("bash_command") == "MARK-CMD": why = "saw bash_command"
if why: print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":why+" \"q\""}}))
'
EOF
# Post hook: exit 2 on any file named broken.*
cat > "$repo/.claude/hooks/post.sh" <<'EOF'
#!/bin/bash
f=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["tool_input"]["file_path"])')
case "$f" in */broken.*) echo "suite red for $f" >&2; exit 2 ;; esac
exit 0
EOF
# Bash-matched hook: must never be replayed.
cat > "$repo/.claude/hooks/bashonly.sh" <<'EOF'
#!/bin/bash
echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"BASH-ONLY HOOK RAN"}}'
EOF
chmod +x "$repo/.claude/hooks/"*.sh
cat > "$repo/.claude/settings.json" <<'EOF'
{"hooks":{
 "PreToolUse":[
  {"matcher":"Bash","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bashonly.sh"}]},
  {"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/pre.sh"}]}],
 "PostToolUse":[
  {"matcher":"Edit|Write|MultiEdit","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/post.sh"}]}]}}
EOF
printf 'BAD(1)\nok\n' > "$repo/src/old.ts"
git -C "$repo" add -A && git -C "$repo" commit -qm init

run(){ # $1 = raw stdin
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null
}
event(){ # args = changed file paths (absolute)
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":"s","cwd":sys.argv[1],"tool_response":{"bashEditDiff":{"changedFiles":sys.argv[2:]}}}))' "$repo" "$@"
}
verdict(){ run "$1" | python3 -c '
import json,sys
s=sys.stdin.read().strip()
if not s: print("allow"); raise SystemExit
try: d=json.loads(s)
except Exception: print("BADJSON"); raise SystemExit
print("block" if d.get("decision")=="block" else "allow")
'; }
t(){ got=$(verdict "$2"); if [ "$got" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $got, want $1) — $3"; fail=1; fi; }

echo "MUST ALLOW:"
printf 'ok\n' > "$repo/src/clean.ts"
t allow "$(event "$repo/src/clean.ts")" 'a new file every guard accepts'
printf 'BAD(1)\nok\nmore\n' > "$repo/src/old.ts"
t allow "$(event "$repo/src/old.ts")" 'committed content is not judged — only lines added since HEAD'
t allow '{"tool_name":"Bash","tool_response":{"stdout":"x"}}' 'no bashEditDiff (non-edit command)'
t allow "$(event)" 'empty changedFiles'
out=$(printf '%s' "$(event "$repo/src/forbidden.ts")" | SKIP_BASH_EDIT_GUARD=1 CLAUDE_PROJECT_DIR="$repo" "$H")
if [ -z "$out" ]; then echo "  ✓ SKIP_BASH_EDIT_GUARD=1 skips"; else echo "  ✗ FAIL — override did not skip"; fail=1; fi

echo "MUST BLOCK:"
printf 'x\n' > "$repo/src/forbidden.ts"
t block "$(event "$repo/src/forbidden.ts")" 'a path-based Pre guard denies'
printf 'BAD(2)\n' >> "$repo/src/old.ts"
t block "$(event "$repo/src/old.ts")" 'a content guard sees an added line'
printf 'BAD(3)\n' > "$repo/src/untracked.ts"
t block "$(event "$repo/src/untracked.ts")" 'an untracked file is judged whole'
printf 'x\n' > "$repo/src/broken.sh"
t block "$(event "$repo/src/broken.sh")" 'a PostToolUse hook exiting 2 is reported'
t block "$(event "$repo/src/clean.ts" "$repo/src/forbidden.ts")" 'one bad file among clean ones'

echo "KIT DELIVERY (content matches .claude/.kit-sync.json):"
lock="$repo/.claude/.kit-sync.json"
printf 'kit content\n' > "$repo/src/forbidden-kit.md"
sha=$(shasum -a 256 "$repo/src/forbidden-kit.md" | cut -d' ' -f1)
printf '{"files":{"src/forbidden-kit.md":{"sha":"%s","mode":"owned"}}}' "$sha" > "$lock"
t allow "$(event "$repo/src/forbidden-kit.md")" 'a file exactly as the kit delivered it is not replayed'
t block "$(event "$repo/src/forbidden-kit.md" "$repo/src/forbidden.ts")" 'the other files in the same command are still replayed'
printf '{"files":{"src/forbidden-kit.md":"%s"}}' "$sha" > "$lock"
t allow "$(event "$repo/src/forbidden-kit.md")" 'a legacy bare-string lockfile entry is recognised'
printf 'edited here\n' >> "$repo/src/forbidden-kit.md"
t block "$(event "$repo/src/forbidden-kit.md")" 'the same file edited after delivery is replayed'
printf 'not json' > "$lock"
t block "$(event "$repo/src/forbidden-kit.md")" 'an unreadable lockfile never disables the guards'
rm -f "$lock"

echo "ONLY EDIT-MATCHED HOOKS ARE REPLAYED:"
if run "$(event "$repo/src/forbidden.ts")" | grep -q "BASH-ONLY HOOK RAN"; then
  echo "  ✗ FAIL — a Bash-matched hook was replayed"; fail=1
else echo "  ✓ Bash-matched hooks are not run"; fi

echo "BLOCK PAYLOAD MUST BE VALID JSON:"
if run "$(event "$repo/src/forbidden.ts")" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["decision"]=="block" and "src/forbidden.ts" in d["reason"] and "\"q\"" in d["reason"]' 2>/dev/null; then
  echo "  ✓ valid JSON naming the file, quotes intact"
else echo "  ✗ FAIL — block payload unparseable or incomplete"; fail=1; fi

echo "A GUARD THAT DOES NOT RUN IS A FINDING, NEVER AN ALLOW:"
cp "$repo/.claude/settings.json" "$tmp/settings.saved"
printf '#!/bin/bash\nsleep 5\n' > "$repo/.claude/hooks/slow.sh"; chmod +x "$repo/.claude/hooks/slow.sh"
cat > "$repo/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[
  {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/slow.sh"},
  {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/not-there.sh"}]}]}}
EOF
printf 'ok\n' > "$repo/src/fine.ts"
reason=$(printf '%s' "$(event "$repo/src/fine.ts")" | BASH_EDIT_GUARD_TIMEOUT=1 CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"], d["reason"])' 2>/dev/null)
case "$reason" in block*"slow.sh could not run"*"did not finish"*) echo "  ✓ a guard that times out is reported by name" ;;
                  *) echo "  ✗ FAIL — timeout not reported: $reason"; fail=1 ;; esac
case "$reason" in *"not-there.sh could not run"*"not found"*) echo "  ✓ a guard that is not found is reported by name" ;;
                  *) echo "  ✗ FAIL — missing guard not reported: $reason"; fail=1 ;; esac
cp "$tmp/settings.saved" "$repo/.claude/settings.json"

echo "A BLOCK WITH NO REASON STILL SAYS WHICH GUARD:"
printf '%s\n' '#!/bin/bash' 'echo '"'"'{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"  "}}'"'" > "$repo/.claude/hooks/mute.sh"
chmod +x "$repo/.claude/hooks/mute.sh"
cat > "$repo/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/mute.sh"}]}]}}
EOF
reason=$(printf '%s' "$(event "$repo/src/fine.ts")" | CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null \
         | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["decision"], d["reason"])' 2>/dev/null)
case "$reason" in block*"mute.sh objected to this file without saying why"*) echo "  ✓ a reasonless block names its guard" ;;
                  *) echo "  ✗ FAIL — reasonless block: $reason"; fail=1 ;; esac
cp "$tmp/settings.saved" "$repo/.claude/settings.json"

echo "PROJECT DIR FROM THE PAYLOAD when CLAUDE_PROJECT_DIR is unset:"
got=$(printf '%s' "$(event "$repo/src/forbidden.ts")" | env -u CLAUDE_PROJECT_DIR "$H" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("decision"))' 2>/dev/null)
if [ "$got" = block ]; then echo "  ✓ cwd in the payload locates the project"; else echo "  ✗ FAIL (got $got) — payload cwd ignored"; fail=1; fi

echo "NO SHELL TEXT IN ARGV — Windows re-splits it, and its quotes arrive unbalanced:"
# A bash on PATH that refuses any argument containing a double quote stands in for Git
# Bash receiving a Python argv on Windows.
real_bash=$(command -v bash)
mkdir -p "$tmp/shim"
{ printf '#!%s\n' "$real_bash"; cat <<'EOF'; printf 'exec %s "$@"\n' "$real_bash"; } > "$tmp/shim/bash"
for a; do case "$a" in *\"*) echo "quote in argv: $a" >&2; exit 2 ;; esac; done
EOF
chmod +x "$tmp/shim/bash"
shim(){ printf '%s' "$1" | PATH="$tmp/shim:$PATH" CLAUDE_PROJECT_DIR="$2" "$H" 2>/dev/null \
        | python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.loads(s)["reason"] if s else "allow")' 2>/dev/null; }
spaced="$tmp/my project"; cp -R "$repo" "$spaced"
ev(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_response":{"bashEditDiff":{"changedFiles":sys.argv[2:]}}}))' "$@"; }
printf 'BAD(4)\n' > "$spaced/src/added.ts"
got=$(shim "$(ev "$spaced" "$spaced/src/added.ts")" "$spaced")
case "$got" in *"added BAD("*) echo "  ✓ a replayed guard judges the file, in a project path with spaces" ;;
               *) echo "  ✗ FAIL — replay did not judge the file: $got"; fail=1 ;; esac
printf 'kit content\n' > "$spaced/src/forbidden-kit.md"
sha=$(shasum -a 256 "$spaced/src/forbidden-kit.md" | cut -d' ' -f1)
printf '{"files":{"src/forbidden-kit.md":{"sha":"%s","mode":"owned"}}}' "$sha" > "$spaced/.claude/.kit-sync.json"
got=$(shim "$(ev "$spaced" "$spaced/src/forbidden-kit.md")" "$spaced")
if [ "$got" = allow ]; then echo "  ✓ a kit-delivered file is skipped, in a project path with spaces"
else echo "  ✗ FAIL — kit-delivered file not skipped: $got"; fail=1; fi

reason_of(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null \
             | python3 -c 'import json,sys; s=sys.stdin.read().strip(); print(json.loads(s)["reason"] if s else "allow")' 2>/dev/null; }
now(){ python3 -c 'import time; print(time.time())'; }
elapsed_under(){ python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < float(sys.argv[3]) else 1)' "$@"; }

echo "THE SHELL COMMAND RIDES ALONG as bash_command (a guard can tell a generator from a hand edit):"
printf 'ok\n' > "$repo/src/cmd.ts"
cmd_event(){ python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","session_id":"s","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]},"tool_response":{"bashEditDiff":{"changedFiles":[sys.argv[3]]}}}))' "$repo" "$1" "$2"; }
got=$(reason_of "$(cmd_event MARK-CMD "$repo/src/cmd.ts")")
case "$got" in *"saw bash_command"*) echo "  ✓ the replayed payload carries the Bash command" ;;
               *) echo "  ✗ FAIL — bash_command not passed to the replayed guard: $got"; fail=1 ;; esac
t allow "$(cmd_event 'other command' "$repo/src/cmd.ts")" 'a different command is passed through unchanged'
rm -f "$repo/src/cmd.ts"

echo "ONE BATCH, EACH FILE ON ITS OWN ADDED LINES:"
printf 'BAD(5)\nok\n' > "$repo/src/two.ts"; printf 'ok\n' > "$repo/src/three.ts"
git -C "$repo" add src/two.ts src/three.ts && git -C "$repo" commit -qm more
printf 'fine\n' >> "$repo/src/two.ts"
printf '++ BAD(6)\n' >> "$repo/src/three.ts"
got=$(reason_of "$(event "$repo/src/two.ts" "$repo/src/three.ts")")
case "$got" in *"src/three.ts"*) echo "  ✓ an added line that itself begins \"++ \" is judged" ;;
               *) echo "  ✗ FAIL — added \"++ \" line missed: $got"; fail=1 ;; esac
case "$got" in *"src/two.ts"*) echo "  ✗ FAIL — committed content of another file in the batch was judged"; fail=1 ;;
               *) echo "  ✓ committed content of another file in the same batch is not judged" ;; esac
mkdir -p "$repo/vendor/lib"; git -C "$repo/vendor/lib" init -q
git -C "$repo/vendor/lib" config user.email t@example.com && git -C "$repo/vendor/lib" config user.name t
printf 'BAD(7)\n' > "$repo/vendor/lib/x.ts"; git -C "$repo/vendor/lib" add -A && git -C "$repo/vendor/lib" commit -qm v
printf 'fine\n' >> "$repo/vendor/lib/x.ts"
t allow "$(event "$repo/vendor/lib/x.ts")" 'a file in a nested repository is judged on its own added lines'
printf 'BAD(8)\n' >> "$repo/vendor/lib/x.ts"
t block "$(event "$repo/vendor/lib/x.ts")" '…and a bad line added there is caught'
got=$(cd "$repo/vendor/lib" && verdict "$(event x.ts)")
[ "$got" = block ] && echo "  ✓ a bare file name is judged, not a crash" || { echo "  ✗ FAIL (got $got) — bare file name"; fail=1; }
got=$(cd "$repo" && verdict "$(event vendor/lib/x.ts)")
[ "$got" = block ] && echo "  ✓ a relative path into a nested repository is judged on its own added lines" || { echo "  ✗ FAIL (got $got) — relative path"; fail=1; }
rm -rf "$repo/vendor"

echo "PROCESS STARTS DO NOT GROW WITH THE FILE COUNT (each costs ~0.25s on Windows):"
mkdir -p "$tmp/count"; log="$tmp/count/log"
{ printf '#!%s\n' "$real_bash"; cat <<'EOF'; } > "$tmp/count/bash"
echo "bash ${1##*/}" >> "$COUNT_LOG"
exec "$REAL_BASH" "$@"
EOF
{ printf '#!%s\n' "$real_bash"; cat <<'EOF'; } > "$tmp/count/git"
echo git >> "$COUNT_LOG"
exec "$REAL_GIT" "$@"
EOF
chmod +x "$tmp/count/bash" "$tmp/count/git"
counted(){ : > "$log"; printf '%s' "$1" | COUNT_LOG="$log" REAL_BASH="$real_bash" REAL_GIT="$(command -v git)" \
           PATH="$tmp/count:$PATH" CLAUDE_PROJECT_DIR="$repo" "$H" >/dev/null 2>&1; }
many=(); entries=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'ok %s\n' "$i" > "$repo/src/many$i.ts"; many+=("$repo/src/many$i.ts")
  entries="$entries${entries:+,}\"src/many$i.ts\":\"$(shasum -a 256 "$repo/src/many$i.ts" | cut -d' ' -f1)\""
done
git -C "$repo" add src && git -C "$repo" commit -qm many
# A sync writes new content over tracked files and records it in the lockfile.
entries=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  printf 'synced\n' >> "$repo/src/many$i.ts"
  entries="$entries${entries:+,}\"src/many$i.ts\":\"$(shasum -a 256 "$repo/src/many$i.ts" | cut -d' ' -f1)\""
done
printf '{"files":{%s}}' "$entries" > "$lock"
counted "$(event "${many[@]}")"
k=$(grep -c "kit-delivered.sh" "$log"); g=$(grep -c "^git$" "$log"); b=$(grep -c "^bash " "$log")
if [ "$k" = 1 ] && [ "$g" = 2 ] && [ "$b" = 1 ]; then echo "  ✓ 10 synced files: two git runs, one kit-delivered.sh run, no guard run"
else echo "  ✗ FAIL — 10 synced files: $g git, $k kit-delivered.sh, $b bash runs"; fail=1; fi
rm -f "$lock"
counted "$(event "${many[@]}")"
g=$(grep -c "^git$" "$log")
if [ "$g" = 2 ]; then echo "  ✓ 10 tracked files: one git ls-files and one git diff"
else echo "  ✗ FAIL — 10 tracked files: $g git runs"; fail=1; fi

echo "GUARDS RUN SIDE BY SIDE, EACH ON ONE FILE AT A TIME:"
for g in one two; do
  cat > "$repo/.claude/hooks/lane-$g.sh" <<'EOF'
#!/bin/bash
d="$LANE_LOCKS/${0##*/}"
mkdir "$d" 2>/dev/null || { echo "two copies of ${0##*/} ran at once" >&2; exit 2; }
sleep 1; rmdir "$d"
EOF
  chmod +x "$repo/.claude/hooks/lane-$g.sh"
done
cat > "$repo/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[
  {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/lane-one.sh"},
  {"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/lane-two.sh"}]}]}}
EOF
mkdir -p "$tmp/locks"
printf 'ok\n' > "$repo/src/lane1.ts"; printf 'ok\n' > "$repo/src/lane2.ts"
t0=$(now)
got=$(printf '%s' "$(event "$repo/src/lane1.ts" "$repo/src/lane2.ts")" | LANE_LOCKS="$tmp/locks" CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null)
t1=$(now)
if [ -z "$got" ]; then echo "  ✓ no guard judged two files at once"; else echo "  ✗ FAIL — $got"; fail=1; fi
if elapsed_under "$t0" "$t1" 3.5; then echo "  ✓ two guards × two files of 1s each finish in about 2s, not 4s"
else echo "  ✗ FAIL — guards ran one after another"; fail=1; fi

echo "OUT OF TIME — the files not reached are named, never dropped in silence:"
cat > "$repo/.claude/settings.json" <<'EOF'
{"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/slow.sh"}]}],
 "PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/bash-edit-guard.sh","timeout":2}]}]}}
EOF
for i in 1 2 3; do printf 'ok\n' > "$repo/src/late$i.ts"; done
t0=$(now)
got=$(reason_of "$(event "$repo/src/late1.ts" "$repo/src/late2.ts" "$repo/src/late3.ts")")
t1=$(now)
case "$got" in *"src/late1.ts, src/late2.ts, src/late3.ts"*"ran out of time (1.5 seconds)"*) echo "  ✓ every file not finished is named as not checked" ;;
               *) echo "  ✗ FAIL — out-of-time files not reported: $got"; fail=1 ;; esac
if elapsed_under "$t0" "$t1" 3; then echo "  ✓ the budget comes from the hook's own timeout in settings.json (2s → stops at 1.5s)"
else echo "  ✗ FAIL — the run overran its own timeout"; fail=1; fi
cp "$tmp/settings.saved" "$repo/.claude/settings.json"

echo "FILES THE SAME AS HEAD ARE NOT JUDGED — git wrote them, or the command committed them:"
printf 'x\n' > "$repo/src/forbidden-pulled.ts"; printf 'BAD(9)\n' > "$repo/src/pulled.ts"
git -C "$repo" add src && git -C "$repo" commit -qm pulled
t allow "$(event "$repo/src/forbidden-pulled.ts" "$repo/src/pulled.ts")" 'committed files unchanged on disk (a pull, a rebase, a commit in the command)'
t allow "$(event "$repo/src/gone-before-and-after.ts")" 'a path in neither HEAD nor the working tree (a pull removed it)'
git -C "$repo" rm -q src/forbidden-pulled.ts
t block "$(event "$repo/src/forbidden-pulled.ts")" 'a tracked file removed by the command is still judged'
git -C "$repo" add src && git -C "$repo" commit -qm removed
many_same=()
for i in $(seq 1 60); do printf 'x\n' > "$repo/src/forbidden-bulk$i.ts"; many_same+=("$repo/src/forbidden-bulk$i.ts"); done
git -C "$repo" add src && git -C "$repo" commit -qm bulk
counted "$(event "${many_same[@]}")"
g=$(grep -c "^git$" "$log"); b=$(grep -c "^bash " "$log")
if [ "$g" = 2 ] && [ "$b" = 0 ]; then echo "  ✓ 60 pulled files: two git runs, no guard run, nothing over the file cap"
else echo "  ✗ FAIL — 60 pulled files: $g git runs, $b bash runs"; fail=1; fi

echo "OVER THE FILE CAP — the files past it are named:"
over=()
for i in $(seq 1 41); do printf 'ok\n' > "$repo/src/cap$i.ts"; over+=("$repo/src/cap$i.ts"); done
got=$(reason_of "$(event "${over[@]}")")
case "$got" in *"src/cap41.ts"*"at most 40 changed files"*) echo "  ✓ the 41st file is named as not checked" ;;
               *) echo "  ✗ FAIL — cap not reported by name: $got"; fail=1 ;; esac
rm -f "$repo"/src/cap*.ts

echo "TOOL MISSING — python3 that does not run is reported, never a silent pass:"
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"
assert_refuses_without "$H" block "$(path_with_store_python)" python3 "$(event "$repo/src/forbidden.ts")" 'python3 is the Windows Store stub'
assert_refuses_without "$H" block "$(path_without python3)" python3 "$(event "$repo/src/forbidden.ts")" 'no python3 on PATH'

echo "DEGENERATE INPUT:"
for p in '' 'not json' 'null' '[]' '{"tool_response":null}' '{"tool_response":{"bashEditDiff":{"changedFiles":"x"}}}' '{"tool_response":{"bashEditDiff":{"changedFiles":[null,3]}}}'; do
  out=$(run "$p"); rc=$?
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "  ✓ exits clean: ${p:-<empty>}"
  else echo "  ✗ FAIL (rc=$rc out=$out) — ${p:-<empty>}"; fail=1; fi
done
out=$(printf '%s' "$(event "$repo/src/forbidden.ts")" | CLAUDE_PROJECT_DIR="$tmp/nowhere" "$H" 2>/dev/null); rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then echo "  ✓ exits clean with no settings.json"; else echo "  ✗ FAIL — missing settings.json"; fail=1; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
