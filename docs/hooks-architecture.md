# Hooks-Enforced Memory System

## The Problem with CLAUDE.md-Only Enforcement

CLAUDE.md instructions are advisory — the model can ignore them, especially after compaction or in long sessions where context drift kicks in. Hooks are deterministic. They fire every time, regardless of what the model decides to do.

## Hook Strategy

Six hooks enforce the memory system programmatically:

| Hook Event | Purpose | Type |
|-----------|---------|------|
| **SessionStart** | Detect project, inject context pointer via `additionalContext`, flag unsynced sessions, run the post-compaction handoff | command |
| **PreToolUse** (Read) | Deduplicate source-code re-reads (read-once) | command |
| **PreCompact** | Clear the read-once cache before context shrinks (checkpoint stubs retired) | command |
| **Stop** | Track message count, nudge for /memory-sync via `systemMessage` if significant | command |
| **SessionEnd** | Flag a real-length session that ended without /memory-sync | command |
| **UserPromptSubmit** | Surface a logged correction when the prompt touches its topic | command |

Plus one enhanced slash command:

| Command | Purpose |
|---------|---------|
| **`/memory-init`** | /init on steroids — detects project, creates everything, loads context |

---

## Project Detection Logic

The project slug drives everything — where sessions get written, where context gets loaded from, what folder exists in Obsidian. Rather than hardcoding it, we derive it automatically and store it in the project CLAUDE.md.

### Detection Priority

```
1. .claude/CLAUDE.md → look for `project-slug:` in frontmatter/content
2. .claude/settings.json → check for custom memory.projectSlug field
3. git remote → extract repo name from origin URL
4. package.json / pyproject.toml / Cargo.toml → extract project name
5. Directory name → basename of $PWD
6. Fallback → "unknown-project" (prompt user to set it)
```

### Where the Slug Lives

Once detected or set via `/memory-init`, the slug is stored in `.claude/CLAUDE.md` in a parseable format:

```markdown
<!-- memory:project-slug=my-project -->
<!-- memory:area=AWS -->
<!-- memory:vault-path=1 Projects/Personal/my-project -->
```

HTML comments because they're invisible in rendered markdown but trivially parseable by hooks via grep.

---

## Hook 1: SessionStart

**File:** `~/.claude/hooks/session-start.sh`

Fires every time Claude Code starts. Deterministic context injection.

### What It Does

1. **Detect project slug** — reads `.claude/CLAUDE.md` for the `memory:project-slug` comment. If missing, falls back through the detection priority chain. The slug is charset-clamped before it touches any path.
2. **Validate Obsidian structure** — checks if `5 Agent Memory/sessions/by-project/<slug>/` exists (via file check if vault is locally synced).
3. **Inject context pointer** — outputs `hookSpecificOutput.additionalContext` telling Claude where to find memory and what slug to use (or plain stdout when `MEMORY_HOOK_PLAINTEXT=1`).
4. **Flag pending work** — surfaces a pending handoff (`handoff.md`) and the `.unsynced` marker SessionEnd leaves when a prior session was never synced.
5. **Flag if uninitialised** — if no slug found, context tells Claude to suggest running `/memory-init`.
6. **Handle the compaction restart** — when `source=compact`, harvests the compaction summary into a handoff scratch file, preserving the session counter and start time across compaction. (No stub-filling or blackbox direction — the handoff is injected directly.)

### SessionStart vs UserPromptSubmit

SessionStart fires once and carries the bulk context load — too expensive to repeat per message. UserPromptSubmit fires on every prompt, so it does the one cheap, high-value thing that must be just-in-time: surfacing a correction the moment the prompt touches its topic (Hook 5). It exits before reading stdin in the common no-corrections case to stay under its 100ms budget. The heavy Obsidian reads still happen via MCP when Claude acts on the SessionStart pointer.

---

## Hook 2: PreCompact

**File:** `~/.claude/hooks/pre-compact.sh`

Fires before context compaction. Checkpoint stubs are retired — the hook now does one thing only: clear the read-once cache so the compacted session starts with a clean slate.

### What It Does

1. **Clear the read-once cache** — removes the per-session dedup index (keyed on `CLAUDE_SESSION_ID`) so the fresh compacted session can re-read files freely
2. **Inject nothing** — Claude can't act mid-compaction, so the hook emits no output. The continuation path is the handoff workflow: SessionStart with `source=compact` harvests the compaction summary into a handoff scratch file and injects it as `additionalContext` so the next session resumes automatically.

### Compaction as a Dormant Safety Net

Compaction is no longer the primary large-session path. The preferred workflow is `/handoff` → `/clear` (explicit, user-controlled) long before compaction would fire. Compaction stays enabled as a last-resort catch, but its hook no longer writes stubs or directs any agent to fill them.

### The Handoff Scratch Lifecycle

```
/handoff writes ~/.claude/memory-staging/<slug>/handoff.md
    (fallback: session-end.sh harvests on a clear with no handoff,
     or session-start.sh harvests the compaction summary on source=compact)
  ↓
SessionStart(source=clear) injects handoff.md as additionalContext
  ↓
SessionStart renames it handoff.consumed.md
  ↓
/memory-sync deletes both handoff.md and handoff.consumed.md
```

A single-slot scratch file — only one handoff at a time per project.

### hooks/handoff-lib.sh — Shared Library

`hooks/handoff-lib.sh` is a bash library that holds the handoff read/write functions used by multiple hooks. It is **not** registered as a hook event; it is sourced defensively by `session-start.sh` and `session-end.sh`:

```bash
# Sourced at the top of each hook that needs handoff functions:
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/handoff-lib.sh" 2>/dev/null || true
```

The CLI dispatcher inside `handoff-lib.sh` is guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so sourcing it never runs any code — only function definitions are loaded.

---

## Hook 3: Stop

**File:** `~/.claude/hooks/stop-memory.sh`

Fires when Claude finishes responding. Lightweight session tracking.

### What It Does

1. **Increment message counter** — one awk pass updates the count and last-activity time in `~/.claude/memory-staging/<slug>/.session-meta`, deriving duration from the `session_start_epoch` SessionStart wrote.
2. **Check thresholds** — fires at 15 and 30 messages (30 checked first, with independent sent-flags so a session that jumps past 15 still nudges), or after 45+ minutes; also checks the 24-hour dream timer.
3. **Emit nudge** — via `systemMessage` (shown to the user, not Claude): "This session looks substantial. Consider running /memory-sync before ending."

### Why Not Auto-Write Sessions on Stop

The Stop hook fires on EVERY response, not just session end. Auto-writing would create noise. Instead, it tracks and nudges. The human decides when to sync.

---

## Hook 4: SessionEnd

**File:** `~/.claude/hooks/session-end.sh`

Fires when the session ends (close, `exit`, `logout`, or `/clear`). It catches the case the Stop nudge can't: a substantial session that simply ends without `/memory-sync`.

### What It Does

1. **Read the end reason** from stdin. A `clear` is a deliberate wipe — skip it.
2. **Detect and clamp the slug**, then read `.session-meta`.
3. **Flag if unsynced** — if the session ran to real length (≥10 messages) and `.session-meta` has no `synced=true`, write an `.unsynced` marker (end time + message count) to staging.

It emits no stdout and always exits 0 — SessionEnd can't block or inject. The next SessionStart surfaces the marker; `/memory-sync` owns removing it.

### Why a Deterministic Flag, Not the Heuristic

The old "previous session had N messages" hint was a guess. SessionEnd turns it into a fact: the marker means *this session ended unsynced*. SessionStart prefers the marker and falls back to the message-count heuristic only when it's absent — which still covers a crashed or killed session that never fired SessionEnd.

---

## Hook 5: UserPromptSubmit

**File:** `~/.claude/hooks/prompt-corrections.sh`

Fires on every prompt. Surfaces a logged correction the moment the prompt touches its topic, so Claude loads it *before* acting rather than repeating a known mistake.

### What It Does

1. **Detect and clamp the slug.**
2. **Fast exit** — if there's no `.corrections-index` for the project (the common case), exit before reading stdin or spawning anything. This keeps the per-prompt cost under the 100ms budget.
3. **Match** — otherwise, lowercase the prompt and literal-substring-match it against the index keys (built by SessionStart from correction-note titles).
4. **Inject a pointer** — on a hit, emit `additionalContext`: "Correction(s) on record for: X. Load the details via memberberry before proceeding." (`MEMORY_HOOK_PLAINTEXT=1` falls back to plain stdout.)

### Why Just-in-Time

A correction loaded at SessionStart competes with everything else for attention and may be long-forgotten by the time it matters. Matching it to the live prompt surfaces it exactly when it's relevant, at the cost of one cheap string match per prompt.

---

## /memory-init — The Init on Steroids

This replaces the standard `/init` workflow for memory-enabled projects. It's a slash command (not a hook) because it needs MCP-Obsidian access and interactive confirmation.

### Detection Phase

```
1. Check git remote origin → extract repo name
   Example: git@github.com:user/my-project.git → "my-project"

2. Check package.json / pyproject.toml / Cargo.toml for project name

3. Check existing .claude/CLAUDE.md for prior slug

4. Check directory name as fallback

5. Present detected values to user for confirmation:
   "Detected project: my-project
    Area: AWS (inferred from repo topics / CLAUDE.md content)
    Vault path: 1 Projects/Personal/my-project
    
    Confirm or adjust?"
```

### Setup Phase (after confirmation)

1. **Create/update `.claude/CLAUDE.md`** with:
   - Project overview (from README.md if present)
   - Tech stack (from package.json, requirements.txt, etc.)
   - Build/test commands (detected or prompted)
   - Memory metadata comments:
     ```
     <!-- memory:project-slug=my-project -->
     <!-- memory:area=AWS -->
     <!-- memory:vault-path=1 Projects/Personal/my-project -->
     ```

2. **Create Obsidian structure** via MCP-Obsidian:
   ```
   5 Agent Memory/sessions/by-project/my-project/  (if not exists)
   ```

3. **Update project index** — add/update row in `5 Agent Memory/project-index.md`

4. **Load existing context** — search for prior sessions on this project
   ```
   search_notes(query="my-project", searchContent=true)
   ```
   Present summary of what was found.

5. **Check for a pending handoff** — look in `~/.claude/memory-staging/<slug>/` for a `handoff.md` or `handoff.consumed.md` from a prior session that was not yet cleaned up by `/memory-sync`

6. **Ingest auto-memory** — if `~/.claude/projects/<project>/memory/MEMORY.md` exists, offer to pull relevant items into Obsidian

### What Makes This Different from /init

| Standard /init | /memory-init |
|---------------|-------------|
| Creates CLAUDE.md with project basics | Creates CLAUDE.md with project basics AND memory metadata |
| Scans codebase for conventions | Scans codebase AND Obsidian vault for prior context |
| One-time setup | Idempotent — safe to re-run, updates rather than overwrites |
| No vault awareness | Creates Obsidian folder structure and updates project index |
| No context loading | Loads and presents relevant prior sessions and learnings |

---

## File Layout

```
~/.claude/
├── CLAUDE.md                              # Global instructions (already created)
├── agents/
│   ├── memberberry.md                     # Retrieval subagent (memory: user)
│   └── blackbox.md                        # Checkpoint subagent (explicit save-progress requests)
├── commands/
│   ├── memory-sync.md                     # /memory-sync slash command
│   ├── memory-load.md                     # /memory-load slash command
│   ├── memory-init.md                     # /memory-init slash command
│   ├── handoff.md                         # /handoff slash command
│   └── decision.md                        # /decision slash command
├── hooks/
│   ├── handoff-lib.sh                     # Shared handoff library (sourced, not a hook)
│   ├── session-start.sh                   # SessionStart hook
│   ├── pre-compact.sh                     # PreCompact hook (clears read-once cache)
│   ├── stop-memory.sh                     # Stop hook
│   ├── session-end.sh                     # SessionEnd hook
│   ├── prompt-corrections.sh              # UserPromptSubmit hook
│   └── read-once/hook.sh                  # PreToolUse hook
├── memory-staging/                        # Local staging for hook → MCP bridge
│   └── my-project/
│       ├── .session-meta                  # Message count, timestamps, synced flag
│       ├── .corrections-index             # title|key index for UserPromptSubmit
│       ├── .unsynced                      # written by SessionEnd, cleared by /memory-sync
│       ├── handoff.md                     # Current-work-unit scratch (written by /handoff)
│       └── handoff.consumed.md            # Renamed by SessionStart after injection
└── settings.json                          # Hook configuration
```

Installed as a plugin, the hooks, agents, and commands live at the plugin root instead, registered via `hooks/hooks.json` and `.claude-plugin/plugin.json` with `${CLAUDE_PLUGIN_ROOT}` paths.

---

## Hook ↔ MCP Bridge

The fundamental challenge: hooks are shell commands that can't call MCP-Obsidian. The solution is a two-stage pattern:

```
Hook (shell)                          Claude (MCP)
    │                                      │
    ├── writes to memory-staging/          │
    ├── injects additionalContext ────────►│
    │                                      ├── reads staging files
    │                                      ├── writes to Obsidian via MCP
    │                                      └── cleans staging files
```

### Staging File Format

```yaml
---
type: handoff|session-meta|nudge
project-slug: my-project
created: 2026-03-17T14:30:00Z
---

## Session State
<content that needs to be written to Obsidian>
```

The SessionStart hook checks for a pending handoff file and injects its content as `additionalContext`, then renames it `handoff.consumed.md`. This closes the loop without requiring MCP access from shell scripts.

---

## Settings.json Configuration

The hooks are registered in `~/.claude/settings.json` (user-level, applies to all projects):

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/session-start.sh" }] }
    ],
    "PreToolUse": [
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/read-once/hook.sh" }] }
    ],
    "PreCompact": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/pre-compact.sh" }] }
    ],
    "Stop": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/stop-memory.sh" }] }
    ],
    "SessionEnd": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/session-end.sh" }] }
    ],
    "UserPromptSubmit": [
      { "matcher": "", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/prompt-corrections.sh" }] }
    ]
  }
}
```

---

## Interaction Flow

### First Time in a New Project

```
1. User opens Claude Code in ~/projects/new-thing/
2. SessionStart hook fires:
   - No .claude/CLAUDE.md found
   - No memory:project-slug detected
   - Injects context: "No memory configuration found. Run /memory-init to set up."
3. User types: /memory-init
4. Slash command:
   - Detects: git remote → "new-thing", package.json → "New Thing App"
   - Proposes: slug=new-thing, area=Personal
   - User confirms
   - Creates .claude/CLAUDE.md with metadata
   - Creates Obsidian folder: 5 Agent Memory/sessions/by-project/new-thing/
   - Updates project-index.md
   - No prior sessions found — "Starting fresh."
5. User works normally
6. Stop hook nudges around ~150k tokens → user runs `/handoff` then `/clear`; next session auto-loads the handoff
7. Stop fires after each response → tracks message count
8. User runs /memory-sync at end → structured session note to Obsidian
```

### Returning to an Existing Project (after a `/handoff` + `/clear`)

```
1. User ran /handoff at the end of a large session → handoff.md written to staging
2. User ran /clear → session ended; SessionEnd skips the .unsynced flag (clear is deliberate)
3. User opens Claude Code in ~/projects/my-project/ (new session)
4. SessionStart hook fires (source=clear):
   - Reads .claude/CLAUDE.md → slug=my-project, area=AWS
   - Finds handoff.md in staging
   - Injects handoff content as additionalContext
   - Renames handoff.md → handoff.consumed.md
5. Claude resumes with the injected handoff context automatically
6. User types: /memory-load (optional — for deeper prior session context)
7. Work continues with full context
8. /memory-sync at end → structured session note to Obsidian, deletes handoff scratch files
```

---

## Performance Considerations

Per-hook budgets, enforced as WARN (not FAIL) on the Tier 1 harness:

| Hook | Budget |
|------|--------|
| SessionStart | warm ≤300ms / cold ≤3s (cold runs the cacheable vault queries in parallel) |
| PreCompact | ≤100ms (clears read-once cache only; spawn-dominated) |
| Stop | ≤50ms target |
| SessionEnd | ≤100ms |
| UserPromptSubmit | ≤100ms (fast-exits before stdin when no corrections exist) |

On Windows Git Bash the empty-bash spawn floor alone can exceed 100ms, so the Stop and UserPromptSubmit targets aren't reachable there — the harness warns and fails only on a >2× regression against the recorded per-machine baseline. The expensive operations (MCP-Obsidian reads/writes) happen in Claude's turn, not in the hooks, keeping the lifecycle fast and the memory operations in the model's control.
