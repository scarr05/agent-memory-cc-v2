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
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    RO_SESSION=$(echo "$CLAUDE_SESSION_ID" | tr -cd 'A-Za-z0-9_-')
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi

# No stdout. Post-compaction recovery is delivered by session-start.sh
# (source=compact), which harvests CC's own summary into a handoff scratch.
exit 0
