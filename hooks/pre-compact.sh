#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for memory system
# Checkpoints current session state before context compaction
# This is the safety net — if compaction loses context, we have a copy

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"

# Detect slug (same logic as session-start.sh)
detect_slug() {
    if [[ -f "$CLAUDE_MD" ]]; then
        local slug
        slug=$(grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' "$CLAUDE_MD" 2>/dev/null || true)
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
PROJECT_DIR="$STAGING_DIR/$SLUG"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CHECKPOINT_FILE="$PROJECT_DIR/checkpoint-${TIMESTAMP//:/-}.md"

mkdir -p "$PROJECT_DIR"

# Read session meta
MESSAGE_COUNT=0
SESSION_START=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    MESSAGE_COUNT=$(grep -oP '(?<=message_count=)\d+' "$PROJECT_DIR/.session-meta" || echo "0")
    SESSION_START=$(grep -oP '(?<=session_start=).*' "$PROJECT_DIR/.session-meta" || echo "unknown")
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
Claude should update this with the actual session state when it next
has the opportunity (SessionStart will flag it as pending).

## Session State
[To be filled by Claude — summarise decisions, progress, open items]

## Key Files Modified
[To be filled by Claude — list files changed this session]

## Next Steps
[To be filled by Claude — what was about to happen before compaction]
EOF

# Output context telling Claude about the checkpoint
cat << HOOKJSON
{
  "hookSpecificOutput": {
    "hookEventName": "PreCompact",
    "additionalContext": "Pre-compaction checkpoint created at $CHECKPOINT_FILE. Before compaction completes, write the current session state (decisions, progress, open items, next steps) into this file. After compaction, process it to Obsidian 5 Agent Memory/working/$SLUG-checkpoint.md via MCP."
  }
}
HOOKJSON
