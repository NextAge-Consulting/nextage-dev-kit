#!/bin/bash
# guard-lib.sh — what every kit hook needs before it can judge anything. Sourced, never
# run. Written in plain bash (3.2) with no jq or python3, because its first job is to
# say so when those are missing.
#
#   require_tools <event> <tool>...
#       Returns when every tool runs. Otherwise prints the output that <event> uses to
#       stop or flag the action, naming the missing tool and its install line, and
#       exits the hook. A guard that cannot read its input must never allow by default:
#       `jq` missing used to make every guard read an empty tool name and pass.
#       "Runs" means it executed, not that a file of that name is on PATH — Windows
#       ships a `python3` that only prints a pointer to the Microsoft Store.
#       <event>: PreToolUse (deny), PostToolUse (block), anything else (a warning).
#
#   hook_event_of <payload>
#       The payload's hook_event_name, read without jq. Empty when absent.
#
#   path_spelling <path>
#       One spelling per file, touching no file: `\` becomes `/`; `C:/x`, `c:\x`,
#       `/C/x`, `/c/x` and `/cygdrive/c/x` all become `/c/x`; `.` and `..` segments
#       collapse. Use it to match a path against patterns.
#
#   normalize_path <path>
#       path_spelling, then the longest part of the path that exists is resolved
#       through symlinks. Use it to compare two paths that name the same file.
#
#   path_rel_to <root> <path>
#       Prints <path> relative to <root> and returns 0, or returns 1 when <path> lies
#       outside it. A relative <path> is taken as already relative to <root>. Both are
#       compared as written first, then resolved through symlinks, so a project opened
#       through a link and a file named through its target still match.
#
#   sha256_file <file>      sha256_stdin
#       The hex digest, from sha256sum or shasum, whichever this machine has.
#
#   sha256_files <file>...
#       One hex digest per line, in argument order, from a single hasher run. Returns 1
#       when any file is missing or the hasher fails, printing nothing.
#
#   install_hint <tool>
#       The one-line install instruction for <tool> on this platform.
#
# On Windows (Git Bash, MSYS2, Cygwin) a native jq.exe writes CRLF, so `$(jq -r …)`
# ends in a carriage return and no comparison matches. Sourcing this file wraps jq in
# its --binary mode there, which writes LF. That needs jq 1.7 or later; an older jq
# fails the check in require_tools and is reported, rather than misread.

# The kit's Windows check reads $OSTYPE, which bash sets without running anything.
kit_is_windows() {
    case "${OSTYPE:-}" in
        msys*|cygwin*|win32*) return 0 ;;
    esac
    return 1
}

if kit_is_windows; then
    jq() { command jq -b "$@"; }
fi

# JSON string literal for text this file composes. Escapes what a hand-written message
# can contain: backslash, double quote, newline, carriage return, tab.
_kit_json_str() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

install_hint() {
    local os="other"
    kit_is_windows && os="windows"
    case "${OSTYPE:-}" in darwin*) os="macos" ;; linux*) os="linux" ;; esac
    case "$1:$os" in
        jq:macos)        printf '%s' 'brew install jq' ;;
        jq:windows)      printf '%s' 'winget install jqlang.jq (jq 1.7 or later)' ;;
        jq:linux)        printf '%s' 'install the jq package (sudo apt install jq, sudo dnf install jq)' ;;
        python3:macos)   printf '%s' 'brew install python' ;;
        python3:windows) printf '%s' 'winget install Python.Python.3.12, then turn off the python3 App execution alias (Settings > Apps > Advanced app settings > App execution aliases) and make python3 run the installed Python' ;;
        python3:linux)   printf '%s' 'install the python3 package (sudo apt install python3, sudo dnf install python3)' ;;
        *)               printf 'install %s and put it on PATH' "$1" ;;
    esac
}

# 0 when the tool actually runs and answers, not merely when a file of that name exists.
_kit_tool_works() {
    local out
    case "$1" in
        jq)
            command -v jq >/dev/null 2>&1 || return 1
            out=$(printf '1' | jq . 2>/dev/null) || return 1 ;;
        python3)
            command -v python3 >/dev/null 2>&1 || return 1
            out=$(python3 -c 'print(1)' 2>/dev/null) || return 1 ;;
        *)
            command -v "$1" >/dev/null 2>&1
            return ;;
    esac
    out=${out%$'\r'}
    [ "$out" = "1" ]
}

# A passing check is remembered for this PATH, so a session pays for it once rather
# than on every tool call. toolchain-check.sh clears the record at session start.
_kit_tools_marker() {
    local sum
    sum=$(printf '%s|%s' "$PATH" "$*" | cksum)
    printf '%s/kit-toolchain-ok-%s-%s' "${TMPDIR:-/tmp}" "${UID:-0}" "${sum%% *}"
}

kit_clear_tool_markers() {
    rm -f "${TMPDIR:-/tmp}"/kit-toolchain-ok-"${UID:-0}"-* 2>/dev/null
    return 0
}

# Prints the names of the tools that do not run, space-separated. Empty when all do.
missing_tools() {
    local t missing=""
    for t in "$@"; do
        _kit_tool_works "$t" || missing="$missing $t"
    done
    printf '%s' "${missing# }"
}

require_tools() {
    local event="$1"; shift
    local marker missing t msg=""
    marker=$(_kit_tools_marker "$@")
    [ -f "$marker" ] && return 0
    missing=$(missing_tools "$@")
    if [ -z "$missing" ]; then
        : > "$marker" 2>/dev/null
        return 0
    fi
    for t in $missing; do
        msg="$msg
  - $t: $(install_hint "$t")"
    done
    msg="This project's guard ${0##*/} cannot run: $missing is missing or does not work in the shell Claude Code started with. Every guard that needs it refuses actions until it is installed.
${msg}
Then restart Claude Code, because hooks use the PATH it started with. Tell the human exactly this; do not work around the guard."
    case "$event" in
        PreToolUse)
            printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$(_kit_json_str "$msg")" ;;
        PostToolUse)
            printf '{"decision":"block","reason":%s}\n' "$(_kit_json_str "$msg")" ;;
        *)
            printf '{"systemMessage":%s}\n' "$(_kit_json_str "$msg")" ;;
    esac
    exit 0
}

hook_event_of() {
    local re='"hook_event_name"[[:space:]]*:[[:space:]]*"([A-Za-z]+)"'
    if [[ $1 =~ $re ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

_kit_lower_letter() {
    local up=ABCDEFGHIJKLMNOPQRSTUVWXYZ low=abcdefghijklmnopqrstuvwxyz head
    head=${up%%"$1"*}
    if [ ${#head} -lt 26 ]; then printf '%s' "${low:${#head}:1}"; else printf '%s' "$1"; fi
}

# Spelling only: separators, drive letters, `.` and `..`. Touches no file.
path_spelling() {
    local p="$1" d rest out seg abs=0
    p=${p//\\//}
    case "$p" in
        /cygdrive/[A-Za-z]|/cygdrive/[A-Za-z]/*) p=${p#/cygdrive} ;;
    esac
    case "$p" in
        [A-Za-z]:|[A-Za-z]:/*)
            d=$(_kit_lower_letter "${p:0:1}"); rest=${p:2}; p="/$d$rest" ;;
        /[A-Za-z]|/[A-Za-z]/*)
            d=$(_kit_lower_letter "${p:1:1}"); rest=${p:2}; p="/$d$rest" ;;
    esac
    case "$p" in /*) abs=1 ;; esac
    out=""
    rest="$p"
    while [ -n "$rest" ]; do
        seg=${rest%%/*}
        case "$rest" in */*) rest=${rest#*/} ;; *) rest="" ;; esac
        case "$seg" in
            ''|.) ;;
            ..)
                if [ -n "$out" ] && [ "${out##*/}" != ".." ]; then
                    case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac
                elif [ "$abs" -eq 0 ]; then
                    out="${out:+$out/}.."
                fi ;;
            *) out="${out:+$out/}$seg" ;;
        esac
    done
    if [ "$abs" -eq 1 ]; then printf '/%s' "$out"; else printf '%s' "${out:-.}"; fi
}

# Resolves the longest existing prefix through symlinks (pwd -P), keeping the rest.
_kit_physical_path() {
    local p="$1" head tail="" resolved
    head="$p"
    while [ -n "$head" ] && [ ! -d "$head" ]; do
        case "$head" in
            */*) tail="${head##*/}${tail:+/$tail}"; head="${head%/*}" ;;
            *)   tail="$head${tail:+/$tail}"; head="" ;;
        esac
    done
    if [ -z "$head" ]; then
        case "$p" in /*) head="/" ;; *) head="." ;; esac
    fi
    resolved=$(cd -P -- "$head" 2>/dev/null && pwd -P) || { printf '%s' "$p"; return; }
    resolved=$(path_spelling "$resolved")
    if [ -z "$tail" ]; then printf '%s' "$resolved"
    elif [ "$resolved" = "/" ]; then printf '/%s' "$tail"
    else printf '%s/%s' "$resolved" "$tail"
    fi
}

normalize_path() {
    local p
    p=$(path_spelling "$1")
    _kit_physical_path "$p"
}

_kit_under() {  # <root> <path> → prints the relative part, or returns 1
    local root="${1%/}" p="$2"
    [ "$p" = "$root" ] && return 1
    case "$p" in
        "$root"/*) printf '%s' "${p#"$root"/}"; return 0 ;;
    esac
    return 1
}

path_rel_to() {
    local root="$1" p="$2" lr lp
    [ -n "$root" ] && [ -n "$p" ] || return 1
    lp=$(path_spelling "$p")
    case "$lp" in
        /*) ;;
        ..|../*) return 1 ;;
        .) return 1 ;;
        *) printf '%s' "$lp"; return 0 ;;
    esac
    lr=$(path_spelling "$root")
    _kit_under "$lr" "$lp" && return 0
    _kit_under "$(_kit_physical_path "$lr")" "$(_kit_physical_path "$lp")"
}

sha256_stdin() {
    local out
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum)
    else
        out=$(shasum -a 256)
    fi
    printf '%s' "${out%% *}"
}

sha256_file() {
    [ -f "$1" ] || return 1
    sha256_stdin < "$1"
}

sha256_files() {
    local f out line
    [ "$#" -gt 0 ] || return 0
    for f in "$@"; do [ -f "$f" ] || return 1; done
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum -- "$@") || return 1
    else
        out=$(shasum -a 256 -- "$@") || return 1
    fi
    # GNU marks a line whose file name it escaped with a leading backslash.
    while IFS= read -r line; do
        line=${line%% *}
        printf '%s\n' "${line#\\}"
    done <<< "$out"
}
