---
name: float-ops
description: Operate and diagnose the float platform on AWS. Use for any float AWS work - checking metrics, instance lookups, deploy status, auth problems, or questions about the float landing zone/account structure. Triggers on "float", "landing zone", "float-management", CloudWatch/SSM/deploy checks in the float context.
---

# Float Ops

## Auth (read this first)

SSO to the management account, profile `float-management`. Expired token → run `aws sso login --profile float-management`. Full account structure: `docs/float-landing-zone.md` in the agent-memory-cc-v2 repo.

## Helpers (use these instead of hand-building CLI calls)

All in `~/Documents/Projects/agent-memory-cc-v2-files/scripts/aws/`:

| Script | Purpose |
|--------|---------|
| `cw-dash.sh [hours]` | The standard float metric set, one table (defaults to the workload account profile) |
| `ssm-ids.sh [--refresh]` | Instance id/name/state, cached 1h |
| `deploy-watch.sh [run-id]` | Watch GH Actions run; exit 0 ONLY on verified `completed success` — never trust `gh run watch`'s exit code |

Scripts fail fast with the login command when the SSO token is stale — relay it to the user, don't work around it.
