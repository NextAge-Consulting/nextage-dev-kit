#!/usr/bin/env bash
# Regression suite for the kit's Biome configuration: biome.base.json's noConsole setting
# and the GritQL plugins in templates/biome-plugins/.
#
# Lives outside every synced source directory, so it never reaches a consumer. It builds a
# throwaway repository holding the kit's biome.base.json and plugins, as sync places them,
# writes one fixture per rule with a hit and a near-miss, lints it with the Biome version
# the stack manifest pins, and asserts which lines each rule reports.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$KIT/_claude-project/templates"
VERSION=$(jq -r '.packages["@biomejs/biome"].version' "$KIT/_claude-project/stack-manifest.json")
fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

r="$tmp/repo"
mkdir -p "$r/src" "$r/scripts"
cp "$T/biome.base.json" "$r/"
cp -R "$T/biome-plugins" "$r/"
echo '{ "extends": ["./biome.base.json"] }' > "$r/biome.json"
git -C "$r" init -q

fixtures=0
put() { mkdir -p "$(dirname "$r/$1")"; printf '%s\n' "$2" > "$r/$1"; fixtures=$((fixtures + 1)); }

put src/inner.ts 'const el = document.body
el.innerHTML = "<b>x</b>"
el.outerHTML = "y"
const read = el.innerHTML'
put src/inner.test.ts 'document.body.innerHTML = "fixture"'
put src/fn.ts 'export const f = new Function("return 1")
class Fn {}
export const g = new Fn()'
put src/emoji.tsx 'export const B = () => (
  <div>
    <span>🚀</span>
    <span aria-label="⚠ warning">ok</span>
    <span>plain → arrow</span>
    {/* 🚀 in a comment */}
  </div>
)
export const s = "🚀 in a plain string"'
put src/frame.tsx 'export const C = () => (
  <div>
    <iframe sandbox="allow-scripts allow-same-origin" title="a" />
    <iframe sandbox="allow-same-origin" title="b" />
    <div sandbox="allow-scripts" />
  </div>
)'
put src/console.ts 'console.log("app")'
put src/console.test.ts 'console.log("test")'
put scripts/build.mjs 'console.log("script")'
put server-start.mjs 'console.log("listening")'
put infra/authorizer/index.mjs 'console.log("lambda")'
put packages/ui/design-system/checks/padding.mjs 'console.log("  · checked 3")'
put src/serverfn.ts 'declare const createServerFn: any, logFailures: any, validateInput: any, schema: any, other: any
export const a = createServerFn({ method: "GET" })
  .validator(validateInput("a", schema))
  .handler(logFailures("a", async () => 1))
export const b = createServerFn({ method: "POST" })
  .validator((raw: unknown) => schema.parse(raw))
  .handler(async () => 2)
export const c = other().validator(schema).handler(async () => 3)'
put src/serverfn-suppressed.ts 'declare const createServerFn: any
export const d = createServerFn({ method: "GET" })
  // biome-ignore lint/plugin/server-fn-logging: fixture of a sanctioned site
  .handler(async () => 4)'
put src/suppressed.ts '// biome-ignore lint/plugin/no-new-function: fixture of a sanctioned site
export const h = new Function("return 2")'

if ! npx --yes "@biomejs/biome@$VERSION" --version >/dev/null 2>&1; then
    bad "Biome $VERSION could not run through npx — nothing was checked"
    exit 1
fi
out=$(cd "$r" && npx --yes "@biomejs/biome@$VERSION" lint --reporter=json --max-diagnostics=none . 2>/dev/null)

# hits <file> <message fragment> → the reported line numbers, comma-separated
hits() {
    printf '%s' "$out" | python3 -c '
import json, sys
file, frag = sys.argv[1], sys.argv[2]
try:
    data = json.loads(sys.stdin.read())
except Exception:
    print("UNPARSEABLE"); raise SystemExit
lines = []
for d in data.get("diagnostics", []):
    loc = d.get("location") or {}
    path = loc.get("path") or ""
    path = path.get("file") if isinstance(path, dict) else path
    msg = d.get("message") or d.get("description") or ""
    if isinstance(msg, list): msg = "".join(m.get("content", "") if isinstance(m, dict) else str(m) for m in msg)
    if str(path).endswith(file) and (frag in str(msg) or frag in str(d.get("category", ""))):
        start = (loc.get("start") or {}).get("line")
        lines.append(str(start) if start is not None else "?")
print(",".join(sorted(set(lines), key=lambda x: (len(x), x))))
' "$1" "$2"
}
expect() { got=$(hits "$2" "$3"); if [ "$got" = "$4" ]; then ok "$1"; else bad "$1 (lines \"$got\", wanted \"$4\")"; fi; }

expect "innerHTML and outerHTML assignments fail; a read passes"            src/inner.ts      "innerHTML/outerHTML" "2,3"
expect "innerHTML in a test file passes"                                     src/inner.test.ts "innerHTML/outerHTML" ""
expect "new Function fails; new of another class passes"                     src/fn.ts         "new Function"        "1"
expect "emoji in JSX text and attributes fail; arrows, comments, strings pass" src/emoji.tsx   "emoji"               "3,4"
expect "sandbox allow-scripts on an iframe fails; without it, or not an iframe, passes" src/frame.tsx "sandbox allows scripts" "3"
expect "console in application code fails"                                   src/console.ts    "noConsole"           "1"
expect "console in a test file passes"                                       src/console.test.ts "noConsole"         ""
expect "console in scripts/ passes"                                          scripts/build.mjs "noConsole"           ""
expect "console in the server entry passes"                                  server-start.mjs  "noConsole"           ""
expect "console in infra/ passes"                                            infra/authorizer/index.mjs "noConsole"  ""
expect "console in a token-checker project check passes"                     packages/ui/design-system/checks/padding.mjs "noConsole" ""
expect "an unwrapped server function handler fails; a wrapped one, or a non-server-fn chain, passes" src/serverfn.ts "logFailures(name, fn)" "7"
expect "an unwrapped server function validator fails; a wrapped one, or a non-server-fn chain, passes" src/serverfn.ts "validateInput(name, schema)" "6"
expect "a biome-ignore on the line above suppresses server-fn-logging" src/serverfn-suppressed.ts "logFailures(name, fn)" ""
expect "a biome-ignore with its reason suppresses a plugin"                 src/suppressed.ts "new Function"        ""

total=$(printf '%s' "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("diagnostics",[])))' 2>/dev/null || echo "?")
echo "checked $fixtures fixtures; Biome $VERSION reported $total diagnostic(s)"
exit "$fail"
