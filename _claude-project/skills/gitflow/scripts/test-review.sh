#!/bin/bash
# test-review.sh <base-ref> — the test review gate for /commit and /ship-main.
#
# Every TypeScript source and test file changed since <base-ref> — committed checkpoints,
# the working tree and untracked files alike — is judged by a headless Claude against the
# kit's criteria for what earns a test: risky behaviour with no test proving it, a test
# that imports nothing from the application or re-implements its logic, a superfluous test
# (ORM-only, or a duplicate of another, happy-path tests included, a shared function
# re-tested through an app's pass-through wrapper among them) and a test of the wrong
# kind for its file name. A finding fails the gate.
#
# Source is a .ts or .tsx outside node_modules, .claude, a test/, tests/ or __tests__
# folder, and not a .d.ts or a test. A test is a *.test.* or *.spec.* in any TypeScript or JavaScript extension; its kind
# is in its name — *.happy.integration.test.ts (happy-path), *.dev.integration.test.ts
# (development), any other *.integration.test.ts (risk), the rest unit tests.
#
# The reviewer's input inlines, in this order until MAX_BYTES is spent: each changed source
# file's diff with the top-level declarations the change touches, every changed test, every
# test that imports a changed source file directly, and the source a changed test imports.
# A file that does not fit is listed by path under "NOT INLINED — read with the Read tool";
# no change is too big to review. The reviewer can read the repository — Read, Grep and
# Glob only, pre-approved, the repository added with --add-dir — and searches its tests
# before reporting a test missing or a duplicate. It runs from a temp dir with no settings
# sources, so no project CLAUDE.md or settings load, and reports nothing it is unsure of.
#
# Because the reviewer can read any test, a remembered pass is keyed on the content of
# every test file in the repository as well as the input sent.
#
# Exit 0: nothing to review, or clean. Exit 1: findings, or the gate could not run.
# Override (user-authorized only): SKIP_TEST_REVIEW=1.
#
# TEST_REVIEW_CLAUDE names the CLI to run (default `claude`), and TEST_REVIEW_MAX_BYTES
# the inline budget (default 300000); the suite sets both.

set -uo pipefail

BASE="${1:-HEAD}"
MAX_BYTES="${TEST_REVIEW_MAX_BYTES:-300000}"

if [ "${SKIP_TEST_REVIEW:-}" = "1" ]; then
    echo "gitflow: test review skipped (SKIP_TEST_REVIEW=1)." >&2
    exit 0
fi

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "gitflow: test review: not in a git repository." >&2; exit 1; }
CACHE_LIB="$(dirname "${BASH_SOURCE[0]}")/review-cache.sh"
if [ ! -f "$CACHE_LIB" ]; then
    echo "gitflow: the test review cannot run — review-cache.sh is missing beside it. Run /sync-dev-kit." >&2
    exit 1
fi
# shellcheck source=./review-cache.sh
source "$CACHE_LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# NUL-separated, so a path git would quote is read as itself. A failing diff — a base
# that does not resolve — fails the gate rather than reading as "nothing changed".
if ! (cd "$ROOT" && git diff -z --name-only --diff-filter=d "$BASE" -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs' && git ls-files -z --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs') >"$WORK/changed" 2>"$WORK/err"; then
    echo "gitflow: test review cannot list the changed files (git diff against $BASE failed):" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

# kind_of <path> — prints test, source, or nothing for a file the review does not read.
kind_of() {
    case "$1" in
        node_modules/*|*/node_modules/*|.claude/*|*.d.ts) return 0 ;;
        *.test.ts|*.test.tsx|*.test.mts|*.test.cts|*.test.js|*.test.jsx|*.test.mjs|*.test.cjs) echo test; return 0 ;;
        *.spec.ts|*.spec.tsx|*.spec.mts|*.spec.cts|*.spec.js|*.spec.jsx|*.spec.mjs|*.spec.cjs) echo test; return 0 ;;
        test/*|*/test/*|tests/*|*/tests/*|__tests__/*|*/__tests__/*) return 0 ;;
        *.ts|*.tsx) echo source ;;
    esac
}

SOURCES=(); TESTS=()
while IFS= read -r -d '' f; do
    [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
    case "$(kind_of "$f")" in
        source) SOURCES+=("$f") ;;
        test) TESTS+=("$f") ;;
    esac
done < <(sort -zu "$WORK/changed")

if [ ${#SOURCES[@]} -eq 0 ] && [ ${#TESTS[@]} -eq 0 ]; then
    echo "gitflow: test review: no TypeScript source or test file changed." >&2
    exit 0
fi
WHAT="${#SOURCES[@]} changed source file(s) and ${#TESTS[@]} changed test file(s)"

# The reviewer's answer is parsed by python3, and the input is built by it. Without a
# working one every answer would read as "no findings" — so a missing python3 fails here,
# before the review is paid for.
if [ "$(python3 -c 'print(1)' 2>/dev/null)" != "1" ]; then
    echo "gitflow: $WHAT, and the test review needs a working python3, which is missing or not a real interpreter." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

CLAUDE_BIN="${TEST_REVIEW_CLAUDE:-claude}"
if ! command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
    echo "gitflow: $WHAT, and the test review needs the Claude Code CLI, which is not on PATH." >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

# Each changed source file's diff, one file per source, in the order of SOURCES.
mkdir -p "$WORK/diffs"
i=0
for f in ${SOURCES[@]+"${SOURCES[@]}"}; do
    if (cd "$ROOT" && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1); then
        (cd "$ROOT" && git diff -U3 "$BASE" -- "$f") >"$WORK/diffs/$i" 2>"$WORK/err"; rc=$?
    else
        # --no-index exits 1 when the files differ, which a new file always does.
        (cd "$ROOT" && git diff -U3 --no-index -- /dev/null "$f") >"$WORK/diffs/$i" 2>"$WORK/err"; rc=$?
        [ "$rc" -eq 1 ] && rc=0
    fi
    if [ "$rc" -ne 0 ]; then
        echo "gitflow: test review cannot diff $f against $BASE:" >&2
        sed 's/^/  /' "$WORK/err" >&2
        echo "  A gate that cannot run must not report success, so this is a failure." >&2
        exit 1
    fi
    i=$((i + 1))
done
printf '%s\0' ${SOURCES[@]+"${SOURCES[@]}"} >"$WORK/sources"
printf '%s\0' ${TESTS[@]+"${TESTS[@]}"} >"$WORK/tests"

# Every TypeScript file in the repository, for the import graph.
if ! (cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' '*.js' '*.jsx' '*.mjs' '*.cjs') >"$WORK/all" 2>"$WORK/err"; then
    echo "gitflow: test review cannot list the repository's files:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

# Builds the reviewer's input, and the test-file manifest the pass cache keys on. Its
# output is the count of what was inlined and what was listed:
# "<covering inlined> <context inlined> <listed>".
python3 - "$ROOT" "$WORK" "$MAX_BYTES" "$BASE" >"$WORK/stats" 2>"$WORK/err" <<'PY'
import hashlib, os, re, sys

root, work, cap, base = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

def nul_list(name):
    with open(os.path.join(work, name), "rb") as fh:
        return [p.decode("utf-8", "surrogateescape") for p in fh.read().split(b"\0") if p]

def read(path):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()

def test_kind(path):
    name = os.path.basename(path)
    if re.search(r"\.happy\.integration\.(test|spec)\.(tsx?|mts|cts|jsx?|mjs|cjs)$", name): return "happy-path test"
    if re.search(r"\.dev\.integration\.(test|spec)\.(tsx?|mts|cts|jsx?|mjs|cjs)$", name): return "development test"
    if re.search(r"\.integration\.(test|spec)\.(tsx?|mts|cts|jsx?|mjs|cjs)$", name): return "risk test"
    return "unit test"

def is_test(path):
    return re.search(r"\.(test|spec)\.(tsx?|mts|cts|jsx?|mjs|cjs)$", path) is not None

def excluded(path):
    parts = path.split("/")
    return "node_modules" in parts or parts[0] == ".claude" or path.endswith(".d.ts")

sources, tests = nul_list("sources"), nul_list("tests")
all_files = [p for p in nul_list("all") if not excluded(p) and os.path.isfile(os.path.join(root, p))]
TEST_DIRS = {"test", "tests", "__tests__"}
app_files = [p for p in all_files if not is_test(p) and not TEST_DIRS & set(p.split("/")[:-1])]
all_tests = [p for p in all_files if is_test(p)]

IMPORT = re.compile(r"""(?:\bfrom\s*|\bimport\s*\(\s*|\bimport\s+|\brequire\s*\(\s*)["']([^"']+)["']""")

def stem(path):
    s = re.sub(r"\.(tsx?|jsx?|mts|cts)$", "", path)
    return re.sub(r"/index$", "", s)

app_by_stem = {}
for p in app_files:
    app_by_stem.setdefault(stem(p), []).append(p)

def resolve(spec, importer):
    """App files a specifier names. Relative paths resolve exactly; an alias or package
    path (`@/lib/x`, `~/lib/x`, `@scope/pkg/lib/x`, `pkg/lib/x`) matches a file whose path
    ends in the part after the alias or package name."""
    spec = re.sub(r"\.(js|jsx|mjs|cjs|ts|tsx)$", "", spec)
    if spec.startswith("."):
        target = os.path.normpath(os.path.join(os.path.dirname(importer), spec))
        return app_by_stem.get(stem(target), [])
    segs = spec.split("/")
    drop = 2 if spec.startswith("@") and not spec.startswith("@/") else 1
    rest = "/".join(segs[drop:])
    if not rest:
        return []
    return [p for s, ps in app_by_stem.items() if s == rest or s.endswith("/" + rest) for p in ps]

imports = {}
def imports_of(path):
    if path not in imports:
        found = set()
        for spec in IMPORT.findall(read(path)):
            found.update(resolve(spec, path))
        imports[path] = found
    return imports[path]

# The new-file line numbers a diff adds or changes; a hunk that only deletes marks the
# line it deleted before.
def changed_lines(diff):
    lines, n = set(), None
    for line in diff.split("\n"):
        m = re.match(r"^@@ -\d+(?:,\d+)? \+(\d+)", line)
        if m:
            n = int(m.group(1)); continue
        if n is None or line.startswith(("+++", "---")):
            continue
        if line.startswith("+"):
            lines.add(n); n += 1
        elif line.startswith("-"):
            lines.add(n)
        elif line.startswith(" "):
            n += 1
    return lines

DECL = re.compile(r"^(export\s|default\s|async\s|function[\s*]|const\s|let\s|var\s|class\s|abstract\s|interface\s|type\s|enum\s|declare\s|namespace\s|@)")

# The top-level declarations a set of lines falls in, numbered as in the file. A
# declaration starts at a column-0 keyword and runs to the next one.
def touched_declarations(text, lines):
    rows = text.split("\n")
    starts = [i for i, r in enumerate(rows) if DECL.match(r)]
    out = []
    for k, s in enumerate(starts):
        e = starts[k + 1] if k + 1 < len(starts) else len(rows)
        while e > s + 1 and rows[e - 1].strip() == "":
            e -= 1
        if any(s + 1 <= ln <= e for ln in lines):
            out.append("\n".join("%5d  %s" % (i + 1, rows[i]) for i in range(s, e)))
    return "\n\n".join(out) if out else "(the change touches no top-level declaration: imports or comments only)"

# Inlined in priority order — changed sources, changed tests, covering tests, context —
# while the budget lasts. A block that does not fit is listed by path for the reviewer to
# read, and a smaller one after it may still be inlined.
changed_sources, changed_tests = set(sources), set(tests)
covering = [t for t in all_tests if t not in changed_tests and imports_of(t) & changed_sources]
context = sorted(set().union(*[imports_of(t) for t in tests]) - changed_sources) if tests else []

candidates = []  # (group, block, listed-label)
for i, f in enumerate(sources):
    with open(os.path.join(work, "diffs", str(i)), encoding="utf-8", errors="replace") as fh:
        diff = fh.read()
    candidates.append(("source",
        "=== CHANGED SOURCE: %s ===\n--- the diff ---\n%s\n--- the declarations the change touches, as they are now ---\n%s\n"
        % (f, diff.rstrip("\n"), touched_declarations(read(f), changed_lines(diff))),
        "%s (changed source; its diff against %s was not inlined — read the file)" % (f, base)))
for t in tests:
    candidates.append(("test", "=== CHANGED TEST (%s): %s ===\n%s\n" % (test_kind(t), t, read(t).rstrip("\n")),
        "%s (changed test, %s)" % (t, test_kind(t))))
for t in covering:
    candidates.append(("covering", "=== TEST THAT IMPORTS A CHANGED FILE (%s): %s ===\n%s\n" % (test_kind(t), t, read(t).rstrip("\n")),
        "%s (%s that imports a changed file)" % (t, test_kind(t))))
for p in context:
    candidates.append(("context", "=== APPLICATION CODE A CHANGED TEST IMPORTS (unchanged, for context): %s ===\n%s\n" % (p, read(p).rstrip("\n")),
        "%s (application code a changed test imports)" % p))

inlined, listed = [], []
counts = {"source": 0, "test": 0, "covering": 0, "context": 0}
budget = cap
for group, block, label in candidates:
    n = len(block.encode("utf-8"))
    if n <= budget:
        inlined.append(block); budget -= n; counts[group] += 1
    else:
        listed.append(label)

with open(os.path.join(work, "input"), "w", encoding="utf-8") as out:
    out.write("Repository root: %s\nChanged files are compared against %s.\n\n" % (root, base))
    out.write("\n".join(inlined))
    if listed:
        out.write("\n=== NOT INLINED — read with the Read tool (paths relative to the repository root) ===\n")
        out.write("\n".join(listed) + "\n")
with open(os.path.join(work, "listed"), "w", encoding="utf-8") as out:
    out.write("".join("  " + l + "\n" for l in listed))

# Every test file the reviewer could read, by path and content hash, for the pass cache.
with open(os.path.join(work, "test-manifest"), "w", encoding="utf-8") as out:
    for t in sorted(all_tests):
        with open(os.path.join(root, t), "rb") as fh:
            out.write("%s\t%s\n" % (t, hashlib.sha256(fh.read()).hexdigest()))
print("%d %d %d %d %d" % (counts["source"], counts["test"], counts["covering"], counts["context"], len(listed)))
PY
BUILD=$?

if [ "$BUILD" -ne 0 ] || ! read -r IN_SOURCES IN_TESTS SHOWN CONTEXT LISTED <"$WORK/stats"; then
    echo "gitflow: the test review cannot read the changed files:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi
SENT="$WHAT, $SHOWN test file(s) importing a changed file, $CONTEXT application file(s) a changed test imports"
if [ "$LISTED" -gt 0 ]; then
    SENT="$WHAT; inlined $IN_SOURCES changed source diff(s), $IN_TESTS changed test(s), $SHOWN test file(s) importing a changed file, $CONTEXT application file(s) a changed test imports; $LISTED file(s) over the $MAX_BYTES-byte inline budget listed for the reviewer to read"
fi

read -r -d '' SYSTEM <<'EOF'
You judge the tests of one change to a TypeScript business application. The input opens with the repository root. It inlines, as far as its size allows, each changed source file's diff and the top-level declarations the change touches, numbered as they are now; every test file the change adds or edits; every test file that imports a changed source file; and, for context, the application code the changed tests import. Each test file is headed by its kind. Anything that did not fit is listed under "NOT INLINED", by path relative to the repository root: read every file listed there with the Read tool before judging. You can read the whole repository with Read, Grep and Glob, and nothing else; you change nothing.

The kinds of test, told apart by file name:
- Happy-path test (`*.happy.integration.test.ts`): the main success case of a core function. The happy-path audit writes these; never report one as superfluous or misnamed.
- Risk test (`*.integration.test.ts`): proves a case that touches risky behaviour, as defined below, against the real database — a period boundary, money math, a permission denial. It may also hold one main success case per function when no other case of that function is a risk test: a function that queries the database in a risky shape — raw SQL, a join, a filter beyond a lookup by key, an aggregate or grouping, a date range, an upsert, a transaction, more than one write — must keep one test in the full suite, and that case is it until the happy-path audit decides whether the function is core. Happy-path and risk tests together are the full suite.
- Development test (`*.dev.integration.test.ts`): helped while the code was being written; runs only when its code changes, never in the full suite.
- Unit test (any other test file): the answer is in the code — formatting, parsing, validation, a branch, a calculation — and needs no database.

Code is risky when it handles: money math — an amount the code computes: a sum, a fee rate, rounding, proration; a zero or a missing amount is not money math; dates, time zones and period boundaries; permissions and access; data integrity — a write that could corrupt, duplicate or orphan data that other code or another application reads: a duplicate where one must be unique, a write left half-done, a write landing on the wrong record; a function that writes nothing when it refuses, or leaves other columns alone, is checking its own logic, not data integrity; concurrency — two writers, retries, idempotency; a contract with another system — the shape, protocol or encoding the other system requires, asserted against its real format; a case where that system is mocked tests a branch, not the contract; or code many other parts depend on. A bug fixed there before makes code risky only when a competent developer making a sensible later change could plausibly reintroduce it, because the fix rests on a database quirk, a protocol detail, a boundary or an external contract. A plain mistake — a typo, a misread requirement, a wrong variable — does not. A filter, a join, an aggregate or a date range on its own is not risky behaviour; a case asserting a period boundary itself is. A database quirk on its own — collation, trimming, NULL handling, a column's type, a fallback that writes nothing — is not risky behaviour either, unless a fixed bug rests on it.

Report a finding of one of these kinds:
- missing: a changed function has risky behaviour that no test in the repository proves. Name the function and the case that needs a test — the period boundary, the permission denial, the rounding. Thin code — a plain read or write with no condition, calculation or boundary — needs no test.
- reimplements: a test that does not call the application's code — it imports nothing from the application, or runs its own copy of the logic or the SQL and asserts on that copy, so it passes with the application broken. The case was worth testing; the fix is to rewrite the test to call the application's function.
- superfluous: a risk, development or unit test that proves nothing the application's code decides — it only shows the ORM saved a row or read back what was written (ORM-only) — or that repeats a case another test already proves, a happy-path test included (duplicate). Shared code is tested once, in the shared module: an app test of an app function whose body only passes the call through to a shared-module function — forwarding it, perhaps reshaping the arguments — is a duplicate when it asserts nothing the shared module's test of that function does not; what the app adds on top — its own inputs, checks or output shape — is judged on its own.
- misnamed: a test filed as the wrong kind — a risk test of nothing risky, other than the one main success case a risky-shape function keeps (it belongs in a `.dev.integration.test.ts` file), a development test that proves risky behaviour (it belongs in a risk test), an integration test that needs no database (it belongs in a unit test).

Judge the changed code and every test that bears on it, wherever it lives. Before reporting a function's case missing, or a test superfluous as a duplicate, search the repository's test files (`*.test.*` and `*.spec.*` in any TypeScript or JavaScript extension — `.ts`, `.tsx`, `.mts`, `.js`, `.mjs` and the rest) with Grep for the function's name and read every test that names it or imports its file: a test anywhere in the repository counts, inlined or not. Report only clear cases; when unsure, do not report. A clean change returns {"findings": []}.
For each finding give the kind; the file — the source file for missing, the test file for the others; the test's name when the finding is about one test; the function's name when it is about one function; one sentence on why; and the concrete fix.
EOF

SCHEMA='{"type":"object","properties":{"findings":{"type":"array","items":{"type":"object","properties":{"kind":{"type":"string","enum":["missing","reimplements","superfluous","misnamed"]},"file":{"type":"string"},"test":{"type":"string"},"function":{"type":"string"},"why":{"type":"string"},"fix":{"type":"string"}},"required":["kind","file","why","fix"]}}},"required":["findings"]}'

# The key covers the input sent and, since the reviewer can read any test, the path and
# content hash of every test file in the repository: a test added or edited anywhere
# re-asks the review.
if cat "$WORK/input" "$WORK/test-manifest" >"$WORK/keyed" 2>/dev/null \
    && CACHE_KEY=$(review_cache_key "$WORK" "${BASH_SOURCE[0]}" "$SYSTEM" "$SCHEMA" "$WORK/keyed"); then
    :
else
    CACHE_KEY=""
fi
if review_cache_hit "$ROOT" test-review "$CACHE_KEY"; then
    echo "gitflow: test review — reusing the earlier pass: the same $WHAT and the same tests, unchanged since it was reviewed." >&2
    exit 0
fi

echo "gitflow: judging the tests of $WHAT..." >&2
if [ "$LISTED" -gt 0 ]; then
    echo "  over the $MAX_BYTES-byte inline budget, listed for the reviewer to read:" >&2
    cat "$WORK/listed" >&2
fi

# Runs from $WORK, so no project CLAUDE.md or settings load; the repository is reachable
# only through --add-dir, and only by the three read-only tools, pre-approved.
OUT=$(cd "$WORK" && "$CLAUDE_BIN" -p \
    --model sonnet --tools "Read,Grep,Glob" --allowedTools "Read,Grep,Glob" --add-dir "$ROOT" \
    --system-prompt "$SYSTEM" --json-schema "$SCHEMA" \
    --output-format json --no-session-persistence --disable-slash-commands \
    --strict-mcp-config --setting-sources "" <"$WORK/input" 2>"$WORK/err")
STATUS=$?

REPORT=$(printf '%s' "$OUT" | python3 -c '
import json, sys
ACTION = {
    "missing": "write the test",
    "reimplements": "rewrite it to call the function it tests",
    "superfluous": "delete it",
    "misnamed": "rename or move it",
}
try:
    d = json.load(sys.stdin)
    if d.get("is_error"):
        raise ValueError
    findings = d["structured_output"]["findings"]
    for f in findings:
        if f["kind"] not in ACTION:
            raise ValueError
except Exception:
    print("ERROR"); sys.exit(0)
print("PARSED")
for i, f in enumerate(findings, 1):
    where = f["file"]
    for k in ("function", "test"):
        if (f.get(k) or "").strip():
            where += " — " + f[k].strip()
    print("  %d. %s: %s" % (i, f["kind"], where))
    print("     why: " + f["why"].strip())
    print("     fix: " + f["fix"].strip() + " (" + ACTION[f["kind"]] + ")")
' 2>/dev/null)

# The first line is PARSED only when python3 read a well-formed answer; anything else —
# ERROR, or nothing at all — is a review that did not happen.
if [ "$STATUS" -ne 0 ] || [ "$(printf '%s\n' "$REPORT" | head -1)" != "PARSED" ]; then
    echo "gitflow: the test review could not run (claude exited $STATUS)." >&2
    sed 's/^/  /' "$WORK/err" >&2
    echo "  A gate that cannot run must not report success, so this is a failure." >&2
    exit 1
fi

REPORT=$(printf '%s\n' "$REPORT" | sed '1d')
if [ -n "$REPORT" ]; then
    echo "gitflow: test review — the tests of this change need work ($SENT):" >&2
    printf '%s\n' "$REPORT" >&2
    echo "  missing: write the test. reimplements: rewrite the test to call the application's function." >&2
    echo "  superfluous: delete the test. misnamed: rename or move it as the fix says." >&2
    echo "  Then commit again. A finding the human judges wrong: they may commit with SKIP_TEST_REVIEW=1." >&2
    exit 1
fi

review_cache_store "$ROOT" test-review "$CACHE_KEY"
echo "gitflow: test review clean — reviewed $SENT." >&2
exit 0
