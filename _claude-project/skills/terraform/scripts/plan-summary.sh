#!/bin/bash
# A saved plan as sorted `<action> <address>` lines, one per resource it touches —
# the form /open-pr writes into the PR body and /deploy compares against before it
# applies. Run from the repository root:
#
#   .claude/skills/terraform/scripts/plan-summary.sh <root> <plan file>
#   .claude/skills/terraform/scripts/plan-summary.sh --block <root> <plan file>
#   .claude/skills/terraform/scripts/plan-summary.sh --from-pr <root> < pr-body.md
#
# <plan file> is the name given to `tf.sh <root> plan -out=`, relative to the root.
#
# Actions: create, update, delete, replace, import, move (written
# `move <old> -> <new>`), with `import+<action>` for an import that also changes the
# resource. A plan that touches nothing prints `no changes`.
#
# --block wraps the summary in the markers the PR body carries:
#   <!-- plan:<root> -->  a ```text fence  <!-- /plan:<root> -->
# --from-pr reads a PR body on stdin and prints the summary inside that root's
# markers, failing when the body has none.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="summary"
case "${1:-}" in
    --block)   MODE="block"; shift ;;
    --from-pr) MODE="from-pr"; shift ;;
esac

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    echo "usage: plan-summary.sh [--block] <root> <plan file> | --from-pr <root> < body" >&2
    exit 2
fi

if [ "$MODE" = "from-pr" ]; then
    body=$(mktemp)
    trap 'rm -f "$body"' EXIT
    cat > "$body"
    if ! grep -qxF "<!-- plan:$ROOT -->" "$body"; then
        echo "plan-summary: the PR body has no plan for $ROOT" >&2
        exit 4
    fi
    awk -v first="<!-- plan:$ROOT -->" -v last="<!-- /plan:$ROOT -->" '
        $0 == first { inside = 1; next }
        $0 == last  { inside = 0; next }
        inside && /^```/ { next }
        inside { print }
    ' "$body"
    exit 0
fi

PLAN="${2:-}"
if [ -z "$PLAN" ]; then
    echo "usage: plan-summary.sh [--block] <root> <plan file>" >&2
    exit 2
fi

if ! JSON=$("$HERE/tf.sh" "$ROOT" show -json "$PLAN" 2>&1); then
    echo "plan-summary: could not read the $ROOT plan:" >&2
    printf '%s\n' "$JSON" | sed 's/^/  /' >&2
    exit 1
fi

if ! LINES=$(printf '%s' "$JSON" | jq -r '
    [ .resource_changes[]?
      | .change.actions as $a
      | (.change.importing != null) as $imp
      | (if ($a == ["no-op"] or $a == ["read"]) then
            (if $imp then "import \(.address)"
             elif .previous_address then "move \(.previous_address) -> \(.address)"
             else empty end)
         else
            (if $a == ["create"] then "create"
             elif $a == ["update"] then "update"
             elif $a == ["delete"] then "delete"
             elif ($a | sort) == ["create", "delete"] then "replace"
             else ($a | join("+")) end) as $act
            | (if $imp then "import+\($act)" else $act end) + " \(.address)"
         end)
    ] | sort | .[]'); then
    echo "plan-summary: the $ROOT plan is not a Terraform plan" >&2
    exit 1
fi
[ -n "$LINES" ] || LINES="no changes"

if [ "$MODE" = "block" ]; then
    # shellcheck disable=SC2016 # the backticks are a Markdown fence, printed literally
    printf '<!-- plan:%s -->\n```text\n%s\n```\n<!-- /plan:%s -->\n' "$ROOT" "$LINES" "$ROOT"
else
    printf '%s\n' "$LINES"
fi
