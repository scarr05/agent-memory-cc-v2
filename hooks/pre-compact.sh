#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for memory system
# Checkpoints current session state before context compaction
# This is the safety net — if compaction loses context, we have a copy

set -euo pipefail

# Clear read-once cache — prevents stale state after compaction
rm -rf "$HOME/.claude/read-once/cache/" 2>/dev/null || true

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"

# --- Slug detection: state file first, then fallback ---
STATE_FILE=".claude/memory-state.json"
SLUG=""
AREA=""
SESSION_PATH=""

if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null || true)
    AREA=$(jq -r '.area // empty' "$STATE_FILE" 2>/dev/null || true)
    SESSION_PATH=$(jq -r '.sessionPath // empty' "$STATE_FILE" 2>/dev/null || true)
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
    SESSION_PATH="5 Agent Memory/sessions/by-project/$SLUG/"
fi

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
The blackbox subagent should update this with actual session state.
If blackbox is unavailable, Claude should fill this in manually.

## Session State
[To be filled by blackbox or Claude — summarise decisions, progress, open items]

## Key Files Modified
[To be filled by blackbox or Claude — list files changed this session]

## Next Steps
[To be filled by blackbox or Claude — what was about to happen before compaction]
EOF

# Update state file with new checkpoint
if [[ -f "$STATE_FILE" ]]; then
    jq --arg cp "$CHECKPOINT_FILE" '.pendingCheckpoints += [$cp] | .lastUpdated = (now | todate)' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
fi

# --- Build context re-injection ---
CONTEXT="## Memory System Active (restored after compaction)\\n"
CONTEXT+="Project slug: \`$SLUG\`\\n"

if [[ -n "$AREA" ]]; then
    CONTEXT+="Area: \`$AREA\`\\n"
fi

CONTEXT+="Obsidian session path: \`${SESSION_PATH:-5 Agent Memory/sessions/by-project/$SLUG/}\`\\n\\n"

# List all pending checkpoints (including the one just created)
CONTEXT+="📋 **Pending checkpoints:**\\n"
CONTEXT+="- \`$CHECKPOINT_FILE\` (just created — fill in session state before compaction completes)\\n"
while IFS= read -r -d '' file; do
    if [[ "$file" != "$CHECKPOINT_FILE" ]]; then
        CONTEXT+="- \`$file\` (from prior session)\\n"
    fi
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)
CONTEXT+="Process these to Obsidian \`5 Agent Memory/working/\` when appropriate, then delete the staging files.\\n\\n"

# Dream pending
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending.** Run \`/memory-sync --dream\` when you have a moment.\\n\\n"
fi

CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"

# Output combined context
jq -n --arg msg "$(echo -e "$CONTEXT")" '{"systemMessage": $msg}'
