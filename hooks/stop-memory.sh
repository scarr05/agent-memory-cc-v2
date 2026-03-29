#!/usr/bin/env bash
# stop-memory.sh — Stop hook for memory system
# Tracks message count and nudges for /memory-sync on significant sessions
# Fires on EVERY response — must be fast (<50ms)

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"

# Fast slug detection (minimal checks for performance)
detect_slug_fast() {
    if [[ -f "$CLAUDE_MD" ]]; then
        grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' "$CLAUDE_MD" 2>/dev/null && return 0
    fi
    basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

SLUG=$(detect_slug_fast)
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
CURRENT_COUNT=$(grep -oP '(?<=message_count=)\d+' "$META_FILE" 2>/dev/null || echo "0")
NEW_COUNT=$((CURRENT_COUNT + 1))
sed -i "s/message_count=$CURRENT_COUNT/message_count=$NEW_COUNT/" "$META_FILE"

# Record last activity timestamp
if grep -q 'last_activity=' "$META_FILE" 2>/dev/null; then
    sed -i "s/last_activity=.*/last_activity=$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$META_FILE"
else
    echo "last_activity=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$META_FILE"
fi

# Check session duration
SESSION_START=$(grep -oP '(?<=session_start=).*' "$META_FILE" 2>/dev/null || echo "")
DURATION_MINS=0
NOW_EPOCH=$(date +%s)
if [[ -n "$SESSION_START" ]]; then
    START_EPOCH=$(date -d "$SESSION_START" +%s 2>/dev/null || echo "0")
    if [[ "$START_EPOCH" -gt 0 ]]; then
        DURATION_MINS=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
    fi
fi

# Significance check — nudge at thresholds
# Only nudge once per threshold to avoid nagging
NUDGE=""

if [[ "$NEW_COUNT" -eq 15 ]] || [[ "$NEW_COUNT" -eq 30 ]]; then
    NUDGE="This session has $NEW_COUNT exchanges (~${DURATION_MINS}min). Consider running /memory-sync to checkpoint progress to Obsidian."
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

# Output nudge if significant
if [[ -n "$NUDGE" ]]; then
    cat << HOOKJSON
{
  "reason": "$NUDGE"
}
HOOKJSON
fi

# Always exit 0 — never block on Stop
exit 0
