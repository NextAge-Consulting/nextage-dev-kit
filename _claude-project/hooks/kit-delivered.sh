#!/bin/bash
# kit-delivered.sh — whether a file is exactly what /sync-dev-kit delivered. Sourced by
# bash-edit-guard.sh and by the gitflow rule-review gate, so a sync's own writes are
# judged in the kit, where they were authored, and never again in the consumer.
#
#   is_kit_delivered <project-root> <path>
#       exit 0 when <path> (absolute, or relative to <project-root>) has the content
#       `.claude/.kit-sync.json` records for it. Any doubt — no lockfile, no entry, an
#       unreadable lockfile, a missing file — is exit 1, so the caller still judges it.

is_kit_delivered() {
    local root="$1" p="$2" lock rel want have
    lock="$root/.claude/.kit-sync.json"
    [ -n "$root" ] && [ -n "$p" ] && [ -f "$lock" ] || return 1
    case "$p" in
        /*) ;;
        *) p="$root/$p" ;;
    esac
    [ -f "$p" ] || return 1
    rel="${p#"$root"/}"
    want=$(jq -r --arg f "$rel" '.files[$f] | if type == "object" then .sha elif type == "string" then . else empty end // empty' "$lock" 2>/dev/null) || return 1
    [ -n "$want" ] || return 1
    have=$(shasum -a 256 "$p" | awk '{print $1}')
    [ "$have" = "$want" ]
}
