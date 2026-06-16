#!/usr/bin/env bash
# handoff-lib.sh — shared deterministic harvest library for the handoff workflow.
# Sourced by session-start.sh / session-end.sh / stop-memory.sh, and dispatched
# as a CLI by the /handoff command. All functions are pure-ish: they take a
# transcript path or read windowed JSONL on stdin and write to stdout, so they
# are unit-testable against fixture transcripts (tests/handoff-lib-test.sh).
#
# Sourcing contract: callers `source` this file and guard every call on the
# library being present, e.g.
#   LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1; else HANDOFF_LIB=0; fi
# so a partial install degrades to a no-op rather than crashing the hook.

# Print transcript entries after the LAST compaction boundary. Boundary detection
# is STRUCTURAL: a cheap grep prefilter finds candidate lines containing the
# marker substring, then each candidate is confirmed with jq to carry a TOP-LEVEL
# compactMetadata key — so the token nested inside ordinary tool output is never
# mistaken for a boundary. grep tolerates malformed lines elsewhere in the file;
# only the few candidate lines are jq-parsed. No compaction => whole file (a fresh
# post-/clear session is already its own transcript).
window_transcript() {
    local t="$1"
    [[ -f "$t" ]] || return 0
    local last="" ln rest
    while IFS= read -r ln; do
        rest="${ln#*:}"
        if printf '%s' "$rest" | jq -e 'has("compactMetadata")' >/dev/null 2>&1; then
            last="${ln%%:*}"
        fi
    done < <(grep -n '"compactMetadata"' "$t" 2>/dev/null || true)
    if [[ -n "$last" ]]; then
        tail -n +"$((last + 1))" "$t"
    else
        cat "$t"
    fi
}

# ---- CLI dispatcher (added in Task 6) ----
