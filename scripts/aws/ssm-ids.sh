#!/usr/bin/env bash
# ssm-ids.sh [--refresh] — instance ids/names/states, cached 1h.
# Audit: the same instance-id lookup ran 4x in one investigation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-float-workload}"   # ponytail: the instances live in the workload account; explicit AWS_PROFILE still wins
source "$SCRIPT_DIR/aws-common.sh"

CACHE_DIR="$HOME/.claude/aws-cache"
CACHE="$CACHE_DIR/ssm-ids-$AWS_PROFILE"
mkdir -p "$CACHE_DIR"

if [[ "${1:-}" != "--refresh" && -f "$CACHE" ]]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
    if [[ $AGE -lt 3600 ]]; then cat "$CACHE"; exit 0; fi
fi

require_aws
aws ec2 describe-instances "${AWS_JSON[@]}" \
| jq -r '.Reservations[].Instances[] | [.InstanceId, ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // "-"), .State.Name] | @tsv' \
| column -t -s $'\t' | tee "$CACHE"
