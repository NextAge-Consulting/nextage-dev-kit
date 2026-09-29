#!/usr/bin/env bash
# Regression suite for kit-delivered.sh — every doubt must answer "not delivered", so
# the caller still judges the file.
set -uo pipefail
# shellcheck source=kit-delivered.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-delivered.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
root="$tmp/proj"; mkdir -p "$root/.claude/rules"
f="$root/.claude/rules/a.md"; printf 'kit content\n' > "$f"
sha=$(shasum -a 256 "$f" | awk '{print $1}')
lock="$root/.claude/.kit-sync.json"
t(){ if is_kit_delivered "$root" "$2"; then got=yes; else got=no; fi
     if [ "$got" = "$1" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got $got, want $1) — $3"; fail=1; fi; }

echo "DELIVERED:"
printf '{"files":{".claude/rules/a.md":{"sha":"%s","mode":"owned"}}}' "$sha" > "$lock"
t yes "$f"                  'absolute path, matching entry'
t yes ".claude/rules/a.md"  'relative path, matching entry'
printf '{"files":{".claude/rules/a.md":"%s"}}' "$sha" > "$lock"
t yes "$f"                  'legacy bare-string entry'

echo "NOT DELIVERED — every doubt:"
printf '{"files":{".claude/rules/a.md":{"sha":"%s","mode":"owned"}}}' "$sha" > "$lock"
printf 'edited\n' >> "$f"
t no "$f"                   'content changed after delivery'
printf 'kit content\n' > "$f"
printf '{"files":{}}' > "$lock"
t no "$f"                   'no entry for the file'
printf '{"files":{".claude/rules/a.md":{"mode":"owned"}}}' > "$lock"
t no "$f"                   'entry without a sha'
printf 'not json' > "$lock"
t no "$f"                   'unreadable lockfile'
rm -f "$lock"
t no "$f"                   'no lockfile'
printf '{"files":{".claude/rules/gone.md":{"sha":"x"}}}' > "$lock"
t no "$root/.claude/rules/gone.md" 'file does not exist'
t no ""                     'empty path'
if is_kit_delivered "" "$f"; then echo "  ✗ FAIL — empty root answered delivered"; fail=1; else echo "  ✓ empty root"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
