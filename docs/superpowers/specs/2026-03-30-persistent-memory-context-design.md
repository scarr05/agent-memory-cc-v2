# Persistent Memory Context Across Sessions

**Date:** 2026-03-30
**Status:** Draft
**Branch:** `dev/memory-improvements`

## Problem

The memory system's context injection is ephemeral. SessionStart fires once, injects the project slug, pending checkpoints, and dream status into the conversation — then that context is lost on compaction or `/clear`. After loss:

- Claude loses awareness of the memory system entirely (doesn't search Obsidian, doesn't process checkpoints)
- Claude may detect the wrong slug (picks up worktree paths, wrong sub-repo in multi-repo projects)
- The user has to re-explain or re-run `/memory-init` despite it already having been run

Secondary bug: `grep -oP` (PCRE lookbehind) fails silently on Windows Git Bash due to locale issues, meaning Priority 1 slug detection from `.claude/CLAUDE.md` metadata never works. All projects fall through to git remote or directory name detection.

## Solution

Three complementary recovery mechanisms:

1. **Persistent state file** — ground truth that survives compaction and clear
2. **PreCompact re-injection** — automatic context recovery after compaction
3. **`/memory-load` update** — manual recovery after `/clear`, reads state file

Plus a portability fix for all `grep -oP` usage across hook scripts.

## Design

### 1. Persistent State File (`.claude/memory-state.json`)

Written by SessionStart after slug detection. Read by PreCompact and `/memory-load`.

```json
{
  "slug": "wafr-discovery",
  "area": "AI",
  "sessionPath": "5 Agent Memory/sessions/by-project/wafr-discovery/",
  "detectedVia": "claude-md-metadata",
  "pendingCheckpoints": [
    "/c/Users/user/.claude/memory-staging/wafr-discovery/checkpoint-2026-03-29T20-33-37Z.md"
  ],
  "dreamPending": false,
  "lastUpdated": "2026-03-30T10:00:00Z"
}
```

**Location:** `.claude/memory-state.json` (already gitignored via `.claude/`).

**Lifecycle:**
- Created/overwritten by SessionStart on every new session
- Read by PreCompact to re-inject context
- Read by `/memory-load` as fast path
- Updated by PreCompact when it creates a new checkpoint (appends to `pendingCheckpoints`)
- `detectedVia` field records which detection method produced the slug (for debugging)

**Why JSON:** hooks already depend on `jq` for settings.json parsing. Structured format avoids fragile sed/grep parsing of the state file itself.

### 2. PreCompact Hook Changes

Currently `pre-compact.sh` creates a checkpoint stub and outputs a single-line systemMessage telling Claude to fill it in.

**Changes:**

1. After creating the checkpoint, read `.claude/memory-state.json`
2. Update `pendingCheckpoints` in the state file to include the new checkpoint
3. Re-inject the full memory context block (same format as SessionStart) as `systemMessage`
4. Append the existing checkpoint instruction to the context block

The systemMessage output becomes the combined memory context + checkpoint instruction, so Claude starts post-compaction with full awareness.

**Fallback:** If `.claude/memory-state.json` doesn't exist (old install, first run), fall back to current behaviour — just the checkpoint message.

**Slug detection in PreCompact:** Currently duplicates the full detection chain. After this change, PreCompact reads the slug from `memory-state.json` first, only falling back to detection if the file is missing. This is faster and consistent.

### 3. `/memory-load` Command Update

The existing command focuses on loading Obsidian context (sessions, learnings, working files). It needs a new **preamble step** that restores the hook-level context that would normally come from SessionStart.

**New Step 0 (before current Step 1):**

1. Check for `.claude/memory-state.json`
   - If exists: read it, use slug/area/sessionPath from file
   - If missing: detect slug using same logic as SessionStart, warn that state file is missing
2. Scan staging directory for pending checkpoints (verify against state file, pick up any new ones)
3. Check dream-pending flag
4. Output the same context block format as SessionStart

The rest of the command (Steps 1-7: project index, sessions, learnings, working files, summary) continues as before, now with the correct slug guaranteed.

**CLAUDE.md instruction addition:** The global CLAUDE.md template gets a line:

> If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.

### 4. `grep -oP` Portability Fix

Replace all PCRE lookbehind patterns with portable `sed` equivalents. Affected locations:

| File | Pattern | Replacement |
|------|---------|-------------|
| `session-start.sh:17` | `grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*'` | `sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' \| head -1` |
| `session-start.sh:76` | `grep -oP '(?<=memory:area=)[^\s]+'` | `sed -n 's/.*memory:area=\([^ ]*\).*/\1/p' \| head -1` |
| `pre-compact.sh:15` | `grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*'` | Same as above |
| `pre-compact.sh:42` | `grep -oP '(?<=message_count=)\d+'` | `sed -n 's/.*message_count=\([0-9]*\).*/\1/p' \| head -1` |
| `pre-compact.sh:43` | `grep -oP '(?<=session_start=).*'` | `sed -n 's/.*session_start=\(.*\)/\1/p' \| head -1` |
| `stop-memory.sh:14` | `grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*'` | Same as session-start |
| `stop-memory.sh:37` | `grep -oP '(?<=message_count=)\d+'` | Same as pre-compact |
| `stop-memory.sh:49` | `grep -oP '(?<=session_start=).*'` | Same as pre-compact |

All `grep -q` (non-PCRE) calls remain unchanged — they work fine.

## File Changes Summary

| File | Change Type | Description |
|------|-------------|-------------|
| `hooks/session-start.sh` | Modify | Write `memory-state.json` after detection; fix `grep -oP`; add `detectedVia` tracking |
| `hooks/pre-compact.sh` | Modify | Read state file; update pending checkpoints; re-inject full context; fix `grep -oP` |
| `hooks/stop-memory.sh` | Modify | Read slug from state file first; fix `grep -oP` |
| `commands/memory-load.md` | Modify | Add Step 0 preamble for state file recovery |
| `config/global-claude-md-v2.md` | Modify | Add instruction about `/memory-load` after clear |
| `commands/memory-init.md` | Modify | Add instruction for Claude to write `memory-state.json` after slug setup |

No new files beyond `.claude/memory-state.json` which is generated at runtime.

## Edge Cases

**Multi-repo projects (float-platform):** The state file is per-working-directory (`.claude/memory-state.json` is relative to where Claude Code was opened). If the user opens Claude Code in different sub-repos, each gets its own state file with the correct slug. This is already how `.claude/CLAUDE.md` works.

**Worktree agents:** Worktrees get their own `.claude/` directory. The state file written in a worktree won't interfere with the main working copy. When the worktree is cleaned up, its state file goes with it.

**State file out of date:** If a user runs `/memory-init` mid-session (changing the slug), SessionStart won't re-fire to update the state file. `/memory-init` must update `.claude/memory-state.json` as part of its setup — this is an additional change to `commands/memory-init.md` (add an instruction for Claude to write the state file after setting the slug).

**Missing jq:** The state file is JSON, requiring `jq` to parse. All hooks already use `jq` for `settings.json`, so this is not a new dependency. If `jq` is missing, fall back to grep-based extraction from the JSON (fragile but functional).

## Non-Goals

- Automatic `/clear` detection — Claude Code doesn't fire a hook on `/clear`, so there's no way to auto-re-inject. The CLAUDE.md instruction + `/memory-load` is the fallback.
- Slug versioning or migration — if a slug changes, the user re-runs `/memory-init`.
- Multi-project sessions — each Claude Code instance maps to one project. No multiplexing.
