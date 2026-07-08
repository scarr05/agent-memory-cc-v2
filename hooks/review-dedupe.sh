#!/usr/bin/env bash
# review-dedupe.sh — UserPromptSubmit hook.
# Warns when /security-review or /code-review is invoked on a diff whose hash
# matches the last-reviewed hash for this repo (audit: 4 duplicate-pair reviews
# on byte-identical diffs, one pair 17s apart). Warn-only — never blocks.
set -euo pipefail

RAW=$(cat || true)
PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)

# Hot path: only review commands pay anything beyond the jq parse.
case "$PROMPT" in
    /security-review*|/code-review*) ;;
    *) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Hash = HEAD commit + working+staged diff. Clean tree at the same commit
# hashes identically — that IS the duplicate-branch-review case we want caught.
HASH=$( { git rev-parse HEAD 2>/dev/null; git diff HEAD 2>/dev/null; } | sha256sum | cut -d' ' -f1)

STATE_DIR="$HOME/.claude/review-dedupe"
REPO_KEY=$(printf '%s' "$PWD" | sha256sum | cut -c1-16)
STATE_FILE="$STATE_DIR/$REPO_KEY"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [[ -f "$STATE_FILE" ]]; then
    read -r PREV_HASH PREV_TIME < "$STATE_FILE" || true
    if [[ "$HASH" == "${PREV_HASH:-}" ]]; then
        MSG="Review dedupe: this exact diff (${HASH:0:12}…) was already reviewed at ${PREV_TIME:-unknown}. Tell the user and confirm before re-running the review."
        jq -n --arg ctx "$MSG" \
            '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
        exit 0   # dupe: do NOT refresh the timestamp
    fi
fi

printf '%s %s\n' "$HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE" 2>/dev/null || true
exit 0
