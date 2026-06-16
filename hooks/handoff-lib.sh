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

# Frequency table of files edited this work unit. Reads windowed JSONL on stdin.
# Covers Edit/Write/MultiEdit (file_path) and NotebookEdit (notebook_path).
harvest_files() {
    jq -r 'select(.type=="assistant") | .message.content[]?
           | select(.type=="tool_use")
           | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
           | (.input.file_path // .input.notebook_path // empty)' 2>/dev/null \
        | sort | uniq -c | sort -rn | sed -E 's/^[[:space:]]*//'
}

# Git snapshot for the handoff: branch, dirty count, last 3 commits. Operates on
# the current working directory (the command/hook runs in the repo root).
harvest_git() {
    if ! { command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; }; then
        echo "Not a git repo."
        return 0
    fi
    local branch dirty
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
    echo "Branch: \`$branch\` ($dirty dirty files)"
    echo "Recent commits:"
    git log --oneline -3 2>/dev/null | sed 's/^/- /' || true
}

# ---- CLI dispatcher (added in Task 6) ----
