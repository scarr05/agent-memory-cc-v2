#!/usr/bin/env bash
# stop-memory.sh — Stop hook for memory system
# Tracks message count and nudges for /memory-sync on significant sessions.
# Fires on EVERY response — keep it to a state-file read, one awk pass, and a
# conditional printf. No jq, no date -d. (<=50ms is unreachable on Git Bash; the
# harness WARNs over 50ms and FAILs only on a >2x regression.)

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
STATE_FILE=".claude/memory-state.json"

# --- Fast slug detection: state file first (sed, no jq), then minimal fallback ---
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
# Defence in depth: the state-file branch above is not charset-filtered. Clamp so
# a crafted slug can't traverse out of the staging dir (it forms rm/mkdir paths).
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
[[ -z "$SLUG" ]] && SLUG="unknown"

PROJECT_DIR="$STAGING_DIR/$SLUG"
META_FILE="$PROJECT_DIR/.session-meta"

[[ -d "$PROJECT_DIR" ]] || mkdir -p "$PROJECT_DIR"

NOW_EPOCH=$(date +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Initialise meta if missing (shouldn't happen if SessionStart ran). Schema
# source of truth is session-start.sh's reset block — keep these fields in sync.
if [[ ! -f "$META_FILE" ]]; then
    cat > "$META_FILE" << EOF
session_start=$NOW_ISO
session_start_epoch=$NOW_EPOCH
message_count=0
project_slug=$SLUG
area=
EOF
fi

# One awk pass: increment message_count, refresh last_activity, compute the
# session duration from session_start_epoch, and apply the nudge sent-flags. The
# new meta is written to a temp file; the nudge message (if any) is printed to
# stdout for the shell to emit. Highest threshold first so a session that jumps
# past 15 (a missed fire) still triggers the 30 nudge. Unknown lines
# (project_slug, area, synced, session_start, ...) are preserved verbatim.
NUDGE=$(awk -v now_iso="$NOW_ISO" -v now_epoch="$NOW_EPOCH" -v tmp="$META_FILE.tmp" '
    BEGIN { count = 0; n15 = 0; n30 = 0; ndur = 0; start_epoch = 0 }
    /^message_count=/           { split($0, a, "="); count = a[2] + 0; next }
    /^last_activity=/           { next }
    /^nudge15_sent=true/        { n15 = 1; print > tmp; next }
    /^nudge30_sent=true/        { n30 = 1; print > tmp; next }
    /^duration_nudge_sent=true/ { ndur = 1; print > tmp; next }
    /^session_start_epoch=/     { split($0, a, "="); start_epoch = a[2] + 0; print > tmp; next }
    { print > tmp }
    END {
        newcount = count + 1
        print "message_count=" newcount > tmp
        print "last_activity=" now_iso > tmp
        dur = (start_epoch > 0) ? int((now_epoch - start_epoch) / 60) : 0
        msg = ""
        if (newcount >= 30 && !n30) {
            print "nudge30_sent=true" > tmp
            msg = "This session has " newcount " exchanges (~" dur "min). Consider running /memory-sync to checkpoint progress to Obsidian."
        } else if (newcount >= 15 && !n15) {
            print "nudge15_sent=true" > tmp
            msg = "This session has " newcount " exchanges (~" dur "min). Consider running /memory-sync to checkpoint progress to Obsidian."
        }
        if (dur >= 45 && !ndur) {
            print "duration_nudge_sent=true" > tmp
            msg = "This session has been running for " dur " minutes with " newcount " exchanges. Consider running /memory-sync before context gets too large."
        }
        print msg
    }
' "$META_FILE" 2>/dev/null) || NUDGE=""
# Never let a failed awk/mv abort the Stop hook — it must always exit 0. Promote
# only a non-empty tmp so a half-written awk output can't clobber good meta (the
# counter just stalls for one turn instead, which is safe degradation).
if [[ -s "$META_FILE.tmp" ]]; then
    mv "$META_FILE.tmp" "$META_FILE" 2>/dev/null || true
else
    rm -f "$META_FILE.tmp" 2>/dev/null || true
fi

# Output nudge if significant. systemMessage = user-visible reminder; never block
# the agent on Stop. ($NUDGE has no quotes/backslashes by construction.)
if [[ -n "$NUDGE" ]]; then
    printf '{"systemMessage": "%s"}\n' "$NUDGE"
fi

# Always exit 0 — never block on Stop.
exit 0
