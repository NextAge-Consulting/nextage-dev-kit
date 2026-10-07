#!/usr/bin/env bash
# Regression suite for gates.sh — the typecheck, biome, knip, semgrep and build gates
# /commit, /ship-main and /merge run.
#
# The contract under test: every gate passes, fails, or says why it does not
# apply, and a gate that cannot run fails. Each case runs in a throwaway git repo
# with PATH pinned to a sandbox, so "is the tool installed" is decided here and
# not by the machine running the suite. npm, pyright, mypy and semgrep are stubs
# that record how they were called; the build gate uses the real npm, because
# what it counts is npm's own answer about workspaces.
set -uo pipefail
D="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

t(){ # t <want> <got> <label>
  if [ "$1" = "$2" ]; then echo "  ✓ $3"; else echo "  ✗ FAIL (got '$2', want '$1') — $3"; fail=1; fi; }
has(){ # has <pattern> <label> — the last gate's stderr contains the pattern
  if grep -qF -- "$1" "$tmp/err"; then echo "  ✓ $2"; else echo "  ✗ FAIL — $2; stderr was: $(cat "$tmp/err")"; fail=1; fi; }

# The sandbox: only the tools the gates need, so a missing checker is really missing.
SANDBOX="$tmp/sandbox"; mkdir -p "$SANDBOX"
for tool in bash git jq sed sort mktemp rm grep tr tail head cat dirname env; do
  ln -s "$(command -v "$tool")" "$SANDBOX/$tool"
done
STUBS="$tmp/stubs"; mkdir -p "$STUBS"
stub(){ # stub <name> <exit code> — records its argv, one argument per line
  printf '#!/bin/bash\nprintf "%%s\\n" "$@" > "%s/%s.args"\n%s\nexit %s\n' "$tmp" "$1" "${3:-}" "$2" > "$STUBS/$1"
  chmod +x "$STUBS/$1"; }
unstub(){ rm -f "$STUBS/$1" "$tmp/$1.args"; }

new_repo(){
  repo="$tmp/r$RANDOM"; mkdir -p "$repo"; cd "$repo" || exit 1
  git init -q; git config user.email t@example.com; git config user.name t
  printf 'x\n' > base.txt; git add -A; git commit -qm init
  BASE=$(git rev-parse HEAD)
  rm -f "$STUBS"/*
}
gate(){ # gate <function> <args…> — runs it under the sandbox PATH; echoes the exit code
  ( PATH="$STUBS:$SANDBOX"; source "$D/gates.sh"; "$@" ) 2>"$tmp/err"; echo $?; }

echo "typecheck:"
new_repo
t 0 "$(gate run_typecheck_gate 1 committing)" '--skip-typecheck passes'
has 'typecheck: skipped — --skip-typecheck was passed' '…and says it skipped'
t 0 "$(gate run_typecheck_gate 0 committing)" 'no package.json, pyproject.toml or pyrightconfig.json passes'
has 'typecheck: skipped — no package.json, pyproject.toml or pyrightconfig.json' '…and says why'

printf '{"name":"app","scripts":{"build":"x"}}\n' > package.json
stub npm 0
t 0 "$(gate run_typecheck_gate 0 committing)" 'package.json without check-types and no TypeScript sources passes'
has 'check-types does not apply: no TypeScript sources' '…and says why'
mkdir -p node_modules/x .claude dist
touch knip.config.ts node_modules/x/a.ts .claude/a.ts dist/a.d.ts
t 0 "$(gate run_typecheck_gate 0 committing)" '…the kit'"'"'s knip.config.ts and files under node_modules, .claude and dist are not sources'
mkdir -p src; touch src/app.mts
t 4 "$(gate run_typecheck_gate 0 committing)" 'package.json without check-types and a TypeScript source fails — CI runs it'
has 'no "check-types" script' '…naming the missing script'
rm -rf src node_modules .claude dist knip.config.ts
mkdir -p web; touch web/page.tsx
printf '{"name":"app","description":"\\"check-types\\" lives elsewhere"}\n' > package.json
t 4 "$(gate run_typecheck_gate 0 committing)" 'the words "check-types" outside scripts do not count as the script'
rm -rf web
printf '{"name":"app","scripts":{"check-types":"tsc --checkJs"}}\n' > package.json
t 0 "$(gate run_typecheck_gate 0 committing)" 'a declared check-types runs without TypeScript sources'
t "run check-types" "$(tr '\n' ' ' < "$tmp/npm.args" | sed 's/ $//')" '…by running npm run check-types'
printf '{"name":"app","scripts":{"check-types":"tsc --noEmit"}}\n' > package.json
t 0 "$(gate run_typecheck_gate 0 committing)" 'check-types passing passes'
t "run check-types" "$(tr '\n' ' ' < "$tmp/npm.args" | sed 's/ $//')" '…by running npm run check-types'
stub npm 1
t 4 "$(gate run_typecheck_gate 0 "shipping to main")" 'check-types failing fails'
has 'Fix before shipping to main.' '…with the caller'"'"'s action'
printf '{' > package.json
t 4 "$(gate run_typecheck_gate 0 committing)" 'an unreadable package.json fails'
rm package.json

touch pyproject.toml
t 4 "$(gate run_typecheck_gate 0 committing)" 'pyproject.toml with neither pyright nor mypy fails'
has 'neither pyright nor mypy is installed' '…naming both'
has 'npm install -g pyright' '…with the install line'
stub mypy 0
t 0 "$(gate run_typecheck_gate 0 committing)" 'mypy alone runs and passes'
stub pyright 1
t 4 "$(gate run_typecheck_gate 0 committing)" 'pyright is preferred over mypy, and its errors fail'
unstub pyright; unstub mypy
printf '{"name":"app","scripts":{"check-types":"tsc"}}\n' > package.json
stub npm 0; stub pyright 1
t 4 "$(gate run_typecheck_gate 0 committing)" 'a repo with both checks both: Python errors fail after TypeScript passes'
rm package.json pyproject.toml

printf '{}\n' > pyrightconfig.json
unstub npm; unstub pyright
t 4 "$(gate run_typecheck_gate 0 committing)" 'pyrightconfig.json alone, with neither checker, fails'
has 'neither pyright nor mypy is installed' '…naming both'
stub pyright 0
t 0 "$(gate run_typecheck_gate 0 committing)" 'pyrightconfig.json alone runs pyright'
has 'running pyright' '…and says so'
stub pyright 1
t 4 "$(gate run_typecheck_gate 0 committing)" '…and its errors fail'
mkdir -p .claude
printf '{"packages":{"pyright":{"version":"1.1.409"}}}\n' > .claude/stack-manifest.json
stub pyright 0 '[ "${1:-}" = --version ] && echo "pyright 1.1.400"'
t 0 "$(gate run_typecheck_gate 0 committing)" 'an installed pyright off the manifest pin still runs and passes'
has 'pyright 1.1.400 is installed, but the stack manifest pins 1.1.409' '…warning with both versions'
stub pyright 0 '[ "${1:-}" = --version ] && echo "pyright 1.1.409"'
t 0 "$(gate run_typecheck_gate 0 committing)" 'the pinned pyright passes'
if grep -q 'warning' "$tmp/err"; then t 'no warning' 'warned' '…without a warning'; else t x x '…without a warning'; fi
unstub pyright; rm -rf pyrightconfig.json .claude

echo "biome:"
new_repo
t 0 "$(gate run_biome_gate committing)" 'no biome.json passes'
has 'biome: skipped' '…and says why'
printf '{"name":"app"}\n' > package.json
printf '{"$schema":"./node_modules/@biomejs/biome/configuration_schema.json","extends":["./biome.base.json"]}\n' > biome.json
printf '{\n  "$schema": "https://biomejs.dev/schemas/2.3.4/schema.json"\n}\n' > biome.base.json
stub npx 1
t 4 "$(gate run_biome_gate committing)" 'biome.json present, @biomejs/biome not installed: fails'
has 'npm i -D @biomejs/biome@2.3.4' '…with the version biome.base.json pins'
rm biome.base.json
printf '{"$schema":"https://biomejs.dev/schemas/2.1.0/schema.json"}\n' > biome.json
t 4 "$(gate run_biome_gate committing)" 'a project not yet split: still fails'
has 'npm i -D @biomejs/biome@2.1.0' '…with the version biome.json pins'
printf '{"$schema":"./node_modules/@biomejs/biome/configuration_schema.json"}\n' > biome.json
t 4 "$(gate run_biome_gate committing)" 'no pinned version anywhere: still fails'
has "<the version biome.base.json's" '…naming where the version belongs'
stub npx 0
t 0 "$(gate run_biome_gate committing)" 'biome installed and lint clean: passes'
rm biome.json package.json

echo "knip:"
new_repo
t 0 "$(gate run_knip_gate committing)" 'no package.json passes'
has 'knip: skipped — no root package.json' '…and says why'
printf '{"name":"app"}\n' > package.json
t 0 "$(gate run_knip_gate committing)" 'KNIP_GATE unset passes, as CI does'
has 'KNIP_GATE is not "true"' '…and says why'
mkdir -p .claude
printf '{"KNIP_GATE":"true"}\n' > .claude/sync-substitutions.json
t 4 "$(gate run_knip_gate committing)" 'KNIP_GATE on with no pinned version fails'
has 'pins no knip version' '…naming what is missing'
printf '{"packages":{"knip":{"version":"5.88.1"}}}\n' > .claude/stack-manifest.json
stub npx 1
t 4 "$(gate run_knip_gate committing)" 'a knip finding fails'
has 'knip found unused code' '…and says so'
t knip@5.88.1 "$(sed -n 2p "$tmp/npx.args")" '…running the manifest-pinned version'
stub npx 2
t 4 "$(gate run_knip_gate committing)" 'knip unable to run fails'
has 'knip could not run (exit 2)' '…and says so'
stub npx 0
t 0 "$(gate run_knip_gate committing)" 'no findings passes'
rm -rf package.json .claude

echo "semgrep:"
new_repo
t 0 "$(gate run_semgrep_gate "$BASE" committing)" 'CI declares no semgrep job: passes'
has 'semgrep: skipped — CI declares no semgrep job' '…and says why'
mkdir -p .github/workflows; printf 'jobs:\n  semgrep:\n    runs-on: x\n' > .github/workflows/ci.yml
git add -A; git commit -qm ci; BASE=$(git rev-parse HEAD)
t 4 "$(gate run_semgrep_gate "$BASE" committing)" 'CI runs semgrep but it is not installed: fails'
stub semgrep 0 'echo "Ran 9 rules on 2 files: 0 findings."'
t 0 "$(gate run_semgrep_gate "$BASE" committing)" 'nothing changed: passes'
has 'semgrep: no changed files' '…and says so'
[ ! -f "$tmp/semgrep.args" ] && echo "  ✓ …without running semgrep" || { echo "  ✗ FAIL — semgrep ran on nothing"; fail=1; }

mkdir -p src vendor
printf 'a\n' > a.js; printf 'b\n' > src/a.js; printf 'c\n' > 'src/[x] y.js'; printf 'd\n' > vendor/lib.js
git add src/a.js; git commit -qm 'checkpointed'   # content already committed since BASE still counts
printf 'b2\n' >> src/a.js
git rm -q base.txt                                # a deletion is never scanned
t 0 "$(gate run_semgrep_gate "$BASE" committing)" 'changed files, no findings: passes'
has 'running semgrep on 4 changed file(s)' '…counting the changed files, deletions excluded'
args=$(cat "$tmp/semgrep.args")
case "$args" in *$'\n.') echo "  ✓ …scanning the repository root, so .semgrepignore applies";; *) echo "  ✗ FAIL — scan target is not '.': $args"; fail=1;; esac
grep -qx -- '/a.js' "$tmp/semgrep.args" && echo "  ✓ …each file an anchored --include, so a.js does not also select src/a.js" || { echo "  ✗ FAIL — a.js not anchored: $args"; fail=1; }
grep -qxF -- '/src/\[x\]\ y.js' "$tmp/semgrep.args" && echo "  ✓ …glob metacharacters and spaces escaped" || { echo "  ✗ FAIL — not escaped: $args"; fail=1; }
grep -qx -- 'base.txt' "$tmp/semgrep.args" && { echo "  ✗ FAIL — a file named as a target"; fail=1; } || echo "  ✓ …and no file is named as a target"
has '2 of 4 changed file(s) scanned' '…and reports how many semgrep scanned after .semgrepignore'
stub semgrep 1 'echo "src/a.js: finding"'
t 4 "$(gate run_semgrep_gate "$BASE" "shipping to main")" 'a finding fails'
has 'src/a.js: finding' '…and its output is replayed'
stub semgrep 0
t 4 "$(gate run_semgrep_gate no-such-ref committing)" 'a base git cannot diff against fails, not "no changed files"'
has 'no-such-ref' '…naming the base'

echo "project gate:"
new_repo
t 0 "$(gate run_project_gate "$BASE" committing)" 'no .claude/project-gate.sh: passes'
has 'project gate: none' '…and says so'
mkdir -p .claude
printf 'echo "checked against $1" >&2\nexit 0\n' > .claude/project-gate.sh
t 0 "$(gate run_project_gate "$BASE" committing)" 'a project gate that passes: passes'
has "checked against $BASE" '…given the base the change is measured from'
printf 'echo "a project check failed" >&2\nexit 3\n' > .claude/project-gate.sh
t 4 "$(gate run_project_gate "$BASE" "shipping to main")" 'a project gate that fails: fails'
has 'Fix before shipping to main' '…naming the action'
rm -rf .claude

echo "build (real npm):"
mono="$tmp/mono"; mkdir -p "$mono/packages/a" "$mono/packages/b"
printf '{"name":"root","private":true,"workspaces":["packages/*"]}\n' > "$mono/package.json"
printf '{"name":"a"}\n' > "$mono/packages/a/package.json"
printf '{"name":"b"}\n' > "$mono/packages/b/package.json"
build(){ ( source "$D/gates.sh"; run_build_gate "$1" ) >"$tmp/out" 2>"$tmp/err"; echo $?; }
t 0 "$(build "$mono")" 'no workspace declares a build: passes'
has 'no workspace declares a build script — nothing to build' '…and says so instead of "build OK"'
grep -q 'build OK' "$tmp/err" && { echo "  ✗ FAIL — claimed a build that never ran"; fail=1; } || echo "  ✓ …never claiming a build ran"
printf '{"name":"a","scripts":{"build":"echo built-a"}}\n' > "$mono/packages/a/package.json"
t 0 "$(build "$mono")" 'one workspace with a build: builds and passes'
has '1 workspace(s) declare a build script' '…counting it'
grep -q built-a "$tmp/out" && echo "  ✓ …and it really ran" || { echo "  ✗ FAIL — build did not run"; fail=1; }
printf '{"name":"b","scripts":{"build":"exit 3"}}\n' > "$mono/packages/b/package.json"
t 15 "$(build "$mono")" 'a failing build fails with 15'
# npm 12 answers each workspace with an object, not the bare script string.
npm12="$tmp/npm12"; mkdir -p "$npm12"
cat > "$npm12/npm" <<'NPM'
#!/bin/bash
if [ "$1" = pkg ]; then printf '{"a":{},"b":{"scripts.build":"echo built-12"}}\n'; else echo built-12; fi
NPM
chmod +x "$npm12/npm"
build12(){ ( PATH="$npm12:$PATH"; source "$D/gates.sh"; run_build_gate "$1" ) >"$tmp/out" 2>"$tmp/err"; echo $?; }
t 0 "$(build12 "$mono")" 'npm 12 object answer: builds and passes'
has '1 workspace(s) declare a build script' '…counting the workspace that declares one'
grep -q built-12 "$tmp/out" && echo "  ✓ …and it really ran" || { echo "  ✗ FAIL — build did not run"; fail=1; }
single="$tmp/single"; mkdir -p "$single"
printf '{"name":"s"}\n' > "$single/package.json"
t 0 "$(build "$single")" 'single package without a build: passes'
has 'no package declares a build script' '…and says so'
printf '{"name":"s","scripts":{"build":"echo built-s"}}\n' > "$single/package.json"
t 0 "$(build "$single")" 'single package with a build: builds'
grep -q built-s "$tmp/out" && echo "  ✓ …and it really ran" || { echo "  ✗ FAIL — build did not run"; fail=1; }

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
