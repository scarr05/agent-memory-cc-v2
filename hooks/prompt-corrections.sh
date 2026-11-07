#!/usr/bin/env bash
# prompt-corrections.sh — UserPromptSubmit hook for memory system
# Just-in-time correction surfacing: if the user's prompt mentions a topic that
# has a logged correction, inject a one-line pointer so Claude loads it before
# acting. Budget <100ms: the common case (no corrections for this project) exits
# before reading stdin or spawning jq.

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"

# --- Slug: the shared lookup (slug-lib.sh, beside this hook) ---
# Without it the hook stages under "unknown" rather than guess a directory.
LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
# shellcheck source=/dev/null
if [[ -f "$LIBDIR/slug-lib.sh" ]]; then source "$LIBDIR/slug-lib.sh"; resolve_slug; else SLUG="unknown"; fi

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
if (( BASH_VERSINFO[0] >= 4 )); then PROMPT_LC="${PROMPT,,}"; else PROMPT_LC=$(printf '%s' "$PROMPT" | tr '[:upper:]' '[:lower:]'); fi

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
# No jq => degrade to the documented plaintext channel rather than dying at 127
# under set -e, having dropped a correction. Parity with session-start.sh.
if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]] || ! command -v jq >/dev/null 2>&1; then
    echo "$MSG"
else
    jq -n --arg ctx "$MSG" \
        '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
fi
exit 0
