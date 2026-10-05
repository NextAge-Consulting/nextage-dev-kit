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

# Pre guard: denies any file whose path contains "forbidden", and any new_string with "BAD(".
cat > "$repo/.claude/hooks/pre.sh" <<'EOF'
#!/bin/bash
python3 -c '
import json,sys
d=json.load(sys.stdin); ti=d["tool_input"]
why = "path is forbidden" if "forbidden" in ti["file_path"] else ("added BAD(" if "BAD(" in ti["new_string"] else "")
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
