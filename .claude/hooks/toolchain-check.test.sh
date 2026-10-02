#!/usr/bin/env bash
# Regression suite for toolchain-check.sh — the session-start check that says so when
# the guards cannot run, when /commit cannot typecheck, and (on Windows) refreshes
# files whose only difference from Git is CRLF line endings.
#
# The Windows branch is driven by sourcing the script and setting OSTYPE, which is how
# guard-lib.sh decides the platform; the line-ending work runs against a temp repo.
set -uo pipefail
H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/toolchain-check.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp/markers"; mkdir -p "$TMPDIR"
# shellcheck source=test-helpers.sh
source "$(dirname "$H")/test-helpers.sh"

ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ FAIL — $1"; fail=1; }
# Runs the hook in <dir> with <PATH>; prints "<systemMessage>\n---\n<additionalContext>",
# "SILENT" for no output, or "MALFORMED".
run(){ printf '{}' | CLAUDE_PROJECT_DIR="$1" PATH="$2" "$H" 2>/dev/null | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw: print("SILENT"); raise SystemExit
try: d = json.loads(raw)
except Exception: print("MALFORMED"); raise SystemExit
print(d.get("systemMessage", "") + "\n---\n" + ((d.get("hookSpecificOutput") or {}).get("additionalContext") or ""))
'; }
has(){ case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 — output: $2" ;; esac; }

mkdir -p "$tmp/empty" "$tmp/ts-ok" "$tmp/ts-bad" "$tmp/py" "$tmp/pyconf"
printf '{"scripts":{"check-types":"tsc --noEmit"}}' > "$tmp/ts-ok/package.json"
printf '{"scripts":{"build":"vite build"}}'         > "$tmp/ts-bad/package.json"
printf '[project]\nname = "x"\n'                    > "$tmp/py/pyproject.toml"
printf '{}'                                        > "$tmp/pyconf/pyrightconfig.json"

echo "SILENT when everything is in place:"
[ "$(run "$tmp/empty" "$PATH")" = SILENT ] && ok 'tools present, no manifests' || bad 'spoke with nothing to say'
[ "$(run "$tmp/ts-ok" "$PATH")" = SILENT ] && ok 'package.json with check-types' || bad 'warned about a check-types script that exists'

echo "TOOLS — a tool that does not run is named, with its install line and the restart:"
out=$(run "$tmp/empty" "$(path_without jq)")
has 'jq is missing'            "$out" 'names jq'
has 'brew install jq'          "$out" 'gives the macOS install line'
has 'restart Claude Code'      "$out" 'says to restart Claude Code'
has 'Tell the human'           "$out" 'tells Claude to tell the human'
out=$(run "$tmp/empty" "$(path_with_store_python)")
has 'python3 is missing'       "$out" 'names python3 when it is the Windows Store stub'
[ "$(run "$tmp/empty" "$(path_without jq)")" != MALFORMED ] && ok 'output is valid JSON' || bad 'malformed JSON'

echo "TYPECHECK — what the commit gate needs:"
out=$(run "$tmp/ts-bad" "$PATH")
has 'no "check-types" script'  "$out" 'package.json without check-types'
out=$(run "$tmp/py" "$(path_without pyright mypy)")
has 'neither pyright nor mypy' "$out" 'pyproject.toml without pyright or mypy'
mkdir -p "$tmp/fakepy"; printf '#!/bin/sh\nexit 0\n' > "$tmp/fakepy/mypy"; chmod +x "$tmp/fakepy/mypy"
[ "$(run "$tmp/py" "$tmp/fakepy:$(path_without pyright mypy)")" = SILENT ] && ok 'pyproject.toml with mypy on PATH' || bad 'warned with mypy present'
out=$(run "$tmp/pyconf" "$(path_without pyright mypy)")
has 'neither pyright nor mypy' "$out" 'pyrightconfig.json alone without pyright or mypy'
printf '#!/bin/sh\nexit 0\n' > "$tmp/fakepy/pyright"; chmod +x "$tmp/fakepy/pyright"
[ "$(run "$tmp/pyconf" "$tmp/fakepy:$(path_without pyright mypy)")" = SILENT ] && ok 'pyrightconfig.json with pyright on PATH' || bad 'warned with pyright present'

echo "MARKERS — each session's guards re-check the tools:"
: > "$TMPDIR/kit-toolchain-ok-${UID:-0}-123"
run "$tmp/empty" "$PATH" >/dev/null
ls "$TMPDIR"/kit-toolchain-ok-* >/dev/null 2>&1 && bad 'stale marker survived session start' || ok 'session start clears the passing-check markers'

echo "LINE ENDINGS — a temp repo with every case:"
repo="$tmp/repo"; mkdir -p "$repo/sp ace"
git -C "$repo" init -q; git -C "$repo" config user.email t@example.com; git -C "$repo" config user.name t
printf '* text=auto eol=lf\n*.bat text eol=crlf\n' > "$repo/.gitattributes"
printf 'a\nb\n' > "$repo/same.txt"; printf 'a\nb\n' > "$repo/edited.txt"; printf 'x\n' > "$repo/lf.txt"
printf 'echo\n' > "$repo/run.bat"; printf 'q\n' > "$repo/sp ace/f \"q\".txt"
git -C "$repo" add -A 2>/dev/null; git -C "$repo" commit -qm init
printf 'a\r\nb\r\n' > "$repo/same.txt"; printf 'a\r\nB\r\n' > "$repo/edited.txt"; printf 'q\r\n' > "$repo/sp ace/f \"q\".txt"
crlf(){ LC_ALL=C grep -c $'\r' "$1" 2>/dev/null || true; }

line=$(bash -c 'source "$0"; refresh_line_endings "$1"' "$H" "$repo")
[ "$(crlf "$repo/same.txt")" = 0 ]          && ok 'CRLF-only file rewritten to LF'          || bad 'CRLF-only file not rewritten'
[ "$(crlf "$repo/sp ace/f \"q\".txt")" = 0 ] && ok 'a path with a space and quotes too'      || bad 'quoted path not rewritten'
[ "$(crlf "$repo/edited.txt")" = 2 ]        && ok 'file with real edits left untouched'     || bad 'edited file was rewritten'
has '2 file(s) rewritten'                   "$line" 'summary counts the rewritten files'
has '1 file(s) CRLF with real edits, not refreshed: edited.txt' "$line" 'summary lists the file with real edits'
[ -z "$(git -C "$repo" diff --name-only -- same.txt 2>/dev/null)" ] && ok 'rewritten file matches the index' || bad 'rewritten file differs from the index'
marker="$repo/.git/kit-eol-checked"
[ "$(cat "$marker" 2>/dev/null)" = "$(git -C "$repo" hash-object .gitattributes)" ] && ok 'marker holds the .gitattributes hash' || bad 'marker missing or wrong'

printf 'a\r\nb\r\n' > "$repo/same.txt"
line=$(bash -c 'source "$0"; refresh_line_endings "$1"' "$H" "$repo")
[ -z "$line" ] && [ "$(crlf "$repo/same.txt")" = 2 ] && ok 'same .gitattributes: nothing rescanned' || bad 'rescanned without a .gitattributes change'
printf '* text=auto eol=lf\n*.bat text eol=crlf\n*.cmd text eol=crlf\n' > "$repo/.gitattributes"
line=$(bash -c 'source "$0"; refresh_line_endings "$1"' "$H" "$repo")
[ "$(crlf "$repo/same.txt")" = 0 ] && ok '.gitattributes changed: rescanned and refreshed' || bad 'no rescan after .gitattributes changed'

echo "PLATFORM — the refresh runs on Windows only:"
printf 'a\r\nb\r\n' > "$repo/same.txt"; rm -f "$marker"
out=$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" "$H" 2>/dev/null)
[ -z "$out" ] && [ "$(crlf "$repo/same.txt")" = 2 ] && ok 'macOS/Linux: no refresh, no output' || bad 'refresh ran off Windows'
out=$(printf '{}' | CLAUDE_PROJECT_DIR="$repo" bash -c 'source "$0"; OSTYPE=msys; main' "$H" 2>/dev/null)
[ "$(crlf "$repo/same.txt")" = 0 ] && ok 'Windows: refreshed at session start' || bad 'Windows session did not refresh'
has 'Line endings checked' "$(printf '%s' "$out" | python3 -c 'import json,sys;print(json.load(sys.stdin)["systemMessage"])' 2>/dev/null)" 'Windows: the summary reaches the human'

echo "DEGENERATE — no git repo, no .gitattributes:"
line=$(bash -c 'source "$0"; refresh_line_endings "$1"' "$H" "$tmp/empty"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$line" ] && ok 'no .gitattributes: nothing to do' || bad 'no .gitattributes'
printf '* text=auto eol=lf\n' > "$tmp/empty/.gitattributes"
line=$(bash -c 'source "$0"; refresh_line_endings "$1"' "$H" "$tmp/empty"); rc=$?
[ "$rc" -eq 0 ] && [ -z "$line" ] && ok 'not a git repo: nothing to do' || bad 'not a git repo'

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
