#!/usr/bin/env bash
# Regression suite for _claude-project/templates/scripts/check-types.mjs.
#
# Lives outside every synced source directory, so it never reaches a consumer.
# Each case builds a throwaway repository whose workspaces' `check-types` scripts
# pass or fail on purpose, installs the real script at scripts/ as sync does (it
# resolves the repo root from its own location), runs it, and asserts the exit
# code and what it prints.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="$KIT/_claude-project/templates/scripts/check-types.mjs"
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# repo <name> <root package.json> — a repository holding the script.
repo() {
    local r="$tmp/$1"
    mkdir -p "$r/scripts"
    cp "$S" "$r/scripts/"
    printf '%s\n' "$2" > "$r/package.json"
    echo "$r"
}

# workspace <repo> <dir> <check-types command, or "" for none>
workspace() {
    mkdir -p "$1/$2"
    if [ -n "$3" ]; then
        jq -n --arg n "@acme/$(basename "$2")" --arg c "$3" '{name: $n, scripts: {"check-types": $c}}' > "$1/$2/package.json"
    else
        jq -n --arg n "@acme/$(basename "$2")" '{name: $n}' > "$1/$2/package.json"
    fi
}

PASS='node -e "process.exit(0)"'
FAIL_TWO_LINES='node -e "console.log(\"src/a.ts(1,7): error TS2322: first\"); console.log(\"src/b.ts(2,1): error TS2304: second\"); process.exit(2)"'

# expect <name> <exit> <output> [pattern…] — each pattern must appear in the output.
expect() {
    local name="$1" want="$2" out="$3" code="$4"; shift 4
    if [ "$code" -ne "$want" ]; then bad "$name (exit $code, wanted $want): $out"; return; fi
    local p
    for p in "$@"; do
        if ! grep -qF -- "$p" <<<"$out"; then bad "$name (missing \"$p\"): $out"; return; fi
    done
    ok "$name"
}

# refute <name> <output> <pattern> — the pattern must NOT appear.
refute() {
    if grep -qF -- "$3" <<<"$2"; then bad "$1 (unexpected \"$3\"): $2"; else ok "$1"; fi
}

r=$(repo all-pass '{"workspaces":["apps/*","packages/*"]}')
workspace "$r" apps/web "$PASS"; workspace "$r" packages/shared "$PASS"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "every workspace passing exits 0 and says how many it checked" 0 "$out" "$code" "✓ check-types: 2 workspace(s) type-checked clean"

jq '.scripts={"check-types":"node scripts/check-types.mjs"}' "$r/package.json" > "$tmp/root.json" && mv "$tmp/root.json" "$r/package.json"
# A decoy `npm` first on PATH fails every check it runs, so a pass proves the workspaces
# ran through the npm CLI the root script was started by, not through PATH.
NPM=$(command -v npm)
mkdir -p "$tmp/decoy"; printf '#!/bin/sh\necho decoy npm; exit 99\n' > "$tmp/decoy/npm"; chmod +x "$tmp/decoy/npm"
out=$(cd "$r" && PATH="$tmp/decoy:$PATH" "$NPM" run check-types --silent 2>&1); code=$?
expect "run as the root npm script it spawns npm through npm_execpath" 0 "$out" "$code" "✓ check-types: 2 workspace(s) type-checked clean"

r=$(repo one-fails '{"workspaces":["apps/*","packages/*"]}')
workspace "$r" apps/web "$PASS"; workspace "$r" packages/shared "$FAIL_TWO_LINES"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a failing workspace exits 1 and prints its output whole" 1 "$out" "$code" \
    "✗ @acme/shared" "src/a.ts(1,7): error TS2322: first" "src/b.ts(2,1): error TS2304: second" \
    "✗ check-types: 1 of 2 workspace(s) failed"
refute "a passing workspace is not printed as a failure" "$out" "✗ @acme/web"

r=$(repo object-form '{"workspaces":{"packages":["apps/web","packages/shared"]}}')
workspace "$r" apps/web "$PASS"; workspace "$r" packages/shared "$FAIL_TWO_LINES"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect 'the { packages: [...] } form names the workspaces too' 1 "$out" "$code" "✗ check-types: 1 of 2 workspace(s) failed"

r=$(repo skipped '{"workspaces":["apps/*"]}')
workspace "$r" apps/web "$PASS"; workspace "$r" apps/docs ""
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a workspace without the script is counted as skipped" 0 "$out" "$code" \
    "✓ check-types: 1 workspace(s) (1 without a check-types script skipped) type-checked clean"

r=$(repo no-script '{"workspaces":["apps/*"]}')
workspace "$r" apps/web ""; workspace "$r" apps/docs ""
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "no workspace declaring the script fails, saying nothing was checked" 1 "$out" "$code" \
    'none of the 2 workspace(s) declares a "check-types" script, so nothing was checked'

r=$(repo no-workspaces '{"name":"single","scripts":{"check-types":"tsc --noEmit"}}')
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a repository with no workspaces fails, pointing at tsc" 1 "$out" "$code" 'package.json declares no "workspaces"'

r=$(repo broken-literal '{"workspaces":["apps/web","packages/shared"]}')
workspace "$r" apps/web "$PASS"; mkdir -p "$r/packages/shared"; echo '{ not json' > "$r/packages/shared/package.json"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a declared workspace whose package.json does not parse fails loud" 1 "$out" "$code" "cannot read or parse packages/shared/package.json"

r=$(repo missing-literal '{"workspaces":["apps/web","apps/gone"]}')
workspace "$r" apps/web "$PASS"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a declared workspace with no package.json fails loud" 1 "$out" "$code" "cannot read or parse apps/gone/package.json"

r=$(repo empty-glob '{"workspaces":["apps/*","services/*"]}')
workspace "$r" apps/web "$PASS"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "a workspace glob matching nothing fails" 1 "$out" "$code" "match no package" "services/*"

r="$tmp/not-node"; mkdir -p "$r/scripts"; cp "$S" "$r/scripts/"
out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
expect "no package.json says it does not apply and passes" 0 "$out" "$code" "not a Node repo, so it does not apply"

# Concurrency: each workspace's check marks itself started, then waits for the other's
# mark. Run one after another, the first would wait alone and fail.
if [ "$(node -p 'require("node:os").availableParallelism()')" -ge 2 ]; then
    r=$(repo concurrent '{"workspaces":["apps/*"]}')
    cat > "$r/barrier.js" <<'JS'
const fs = require("node:fs");
const path = require("node:path");
const marks = path.join(__dirname, "marks");
fs.mkdirSync(marks, { recursive: true });
fs.writeFileSync(path.join(marks, process.argv[2]), "");
const deadline = Date.now() + 5000;
const poll = () => {
  if (fs.readdirSync(marks).length >= 2) process.exit(0);
  if (Date.now() > deadline) { console.log(`${process.argv[2]} ran alone`); process.exit(3); }
  setTimeout(poll, 25);
};
poll();
JS
    workspace "$r" apps/one 'node ../../barrier.js one'; workspace "$r" apps/two 'node ../../barrier.js two'
    out=$(node "$r/scripts/check-types.mjs" 2>&1); code=$?
    expect "workspaces run concurrently, not in turn" 0 "$out" "$code" "✓ check-types: 2 workspace(s) type-checked clean"
else
    echo "skip workspaces run concurrently — this machine reports one CPU, and the script runs one per CPU"
fi

[ "$fail" -eq 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
