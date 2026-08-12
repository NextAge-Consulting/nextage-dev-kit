#!/bin/bash
# Sync Dev Kit — three-way diff/review sync from kit template to consumer project.
#
# Modes:
#   --scan                  Output JSON report of state per file. Non-interactive.
#   --apply-file <kit-rel>  Apply one kit file to project + update lockfile entry.
#   --decline-file <kit-rel> Record that this project does NOT want the file. It stops
#                           being offered until the KIT changes it again.
#   --ack-file <kit-rel>    Record the kit's current content as the baseline WITHOUT
#                           writing the project file — "seen it, keeping mine" for a
#                           `template` file. Silences a declined `template-drift` until
#                           the kit changes again.
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
        --apply-gitignore)  MODE="apply-gitignore"; shift 1 ;;
        --finalize)         MODE="finalize"; shift 1 ;;
        *) echo "sync-dev-kit.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "sync-dev-kit.sh: mode required (--scan | --apply-file <path> | --ack-file <path> | --decline-file <path> | --apply-gitignore | --finalize)" >&2
    exit 2
fi

# ---------------------------------------------------------------------------
# Locate kit
# ---------------------------------------------------------------------------
CONFIG_FILE="$HOME/.claude/dev-kit-config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "sync-dev-kit.sh: $CONFIG_FILE missing. Run install-kit handbook steps first." >&2
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
# See HANDBOOK §9 for the design rationale.

# Refuse to run from inside the kit itself
if [ "$PROJECT_PATH" = "$KIT_PATH" ]; then
    echo "sync-dev-kit.sh: running from the kit repo itself is not supported." >&2
    echo "  To update kit bootstrap in ~/.claude/, use /install-kit." >&2
    exit 4
fi

LOCKFILE="${PROJECT_PATH}/.claude/.kit-sync.json"
# Global bootstrap files live in kit's `_claude-global/` — not scanned here.
# Project-owned rules under `_claude-project/rules/project/` are matched by pattern
# below (is_skipped function), not by explicit list.
SKIP_LIST=(
    "_claude-project/templates/README.md"
    # Kit-internal documentation ABOUT the testing templates, for someone
    # reading the kit. The templates themselves sync (mode `template`, destination
    # from SHARED_MODULE_DIR); this file explaining them would land in the
    # consumer's test directory, where it is noise.
    "_claude-project/templates/testing/README.md"
    # sync-substitutions.json is project-specific from the moment it's filled
    # in; every project's values differ, so kit's empty-template version
    # always conflicts after first sync. Skip unconditionally. First-time
    # bootstrap (copying the template) is handled via /install-kit or
    # manually per HANDBOOK instructions.
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
# (org name, repo slug, release-bot App slug, etc.). Consumer projects define
# the actual values in `.claude/sync-substitutions.json`:
#
#   {
#     "OWNER_REPO": "acme/widget",
#     "RELEASE_BOT_APP": "acme-release-bot",
#     "ORG": "acme"
#   }
#
# sync-dev-kit applies these substitutions to kit content in two places:
#   1. During scan — computes kit SHA against substituted content, so a kit
#      template with `{{OWNER_REPO}}` matching a project file with `acme/widget`
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
    # and /install-kit does not handle it either. Without bootstrap, every
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
    # HANDBOOK §9.7 "Adding a new placeholder" step 6 assumed a new kit key reaches
    # existing consumers because this file syncs as a `kit-only` diff. It does not:
    # the file is in SKIP_LIST (every project's values differ, so the kit's empty
    # template would conflict forever after first sync), so that delivery path does
    # not exist and bootstrap only ever fires on a project that lacks the file. A
    # key added to the kit AFTER a project bootstrapped therefore never arrived.
    # Canonical `{{KEY}}` placeholders at least nagged — the unsubstituted marker
    # survived into the synced file as a standing diff. Runtime-read keys (read via
    # `jq` at execution time, never substituted into any template — AWS_*, and see
    # HANDBOOK §9.7 "Runtime-read placeholders") have no marker anywhere, so they
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
# See HANDBOOK §9.6.
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

# Read one substitution value. Empty when the key is absent, null, or blank —
# which is how a project says "this does not apply to me".
subst_value() {
    printf '%s' "$SUBSTITUTIONS_JSON" | jq -r --arg k "$1" '.[$k] // "" | if type == "string" then . else "" end'
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
            echo "biome.json"
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
        _claude-project/templates/scripts/check-tanstack.mjs)
            echo "scripts/check-tanstack.mjs"
            ;;
        _claude-project/templates/ui-inventory.md)
            # Lands in the consumer's PROJECT-OWNED rules dir. It cannot ship
            # from `_claude-project/rules/project/` — `is_skipped` skips that
            # whole tree, by design, so nothing there ever reaches a consumer.
            # Shipping it from templates/ with an explicit destination is what
            # lets the kit seed one file into a directory it otherwise never
            # touches. Mode `template`: every line of the content is the
            # project's own inventory.
            echo ".claude/rules/project/ui-inventory.md"
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
            # README.md and other meta files — skipped via SKIP_LIST or unmapped.
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

# Sync mode for a kit file. Two values:
#
#   owned    — the kit owns the content. Consumers must not edit it
#              (`block-kit-edit.sh` denies the write); divergence is a `conflict`
#              reconciled toward the kit. Default, and the common case.
#   template — the kit ships a STARTING POINT; the project owns the file and has
#              final say. Consumers may edit it freely (the hook allows the
#              write), and divergence reports as `template-drift`: the kit's delta
#              is shown for the project to take or ignore, never reconciled.
#
# Use `template` only where content genuinely must vary per project — a value that
# differs, not a preference that differs. When in doubt it is `owned`: a file
# marked `template` stops receiving enforced updates, and that is hard to notice.
#
# Mode is a property of the KIT file, not of the consumer, so it is declared here
# and copied into each consumer's lockfile on apply — `block-kit-edit.sh` runs on
# machines where the kit is not checked out and cannot ask the kit at edit time.
mode_for_kit_path() {
    local kit_rel="$1"
    case "$kit_rel" in
        # Vitest scaffolding. The project owns these outright: test layout,
        # TZ pinning, and the database topology they set up are all
        # project-specific, and a consumer that adapts one must not have the
        # edit reverted. The kit still ships improvements — they surface as
        # `kit-only` (offered) when untouched, `template-drift` (informational)
        # when adapted. Per-project deploy workflows are the other prospective
        # member; they are not synced at all yet.
        _claude-project/templates/testing/*) echo "template" ;;
        # The UI inventory. `owned` is not even coherent here: the file's whole
        # purpose is to enumerate THIS project's components and patterns, so a
        # consumer that has not rewritten it entirely has not adopted it. The
        # kit ships the shape; the content is the project's from first sync.
        _claude-project/templates/ui-inventory.md) echo "template" ;;
        *) echo "owned" ;;
    esac
}

# Baseline SHA from the lockfile. Tolerates both schemas: the legacy bare-string
# value (implicitly mode `owned`) and the current {sha, mode} object.
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

update_lockfile_file() {
    local dest_rel="$1"
    local new_sha="$2"
    local mode="${3:-owned}"

    mkdir -p "$(dirname "$LOCKFILE")"
    if [ ! -f "$LOCKFILE" ]; then
        echo '{"kitRepo":"","lastSyncedCommit":"","lastSyncedAt":"","files":{}}' > "$LOCKFILE"
    fi

    local tmp
    tmp=$(mktemp)
    if [ -n "$new_sha" ]; then
        jq --arg k "$dest_rel" --arg v "$new_sha" --arg m "$mode" \
            '.files[$k] = {sha: $v, mode: $m}' "$LOCKFILE" > "$tmp"
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

    FILE_ENTRIES="[]"
    while IFS= read -r kit_rel; do
        [ -z "$kit_rel" ] && continue
        is_skipped "$kit_rel" && continue

        dest_rel=$(dest_for_kit_path "$kit_rel")
        [ -z "$dest_rel" ] && continue

        kit_full="${KIT_PATH}/${kit_rel}"
        proj_full="${PROJECT_PATH}/${dest_rel}"

        # kit_sha reflects content AFTER placeholder substitution, so a kit
        # template with {{KEY}} matches a project file with the real value.
        # proj_sha is the raw project file (already the real values).
        # settings.json takes a separate path: both sides are canonicalized
        # via jq before SHA. See HANDBOOK §9.6.
        if is_settings_json "$kit_rel"; then
            kit_sha=$(sha256_settings_kit "$kit_full")
            proj_sha=$(sha256_settings_proj "$proj_full")
        else
            kit_sha=$(sha256_substituted "$kit_full")
            proj_sha=$(sha256 "$proj_full")
        fi
        baseline_sha=$(load_baseline_sha "$dest_rel")

        [ -z "$kit_sha" ] && continue

        declined_sha=$(load_declined_sha "$dest_rel")

        # A declined file has no project copy BY DESIGN, so it must be
        # resolved before the absent-file branches below — otherwise a
        # refusal reads as a deletion and nags just as loudly as the offer
        # it replaced. Declining is not permanent: when the kit changes the
        # file, the recorded SHA no longer matches and it is offered again,
        # which is the whole point of recording a SHA rather than a flag.
        if [ -n "$declined_sha" ] && [ -z "$proj_sha" ]; then
            if [ "$kit_sha" = "$declined_sha" ]; then
                state="declined"
            else
                state="new-kit"
            fi
        elif [ -z "$proj_sha" ] && [ -z "$baseline_sha" ]; then
            state="new-kit"
        elif [ -z "$proj_sha" ] && [ -n "$baseline_sha" ]; then
            state="project-deleted"
        elif [ "$kit_sha" = "$baseline_sha" ] && [ "$proj_sha" = "$baseline_sha" ]; then
            state="clean"
        elif [ "$kit_sha" != "$baseline_sha" ] && [ "$proj_sha" = "$baseline_sha" ]; then
            state="kit-only"
        elif [ "$kit_sha" = "$baseline_sha" ] && [ "$proj_sha" != "$baseline_sha" ]; then
            state="project-only"
        elif [ "$kit_sha" != "$baseline_sha" ] && [ "$proj_sha" != "$baseline_sha" ]; then
            if [ "$kit_sha" = "$proj_sha" ]; then
                state="clean-converged"
            else
                state="conflict"
            fi
        elif [ -z "$baseline_sha" ] && [ -n "$proj_sha" ]; then
            if [ "$kit_sha" = "$proj_sha" ]; then
                state="clean-first"
            else
                state="conflict-first"
            fi
        else
            state="unknown"
        fi

        # Template files: the project owns the content, so a two-sided divergence
        # is not something to reconcile toward the kit. Report it as drift — the
        # kit's delta is informational, the project decides. Every other state
        # keeps its meaning: `kit-only` still offers the update (the project has
        # not customized), `project-only` is still a silent skip.
        file_mode=$(mode_for_kit_path "$kit_rel")
        if [ "$file_mode" = "template" ]; then
            case "$state" in
                conflict|conflict-first) state="template-drift" ;;
            esac
        fi

        FILE_ENTRIES=$(echo "$FILE_ENTRIES" | jq \
            --arg kit_path "$kit_rel" \
            --arg dest_path "$dest_rel" \
            --arg state "$state" \
            --arg mode "$file_mode" \
            --arg kit_sha "$kit_sha" \
            --arg proj_sha "$proj_sha" \
            --arg baseline_sha "$baseline_sha" \
            '. + [{kit_path: $kit_path, dest_path: $dest_path, state: $state, mode: $mode, kit_sha: $kit_sha, project_sha: $proj_sha, baseline_sha: $baseline_sha}]')
    done <<< "$KIT_FILES"

    # Removed-from-kit: files in lockfile not present in kit
    if [ -f "$LOCKFILE" ]; then
        LOCKED_FILES=$(jq -r '.files | keys[]' "$LOCKFILE" 2>/dev/null || echo "")
        while IFS= read -r dest_rel; do
            [ -z "$dest_rel" ] && continue
            still_in_kit=$(echo "$FILE_ENTRIES" | jq --arg d "$dest_rel" 'any(.[]; .dest_path == $d)')
            if [ "$still_in_kit" = "false" ]; then
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
            if [ ! -f "${PROJECT_PATH}/.gitignore" ] || ! grep -Fxq "$line" "${PROJECT_PATH}/.gitignore"; then
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
        '{kit_path: $kit_path, kit_commit: $kit_commit, kit_clean: $kit_clean, kit_behind_remote: $kit_behind, files: $files, gitignore_additions_missing: $gitignore_missing}'

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
    [ -z "$dest_rel" ] && { echo "sync-dev-kit.sh: no destination mapping for $APPLY_FILE" >&2; exit 4; }

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
    # file matches the SHA the scan computed. See HANDBOOK §9.6.
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
    else
        apply_substitutions < "$kit_full" > "$proj_full"
        case "$APPLY_FILE" in
            *.sh) chmod +x "$proj_full" ;;
        esac
        new_sha=$(sha256 "$proj_full")
    fi

    # Lockfile baseline SHA tracks the SUBSTITUTED (and for settings.json,
    # overlaid + canonicalized) kit content — same as what got written to
    # the project. This keeps subsequent scans clean until the kit template
    # changes or the substitution value changes.
    update_lockfile_file "$dest_rel" "$new_sha" "$(mode_for_kit_path "$APPLY_FILE")"

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
# Why this exists: the baseline only ever advanced when a change was APPLIED,
# so declining a `template-drift` left the baseline behind the kit and the
# same drift re-reported on every subsequent sync, forever. A signal that
# cannot be dismissed is one people learn to skip past, which costs more than
# it saves. After an ack the file reports `project-only` (a silent skip) until
# the kit changes again — at which point you are told once more, which is the
# whole point.
#
# Deliberately NOT restricted to `template` files, and that is not an
# oversight to be corrected by a caller that refuses `owned` outright. What
# makes an ack wrong is acking a kit change that was never INCORPORATED —
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
    # as unchanged and reports `project-only` rather than drift.
    if is_settings_json "$APPLY_FILE"; then
        ack_sha=$(sha256_settings_kit "$kit_full")
    else
        ack_sha=$(sha256_substituted "$kit_full")
    fi
    [ -z "$ack_sha" ] && { echo "sync-dev-kit.sh: could not hash $APPLY_FILE" >&2; exit 5; }

    update_lockfile_file "$dest_rel" "$ack_sha" "$(mode_for_kit_path "$APPLY_FILE")"
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
# Mode: apply-gitignore
# ---------------------------------------------------------------------------

if [ "$MODE" = "apply-gitignore" ]; then
    ADD_FILE="${KIT_PATH}/_claude-project/templates/.gitignore-additions"
    [ -f "$ADD_FILE" ] || { echo "sync-dev-kit.sh: no .gitignore-additions in kit" >&2; exit 4; }

    touch "${PROJECT_PATH}/.gitignore"

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in \#*)
            if ! grep -Fxq "$line" "${PROJECT_PATH}/.gitignore"; then
                echo "$line" >> "${PROJECT_PATH}/.gitignore"
            fi
            continue
            ;;
        esac
        if ! grep -Fxq "$line" "${PROJECT_PATH}/.gitignore"; then
            echo "$line" >> "${PROJECT_PATH}/.gitignore"
            echo "sync-dev-kit.sh: added '$line' to .gitignore" >&2
        fi
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
    while IFS= read -r kit_rel; do
        [ -z "$kit_rel" ] && continue
        is_skipped "$kit_rel" && continue
        dest_rel=$(dest_for_kit_path "$kit_rel")
        [ -z "$dest_rel" ] && continue
        [ -f "${PROJECT_PATH}/${dest_rel}" ] || continue

        kit_sha=$(sha256_substituted "${KIT_PATH}/${kit_rel}" "$kit_rel")
        proj_sha=$(sha256 "${PROJECT_PATH}/${dest_rel}")
        [ -n "$kit_sha" ] && [ "$kit_sha" = "$proj_sha" ] || continue

        already=$(jq -r --arg k "$dest_rel" '
            (.files[$k] // "") | if type == "object" then (.sha // "") else . end
        ' "$LOCKFILE")
        [ "$already" = "$kit_sha" ] && continue

        BACKFILL=$(jq -c --arg k "$dest_rel" --arg v "$kit_sha" \
            --arg m "$(mode_for_kit_path "$kit_rel")" \
            '. + {($k): {sha: $v, mode: $m}}' <<<"$BACKFILL")
        BACKFILL_N=$((BACKFILL_N + 1))
    done <<< "$ALL_KIT_FILES"

    tmp=$(mktemp)
    jq --arg repo "$KIT_REMOTE" --arg commit "$KIT_COMMIT" --arg ts "$NOW" \
        --argjson backfill "$BACKFILL" \
        '.kitRepo = $repo | .lastSyncedCommit = $commit | .lastSyncedAt = $ts
         | .files = (.files + $backfill)' \
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
