#!/bin/bash
# kit-delivered.sh — whether a file is exactly what /sync-dev-kit delivered. Sourced by
# bash-edit-guard.sh and by the gitflow rule-review gate, so a sync's own writes are
# judged in the kit, where they were authored, and never again in the consumer.
#
#   kit_delivered_among <project-root> <path>...
#       prints, one per line and as given, each <path> (absolute, or relative to
#       <project-root>) that has the content `.claude/.kit-sync.json` records for it.
#       One jq and one hasher run cover the whole list, so the cost does not grow with
#       the number of paths: on Windows every process start costs a fraction of a
#       second. Any doubt — no lockfile, no entry, an unreadable lockfile, a missing
#       file, a path containing a newline, a missing guard-lib.sh — leaves that path
#       out, so the caller still judges it.
#
#   is_kit_delivered <project-root> <path>
#       exit 0 when kit_delivered_among names <path>, 1 otherwise.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null

kit_delivered_among() {
    local root lock p rel out line i=0 n
    local -a given=() files=() rels=() wants=() check_given=() check_files=() check_wants=() haves=()
    command -v path_rel_to >/dev/null 2>&1 || return 0
    [ -n "$1" ] || return 0
    root=$(normalize_path "$1"); shift
    lock="$root/.claude/.kit-sync.json"
    [ -f "$lock" ] || return 0
    for p in "$@"; do
        case "$p" in '' | *$'\n'*) continue ;; esac
        rel=$(path_rel_to "$root" "$p") || continue
        [ -f "$root/$rel" ] || continue
        given+=("$p"); rels+=("$rel"); files+=("$root/$rel")
    done
    n=${#rels[@]}
    [ "$n" -gt 0 ] || return 0
    out=$(jq -r '.files as $f | $ARGS.positional[]
                 | ($f[.] | if type == "object" then .sha elif type == "string" then . else empty end) // ""' \
          "$lock" --args "${rels[@]}" 2>/dev/null) || return 0
    while IFS= read -r line; do wants+=("$line"); done <<< "$out"
    [ "${#wants[@]}" -eq "$n" ] || return 0
    while [ "$i" -lt "$n" ]; do
        if [ -n "${wants[$i]}" ]; then
            check_given+=("${given[$i]}"); check_files+=("${files[$i]}"); check_wants+=("${wants[$i]}")
        fi
        i=$((i + 1))
    done
    n=${#check_files[@]}
    [ "$n" -gt 0 ] || return 0
    out=$(sha256_files "${check_files[@]}") || return 0
    while IFS= read -r line; do haves+=("$line"); done <<< "$out"
    [ "${#haves[@]}" -eq "$n" ] || return 0
    i=0
    while [ "$i" -lt "$n" ]; do
        [ "${haves[$i]}" = "${check_wants[$i]}" ] && printf '%s\n' "${check_given[$i]}"
        i=$((i + 1))
    done
    return 0
}

is_kit_delivered() {
    [ -n "$2" ] || return 1
    [ -n "$(kit_delivered_among "$1" "$2")" ]
}

# Run directly — `bash kit-delivered.sh <project-root> <path>...` — it prints what
# kit_delivered_among prints and exits 0, or exits 1 when that is nothing, so a caller
# asking about one path can read the exit status alone. bash-edit-guard.sh calls it
# this way from Python: on Windows, shell text with quotes does not survive Python's
# argv into Git Bash, so the call carries only the script and the values.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    out=$(kit_delivered_among "$@")
    [ -n "$out" ] || exit 1
    printf '%s\n' "$out"
    exit 0
fi
