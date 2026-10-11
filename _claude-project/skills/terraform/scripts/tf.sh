#!/bin/bash
# Run Terraform for one root of this repository with the project's AWS credentials.
#
#   .claude/skills/terraform/scripts/tf.sh <root> <terraform args...>
#   .claude/skills/terraform/scripts/tf.sh prod plan -out=prod.tfplan
#   .claude/skills/terraform/scripts/tf.sh prod apply prod.tfplan
#
# <root> is a folder under infra/terraform/. Run from the repository root.
#
# The profile, region and account come from .claude/sync-substitutions.json
# (AWS_PROFILE, AWS_REGION, AWS_ACCOUNT_ID). The profile's temporary credentials
# are exported into this process only — never into the shell that called it — so
# sessions working in different accounts at the same time cannot cross. Before
# Terraform runs, the credentials must belong to AWS_ACCOUNT_ID; the provider's
# allowed_account_ids is the second guard.

set -euo pipefail

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    echo "usage: tf.sh <root> <terraform args...>   (<root> is a folder under infra/terraform/)" >&2
    exit 2
fi
shift

SUBS=".claude/sync-substitutions.json"
if [ ! -f "$SUBS" ]; then
    echo "tf.sh: $SUBS not found — run this from the repository root." >&2
    exit 2
fi
DIR="infra/terraform/$ROOT"
if [ ! -d "$DIR" ]; then
    echo "tf.sh: no Terraform root at $DIR" >&2
    exit 2
fi
case "$ROOT" in
    modules|modules/*)
        echo "tf.sh: $DIR is a module, not a root — run the root that calls it." >&2
        exit 2
        ;;
esac

PROFILE=$(jq -r '.AWS_PROFILE // ""' "$SUBS")
REGION=$(jq -r '.AWS_REGION // ""' "$SUBS")
ACCOUNT=$(jq -r '.AWS_ACCOUNT_ID // ""' "$SUBS")
missing=""
[ -n "$PROFILE" ] || missing="$missing AWS_PROFILE"
[ -n "$REGION" ]  || missing="$missing AWS_REGION"
[ -n "$ACCOUNT" ] || missing="$missing AWS_ACCOUNT_ID"
if [ -n "$missing" ]; then
    echo "tf.sh: $SUBS has no value for:$missing" >&2
    exit 2
fi

# A profile left in the calling shell must not steer the check below.
unset AWS_PROFILE AWS_DEFAULT_PROFILE
if ! CREDS=$(aws configure export-credentials --profile "$PROFILE" --format env 2>&1); then
    echo "tf.sh: could not get credentials for the $PROFILE profile:" >&2
    printf '%s\n' "$CREDS" | sed 's/^/  /' >&2
    HUB=$(aws configure get source_profile --profile "$PROFILE" 2>/dev/null || true)
    echo "  Sign in again: aws login --profile ${HUB:-$PROFILE}" >&2
    exit 1
fi
eval "$CREDS"

if ! CALLER=$(aws sts get-caller-identity --region "$REGION" --query Account --output text 2>&1); then
    echo "tf.sh: the $PROFILE credentials were refused:" >&2
    printf '%s\n' "$CALLER" | sed 's/^/  /' >&2
    exit 1
fi
if [ "$CALLER" != "$ACCOUNT" ]; then
    echo "tf.sh: the $PROFILE profile reaches account $CALLER, but this repository's AWS_ACCOUNT_ID is $ACCOUNT. Nothing was run." >&2
    exit 1
fi

exec terraform -chdir="$DIR" "$@"
