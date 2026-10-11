#!/bin/bash
# Sourced, never run: give this process the project's AWS credentials, and refuse
# unless they belong to the repository's account. tf.sh, aws-key.sh and
# gen-reference.sh all reach AWS through it.
#
#   source "$(dirname "$0")/aws-session.sh"
#   aws_session <caller name> || exit $?
#
# The profile, region and account come from .claude/sync-substitutions.json
# (AWS_PROFILE, AWS_REGION, AWS_ACCOUNT_ID). The profile's temporary credentials
# are exported into this process only — never into the shell that called it — so
# sessions working in different accounts at the same time cannot cross. On success
# AWS_REGION and AWS_ACCOUNT_ID are exported too.
#
# Returns 2 when the settings are missing, 1 when the credentials are refused or
# reach another account.

aws_session() {
    local me="$1" subs=".claude/sync-substitutions.json"
    local profile region account missing creds caller hub
    if [ ! -f "$subs" ]; then
        echo "$me: $subs not found — run this from the repository root." >&2
        return 2
    fi
    profile=$(jq -r '.AWS_PROFILE // ""' "$subs")
    region=$(jq -r '.AWS_REGION // ""' "$subs")
    account=$(jq -r '.AWS_ACCOUNT_ID // ""' "$subs")
    missing=""
    [ -n "$profile" ] || missing="$missing AWS_PROFILE"
    [ -n "$region" ]  || missing="$missing AWS_REGION"
    [ -n "$account" ] || missing="$missing AWS_ACCOUNT_ID"
    if [ -n "$missing" ]; then
        echo "$me: $subs has no value for:$missing" >&2
        return 2
    fi

    # A profile left in the calling shell must not steer the check below.
    unset AWS_PROFILE AWS_DEFAULT_PROFILE
    if ! creds=$(aws configure export-credentials --profile "$profile" --format env 2>&1); then
        echo "$me: could not get credentials for the $profile profile:" >&2
        printf '%s\n' "$creds" | sed 's/^/  /' >&2
        hub=$(aws configure get source_profile --profile "$profile" 2>/dev/null || true)
        echo "  Sign in again: aws login --profile ${hub:-$profile}" >&2
        return 1
    fi
    eval "$creds"

    if ! caller=$(aws sts get-caller-identity --region "$region" --query Account --output text 2>&1); then
        echo "$me: the $profile credentials were refused:" >&2
        printf '%s\n' "$caller" | sed 's/^/  /' >&2
        return 1
    fi
    if [ "$caller" != "$account" ]; then
        echo "$me: the $profile profile reaches account $caller, but this repository's AWS_ACCOUNT_ID is $account. Nothing was run." >&2
        return 1
    fi
    export AWS_REGION="$region" AWS_ACCOUNT_ID="$account"
}
