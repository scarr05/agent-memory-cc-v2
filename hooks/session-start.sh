#!/usr/bin/env bash
# session-start.sh — SessionStart hook for memory system (v3)
# Uses Obsidian CLI for vault reads, directs agent to subagents
# Falls back gracefully if CLI unavailable

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"

# --- Output emitter ---
# additionalContext is the documented injection channel for SessionStart.
# MEMORY_HOOK_PLAINTEXT=1 falls back to plain stdout (also documented) in case
# the upstream additionalContext bug (#16538) is still live for this CC version.
# Takes the context string as an explicit argument so callers cannot emit a
# half-built payload — the full path and this script's compact/clear branch
# (Task 4) both call it the same way, with their context fully assembled.
emit_context_and_exit() {
    local ctx="$1"
    if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]]; then
        echo -e "$ctx"
    else
        jq -n --arg ctx "$(echo -e "$ctx")" \
            '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": $ctx}}'
    fi
    exit 0
}

# --- Project slug detection (unchanged from v2) ---

detect_slug() {
    _DETECTED_VIA=""

    # Priority 1: Existing CLAUDE.md metadata
    if [[ -f "$CLAUDE_MD" ]]; then
        local slug
        slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="claude-md-metadata"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 1b: .claude/memory-state.json from prior session
    if [[ -f ".claude/memory-state.json" ]]; then
        local slug
        slug=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="memory-state-file"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 2: .claude/settings.json custom field
    if [[ -f ".claude/settings.json" ]]; then
        local slug
        slug=$(jq -r '.memory.projectSlug // empty' .claude/settings.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="settings-json"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 3: Git remote
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local remote
        remote=$(git remote get-url origin 2>/dev/null || true)
        if [[ -n "$remote" ]]; then
            local slug
            slug=$(echo "$remote" | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$slug" ]]; then
                _DETECTED_VIA="git-remote"
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
            _DETECTED_VIA="package-json"
            echo "$slug"
            return 0
        fi
    fi

    if [[ -f "pyproject.toml" ]]; then
        local slug
        slug=$(sed -n 's/.*name = "\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="pyproject-toml"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 5: Directory name
    _DETECTED_VIA="directory-name"
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

_DETECTED_VIA=""
SLUG=$(detect_slug)
DETECTED_VIA="$_DETECTED_VIA"
AREA=$(detect_area)
PROJECT_DIR="$STAGING_DIR/$SLUG"

# Ensure staging directory exists
mkdir -p "$PROJECT_DIR"

# --- Write persistent state file ---
STATE_FILE=".claude/memory-state.json"
mkdir -p .claude

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

# Keep memory-state.json out of git status without touching tracked .gitignore
GIT_DIR_PATH=$(git rev-parse --git-dir 2>/dev/null || true)
if [[ -n "$GIT_DIR_PATH" ]]; then
    EXCLUDE_FILE="$GIT_DIR_PATH/info/exclude"
    if ! grep -q 'memory-state.json' "$EXCLUDE_FILE" 2>/dev/null; then
        echo ".claude/memory-state.json" >> "$EXCLUDE_FILE" 2>/dev/null || true
    fi
fi

# Check for pending checkpoints
PENDING_CHECKPOINTS=()
while IFS= read -r -d '' file; do
    PENDING_CHECKPOINTS+=("$file")
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)

# Check prior session info
PRIOR_SESSION_INFO=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    PRIOR_SESSION_INFO=$(cat "$PROJECT_DIR/.session-meta")
fi

# Reset session meta
cat > "$PROJECT_DIR/.session-meta" << EOF
session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
message_count=0
project_slug=$SLUG
area=$AREA
EOF

# Check if memory-init has been run
HAS_MEMORY_CONFIG="false"
if [[ -f "$CLAUDE_MD" ]] && grep -q 'memory:project-slug=' "$CLAUDE_MD" 2>/dev/null; then
    HAS_MEMORY_CONFIG="true"
fi

# --- CLI availability check ---
CLI_OK="true"
"$OBS" version > /dev/null 2>&1 || CLI_OK="false"

# --- Build context injection ---
CONTEXT="## Memory System Active\\n"
CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n\\n"

if [[ "$HAS_MEMORY_CONFIG" == "false" ]]; then
    CONTEXT+="⚠ **No memory config.** Run \`/memory-init\` to set up. Using auto-detected slug \`$SLUG\`.\\n\\n"
fi

# --- Git state ---
CONTEXT+="### Git\\n"
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
    CONTEXT+="Branch: \`$BRANCH\`"
    DIRTY_COUNT=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT+=" ($DIRTY_COUNT dirty files)"
    else
        CONTEXT+=" (clean)"
    fi
    CONTEXT+="\\n"
    RECENT=$(git log --oneline -3 2>/dev/null || true)
    if [[ -n "$RECENT" ]]; then
        CONTEXT+="Recent: $(echo "$RECENT" | head -1)\\n"
    fi
else
    CONTEXT+="Not a git repo.\\n"
fi
CONTEXT+="\\n"

# --- CLI-driven vault state ---
if [[ "$CLI_OK" == "true" ]]; then

    # Project status from index
    INDEX_ROW=$("$OBS" search:context query="$SLUG" path="5 Agent Memory/project-index.md" format=json 2>/dev/null || echo "")
    if [[ -n "$INDEX_ROW" ]] && [[ "$INDEX_ROW" != "[]" ]]; then
        CONTEXT+="### Project Status\\n"
        # Extract just the matching text lines
        INDEX_TEXT=$(echo "$INDEX_ROW" | jq -r '.[0].matches[].text' 2>/dev/null | head -3 || true)
        if [[ -n "$INDEX_TEXT" ]]; then
            CONTEXT+="$INDEX_TEXT\\n"
        fi
        CONTEXT+="\\n"
    fi

    # Open tasks
    TASKS=$("$OBS" search:context query="- \[ \]" path="5 Agent Memory/sessions/by-project/$SLUG" format=json limit=5 2>/dev/null || echo "")
    if [[ -n "$TASKS" ]] && [[ "$TASKS" != "[]" ]]; then
        CONTEXT+="### Open Items\\n"
        TASK_LINES=$(echo "$TASKS" | jq -r '.[].matches[].text' 2>/dev/null | head -5 || true)
        if [[ -n "$TASK_LINES" ]]; then
            CONTEXT+="$(echo "$TASK_LINES" | sed 's/^/  /')\\n"
        fi
        CONTEXT+="\\n"
    fi

    # Working files
    WORKING=$("$OBS" search query="$SLUG" path="5 Agent Memory/working" format=json 2>/dev/null || echo "")
    if [[ -n "$WORKING" ]] && [[ "$WORKING" != "[]" ]]; then
        CONTEXT+="### Working Files\\n"
        WORKING_LIST=$(echo "$WORKING" | jq -r '.[]' 2>/dev/null | head -5 | sed 's/^/- /' || true)
        if [[ -n "$WORKING_LIST" ]]; then
            CONTEXT+="$WORKING_LIST\\n"
        fi
        CONTEXT+="\\n"
    fi

    # Corrections flag
    CORRECTIONS=$("$OBS" search query="$SLUG" path="5 Agent Memory/learnings/corrections" format=json 2>/dev/null || echo "")
    if [[ -n "$CORRECTIONS" ]] && [[ "$CORRECTIONS" != "[]" ]]; then
        CONTEXT+="### ⚠ Corrections exist — load via memberberry before making assumptions\\n\\n"
    fi

    # Session depth
    SESSION_COUNT=$("$OBS" search query="type: session" path="5 Agent Memory/sessions/by-project/$SLUG" format=json 2>/dev/null || echo "[]")
    COUNT=$(echo "$SESSION_COUNT" | jq 'length' 2>/dev/null || echo "0")
    CONTEXT+="Memory depth: $COUNT prior sessions\\n\\n"

else
    CONTEXT+="⚠ Obsidian CLI unavailable. Open Obsidian or check PATH.\\n"
    CONTEXT+="Falling back to minimal context. Use MCP for vault access.\\n\\n"
fi

# --- Pending checkpoints ---
if [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
    CONTEXT+="### Pending Checkpoints\\n"
    for cp in "${PENDING_CHECKPOINTS[@]}"; do
        CONTEXT+="- \`$cp\`\\n"
    done
    CONTEXT+="Process these to Obsidian \`5 Agent Memory/working/\` then delete staging files.\\n\\n"
fi

# Dream nudge
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending.** Run \`/memory-sync --dream\` when ready.\\n\\n"
fi

# Prior session info
if [[ -n "$PRIOR_SESSION_INFO" ]]; then
    PRIOR_COUNT=$(echo "$PRIOR_SESSION_INFO" | sed -n 's/.*message_count=\([0-9]*\).*/\1/p' | head -1)
    PRIOR_COUNT="${PRIOR_COUNT:-0}"
    if [[ "$PRIOR_COUNT" -gt 10 ]]; then
        CONTEXT+="ℹ Previous session had $PRIOR_COUNT messages. Check if it was synced (\`/memory-sync --status\`).\\n\\n"
    fi
fi

# --- Delegation guidance ---
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"

# --- Output ---
emit_context_and_exit "$CONTEXT"
