#!/usr/bin/env bash
# Regression suite for code-fingerprint.mjs — one hash for the code of a tree, the same
# whenever only comments and whitespace changed, different whenever anything a check
# can see changed.
#
# Needs node, and TypeScript installed globally or in the repository; without
# TypeScript, the cases that read code are reported and skipped, and the raw fallback
# is tested on its own.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$D/code-fingerprint.mjs"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ FAIL — $1"; fail=1; }

if ! command -v node >/dev/null 2>&1; then
  echo "code-fingerprint: node is not installed — cannot run this suite." >&2
  exit 1
fi

repo="$tmp/r"; mkdir -p "$repo"; cd "$repo" || exit 1
git init -q; git config user.email t@example.com; git config user.name t

fp(){ node "$FP" "$@" 2>"$tmp/err"; }
# same <label> — the working tree's fingerprint equals $before
same(){ local now; now=$(fp); if [ -n "$now" ] && [ "$now" = "$before" ]; then ok "$1"; else bad "$1 (was $before, now $now)"; fi; }
differs(){ local now; now=$(fp); if [ -n "$now" ] && [ "$now" != "$before" ]; then ok "$1"; else bad "$1 (both $now)"; fi; }

has_ts=1
if ! node -e 'require(require("child_process").execSync("npm root -g").toString().trim() + "/typescript")' 2>/dev/null; then
  has_ts=0
fi

cat > a.ts <<'EOF'
// A leading comment.
/** Doc for f. */
export function f(x: number): string {
  /* inline */ return `${x}://host/` + "s"; // trailing
}
const re = /[//]/;
export const g = (y: number) => y + 1;
EOF
cat > b.tsx <<'EOF'
export const C = () => (
  <div>
    hello   world
    {/* a comment in JSX */}
  </div>
);
EOF
printf 'notes\n' > readme.md

echo "basics:"
before=$(fp)
if [[ "$before" =~ ^[0-9a-f]{32}$ ]]; then ok "prints a 32-character hex fingerprint"; else bad "fingerprint shape: '$before'"; fi
if grep -qE '3 file\(s\)' "$tmp/err"; then ok "says how many files it read"; else bad "count missing: $(cat "$tmp/err")"; fi
git add -A; git commit -qm init
c=$(fp --commit HEAD)
if [ "$c" = "$before" ]; then ok "a commit and a checkout of it have the same fingerprint"; else bad "commit $c vs tree $before"; fi
if [ -z "$(git status --porcelain)" ]; then ok "reads the tree without changing it"; else bad "the tree changed"; fi

if [ "$has_ts" -eq 1 ]; then
  echo "comments and whitespace:"
  cat > a.ts <<'EOF'
export function f(x: number): string { return `${x}://host/` + "s"; }
// a different comment
const re = /[//]/;
export const g = (y: number) =>
    y + 1;
EOF
  same "identical code with different comments and whitespace has the same fingerprint"
  cat > b.tsx <<'EOF'
export const C = () => (
  <div>
        hello   world
    {/* another comment */}
  </div>
);
EOF
  same "JSX text re-indented, a JSX comment reworded: same"
  git checkout -q -- a.ts b.tsx

  echo "code changes:"
  sed -i.bak 's#"s"#"t"#' a.ts; rm -f a.ts.bak
  differs "a string literal change changes it"
  git checkout -q -- a.ts
  sed -i.bak 's#://host/#://other/#' a.ts; rm -f a.ts.bak
  differs "a change inside a template after an interpolation changes it"
  git checkout -q -- a.ts
  sed -i.bak 's#\[//\]#[/x/]#' a.ts; rm -f a.ts.bak
  differs "a change inside a regular expression changes it"
  git checkout -q -- a.ts
  sed -i.bak 's#hello   world#hello world#' b.tsx; rm -f b.tsx.bak
  differs "spaces inside a line of JSX text count"
  git checkout -q -- b.tsx
  printf 'export function h() {\n  return 1;\n}\n' > c.ts; git add c.ts; git commit -qm c; before=$(fp)
  printf 'export function h() {\n  return\n  1;\n}\n' > c.ts
  differs "a line break that changes the parse (return, then a newline) changes it"
  git checkout -q -- c.ts

  echo "directives:"
  printf 'export const v: number = 1;\n' > d.ts; git add d.ts; git commit -qm d; before=$(fp)
  for directive in '// @ts-ignore' '// @ts-expect-error' '// biome-ignore lint/x: reason' '// eslint-disable-next-line' \
                   '// nosemgrep' '/* @vite-ignore */' '/* webpackChunkName: "x" */' '/*#__PURE__*/' '/* @__PURE__ */' \
                   '/** @license MIT */' '/*! legal */' '/// <reference types="node" />' '/** @jsxImportSource preact */' \
                   '// prettier-ignore' '/* c8 ignore next */' '/* istanbul ignore next */' '// @vitest-environment jsdom'; do
    printf '%s\nexport const v: number = 1;\n' "$directive" > d.ts
    differs "adding $directive changes it"
  done
  printf '// @ts-ignore\nexport const v: number = 1;\n' > d.ts; git add d.ts; git commit -qm d2; before=$(fp)
  printf '// @ts-ignore\n\nexport const v: number = 1;\n' > d.ts
  differs "moving code a line away from a line-scoped directive changes it"
  printf '// @ts-expect-error\nexport const v: number = 1;\n' > d.ts
  differs "changing a directive's text changes it"
  printf '// @ts-ignore\nexport   const v :number=1;\n' > d.ts
  same "whitespace within the line a directive covers does not"
  git checkout -q -- d.ts

  echo "JavaScript:"
  printf '/** @type {number} */\nexport const n = 1;\n' > e.js; git add e.js; git commit -qm e; before=$(fp)
  printf '/** @type {string} */\nexport const n = 1;\n' > e.js
  differs "a JSDoc type in a JavaScript file counts — it carries types there"
  printf '/** @type {number} */\n// just a note\nexport const   n = 1;\n' > e.js
  same "a plain comment and spacing in a JavaScript file do not"
  git checkout -q -- e.js

  echo "unparseable code:"
  printf 'export const = = ;\n' > f.ts; git add f.ts; git commit -qm f; before=$(fp)
  printf 'export const = = ; // note\n' > f.ts
  differs "a file the parser cannot read is hashed byte for byte"
  if grep -q 'could not read cleanly' "$tmp/err"; then ok "…and says so"; else bad "no note: $(cat "$tmp/err")"; fi
  git checkout -q -- f.ts
else
  echo "TypeScript is not installed globally — the code-reading cases are skipped." >&2
fi

echo "other files:"
before=$(fp)
printf 'notes, changed\n' > readme.md
differs "a non-code file change changes it"
git checkout -q -- readme.md
printf 'new\n' > new.txt
differs "an untracked, unignored file counts"
printf 'new.txt\n' > .gitignore; git add .gitignore; git commit -qm ignore; before=$(fp)
printf 'other\n' > new.txt
same "an ignored file does not"
git mv readme.md README.md
differs "a rename changes it"
git mv README.md readme.md
git rm -q --cached readme.md; rm -f readme.md
differs "a deleted file changes it"
git checkout -q HEAD -- readme.md

echo "without TypeScript:"
before=$(fp)
# A PATH without npm, and a repository without typescript, so neither lookup finds it.
nonpm="$tmp/nonpm"; mkdir -p "$nonpm"; ln -s "$(command -v node)" "$nonpm/node"; ln -s "$(command -v git)" "$nonpm/git"
raw_fp=$(PATH="$nonpm" node "$FP" 2>"$tmp/err")
if [[ "$raw_fp" =~ ^[0-9a-f]{32}$ ]] && [ "$raw_fp" != "$before" ]; then ok "every file is hashed byte for byte, a different fingerprint"; else bad "raw fallback: '$raw_fp'"; fi
if grep -q 'TypeScript could not be loaded' "$tmp/err"; then ok "…and says so"; else bad "no note: $(cat "$tmp/err")"; fi
printf '%s\n// a new comment\n' "$(cat a.ts)" > a.ts
raw2=$(PATH="$nonpm" node "$FP" 2>/dev/null)
if [ "$raw2" != "$raw_fp" ]; then ok "…so a comment change is a change"; else bad "comment change skipped without TypeScript"; fi
git checkout -q -- a.ts

echo "the full-suite status:"
t_ctx=$(node "$FP" --status-context)
[ "$t_ctx" = "full-suite" ] && ok "the status is named full-suite" || bad "context: $t_ctx"
desc=$(node "$FP" --status-description "$before")
[ "$desc" = "fp $before" ] && ok "a pass is described as 'fp <fingerprint>'" || bad "description: $desc"
desc2=$(node "$FP" --status-description "$before" --from abc123)
[ "$desc2" = "carried forward from abc123 · fp $before" ] && ok "a carried-forward pass names the commit it came from" || bad "description: $desc2"
[ "$(node "$FP" --status-fp "$desc2")" = "$before" ] && ok "the fingerprint reads back from a description" || bad "read back"
if node "$FP" --status-fp "something else" >/dev/null; then bad "a description without a fingerprint read as one"; else ok "a description without one reads as none"; fi

echo "refusals:"
empty="$tmp/empty"; mkdir -p "$empty"; git -C "$empty" init -q
if node "$FP" -C "$empty" >/dev/null 2>"$tmp/err"; then bad "an empty tree passed"; else ok "an empty tree fails, saying there is nothing to fingerprint"; fi
if node "$FP" --commit nosuchrev >/dev/null 2>"$tmp/err"; then bad "a bad revision passed"; else ok "an unknown revision fails"; fi

exit "$fail"
