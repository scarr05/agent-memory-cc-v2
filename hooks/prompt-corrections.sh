#!/usr/bin/env bash
# prompt-corrections.sh — UserPromptSubmit hook for memory system
# Just-in-time correction surfacing: if the user's prompt mentions a topic that
# has a logged correction, inject a one-line pointer so Claude loads it before
# acting. Budget <100ms: the common case (no corrections for this project) exits
# before reading stdin or spawning jq.

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
STATE_FILE=".claude/memory-state.json"

# --- Fast slug detection: state file (sed, no jq) -> CLAUDE.md -> dirname ---
SLUG=""
if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(sed -n 's/.*"slug": *"\([^"]*\)".*/\1/p' "$STATE_FILE" 2>/dev/null | head -1)
fi
if [[ -z "$SLUG" ]] && [[ -f "$CLAUDE_MD" ]]; then
    SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1)
fi
if [[ -z "$SLUG" ]]; then
    SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
fi
# Defence in depth: clamp so a crafted slug can't traverse out of the staging dir.
# Pure-bash builtins (bash 4+) — no subprocess on this per-prompt hot path.
SLUG="${SLUG,,}"
SLUG="${SLUG//[^a-z0-9-]/}"
[[ -z "$SLUG" ]] && SLUG="unknown"

INDEX="$STAGING_DIR/$SLUG/.corrections-index"

# Common case: no corrections on record for this project. Exit before reading
# stdin or spawning anything — this is the per-prompt hot path.
[[ -f "$INDEX" ]] || exit 0

# Corrections exist: read the prompt and match index keywords against it.
RAW=$(cat || true)
PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)
# If the prompt field can't be parsed, match against the raw payload rather than
# silently miss a correction (fail toward surfacing).
[[ -z "$PROMPT" ]] && PROMPT="$RAW"
PROMPT_LC="${PROMPT,,}"

# Index lines: "<title>|<key>" where <key> is the lowercased, space-separated
# topic (built by session-start.sh, always newline-terminated via awk's ORS).
# Pure-bash substring match — no per-line spawn. "$key" is quoted inside the
# case pattern, so its contents are literal (no glob injection from a crafted
# vault filename).
HITS=""
while IFS='|' read -r name key; do
    [[ -z "$key" ]] && continue
    case "$PROMPT_LC" in
        *"$key"*) HITS="${HITS:+$HITS, }$name" ;;
    esac
done < "$INDEX"

[[ -z "$HITS" ]] && exit 0

MSG="Correction(s) on record for: $HITS. Load the details via memberberry before proceeding."

# additionalContext is the documented UserPromptSubmit injection channel and is
# verified working for the sibling SessionStart hook on this CC version.
# MEMORY_HOOK_PLAINTEXT=1 falls back to plain stdout (also documented as
# injected) if additionalContext proves unreliable for this hook.
if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]]; then
    echo "$MSG"
else
    jq -n --arg ctx "$MSG" \
        '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
fi
exit 0
