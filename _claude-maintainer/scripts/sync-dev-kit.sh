#!/bin/bash
# Sync Dev Kit — three-way diff/review sync from kit template to consumer project.
#
# Modes:
#   --scan                  Output JSON report of state per file. Non-interactive.
#   --apply-file <kit-rel>  Apply one kit file to project + update lockfile entry.
#   --decline-file <kit-rel> Record that this project does NOT want the file. It stops
#                           being offered until the KIT changes it again.
#   --ack-file <kit-rel>    Record the kit's current content as the baseline WITHOUT
#                           writing the project file — after a conflict was resolved
#                           by hand, so the next scan sees the kit as incorporated.
#   --remove-patch <dest>   Drop a destination's entry from .claude/.kit-patches.json once
#                           the patch it sanctioned is gone. Prints the entry removed, so
#                           the caller can close its project issue.
#   --apply-gitignore       Append missing .gitignore-additions entries to project .gitignore.
#   --finalize              Update lockfile kit commit SHA + timestamp after all decisions applied.
#
# Claude invokes --scan, reviews the report interactively with the user, invokes
# --apply-file for each accepted change, then invokes --finalize at the end.
#
# Lockfile: .claude/.kit-sync.json in the consumer project (committed).

set -e

MODE=""
APPLY_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --scan)             MODE="scan"; shift 1 ;;
        --apply-file)       MODE="apply"; APPLY_FILE="$2"; shift 2 ;;
        --ack-file)         MODE="ack"; APPLY_FILE="$2"; shift 2 ;;
        --decline-file)     MODE="decline"; APPLY_FILE="$2"; shift 2 ;;
        --remove-patch)     MODE="remove-patch"; APPLY_FILE="$2"; shift 2 ;;
        --apply-gitignore)  MODE="apply-gitignore"; shift 1 ;;
        --finalize)         MODE="finalize"; shift 1 ;;
        *) echo "sync-dev-kit.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "sync-dev-kit.sh: mode required (--scan | --apply-file <path> | --ack-file <path> | --decline-file <path> | --remove-patch <dest> | --apply-gitignore | --finalize)" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Locate kit
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.claude/dev-kit-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "sync-dev-kit.sh: $CONFIG_FILE missing. See kitmaintainer-handbook.md §0.1 (maintainer machine setup)." >&2
    exit 3
fi

KIT_PATH=$(jq -r '.kit_path // .devKitPath // empty' "$CONFIG_FILE")
if [ -z "$KIT_PATH" ] || [ ! -d "$KIT_PATH/_claude-project" ]; then
    echo "sync-dev-kit.sh: invalid kit path: $KIT_PATH" >&2
    exit 3
fi

PROJECT_PATH="${PWD}"

# Sync runs on whatever branch you are standing on, mid-feature included.
#
# There is deliberately NO on-main requirement. Sync does NO git at all: it
# applies kit updates to the working tree and stamps the lockfile, leaving the
# changes uncommitted for the user to land with any commit path. The lockfile
# records the KIT's SHAs, so applying on a feature branch stamps exactly the
# values it would on main — and if that branch is abandoned, the stamp is
# discarded along with the files it describes. Consistent either way.
#
# Running mid-feature is the POINT. A rule you fix while working is live in
# context for the rest of that session instead of stranded until a merge. And
# kit updates riding the same commit as product work is the house model (one
# body of work, one PR — rules/git.md), not something to guard against.
# See kitmaintainer-handbook.md §9 for the design rationale.

# Refuse to run from inside the kit itself
if [ "$PROJECT_PATH" = "$KIT_PATH" ]; then
    echo "sync-dev-kit.sh: running from the kit repo itself is not supported." >&2
    echo "  To update the maintainer surface in ~/.claude/, edit it and the kit source together." >&2
    exit 4
fi

LOCKFILE="${PROJECT_PATH}/.claude/.kit-sync.json"
# The maintainer surface (`_claude-maintainer/` → ~/.claude/) is not scanned here;
# it is hand-propagated. Consumers receive nothing globally at all.
# Project-owned rules under `_claude-project/rules/project/` are matched by pattern
# below (is_skipped function), not by explicit list.
SKIP_LIST=(
    "_claude-project/templates/README.md"
    # Kit-internal documentation ABOUT the testing templates, for someone
    # reading the kit. The files themselves sync (kit-owned, destination
    # from SHARED_MODULE_DIR); this file explaining them would land in the
    # consumer's test directory, where it is noise.
    "_claude-project/templates/testing/README.md"
    # sync-substitutions.json is project-specific from the moment it's filled
    # in; every project's values differ, so kit's empty-template version
    # always conflicts after first sync. Skip unconditionally. First-time
    # bootstrap (copying the template) is handled below, on first sync.
    "_claude-project/sync-substitutions.json"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sha256() {
    [ -f "$1" ] || { echo ""; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# ─── Substitutions (project-specific placeholder resolution) ───────────────
# Kit templates use `{{KEY}}` markers for values that are project-specific
# (org name, repo slug, etc.). Consumer projects define
# the actual values in `.claude/sync-substitutions.json`:
#
#   {
#     "ORG": "acme"
#   }
#
# sync-dev-kit applies these substitutions to kit content in two places:
#   1. During scan — computes kit SHA against substituted content, so a kit
#      template with `{{ORG}}` matching a project file with `acme`
#      reports `clean`, not `conflict`.
#   2. During apply — writes substituted content into the project, so the
#      project file on disk has real values, not placeholders.
#
# Missing substitutions file OR missing individual keys → no substitution
# for that token → kit content used as-is. Behavior is identical to the
# pre-substitution version of this script when no substitutions file exists
# (backward compat hard requirement).
SUBSTITUTIONS_JSON="{}"

load_substitutions() {
    local sub_file="${PROJECT_PATH}/.claude/sync-substitutions.json"
    local kit_template="${KIT_PATH}/_claude-project/sync-substitutions.json"

    # Bootstrap on first sync: the substitutions file is in SKIP_LIST (so
    # /sync-dev-kit never overwrites consumer values once populated),
    # and nothing else populates it either. Without bootstrap, every
    # consumer project ends up missing the file entirely and kit templates
    # land with literal {{KEY}} markers. Copy the kit template on first
    # encounter; subsequent runs see the file exists and skip bootstrap.
    # The template ships with empty values, which is the explicit "feature
    # disabled" state for every gated placeholder (e.g. GITFLOW_*).
    if [ ! -f "$sub_file" ] && [ -f "$kit_template" ]; then
        mkdir -p "$(dirname "$sub_file")"
        cp "$kit_template" "$sub_file"
        echo "sync-dev-kit.sh: bootstrapped .claude/sync-substitutions.json from kit template (populate values to override placeholders, leave empty to disable gated features)" >&2
    fi

    # Additive key merge — the kit owns the KEY SET, the consumer owns the VALUES.
    #
    # kitmaintainer-handbook.md §9.7 "Adding a new placeholder" step 6 assumed a new kit key reaches
    # existing consumers because this file syncs as a `kit-only` diff. It does not:
    # the file is in SKIP_LIST (every project's values differ, so the kit's empty
    # template would conflict forever after first sync), so that delivery path does
    # not exist and bootstrap only ever fires on a project that lacks the file. A
    # key added to the kit AFTER a project bootstrapped therefore never arrived.
    # Canonical `{{KEY}}` placeholders at least nagged — the unsubstituted marker
    # survived into the synced file as a standing diff. Runtime-read keys (read via
    # `jq` at execution time, never substituted into any template — AWS_*, and see
    # kitmaintainer-handbook.md §9.7 "Runtime-read placeholders") have no marker anywhere, so they
    # failed SILENTLY: the rule that reads them shipped, its config surface did not.
    #
    # Merging only keys the consumer LACKS restores step 6's intent without
    # resurrecting the conflict problem. New keys land carrying the kit's empty
    # default, i.e. empty + absent from `_intentionally_empty` — the "deferred
    # decision" state that the §9.8 walkthrough re-surfaces every sync until the
    # user populates or explicitly disables it.
    #
    # Exactly two things in this file are the consumer's; everything else is the
    # kit's and syncs like any other kit content:
    #   - VALUES for non-`_` keys        — the project's real strings. Consumer wins.
    #   - `_intentionally_empty`         — the project's list of deliberately-blank
    #                                      keys. That's DATA, not prose. Consumer wins.
    # Every other `_` key is a COMMENT BLOCK the kit authors (`_comment`,
    # `_placeholders_referenced_by_kit`, `_documented_behavior`,
    # `_intentionally_empty_doc`). They are documentation of kit-owned settings and
    # are overwritten from the kit on every sync. Do NOT add "preserve consumer
    # prose" logic here: nothing but an AI has ever written these, they describe the
    # kit's own settings, and letting them drift per-project is what left this file
    # documenting 8 settings while the kit shipped 15 — the stale copy then misleads
    # the next reader. Project-specific prose does not belong in a kit comment block.
    if [ -f "$sub_file" ] && [ -f "$kit_template" ]; then
        local merged added
        if merged=$(jq -s '
            .[0] as $kit | .[1] as $proj
            | ($kit  | with_entries(select(.key | startswith("_") | not))) as $kitvals
            | ($proj | with_entries(select(.key | startswith("_") | not))) as $projvals
            | ($kit  | with_entries(select(.key | startswith("_"))))       as $kitnotes
            | ($kitvals + $projvals)
              + $kitnotes
              + (if ($proj | has("_intentionally_empty"))
                 then { _intentionally_empty: $proj._intentionally_empty }
                 else {} end)
        ' "$kit_template" "$sub_file" 2>/dev/null) && [ -n "$merged" ]; then
            if [ "$(jq -S . <<<"$merged" 2>/dev/null)" != "$(jq -S . "$sub_file" 2>/dev/null)" ]; then
                added=$(jq -r -s '
                    (.[0] | keys_unsorted | map(select(startswith("_") | not))) as $kit
                    | (.[1] | keys_unsorted) as $proj
                    | ($kit - $proj) | join(", ")
                ' "$kit_template" "$sub_file" 2>/dev/null)
                printf '%s\n' "$merged" > "$sub_file"
                if [ -n "$added" ]; then
                    echo "sync-dev-kit.sh: added new kit placeholder key(s) to .claude/sync-substitutions.json: ${added} — Step 1.5 will walk you through populating them" >&2
                else
                    echo "sync-dev-kit.sh: refreshed kit comment blocks in .claude/sync-substitutions.json (values and _intentionally_empty untouched)" >&2
                fi
            fi
        fi
    fi

    if [ -f "$sub_file" ]; then
        if ! SUBSTITUTIONS_JSON=$(jq -c '. // {}' "$sub_file" 2>/dev/null); then
            echo "sync-dev-kit.sh: warning — could not parse $sub_file, proceeding without substitutions" >&2
            SUBSTITUTIONS_JSON="{}"
        fi
    else
        SUBSTITUTIONS_JSON="{}"
    fi
}

# apply_substitutions — reads stdin, applies {{KEY}} → value for every non-empty
# entry in SUBSTITUTIONS_JSON, writes to stdout. Uses `sed` so the byte stream
# is preserved exactly (including trailing newlines). Earlier bash parameter-
# expansion version via $(cat) stripped trailing newlines on the round trip,
# which corrupted kit SHAs even on the no-substitution fast path.
#
# Filter rules for SUBSTITUTIONS_JSON entries:
#   - Skip keys starting with `_` (reserved for JSON metadata / inline docs,
#     e.g. `_comment`, `_placeholders_referenced_by_kit`).
#   - Skip values that are null (key absent intent — leave {{KEY}} visible
#     so the consumer is prompted to configure it).
#   - Empty string is a VALID substitution: `{{KEY}}` → empty. This is the
#     explicit opt-out path — the consumer has acknowledged the placeholder
#     and chosen to disable the feature it gates (e.g. gitflow project
#     integration). Missing key vs. empty key carries different meaning:
#       missing → "not yet configured" (placeholder survives → diff noise
#                  on every scan → forces consumer to address it)
#       empty   → "intentionally off" (substituted to empty string → conf
#                  ends up with real empty value → runtime treats as off)
#   - Require string values (skip objects / arrays that appear as metadata).
apply_substitutions() {
    local empty
    empty=$(printf '%s' "$SUBSTITUTIONS_JSON" | jq -r 'length')
    if [ "$empty" = "0" ] || [ -z "$empty" ]; then
        cat
        return
    fi

    # Build a single sed script: `s/{{KEY}}/value/g` per entry. KEY and value
    # are escaped for sed's BRE syntax — KEY on the pattern side (only brace
    # and backslash in practice, since uppercase-underscore keys are the
    # convention), value on the replacement side (`\`, `&`, `/` must be
    # escaped).
    local sed_script=""
    local pairs
    pairs=$(printf '%s' "$SUBSTITUTIONS_JSON" | jq -r 'to_entries[] | select(.key | startswith("_") | not) | select(.value != null and (.value | type) == "string") | "\(.key)\t\(.value)"')
    while IFS=$'\t' read -r key value; do
        [ -z "$key" ] && continue
        local k_esc v_esc
        # Pattern-side escape: backslash + regex metas. Keys are typically
        # safe (A-Z, _) but escape defensively.
        k_esc=$(printf '%s' "$key" | sed 's/[][\\/.^$*]/\\&/g')
        # Replacement-side escape: `\`, `&`, `/`.
        v_esc=$(printf '%s' "$value" | sed 's/[\\/&]/\\&/g')
        sed_script+="s/{{${k_esc}}}/${v_esc}/g;"
    done <<< "$pairs"

    if [ -z "$sed_script" ]; then
        cat
        return
    fi

    sed "$sed_script"
}

# sha256_substituted — SHA of a kit file AFTER placeholder substitution.
# When SUBSTITUTIONS_JSON is empty, identical to sha256() on the raw file.
sha256_substituted() {
    local kit_full="$1"
    [ -f "$kit_full" ] || { echo ""; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        apply_substitutions < "$kit_full" | sha256sum | awk '{print $1}'
    else
        apply_substitutions < "$kit_full" | shasum -a 256 | awk '{print $1}'
    fi
}

# ─── settings.json canonicalization ────────────────────────────────────────
# settings.json is compared as canonicalized JSON rather than raw bytes, so a
# reordered key or reindented block does not surface as a diff on a file whose
# content is semantically identical. Every field flows through normal 3-way
# state; the kit owns them all.
#
# See kitmaintainer-handbook.md §9.6.
is_settings_json() {
    [ "$1" = "_claude-project/settings.json" ]
}

# canonicalize_settings — read JSON on stdin, emit jq-canonicalized JSON on
# stdout. Empty input passes through untouched.
canonicalize_settings() {
    local json
    json=$(cat)
    [ -z "$json" ] && return
    printf '%s' "$json" | jq '.'
}

# sha256_settings_kit — SHA of kit settings.json after substitution +
# canonicalization. Replaces sha256_substituted() for the settings.json path
# so key-order / whitespace differences don't surface as false-positive diffs.
sha256_settings_kit() {
    local kit_full="$1"
    [ -f "$kit_full" ] || { echo ""; return; }
    local tmp_subst
    tmp_subst=$(mktemp)
    apply_substitutions < "$kit_full" > "$tmp_subst"
    local content
    content=$(canonicalize_settings < "$tmp_subst")
    rm -f "$tmp_subst"
    [ -z "$content" ] && { echo ""; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$content" | sha256sum | awk '{print $1}'
    else
        printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
    fi
}

# sha256_settings_proj — SHA of project settings.json after canonicalization.
# Matches sha256_settings_kit's jq normalization so equivalent JSON content
# reports equal SHAs regardless of whitespace / key-order.
sha256_settings_proj() {
    local proj_full="$1"
    [ -f "$proj_full" ] || { echo ""; return; }
    local content
    content=$(jq '.' "$proj_full" 2>/dev/null)
    [ -z "$content" ] && { echo ""; return; }
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$content" | sha256sum | awk '{print $1}'
    else
        printf '%s' "$content" | shasum -a 256 | awk '{print $1}'
    fi
}

is_skipped() {
    local path="$1"
    for skip in "${SKIP_LIST[@]}"; do
        [ "$path" = "$skip" ] && return 0
    done
    case "$path" in
        _claude-project/rules/project/*) return 0 ;;
        *.DS_Store) return 0 ;;
    esac
    return 1
}

# Destinations sync never writes, whatever a kit path maps to. The lockfile is
# sync's own state; the patch register is the PROJECT's record of sanctioned
# edits to owned files, written by the consumer and only ever read here.
is_protected_dest() {
    case "$1" in
        .claude/.kit-sync.json|.claude/.kit-patches.json) return 0 ;;
    esac
    return 1
}

# ─── Patch register (`.claude/.kit-patches.json`) ──────────────────────────
# A consumer edit to an `owned` file is either sanctioned — recorded here with
# the kit issue that will fix it upstream and the project issue tracking the
# temporary change — or it is unsanctioned. Schema, shared with
# block-kit-edit.sh:
#
#   {"patches":[{"path":".claude/…","kitIssue":"owner/repo#N",
#                "projectIssue":"#M","reason":"…"}]}
#
# `path` is the destination path relative to the project root, the same key
# the lockfile uses.
PATCHES_FILE=""
PATCHES_JSON='{"patches":[]}'

load_patches() {
    PATCHES_FILE="${PROJECT_PATH}/.claude/.kit-patches.json"
    PATCHES_JSON='{"patches":[]}'
    [ -f "$PATCHES_FILE" ] || return 0
    if ! PATCHES_JSON=$(jq -c '{patches: (.patches // [])} | if (.patches | type) == "array" then . else error("patches is not an array") end' "$PATCHES_FILE" 2>/dev/null); then
        echo "sync-dev-kit.sh: .claude/.kit-patches.json is not valid — expected {\"patches\":[{\"path\",\"kitIssue\",\"projectIssue\",\"reason\"}]}. Fix it before syncing." >&2
        exit 5
    fi
}

# The register entry for a destination path, compact JSON, or empty.
patch_entry_for() {
    printf '%s' "$PATCHES_JSON" | jq -c --arg p "$1" 'first(.patches[] | select(.path == $p)) // empty'
}

# OPEN / CLOSED for "owner/repo#N" (or "#N" against the project's own repo),
# `unknown` when gh is missing, unauthenticated, or the reference is malformed.
# Unknown is reported as such — never read as either answer.
issue_state() {
    local ref="$1" repo="" num="" state
    if [[ "$ref" =~ ^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)$ ]]; then
        repo="${BASH_REMATCH[1]}"; num="${BASH_REMATCH[2]}"
    elif [[ "$ref" =~ ^#?([0-9]+)$ ]]; then
        num="${BASH_REMATCH[1]}"
    else
        echo "unknown"; return
    fi
    command -v gh >/dev/null 2>&1 || { echo "unknown"; return; }
    if [ -n "$repo" ]; then
        state=$(gh issue view "$num" --repo "$repo" --json state --jq .state 2>/dev/null) || state=""
    else
        state=$(cd "$PROJECT_PATH" && gh issue view "$num" --json state --jq .state 2>/dev/null) || state=""
    fi
    case "$state" in
        OPEN|CLOSED) echo "$state" ;;
        *) echo "unknown" ;;
    esac
}

# ─── Merge regions ─────────────────────────────────────────────────────────
# A `merge` file is kit-owned everywhere except inside named project regions,
# marked in the file's own comment syntax:
#
#   Markdown          <!-- project:begin <name> -->  …  <!-- project:end <name> -->
#   YAML, attributes  # project:begin <name>         …  # project:end <name>
#
# Sync writes the kit file with each region's body replaced by the project's
# body for the same-named region; the kit's body is the seed for a region the
# project does not have yet. Names are [A-Za-z0-9_-]+, unique per file, and
# regions do not nest.
region_syntax() {
    case "$1" in
        *.md) echo "md" ;;
        *) echo "hash" ;;
    esac
}

# region_awk <op> <syntax> <file> [<project-file>]
#   names    — region names in file order, one per line
#   blank    — the file with every region body removed, markers kept
#   compose  — <file> (the kit) with each region body taken from <project-file>
# Exit 3 with a reason on stderr when a file's markers are malformed; compose
# also exits 3 when the project has a region the kit does not.
region_awk() {
    local op="$1" syn="$2" file="$3" proj="${4:-}"
    awk -v op="$op" -v syn="$syn" -v projfile="$proj" '
        function marker(line, kind,    m, re) {
            if (syn == "md") re = "^[ \t]*<!-- project:" kind " [A-Za-z0-9_-]+ -->[ \t\r]*$"
            else             re = "^[ \t]*# project:" kind " [A-Za-z0-9_-]+[ \t\r]*$"
            if (line !~ re) return ""
            m = line
            sub("^[ \t]*(<!-- |# )project:" kind " ", "", m)
            sub("( -->)?[ \t\r]*$", "", m)
            return m
        }
        function fail(where, msg) {
            printf "%s: %s\n", where, msg > "/dev/stderr"
            bad = 1
            exit 3
        }
        # Read a whole file into bodies[] keyed by region name, validating.
        function readproj(f,    line, b, e, cur, n) {
            cur = ""; n = 0
            while ((getline line < f) > 0) {
                n++
                b = marker(line, "begin"); e = marker(line, "end")
                if (b != "") {
                    if (cur != "") fail(f ":" n, "region \"" b "\" opens inside region \"" cur "\"")
                    if (b in pseen) fail(f ":" n, "region \"" b "\" appears twice")
                    pseen[b] = 1; cur = b; pbody[b] = ""; continue
                }
                if (e != "") {
                    if (e != cur) fail(f ":" n, "region end \"" e "\" does not close an open region")
                    cur = ""; continue
                }
                if (cur != "") pbody[cur] = pbody[cur] line "\n"
            }
            close(f)
            if (cur != "") fail(f, "region \"" cur "\" is never closed")
        }
        BEGIN {
            cur = ""
            if (op == "compose") readproj(projfile)
        }
        {
            b = marker($0, "begin"); e = marker($0, "end")
            if (b != "") {
                if (cur != "") fail(FILENAME ":" NR, "region \"" b "\" opens inside region \"" cur "\"")
                if (b in seen) fail(FILENAME ":" NR, "region \"" b "\" appears twice")
                seen[b] = 1; cur = b
                if (op == "names") { print b; next }
                print
                if (op == "compose" && (b in pbody)) printf "%s", pbody[b]
                next
            }
            if (e != "") {
                if (e != cur) fail(FILENAME ":" NR, "region end \"" e "\" does not close an open region")
                cur = ""
                if (op != "names") print
                next
            }
            if (op == "names") next
            if (cur == "") { print; next }
            if (op == "blank") next
            if (op == "compose" && (cur in pbody)) next
            print
        }
        END {
            if (bad) exit 3
            if (cur != "") fail(FILENAME, "region \"" cur "\" is never closed")
            if (op == "compose") {
                for (n in pseen) if (!(n in seen)) fail(projfile, "the project has region \"" n "\", which the kit file does not — its content would be lost")
            }
        }
    ' "$file"
}

# Does this file carry at least one region marker (well-formed or not)?
has_region_markers() {
    local syn="$1" file="$2"
    if [ "$syn" = "md" ]; then
        grep -Eq '^[[:space:]]*<!-- project:(begin|end) ' "$file"
    else
        grep -Eq '^[[:space:]]*# project:(begin|end) ' "$file"
    fi
}

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

# SHA of a file with its region bodies removed — the part of a merge file the
# kit owns. Empty on malformed markers (reason on stderr).
sha256_skeleton() {
    local syn="$1" file="$2" out
    out=$(mktemp)
    if ! region_awk blank "$syn" "$file" > "$out"; then
        rm -f "$out"; echo ""; return
    fi
    sha256_stdin < "$out"
    rm -f "$out"
}

# Read one substitution value. Empty when the key is absent, null, or blank —
# which is how a project says "this does not apply to me".
subst_value() {
    printf '%s' "$SUBSTITUTIONS_JSON" | jq -r --arg k "$1" '.[$k] // "" | if type == "string" then . else "" end'
}

# Whether a key is the deliberate blank: present, empty, and listed in `_intentionally_empty`.
subst_intentionally_empty() {
    printf '%s' "$SUBSTITUTIONS_JSON" | jq -e --arg k "$1" \
        'has($k) and (.[$k] == "") and ((._intentionally_empty // []) | index($k) != null)' >/dev/null 2>&1
}

# Map kit path to consumer destination path (relative to project root).
# Convention: `_<name>-project/` in the kit maps 1:1 to `.<name>/` in the consumer.
#   _claude-project/  → .claude/
#   _github-project/  → .github/
#   _gemini-project/  → .gemini/
# Root-level dotfiles (.mcp.json, .commitlintrc.json, .gitignore) live under
# _claude-project/templates/ and require explicit mappings here.
dest_for_kit_path() {
    local kit_rel="$1"
    case "$kit_rel" in
        _claude-project/templates/.mcp.json)
            echo ".mcp.json"
            ;;
        _claude-project/templates/.commitlintrc.json)
            echo ".commitlintrc.json"
            ;;
        _claude-project/templates/biome.json)
            # The project's seed: it extends the kit base and adds what is
            # this project's own (its plugins, its overrides).
            echo "biome.json"
            ;;
        _claude-project/templates/biome.base.json)
            echo "biome.base.json"
            ;;
        _claude-project/templates/biome-plugins/*)
            # The kit's GritQL plugins, named in biome.base.json's `plugins`,
            # which Biome resolves against the base file's own folder — the
            # repo root. A project's own plugins sit beside them, listed in
            # its biome.json.
            echo "biome-plugins/${kit_rel#_claude-project/templates/biome-plugins/}"
            ;;
        _claude-project/templates/.gitattributes)
            echo ".gitattributes"
            ;;
        _claude-project/templates/knip.config.ts)
            # The kit's unused-code configuration, one file for every project.
            # It reads the project's own layout at run time, so it never varies.
            echo "knip.config.ts"
            ;;
        _claude-project/templates/.semgrepignore)
            echo ".semgrepignore"
            ;;
        _claude-project/templates/scripts/check-dep-alignment.mjs)
            echo "scripts/check-dep-alignment.mjs"
            ;;
        _claude-project/templates/scripts/check-workspace-tiers.mjs)
            echo "scripts/check-workspace-tiers.mjs"
            ;;
        _claude-project/templates/scripts/check-stack.mjs)
            echo "scripts/check-stack.mjs"
            ;;
        _claude-project/templates/scripts/db-branch.mjs)
            echo "scripts/db-branch.mjs"
            ;;
        _claude-project/templates/dependency-policy.md)
            # Operating procedure for dependency + vulnerability work. Lands in
            # the consumer's docs, not .claude/ — it is read by humans, not
            # loaded as a rule. Mode `merge`: the owners and the timelines
            # table are project regions.
            echo "project-documentation/dependency-policy.md"
            ;;
        _claude-project/templates/ui-inventory.md)
            # Lands in the consumer's PROJECT-OWNED rules dir. It cannot ship
            # from `_claude-project/rules/project/` — `is_skipped` skips that
            # whole tree, by design, so nothing there ever reaches a consumer.
            # Shipping it from templates/ with an explicit destination is what
            # lets the kit seed one file into a directory it otherwise never
            # touches. Mode `merge`: every enumeration is a project region.
            echo ".claude/rules/project/ui-inventory.md"
            ;;
        _claude-project/templates/design-system/*)
            # The claude-design engine's files land inside the UI package, which
            # every project names differently. DESIGN_UI_PACKAGE supplies it; empty
            # means the project has no UI package. A project with one that does
            # not publish to Claude Design sets DESIGN_FEED_BARREL deliberately
            # empty, and the engine's files are skipped too. Both are reported
            # under `skipped_unconfigured`.
            local ui_pkg
            ui_pkg=$(subst_value "DESIGN_UI_PACKAGE")
            [ -z "$ui_pkg" ] && { echo ""; return; }
            subst_intentionally_empty "DESIGN_FEED_BARREL" && { echo ""; return; }
            echo "${ui_pkg%/}/design-system/${kit_rel#_claude-project/templates/design-system/}"
            ;;
        _claude-project/templates/testing/vitest.config.ts)
            # Test scaffolding has no fixed home — it lands beside the shared
            # module, which every project names differently (apps/shared,
            # src, packages/core). SHARED_MODULE_DIR supplies it; empty means
            # the project has no shared module and these files are skipped.
            local shared_dir
            shared_dir=$(subst_value "SHARED_MODULE_DIR")
            [ -z "$shared_dir" ] && { echo ""; return; }
            echo "${shared_dir}/vitest.config.ts"
            ;;
        _claude-project/templates/testing/globalSetup.ts|_claude-project/templates/testing/integration-helpers.ts)
            # The integration harness is Postgres on Neon: a branch per run, a
            # rolled-back pg transaction per test. Another engine — or one not
            # yet declared — gets the unit scaffolding only.
            local shared_dir3
            shared_dir3=$(subst_value "SHARED_MODULE_DIR")
            [ -z "$shared_dir3" ] && { echo ""; return; }
            [ "$(subst_value "DB_ENGINE")" = "PostgreSQL" ] || { echo ""; return; }
            echo "${shared_dir3}/test/${kit_rel#_claude-project/templates/testing/}"
            ;;
        _claude-project/templates/testing/*)
            local shared_dir2
            shared_dir2=$(subst_value "SHARED_MODULE_DIR")
            [ -z "$shared_dir2" ] && { echo ""; return; }
            echo "${shared_dir2}/test/${kit_rel#_claude-project/templates/testing/}"
            ;;
        _gemini-project/*)
            echo ".gemini/${kit_rel#_gemini-project/}"
            ;;
        _claude-project/templates/*)
            # No mapping. The scan lists every such file under
            # `unmapped_templates` so a new template cannot be skipped silently.
            echo ""
            ;;
        _claude-project/*)
            echo ".claude/${kit_rel#_claude-project/}"
            ;;
        _github-project/*)
            echo ".github/${kit_rel#_github-project/}"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Reverse of dest_for_kit_path: which kit file, if any, currently supplies this
# destination? Empty when nothing does.
#
# There is no closed-form inverse — templates/ maps several kit paths onto
# root-level and SHARED_MODULE_DIR destinations — so this walks the kit surfaces
# and compares forward mappings. Only `--apply-file` needs it, once per call, to
# tell "the kit deleted this" from "the caller passed a dest path for a file the
# kit still ships". Requires load_substitutions to have run (SHARED_MODULE_DIR
# participates in the forward map).
kit_path_for_dest() {
    local want="$1"
    local dirs=() kit_rel
    [ -d "${KIT_PATH}/_claude-project" ] && dirs+=("_claude-project")
    [ -d "${KIT_PATH}/_github-project" ] && dirs+=("_github-project")
    [ -d "${KIT_PATH}/_gemini-project" ] && dirs+=("_gemini-project")
    [ ${#dirs[@]} -eq 0 ] && { echo ""; return; }

    while IFS= read -r kit_rel; do
        [ -z "$kit_rel" ] && continue
        is_skipped "$kit_rel" && continue
        if [ "$(dest_for_kit_path "$kit_rel")" = "$want" ]; then
            echo "$kit_rel"
            return
        fi
    done <<< "$(cd "$KIT_PATH" && find "${dirs[@]}" -type f ! -name ".DS_Store" 2>/dev/null | sort)"
    echo ""
}

# The substitution key a kit path's destination depends on, or empty. A path
# whose key is empty in this project is skipped deliberately, not unmapped.
dest_key_for_kit_path() {
    case "$1" in
        _claude-project/templates/testing/globalSetup.ts|_claude-project/templates/testing/integration-helpers.ts)
            if [ -z "$(subst_value SHARED_MODULE_DIR)" ]; then echo "SHARED_MODULE_DIR"; else echo "DB_ENGINE"; fi ;;
        _claude-project/templates/testing/*)       echo "SHARED_MODULE_DIR" ;;
        _claude-project/templates/design-system/*)
            if [ -z "$(subst_value DESIGN_UI_PACKAGE)" ]; then echo "DESIGN_UI_PACKAGE"; else echo "DESIGN_FEED_BARREL"; fi ;;
        *) echo "" ;;
    esac
}

# Sync mode for a kit file. Three values:
#
#   owned    — the kit owns the content. Consumers must not edit it
#              (`block-kit-edit.sh` denies the write); divergence is a `conflict`
#              reconciled toward the kit. A project edit with no kit change is
#              `patched` when the patch register sanctions it and `unsanctioned`
#              when it does not. Default, and the common case.
#   merge    — owned, except inside named project regions (see "Merge regions"
#              above). Kit text outside the regions always applies; the
#              project's region bodies are always kept.
#   template — a SEED: the project's content from the start. Offered once to a
#              project that has never had it; once the project has it — or
#              declined it — a kit change never offers it again (`template-kept`).
#              Consumers may edit it freely (the hook allows the write).
#
# Choose a mode in this order, and stop at the first that fits: `owned`, with
# placeholders for the values that differ; `merge`, for text a project adds
# beside the kit's; `owned` with a project extension file it imports for project
# logic (test/project.ts); and `template` last — only for a file that is the
# project's own content, which the kit never needs to improve. A `template` file
# stops receiving every kit change, silently.
#
# Mode is a property of the KIT file, not of the consumer, so it is declared here
# and copied into each consumer's lockfile on apply — `block-kit-edit.sh` runs on
# machines where the kit is not checked out and cannot ask the kit at edit time.
mode_for_kit_path() {
    local kit_rel="$1"
    case "$kit_rel" in
        # Seeds: files whose content is the project's from the start. The test
        # settings every kit test file reads (test/project.ts), and the Biome seed
        # — one line extending the kit-owned biome.base.json, plus whatever this
        # project adds. Seeded once; never offered again (template-kept below).
        _claude-project/templates/testing/project.ts) echo "template" ;;
        _claude-project/templates/biome.json) echo "template" ;;
        # The UI inventory's enumerations, the dependency policy's owners and
        # timelines, the project's own CI steps, review rules and attributes
        # are project regions; every other line is the kit's.
        _claude-project/templates/ui-inventory.md) echo "merge" ;;
        _claude-project/templates/dependency-policy.md) echo "merge" ;;
        _claude-project/templates/.gitattributes) echo "merge" ;;
        _github-project/workflows/ci.yml) echo "merge" ;;
        _gemini-project/styleguide.md) echo "merge" ;;
        *) echo "owned" ;;
    esac
}

# Baseline SHA from the lockfile. Tolerates both schemas: the legacy bare-string
# value (implicitly mode `owned`) and the current {sha, mode} object.
# A kit .gitignore rule is "missing" only when it is not ALREADY IN EFFECT.
#
# The literal whole-line match this replaced called `.env` missing in a project
# whose `.env*` already covers it, and had no lockfile state to be clean against
# — so a brownfield project that expresses the same rule differently re-declined
# the same lines on every sync, forever, while being fully protected. Ask git the
# question that actually matters instead: would git ignore this path today?
#
# A greenfield project ignores nothing, so it is still offered the whole set —
# which is the case this list exists for.
gitignore_rule_in_effect() {
    local rule="$1" probe negate=0

    case "$rule" in
        '!'*) negate=1; rule="${rule#!}" ;;
    esac

    # Turn the pattern into a concrete path git can rule on: a trailing slash is
    # the directory marker, a leading one anchors at the root (where we probe),
    # and every wildcard needs something to stand for.
    probe="${rule%/}"
    probe="${probe#/}"
    probe="$(printf '%s' "$probe" | sed 's/\*\*/x/g; s/\*/x/g; s/?/x/g')"
    [ -n "$probe" ] || return 0

    # `node_modules/` ignores what is INSIDE the directory, so probe a path in it.
    case "$rule" in */) probe="${probe}/x" ;; esac

    # core.excludesFile is DISABLED for the probe. A rule covered only by the
    # running developer's personal global ignore is not covered for anyone who
    # clones the repo, and skipping it there would silently leave the file
    # tracked for the whole team. Only ignore rules that ship WITH the repo
    # count. ($GIT_DIR/info/exclude is per-clone too and cannot be switched off
    # here, but it is a deliberate local override rather than a machine default.)
    if git -C "$PROJECT_PATH" -c core.excludesFile=/dev/null \
           check-ignore -q -- "$probe" 2>/dev/null; then
        # Ignored: satisfies a normal rule, VIOLATES a negation.
        [ "$negate" -eq 0 ]
    else
        # Not ignored: satisfies a negation, violates a normal rule. Also the
        # answer when the project is not a git repo yet, which correctly offers
        # every rule rather than hiding them.
        [ "$negate" -eq 1 ]
    fi
}

load_baseline_sha() {
    local dest_rel="$1"
    [ -f "$LOCKFILE" ] || { echo ""; return; }
    jq -r --arg k "$dest_rel" '
        (.files[$k] // "") | if type == "object" then (.sha // "") else . end
    ' "$LOCKFILE"
}

# Was this file declined, and at which kit content? Empty when it was not.
#
# A declined entry records the kit SHA at the moment of refusal, NOT a
# project file — there is no project file, that is the point. It is what lets
# `new-kit` be answered with "no" instead of being re-offered forever.
load_declined_sha() {
    local dest_rel="$1"
    [ -f "$LOCKFILE" ] || { echo ""; return; }
    jq -r --arg k "$dest_rel" '
        (.files[$k] // "") | if type == "object" and (.declined // false)
        then (.sha // "") else "" end
    ' "$LOCKFILE"
}

# Record a refusal. Same shape as a normal entry plus `declined: true`, so a
# later apply simply overwrites it and the refusal evaporates.
update_lockfile_declined() {
    local dest_rel="$1"
    local kit_sha="$2"
    local mode="${3:-owned}"

    mkdir -p "$(dirname "$LOCKFILE")"
    if [ ! -f "$LOCKFILE" ]; then
        echo '{"kitRepo":"","lastSyncedCommit":"","lastSyncedAt":"","files":{}}' > "$LOCKFILE"
    fi

    local tmp
    tmp=$(mktemp)
    jq --arg k "$dest_rel" --arg v "$kit_sha" --arg m "$mode" \
        '.files[$k] = {sha: $v, mode: $m, declined: true}' "$LOCKFILE" > "$tmp"
    mv "$tmp" "$LOCKFILE"
}

# The skeleton SHA recorded for a merge file: its kit-owned text, region bodies
# removed, as last written. Empty for any other file or a legacy entry.
load_baseline_skeleton() {
    local dest_rel="$1"
    [ -f "$LOCKFILE" ] || { echo ""; return; }
    jq -r --arg k "$dest_rel" '
        (.files[$k] // "") | if type == "object" then (.skeleton // "") else "" end
    ' "$LOCKFILE"
}

update_lockfile_file() {
    local dest_rel="$1"
    local new_sha="$2"
    local mode="${3:-owned}"
    local skeleton="${4:-}"

    mkdir -p "$(dirname "$LOCKFILE")"
    if [ ! -f "$LOCKFILE" ]; then
        echo '{"kitRepo":"","lastSyncedCommit":"","lastSyncedAt":"","files":{}}' > "$LOCKFILE"
    fi

    local tmp
    tmp=$(mktemp)
    if [ -n "$new_sha" ]; then
        jq --arg k "$dest_rel" --arg v "$new_sha" --arg m "$mode" --arg s "$skeleton" \
            '.files[$k] = ({sha: $v, mode: $m} + (if $s == "" then {} else {skeleton: $s} end))' "$LOCKFILE" > "$tmp"
    else
        jq --arg k "$dest_rel" 'del(.files[$k])' "$LOCKFILE" > "$tmp"
    fi
    mv "$tmp" "$LOCKFILE"
}

# ---------------------------------------------------------------------------
# Mode: scan
# ---------------------------------------------------------------------------

if [ "$MODE" = "scan" ]; then
    cd "$KIT_PATH"

    # Load per-project placeholder substitutions (if any). Must happen before
    # the per-file SHA loop so kit SHAs reflect substituted content.
    load_substitutions

    KIT_CLEAN=true
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        KIT_CLEAN=false
    fi

    KIT_BEHIND=false
    git fetch origin >/dev/null 2>&1 || true
    LOCAL=$(git rev-parse HEAD 2>/dev/null || echo "")
    REMOTE=$(git rev-parse '@{u}' 2>/dev/null || echo "")
    if [ -n "$LOCAL" ] && [ -n "$REMOTE" ] && [ "$LOCAL" != "$REMOTE" ]; then
        BASE=$(git merge-base HEAD '@{u}' 2>/dev/null || echo "")
        [ "$LOCAL" = "$BASE" ] && KIT_BEHIND=true
    fi

    KIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")

    cd "$PROJECT_PATH"

    # Scan every kit template surface that exists. `_claude-project` is required;
    # other `_<dir>-project` surfaces are optional (introduced as needed).
    KIT_DIRS=()
    [ -d "${KIT_PATH}/_claude-project" ] && KIT_DIRS+=("_claude-project")
    [ -d "${KIT_PATH}/_github-project" ] && KIT_DIRS+=("_github-project")
    [ -d "${KIT_PATH}/_gemini-project" ] && KIT_DIRS+=("_gemini-project")
    KIT_FILES=$(cd "$KIT_PATH" && find "${KIT_DIRS[@]}" -type f ! -name ".DS_Store" 2>/dev/null | sort)

    load_patches

    FILE_ENTRIES="[]"
    UNMAPPED="[]"
    UNCONFIGURED="[]"
    while IFS= read -r kit_rel; do
        [ -z "$kit_rel" ] && continue
        is_skipped "$kit_rel" && continue

        dest_rel=$(dest_for_kit_path "$kit_rel")
        if [ -z "$dest_rel" ]; then
            # Either the project deliberately has no home for it (its
            # destination key is empty) or the kit forgot a mapping. Both are
            # reported; neither is a silent skip.
            dest_key=$(dest_key_for_kit_path "$kit_rel")
            if [ -n "$dest_key" ]; then
                UNCONFIGURED=$(jq -c --arg p "$kit_rel" --arg k "$dest_key" '. + [{kit_path: $p, key: $k}]' <<<"$UNCONFIGURED")
            else
                case "$kit_rel" in
                    # Not a file: --apply-gitignore reads its lines.
                    _claude-project/templates/.gitignore-additions) ;;
                    _claude-project/templates/*)
                        UNMAPPED=$(jq -c --arg p "$kit_rel" '. + [$p]' <<<"$UNMAPPED") ;;
                esac
            fi
            continue
        fi
        is_protected_dest "$dest_rel" && continue

        kit_full="${KIT_PATH}/${kit_rel}"
        proj_full="${PROJECT_PATH}/${dest_rel}"
        file_mode=$(mode_for_kit_path "$kit_rel")
        baseline_sha=$(load_baseline_sha "$dest_rel")
        declined_sha=$(load_declined_sha "$dest_rel")
        state=""
        detail=""
        owned_edit=false
        kit_changed=false

        # kit_sha is what applying would write: the kit file after placeholder
        # substitution — and, for a merge file, with the project's region
        # bodies carried in. proj_sha is the raw project file. settings.json
        # canonicalizes both sides via jq (kitmaintainer-handbook.md §9.6).
        if is_settings_json "$kit_rel"; then
            kit_sha=$(sha256_settings_kit "$kit_full")
            proj_sha=$(sha256_settings_proj "$proj_full")
        elif [ "$file_mode" = "merge" ]; then
            syn=$(region_syntax "$kit_rel")
            tmp_kit=$(mktemp)
            apply_substitutions < "$kit_full" > "$tmp_kit"
            kit_skel=$(sha256_skeleton "$syn" "$tmp_kit")
            if [ -z "$kit_skel" ]; then
                rm -f "$tmp_kit"
                echo "sync-dev-kit.sh: the kit's $kit_rel has malformed region markers — fix the kit before syncing" >&2
                exit 5
            fi
            kit_sha=$(sha256 "$tmp_kit")
            proj_sha=$(sha256 "$proj_full")
            if [ -n "$proj_sha" ]; then
                if ! has_region_markers "$syn" "$proj_full"; then
                    # The project's content predates the regions. Applying would
                    # discard it, so nothing is written until it is moved into
                    # the regions by hand.
                    state="merge-unmarked"
                else
                    tmp_merged=$(mktemp)
                    tmp_err=$(mktemp)
                    if region_awk compose "$syn" "$tmp_kit" "$proj_full" > "$tmp_merged" 2> "$tmp_err"; then
                        kit_sha=$(sha256 "$tmp_merged")
                        proj_skel=$(sha256_skeleton "$syn" "$proj_full")
                        base_skel=$(load_baseline_skeleton "$dest_rel")
                        if [ -z "$base_skel" ]; then
                            # First merge-aware sync: no record of the kit text
                            # this project last took, so an outside difference
                            # cannot be attributed to either side.
                            if [ "$proj_sha" = "$kit_sha" ]; then
                                state="clean-first"
                            elif [ "$proj_skel" = "$kit_skel" ]; then
                                state="kit-only"
                            else
                                state="conflict-first"
                            fi
                        elif [ "$proj_skel" != "$base_skel" ] && [ "$proj_skel" != "$kit_skel" ]; then
                            # The project changed kit-owned text outside its regions.
                            owned_edit=true
                            [ "$kit_skel" != "$base_skel" ] && kit_changed=true
                        elif [ "$proj_sha" = "$kit_sha" ]; then
                            if [ "$proj_sha" = "$baseline_sha" ]; then state="clean"; else state="clean-converged"; fi
                        else
                            # Kit text moved, or a region the project lacks takes
                            # its kit seed. Region bodies are carried, so applying
                            # never costs the project anything.
                            state="kit-only"
                        fi
                    else
                        state="merge-invalid"
                        detail=$(cat "$tmp_err")
                    fi
                    rm -f "$tmp_merged" "$tmp_err"
                fi
            fi
            rm -f "$tmp_kit"
        else
            kit_sha=$(sha256_substituted "$kit_full")
            proj_sha=$(sha256 "$proj_full")
        fi

        [ -z "$kit_sha" ] && continue

        # A declined file has no project copy BY DESIGN, so it must be
        # resolved before the absent-file branches below — otherwise a
        # refusal reads as a deletion and nags just as loudly as the offer
        # it replaced. Declining is not permanent: when the kit changes the
        # file, the recorded SHA no longer matches and it is offered again,
        # which is the whole point of recording a SHA rather than a flag.
        if [ -n "$state" ] || [ "$owned_edit" = true ]; then
            :   # decided above (merge files)
        elif [ -n "$declined_sha" ] && [ -z "$proj_sha" ]; then
            # A declined seed stays declined whatever the kit later does to it.
            if [ "$kit_sha" = "$declined_sha" ] || [ "$file_mode" = "template" ]; then
                state="declined"
            else
                state="new-kit"
            fi
        elif [ -z "$proj_sha" ] && [ -z "$baseline_sha" ]; then
            state="new-kit"
        elif [ -z "$proj_sha" ] && [ -n "$baseline_sha" ]; then
            state="project-deleted"
        elif [ -z "$baseline_sha" ]; then
            if [ "$kit_sha" = "$proj_sha" ]; then
                state="clean-first"
            else
                state="conflict-first"
            fi
        elif [ "$kit_sha" = "$baseline_sha" ] && [ "$proj_sha" = "$baseline_sha" ]; then
            state="clean"
        elif [ "$kit_sha" != "$baseline_sha" ] && [ "$proj_sha" = "$baseline_sha" ]; then
            state="kit-only"
        elif [ "$kit_sha" = "$baseline_sha" ]; then
            state="project-only"
        elif [ "$kit_sha" = "$proj_sha" ]; then
            state="clean-converged"
        else
            state="conflict"
        fi

        # Template files are seeds: the project owns the content from the moment
        # it lands. Once the project has the file — untouched, adapted or
        # deleted — a kit change to it is never offered again; it is
        # `template-kept`, silent. Only a project that never had it is offered
        # the seed (`new-kit`), once.
        if [ "$file_mode" = "template" ]; then
            case "$state" in
                kit-only|project-only|conflict|conflict-first|project-deleted) state="template-kept" ;;
            esac
        fi

        # Owned files: a project edit is never a silent skip. Merge files
        # arrive here with owned_edit already decided.
        if [ "$file_mode" = "owned" ]; then
            case "$state" in
                project-only) owned_edit=true ;;
                conflict)
                    # Unregistered, a two-sided divergence stays a conflict to
                    # reconcile; registered, it is a patch the kit has moved under.
                    if [ -n "$(patch_entry_for "$dest_rel")" ]; then
                        owned_edit=true; kit_changed=true
                    fi
                    ;;
            esac
        fi

        patch_json="null"
        if [ "$owned_edit" = true ]; then
            entry=$(patch_entry_for "$dest_rel")
            if [ -n "$entry" ]; then
                state="patched"
                kit_issue=$(jq -r '.kitIssue // ""' <<<"$entry")
                proj_issue=$(jq -r '.projectIssue // ""' <<<"$entry")
                kit_issue_state=$(issue_state "$kit_issue")
                proj_issue_state=$(issue_state "$proj_issue")
                if [ "$kit_changed" = true ] && [ "$kit_issue_state" = "CLOSED" ]; then
                    rec="take-kit"
                elif [ "$kit_changed" = true ]; then
                    rec="merge-kit-keep-patch"
                elif [ "$kit_issue_state" = "CLOSED" ]; then
                    rec="kit-issue-closed-file-unchanged"
                else
                    rec="keep"
                fi
                patch_json=$(jq -c --arg kis "$kit_issue_state" --arg pis "$proj_issue_state" \
                    --argjson kc "$kit_changed" --arg rec "$rec" \
                    '{kitIssue, projectIssue, reason, kit_issue_state: $kis, project_issue_state: $pis, kit_changed: $kc, recommendation: $rec}' <<<"$entry")
            else
                state="unsanctioned"
            fi
        fi

        FILE_ENTRIES=$(echo "$FILE_ENTRIES" | jq \
            --arg kit_path "$kit_rel" \
            --arg dest_path "$dest_rel" \
            --arg state "$state" \
            --arg mode "$file_mode" \
            --arg kit_sha "$kit_sha" \
            --arg proj_sha "$proj_sha" \
            --arg baseline_sha "$baseline_sha" \
            --arg detail "$detail" \
            --argjson patch "$patch_json" \
            '. + [{kit_path: $kit_path, dest_path: $dest_path, state: $state, mode: $mode, kit_sha: $kit_sha, project_sha: $proj_sha, baseline_sha: $baseline_sha}
                  + (if $detail == "" then {} else {detail: $detail} end)
                  + (if $patch == null then {} else {patch: $patch} end)]')
    done <<< "$KIT_FILES"

    # Register entries that sanction nothing: the file now matches the kit,
    # was never kit-owned, or is project-owned already. Each is reported so the
    # entry is removed and its project issue closed.
    STALE_PATCHES=$(jq -c --argjson files "$FILE_ENTRIES" '
        [ .patches[] as $p
          | ($files | map(select(.dest_path == $p.path)) | first) as $f
          | select(($f.state // "") != "patched")
          | $p + {current_state: ($f.state // "not-kit-managed"), current_mode: ($f.mode // "")} ]
    ' <<<"$PATCHES_JSON")

    # Removed-from-kit: files in lockfile not present in kit
    if [ -f "$LOCKFILE" ]; then
        LOCKED_FILES=$(jq -r '.files | keys[]' "$LOCKFILE" 2>/dev/null || echo "")
        while IFS= read -r dest_rel; do
            [ -z "$dest_rel" ] && continue
            still_in_kit=$(echo "$FILE_ENTRIES" | jq --arg d "$dest_rel" 'any(.[]; .dest_path == $d)')
            # Nothing maps here and the project has no such file — a declined
            # seed, a destination a substitution gate now skips: nothing to
            # remove. --finalize drops the entry.
            if [ "$still_in_kit" = "false" ] && [ -e "${PROJECT_PATH}/${dest_rel}" ]; then
                proj_full="${PROJECT_PATH}/${dest_rel}"
                proj_sha=$(sha256 "$proj_full")
                baseline_sha=$(load_baseline_sha "$dest_rel")
                FILE_ENTRIES=$(echo "$FILE_ENTRIES" | jq \
                    --arg dest_path "$dest_rel" \
                    --arg proj_sha "$proj_sha" \
                    --arg baseline_sha "$baseline_sha" \
                    '. + [{kit_path: "", dest_path: $dest_path, state: "removed-kit", kit_sha: "", project_sha: $proj_sha, baseline_sha: $baseline_sha}]')
            fi
        done <<< "$LOCKED_FILES"
    fi

    GITIGNORE_ADDITIONS_FILE="${KIT_PATH}/_claude-project/templates/.gitignore-additions"
    MISSING_ENTRIES="[]"
    if [ -f "$GITIGNORE_ADDITIONS_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in \#*) continue ;; esac
            if ! gitignore_rule_in_effect "$line"; then
                MISSING_ENTRIES=$(echo "$MISSING_ENTRIES" | jq --arg e "$line" '. + [$e]')
            fi
        done < "$GITIGNORE_ADDITIONS_FILE"
    fi

    jq -n \
        --arg kit_path "$KIT_PATH" \
        --arg kit_commit "$KIT_COMMIT" \
        --argjson kit_clean "$KIT_CLEAN" \
        --argjson kit_behind "$KIT_BEHIND" \
        --argjson files "$FILE_ENTRIES" \
        --argjson gitignore_missing "$MISSING_ENTRIES" \
        --argjson unmapped "$UNMAPPED" \
        --argjson unconfigured "$UNCONFIGURED" \
        --argjson stale_patches "$STALE_PATCHES" \
        '{kit_path: $kit_path, kit_commit: $kit_commit, kit_clean: $kit_clean, kit_behind_remote: $kit_behind, files: $files, gitignore_additions_missing: $gitignore_missing, unmapped_templates: $unmapped, skipped_unconfigured: $unconfigured, stale_patches: $stale_patches}'

    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: apply-file
# ---------------------------------------------------------------------------

if [ "$MODE" = "apply" ]; then
    [ -z "$APPLY_FILE" ] && { echo "sync-dev-kit.sh: --apply-file requires a kit-relative path" >&2; exit 2; }

    # Apply mode uses substitutions when writing kit content into the project.
    load_substitutions

    kit_full="${KIT_PATH}/${APPLY_FILE}"
    dest_rel=$(dest_for_kit_path "$APPLY_FILE")

    # `removed-kit` is addressed by DESTINATION path, not kit path.
    #
    # --scan reports a kit-deleted file with an empty `kit_path` — there is no
    # kit file left to name — so `dest_path` is the only identifier the caller
    # has. Requiring a kit path here made the documented removal flow
    # unrunnable: dest_for_kit_path is NOT invertible (templates/ maps several
    # kit paths onto root-level and SHARED_MODULE_DIR destinations), so the
    # caller cannot reconstruct the kit path, and every attempt exits 4.
    #
    # Accepting a dest path is safe only when nothing in the kit still maps to
    # it — otherwise a caller who passed a dest path by mistake would delete a
    # live kit-managed file. kit_path_for_dest is the exact reverse map, so
    # that case fails loud instead. kit_full is cleared because, by definition
    # of reaching here, no kit file corresponds to this destination; `[ ! -f "" ]`
    # is true, so the removal branch below fires.
    if [ -z "$dest_rel" ] && [ -n "$(load_baseline_sha "$APPLY_FILE")" ]; then
        live_kit_path=$(kit_path_for_dest "$APPLY_FILE")
        if [ -n "$live_kit_path" ]; then
            echo "sync-dev-kit.sh: $APPLY_FILE is still supplied by the kit ($live_kit_path) — pass the kit path to apply it" >&2
            exit 4
        fi
        dest_rel="$APPLY_FILE"
        kit_full=""
    fi

    if [ -z "$dest_rel" ]; then
        dest_key=$(dest_key_for_kit_path "$APPLY_FILE")
        if [ -n "$dest_key" ]; then
            echo "sync-dev-kit.sh: $APPLY_FILE has no destination because $dest_key is empty in .claude/sync-substitutions.json" >&2
        else
            echo "sync-dev-kit.sh: no destination mapping for $APPLY_FILE" >&2
        fi
        exit 4
    fi
    if is_protected_dest "$dest_rel"; then
        echo "sync-dev-kit.sh: $dest_rel is sync state, never written from the kit" >&2
        exit 4
    fi

    if [ ! -f "$kit_full" ]; then
        # Removed from kit — delete from project + lockfile
        proj_full="${PROJECT_PATH}/${dest_rel}"
        rm -f "$proj_full"
        update_lockfile_file "$dest_rel" ""
        echo "sync-dev-kit.sh: removed $dest_rel (kit-removed)" >&2
        exit 0
    fi

    proj_full="${PROJECT_PATH}/${dest_rel}"
    mkdir -p "$(dirname "$proj_full")"
    # Write SUBSTITUTED content, not raw kit bytes. If no substitutions are
    # defined, apply_substitutions is a pass-through so behavior matches
    # the pre-substitution cp.
    # settings.json takes a separate path: canonicalized via jq so the written
    # file matches the SHA the scan computed. See kitmaintainer-handbook.md §9.6.
    if is_settings_json "$APPLY_FILE"; then
        tmp_subst=$(mktemp)
        tmp_final=$(mktemp)
        apply_substitutions < "$kit_full" > "$tmp_subst"
        canonicalize_settings < "$tmp_subst" > "$tmp_final"
        if [ ! -s "$tmp_final" ]; then
            rm -f "$tmp_subst" "$tmp_final"
            echo "sync-dev-kit.sh: failed to compose settings.json (jq returned empty)" >&2
            exit 5
        fi
        mv "$tmp_final" "$proj_full"
        rm -f "$tmp_subst"
        new_sha=$(sha256_settings_proj "$proj_full")
    elif [ "$(mode_for_kit_path "$APPLY_FILE")" = "merge" ]; then
        # Kit text everywhere, the project's bodies inside its regions.
        syn=$(region_syntax "$APPLY_FILE")
        tmp_kit=$(mktemp)
        tmp_final=$(mktemp)
        apply_substitutions < "$kit_full" > "$tmp_kit"
        if [ -f "$proj_full" ]; then
            if ! has_region_markers "$syn" "$proj_full"; then
                rm -f "$tmp_kit" "$tmp_final"
                echo "sync-dev-kit.sh: $dest_rel has no project regions yet (merge-unmarked). Move its project content into the kit's regions by hand first — applying now would discard it." >&2
                exit 4
            fi
            if ! region_awk compose "$syn" "$tmp_kit" "$proj_full" > "$tmp_final"; then
                rm -f "$tmp_kit" "$tmp_final"
                echo "sync-dev-kit.sh: could not merge $dest_rel — fix the region markers named above, then apply again" >&2
                exit 4
            fi
        else
            cp "$tmp_kit" "$tmp_final"
        fi
        cat "$tmp_final" > "$proj_full"
        rm -f "$tmp_kit" "$tmp_final"
        new_sha=$(sha256 "$proj_full")
        new_skeleton=$(sha256_skeleton "$syn" "$proj_full")
    else
        apply_substitutions < "$kit_full" > "$proj_full"
        case "$APPLY_FILE" in
            *.sh) chmod +x "$proj_full" ;;
        esac
        new_sha=$(sha256 "$proj_full")
    fi

    # Lockfile baseline SHA tracks what was WRITTEN: the substituted kit
    # content (canonicalized for settings.json, region-merged for a merge
    # file). This keeps subsequent scans clean until the kit template changes
    # or the substitution value changes. A merge file also records its skeleton
    # — the kit-owned text — which is how a later scan tells a project edit
    # outside the regions from one inside them.
    update_lockfile_file "$dest_rel" "$new_sha" "$(mode_for_kit_path "$APPLY_FILE")" "${new_skeleton:-}"

    echo "sync-dev-kit.sh: applied $dest_rel ($new_sha)" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: ack-file
#
# "I have seen this kit version and I am keeping mine." Records the kit's
# current (substituted) content as the baseline WITHOUT touching the project
# file.
#
# The baseline otherwise advances only when a change is APPLIED, so a conflict
# resolved by hand would re-report on every later sync.
#
# What makes an ack wrong is acking a kit change that was never INCORPORATED —
# that silences a real enforced update. Acking an `owned` file AFTER
# resolving its conflict by hand is correct and necessary: the kit's content
# is in the file, only the project's own customization still differs, and
# without the ack that identical conflict re-reports on every sync forever.
# So `owned` conflicts resolve in two steps — merge, then ack — and the
# guard belongs in the /sync-dev-kit walkthrough, where the user can see
# which of the two situations they are in.
# ---------------------------------------------------------------------------

if [ "$MODE" = "ack" ]; then
    [ -z "$APPLY_FILE" ] && { echo "sync-dev-kit.sh: --ack-file requires a kit-relative path" >&2; exit 2; }

    load_substitutions

    kit_full="${KIT_PATH}/${APPLY_FILE}"
    dest_rel=$(dest_for_kit_path "$APPLY_FILE")
    [ -z "$dest_rel" ] && { echo "sync-dev-kit.sh: no destination mapping for $APPLY_FILE" >&2; exit 4; }
    [ ! -f "$kit_full" ] && { echo "sync-dev-kit.sh: $APPLY_FILE does not exist in the kit" >&2; exit 4; }

    # Same hash the scan computes for kit_sha, so the next scan sees the kit
    # as unchanged. A merge file records the kit's skeleton too; its kit_sha
    # carries the project's regions, so it is taken from the composed text.
    ack_skeleton=""
    if is_settings_json "$APPLY_FILE"; then
        ack_sha=$(sha256_settings_kit "$kit_full")
    elif [ "$(mode_for_kit_path "$APPLY_FILE")" = "merge" ]; then
        syn=$(region_syntax "$APPLY_FILE")
        tmp_kit=$(mktemp)
        apply_substitutions < "$kit_full" > "$tmp_kit"
        ack_skeleton=$(sha256_skeleton "$syn" "$tmp_kit")
        proj_full="${PROJECT_PATH}/${dest_rel}"
        if [ -f "$proj_full" ] && has_region_markers "$syn" "$proj_full"; then
            tmp_merged=$(mktemp)
            if ! region_awk compose "$syn" "$tmp_kit" "$proj_full" > "$tmp_merged"; then
                rm -f "$tmp_kit" "$tmp_merged"
                echo "sync-dev-kit.sh: could not merge $dest_rel — fix the region markers named above first" >&2
                exit 4
            fi
            ack_sha=$(sha256 "$tmp_merged")
            rm -f "$tmp_merged"
        else
            ack_sha=$(sha256 "$tmp_kit")
        fi
        rm -f "$tmp_kit"
    else
        ack_sha=$(sha256_substituted "$kit_full")
    fi
    [ -z "$ack_sha" ] && { echo "sync-dev-kit.sh: could not hash $APPLY_FILE" >&2; exit 5; }

    update_lockfile_file "$dest_rel" "$ack_sha" "$(mode_for_kit_path "$APPLY_FILE")" "$ack_skeleton"
    echo "sync-dev-kit.sh: acknowledged $dest_rel ($ack_sha) — project file left untouched" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: decline-file
#
# "This project does not want this file." Records the kit's current content as
# a refusal WITHOUT creating the project file.
#
# Why this exists: `new-kit` had only two answers — take it, or be asked again
# on every sync forever. `--ack-file` is not the answer either; it records a
# baseline for a file that does not exist locally, so the next scan reports
# `project-deleted` and trades one recurring nag for another.
#
# The refusal is per kit VERSION, not permanent. Change the file in the kit and
# it is offered again — a consumer that said no to one thing has not said no to
# everything that file might later become.
#
# Undo is just `--apply-file`: applying overwrites the entry and the refusal
# disappears with it.
# ---------------------------------------------------------------------------

if [ "$MODE" = "decline" ]; then
    [ -z "$APPLY_FILE" ] && { echo "sync-dev-kit.sh: --decline-file requires a kit-relative path" >&2; exit 2; }

    load_substitutions

    kit_full="${KIT_PATH}/${APPLY_FILE}"
    dest_rel=$(dest_for_kit_path "$APPLY_FILE")
    [ -z "$dest_rel" ] && { echo "sync-dev-kit.sh: no destination mapping for $APPLY_FILE" >&2; exit 4; }
    [ ! -f "$kit_full" ] && { echo "sync-dev-kit.sh: $APPLY_FILE does not exist in the kit" >&2; exit 4; }

    if [ -f "${PROJECT_PATH}/${dest_rel}" ]; then
        echo "sync-dev-kit.sh: $dest_rel exists in the project — decline is for files you do NOT have. Use --ack-file to keep your version." >&2
        exit 4
    fi

    # The same hash the scan computes for kit_sha, so the next scan can tell
    # "still the file I refused" from "the kit changed it".
    decline_sha=$(sha256_substituted "$kit_full")
    [ -z "$decline_sha" ] && { echo "sync-dev-kit.sh: could not hash $APPLY_FILE" >&2; exit 5; }

    update_lockfile_declined "$dest_rel" "$decline_sha" "$(mode_for_kit_path "$APPLY_FILE")"
    echo "sync-dev-kit.sh: declined $dest_rel — not offered again until the kit changes it" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: remove-patch
#
# The register entry outlives the patch only by mistake: once the project file
# matches the kit again (the kit took the fix, or the patch was reverted), the
# entry would sanction a future edit nobody approved. Sync never edits the
# register on its own — this is called by the walkthrough after the user agrees.
# ---------------------------------------------------------------------------

if [ "$MODE" = "remove-patch" ]; then
    [ -z "$APPLY_FILE" ] && { echo "sync-dev-kit.sh: --remove-patch requires a destination path" >&2; exit 2; }
    load_patches
    entry=$(patch_entry_for "$APPLY_FILE")
    if [ -z "$entry" ]; then
        echo "sync-dev-kit.sh: no patch register entry for $APPLY_FILE" >&2
        exit 4
    fi
    tmp=$(mktemp)
    if ! jq --arg p "$APPLY_FILE" '.patches |= map(select(.path != $p))' "$PATCHES_FILE" > "$tmp"; then
        rm -f "$tmp"
        echo "sync-dev-kit.sh: could not rewrite .claude/.kit-patches.json" >&2
        exit 5
    fi
    mv "$tmp" "$PATCHES_FILE"
    printf '%s\n' "$entry"
    echo "sync-dev-kit.sh: removed the patch register entry for $APPLY_FILE" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: apply-gitignore
# ---------------------------------------------------------------------------

if [ "$MODE" = "apply-gitignore" ]; then
    ADD_FILE="${KIT_PATH}/_claude-project/templates/.gitignore-additions"
    [ -f "$ADD_FILE" ] || { echo "sync-dev-kit.sh: no .gitignore-additions in kit" >&2; exit 4; }

    touch "${PROJECT_PATH}/.gitignore"

    # Comments are held back and flushed only ahead of a rule that is actually
    # being written, so a project that already covers everything gains no
    # orphaned section headers explaining rules that were never added.
    PENDING_COMMENTS=""

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*)
            PENDING_COMMENTS="${PENDING_COMMENTS}${line}\n"
            continue
            ;;
        esac
        # Same predicate the scan uses, so what was reported is what gets written.
        # The literal check stays as the write guard — a rule can be in effect via
        # a broader pattern AND absent as a line, and only the second decides
        # whether appending would duplicate.
        if gitignore_rule_in_effect "$line" || grep -Fxq "$line" "${PROJECT_PATH}/.gitignore"; then
            continue
        fi
        if [ -n "$PENDING_COMMENTS" ]; then
            printf '%b' "$PENDING_COMMENTS" >> "${PROJECT_PATH}/.gitignore"
            PENDING_COMMENTS=""
        fi
        echo "$line" >> "${PROJECT_PATH}/.gitignore"
        echo "sync-dev-kit.sh: added '$line' to .gitignore" >&2
    done < "$ADD_FILE"

    exit 0
fi

# ---------------------------------------------------------------------------
# Mode: finalize
# ---------------------------------------------------------------------------

if [ "$MODE" = "finalize" ]; then
    cd "$KIT_PATH"
    KIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
    KIT_REMOTE=$(git config --get remote.origin.url 2>/dev/null || echo "")
    cd "$PROJECT_PATH"

    if [ ! -f "$LOCKFILE" ]; then
        mkdir -p "$(dirname "$LOCKFILE")"
        echo '{"kitRepo":"","lastSyncedCommit":"","lastSyncedAt":"","files":{}}' > "$LOCKFILE"
    fi

    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # ─── Backfill: record every already-matching kit file ──────────────────
    #
    # A file whose project copy has ALWAYS matched the kit is never handed to
    # --apply-file (it scans `clean` / `clean-converged`, gets silently skipped),
    # so it never earned a lockfile entry. That looks harmless — the content is
    # correct — but it silently breaks DELETION for that file forever:
    #
    #   `removed-kit` is detected by finding a lockfile entry whose kit file no
    #   longer exists. No entry → when the kit later deletes the file, it is gone
    #   from the kit (so the scan does not walk it) AND absent from the lockfile
    #   (so nothing records it was ever kit-managed). The scan reports NOTHING for
    #   it — not `removed-kit`, just invisible — and the dead file lives on in
    #   every consumer permanently.
    #
    # This is not hypothetical: `rules/kit-consumer.md` shipped 2026-06-18, was
    # retired from the kit 2026-07-14 and replaced by kit-maintainer.md, and
    # survived in four consumer projects because it had never once differed.
    #
    # So finalize records an entry for every kit file whose project copy matches
    # the kit's substituted content. Entries written by --apply-file are already
    # current and are overwritten with the identical value (both sides are the
    # SHA of what is on disk). Files that DIFFER are deliberately left alone —
    # an un-applied difference must stay un-baselined so the next scan still
    # surfaces it for review.
    load_substitutions

    KIT_DIRS=()
    [ -d "${KIT_PATH}/_claude-project" ] && KIT_DIRS+=("_claude-project")
    [ -d "${KIT_PATH}/_github-project" ] && KIT_DIRS+=("_github-project")
    [ -d "${KIT_PATH}/_gemini-project" ] && KIT_DIRS+=("_gemini-project")
    ALL_KIT_FILES=$(cd "$KIT_PATH" && find "${KIT_DIRS[@]}" -type f ! -name ".DS_Store" 2>/dev/null | sort)

    BACKFILL="{}"
    BACKFILL_N=0
    MAPPED="[]"
    while IFS= read -r kit_rel; do
        [ -z "$kit_rel" ] && continue
        is_skipped "$kit_rel" && continue
        dest_rel=$(dest_for_kit_path "$kit_rel")
        [ -z "$dest_rel" ] && continue
        MAPPED=$(jq -c --arg d "$dest_rel" '. + [$d]' <<<"$MAPPED")
        [ -f "${PROJECT_PATH}/${dest_rel}" ] || continue

        is_protected_dest "$dest_rel" && continue
        file_mode=$(mode_for_kit_path "$kit_rel")
        proj_full="${PROJECT_PATH}/${dest_rel}"
        proj_sha=$(sha256 "$proj_full")
        skeleton=""

        if [ "$file_mode" = "merge" ]; then
            # A merge file matches when composing the kit around the project's
            # own regions reproduces the project file exactly — its regions may
            # hold anything, its kit text must be the kit's.
            syn=$(region_syntax "$kit_rel")
            has_region_markers "$syn" "$proj_full" || continue
            tmp_kit=$(mktemp)
            tmp_merged=$(mktemp)
            apply_substitutions < "${KIT_PATH}/${kit_rel}" > "$tmp_kit"
            if region_awk compose "$syn" "$tmp_kit" "$proj_full" > "$tmp_merged" 2>/dev/null; then
                kit_sha=$(sha256 "$tmp_merged")
                skeleton=$(sha256_skeleton "$syn" "$tmp_kit")
            else
                kit_sha=""
            fi
            rm -f "$tmp_kit" "$tmp_merged"
        elif is_settings_json "$kit_rel"; then
            kit_sha=$(sha256_settings_kit "${KIT_PATH}/${kit_rel}")
            proj_sha=$(sha256_settings_proj "$proj_full")
        else
            kit_sha=$(sha256_substituted "${KIT_PATH}/${kit_rel}")
        fi
        [ -n "$kit_sha" ] && [ "$kit_sha" = "$proj_sha" ] || continue

        already=$(jq -r --arg k "$dest_rel" '
            (.files[$k] // "") | if type == "object" then ((.sha // "") + "|" + (.skeleton // "") + "|" + (.mode // "owned")) else . + "||owned" end
        ' "$LOCKFILE")
        [ "$already" = "${kit_sha}|${skeleton}|${file_mode}" ] && continue

        BACKFILL=$(jq -c --arg k "$dest_rel" --arg v "$kit_sha" \
            --arg m "$file_mode" --arg s "$skeleton" \
            '. + {($k): ({sha: $v, mode: $m} + (if $s == "" then {} else {skeleton: $s} end))}' <<<"$BACKFILL")
        BACKFILL_N=$((BACKFILL_N + 1))
    done <<< "$ALL_KIT_FILES"

    # An entry nothing in the kit maps to, for a file the project does not
    # have, records nothing: the scan skips it, and it is dropped here.
    STALE="[]"
    while IFS= read -r dest_rel; do
        [ -z "$dest_rel" ] && continue
        [ -e "${PROJECT_PATH}/${dest_rel}" ] && continue
        jq -e --arg d "$dest_rel" 'index($d) == null' <<<"$MAPPED" >/dev/null || continue
        STALE=$(jq -c --arg d "$dest_rel" '. + [$d]' <<<"$STALE")
    done <<< "$(jq -r '.files | keys[]' "$LOCKFILE" 2>/dev/null)"

    tmp=$(mktemp)
    jq --arg repo "$KIT_REMOTE" --arg commit "$KIT_COMMIT" --arg ts "$NOW" \
        --argjson backfill "$BACKFILL" --argjson stale "$STALE" \
        '.kitRepo = $repo | .lastSyncedCommit = $commit | .lastSyncedAt = $ts
         | .files = ((.files + $backfill) | with_entries(select(.key as $k | $stale | index($k) == null)))' \
        "$LOCKFILE" > "$tmp"
    mv "$tmp" "$LOCKFILE"

    echo "sync-dev-kit.sh: lockfile finalized (kit commit $KIT_COMMIT)" >&2
    if [ "$BACKFILL_N" -gt 0 ]; then
        echo "sync-dev-kit.sh: baselined $BACKFILL_N already-matching file(s) that had no lockfile entry — the kit can now propagate their deletion." >&2
    fi

    # That's the whole job: sync APPLIES kit updates to the working tree (via
    # --apply-file) and stamps the lockfile. It does NOT commit or push —
    # committing is gitflow's job, not sync's. The synced `.claude/` changes
    # plus the lockfile bump are left as a normal uncommitted change for the
    # user to land however they want. `/ship-main` is the natural fit (commits
    # + pushes straight to main in one step). Keeping git entirely out of sync
    # removes the bootstrap "which /commit runs after sync?" problem and stops
    # duplicating logic that now lives in ship-main.sh / deploy.sh.
    if [ -n "$(git status --porcelain)" ]; then
        echo "sync-dev-kit.sh: synced — kit updates + lockfile are uncommitted in your working tree." >&2
        echo "  Land them with /ship-main (commits + pushes straight to main)." >&2
    else
        echo "sync-dev-kit.sh: already in sync — nothing to commit." >&2
    fi
    exit 0
fi
