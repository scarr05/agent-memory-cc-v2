#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for memory system
# Checkpoints current session state before context compaction
# This is the safety net — if compaction loses context, we have a copy

set -euo pipefail

# Clear read-once cache for THIS session only — other sessions keep theirs.
# Requires CLAUDE_SESSION_ID (the same key read-once/hook.sh uses). If it is
# unset, skip the clear rather than wipe all sessions or target a wrong PID dir.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    RO_SESSION=$(echo "$CLAUDE_SESSION_ID" | tr -cd 'A-Za-z0-9_-')
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"

# --- Slug detection: state file first, then fallback ---
STATE_FILE=".claude/memory-state.json"
SLUG=""

if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null || true)
fi

# Fallback: detect slug if state file missing or empty
if [[ -z "$SLUG" ]]; then
    detect_slug() {
        if [[ -f "$CLAUDE_MD" ]]; then
            local slug
            slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
            if [[ -n "$slug" ]]; then echo "$slug"; return 0; fi
        fi

        if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
            local remote
            remote=$(git remote get-url origin 2>/dev/null || true)
            if [[ -n "$remote" ]]; then
                echo "$remote" | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]'
                return 0
            fi
        fi

        basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
    }
    SLUG=$(detect_slug)
fi
# Defence in depth: the state-file/git-remote branches are not charset-filtered.
# Clamp so a crafted slug can't traverse out of the staging dir.
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
[[ -z "$SLUG" ]] && SLUG="unknown"

PROJECT_DIR="$STAGING_DIR/$SLUG"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CHECKPOINT_FILE="$PROJECT_DIR/checkpoint-${TIMESTAMP//:/-}.md"

mkdir -p "$PROJECT_DIR"

# Read session meta
MESSAGE_COUNT=0
SESSION_START=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    MESSAGE_COUNT=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$PROJECT_DIR/.session-meta" 2>/dev/null | head -1)
    MESSAGE_COUNT="${MESSAGE_COUNT:-0}"
    SESSION_START=$(sed -n 's/.*session_start=\(.*\)/\1/p' "$PROJECT_DIR/.session-meta" 2>/dev/null | head -1)
    SESSION_START="${SESSION_START:-unknown}"
fi

# Write checkpoint stub
# The actual content needs to come from Claude (it knows the conversation state)
# This file signals that a checkpoint is needed
cat > "$CHECKPOINT_FILE" << EOF
---
type: checkpoint
project-slug: $SLUG
created: $TIMESTAMP
session-start: $SESSION_START
messages-before-compact: $MESSAGE_COUNT
status: pending
---

## Pre-Compaction Checkpoint

This checkpoint was created automatically before context compaction.
Process this checkpoint at the start of the post-compaction session
(SessionStart source=compact will direct this).
The blackbox subagent should update this with actual session state.
If blackbox is unavailable, Claude should fill this in manually.

## Session State
[To be filled by blackbox or Claude — summarise decisions, progress, open items]

## Key Files Modified
[To be filled by blackbox or Claude — list files changed this session]

## Next Steps
[To be filled by blackbox or Claude — what was about to happen before compaction]
EOF

# Update state file with new checkpoint. If jq fails (malformed state file) this
# is non-load-bearing: session-start.sh rebuilds pendingCheckpoints from disk by
# globbing checkpoint-*.md, so the entry self-heals on the next start. Do not
# promote this to a hard failure.
if [[ -f "$STATE_FILE" ]]; then
    jq --arg cp "$CHECKPOINT_FILE" '.pendingCheckpoints += [$cp] | .lastUpdated = (now | todate)' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
fi

# No stdout. This hook is a filesystem side-effect only: it writes the checkpoint
# stub and updates the state file. The post-compaction handoff is delivered by
# session-start.sh when it next runs with source=compact (it surfaces the pending
# checkpoint and directs blackbox to fill it in). Claude cannot act mid-compaction,
# so emitting context here would be wasted.
exit 0
