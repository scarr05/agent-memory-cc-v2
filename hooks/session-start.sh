#!/usr/bin/env bash
# session-start.sh — SessionStart hook for memory system
# Detects project, checks for pending memory, injects context pointer
# Receives JSON on stdin with session info

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"

# --- Project slug detection ---

detect_slug() {
    # Priority 1: Existing CLAUDE.md metadata
    if [[ -f "$CLAUDE_MD" ]]; then
        local slug
        slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$slug" ]]; then
            echo "claude-md-metadata" > "$_DETECTED_VIA_FILE"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 1b: .claude/memory-state.json from prior session
    if [[ -f ".claude/memory-state.json" ]]; then
        local slug
        slug=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            echo "memory-state-file" > "$_DETECTED_VIA_FILE"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 2: .claude/settings.json custom field
    if [[ -f ".claude/settings.json" ]]; then
        local slug
        slug=$(jq -r '.memory.projectSlug // empty' .claude/settings.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            echo "settings-json" > "$_DETECTED_VIA_FILE"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 3: Git remote
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local remote
        remote=$(git remote get-url origin 2>/dev/null || true)
        if [[ -n "$remote" ]]; then
            # Extract repo name from various URL formats
            local slug
            slug=$(echo "$remote" | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$slug" ]]; then
                echo "git-remote" > "$_DETECTED_VIA_FILE"
                echo "$slug"
                return 0
            fi
        fi
    fi

    # Priority 4: Project manifest name
    if [[ -f "package.json" ]]; then
        local slug
        slug=$(jq -r '.name // empty' package.json 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            echo "package-json" > "$_DETECTED_VIA_FILE"
            echo "$slug"
            return 0
        fi
    fi

    if [[ -f "pyproject.toml" ]]; then
        local slug
        slug=$(sed -n 's/.*name = "\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            echo "pyproject-toml" > "$_DETECTED_VIA_FILE"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 5: Directory name
    echo "directory-name" > "$_DETECTED_VIA_FILE"
    basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

detect_area() {
    if [[ -f "$CLAUDE_MD" ]]; then
        local area
        area=$(sed -n 's/.*memory:area=\([^ ]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$area" ]]; then
            echo "$area"
            return 0
        fi
    fi
    echo ""
}

# --- Main ---

_DETECTED_VIA_FILE=$(mktemp 2>/dev/null || echo "/tmp/memory-detected-via-$$")
DETECTED_VIA=""
SLUG=$(detect_slug)
DETECTED_VIA=$(cat "$_DETECTED_VIA_FILE" 2>/dev/null || echo "")
rm -f "$_DETECTED_VIA_FILE"
AREA=$(detect_area)
PROJECT_DIR="$STAGING_DIR/$SLUG"

# Ensure staging directory exists
mkdir -p "$PROJECT_DIR"

# --- Write persistent state file ---
STATE_FILE=".claude/memory-state.json"
mkdir -p .claude

# Scan pending checkpoints for state file
CHECKPOINT_JSON="[]"
if [[ -d "$PROJECT_DIR" ]]; then
    CHECKPOINT_LIST=""
    while IFS= read -r -d '' file; do
        if [[ -n "$CHECKPOINT_LIST" ]]; then
            CHECKPOINT_LIST="$CHECKPOINT_LIST, "
        fi
        CHECKPOINT_LIST="$CHECKPOINT_LIST\"$file\""
    done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)
    if [[ -n "$CHECKPOINT_LIST" ]]; then
        CHECKPOINT_JSON="[$CHECKPOINT_LIST]"
    fi
fi

# Check dream-pending
DREAM_PENDING="false"
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    DREAM_PENDING="true"
fi

cat > "$STATE_FILE" << STATEJSON
{
  "slug": "$SLUG",
  "area": "$AREA",
  "sessionPath": "5 Agent Memory/sessions/by-project/$SLUG/",
  "detectedVia": "$DETECTED_VIA",
  "pendingCheckpoints": $CHECKPOINT_JSON,
  "dreamPending": $DREAM_PENDING,
  "lastUpdated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATEJSON

# Check for pending checkpoints from prior sessions
PENDING_CHECKPOINTS=()
while IFS= read -r -d '' file; do
    PENDING_CHECKPOINTS+=("$file")
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)

# Check for session meta from prior session
PRIOR_SESSION_INFO=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    PRIOR_SESSION_INFO=$(cat "$PROJECT_DIR/.session-meta")
fi

# Reset session meta for new session
cat > "$PROJECT_DIR/.session-meta" << EOF
session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
message_count=0
project_slug=$SLUG
area=$AREA
EOF

# Check if memory-init has been run (CLAUDE.md has memory metadata)
HAS_MEMORY_CONFIG="false"
if [[ -f "$CLAUDE_MD" ]] && grep -q 'memory:project-slug=' "$CLAUDE_MD" 2>/dev/null; then
    HAS_MEMORY_CONFIG="true"
fi

# --- Build context injection ---

CONTEXT="## Memory System Active\n"
CONTEXT+="Project slug: \`$SLUG\`\n"

if [[ -n "$AREA" ]]; then
    CONTEXT+="Area: \`$AREA\`\n"
fi

CONTEXT+="Obsidian session path: \`5 Agent Memory/sessions/by-project/$SLUG/\`\n\n"

if [[ "$HAS_MEMORY_CONFIG" == "false" ]]; then
    CONTEXT+="⚠ **No memory configuration found.** This project hasn't been initialised with \`/memory-init\`. "
    CONTEXT+="Run \`/memory-init\` to set up the project slug, create the Obsidian folder structure, and load any prior context. "
    CONTEXT+="Using auto-detected slug \`$SLUG\` for now.\n\n"
fi

if [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
    CONTEXT+="📋 **Pending checkpoints from prior session(s):**\n"
    for cp in "${PENDING_CHECKPOINTS[@]}"; do
        CONTEXT+="- \`$cp\`\n"
    done
    CONTEXT+="Process these to Obsidian \`5 Agent Memory/working/\` when appropriate, then delete the staging files.\n\n"
fi

# Dream consolidation nudge (per-project flag set by stop hook)
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending** (24+ hours since last dream). "
    CONTEXT+="Run \`/memory-sync --dream\` when you have a moment to consolidate recent session transcripts.\n\n"
fi

if [[ -n "$PRIOR_SESSION_INFO" ]]; then
    PRIOR_COUNT=$(echo "$PRIOR_SESSION_INFO" | sed -n 's/.*message_count=\([0-9]*\).*/\1/p' | head -1)
    PRIOR_COUNT="${PRIOR_COUNT:-0}"
    if [[ "$PRIOR_COUNT" -gt 10 ]]; then
        CONTEXT+="ℹ Previous session had $PRIOR_COUNT messages. Check if it was synced to Obsidian (\`/memory-sync --status\`).\n\n"
    fi
fi

CONTEXT+="**For non-trivial tasks:** Search Obsidian for prior context before starting:\n"
CONTEXT+="\`search_notes(query=\"$SLUG\", searchContent=true)\` in \`5 Agent Memory/\`\n"

# Output context injection via JSON to stdout
# Claude Code reads this and adds it to the model's context
cat << HOOKJSON
{
  "systemMessage": "$(echo -e "$CONTEXT" | sed 's/"/\\"/g' | tr '\n' ' ')"
}
HOOKJSON
