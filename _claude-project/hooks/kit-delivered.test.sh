#!/usr/bin/env bash
# Regression suite for kit-delivered.sh — every doubt must answer "not delivered", so
# the caller still judges the file.
set -uo pipefail
# shellcheck source=kit-delivered.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-delivered.sh"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# shellcheck source=test-helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-helpers.sh"
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
printf '{"files":{".claude/rules/a.md":{"sha":"%s","mode":"owned"}}}' "$sha" > "$lock"
phys=$(cd "$root" && pwd -P)
t yes "${phys//\//\\}\\.claude\\rules\\a.md" 'Windows backslash path'
t yes "$root/.claude/./rules/a.md" 'dot segment in the path'
ln -s "$root" "$tmp/proj-link"
t yes "$tmp/proj-link/.claude/rules/a.md" 'file named through a symlinked root'
if is_kit_delivered "$tmp/proj-link" "$f"; then echo "  ✓ root given as the symlink, file as the target"
else echo "  ✗ FAIL — symlinked root, target path"; fail=1; fi

echo "BATCH — one call answers for every path, each as given, in order:"
g="$root/.claude/rules/b c.md"; printf 'other\n' > "$g"
gsha=$(shasum -a 256 "$g" | awk '{print $1}')
e="$root/.claude/rules/edited.md"; printf 'edited\n' > "$e"
printf '{"files":{".claude/rules/a.md":{"sha":"%s"},".claude/rules/b c.md":"%s",".claude/rules/edited.md":{"sha":"%s"}}}' "$sha" "$gsha" "$sha" > "$lock"
want=$(printf '%s\n' "$g" ".claude/rules/a.md")
got=$(kit_delivered_among "$root" "$e" "$g" "$root/nope.md" ".claude/rules/a.md")
if [ "$got" = "$want" ]; then echo "  ✓ delivered paths only, as given, in order"
else echo "  ✗ FAIL (got '$got') — batch"; fail=1; fi
got=$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-delivered.sh" "$root" "$e" "$g" "$root/nope.md" ".claude/rules/a.md")
if [ "$got" = "$want" ]; then echo "  ✓ run directly, it prints the same"
else echo "  ✗ FAIL (got '$got') — direct run"; fail=1; fi
got=$(kit_delivered_among "$root" "$e" "$root/nope.md")
if [ -z "$got" ]; then echo "  ✓ none delivered prints nothing"
else echo "  ✗ FAIL (got '$got') — none delivered"; fail=1; fi
KD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-delivered.sh"
if bash "$KD" "$root" "$g" >/dev/null; then echo "  ✓ run directly on a delivered path, it exits 0"
else echo "  ✗ FAIL — direct run, delivered path, non-zero exit"; fail=1; fi
if bash "$KD" "$root" "$e" >/dev/null; then echo "  ✗ FAIL — direct run, nothing delivered, exit 0"; fail=1
else echo "  ✓ run directly with nothing delivered, it exits 1"; fi
rm -f "$g" "$e"

echo "HASHING — shasum stands in where sha256sum is missing:"
nosha=$(path_without sha256sum)
if PATH="$nosha" bash -c 'source "$0"; is_kit_delivered "$1" "$2"' \
     "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/kit-delivered.sh" "$root" "$f"; then
  echo "  ✓ delivered file recognised without sha256sum"
else echo "  ✗ FAIL — no sha256sum broke the check"; fail=1; fi

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
t no "/elsewhere/.claude/rules/a.md" 'absolute path outside the root'
if is_kit_delivered "" "$f"; then echo "  ✗ FAIL — empty root answered delivered"; fail=1; else echo "  ✓ empty root"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
