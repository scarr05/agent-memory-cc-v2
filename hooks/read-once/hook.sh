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

# Dependency check — jq is required for JSON parsing and output
if ! command -v jq &>/dev/null; then
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-once: jq is not installed. Install jq to enable redundant read prevention."}}'
    exit 0
fi

# Validate numeric config
if ! [[ "$TTL" =~ ^[0-9]+$ ]] || ! [[ "$DIFF_MAX" =~ ^[0-9]+$ ]]; then
    echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"read-once: TTL or DIFF_MAX is not a valid number. Check READ_ONCE_TTL and READ_ONCE_DIFF_MAX."}}'
    exit 0
fi

# --- Cache setup ---
CACHE_DIR="$HOME/.claude/read-once/cache"
SESSION_ID=$(echo "${CLAUDE_SESSION_ID:-$$}" | tr -cd 'A-Za-z0-9_-')
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
# sha1 of the path: fixed 40-char filename, safe for non-ASCII and >NAME_MAX
# paths (raw base64 can emit "/" for bytes >=0x80 and overflow NAME_MAX).
# sha1sum ships with Git Bash / coreutils.
CACHE_KEY=$(printf '%s' "$FILE_PATH" | sha1sum 2>/dev/null || true)
CACHE_KEY="${CACHE_KEY%% *}"  # strip the "  -" filename suffix without a cut spawn (hot path)
if [[ -z "$CACHE_KEY" ]]; then
    exit 0  # Cannot create cache key — allow read
fi
CACHE_FILE="$SESSION_CACHE/$CACHE_KEY"

# --- Helper: atomic cache write ---
write_cache() {
    local mtime="$1"
    local timestamp="$2"
    printf '%s\n%s\n' "$mtime" "$timestamp" > "$CACHE_FILE.tmp"
    mv "$CACHE_FILE.tmp" "$CACHE_FILE"
}

# --- Get current file state ---
if [[ ! -f "$FILE_PATH" ]]; then
    # File doesn't exist — let Read tool handle the error
    exit 0
fi

CURRENT_MTIME=$(stat -c %Y "$FILE_PATH" 2>/dev/null || stat -f %m "$FILE_PATH" 2>/dev/null || true)
if [[ -z "$CURRENT_MTIME" ]]; then
    exit 0  # Cannot determine mtime — allow read without caching
fi

# --- Check cache ---
if [[ -f "$CACHE_FILE" ]]; then
    CACHED_MTIME=$(sed -n '1p' "$CACHE_FILE")
    CACHED_TIME=$(sed -n '2p' "$CACHE_FILE")
    NOW=$(date +%s)

    # Guard against empty cached values
    if [[ -z "$CACHED_MTIME" ]] || [[ -z "$CACHED_TIME" ]]; then
        write_cache "$CURRENT_MTIME" "$NOW"
        exit 0
    fi

    # Check TTL expiry
    ELAPSED=$((NOW - CACHED_TIME))
    if [[ "$ELAPSED" -ge "$TTL" ]]; then
        write_cache "$CURRENT_MTIME" "$NOW"
        exit 0
    fi

    # File unchanged since last read
    if [[ "$CURRENT_MTIME" == "$CACHED_MTIME" ]]; then
        MINS_AGO=$((ELAPSED / 60))

        if [[ "$MODE" == "deny" ]]; then
            jq -n --arg path "$FILE_PATH" --argjson mins "$MINS_AGO" \
                '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: ("read-once: already in context (read " + ($mins | tostring) + "m ago, unchanged). File: " + $path)}}'
            exit 0
        else
            jq -n --arg path "$FILE_PATH" --argjson mins "$MINS_AGO" \
                '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: ("read-once: this file was already read " + ($mins | tostring) + "m ago and hasn'\''t changed. It should still be in your context. File: " + $path)}}'
            exit 0
        fi
    fi

    # File changed since last read
    if [[ "$DIFF_ENABLED" == "1" ]]; then
        # Check that cached content exists before attempting diff
        if [[ -f "$CACHE_FILE.content" ]]; then
            DIFF_OUTPUT=$(diff "$CACHE_FILE.content" "$FILE_PATH" 2>/dev/null || true)
            DIFF_LINES=$(echo "$DIFF_OUTPUT" | wc -l)

            if [[ "$DIFF_LINES" -gt 0 ]] && [[ "$DIFF_LINES" -le "$DIFF_MAX" ]]; then
                write_cache "$CURRENT_MTIME" "$(date +%s)"
                cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true

                TRIMMED_DIFF=$(echo "$DIFF_OUTPUT" | head -"$DIFF_MAX")
                jq -n --arg lines "$DIFF_LINES" --arg diff "$TRIMMED_DIFF" \
                    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "allow", permissionDecisionReason: ("read-once: file changed since last read (" + $lines + " lines differ). Diff:\n" + $diff)}}'
                exit 0
            fi
        fi
        # No cached content or diff too large — fall through to full re-read
    fi

    # Update cache and allow full re-read
    write_cache "$CURRENT_MTIME" "$(date +%s)"
    if [[ "$DIFF_ENABLED" == "1" ]]; then
        cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
    fi
    exit 0
fi

# --- First read: cache and allow ---
write_cache "$CURRENT_MTIME" "$(date +%s)"
if [[ "$DIFF_ENABLED" == "1" ]]; then
    cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
fi
exit 0
