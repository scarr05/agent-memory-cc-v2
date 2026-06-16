#!/usr/bin/env bash
# stop-memory.sh — Stop hook for memory system
# Tracks message count and nudges for /memory-sync on significant sessions.
# Fires on EVERY response. Hot-path design: state-file read, one awk pass,
# conditional printf. One jq parse of the tiny Stop stdin payload runs per turn
# to extract transcript_path (needed to keep the path breadcrumb current and to
# check for the handoff token nudge). The expensive token scan is gated behind
# a message-count floor (>= 8 exchanges) and a once-per-session flag, so jq
# only reads the transcript file at most a few times per session, never on the
# common short turn. (<=50ms is unreachable on Git Bash; the harness WARNs over
# 50ms and FAILs only on a >2x regression.)

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
STATE_FILE=".claude/memory-state.json"

LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1
else
    HANDOFF_LIB=0
fi
# Stop receives { transcript_path } on stdin; capture it for the token nudge.
STDIN_JSON=$(cat || true)
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)

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

# Refresh the transcript breadcrumb for /handoff every turn (tiny, unconditional —
# keeps the authoritative path current as the session grows).
if [[ -n "${TRANSCRIPT:-}" ]]; then
    printf '%s\n' "$TRANSCRIPT" > "$PROJECT_DIR/.transcript-path" 2>/dev/null || true
fi

# --- Handoff token nudge (off hot path) ---
# Cheap pre-checks gate the expensive transcript scan: skip entirely until the
# session is plausibly large (>= 8 exchanges) and only fire once. 150k tokens is
# implausible before a handful of exchanges, so the jq scan runs at most a few
# times per session, never on the common short turn.
MSG_NOW=$(sed -n 's/^message_count=\([0-9]*\).*/\1/p' "$META_FILE" | head -1); MSG_NOW="${MSG_NOW:-0}"
if [[ "$HANDOFF_LIB" == "1" ]] && [[ -n "$TRANSCRIPT" ]] \
   && [[ "$MSG_NOW" -ge 8 ]] && ! grep -q '^handoff_nudge_sent=true' "$META_FILE" 2>/dev/null; then
    # Threshold: project settings -> global settings -> 150000 default.
    THRESH=$(jq -r '.memory.handoffTokenThreshold // empty' .claude/settings.json 2>/dev/null || true)
    [[ -z "$THRESH" ]] && THRESH=$(jq -r '.memory.handoffTokenThreshold // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
    [[ "$THRESH" =~ ^[0-9]+$ ]] || THRESH=150000
    LIVE=$(read_live_tokens "$TRANSCRIPT")
    if [[ "$LIVE" =~ ^[0-9]+$ ]] && [[ "$LIVE" -ge "$THRESH" ]]; then
        # Upsert the once-per-session flag (replace if present, else append) so it
        # can never accumulate duplicate lines across runs.
        if grep -q '^handoff_nudge_sent=' "$META_FILE" 2>/dev/null; then
            sed -i 's/^handoff_nudge_sent=.*/handoff_nudge_sent=true/' "$META_FILE"
        else
            echo "handoff_nudge_sent=true" >> "$META_FILE"
        fi
        HANDOFF_MSG="~$((LIVE / 1000))k tokens — consider /handoff then /clear to continue in a fresh session."
        if [[ -n "$NUDGE" ]]; then NUDGE="$NUDGE | $HANDOFF_MSG"; else NUDGE="$HANDOFF_MSG"; fi
    fi
fi

# Output nudge if significant. systemMessage = user-visible reminder; never block
# the agent on Stop. ($NUDGE has no quotes/backslashes by construction.)
if [[ -n "$NUDGE" ]]; then
    printf '{"systemMessage": "%s"}\n' "$NUDGE"
fi

# Always exit 0 — never block on Stop.
exit 0
