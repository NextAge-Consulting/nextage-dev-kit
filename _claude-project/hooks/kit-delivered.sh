#!/bin/bash
# kit-delivered.sh — whether a file is exactly what /sync-dev-kit delivered. Sourced by
# bash-edit-guard.sh and by the gitflow rule-review gate, so a sync's own writes are
# judged in the kit, where they were authored, and never again in the consumer.
#
#   is_kit_delivered <project-root> <path>
#       exit 0 when <path> (absolute, or relative to <project-root>) has the content
#       `.claude/.kit-sync.json` records for it. Any doubt — no lockfile, no entry, an
#       unreadable lockfile, a missing file, a missing guard-lib.sh — is exit 1, so the
#       caller still judges it.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh" 2>/dev/null

is_kit_delivered() {
    local root p="$2" lock rel want have
    command -v path_rel_to >/dev/null 2>&1 || return 1
    [ -n "$1" ] && [ -n "$p" ] || return 1
    root=$(normalize_path "$1")
    lock="$root/.claude/.kit-sync.json"
    [ -f "$lock" ] || return 1
    rel=$(path_rel_to "$root" "$p") || return 1
    [ -f "$root/$rel" ] || return 1
    want=$(jq -r --arg f "$rel" '.files[$f] | if type == "object" then .sha elif type == "string" then . else empty end // empty' "$lock" 2>/dev/null) || return 1
    [ -n "$want" ] || return 1
    have=$(sha256_file "$root/$rel") || return 1
    [ "$have" = "$want" ]
}

# Run directly — `bash kit-delivered.sh <project-root> <path>` — it answers by exit
# status, for a caller that cannot source it. bash-edit-guard.sh calls it this way from
# Python: on Windows, shell text with quotes does not survive Python's argv into Git
# Bash, so the call carries only the script and the two values.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    is_kit_delivered "$1" "$2"
    exit
fi
