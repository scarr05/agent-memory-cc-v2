#!/usr/bin/env bash
# state-lib.sh: where the memory hooks keep each kind of state, so that two
# sessions in one project never write the same session file. Sourced by the
# hooks after slug-lib.sh (it needs SLUG); run as a script by the /memory-sync
# and /handoff commands.
#
#   $STAGING_DIR/<slug>/                    the project: .corrections-index,
#                                           .vault-cache-*, .last-dream, .dream-pending
#   $STAGING_DIR/<slug>/sessions/<id>/      one session: .session-meta, .transcript-path
#   SLOT_DIR, the same folder as the project, holds what crosses /clear:
#     handoff.md, handoff.consumed.md, .unsynced, .last-session (newest session
#     id). relay-baton, /wrap and memory-load read <slug>/handoff.md there.
#
# The session id is the hook input's `session_id`. Without one (an older Claude
# Code, a hand run) the session's files stay in the slot: the old layout.
# Session ids are clamped to [A-Za-z0-9_-]; they become paths.
#
#   bash state-lib.sh paths [--session ID]           KEY=value lines for a command
#   bash state-lib.sh args memory-sync|handoff       arguments on stdin; MODE, AUTO, NOTE
#   bash state-lib.sh mark synced|handoff [--session ID]
#
# Auto memory: a project whose .claude/CLAUDE.md carries `<!-- memory:auto=true -->`
# runs /memory-sync and /handoff as if --auto were given (AUTO_WHY=project).

_STATE_SID_RE='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'

# Sets SESSION_ID from the hook JSON in $1, clamped; empty when there is none. No fork.
state_session_id() {
    SESSION_ID=""
    [[ $1 =~ $_STATE_SID_RE ]] && SESSION_ID="${BASH_REMATCH[1]//[^A-Za-z0-9_-]/}"
    return 0
}

# Sets PROJECT_AUTO=1 when the project opts into auto memory with a
# `<!-- memory:auto=true -->` marker (slug_marker: this checkout's
# .claude/CLAUDE.md, else the main checkout's), else 0. Needs slug-lib.sh,
# sourced first; without it, 0.
state_project_auto() {
    local _found=""
    PROJECT_AUTO=0
    declare -F slug_marker >/dev/null && slug_marker 'memory:auto=([a-z]+)' &&
        [[ "$_found" == "true" ]] && PROJECT_AUTO=1
    return 0
}

# Sets PROJECT_DIR, SLOT_DIR and SESSION_DIR from SLUG and SESSION_ID. No fork.
state_dirs() {
    PROJECT_DIR="${STAGING_DIR:-$HOME/.claude/memory-staging}/$SLUG"
    SLOT_DIR="$PROJECT_DIR"
    if [[ -n "${SESSION_ID:-}" ]]; then
        SESSION_DIR="$PROJECT_DIR/sessions/$SESSION_ID"
    else
        SESSION_DIR="$SLOT_DIR"
    fi
}

# Sets LAST_SESSION to the slot's newest session id (.last-session, written by
# SessionStart), clamped; empty when there is none. No fork.
state_last_session() {
    LAST_SESSION=""
    if [[ -f "$SLOT_DIR/.last-session" ]]; then
        IFS= read -r LAST_SESSION <"$SLOT_DIR/.last-session" || true
    fi
    LAST_SESSION="${LAST_SESSION//[^A-Za-z0-9_-]/}"
    return 0
}

# Replace KEY's line in FILE, or append it. $1=key $2=value $3=file
state_set() {
    local tmp="$3.tmp.$$"
    [[ -f "$3" ]] || : >"$3"
    awk -v k="$1" -v v="$2" 'BEGIN { p = k "=" } index($0, p) == 1 { if (!d) print p v; d = 1; next }
        { print } END { if (!d) print p v }' "$3" >"$tmp" && mv "$tmp" "$3" || { rm -f "$tmp"; return 1; }
}

# ---- CLI ------------------------------------------------------------------------

_state_die() { echo "state-lib.sh: $*" >&2; exit 2; }

# Source slug-lib.sh from beside this file; false when it is missing.
_state_source_slug_lib() {
    local LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
    [[ -f "$LIBDIR/slug-lib.sh" ]] || return 1
    # shellcheck source=/dev/null
    source "$LIBDIR/slug-lib.sh"
}

# Resolve SLUG, the dirs and the session: the id from `--session ID`, else the
# slot's newest session. $1 names the subcommand for errors; the rest are its
# arguments, of which only --session is known. Sets SESSION_SOURCE, TRANSCRIPT
# and AMBIGUOUS. AMBIGUOUS=1 only on the fallback, when two transcripts beside
# this session's moved in the last two minutes: then the newest session in the
# slot may not be the one asking.
_state_resolve() {
    local sub="$1" given="" crumb="" recent=0
    shift
    while [[ $# -gt 0 ]]; do case "$1" in
        --session) given="${2:-}"; shift 2 || shift;;
        *) _state_die "$sub: unknown argument '$1'";;
    esac; done
    if _state_source_slug_lib; then resolve_slug; else SLUG="unknown"; fi
    SESSION_ID="${given//[^A-Za-z0-9_-]/}"
    SESSION_SOURCE="given"
    state_dirs
    if [[ -z "$SESSION_ID" ]]; then
        state_last_session
        SESSION_ID="$LAST_SESSION"
        SESSION_SOURCE="none"
        if [[ -n "$SESSION_ID" ]]; then
            SESSION_SOURCE="pointer"; SESSION_DIR="$PROJECT_DIR/sessions/$SESSION_ID"
        fi
    fi
    TRANSCRIPT=""
    if [[ -f "$SESSION_DIR/.transcript-path" ]]; then
        IFS= read -r crumb <"$SESSION_DIR/.transcript-path" || true
        crumb="${crumb%$'\r'}"
        [[ -f "$crumb" ]] && TRANSCRIPT="$crumb"
    fi
    AMBIGUOUS=0
    if [[ "$SESSION_SOURCE" != "given" && -n "$TRANSCRIPT" ]]; then
        crumb="${TRANSCRIPT//\\//}"
        recent=$(find "${crumb%/*}" -maxdepth 1 -name '*.jsonl' -mmin -2 2>/dev/null | wc -l | tr -d ' ')
        [[ "${recent:-0}" -gt 1 ]] && AMBIGUOUS=1
    fi
    return 0
}

_state_cli_paths() {
    _state_resolve paths "$@"
    printf '%s=%s\n' SLUG "$SLUG" PROJECT_DIR "$PROJECT_DIR" SLOT_DIR "$SLOT_DIR" \
        SESSION_ID "$SESSION_ID" SESSION_SOURCE "$SESSION_SOURCE" SESSION_DIR "$SESSION_DIR" \
        TRANSCRIPT "${TRANSCRIPT:-<none>}" AMBIGUOUS "$AMBIGUOUS"
}

# Arguments arrive on stdin (the command pastes $ARGUMENTS into a quoted
# heredoc, so quotes in a note cannot break the shell). Flags are exact words;
# anything else starting with - is refused, so a typo never runs the wrong mode.
#   memory-sync: at most one of --dream --ingest --tidy --status, plus --auto.
#                Words that are not flags are refused too: the command takes none.
#   handoff:     --auto, then free text kept as NOTE.
# AUTO=1 also when the project opts in with `memory:auto=true` (AUTO_WHY=project).
_state_cli_args() {
    local cmd="${1:-}" text="" word mode="" auto=0 why="" note=""
    [[ "$cmd" == "memory-sync" || "$cmd" == "handoff" ]] || _state_die "args: memory-sync or handoff"
    text=$(cat || true)
    text="${text//$'\r'/}"
    set -f   # split on whitespace without expanding a bare * in a note
    for word in $text; do
        case "$word" in
            --auto)
                [[ "$auto" == 1 ]] && _state_die "$cmd: --auto given twice"
                auto=1; why="flag";;
            --dream|--ingest|--tidy|--status)
                [[ "$cmd" == "memory-sync" ]] || _state_die "$cmd: unknown flag '$word'"
                [[ -z "$mode" ]] || _state_die "$cmd: --$mode and $word are separate modes"
                mode="${word#--}";;
            -*) _state_die "$cmd: unknown flag '$word'";;
            *)
                [[ "$cmd" == "handoff" ]] || _state_die "$cmd: takes flags only, not '$word'"
                note="${note:+$note }$word";;
        esac
    done
    set +f
    if [[ "$cmd" == "handoff" ]]; then mode="handoff"; else mode="${mode:-standard}"; fi
    if [[ "$auto" == 0 ]] && _state_source_slug_lib; then
        state_project_auto
        [[ "$PROJECT_AUTO" == 1 ]] && { auto=1; why="project"; }
    fi
    printf '%s=%s\n' COMMAND "$cmd" MODE "$mode" AUTO "$auto"
    [[ -n "$why" ]] && printf 'AUTO_WHY=%s\n' "$why"
    [[ "$cmd" == "handoff" ]] && printf 'NOTE=%s\n' "$note"
    return 0
}

# synced:  this session's meta gets synced=true, synced_at=<epoch> and
#          message_count=0, and the slot's .unsynced goes.
# handoff: this session's meta gets handoff_at=<epoch>.
_state_cli_mark() {
    local what="${1:-}" meta now
    shift || true
    [[ "$what" == "synced" || "$what" == "handoff" ]] || _state_die "mark: synced or handoff"
    _state_resolve mark "$@"
    if [[ "$AMBIGUOUS" == 1 ]]; then
        echo "NOT MARKED: two live sessions here and no session id given; pass --session." >&2
        exit 3
    fi
    mkdir -p "$SESSION_DIR"
    meta="$SESSION_DIR/.session-meta"
    now=$(date +%s)
    if [[ "$what" == "synced" ]]; then
        state_set synced true "$meta" && state_set synced_at "$now" "$meta" &&
            state_set message_count 0 "$meta" || _state_die "mark: could not write $meta"
        rm -f "$SLOT_DIR/.unsynced"
    else
        state_set handoff_at "$now" "$meta" || _state_die "mark: could not write $meta"
    fi
    echo "MARKED: $what $meta"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    sub="${1:-}"; shift || true
    case "$sub" in
        paths) _state_cli_paths "$@";;
        args)  _state_cli_args "$@";;
        mark)  _state_cli_mark "$@";;
        *) echo "usage: state-lib.sh {paths|args|mark} ..." >&2; exit 2;;
    esac
fi
