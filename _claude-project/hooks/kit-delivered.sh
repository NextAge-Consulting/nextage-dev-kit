#!/bin/bash
# kit-delivered.sh — whether a file is exactly what the kit ships. Sourced by
# bash-edit-guard.sh and by the gitflow rule-review gate, so a kit file's text is judged
# in the kit, where it was authored, and never again in the consumer.
#
#   kit_delivered_among <project-root> <path>...
#       prints, one per line and as given, each <path> (absolute, or relative to
#       <project-root>) that has the content `.claude/.kit-sync.json` records for it, or
#       that is byte-identical to the same file in the kit clone `devKitPath` names in
#       ~/.claude/dev-kit-config.json — a kit file copied in before any sync recorded it,
#       as the kit-sync setup does. Never inside the kit itself, where its files are
#       authored. Each source costs one jq and one hasher run for the whole list, so the
#       cost does not grow with the number of paths: on Windows every process start costs
#       a fraction of a second. Any doubt — no record and no identical kit file, an
#       unreadable lockfile or config, a missing file, a path containing a newline, a
#       missing guard-lib.sh — leaves that path out, so the caller still judges it.
#
#   is_kit_delivered <project-root> <path>
#       exit 0 when kit_delivered_among names <path>, 1 otherwise.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null

kit_delivered_among() {
    local root lock p rel out line i=0 n kit kitrel config
    local -a given=() files=() rels=() wants=() hit=() haves=() idx=() check_files=() check_wants=()
    command -v path_rel_to >/dev/null 2>&1 || return 0
    [ -n "$1" ] || return 0
    root=$(normalize_path "$1"); shift
    for p in "$@"; do
        case "$p" in '' | *$'\n'*) continue ;; esac
        rel=$(path_rel_to "$root" "$p") || continue
        [ -f "$root/$rel" ] || continue
        given+=("$p"); rels+=("$rel"); files+=("$root/$rel"); hit+=(0)
    done
    n=${#rels[@]}
    [ "$n" -gt 0 ] || return 0

    # 1. The lockfile's record of what sync wrote.
    lock="$root/.claude/.kit-sync.json"
    if [ -f "$lock" ] && out=$(jq -r '.files as $f | $ARGS.positional[]
                 | ($f[.] | if type == "object" then .sha elif type == "string" then . else empty end) // ""' \
          "$lock" --args "${rels[@]}" 2>/dev/null); then
        wants=()
        while IFS= read -r line; do wants+=("$line"); done <<< "$out"
        if [ "${#wants[@]}" -eq "$n" ]; then
            idx=(); check_files=(); check_wants=()
            for ((i = 0; i < n; i++)); do
                [ -n "${wants[$i]}" ] || continue
                idx+=("$i"); check_files+=("${files[$i]}"); check_wants+=("${wants[$i]}")
            done
            if [ "${#idx[@]}" -gt 0 ] && out=$(sha256_files "${check_files[@]}"); then
                haves=()
                while IFS= read -r line; do haves+=("$line"); done <<< "$out"
                if [ "${#haves[@]}" -eq "${#idx[@]}" ]; then
                    for ((i = 0; i < ${#idx[@]}; i++)); do
                        [ "${haves[$i]}" = "${check_wants[$i]}" ] && hit[${idx[$i]}]=1
                    done
                fi
            fi
        fi
    fi

    # 2. The kit clone's own copy, for a kit file no sync has recorded yet.
    config="$HOME/.claude/dev-kit-config.json"
    if [ -f "$config" ] && kit=$(jq -r '.devKitPath // empty' "$config" 2>/dev/null) && [ -n "$kit" ] && [ -d "$kit" ]; then
        kit=$(normalize_path "$kit")
        if [ "$kit" != "$root" ]; then
            idx=(); check_files=()
            for ((i = 0; i < n; i++)); do
                [ "${hit[$i]}" = 0 ] || continue
                case "${rels[$i]}" in
                    .claude/*) kitrel="_claude-project/${rels[$i]#.claude/}" ;;
                    .github/*) kitrel="_github-project/${rels[$i]#.github/}" ;;
                    .gemini/*) kitrel="_gemini-project/${rels[$i]#.gemini/}" ;;
                    *) continue ;;
                esac
                [ -f "$kit/$kitrel" ] || continue
                idx+=("$i"); check_files+=("${files[$i]}" "$kit/$kitrel")
            done
            if [ "${#idx[@]}" -gt 0 ] && out=$(sha256_files "${check_files[@]}"); then
                haves=()
                while IFS= read -r line; do haves+=("$line"); done <<< "$out"
                if [ "${#haves[@]}" -eq "${#check_files[@]}" ]; then
                    for ((i = 0; i < ${#idx[@]}; i++)); do
                        [ "${haves[$((2 * i))]}" = "${haves[$((2 * i + 1))]}" ] && hit[${idx[$i]}]=1
                    done
                fi
            fi
        fi
    fi

    for ((i = 0; i < n; i++)); do
        [ "${hit[$i]}" = 1 ] && printf '%s\n' "${given[$i]}"
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
