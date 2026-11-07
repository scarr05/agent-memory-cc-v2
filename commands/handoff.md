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

## Auto mode

`/handoff --auto`, and every `/handoff` in a Chief lead (`CHIEF_LEAD=1`), asks nothing and never stops to wait: Chief sends it and waits for the turn to end. Step 1 prints `AUTO=1` when it applies; the parse is `state-lib.sh args`, which refuses any flag it does not know. Under `AUTO=1`:

| Where the interactive run stops or asks | What auto does instead |
|---|---|
| Step 1: `AMBIGUOUS=1` (two live sessions, no session id) | Build without the transcript (`--transcript ""`) and say so in the narrative's first sentence |
| Step 1: `TRANSCRIPT` is `<none>` | The same: build without it |
| Step 4: `ABORTED` (narrative too thin) | Finalise has deleted the thin file: run Step 2 again, write a fuller narrative, finalise again; never hand back to the user |
| Step 5: the message to the user | One line, `ARMED: <path>`, and nothing after it |

Anything after `--auto` is a note: fold it into the narrative.

## Step 1: Resolve mode, slug, session and library

```bash
# Libraries: plugin root if present, else the manual-install location.
HOOKS="$HOME/.claude/hooks"
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]] && HOOKS="${CLAUDE_PLUGIN_ROOT}/hooks"
LIB="$HOOKS/handoff-lib.sh"

# Mode: AUTO=1 for --auto or in a Chief lead. The arguments go in through a quoted
# heredoc, so quotes in a note cannot break the shell; an unknown flag stops here.
bash "$HOOKS/state-lib.sh" args handoff <<'HANDOFF_ARGS' || exit 2
$ARGUMENTS
HANDOFF_ARGS

# Paths (state-lib.sh): the slug, as the hooks resolve it (a linked worktree lands
# under its main checkout's slug); the slot this session hands off through (Sam's
# is <slug>/, a lead's is <slug>/leads/<worktree>/, so neither overwrites the
# other); and this session's own folder. Claude Code substitutes this session's id
# below, so the transcript is this session's even with others live in the repo.
# A Claude Code that does not substitute leaves it empty: then the slot's newest
# session stands in (SESSION_SOURCE=pointer) and AMBIGUOUS=1 flags a second
# transcript in this repo written in the last two minutes.
PATHS=$(bash "$HOOKS/state-lib.sh" paths --session "${CLAUDE_SESSION_ID}")
printf '%s\n' "$PATHS"
SLOT=$(sed -n 's/^SLOT_DIR=//p' <<<"$PATHS")
mkdir -p "$SLOT"
echo "HOOKS=$HOOKS"; echo "LIB=$LIB"; echo "HANDOFF=$SLOT/handoff.md"; echo "CONSUMED=$SLOT/handoff.consumed.md"
```

If `AUTO=0`: when `AMBIGUOUS=1`, two or more sessions are active in this repo and the newest may not be this one; tell the user to disambiguate (close the other session, or pass the transcript path) and stop. If `TRANSCRIPT` is `<none>` for any other reason, tell the user the transcript could not be located and stop; do not write a blind handoff. If `AUTO=1`, follow the Auto mode table instead.

## Step 2: Build the deterministic skeleton

Use the values Step 1 printed. Under `AUTO=1` with no usable transcript, pass `--transcript ""`.

```bash
bash "$LIB" build --transcript "$TRANSCRIPT" --slug "$SLUG" --source handoff --out "$HANDOFF"
cat "$HANDOFF"
```

## Step 3: Fill the narrative from your in-context knowledge

You have the live conversation in context — do NOT re-read the transcript. Use the Edit tool on the handoff file to replace the two **fill sentinels**. Replace ONLY the collapsed sentinel line; never touch the surrounding `<!-- HANDOFF:NARRATIVE:START -->` / `:END` (or `:DONOTREDO:` `:START`/`:END`) markers — they delimit the block for every reader.

1. Replace `<!-- HANDOFF:NARRATIVE -->` with 3–5 sentences: what we are mid-way through **right now**, why, and the **exact next action** a fresh agent should take first — file + line + intent (e.g. "Edit `hooks/session-start.sh:165` to add the clear-injection branch").
2. Replace `<!-- HANDOFF:DONOTREDO -->` with the dead ends already ruled out this session, so the fresh agent does not repeat them. If none, write `- None.`

Keep it tight, and keep the body free of lines that begin `## ` or `<!-- HANDOFF:` — those read as section boundaries. (Finalise defangs any that slip through by space-prefixing them, so a slip degrades gracefully rather than truncating the block.) The deterministic sections already carry git state, touched files, and TODOs — the narrative is only the irreducible "what/why/next".

## Step 4: Finalise (thin-guard + supersedes) and mark the session

```bash
bash "$LIB" finalize --out "$HANDOFF" --consumed "$CONSUMED" &&
    bash "$HOOKS/state-lib.sh" mark handoff --session "${CLAUDE_SESSION_ID}"
```

If the output starts with `ABORTED`, the narrative was left unfilled; go back to Step 3 and fill it, then re-run finalise. Do not tell the user it is armed until finalise prints `ARMED`. `MARKED: handoff` records `handoff_at` in this session's `.session-meta`, the marker `chief recycle` waits for.

## Step 5: Tell the user

Under `AUTO=1`, print `ARMED: <path>` and end the turn. Otherwise, on `ARMED`, tell the user:

> Handoff armed at `<HANDOFF>`. Run **`/clear`** now — the fresh session will auto-load it. (`/clear` is a CLI keystroke; I cannot run it for you.)

Do not run `/memory-sync` — handoff and sync are deliberately separate.
