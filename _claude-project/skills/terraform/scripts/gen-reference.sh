#!/bin/bash
# Regenerate this repository's infrastructure reference from Terraform itself:
# every resource each root manages, read from its live state, and each root's
# dependency graph drawn by Graphviz. Run from the repository root after any apply:
#
#   .claude/skills/terraform/scripts/gen-reference.sh
#
# Each IAM user a root manages is listed with its access keys — id, status and the
# date it was created, read from IAM, never a secret (aws-key.sh makes them).
#
# Writes project-documentation/infrastructure-reference.md and one SVG per root
# under project-documentation/infrastructure-reference/. Nothing there is edited by
# hand; the overview a person reads is project-documentation/infrastructure-overview.md.
#
# A root is a folder under infra/terraform/ holding a committed .terraform.lock.hcl.
# Reads state and builds graphs only — it changes nothing in AWS. Needs `dot`
# (brew install graphviz), jq, and the credentials tf.sh uses.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=_claude-project/skills/terraform/scripts/aws-session.sh
source "$HERE/aws-session.sh"
TF="$HERE/tf.sh"
DOC="project-documentation/infrastructure-reference.md"
IMG_DIR="project-documentation/infrastructure-reference"

if [ ! -d infra/terraform ]; then
    echo "gen-reference: no infra/terraform/ here — run this from the repository root." >&2
    exit 2
fi
command -v dot >/dev/null 2>&1 || { echo "gen-reference: Graphviz is missing (brew install graphviz)" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "gen-reference: jq is missing" >&2; exit 2; }

ROOTS=()
while IFS= read -r lock; do
    dir="$(dirname "$lock")"
    ROOTS+=("${dir#infra/terraform/}")
done < <(find infra/terraform -name .terraform.lock.hcl -not -path '*/.terraform/*' | sort)
if [ "${#ROOTS[@]}" -eq 0 ]; then
    echo "gen-reference: no root under infra/terraform/ has a committed .terraform.lock.hcl — nothing to read." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Gather everything first, so a failure leaves the existing reference untouched.
for root in "${ROOTS[@]}"; do
    key="${root//\//_}"
    if ! "$TF" "$root" show -json > "$TMP/$key.json" 2> "$TMP/$key.err"; then
        cat "$TMP/$key.err" >&2
        echo "gen-reference: could not read the $root state" >&2
        exit 1
    fi
    if ! "$TF" "$root" graph > "$TMP/$key.dot" 2> "$TMP/$key.err"; then
        cat "$TMP/$key.err" >&2
        echo "gen-reference: could not build the $root graph" >&2
        exit 1
    fi
    if ! dot -Tsvg "$TMP/$key.dot" -o "$TMP/$key.svg"; then
        echo "gen-reference: Graphviz could not draw the $root graph" >&2
        exit 1
    fi
    count=$(jq '[.. | objects | select(.mode? == "managed")] | length' "$TMP/$key.json")
    if [ "$count" -eq 0 ]; then
        echo "gen-reference: the $root state holds no resources — refusing to write an empty reference" >&2
        exit 1
    fi
done

# Access keys live outside Terraform, so IAM is asked for them directly.
SESSION=0
for root in "${ROOTS[@]}"; do
    key="${root//\//_}"
    : > "$TMP/$key.keys"
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        if [ "$SESSION" -eq 0 ]; then
            aws_session gen-reference || exit 1
            SESSION=1
        fi
        if ! aws iam list-access-keys --user-name "$user" --output json > "$TMP/one.json" 2> "$TMP/$key.err"; then
            cat "$TMP/$key.err" >&2
            echo "gen-reference: could not list the access keys of $user" >&2
            exit 1
        fi
        if ! jq -r --arg u "$user" '
              if (.AccessKeyMetadata | length) == 0 then "| `\($u)` | no key | | |"
              else .AccessKeyMetadata[] | "| `\($u)` | `\(.AccessKeyId)` | \(.Status) | \(.CreateDate[0:10]) |" end
            ' "$TMP/one.json" >> "$TMP/$key.keys"; then
            echo "gen-reference: could not read the access keys of $user" >&2
            exit 1
        fi
    done < <(jq -r '[.. | objects | select(.mode? == "managed" and .type? == "aws_iam_user") | .values.name] | sort[]' "$TMP/$key.json")
done

REPO="$(basename "$(git rev-parse --show-toplevel)")"
{
    echo "# $REPO infrastructure — engineers' reference"
    echo
    echo "Generated from Terraform by \`.claude/skills/terraform/scripts/gen-reference.sh\` on $(date -u '+%Y-%m-%d %H:%M UTC')."
    echo "**Do not edit by hand** — rerun the script after an apply. Every resource each Terraform root"
    echo "manages, read from its live state, and the dependency graph between them. The overview is"
    echo "\`infrastructure-overview.md\`."
    echo
    for root in "${ROOTS[@]}"; do
        key="${root//\//_}"
        n=$(jq '[.. | objects | select(.mode? == "managed")] | length' "$TMP/$key.json")
        echo "## \`$root\` — $n resources"
        echo
        echo "![$root dependency graph](infrastructure-reference/$key.svg)"
        echo
        echo "| Resource | Type | AWS identifier |"
        echo "|---|---|---|"
        jq -r '
          [.. | objects | select(.mode? == "managed")]
          | sort_by(.address)[]
          | "| `\(.address)` | `\(.type)` | `\(.values.arn // .values.id // .values.name // "")` |"
        ' "$TMP/$key.json"
        echo
        if [ -s "$TMP/$key.keys" ]; then
            echo "Access keys, made outside Terraform by \`aws-key.sh\` (created dates UTC):"
            echo
            echo "| User | Key | Status | Created |"
            echo "|---|---|---|---|"
            cat "$TMP/$key.keys"
            echo
        fi
    done
} > "$TMP/reference.md"

mkdir -p "$IMG_DIR"
for root in "${ROOTS[@]}"; do
    key="${root//\//_}"
    cp "$TMP/$key.svg" "$IMG_DIR/$key.svg"
done
cp "$TMP/reference.md" "$DOC"
echo "gen-reference: wrote $DOC and ${#ROOTS[@]} graph(s) in $IMG_DIR"
