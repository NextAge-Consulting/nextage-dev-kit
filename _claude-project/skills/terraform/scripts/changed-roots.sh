#!/bin/bash
# The Terraform roots a branch changes, one per line, relative to infra/terraform/.
# Run from the repository root:
#
#   .claude/skills/terraform/scripts/changed-roots.sh <base>
#
# Counts every change since the branch left <base> — committed, uncommitted and
# untracked. A root is the folder holding a changed .tf, .tfvars or
# .terraform.lock.hcl. A change under infra/terraform/modules/ can reach every root,
# so it reports every root (a folder with a committed .terraform.lock.hcl).
#
# A root whose folder was deleted, or no longer holds a .tf file, fails: its
# resources still exist in AWS and in its state file, and deleting the code does not
# remove them. Delete the resources from the code and deploy that first; the empty
# root goes in a later change.

set -euo pipefail

BASE="${1:-}"
if [ -z "$BASE" ]; then
    echo "usage: changed-roots.sh <base>" >&2
    exit 2
fi
if ! FORK=$(git merge-base "$BASE" HEAD 2>&1); then
    echo "changed-roots: cannot find where this branch left $BASE: $FORK" >&2
    exit 2
fi

list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! { git diff --name-only "$FORK" -- infra/terraform \
        && git ls-files --others --exclude-standard -- infra/terraform; } > "$list"; then
    echo "changed-roots: git could not list the changes since $BASE" >&2
    exit 2
fi

roots=""
all=0
while IFS= read -r f; do
    case "$f" in
        */.terraform/*) continue ;;
        infra/terraform/modules/*) all=1 ;;
        infra/terraform/*.tf|infra/terraform/*.tfvars|infra/terraform/*.terraform.lock.hcl)
            dir="$(dirname "$f")"
            [ "$dir" = "infra/terraform" ] && continue
            roots="$roots${dir#infra/terraform/}"$'\n'
            ;;
    esac
done < "$list"

if [ "$all" -eq 1 ]; then
    while IFS= read -r lock; do
        dir="$(dirname "$lock")"
        roots="$roots${dir#infra/terraform/}"$'\n'
    done < <(find infra/terraform -name .terraform.lock.hcl -not -path '*/.terraform/*' -not -path 'infra/terraform/modules/*')
fi

roots=$(printf '%s' "$roots" | sed '/^$/d' | sort -u)
if [ -z "$roots" ]; then
    echo "changed-roots: no Terraform root changed since $BASE." >&2
    exit 0
fi

n=0
while IFS= read -r r; do
    if ! ls "infra/terraform/$r"/*.tf >/dev/null 2>&1; then
        echo "changed-roots: infra/terraform/$r was deleted or holds no .tf file, but its resources still exist." >&2
        echo "  Delete the resources from its code and deploy that first; remove the empty root in a later change." >&2
        exit 3
    fi
    n=$((n + 1))
done <<< "$roots"

printf '%s\n' "$roots"
echo "changed-roots: $n root(s) changed since $BASE." >&2
