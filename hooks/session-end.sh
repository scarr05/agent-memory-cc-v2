#!/usr/bin/env bash
# session-end.sh — SessionEnd hook for memory system
# Deterministically flags a session that ended without /memory-sync, so the next
# SessionStart can nudge. Side-effect only: emits no stdout, always exits 0
# (SessionEnd cannot block or inject context).

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
STATE_FILE=".claude/memory-state.json"

# SessionEnd receives JSON on stdin with a `reason`
# (clear | logout | prompt_input_exit | other). A `clear` was a deliberate wipe
# — do not flag it as unsynced. Fail open (flag) if reason can't be read.
REASON=$(jq -r '.reason // empty' 2>/dev/null || true)
[[ "$REASON" == "clear" ]] && exit 0

# --- Fast slug detection: state file (sed, no jq) -> CLAUDE.md -> dirname ---
SLUG=""
if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(sed -n 's/.*"slug": *"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null | head -1)
fi
if [[ -z "$SLUG" ]] && [[ -f "$CLAUDE_MD" ]]; then
    SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1)
fi
if [[ -z "$SLUG" ]]; then
    SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
fi
# Defence in depth: the state-file/CLAUDE.md branches aren't charset-filtered.
# Clamp so a crafted slug can't traverse out of the staging dir. Pure-bash
# builtins (bash 4+) keep this side-effect hook subprocess-free past the jq read.
SLUG="${SLUG,,}"
SLUG="${SLUG//[^a-z0-9-]/}"
[[ -z "$SLUG" ]] && SLUG="unknown"

PROJECT_DIR="$STAGING_DIR/$SLUG"
META_FILE="$PROJECT_DIR/.session-meta"

# No meta means SessionStart never tracked this session — nothing to flag.
[[ -f "$META_FILE" ]] || exit 0

MESSAGE_COUNT=$(sed -n 's/^message_count=\([0-9]*\).*/\1/p' "$META_FILE" | head -1)
MESSAGE_COUNT="${MESSAGE_COUNT:-0}"

# Flag only a session of real length (>=10 exchanges) that was never synced.
# /memory-sync writes synced=true (Task 7) and owns removal of .unsynced; this
# hook only creates it. SessionStart surfaces it on the next full-path start.
if [[ "$MESSAGE_COUNT" -ge 10 ]] && ! grep -q '^synced=true' "$META_FILE" 2>/dev/null; then
    cat > "$PROJECT_DIR/.unsynced" << EOF
ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
messages=$MESSAGE_COUNT
EOF
fi

exit 0
