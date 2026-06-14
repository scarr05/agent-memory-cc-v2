#!/usr/bin/env bash
# stop-memory.sh — Stop hook for memory system
# Tracks message count and nudges for /memory-sync on significant sessions
# Fires on EVERY response — must be fast (<50ms)

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"

# Fast slug detection: state file first, then minimal fallback
STATE_FILE=".claude/memory-state.json"
SLUG=""

# Try state file first (fastest, most reliable)
if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null || true)
fi

# Fallback: minimal detection
if [[ -z "$SLUG" ]]; then
    if [[ -f "$CLAUDE_MD" ]]; then
        SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1)
    fi
fi

if [[ -z "$SLUG" ]]; then
    SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
fi
PROJECT_DIR="$STAGING_DIR/$SLUG"
META_FILE="$PROJECT_DIR/.session-meta"

# Ensure directory exists
mkdir -p "$PROJECT_DIR"

# Initialise meta if it doesn't exist (shouldn't happen if SessionStart ran)
if [[ ! -f "$META_FILE" ]]; then
    cat > "$META_FILE" << EOF
session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
message_count=0
project_slug=$SLUG
area=
EOF
fi

# Increment message count
CURRENT_COUNT=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$META_FILE" 2>/dev/null | head -1)
CURRENT_COUNT="${CURRENT_COUNT:-0}"
NEW_COUNT=$((CURRENT_COUNT + 1))
sed -i "s/message_count=$CURRENT_COUNT/message_count=$NEW_COUNT/" "$META_FILE"

# Record last activity timestamp
if grep -q 'last_activity=' "$META_FILE" 2>/dev/null; then
    sed -i "s/last_activity=.*/last_activity=$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$META_FILE"
else
    echo "last_activity=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
fi

# Check session duration
SESSION_START=$(sed -n 's/.*session_start=\(.*\)/\1/p' "$META_FILE" 2>/dev/null | head -1)
SESSION_START="${SESSION_START:-}"
DURATION_MINS=0
NOW_EPOCH=$(date +%s)
if [[ -n "$SESSION_START" ]]; then
    START_EPOCH=$(date -d "$SESSION_START" +%s 2>/dev/null || echo "0")
    if [[ "$START_EPOCH" -gt 0 ]]; then
        DURATION_MINS=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
    fi
fi

# Significance check — nudge at thresholds
# Only nudge once per threshold to avoid nagging. Use -ge plus sent-flags so a
# session that jumps PAST a threshold (a missed fire) still nudges.
NUDGE=""

# Both thresholds emit the same message; only the sent-flag differs. Set it once.
NUDGE_MSG="This session has $NEW_COUNT exchanges (~${DURATION_MINS}min). Consider running /memory-sync to checkpoint progress to Obsidian."

# Highest threshold first. A session that jumps PAST 15 (a missed fire — the
# exact case -ge exists to survive) must still fire the 30 nudge. An
# `if -ge 15 … elif -ge 30` would fire the 15 branch and never reach 30.
if [[ "$NEW_COUNT" -ge 30 ]] && ! grep -q 'nudge30_sent=true' "$META_FILE" 2>/dev/null; then
    NUDGE="$NUDGE_MSG"
    echo "nudge30_sent=true" >> "$META_FILE"
elif [[ "$NEW_COUNT" -ge 15 ]] && ! grep -q 'nudge15_sent=true' "$META_FILE" 2>/dev/null; then
    NUDGE="$NUDGE_MSG"
    echo "nudge15_sent=true" >> "$META_FILE"
fi

if [[ "$DURATION_MINS" -ge 45 ]] && ! grep -q 'duration_nudge_sent=true' "$META_FILE" 2>/dev/null; then
    NUDGE="This session has been running for ${DURATION_MINS} minutes with $NEW_COUNT exchanges. Consider running /memory-sync before context gets too large."
    echo "duration_nudge_sent=true" >> "$META_FILE"
fi

# --- Dream timer check ---
# Uses NOW_EPOCH set above
LAST_DREAM_FILE="$PROJECT_DIR/.last-dream"
if [[ -f "$LAST_DREAM_FILE" ]]; then
    read -r LAST_DREAM < "$LAST_DREAM_FILE" || LAST_DREAM=0
    HOURS_SINCE_DREAM=$(( (NOW_EPOCH - LAST_DREAM) / 3600 ))
    if [[ "$HOURS_SINCE_DREAM" -ge 24 ]]; then
        touch "$PROJECT_DIR/.dream-pending"
    fi
elif [[ "$NEW_COUNT" -ge 5 ]]; then
    # First-ever use: only flag after enough session activity
    touch "$PROJECT_DIR/.dream-pending"
fi

# Output nudge if significant.
# systemMessage = user-visible nudge. Never block the agent for a reminder.
# ($NUDGE contains no quotes/backslashes by construction; keep it that way.)
if [[ -n "$NUDGE" ]]; then
    printf '{"systemMessage": "%s"}\n' "$NUDGE"
fi

# Always exit 0 — never block on Stop
exit 0
