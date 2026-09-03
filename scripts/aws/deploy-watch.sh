#!/usr/bin/env bash
# deploy-watch.sh [run-id] — watch a GitHub Actions run and verify the REAL
# conclusion. Audit: `gh run watch` exit code reported success while 3 deploys
# were still running; never trust it alone.
set -euo pipefail

RUN_ID="${1:-$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')}"
[[ -n "$RUN_ID" ]] || { echo "no runs found" >&2; exit 1; }

gh run watch "$RUN_ID" || true   # progress display only; its exit code lies

STATUS=$(gh run view "$RUN_ID" --json status,conclusion --jq '"\(.status) \(.conclusion)"')
echo "run $RUN_ID: $STATUS"
[[ "$STATUS" == "completed success" ]]
