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
if (( BASH_VERSINFO[0] >= 4 )); then
    SLUG="${SLUG,,}"; SLUG="${SLUG//[^a-z0-9-]/}"   # builtins: zero forks on the hot path
else
    # bash 3.2 (macOS): ${var,,} is a runtime "bad substitution", so fork tr|sed instead.
    SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
fi
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

# Index lines: "<title>|<key>" where <key> is the correction's topic, derived from
# its vault filename by session-start.sh. Matching is word-based, not an exact
# phrase: both sides are lowercased, apostrophes dropped (don't -> dont) and every
# other non-alphanumeric run turned into a space (sed -i -> sed i), then a
# correction fires when every significant word of its key appears as a whole word
# in the prompt, in any order (modulo a trailing s). "Significant" drops filler words and one-letter
# tokens, so "dont-use-sed-i-on-macos" needs {sed, macos}. A key made only of
# filler falls back to all its words. One awk pass, no per-line spawn; the prompt
# goes in via ENVIRON so awk does not interpret backslash escapes in it.
HITS=$(RO_PROMPT="$PROMPT" LC_ALL=C awk -F'|' '
    function norm(t) {
        t = tolower(t)
        gsub(/\047|\342\200\231/, "", t)          # ASCII and curly apostrophes
        gsub(/[^a-z0-9]+/, " ", t)
        return t
    }
    # Crude stem: drop one trailing s so plurals and possessives match (paths -> path,
    # CLI-apostrophe-s -> clis -> cli). Applied to both sides of the comparison.
    function stem(w) { return (length(w) > 3 && w ~ /s$/) ? substr(w, 1, length(w) - 1) : w }
    function seen(w) { return (w in have) || (stem(w) in have) }
    BEGIN {
        n = split("a an and are as at be by do does dont for from in into is it its never no not of on or please should the this to use using via when with without always avoid", sw, " ")
        for (i = 1; i <= n; i++) stop[sw[i]] = 1
        np = split(norm(ENVIRON["RO_PROMPT"]), pw, " ")
        for (i = 1; i <= np; i++) { have[pw[i]] = 1; have[stem(pw[i])] = 1 }
        out = ""
    }
    $2 == "" { next }
    {
        nk = split(norm($2), kw, " ")
        if (nk == 0) next
        sig = 0; ok = 1
        for (i = 1; i <= nk; i++) {
            if (kw[i] in stop || length(kw[i]) < 2) continue
            sig++
            if (!seen(kw[i])) { ok = 0; break }
        }
        if (sig == 0) {
            ok = 1
            for (i = 1; i <= nk; i++) if (!seen(kw[i])) { ok = 0; break }
        }
        if (ok) out = (out == "") ? $1 : out ", " $1
    }
    END { print out }
' "$INDEX" 2>/dev/null || true)

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
