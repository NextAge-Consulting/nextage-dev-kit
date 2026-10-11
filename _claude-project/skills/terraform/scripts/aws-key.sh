#!/bin/bash
# Create, rotate or retire the access key of an IAM user Terraform manages, writing
# it straight from IAM into Parameter Store. The secret is never printed, never in
# a command line, and never in Terraform state.
#
#   .claude/skills/terraform/scripts/aws-key.sh <iam user> <parameter prefix>
#   .claude/skills/terraform/scripts/aws-key.sh <iam user> <parameter prefix> --retire
#
#   aws-key.sh my-app-mailer /my-app/SES
#     → /my-app/SES_ACCESS_KEY_ID and /my-app/SES_SECRET_ACCESS_KEY, both SecureString
#
# Without --retire it creates a key and overwrites both parameters with it. When the
# user already had a key, that is a rotation: the old key keeps working until the app
# reloads its settings, and the script names it. Once the app runs on the new key,
# --retire deletes every key of the user except the one the parameters hold.
#
# IAM allows two keys per user, so a third is refused: retire first. Run from the
# root of the repository holding the user's Terraform; credentials come from
# aws-session.sh.
#
# Exit codes:
#   2  usage, settings, or the user already has two keys
#   1  credentials refused, or an AWS call failed — what was left is named

set -euo pipefail
# shellcheck source=_claude-project/skills/terraform/scripts/aws-session.sh
source "$(dirname "$0")/aws-session.sh"

USER_NAME="${1:-}"
PREFIX="${2:-}"
MODE="${3:-create}"
if [ -z "$USER_NAME" ] || [ -z "$PREFIX" ] || { [ "$MODE" != create ] && [ "$MODE" != --retire ]; } || [ $# -gt 3 ]; then
    echo "usage: aws-key.sh <iam user> <parameter prefix> [--retire]   (prefix like /my-app/SES)" >&2
    exit 2
fi
case "$PREFIX" in
    /*) ;;
    *) echo "aws-key.sh: the parameter prefix starts with / — the app's own path, like /my-app/SES." >&2; exit 2 ;;
esac
ID_PARAM="${PREFIX}_ACCESS_KEY_ID"
SECRET_PARAM="${PREFIX}_SECRET_ACCESS_KEY"

aws_session aws-key.sh || exit $?

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

if ! KEYS=$(aws iam list-access-keys --user-name "$USER_NAME" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>&1); then
    echo "aws-key.sh: could not list the keys of $USER_NAME:" >&2
    printf '%s\n' "$KEYS" | sed 's/^/  /' >&2
    exit 1
fi
[ "$KEYS" = "None" ] && KEYS=""
# Text output separates the ids with tabs; the checks below match on spaces.
KEYS=$(printf '%s' "$KEYS" | tr '\t\n' '  ')
# shellcheck disable=SC2086 # word-splitting the key ids is the point
set -- $KEYS
KEY_COUNT=$#

# ─── Retire: delete every key but the stored one ──────────────────────────
if [ "$MODE" = --retire ]; then
    if ! STORED=$(aws ssm get-parameter --name "$ID_PARAM" --with-decryption --query Parameter.Value --output text 2>&1); then
        echo "aws-key.sh: could not read $ID_PARAM:" >&2
        printf '%s\n' "$STORED" | sed 's/^/  /' >&2
        exit 1
    fi
    case " $KEYS " in
        *" $STORED "*) ;;
        *)
            echo "aws-key.sh: $ID_PARAM holds $STORED, which is not a key of $USER_NAME. Nothing was deleted." >&2
            exit 1
            ;;
    esac
    RETIRED=0
    for key in $KEYS; do
        [ "$key" = "$STORED" ] && continue
        if ! out=$(aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$key" 2>&1); then
            echo "aws-key.sh: could not delete $key:" >&2
            printf '%s\n' "$out" | sed 's/^/  /' >&2
            exit 1
        fi
        echo "aws-key.sh: deleted $key." >&2
        RETIRED=$((RETIRED + 1))
    done
    [ "$RETIRED" -eq 0 ] && echo "aws-key.sh: $USER_NAME has only the stored key $STORED — nothing to retire." >&2
    exit 0
fi

# ─── Create: a new key, straight into both parameters ─────────────────────
if [ "$KEY_COUNT" -ge 2 ]; then
    echo "aws-key.sh: $USER_NAME already has two keys ($KEYS), IAM's limit. Run with --retire once the app runs on the stored one." >&2
    exit 2
fi

if ! aws iam create-access-key --user-name "$USER_NAME" --output json > "$WORK/key.json" 2> "$WORK/err"; then
    echo "aws-key.sh: could not create a key for $USER_NAME:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    exit 1
fi
jq -j '.AccessKey.AccessKeyId' "$WORK/key.json" > "$WORK/id"
jq -j '.AccessKey.SecretAccessKey' "$WORK/key.json" > "$WORK/secret"
rm -f "$WORK/key.json"
NEW_KEY=$(cat "$WORK/id")

# Secret first, then id. If either write fails the new key is deleted, and the
# message says whether the secret parameter had already moved.
put() {
    aws ssm put-parameter --name "$1" --type SecureString --overwrite --value "file://$2" > /dev/null 2> "$WORK/err"
}
if ! put "$SECRET_PARAM" "$WORK/secret"; then
    echo "aws-key.sh: could not write $SECRET_PARAM:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$NEW_KEY" >/dev/null 2>&1 \
        && echo "  The new key $NEW_KEY was deleted; both parameters are unchanged." >&2 \
        || echo "  The new key $NEW_KEY could not be deleted — delete it by hand. Both parameters are unchanged." >&2
    exit 1
fi
if ! put "$ID_PARAM" "$WORK/id"; then
    echo "aws-key.sh: could not write $ID_PARAM:" >&2
    sed 's/^/  /' "$WORK/err" >&2
    aws iam delete-access-key --user-name "$USER_NAME" --access-key-id "$NEW_KEY" >/dev/null 2>&1 \
        && echo "  The new key $NEW_KEY was deleted, but $SECRET_PARAM already holds its secret — run aws-key.sh again before the app reloads." >&2 \
        || echo "  The new key $NEW_KEY could not be deleted, and $SECRET_PARAM holds its secret — run aws-key.sh again, then --retire." >&2
    exit 1
fi

echo "aws-key.sh: created $NEW_KEY for $USER_NAME and stored it in $ID_PARAM and $SECRET_PARAM." >&2
for key in $KEYS; do
    echo "  The old key $key still works. Once the app has reloaded its settings and works, run:" >&2
    echo "  .claude/skills/terraform/scripts/aws-key.sh $USER_NAME $PREFIX --retire" >&2
done
