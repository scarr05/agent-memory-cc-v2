#!/usr/bin/env bash
# cw-dash.sh [hours] — pull the standard float metric set for the last N hours (default 3).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AWS_PROFILE="${AWS_PROFILE:-float-workload}"   # ponytail: metric set lives in the workload account; explicit AWS_PROFILE still wins
source "$SCRIPT_DIR/aws-common.sh"
require_aws

HOURS="${1:-3}"
CFG="$SCRIPT_DIR/metrics.json"
REGION=$(jq -r '.region' "$CFG")
PERIOD=$(jq -r '.period' "$CFG")
START=$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

QUERIES=$(jq '[.metrics[] | {Id: .id, MetricStat: {Metric: {Namespace: .namespace, MetricName: .name, Dimensions: .dimensions}, Period: '"$PERIOD"', Stat: .stat}}]' "$CFG")

aws cloudwatch get-metric-data "${AWS_JSON[@]}" \
    --region "$REGION" \
    --start-time "$START" --end-time "$END" \
    --metric-data-queries "$QUERIES" \
| jq -r '.MetricDataResults[] | [.Id, .Label, (.Values | if length > 0 then (last | tostring) else "no data" end), (.Values | length | tostring) + " pts"] | @tsv' \
| column -t -s $'\t'
