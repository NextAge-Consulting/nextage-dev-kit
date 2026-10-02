#!/bin/bash

# Block hand-authoring of Drizzle migration bookkeeping.
#
# Drizzle's migration state is three coupled files per migration: the `.sql`,
# its `meta/NNNN_snapshot.json`, and an entry in `meta/_journal.json`. Only
# `drizzle-kit generate` (use `--custom` for data-only migrations) writes all
# three atomically. Hand-editing the journal or a snapshot, or hand-creating a
# `.sql`, desyncs the snapshot chain — the next `db:generate` diffs against a
# missing/mismatched snapshot, which is painful to unravel.
#
# What this blocks:
#   - */migrations/meta/_journal.json      — drizzle bookkeeping, never hand-touch
#   - */migrations/meta/*_snapshot.json    — drizzle bookkeeping, never hand-touch
#   - a */migrations/*.sql IN a drizzle dir (one whose meta/_journal.json exists)
#     that the journal does not list — a hand-created migration; scaffold via
#     db:generate instead
#
# What this ALLOWS:
#   - Writing or editing a .sql the journal lists — pasting the SQL body into the
#     file drizzle already generated is the correct workflow.
#   - drizzle-kit itself: it writes via its CLI (a Bash subprocess), which this
#     Write/Edit hook never sees.
#
# The journal decides, not the tool name: bash-edit-guard.sh replays a .sql created by
# a shell command as an Edit, after it exists, so "Write means new" does not hold.
#
# There is intentionally no bypass token: the legitimate path (db:generate, then
# Edit the generated .sql body) is always open, so a bypass is never needed.

# shellcheck source=guard-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/guard-lib.sh"

INPUT=$(cat)
require_tools PreToolUse jq
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name' 2>/dev/null)

# Only the file-writing tools carry a file_path we guard. MultiEdit carries one too,
# and omitting it here let a multi-edit walk straight past this guard.
case "$TOOL_NAME" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
# A Windows path (`C:\…\migrations\…`) matches the patterns below once normalized.
FILE_PATH=$(path_spelling "$FILE_PATH")

# The reason rides through a JSON encoder: a path can carry quotes or backslashes, and
# an unparseable deny is silently discarded.
deny() {
    jq -cn --arg r "$1" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
    exit 0
}

GUIDANCE="Never hand-author Drizzle migration files. Run \`npm run db:generate\` (add \`--custom --name=<name>\` for a data-only migration) to scaffold the .sql + snapshot + journal entry together, then Edit ONLY the generated .sql body. See constitution §XI (canonical path, not the quick hack)."

# --- Drizzle bookkeeping: _journal.json and snapshots — blocked on Write OR Edit ---
if printf '%s' "$FILE_PATH" | grep -qE '/migrations/meta/_journal\.json$'; then
    deny "🚫 DRIZZLE JOURNAL BLOCKED

$FILE_PATH is Drizzle's migration journal — hand-editing it desyncs the snapshot chain.

$GUIDANCE"
fi

if printf '%s' "$FILE_PATH" | grep -qE '/migrations/meta/.*_snapshot\.json$'; then
    deny "🚫 DRIZZLE SNAPSHOT BLOCKED

$FILE_PATH is a Drizzle schema snapshot — it is generated, never hand-written.

$GUIDANCE"
fi

# --- A .sql in a drizzle dir that the journal does not list — hand-created ---
if printf '%s' "$FILE_PATH" | grep -qE '/migrations/[^/]+\.sql$'; then
    MIG_DIR=${FILE_PATH%/*}
    JOURNAL="$MIG_DIR/meta/_journal.json"
    # Only treat it as Drizzle if the journal exists — avoids false positives on
    # unrelated tools that keep hand-written .sql migrations.
    if [ -f "$JOURNAL" ]; then
        TAG=${FILE_PATH##*/}; TAG=${TAG%.sql}
        if ! jq -e --arg t "$TAG" 'any(.entries[]?; .tag == $t)' "$JOURNAL" >/dev/null 2>&1; then
            deny "🚫 DRIZZLE MIGRATION BLOCKED

$FILE_PATH would be a hand-created Drizzle migration: its dir has meta/_journal.json, and the journal has no entry for it. Creating the .sql without the matching snapshot + journal entry breaks db:generate.

$GUIDANCE"
        fi
    fi
fi

exit 0
