#!/usr/bin/env bash
# The kit's pre-ship gate. The gitflow gates run it on /commit and /ship-main
# (run_project_gate). It meets the files changed since <base> the way a consumer's CI
# and gates will after they sync: syntax, semgrep, the suites beside each changed file,
# and the changed project-facing checks replayed against every consumer on this machine.
#
#   bash .claude/project-gate.sh <base>
#
# Exits 0 when every step passes, 1 otherwise. A step with nothing to check says so.

set -u

# The suites covering one changed kit path, printed one per line, existing or not. A
# dogfood copy under .claude/ is covered by its _claude-project source's suites.
suites_for() {
    local f="$1" src
    case "$f" in
        .claude/*)
            src="_claude-project/${f#.claude/}"
            [ -e "$src" ] && f="$src"
            ;;
    esac
    case "$f" in
        *.test.mjs | *.test.sh)
            echo "$f"
            return
            ;;
        _claude-project/stack-manifest.json)
            echo "tests/templates/check-stack.test.sh"
            return
            ;;
        _claude-project/templates/scripts/*.mjs)
            echo "tests/templates/$(basename "$f" .mjs).test.sh"
            ;;
    esac
    case "$f" in
        *.mjs | *.js)
            echo "${f%.*}.test.mjs"
            echo "${f%.*}.test.sh"
            ;;
        *.sh) echo "${f%.sh}.test.sh" ;;
    esac
}

run_suite() {
    case "$1" in
        *.test.mjs) node --test "$1" ;;
        *.test.sh) bash "$1" ;;
    esac
}

main() {
    local base="${1:-}" list out f fails=0 n syntax=0
    if [ -z "$base" ]; then
        echo "project gate: usage: project-gate.sh <base>" >&2
        return 1
    fi
    list=$(mktemp)
    if ! { git diff --name-only --diff-filter=d "$base" && git ls-files --others --exclude-standard; } >"$list"; then
        echo "project gate: cannot list the files changed since $base." >&2
        rm -f "$list"
        return 1
    fi
    sort -u -o "$list" "$list"
    n=$(grep -c . "$list")
    if [ "$n" -eq 0 ]; then
        echo "project gate: no files changed since $base — nothing to check." >&2
        rm -f "$list"
        return 0
    fi
    echo "project gate: $n changed file(s) since $base." >&2

    # Syntax.
    while IFS= read -r f; do
        case "$f" in
            *.mjs | *.js) out=$(node --check "$f" 2>&1) ;;
            *.sh) out=$(bash -n "$f" 2>&1) ;;
            *.json) out=$(jq empty "$f" 2>&1) ;;
            *) continue ;;
        esac || {
            printf 'project gate: syntax: %s\n%s\n' "$f" "$out" >&2
            fails=1
        }
        syntax=$((syntax + 1))
    done <"$list"
    echo "project gate: syntax: $syntax file(s) checked." >&2

    # Semgrep, as a consumer's CI runs it.
    # shellcheck source=.claude/skills/gitflow/scripts/gates.sh
    source .claude/skills/gitflow/scripts/gates.sh
    local includes=() code=0
    while IFS= read -r f; do
        case "$f" in
            *.mjs | *.js | *.ts | *.tsx | *.sh | *.py | *.yml | *.yaml)
                includes+=(--include "$(semgrep_include_pattern "$f")")
                code=$((code + 1))
                ;;
        esac
    done <"$list"
    if [ "$code" -eq 0 ]; then
        echo "project gate: semgrep: no changed code files." >&2
    elif ! command -v semgrep >/dev/null 2>&1; then
        echo "project gate: semgrep is not installed — brew install semgrep." >&2
        fails=1
    elif ! out=$(semgrep scan --config auto --error "${includes[@]}" . 2>&1); then
        printf 'project gate: semgrep findings:\n%s\n' "$out" >&2
        fails=1
    else
        echo "project gate: semgrep: $code changed code file(s), no findings." >&2
    fi

    # The suites beside the changed files.
    local suites
    suites=$(while IFS= read -r f; do suites_for "$f"; done <"$list" | sort -u | while IFS= read -r s; do [ -f "$s" ] && echo "$s"; done)
    if [ -z "$suites" ]; then
        echo "project gate: suites: none beside the changed files." >&2
    else
        while IFS= read -r s; do
            if out=$(run_suite "$s" 2>&1); then
                echo "project gate: suite passed: $s" >&2
            else
                printf 'project gate: suite FAILED: %s\n%s\n' "$s" "$out" | tail -40 >&2
                fails=1
            fi
        done <<<"$suites"
    fi

    # The changed project-facing checks, replayed against every consumer.
    local changed=()
    while IFS= read -r f; do changed+=("$f"); done < <({ git diff --name-only "$base" && git ls-files --others --exclude-standard; } | sort -u)
    node .claude/kit-gate/replay.mjs "${changed[@]}" >&2 || fails=1

    rm -f "$list"
    if [ "$fails" -ne 0 ]; then
        echo "project gate: FAILED." >&2
        return 1
    fi
    echo "project gate: passed." >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    cd "$(git rev-parse --show-toplevel)" || exit 1
    main "$@"
fi
