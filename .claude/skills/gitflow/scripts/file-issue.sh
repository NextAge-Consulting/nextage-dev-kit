#!/bin/bash
# gitflow file-issue: create an issue and put it on the project board in one step.
# Usage: file-issue.sh --title "<title>" --body-file <path> [--repo <owner/name>]
#
# Prints the new issue's URL on stdout. --repo defaults to this repository.
#
# The board is the one this repository's gitflow is configured for
# (GITFLOW_PROJECT_ID). The issue goes on it when it is filed: the board's
# "Auto-add to project" workflow is only a fallback, because GitHub sets it up per
# repository and a new repository is easy to forget. An issue filed in a repository
# under another owner — a kit issue from a client project — is not put on this
# board, and the script says so.
#
# Exit codes:
#   2  bad arguments
#   8  gh missing
#   9  the issue could not be created
#  11  the issue was created but could not be put on the board — its URL is printed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_claude-project/skills/gitflow/scripts/issue_helpers.sh
source "$SCRIPT_DIR/issue_helpers.sh"

TITLE=""
BODY_FILE=""
REPO=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --title)     TITLE="$2"; shift 2 ;;
        --body-file) BODY_FILE="$2"; shift 2 ;;
        --repo)      REPO="$2"; shift 2 ;;
        *) echo "file-issue.sh: unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ -z "$TITLE" ] || [ -z "$BODY_FILE" ] || [ ! -f "$BODY_FILE" ]; then
    echo "usage: file-issue.sh --title \"<title>\" --body-file <path> [--repo <owner/name>]" >&2
    exit 2
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "file-issue.sh: gh is required (brew install gh, then gh auth login)." >&2
    exit 8
fi

HERE_SLUG=$(gitflow_repo_slug)
[ -n "$REPO" ] || REPO="$HERE_SLUG"

if ! URL=$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" 2>&1); then
    echo "file-issue.sh: could not create the issue on $REPO: $URL" >&2
    exit 9
fi
URL=$(printf '%s\n' "$URL" | tail -1)
NUM="${URL##*/}"
echo "$URL"

load_gitflow_project_config
if [ -z "${GITFLOW_PROJECT_ID:-}" ]; then
    echo "gitflow: filed $REPO#$NUM — this repository has no project board configured." >&2
    exit 0
fi
if [ "${REPO%%/*}" != "${HERE_SLUG%%/*}" ]; then
    echo "gitflow: filed $REPO#$NUM — it belongs to another owner, so it is not put on this repository's board." >&2
    exit 0
fi
if ! add_issue_to_project "$REPO" "$NUM" >/dev/null; then
    echo "file-issue.sh: $URL was created but is not on the board. Fix the cause above, then add it by hand." >&2
    exit 11
fi
echo "gitflow: filed $REPO#$NUM and put it on the board." >&2
