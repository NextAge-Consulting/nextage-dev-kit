#!/bin/bash
# review-cache.sh — a passed headless review, remembered so an identical re-run skips the
# call. Sourced by rule-review.sh, part-review.sh, design-review.sh, sql-review.sh and
# test-review.sh.
#
# The key is a hash of everything that decides the reviewer's answer: the review script
# itself (its prompt, schema, model and flags), the system prompt and schema as built, and
# the whole input the reviewer is sent — the diff or files under review and every
# reference file folded into it. Change any of them and the key changes. A review whose
# reviewer can read the repository adds to the keyed input the path and content hash of
# every file it is pointed at: test-review.sh every test file, sql-review.sh every drizzle
# config and schema file, part-review.sh every component source file.
#
# Only a clean, parsed answer is recorded. A finding, or a review that could not run, is
# never recorded, so it is asked again every time. The record is the last pass of each
# review, kept under the git dir of the worktree (gitflow-review-cache/<review>), never in
# the tree.

# review_cache_key <work-dir> <script> <system> <schema> <input-file> — prints the key.
review_cache_key() {
    local work="$1" script="$2" system="$3" schema="$4" input="$5"
    { cat "$script" && printf '\0%s\0%s\0' "$system" "$schema" && cat "$input"; } >"$work/cache-key-input" || return 1
    git hash-object --no-filters -- "$work/cache-key-input"
}

# review_cache_path <root> <review> — prints the record's absolute path.
review_cache_path() {
    (cd "$1" && git rev-parse --path-format=absolute --git-path "gitflow-review-cache/$2")
}

# review_cache_hit <root> <review> <key> — succeeds when the last pass of <review> had <key>.
review_cache_hit() {
    local path
    [ -n "$3" ] || return 1
    path=$(review_cache_path "$1" "$2" 2>/dev/null) || return 1
    [ -f "$path" ] && [ "$(cat "$path" 2>/dev/null)" = "$3" ]
}

# review_cache_store <root> <review> <key> — records a pass. A record that cannot be
# written costs only the next run's reuse, so it warns and the review still passes.
review_cache_store() {
    local path
    if [ -n "$3" ] && path=$(review_cache_path "$1" "$2" 2>/dev/null) \
        && mkdir -p "$(dirname "$path")" 2>/dev/null && printf '%s\n' "$3" >"$path" 2>/dev/null; then
        return 0
    fi
    echo "gitflow: $2 passed, but the pass could not be recorded under the git dir — the next run reviews again." >&2
    return 0
}
