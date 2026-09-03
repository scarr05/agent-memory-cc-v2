#!/usr/bin/env bash
# aws-common.sh — shared guard for float AWS helper scripts.
# Auth model: SSO to the management account, profile float-management.

export AWS_PROFILE="${AWS_PROFILE:-float-management}"
AWS_JSON=(--output json --no-cli-pager)

require_aws() {
    if ! aws sts get-caller-identity "${AWS_JSON[@]}" >/dev/null 2>&1; then
        echo "AWS auth failed for profile '$AWS_PROFILE'. Run:" >&2
        echo "  aws sso login --profile $AWS_PROFILE" >&2
        return 1
    fi
}
