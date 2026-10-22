#!/bin/bash
# /sync-dev-kit launcher — finds this machine's dev-kit clone and runs its sync engine.
#
# Usage:
#   sync-dev-kit.sh --prepare   Bring the kit clone to the kit's latest main and print, as
#                               JSON, where its engine and procedure are. A maintainer
#                               machine (~/.claude/kitmaster) syncs from its working tree
#                               as it stands, so nothing is checked or pulled there.
#   sync-dev-kit.sh <mode ...>  Run the clone's engine with these arguments
#                               (--scan, --apply-file <path>, … --finalize).
#
# The engine and its procedure live in the kit clone, never in the project, so every sync
# runs the kit's current version of both. A project holds only this script and the command.
#
# Exit codes:
#   3  the clone cannot be found: no dev-kit-config.json, or devKitPath is not a kit
#   6  the clone cannot be brought to the kit's latest main: on another branch, local
#      changes, a failed fetch, or local commits origin does not have
#   9  jq or git is missing

set -u

fail() {
    echo "sync-dev-kit: $1" >&2
    exit "$2"
}

for tool in jq git; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is not installed; the sync needs it." 9
done

CONFIG="$HOME/.claude/dev-kit-config.json"
[ -f "$CONFIG" ] || fail "$CONFIG is missing, so the kit clone cannot be found.
  Set this machine up first: 'Set up' in the kit's project-documentation/kit-sync-cheatsheet.md." 3

KIT=$(jq -r '.devKitPath // empty' "$CONFIG" 2>/dev/null) || fail "$CONFIG is not valid JSON." 3
[ -n "$KIT" ] && [ -d "$KIT/_claude-project" ] \
    || fail "devKitPath in $CONFIG ('$KIT') is not a dev-kit clone." 3

ENGINE="$KIT/_claude-maintainer/sync/sync-dev-kit.sh"
PROCEDURE="$KIT/_claude-maintainer/sync/procedure.md"

if [ "${1:-}" != "--prepare" ]; then
    [ -f "$ENGINE" ] || fail "the kit clone at $KIT has no sync engine at $ENGINE. Run /sync-dev-kit again: its first step brings the clone up to date." 3
    exec bash "$ENGINE" "$@"
fi

if [ -f "$HOME/.claude/kitmaster" ]; then
    ROLE="maintainer"
else
    ROLE="syncer"

    BRANCH=$(git -C "$KIT" symbolic-ref --short -q HEAD) || BRANCH=""
    [ "$BRANCH" = "main" ] || fail "the kit clone at $KIT is on '${BRANCH:-a detached HEAD}', not main.
  A sync takes the kit's latest main. Switch the clone back to main, then run /sync-dev-kit again." 6

    DIRTY=$(git -C "$KIT" status --porcelain) || fail "could not read the state of the kit clone at $KIT." 6
    [ -z "$DIRTY" ] || fail "the kit clone at $KIT has local changes:
$DIRTY
  The kit changes only through its maintainer. Remove those changes, then run /sync-dev-kit again." 6

    FETCH_OUT=$(git -C "$KIT" fetch origin main 2>&1) || {
        printf '%s\n' "$FETCH_OUT" >&2
        fail "could not fetch the kit's main from origin, so the latest release cannot be taken. Nothing in this project changed." 6
    }

    MERGE_OUT=$(git -C "$KIT" merge --ff-only origin/main 2>&1) || {
        printf '%s\n' "$MERGE_OUT" >&2
        fail "the kit clone's main has commits origin does not, so it cannot be brought to the kit's latest main. Nothing in this project changed." 6
    }
fi

[ -f "$ENGINE" ] || fail "the kit clone at $KIT has no sync engine at $ENGINE." 3

COMMIT=$(git -C "$KIT" rev-parse HEAD) || fail "could not read the kit clone's commit." 6
RELEASE=""
[ -f "$KIT/VERSION" ] && RELEASE=$(tr -d '[:space:]' < "$KIT/VERSION")

jq -n --arg role "$ROLE" --arg kit "$KIT" --arg commit "$COMMIT" --arg release "$RELEASE" \
    --arg engine "$ENGINE" --arg procedure "$PROCEDURE" \
    '{role: $role, kit_path: $kit, kit_commit: $commit, release: $release, engine: $engine, procedure: $procedure}'
