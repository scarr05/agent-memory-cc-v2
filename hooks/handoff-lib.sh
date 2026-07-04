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
    if ! { command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null; }; then
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

# Live context size = the LAST usage-bearing entry's input + cache_read +
# cache_creation. tail -1 of a transcript is often a type:system line with no
# usage, so take the last usage-bearing line within the final 100 (the last
# usage entry is always within a few of the tail). ONE jq spawn per call — this
# runs on the Stop hot path, where the old per-line loop cost up to 100 spawns
# (~30-50ms each on Git Bash). fromjson? skips a malformed line instead of
# failing the whole slurp, preserving the old per-line tolerance.
read_live_tokens() {
    local t="$1"
    [[ -f "$t" ]] || { echo 0; return 0; }
    local u
    u=$(tail -n 100 "$t" | jq -rRs '
        [ split("\n")[] | fromjson? | .message.usage | select(.)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
          | select(. > 0) ] | last // 0' 2>/dev/null || true)
    [[ "$u" =~ ^[0-9]+$ ]] || u=0
    echo "$u"
}

# Print the lines between <!-- HANDOFF:<NAME>:START --> and its matching :END
# marker (exclusive). One shared extractor so no reader depends on the
# human-readable section header. NAME is e.g. NARRATIVE or DONOTREDO.
extract_block() {
    local name="$1" file="$2"
    [[ -f "$file" ]] || return 0
    # sub(/\r$/,"") strips a trailing CR so markers match on CRLF files (a Windows
    # editor, or jq-written content, can introduce CR) regardless of which awk
    # implementation is in use.
    awk -v s="<!-- HANDOFF:${name}:START -->" -v e="<!-- HANDOFF:${name}:END -->" '
        {sub(/\r$/,"")}                         # CRLF tolerance
        $0==s                              {f=1; next}   # enter block on START
        f && $0==e                         {exit}        # normal: stop at END
        f && (/^## / || /^<!-- HANDOFF:/)  {exit}        # fallback: stop at next section/marker
        f                                                # print body lines
    ' "$file"
}

# Extract CC's own compaction summary (isCompactSummary:true). Content may be a
# bare string or a [text] array, under either .message.content or a top-level
# .content (the shape has varied across versions). Capped so a huge summary
# cannot bloat the scratch.
harvest_compact_summary() {
    local t="$1"
    [[ -f "$t" ]] || return 0
    local s
    # `|| true` on the grep: no isCompactSummary line is a legitimate empty result,
    # not an error. Without it the no-match rc=1 trips `set -e`/`pipefail` and the
    # assignment aborts the function mid-way (the caller assembles this inside a
    # brace group under `set -e`, so an abort would orphan a half-written handoff).
    # Neutralise any HANDOFF marker line embedded in the summary before it is placed
    # inside the START/END block. CC's summary is free LLM text (and, for this very
    # project, often quotes these markers); a line equal to ...:END --> would close
    # the block early and a following ...:START --> would re-open it, so extract_block
    # would mis-scope the narrative. Defanging the tokens keeps the summary one block.
    s=$( { grep '"isCompactSummary"' "$t" 2>/dev/null || true; } | tail -1 \
        | jq -r '(.message.content // .content)
                 | if type=="string" then .
                   elif type=="array" then (.[] | if .type=="text" then .text else empty end)
                   else empty end' 2>/dev/null \
        | sed -E 's/<!-- HANDOFF:[A-Za-z0-9_-]+:(START|END) -->/[handoff-marker]/g' \
        | head -c 4000)
    # Guarantee exactly one trailing newline so the START/END markers always sit on
    # their own lines (head -c can truncate mid-line without one); empty => nothing.
    [[ -n "$s" ]] && printf '%s\n' "$s"
    return 0
}

# Assemble the deterministic handoff scratch. For source=handoff the narrative is
# a fill sentinel Claude replaces in-context; for the fallbacks it is filled
# deterministically (CC summary / a clear note) with no LLM call. The narrative
# and do-not-redo blocks are wrapped in START/END comment markers so every reader
# extracts them via extract_block, independent of the human header.
# Args: --transcript T --slug S --source SRC --out OUT
build_deterministic_handoff() {
    local T="" SLUG="" SRC="handoff" OUT=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --transcript) T="$2"; shift 2;;
        --slug) SLUG="$2"; shift 2;;
        --source) SRC="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        *) shift;;
    esac; done
    [[ -n "$OUT" ]] || return 1
    mkdir -p "$(dirname "$OUT")"

    # Stream the window through a temp file (avoids buffering a multi-MB transcript
    # in a shell variable). Every harvest helper below is abort-safe (guarded jq /
    # || true), so build cannot die mid-way and orphan $win; the explicit rm at the
    # end is the single cleanup path.
    local win branch tokens created
    win=$(mktemp)
    window_transcript "$T" > "$win" 2>/dev/null || true
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    tokens=$(read_live_tokens "$T")
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    {
        echo "---"
        # Quote string scalars so a branch with /, :, #, [ or leading * stays valid YAML.
        echo "slug: \"$SLUG\""
        echo "branch: \"$branch\""
        echo "created: \"$created\""
        echo "source: \"$SRC\""
        echo "live_tokens: $tokens"
        echo "consumed: false"
        echo 'supersedes: ""'
        echo "---"
        echo
        echo "# Handoff — $SLUG ($branch)"
        echo
        echo "## Current Work — Narrative"
        echo "<!-- HANDOFF:NARRATIVE:START -->"
        case "$SRC" in
            handoff)          echo "<!-- HANDOFF:NARRATIVE -->";;
            compact-fallback) harvest_compact_summary "$T";;
            *)                echo "Auto-harvested on bare /clear — no manual handoff was armed. Deterministic facts below.";;
        esac
        echo "<!-- HANDOFF:NARRATIVE:END -->"
        echo
        echo "## Do-Not-Redo"
        echo "<!-- HANDOFF:DONOTREDO:START -->"
        if [[ "$SRC" == "handoff" ]]; then echo "<!-- HANDOFF:DONOTREDO -->"; else echo "(none captured)"; fi
        echo "<!-- HANDOFF:DONOTREDO:END -->"
        echo
        echo "## Git State"
        harvest_git
        echo
        echo "## Files Touched (this work unit)"
        harvest_files < "$win" | sed 's/^/- /'
        # ponytail: no Tasks section — native task state survives /clear within the
        # same CLI process (~/.claude/tasks/), the only path that injects a handoff.
        # If a future harness drops that persistence, re-add a harvester reading the
        # entry-level .toolUseResult fields (shapes recorded in
        # docs/superpowers/specs/2026-07-03-review-fixes-design.md).
    } > "$OUT"

    rm -f "$win"
    # The file is always fully assembled above; the trailing harvest helper's exit
    # code (grep/jq return non-zero on a legitimately-empty section, e.g. no tasks)
    # must not leak as the function's status. The unguarded /handoff CLI
    # path runs under `set -e`, where a non-zero return would spuriously fail an
    # otherwise-valid build. Assembly succeeded — return success explicitly.
    return 0
}

# Finalise a handoff: enforce the empty/thin guard for manual handoffs, stamp
# supersedes from any prior consumed file. Prints ARMED:/ABORTED:. Returns
# non-zero on abort. Args: --out OUT --consumed CONSUMED_FILE
finalize_handoff() {
    local OUT="" CONSUMED=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --out) OUT="$2"; shift 2;;
        --consumed) CONSUMED="$2"; shift 2;;
        *) shift;;
    esac; done
    [[ -f "$OUT" ]] || { echo "ABORTED: no handoff file at $OUT"; return 1; }

    # source is a quoted scalar; tr strips the quotes AND any trailing CR (CRLF).
    local src; src=$(sed -n 's/^source: //p' "$OUT" | head -1 | tr -d '\r"')
    if [[ "$src" == "handoff" ]]; then
        # Refuse to arm only if the narrative is still the EXACT fill sentinel
        # (collapsed comment) or too thin — match the full collapsed comment, not a
        # bare "HANDOFF:NARRATIVE" substring, so a real narrative that merely
        # mentions the token still arms.
        local narr
        narr=$(extract_block NARRATIVE "$OUT" | tr -d '[:space:]')
        if [[ "$narr" == *"<!--HANDOFF:NARRATIVE-->"* ]] || [[ "${#narr}" -lt 40 ]]; then
            rm -f "$OUT"
            echo "ABORTED: handoff narrative not filled — not armed."
            return 1
        fi
        # Enforce the block-content constraint the hardened extract_block relies on:
        # a filled body line that begins "## " or "<!-- HANDOFF:" would be read as a
        # section boundary and silently truncate the block. Space-prefix any such
        # BODY line (inside a NARRATIVE/DONOTREDO :START..:END span) so it is no longer
        # line-anchored. The structural :START/:END markers themselves are printed
        # verbatim and never prefixed. Manual-path analogue of the compaction-summary
        # defang at the harvest_compact_summary helper.
        # CR-normalise for matching only (same idiom as extract_block). NOTE: gawk in
        # text mode (this repo's Windows/Git-Bash platform) strips a trailing CR on read,
        # so this pass LF-normalises the file when it runs. That is harmless — every
        # downstream reader is CR-tolerant, and the supersedes awk below already does the
        # same — so byte-for-byte line-ending preservation is not attempted here.
        local tmp; tmp=$(mktemp "${OUT}.XXXXXX")
        awk '
            NR==FNR {
                ln=$0; sub(/\r$/,"",ln)
                if (ln=="<!-- HANDOFF:NARRATIVE:START -->" && nStart==0) nStart=FNR
                else if (ln=="<!-- HANDOFF:DONOTREDO:START -->" && dStart==0) dStart=FNR
                if (dStart==0 && ln=="<!-- HANDOFF:NARRATIVE:END -->") nEnd=FNR
                if (dStart>0  && ln=="<!-- HANDOFF:DONOTREDO:END -->") dEnd=FNR
                next
            }
            {
                raw=$0; ln=$0; sub(/\r$/,"",ln)
                if (FNR==nStart || FNR==dStart || FNR==nEnd || FNR==dEnd) { print raw; next }
                inN = (nStart>0 && nEnd>0 && FNR>nStart && FNR<nEnd)
                inD = (dStart>0 && dEnd>0 && FNR>dStart && FNR<dEnd)
                if ((inN || inD) && (ln ~ /^## / || ln ~ /^<!-- HANDOFF:/)) { print " " raw; next }
                print raw
            }
        ' "$OUT" "$OUT" > "$tmp" && mv "$tmp" "$OUT"
    fi

    if [[ -n "$CONSUMED" && -f "$CONSUMED" ]]; then
        local prior; prior=$(sed -n 's/^created: //p' "$CONSUMED" | head -1 | tr -d '\r"')
        if [[ -n "$prior" ]]; then
            # Rewrite the supersedes line with awk: prior is passed as a literal
            # variable, so no sed regex/replacement metacharacters (&, /, \) in the
            # value can corrupt the output.
            local tmp2; tmp2=$(mktemp "${OUT}.XXXXXX")
            awk -v p="$prior" '!d && /^supersedes:/ {print "supersedes: \"" p "\""; d=1; next} {print}' \
                "$OUT" > "$tmp2" && mv "$tmp2" "$OUT"
        fi
    fi
    echo "ARMED: $OUT"
}

# ---- CLI dispatcher ----
# Lets the /handoff command drive the library: bash handoff-lib.sh <subcmd> [args]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    cmd="${1:-}"; shift || true
    case "$cmd" in
        build)    build_deterministic_handoff "$@";;
        finalize) finalize_handoff "$@";;
        tokens)   read_live_tokens "$@";;
        *) echo "usage: handoff-lib.sh {build|finalize|tokens} ..." >&2; exit 2;;
    esac
fi
