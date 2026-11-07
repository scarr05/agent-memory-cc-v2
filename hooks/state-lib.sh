#!/usr/bin/env bash
# state-lib.sh: where the memory hooks keep each kind of state, so that two
# sessions in one project, a Chief lead's and Sam's, never write the same file.
# Sourced by the hooks after slug-lib.sh (it needs SLUG); run as a script by
# the /memory-sync and /handoff commands.
#
#   $STAGING_DIR/<slug>/                    the project: .corrections-index,
#                                           .vault-cache-*, .last-dream, .dream-pending
#   $STAGING_DIR/<slug>/sessions/<id>/      one session: .session-meta, .transcript-path
#   the slot                                what one line of work hands its next
#     Sam: $STAGING_DIR/<slug>/             session across /clear: handoff.md,
#     a lead (CHIEF_LEAD=1):                handoff.consumed.md, .unsynced, and
#       $STAGING_DIR/<slug>/leads/<worktree>/  .last-session (the newest session id)
#
# Sam's slot is the project folder itself, so relay-baton, /wrap and memory-load
# keep reading <slug>/handoff.md and <slug>/next-prompt.md as before. A lead gets
# a slot per worktree, named as git names the worktree.
#
# The session id is the hook input's `session_id`. Without one (an older Claude
# Code, a hand run) the session's files stay in the slot: the old layout.
# Session ids and worktree names are clamped to [A-Za-z0-9_-]; they become paths.
#
#   bash state-lib.sh paths [--session ID]           KEY=value lines for a command
#   bash state-lib.sh args memory-sync|handoff       arguments on stdin; MODE, AUTO, NOTE
#   bash state-lib.sh mark synced|handoff [--session ID]

_STATE_SID_RE='"session_id"[[:space:]]*:[[:space:]]*"([^"]*)"'

# Sets SESSION_ID from the hook JSON in $1, clamped; empty when there is none. No fork.
state_session_id() {
    SESSION_ID=""
    [[ $1 =~ $_STATE_SID_RE ]] && SESSION_ID="${BASH_REMATCH[1]//[^A-Za-z0-9_-]/}"
    return 0
}

# Sets _found to this worktree's name: git's name for a linked worktree (the
# last part of `.git/worktrees/<name>`), else the checkout's folder name.
_state_worktree() {
    local line="" top=""
    _found=""
    if [[ -f .git ]]; then
        IFS= read -r line <.git || true
        line="${line#gitdir: }"; line="${line%/}"
        [[ "$line" == */worktrees/* ]] && _found="${line##*/}"
    fi
    if [[ -z "$_found" && ! -d .git ]] && command -v git &>/dev/null; then
        line=$(git rev-parse --absolute-git-dir 2>/dev/null || true); line="${line%/}"
        if [[ "$line" == */worktrees/* ]]; then
            _found="${line##*/}"
        else
            top=$(git rev-parse --show-toplevel 2>/dev/null || true)
        fi
    fi
    [[ -z "$_found" ]] && { top="${top:-$PWD}"; top="${top%/}"; _found="${top##*/}"; }
    _found="${_found//[^A-Za-z0-9_-]/}"
    [[ -n "$_found" ]] || _found="unknown"
}

# Sets PROJECT_DIR, SLOT_DIR and SESSION_DIR from SLUG, SESSION_ID and CHIEF_LEAD.
# Forks only for a lead outside its worktree's root.
state_dirs() {
    local _found=""
    PROJECT_DIR="${STAGING_DIR:-$HOME/.claude/memory-staging}/$SLUG"
    SLOT_DIR="$PROJECT_DIR"
    if [[ "${CHIEF_LEAD:-}" == "1" ]]; then
        _state_worktree
        SLOT_DIR="$PROJECT_DIR/leads/$_found"
    fi
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
    local LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
    if [[ -f "$LIBDIR/slug-lib.sh" ]]; then
        # shellcheck source=/dev/null
        source "$LIBDIR/slug-lib.sh"; resolve_slug
    else
        SLUG="unknown"
    fi
    SESSION_ID="${given//[^A-Za-z0-9_-]/}"
    SESSION_SOURCE="given"
    state_dirs
    if [[ -z "$SESSION_ID" ]]; then
        state_last_session
        SESSION_ID="$LAST_SESSION"
        SESSION_SOURCE="none"; [[ -n "$SESSION_ID" ]] && SESSION_SOURCE="pointer"
        state_dirs
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
# AUTO=1 also when CHIEF_LEAD=1: a lead never has anyone to answer a question.
_state_cli_args() {
    local cmd="${1:-}" text="" word mode="" auto=0 why="" note=() words=()
    [[ "$cmd" == "memory-sync" || "$cmd" == "handoff" ]] || _state_die "args: memory-sync or handoff"
    text=$(cat || true)
    text="${text//$'\r'/}"
    read -r -d '' -a words <<<"$text" || true
    for word in "${words[@]}"; do
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
                note+=("$word");;
        esac
    done
    if [[ "$cmd" == "handoff" ]]; then mode="handoff"; else mode="${mode:-standard}"; fi
    [[ "$auto" == 0 && "${CHIEF_LEAD:-}" == "1" ]] && { auto=1; why="lead"; }
    printf '%s=%s\n' COMMAND "$cmd" MODE "$mode" AUTO "$auto"
    [[ -n "$why" ]] && printf 'AUTO_WHY=%s\n' "$why"
    [[ "$cmd" == "handoff" ]] && printf 'NOTE=%s\n' "${note[*]}"
    return 0
}

# synced:  this session's meta gets synced=true, synced_at=<epoch> and
#          message_count=0, and the slot's .unsynced goes.
# handoff: this session's meta gets handoff_at=<epoch>.
# Chief compares these times with a ticket's start and a lead's last turn.
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
