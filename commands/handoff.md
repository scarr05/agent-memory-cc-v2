---
description: "Capture the current work unit into a handoff scratch file, then arm it for pickup. Run /clear afterwards to continue in a fresh session."
allowed-tools:
  - "Bash"
  - "Read"
  - "Edit"
  - "Write"
---

# /handoff

Capture where we are right now into a single-slot scratch file so a fresh session can pick it up after `/clear`. $ARGUMENTS

## Step 1: Resolve slug, transcript, and library

```bash
# Slug: CLAUDE.md metadata -> state file -> git remote -> dir name
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md 2>/dev/null | head -1)
[[ -z "$SLUG" ]] && SLUG=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
[[ -z "$SLUG" ]] && SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]')
[[ -z "$SLUG" ]] && SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g'); [[ -z "$SLUG" ]] && SLUG="unknown"

# Library path: plugin root if present, else manual-install location
LIB="$HOME/.claude/hooks/handoff-lib.sh"
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-lib.sh" ]] && LIB="${CLAUDE_PLUGIN_ROOT}/hooks/handoff-lib.sh"

STAGING="$HOME/.claude/memory-staging/$SLUG"
HANDOFF="$STAGING/handoff.md"
CONSUMED="$STAGING/handoff.consumed.md"
mkdir -p "$STAGING"

# Transcript resolution. CLAUDE_SESSION_ID is NOT exported into the command's Bash
# env (confirmed), and the .transcript-path breadcrumb is shared per-slug, so it
# can point at a CONCURRENT same-repo session that wrote it more recently.
# Therefore the ambiguity guard runs FIRST as a gate: if >1 transcript was modified
# in the last 2 minutes, refuse — never let the breadcrumb (or newest-wins) silently
# pick the wrong live session. Only when unambiguous do we choose a path:
#   1. .transcript-path breadcrumb (authoritative for a single active session)
#   2. $CLAUDE_SESSION_ID-derived path (only if the env var is ever populated)
#   3. newest *.jsonl
# Claude Code encodes the projects dir from the OS-native path. On Windows git bash
# $PWD is POSIX-form (/c/Users/...), which mis-encodes (-c-Users-... vs CC's
# C--Users-...) and breaks PROJDIR — defeating both the newest-wins fallback AND the
# ambiguity gate. cygpath -w yields the native path on Windows; on macOS/Linux cygpath
# is absent and the fallback keeps $PWD, which CC already encodes directly.
ENCODED=$(printf '%s' "$(cygpath -w "$PWD" 2>/dev/null || printf '%s' "$PWD")" | sed 's#[/\\:]#-#g')
PROJDIR="$HOME/.claude/projects/$ENCODED"
TRANSCRIPT=""; AMBIGUOUS=0
RECENT=$(find "$PROJDIR" -maxdepth 1 -name '*.jsonl' -mmin -2 2>/dev/null | wc -l | tr -d ' ')
if [[ "${RECENT:-0}" -gt 1 ]]; then
    AMBIGUOUS=1
elif [[ -f "$STAGING/.transcript-path" ]] && IFS= read -r _tp < "$STAGING/.transcript-path" && [[ -f "$_tp" ]]; then
    TRANSCRIPT="$_tp"
elif [[ -n "${CLAUDE_SESSION_ID:-}" && -f "$PROJDIR/$CLAUDE_SESSION_ID.jsonl" ]]; then
    TRANSCRIPT="$PROJDIR/$CLAUDE_SESSION_ID.jsonl"
else
    TRANSCRIPT=$(ls -t "$PROJDIR"/*.jsonl 2>/dev/null | head -1 || true)
fi

echo "SLUG=$SLUG"; echo "LIB=$LIB"; echo "TRANSCRIPT=${TRANSCRIPT:-<none>}"; echo "HANDOFF=$HANDOFF"; echo "AMBIGUOUS=$AMBIGUOUS"
```

If `AMBIGUOUS=1`, two or more sessions are active in this repo and newest-wins would be unsafe — tell the user to disambiguate (close the other session, or pass the transcript path) and stop. If `TRANSCRIPT` is `<none>` for any other reason, tell the user the transcript could not be located and stop — do not write a blind handoff.

## Step 2: Build the deterministic skeleton

```bash
bash "$LIB" build --transcript "$TRANSCRIPT" --slug "$SLUG" --source handoff --out "$HANDOFF"
cat "$HANDOFF"
```

## Step 3: Fill the narrative from your in-context knowledge

You have the live conversation in context — do NOT re-read the transcript. Use the Edit tool on the handoff file to replace the two **fill sentinels**. Replace ONLY the collapsed sentinel line; never touch the surrounding `<!-- HANDOFF:NARRATIVE:START -->` / `:END` (or `:DONOTREDO:` `:START`/`:END`) markers — they delimit the block for every reader.

1. Replace `<!-- HANDOFF:NARRATIVE -->` with 3–5 sentences: what we are mid-way through **right now**, why, and the **exact next action** a fresh agent should take first — file + line + intent (e.g. "Edit `hooks/session-start.sh:165` to add the clear-injection branch").
2. Replace `<!-- HANDOFF:DONOTREDO -->` with the dead ends already ruled out this session, so the fresh agent does not repeat them. If none, write `- None.`

Keep it tight, and keep the body free of lines that begin `## ` or `<!-- HANDOFF:` — those read as section boundaries. (Finalise defangs any that slip through by space-prefixing them, so a slip degrades gracefully rather than truncating the block.) The deterministic sections already carry git state, touched files, and TODOs — the narrative is only the irreducible "what/why/next".

## Step 4: Finalise (thin-guard + supersedes)

```bash
bash "$LIB" finalize --out "$HANDOFF" --consumed "$CONSUMED"
```

If the output starts with `ABORTED`, the narrative was left unfilled — go back to Step 3 and fill it, then re-run finalise. Do not tell the user it is armed until finalise prints `ARMED`.

## Step 5: Tell the user

On `ARMED`, tell the user:

> Handoff armed at `~/.claude/memory-staging/<slug>/handoff.md`. Run **`/clear`** now — the fresh session will auto-load it. (`/clear` is a CLI keystroke; I cannot run it for you.)

Do not run `/memory-sync` — handoff and sync are deliberately separate.
