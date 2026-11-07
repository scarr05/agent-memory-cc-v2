#!/usr/bin/env bash
# slug-lib.sh — the one memory-slug lookup, sourced by the hooks and called by
# the commands. relay-baton's TypeScript `projectSlug` reads steps 1, 2 and 4
# only. That's enough: session-start.sh writes whatever this resolves (settings,
# remote and all) into the state file, which relay-baton reads at step 2.
#
#   source "$LIBDIR/slug-lib.sh"; resolve_slug    # sets SLUG and _DETECTED_VIA, no subshell
#   bash slug-lib.sh                              # prints the slug (for commands)
#
# Order, first hit wins:
#   1. .claude/CLAUDE.md `memory:project-slug=` marker      claude-md-metadata
#   2. .claude/memory-state.json "slug"                      memory-state-file
#   3. .claude/settings.json .memory.projectSlug             settings-json
#   4. the main checkout's marker, then its state file       main-checkout
#      (a linked worktree with neither file of its own)
#   5. the origin remote's repo name                         git-remote
#   6. package.json / pyproject.toml name                    package-json / pyproject-toml
#   7. the main checkout's directory name, in git           git-toplevel
#      (a session in `noted/src` or a linked worktree is `noted`), else
#      the directory name                                    directory-name
#
# SLUG_IGNORE_STATE=1 skips step 2. session-start.sh sets it: it writes the
# state file, and reading its own earlier answer back would pin a wrong slug
# (`src`, an agent worktree's ID) for good. The per-turn hooks still read it.
#
# The Stop and UserPromptSubmit hooks run this on every turn, and session-start.sh
# writes the state file in every directory it starts in, so steps 1 and 2 almost
# always answer. They read the file with builtins: no fork. git runs only past
# them, and only when the worktree's own .git file doesn't name the main checkout.
# SLUG is clamped to [a-z0-9-] ("unknown" when nothing is left), because it
# becomes part of rm/mkdir paths and Obsidian CLI arguments.

_SLUG_MARKER_RE='memory:project-slug=([a-z0-9-]+)'
_SLUG_STATE_RE='"slug": *"([^"]*)"'

# Sets _found to the first group of regex $2 in file $1; false when there is none.
_slug_read() {
    local text=""
    _found=""
    [[ -f "$1" ]] || return 1
    IFS= read -r -d '' text <"$1" || true
    [[ $text =~ $2 ]] && _found="${BASH_REMATCH[1]}"
    [[ -n "$_found" ]]
}

# Lowercase, everything outside [a-z0-9-] as `-`.
_slugify() {
    if (( BASH_VERSINFO[0] >= 4 )); then
        _found="${1,,}"; _found="${_found//[^a-z0-9-]/-}"
    else
        _found=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    fi
}

# The main checkout of the linked worktree we're in; empty in a main checkout or outside git.
_slug_main_checkout() {
    local gitfile=""
    _found=""
    if [[ -f .git ]]; then
        # A linked worktree's root: `gitdir: <main>/.git/worktrees/<name>`.
        IFS= read -r gitfile <.git || true
        gitfile="${gitfile#gitdir: }"
        [[ "$gitfile" == */.git/worktrees/* ]] && { _found="${gitfile%/.git/worktrees/*}"; return 0; }
    elif [[ -d .git ]]; then
        return 0 # the main checkout itself: steps 1 and 2 already read its files
    fi
    # A subdirectory, or a layout the .git file doesn't spell out: ask git.
    command -v git &>/dev/null || return 0
    _found=$(git -c core.fsmonitor=false worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)
    [[ "$_found" == "$PWD" ]] && _found=""
    return 0
}

_hit() { SLUG="$_found"; _DETECTED_VIA="$1"; }

# Sets SLUG (unclamped) and _DETECTED_VIA in the caller's shell.
detect_slug_raw() {
    local _found="" main remote
    SLUG=""; _DETECTED_VIA=""

    _slug_read .claude/CLAUDE.md "$_SLUG_MARKER_RE" && { _hit claude-md-metadata; return 0; }
    [[ -z "${SLUG_IGNORE_STATE:-}" ]] && _slug_read .claude/memory-state.json "$_SLUG_STATE_RE" && { _hit memory-state-file; return 0; }

    if [[ -f .claude/settings.json ]] && command -v jq &>/dev/null; then
        _found=$(jq -r '.memory.projectSlug // empty' .claude/settings.json 2>/dev/null || true)
        [[ -n "$_found" ]] && { _hit settings-json; return 0; }
    fi

    _slug_main_checkout; main="$_found"
    if [[ -n "$main" ]]; then
        { _slug_read "$main/.claude/CLAUDE.md" "$_SLUG_MARKER_RE" || _slug_read "$main/.claude/memory-state.json" "$_SLUG_STATE_RE"; } &&
            { _hit main-checkout; return 0; }
    fi

    if command -v git &>/dev/null; then
        remote=$(git remote get-url origin 2>/dev/null || true)
        remote="${remote%/}"; remote="${remote%.git}"; remote="${remote##*[:/]}"
        if [[ -n "$remote" ]]; then
            _slugify "$remote"; _hit git-remote; return 0
        fi
    fi

    if [[ -f package.json ]] && command -v jq &>/dev/null; then
        _found=$(jq -r '.name // empty' package.json 2>/dev/null || true)
        [[ -n "$_found" ]] && { _slugify "$_found"; _hit package-json; return 0; }
    fi

    if _slug_read pyproject.toml 'name = "([^"]*)"'; then
        _slugify "$_found"; _hit pyproject-toml; return 0
    fi

    if [[ -n "$main" ]]; then
        main="${main%/}"; main="${main##*/}"
        _slugify "${main%.git}"; _hit git-toplevel   # .git: a bare main repo
    else
        _slugify "${PWD##*/}"; _hit directory-name
    fi
}

# Sets SLUG, clamped to [a-z0-9-] ("unknown" when nothing is left), and _DETECTED_VIA.
resolve_slug() {
    detect_slug_raw
    if (( BASH_VERSINFO[0] >= 4 )); then
        SLUG="${SLUG,,}"; SLUG="${SLUG//[^a-z0-9-]/}"   # builtins: no forks on the hot path
    else
        SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
    fi
    [[ -z "$SLUG" ]] && SLUG="unknown"
    return 0
}

# Run as a script: print the slug, for the commands.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    resolve_slug
    echo "$SLUG"
fi
