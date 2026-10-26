#!/bin/bash
# Run Terraform for one root of this repository with the project's AWS credentials.
#
#   .claude/skills/terraform/scripts/tf.sh <root> <terraform args...>
#   .claude/skills/terraform/scripts/tf.sh prod plan -out=prod.tfplan
#   .claude/skills/terraform/scripts/tf.sh prod apply prod.tfplan
#
# An init that changes .terraform.lock.hcl is followed by `providers lock` for
# linux_amd64, darwin_arm64 and darwin_amd64, so the committed lock verifies on CI
# and every Mac.
#
# <root> is a folder under infra/terraform/. Run from the repository root.
#
# Credentials come from aws-session.sh: the project's profile, checked against its
# AWS_ACCOUNT_ID before Terraform runs; the provider's allowed_account_ids is the
# second guard.

set -euo pipefail
# shellcheck source=_claude-project/skills/terraform/scripts/aws-session.sh
source "$(dirname "$0")/aws-session.sh"

ROOT="${1:-}"
if [ -z "$ROOT" ]; then
    echo "usage: tf.sh <root> <terraform args...>   (<root> is a folder under infra/terraform/)" >&2
    exit 2
fi
shift

if [ ! -f .claude/sync-substitutions.json ]; then
    echo "tf.sh: .claude/sync-substitutions.json not found — run this from the repository root." >&2
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

aws_session tf.sh || exit $?

# A lock file written here must also verify on CI's Linux and on every developer's
# Mac, so an init that changed it is followed by a lock for all three. It only ever
# adds checksums. An init that left it unchanged has verified the providers against
# it, and locking again would download every provider for every platform.
if [ "${1:-}" = "init" ]; then
    LOCK="$DIR/.terraform.lock.hcl"
    before=$(cat "$LOCK" 2>/dev/null || true)
    terraform -chdir="$DIR" "$@" || exit $?
    [ "$(cat "$LOCK" 2>/dev/null || true)" = "$before" ] && exit 0
    exec terraform -chdir="$DIR" providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
fi

exec terraform -chdir="$DIR" "$@"
