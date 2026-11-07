#!/usr/bin/env bash
# session-end.sh — SessionEnd hook for memory system
# Deterministically flags a session that ended without /memory-sync, so the next
# SessionStart can nudge. Side-effect only: emits no stdout, always exits 0
# (SessionEnd cannot block or inject context).

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"

# SessionEnd receives JSON on stdin: { reason, transcript_path }.
# reason: clear | logout | prompt_input_exit | other. A `clear` is a deliberate
# wipe — it is never flagged unsynced, but it now falls through to slug detection
# so it can harvest a clear-fallback handoff (handled below). Fail open otherwise.
# The transcript and the handoff library are read lazily in the clear branch only,
# so the common non-clear path (logout/other) stays lean.
STDIN_JSON=$(cat || true)
REASON=$(printf '%s' "$STDIN_JSON" | jq -r '.reason // empty' 2>/dev/null || true)

# --- Slug: the shared lookup (slug-lib.sh, beside this hook) ---
# Without it the hook stages under "unknown" rather than guess a directory.
LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
# shellcheck source=/dev/null
if [[ -f "$LIBDIR/slug-lib.sh" ]]; then source "$LIBDIR/slug-lib.sh"; resolve_slug; else SLUG="unknown"; fi

# --- Where this session's state lives (state-lib.sh, beside this hook) ---
# SESSION_DIR is keyed by the hook input's session_id, so two sessions in one
# project keep separate counts; SLOT_DIR holds what crosses /clear. Without the
# library or a session id, both are the project folder, as before.
SESSION_ID=""
if [[ -f "$LIBDIR/state-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIBDIR/state-lib.sh"
    state_session_id "$STDIN_JSON"; state_dirs
else
    PROJECT_DIR="$STAGING_DIR/$SLUG"; SLOT_DIR="$PROJECT_DIR"; SESSION_DIR="$PROJECT_DIR"
fi

META_FILE="$SESSION_DIR/.session-meta"

# Bare /clear with no armed handoff: deterministically harvest a clear-fallback
# so the thread is never silently lost. Never clobber an active manual handoff.
# The library + transcript are read lazily HERE so the common non-clear path
# (logout/other) stays lean — this branch exits before the unsynced logic, so a
# deliberate clear is never "unsynced".
if [[ "$REASON" == "clear" ]]; then
    HANDOFF_LIB=0
    if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then
        # shellcheck source=/dev/null
        source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1
    fi
    TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    if [[ "$HANDOFF_LIB" == "1" && -n "$TRANSCRIPT" && ! -f "$SLOT_DIR/handoff.md" ]]; then
        mkdir -p "$SLOT_DIR"
        build_deterministic_handoff --transcript "$TRANSCRIPT" --slug "$SLUG" --source clear-fallback --out "$SLOT_DIR/handoff.md" 2>/dev/null || true
        # Route through finalize so the supersedes chain is stamped. source is
        # clear-fallback (not handoff), so the narrative thin-guard is skipped and
        # the deterministic-only fallback always arms.
        finalize_handoff --out "$SLOT_DIR/handoff.md" --consumed "$SLOT_DIR/handoff.consumed.md" >/dev/null 2>&1 || true
    fi
    exit 0
fi

# No meta means SessionStart never tracked this session — nothing to flag.
[[ -f "$META_FILE" ]] || exit 0

MESSAGE_COUNT=$(sed -n 's/^message_count=\([0-9]*\).*/\1/p' "$META_FILE" | head -1)
MESSAGE_COUNT="${MESSAGE_COUNT:-0}"

# Flag only a session of real length (>=10 exchanges) that was never synced.
# /memory-sync writes synced=true (Task 7) and owns removal of .unsynced; this
# hook only creates it. SessionStart surfaces it on the next full-path start.
if [[ "$MESSAGE_COUNT" -ge 10 ]] && ! grep -q '^synced=true' "$META_FILE" 2>/dev/null; then
    cat > "$SLOT_DIR/.unsynced" << EOF
ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)
messages=$MESSAGE_COUNT
EOF
fi

exit 0
