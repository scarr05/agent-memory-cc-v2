#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for memory system.
# The checkpoint-stub mechanism this hook used to drive is retired (see
# docs/superpowers/specs/2026-06-15-handoff-clear-continue-design.md). Real
# pre-/clear capture is now /handoff; auto-compaction recovery is the
# SessionStart(source=compact) harvest. This hook keeps only one side effect:
# clearing the read-once dedup cache for THIS session so a post-compaction
# re-read of source files is allowed.

set -euo pipefail

# Clear read-once cache for THIS session only — other sessions keep theirs.
# session_id comes from stdin, the same key read-once/hook.sh uses (CLAUDE_SESSION_ID
# is not set in the hook env). Without jq, fall back to a sed extraction.
STDIN_JSON=$(cat || true)
RO_SESSION=$(printf '%s' "$STDIN_JSON" | jq -r '.session_id // empty' 2>/dev/null \
    || printf '%s' "$STDIN_JSON" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)
[[ -z "$RO_SESSION" ]] && RO_SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
RO_SESSION=$(printf '%s' "$RO_SESSION" | tr -cd 'A-Za-z0-9_-')
if [[ -n "$RO_SESSION" ]]; then
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi

# No stdout. Post-compaction recovery is delivered by session-start.sh
# (source=compact), which harvests CC's own summary into a handoff scratch.
exit 0
