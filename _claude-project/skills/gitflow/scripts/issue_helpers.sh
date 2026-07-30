#!/bin/bash
# gitflow issue helpers: shared functions for /work and /link to resolve
# GitHub issues, link them to the current branch, transition project status,
# assign the current user, and dump issue context for the Claude session.
#
# Sourced by work.sh and link.sh.
#
# ─── Design notes ──────────────────────────────────────────────────────────
# - Issue→branch linking is stored in git config (branch-scoped):
#     branch.<name>.gitflow-issues = "23 25 26"
#   Git auto-removes branch config on `git branch -D`, so stale state doesn't
#   accumulate after merges.
#
# - `/open-pr` reads this config and prepends `Closes #<N>` lines to the PR
#   body, which fires GitHub's native auto-close on merge (no Project
#   workflow dependency for the core closure behavior).
#
# - Failure semantics (zero-tolerance fail-loud-when-configured):
#   * GITFLOW_PROJECT_ID empty → feature off, silent skip (kit default).
#   * GITFLOW_PROJECT_ID populated but other config missing → ERROR + return 1.
#   * Issue not on configured project → ERROR + return 1.
#   * GraphQL mutation fails (typically missing `project` scope) → ERROR + return 1.
#   * Issue assignment failure → ERROR + return 1 (always — not gated on PROJECT_ID).
#   Caller scripts (link.sh, work.sh) run under `set -e` so a non-zero return
#   propagates to script exit; the user retries after fixing the config /
#   scope / project-membership cause. All GraphQL operations are idempotent.
#
# - Config (project/field/option IDs) comes from .claude/gitflow-project.conf
#   at repo root. Empty values are explicit feature-off; partial config
#   (PROJECT_ID set, STATUS_FIELD_ID missing) is an error, not silent.
#   Kit template ships this file empty; per-repo setup fills it in.

# ─── Config loading ────────────────────────────────────────────────────────
# Call once per script; subsequent invocations re-source cleanly.
load_gitflow_project_config() {
    local config_path
    config_path="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/gitflow-project.conf"
    if [ -f "$config_path" ]; then
        # shellcheck disable=SC1090
        source "$config_path"
    fi
}

# ─── Issue-number parsing ──────────────────────────────────────────────────
# parse_issue_csv "23,25,#26 #42" → echoes "23 25 26 42" (space-separated)
# Accepts any combination of commas, spaces, and optional # prefixes.
parse_issue_csv() {
    local raw="$1"
    printf '%s' "$raw" \
        | tr ',' ' ' \
        | tr -s ' ' \
        | sed -E 's/#//g' \
        | tr ' ' '\n' \
        | grep -E '^[0-9]+$' \
        | tr '\n' ' ' \
        | sed -E 's/ +$//'
}

# ─── GitHub repo resolution ────────────────────────────────────────────────
# Resolves owner/repo from origin remote URL. Echoes "owner/repo".
gitflow_repo_slug() {
    local url
    url=$(git config --get remote.origin.url)
    # Handles https://github.com/OWNER/REPO.git and git@github.com:OWNER/REPO.git
    echo "$url" | sed -E 's#(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?#\2#'
}

# ─── Issue validation ──────────────────────────────────────────────────────
# validate_issue <number> → returns 0 if issue exists and is accessible.
# Prints issue title on success, error on stderr on failure.
validate_issue() {
    local num="$1"
    local title
    if ! title=$(gh issue view "$num" --json title --jq .title 2>&1); then
        echo "issue_helpers: issue #$num not found or inaccessible: $title" >&2
        return 1
    fi
    printf '%s' "$title"
}

# ─── Issue context dump (for Claude session) ───────────────────────────────
# dump_issue_context <number> — prints title, body, and comments to stdout
# in a format Claude consumes directly as part of the command output.
dump_issue_context() {
    local num="$1"
    echo
    echo "════════════════════════════════════════════════════════════════"
    echo " ISSUE #$num"
    echo "════════════════════════════════════════════════════════════════"
    gh issue view "$num" --json number,title,state,labels,author,body,comments \
        --template '
{{- "Title: " -}}{{ .title }}
{{ "State: " -}}{{ .state -}} | Author: {{ .author.login -}} | Labels: {{ range .labels }}{{ .name }} {{ end -}}

── Body ────────────────────────────────────────────────────────
{{ .body }}
{{ if .comments }}
── Comments ({{ len .comments }}) ─────────────────────────────────
{{ range .comments -}}
{{ .author.login -}}  ({{ .createdAt -}})
{{ .body }}
────────────────────────────────────────────────────────────────
{{ end -}}
{{ end -}}
'
}

# ─── Slug from issue title (for branch name) ───────────────────────────────
# slug_from_issue <number> [type] — echoes "<type>/<slug>" where type defaults
# to "feat" and slug is derived from the issue title (lowercased, non-alnum
# to -, truncated to 40 chars). Issue # is NOT prefixed: a branch may close
# multiple issues and embedding one number is misleading. Issue↔branch link
# lives in git config; collisions resolved by work.sh (resolve_collision).
slug_from_issue() {
    local num="$1"
    local type="${2:-feat}"
    local title
    title=$(gh issue view "$num" --json title --jq .title 2>/dev/null)
    [ -z "$title" ] && title="issue-$num"

    local slug
    slug=$(printf '%s' "$title" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-40 \
        | sed -E 's/-+$//')
    [ -z "$slug" ] && slug="changes"

    echo "${type}/${slug}"
}

# ─── Branch ↔ issue link storage (git config) ──────────────────────────────
# link_issue_to_branch <issue_num> [branch_name]
# Stores in git config: branch.<name>.gitflow-issues = "23 25 26" (space-sep).
# Idempotent: re-linking the same issue is a no-op.
link_issue_to_branch() {
    local num="$1"
    local branch="${2:-$(git branch --show-current)}"
    local key="branch.${branch}.gitflow-issues"
    local current
    current=$(git config --local --get "$key" 2>/dev/null || echo "")

    # Check if already linked (idempotent).
    for existing in $current; do
        if [ "$existing" = "$num" ]; then
            return 0
        fi
    done

    local new_list
    if [ -z "$current" ]; then
        new_list="$num"
    else
        new_list="$current $num"
    fi
    git config --local "$key" "$new_list"
}

# read_branch_linked_issues [branch_name] — echoes space-separated issue numbers.
read_branch_linked_issues() {
    local branch="${1:-$(git branch --show-current)}"
    git config --local --get "branch.${branch}.gitflow-issues" 2>/dev/null || echo ""
}

# ─── Project status transition ─────────────────────────────────────────────
# _move_issue_to_status <issue_num> <option_id_var_name> <label>
# Internal helper. <option_id_var_name> is the NAME of the env var holding
# the GraphQL option ID for the target status (e.g. GITFLOW_STATUS_STAGED_ID).
# Resolved indirectly so the wrappers stay one-liners.
#
# Failure semantics (zero-tolerance fail-loud-when-configured):
#   - GITFLOW_PROJECT_ID empty → silent skip, return 0 (feature off).
#   - GITFLOW_PROJECT_ID set + GITFLOW_STATUS_FIELD_ID empty → ERROR + return 1.
#   - GITFLOW_PROJECT_ID set + the requested status option ID empty → ERROR + return 1
#     (this status isn't configured for this project — populate
#     `.claude/sync-substitutions.json` or skip the call).
#   - Issue not found on configured project → ERROR + return 1.
#   - GraphQL mutation fails → ERROR + return 1 (almost always missing
#     `project` scope on gh auth; remediation message says so).
_move_issue_to_status() {
    local num="$1"
    local option_id_var="$2"
    local label="$3"
    load_gitflow_project_config

    # Feature-off path: PROJECT_ID empty = consumer didn't opt in.
    if [ -z "${GITFLOW_PROJECT_ID:-}" ]; then
        return 0
    fi

    # Configured-but-broken: PROJECT_ID set, FIELD_ID missing.
    if [ -z "${GITFLOW_STATUS_FIELD_ID:-}" ]; then
        echo "issue_helpers: ERROR — GITFLOW_PROJECT_ID is set but GITFLOW_STATUS_FIELD_ID is empty in .claude/gitflow-project.conf." >&2
        echo "  Fix: populate GITFLOW_STATUS_FIELD_ID in .claude/sync-substitutions.json, re-run /sync-dev-kit --finalize, retry." >&2
        echo "  Discover the field ID with the gh api graphql query in .claude/gitflow-project.conf header." >&2
        return 1
    fi

    # Configured-but-broken: PROJECT_ID set, target option ID empty.
    local option_id="${!option_id_var:-}"
    if [ -z "$option_id" ]; then
        echo "issue_helpers: ERROR — GITFLOW_PROJECT_ID is set but $option_id_var is empty." >&2
        echo "  This status ('$label') isn't configured for this project. Fix one of:" >&2
        echo "    - Populate $option_id_var in .claude/sync-substitutions.json (re-run /sync-dev-kit --finalize)." >&2
        echo "    - If this project's board doesn't have a '$label' column, add $option_id_var to _intentionally_empty in .claude/sync-substitutions.json." >&2
        return 1
    fi

    local repo_slug owner repo
    repo_slug=$(gitflow_repo_slug)
    owner="${repo_slug%/*}"
    repo="${repo_slug#*/}"

    # Find the project item ID for this issue on our configured project.
    local item_id graphql_out
    if ! graphql_out=$(gh api graphql -f query="
        query(\$owner: String!, \$repo: String!, \$num: Int!) {
            repository(owner: \$owner, name: \$repo) {
                issue(number: \$num) {
                    projectItems(first: 20) {
                        nodes { id project { id } }
                    }
                }
            }
        }" \
        -f owner="$owner" -f repo="$repo" -F num="$num" 2>&1); then
        echo "issue_helpers: ERROR — GraphQL lookup failed for issue #$num: $graphql_out" >&2
        echo "  Most likely cause: gh token missing 'project' scope. Fix: gh auth refresh -s project, retry." >&2
        return 1
    fi
    item_id=$(printf '%s' "$graphql_out" \
        | jq -r --arg pid "$GITFLOW_PROJECT_ID" \
            '.data.repository.issue.projectItems.nodes[]? | select(.project.id == $pid) | .id' \
        | head -1)

    if [ -z "$item_id" ]; then
        echo "issue_helpers: ERROR — issue #$num is not on the configured project (PROJECT_ID=$GITFLOW_PROJECT_ID)." >&2
        echo "  Fix one of:" >&2
        echo "    - Enable the project's 'Auto-add to project' workflow (Settings → Workflows → Auto-add to project)." >&2
        echo "    - Manually add issue #$num to the project, then retry." >&2
        echo "    - Verify GITFLOW_PROJECT_ID in .claude/sync-substitutions.json matches the project this repo's issues live on." >&2
        return 1
    fi

    # Update the Status field to the requested option.
    local mutation_out
    if ! mutation_out=$(gh api graphql -f query="
        mutation(\$pid: ID!, \$iid: ID!, \$fid: ID!, \$oid: String!) {
            updateProjectV2ItemFieldValue(input: {
                projectId: \$pid
                itemId: \$iid
                fieldId: \$fid
                value: { singleSelectOptionId: \$oid }
            }) { projectV2Item { id } }
        }" \
        -f pid="$GITFLOW_PROJECT_ID" \
        -f iid="$item_id" \
        -f fid="$GITFLOW_STATUS_FIELD_ID" \
        -f oid="$option_id" 2>&1); then
        echo "issue_helpers: ERROR — failed to update project status for #$num to '$label': $mutation_out" >&2
        echo "  Most likely cause: gh token missing 'project' scope. Fix: gh auth refresh -s project, retry." >&2
        echo "  Less common: the option ID ($option_id_var=$option_id) doesn't belong to GITFLOW_STATUS_FIELD_ID — re-run discovery and update .claude/sync-substitutions.json." >&2
        return 1
    fi

    echo "issue_helpers: moved #$num to $label on the project" >&2
}

# Public wrappers. Signature stays single-arg so call sites don't drift.
move_issue_to_in_progress() { _move_issue_to_status "$1" GITFLOW_STATUS_IN_PROGRESS_ID "In Progress"; }
move_issue_to_staged()      { _move_issue_to_status "$1" GITFLOW_STATUS_STAGED_ID      "Staged"; }
move_issue_to_done()        { _move_issue_to_status "$1" GITFLOW_STATUS_DONE_ID        "Done"; }

# ─── Assign current user ───────────────────────────────────────────────────
# assign_issue_to_current_user <issue_num>
# Fail-loud: assignment isn't gated on project-board config (it's a plain
# `gh issue edit`), so the only failure modes are gh auth missing or the
# `gh` CLI itself broken. Either is a user-visible problem worth surfacing.
assign_issue_to_current_user() {
    local num="$1"
    local login
    if ! login=$(gh api user --jq .login 2>&1); then
        echo "issue_helpers: ERROR — could not determine current user for assignment of #$num: $login" >&2
        echo "  Fix: gh auth login (or gh auth status to inspect current credential), retry." >&2
        return 1
    fi
    if [ -z "$login" ]; then
        echo "issue_helpers: ERROR — gh api user returned empty login for assignment of #$num." >&2
        echo "  Fix: gh auth status, gh auth login, retry." >&2
        return 1
    fi

    local edit_out
    if ! edit_out=$(gh issue edit "$num" --add-assignee "$login" 2>&1); then
        echo "issue_helpers: ERROR — failed to assign #$num to $login: $edit_out" >&2
        echo "  Fix: confirm gh token has 'repo' scope (gh auth refresh -s repo) and the repo allows assigning the current user, retry." >&2
        return 1
    fi

    echo "issue_helpers: assigned #$num to $login" >&2
}
