#!/bin/bash
# The full test suite in CodeBuild, for a project whose TEST_RUNNER is aws. Run by the
# kit's test buildspec (infra/codebuild/buildspec-test.yml) after `npm ci`, from the
# repository root; pipeline.md §1.6 and infrastructure.md ("The full suite in CodeBuild").
#
#   codebuild-suite.sh [--out <file>]     default /tmp/full-suite.env
#
# 1. Fingerprints the code under test — the checked-out commit — with code-fingerprint.mjs.
# 2. When an earlier SUCCEEDED build of this project exported the same FULL_SUITE_FP, the
#    pass is carried forward and the suite does not run (the newest 100 builds are read).
# 3. Otherwise runs `npm test`; when the repository has integration tests that must run
#    (the same rule as ci.yml's vitest job, INTEGRATION_CI_OFF included), they must have run.
# 4. Writes FULL_SUITE_FP (and FULL_SUITE_FROM, the build carried forward from) to <file>
#    as shell assignments; the buildspec sources it, and exports both. /deploy trusts a
#    SUCCEEDED build of this project whose FULL_SUITE_FP is main's fingerprint.
#
# A fingerprint that cannot be computed, or builds that cannot be read, run the suite and
# say so; without a fingerprint the pass is not recorded. Exit non-zero fails the build.

set -uo pipefail

OUT="/tmp/full-suite.env"
while [[ $# -gt 0 ]]; do
    case $1 in
        --out) OUT="$2"; shift 2 ;;
        *) echo "codebuild-suite.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP_SCRIPT="$SCRIPT_DIR/code-fingerprint.mjs"
SUBS=".claude/sync-substitutions.json"
SELF="${CODEBUILD_BUILD_ID:-}"
PROJECT="${SELF%%:*}"
: > "$OUT" || { echo "codebuild-suite.sh: cannot write $OUT" >&2; exit 2; }

record() {
    printf 'FULL_SUITE_FP=%s\nFULL_SUITE_FROM=%s\n' "$1" "${2:-}" > "$OUT"
}

if ! jq -e '.scripts.test | strings' package.json >/dev/null 2>&1; then
    echo "codebuild-suite.sh: package.json declares no \"test\" script, so there is no suite to run (testing.md §1)." >&2
    exit 1
fi

FP=""
if [ ! -f "$FP_SCRIPT" ]; then
    echo "codebuild-suite.sh: WARNING — $FP_SCRIPT is missing (run /sync-dev-kit), so this pass cannot be recorded — the suite runs." >&2
elif ! FP=$(node "$FP_SCRIPT" --commit HEAD); then
    FP=""
    echo "codebuild-suite.sh: WARNING — the code fingerprint could not be computed, so this pass cannot be recorded — the suite runs." >&2
else
    echo "code fingerprint: $FP"
fi

# ─── An earlier pass on this exact code ───────────────────────────────────
if [ -n "$FP" ] && [ -n "$PROJECT" ]; then
    if ! ids=$(aws codebuild list-builds-for-project --project-name "$PROJECT" \
            --sort-order DESCENDING --max-items 100 --query 'ids' --output text 2>&1); then
        echo "codebuild-suite.sh: WARNING — could not list this project's builds, so no earlier pass can be found — the suite runs. $ids" >&2
        ids=""
    fi
    ids=$(printf '%s\n' "$ids" | tr '\t' '\n' | { grep -vE '^(None)?$' || true; } | { grep -vxF "$SELF" || true; })
    if [ -n "$ids" ]; then
        # shellcheck disable=SC2086 # the id list is split on purpose
        if ! passes=$(aws codebuild batch-get-builds --ids $ids \
                --query 'builds[?buildStatus==`SUCCEEDED`].[id, exportedEnvironmentVariables[?name==`FULL_SUITE_FP`].value | [0]]' \
                --output text 2>&1); then
            echo "codebuild-suite.sh: WARNING — could not read this project's builds, so no earlier pass can be found — the suite runs. $passes" >&2
            passes=""
        fi
        while IFS=$'\t' read -r id build_fp; do
            if [ -n "$id" ] && [ "$build_fp" = "$FP" ]; then
                record "$FP" "$id"
                echo "The full suite passed on this exact code in $id — carried forward, not run again."
                exit 0
            fi
        done <<< "$passes"
    fi
    echo "No earlier build of $PROJECT passed the full suite on this code — the suite runs."
fi

# ─── Must the integration tests run ───────────────────────────────────────
engine=""; ci_off=""
if [ -f "$SUBS" ]; then
    engine=$(jq -r '.DB_ENGINE // "" | strings' "$SUBS")
    ci_off=$(jq -r '.INTEGRATION_CI_OFF // "" | strings' "$SUBS")
fi
files=$(git ls-files -- '*.integration.test.ts' '*.integration.test.tsx' '*.integration.test.mts' ':(exclude)*.dev.integration.test.*' | { grep -vE '(^|/)node_modules/' || true; })
required=false
if [ -z "$files" ]; then
    echo "The repository has no integration tests, so none must run."
elif [ "$engine" = "None" ]; then
    echo "DB_ENGINE is None, so the integration tests are not required."
elif [ -n "$ci_off" ]; then
    echo "Integration tests are declared off in CI (INTEGRATION_CI_OFF): $ci_off"
elif [ "$engine" = "PostgreSQL" ] && { [ -z "${NEON_API_KEY:-}" ] || [ -z "${NEON_PROJECT_ID:-}" ]; }; then
    echo "codebuild-suite.sh: this repository has integration tests, but NEON_API_KEY or NEON_PROJECT_ID is empty in this build, so they would be skipped. Give the CodeBuild project both as environment variables from Secrets Manager or Parameter Store (infrastructure.md, \"The full suite in CodeBuild\"), or declare why CI cannot run them in INTEGRATION_CI_OFF." >&2
    printf '%s\n' "$files" >&2
    exit 1
else
    required=true
fi

# ─── The suite ─────────────────────────────────────────────────────────────
# NO_COLOR keeps vitest's project labels plain; with colour on it prints each as a badge
# with no `|` around it, and the integration check below would miss a run that happened.
log=$(mktemp)
NO_COLOR=1 npm test 2>&1 | tee "$log"
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    rm -f "$log"
    echo "codebuild-suite.sh: the full suite failed." >&2
    exit 1
fi
if [ "$required" = true ] && ! grep -qF '|integration|' "$log"; then
    rm -f "$log"
    echo "codebuild-suite.sh: this repository has integration tests, but the integration project did not run. On another engine than PostgreSQL, register it in test/project.ts under the name \"integration\" (the engine rule says how), or declare why CI cannot run it in INTEGRATION_CI_OFF (testing.md §3)." >&2
    exit 1
fi
rm -f "$log"
[ "$required" = true ] && echo "The integration project ran."
if [ -n "$FP" ]; then
    record "$FP"
    echo "The full suite passed — recorded as FULL_SUITE_FP $FP."
fi
exit 0
