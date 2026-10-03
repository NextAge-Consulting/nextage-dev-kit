#!/bin/bash
# toolchain-check.sh — SessionStart, wired first. Checks, once per session, what the
# kit's guards and gates need from this machine, and tells the human and Claude when
# something is missing. Plain bash only: it runs before anything proves jq or python3.
#
#   1. jq and python3 actually run (`jq .`, `python3 -c 'print(1)'`). Without them
#      every guard refuses the actions it covers (guard-lib.sh require_tools), so the
#      warning names the tool, this platform's install line, and that Claude Code must
#      be restarted: hooks use the PATH Claude Code started with.
#   2. The commit gate can typecheck: a package.json in a repository with TypeScript
#      sources carries a `check-types` script, and a project with a root
#      pyproject.toml or pyrightconfig.json has pyright or mypy on PATH.
#   3. Windows only, once per change to .gitattributes: every tracked file the
#      attributes want LF, whose disk copy is CRLF and otherwise identical to Git's, is
#      rewritten from Git. A file with real edits is listed and left alone. The marker
#      `kit-eol-checked` in the git dir holds the .gitattributes hash last handled.
#
# It also clears guard-lib.sh's record of passing checks, so each session's guards
# re-check the tools once.
#
# Sourcing this file defines the checks without running them (the suite does that).

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=guard-lib.sh
source "$HOOK_DIR/guard-lib.sh"

# Prints one line per missing tool, for the human.
check_tools() {
    local missing t
    missing=$(missing_tools jq python3)
    [ -n "$missing" ] || return 0
    for t in $missing; do
        printf '%s is missing or does not run in the shell Claude Code started with. Install it: %s.\n' "$t" "$(install_hint "$t")"
    done
}

# Whether <root> holds TypeScript of its own, as the commit gate asks it (gitflow
# gates.sh has_typescript_sources). Outside a git repository the answer is yes.
has_typescript_sources() {
    local files own
    files=$(git -C "$1" ls-files --cached --others --exclude-standard -- '*.ts' '*.tsx' '*.mts' '*.cts' 2>/dev/null) || return 0
    # An empty list needs no early return: $(…) strips the lone newline, so own is empty.
    own=$(printf '%s\n' "$files" | grep -vE '(^|/)(node_modules|\.claude|dist)/' | grep -vxF 'knip.config.ts')
    [ -n "$own" ]
}

# Whether <package.json> declares a `check-types` script — the scripts key itself, never
# the string anywhere in the file (a dependency name, a description, another script).
# Without jq, check_tools already reports it missing; the text match stands in.
has_check_types_script() {
    if command -v jq >/dev/null 2>&1; then
        jq -e '(.scripts // {}) | has("check-types")' "$1" >/dev/null 2>&1
    else
        grep -q '"check-types"[[:space:]]*:' "$1" 2>/dev/null
    fi
}

# Prints one line per gap in what the commit gate needs to typecheck <root>. Node and
# Python are checked independently, as the gate checks them (gitflow gates.sh).
check_typecheck() {
    local root="$1"
    if [ -f "$root/package.json" ] && ! has_check_types_script "$root/package.json" &&
        has_typescript_sources "$root"; then
        printf '%s\n' "package.json has no \"check-types\" script, so /commit and /ship-main fail their typecheck. Add one, e.g. \"check-types\": \"tsc --noEmit\"."
    fi
    if { [ -f "$root/pyproject.toml" ] || [ -f "$root/pyrightconfig.json" ]; } &&
        ! command -v pyright >/dev/null 2>&1 && ! command -v mypy >/dev/null 2>&1; then
        printf '%s\n' "Python is configured here (pyproject.toml or pyrightconfig.json) but neither pyright nor mypy is on PATH, so /commit and /ship-main fail their typecheck. Install one (pip install pyright)."
    fi
}

# Rewrites from Git each tracked file the attributes want LF whose disk copy differs
# from Git's only in line endings. Prints one summary line when it scanned.
refresh_line_endings() {
    local root="$1" marker attrs info path n_fixed=0 kept="" n_kept=0
    local candidates=() edited=() fix=() e is_edited
    [ -f "$root/.gitattributes" ] || return 0
    marker=$(git -C "$root" rev-parse --git-path kit-eol-checked 2>/dev/null) || return 0
    case "$marker" in /*|[A-Za-z]:*) ;; *) marker="$root/$marker" ;; esac
    attrs=$(git -C "$root" hash-object -- .gitattributes 2>/dev/null) || return 0
    [ -f "$marker" ] && [ "$(cat "$marker" 2>/dev/null)" = "$attrs" ] && return 0

    # Index LF, disk CRLF (or mixed), attributes asking for LF.
    while IFS= read -r -d '' rec; do
        info=${rec%%$'\t'*}; path=${rec#*$'\t'}
        case "$info" in *i/lf*) ;; *) continue ;; esac
        case "$info" in *w/crlf*|*w/mixed*) ;; *) continue ;; esac
        case "$info" in *eol=lf*) ;; *) continue ;; esac
        candidates+=("$path")
    done < <(git -C "$root" ls-files --eol -z 2>/dev/null)

    if [ ${#candidates[@]} -gt 0 ]; then
        # git diff compares through the attributes, so a file that differs only in line
        # endings is not listed; whatever it lists has real edits.
        while IFS= read -r -d '' path; do
            edited+=("$path")
        done < <(git -C "$root" diff --name-only -z -- "${candidates[@]}" 2>/dev/null)
        for path in "${candidates[@]}"; do
            is_edited=0
            for e in ${edited[@]+"${edited[@]}"}; do
                [ "$e" = "$path" ] && { is_edited=1; break; }
            done
            if [ "$is_edited" -eq 1 ]; then
                n_kept=$((n_kept + 1)); kept="$kept${kept:+, }$path"
            else
                fix+=("$path")
            fi
        done
        if [ ${#fix[@]} -gt 0 ]; then
            if printf '%s\0' "${fix[@]}" | git -C "$root" checkout-index -f -u -z --stdin 2>/dev/null; then
                n_fixed=${#fix[@]}
            else
                printf 'Line endings: rewriting %s file(s) from Git failed; nothing is marked done, so the next session tries again.\n' "${#fix[@]}"
                return 0
            fi
        fi
    fi

    printf '%s' "$attrs" > "$marker" 2>/dev/null
    printf 'Line endings checked against .gitattributes: %s file(s) rewritten from Git (CRLF on disk, otherwise identical); %s file(s) CRLF with real edits, not refreshed%s\n' \
        "$n_fixed" "$n_kept" "${kept:+: $kept}"
}

main() {
    local root user="" claude="" tools typecheck eol
    cat >/dev/null   # the SessionStart payload carries nothing this check needs
    root=$(normalize_path "${CLAUDE_PROJECT_DIR:-$PWD}")
    kit_clear_tool_markers

    tools=$(check_tools)
    if [ -n "$tools" ]; then
        user="$tools
Then restart Claude Code. Until then the project's guards refuse every action they cover."
        claude="The kit's guards cannot run in this session: $(printf '%s' "$tools" | tr '\n' ' ')Every tool call those guards cover will be refused until it is installed and Claude Code is restarted. Tell the human this at the start of your first reply."
    fi

    typecheck=$(check_typecheck "$root")
    if [ -n "$typecheck" ]; then
        user="${user:+$user
}$typecheck"
        claude="${claude:+$claude }$typecheck"
    fi

    if kit_is_windows; then
        eol=$(refresh_line_endings "$root")
        if [ -n "$eol" ]; then
            user="${user:+$user
}$eol"
            claude="${claude:+$claude }$eol"
        fi
    fi

    [ -n "$user" ] || exit 0
    printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
        "$(_kit_json_str "⚠️ $user")" "$(_kit_json_str "$claude")"
    exit 0
}

# `return` succeeds only in a sourced file, so this runs main only when executed.
(return 0 2>/dev/null) || main "$@"
