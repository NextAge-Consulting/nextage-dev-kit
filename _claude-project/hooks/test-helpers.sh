#!/bin/bash
# test-helpers.sh — shared fixtures for the hook suites. Sourced by a suite after it
# sets `tmp` (a scratch dir it removes) and `fail`.
#
#   path_without <tool>...    a PATH holding every command on PATH except the <tool>s
#   path_with_store_python    PATH with a python3 first that prints the Windows Store
#                             pointer and exits non-zero, as Windows ships it
#   assert_refuses_without <hook> <deny|block|warn> <PATH> <tool> <payload> <desc>
#       runs <hook> with <PATH>, and passes when it answers with the named form and the
#       message names <tool>. A guard that cannot run must refuse, never allow.
#
# shellcheck disable=SC2154,SC2034 # tmp and fail belong to the sourcing suite, which reads fail

path_without() {
    local d="$tmp/no"
    d="$d$(printf -- '-%s' "$@")"
    [ -d "$d" ] || python3 - "$d" "$@" <<'PY'
import os, sys
d, skip = sys.argv[1], set(sys.argv[2:])
os.makedirs(d)
for p in os.environ["PATH"].split(os.pathsep):
    try:
        names = os.listdir(p)
    except OSError:
        continue
    for n in names:
        f = os.path.join(p, n)
        if n in skip or os.path.lexists(os.path.join(d, n)):
            continue
        if os.path.isfile(f) and os.access(f, os.X_OK):
            os.symlink(f, os.path.join(d, n))
PY
    printf '%s' "$d"
}

path_with_store_python() {
    local d="$tmp/store-python"
    if [ ! -d "$d" ]; then
        mkdir -p "$d"
        printf '#!/bin/sh\necho "Python was not found; run without arguments to install from the Microsoft Store." >&2\nexit 9009\n' > "$d/python3"
        chmod +x "$d/python3"
    fi
    printf '%s:%s' "$d" "$PATH"
}

assert_refuses_without() {
    local hook="$1" kind="$2" path="$3" tool="$4" payload="$5" desc="$6" out got
    mkdir -p "$tmp/markers"
    out=$(printf '%s' "$payload" | PATH="$path" TMPDIR="$tmp/markers" "$hook" 2>/dev/null)
    got=$(printf '%s' "$out" | python3 -c '
import json, sys
tool = sys.argv[1]
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw) if raw else {}
except Exception:
    print("malformed"); raise SystemExit
h = d.get("hookSpecificOutput") or {}
if h.get("permissionDecision") == "deny":
    kind, text = "deny", h.get("permissionDecisionReason") or ""
elif d.get("decision") == "block":
    kind, text = "block", d.get("reason") or ""
elif d.get("systemMessage"):
    kind, text = "warn", d["systemMessage"]
else:
    print("allow"); raise SystemExit
print(kind if tool in text else kind + " without naming " + tool)
' "$tool")
    if [ "$got" = "$kind" ]; then echo "  ✓ $desc"; else echo "  ✗ FAIL ($got, want $kind) — $desc"; fail=1; fi
}
