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
# The session is the hook input's session_id; CLAUDE_SESSION_ID is a fallback
# for a Claude Code that sets it, since hooks are not promised the variable.
STDIN_JSON=""
IFS= read -r -d '' STDIN_JSON || true
LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
SESSION_ID=""
# shellcheck source=/dev/null
[[ -f "$LIBDIR/state-lib.sh" ]] && { source "$LIBDIR/state-lib.sh"; state_session_id "$STDIN_JSON"; }
RO_SESSION="${SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
RO_SESSION="${RO_SESSION//[^A-Za-z0-9_-]/}"
if [[ -n "$RO_SESSION" ]]; then
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi

# No stdout. Post-compaction recovery is delivered by session-start.sh
# (source=compact), which harvests CC's own summary into a handoff scratch.
exit 0
