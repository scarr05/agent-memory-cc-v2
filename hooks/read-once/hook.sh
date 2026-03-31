#!/usr/bin/env bash
# read-once — PreToolUse hook for Claude Code
# Prevents redundant file re-reads within a session
# Vendored from: https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once
#
# Hook intercepts Read tool calls and checks a session cache.
# First read: allowed, cached. Re-read unchanged: blocked/warned.
# Re-read changed + diff enabled: shows diff only.

set -euo pipefail

# --- Configuration ---
MODE="${READ_ONCE_MODE:-warn}"
TTL="${READ_ONCE_TTL:-1200}"
DIFF_ENABLED="${READ_ONCE_DIFF:-0}"
DIFF_MAX="${READ_ONCE_DIFF_MAX:-40}"
DISABLED="${READ_ONCE_DISABLED:-0}"

# Exit immediately if disabled
[[ "$DISABLED" == "1" ]] && exit 0

# --- Cache setup ---
CACHE_DIR="$HOME/.claude/read-once/cache"
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
SESSION_CACHE="$CACHE_DIR/$SESSION_ID"
mkdir -p "$SESSION_CACHE"

# Auto-clean old session caches (>24h)
find "$CACHE_DIR" -maxdepth 1 -mindepth 1 -type d -mmin +1440 -exec rm -rf {} \; 2>/dev/null || true

# --- Parse input ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

# Only intercept Read tool
[[ "$TOOL_NAME" != "Read" ]] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

# Skip partial reads (offset/limit present) — different content each time
HAS_OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || true)
HAS_LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || true)
if [[ -n "$HAS_OFFSET" ]] || [[ -n "$HAS_LIMIT" ]]; then
    exit 0
fi

# --- Cache key ---
# Use base64 of file path as cache filename to handle special chars
CACHE_KEY=$(echo -n "$FILE_PATH" | base64 -w 0 2>/dev/null || echo -n "$FILE_PATH" | base64 2>/dev/null)
CACHE_FILE="$SESSION_CACHE/$CACHE_KEY"

# --- Get current file state ---
if [[ ! -f "$FILE_PATH" ]]; then
    # File doesn't exist — let Read tool handle the error
    exit 0
fi

CURRENT_MTIME=$(stat -c %Y "$FILE_PATH" 2>/dev/null || stat -f %m "$FILE_PATH" 2>/dev/null || echo "0")

# --- Check cache ---
if [[ -f "$CACHE_FILE" ]]; then
    CACHED_MTIME=$(sed -n '1p' "$CACHE_FILE")
    CACHED_TIME=$(sed -n '2p' "$CACHE_FILE")
    NOW=$(date +%s)

    # Check TTL expiry
    ELAPSED=$((NOW - CACHED_TIME))
    if [[ "$ELAPSED" -ge "$TTL" ]]; then
        # Cache expired — allow read and update cache
        echo "$CURRENT_MTIME" > "$CACHE_FILE"
        echo "$NOW" >> "$CACHE_FILE"
        exit 0
    fi

    # File unchanged since last read
    if [[ "$CURRENT_MTIME" == "$CACHED_MTIME" ]]; then
        MINS_AGO=$((ELAPSED / 60))

        if [[ "$MODE" == "deny" ]]; then
            cat << HOOKJSON
{
  "decision": "block",
  "reason": "read-once: already in context (read ${MINS_AGO}m ago, unchanged). File: $FILE_PATH"
}
HOOKJSON
            exit 0
        else
            # Warn mode — allow but advise
            cat << HOOKJSON
{
  "decision": "allow",
  "reason": "read-once: this file was already read ${MINS_AGO}m ago and hasn't changed. It should still be in your context. File: $FILE_PATH"
}
HOOKJSON
            exit 0
        fi
    fi

    # File changed since last read
    if [[ "$DIFF_ENABLED" == "1" ]]; then
        # Try to show diff only
        # We need the cached content — re-read and diff
        DIFF_OUTPUT=$(diff <(cat "$CACHE_FILE.content" 2>/dev/null || echo "") <(cat "$FILE_PATH") 2>/dev/null || true)
        DIFF_LINES=$(echo "$DIFF_OUTPUT" | wc -l)

        if [[ "$DIFF_LINES" -gt 0 ]] && [[ "$DIFF_LINES" -le "$DIFF_MAX" ]]; then
            # Update cache
            echo "$CURRENT_MTIME" > "$CACHE_FILE"
            echo "$(date +%s)" >> "$CACHE_FILE"
            cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true

            cat << HOOKJSON
{
  "decision": "allow",
  "reason": "read-once: file changed since last read (${DIFF_LINES} lines differ). Diff:\\n$(echo "$DIFF_OUTPUT" | head -"$DIFF_MAX" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' ' ')"
}
HOOKJSON
            exit 0
        fi
        # Diff too large — fall through to full re-read
    fi

    # Update cache and allow full re-read
    echo "$CURRENT_MTIME" > "$CACHE_FILE"
    echo "$(date +%s)" >> "$CACHE_FILE"
    if [[ "$DIFF_ENABLED" == "1" ]]; then
        cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
    fi
    exit 0
fi

# --- First read: cache and allow ---
echo "$CURRENT_MTIME" > "$CACHE_FILE"
echo "$(date +%s)" >> "$CACHE_FILE"
if [[ "$DIFF_ENABLED" == "1" ]]; then
    cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
fi
exit 0
