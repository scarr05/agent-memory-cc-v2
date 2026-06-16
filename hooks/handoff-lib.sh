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

# (functions added in Tasks 2-6)

# ---- CLI dispatcher (added in Task 6) ----
