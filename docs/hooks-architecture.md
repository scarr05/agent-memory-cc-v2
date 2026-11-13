# Hooks-Enforced Memory System

## The Problem with CLAUDE.md-Only Enforcement

CLAUDE.md instructions are advisory — the model can ignore them, especially after compaction or in long sessions where context drift kicks in. Hooks are deterministic. They fire every time, regardless of what the model decides to do.

## Design Principles and Memory Tiers

1. **Agents shouldn't need reminding** — hooks and the global CLAUDE.md force memory behaviour in every project.
2. **Three tiers, one brain** — session memory flows up to project memory, project memory flows up to the vault.
3. **Any agent, same context** — the Obsidian vault is the single source of truth, readable by any agent that can reach the files or an MCP server (the Codex adapter reads them directly).
4. **Agents curate, the user can veto** — the agent chooses which learnings to save and reports them; an auto sync marks what it saved `auto: true`, and `--dream` checks those for accuracy.
5. **Token-conscious** — load what is relevant to the task, not everything.

| Tier | What | Where | Lifespan |
|------|------|-------|----------|
| 1 — Hot (session) | The active context window and scratch | Context window, `5 Agent Memory/working/` | One session; `/handoff` carries it across `/clear` |
| 2 — Warm (project) | Claude Code auto-memory and the project CLAUDE.md | `~/.claude/projects/<project>/memory/`, `.claude/CLAUDE.md` | Across sessions, per project, per machine |
| 3 — Cold (vault) | Sessions, decisions, learnings | `5 Agent Memory/` in the vault | Permanent until archived (sessions go stale after 90 days) |

`/memory-sync` promotes from tier 1 to tiers 2 and 3; `--ingest` promotes tier 2 to tier 3. The vault is plain files synced between machines, so there is no knowledge-base server to run or secure, and YAML frontmatter keeps every note machine-parseable.

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

Plus five slash commands:

| Command | Purpose |
|---------|---------|
| **`/memory-init`** | /init on steroids — detects project, creates everything, loads context |
| **`/memory-sync`** | End-of-session sync: session note, decisions log, learnings, staging clean-up (`--dream`, `--ingest`, `--tidy`, `--status`, `--auto`) |
| **`/memory-load`** | Restore hook-level context from `.claude/memory-state.json`, then delegate the vault search to memberberry |
| **`/handoff`** | Capture the current work unit into a handoff scratch file before `/clear` |
| **`/decision`** | Log one decision to `_decisions.md` without a full sync |

---

## Project Detection Logic

The project slug drives everything — where sessions get written, where context gets loaded from, what folder exists in Obsidian. Rather than hardcoding it, we derive it automatically and store it in the project CLAUDE.md.

### Detection Priority

1. `.claude/CLAUDE.md` — `<!-- memory:project-slug=X -->` HTML comment
2. `.claude/memory-state.json` — slug from a prior session (SessionStart skips this, since it writes the file)
3. `.claude/settings.json` — `memory.projectSlug` field
4. A linked worktree with neither file: the main checkout's marker, then its state file
5. Git remote origin — repo name extraction
6. `package.json` / `pyproject.toml` — project name
7. The main checkout's directory name in git (so `noted/src` or a linked worktree is `noted`), else the directory basename

One implementation, `hooks/slug-lib.sh`: the hooks source it and call `resolve_slug`; the commands run `bash slug-lib.sh`, which prints the slug. Step 4 is what lets a session in a linked worktree land in the main checkout's staging folder and vault notes.

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
2. **Query vault state via the Obsidian CLI** — project-index row, open tasks, working files and session count: four queries in parallel with a ~3s watchdog, cached 15 minutes per slug+branch. The corrections query always runs live and rebuilds `.corrections-index`. If the CLI is unavailable it says so and falls back to minimal context.
3. **Inject context pointer** — outputs `hookSpecificOutput.additionalContext` telling Claude where to find memory and what slug to use (or plain stdout when `MEMORY_HOOK_PLAINTEXT=1`).
4. **Flag pending work** — on `source=clear`, injects an armed `handoff.md` and renames it `handoff.consumed.md`; on a full start (`startup`/`resume`), surfaces the `.unsynced` marker SessionEnd leaves when a prior session was never synced. A full start does not read `handoff.md`.
5. **Flag if uninitialised** — if `.claude/CLAUDE.md` has no `memory:project-slug` marker, the context warns, suggests `/memory-init` and names the auto-detected slug it is using.
6. **Check the dream timer** — on a full start, sets `.dream-pending` when the last `/memory-sync --dream` was more than 24 hours ago, and surfaces the nudge.
7. **Write session state** — `.claude/memory-state.json`, this session's `.session-meta`, and the slot's `.last-session`; session folders older than 7 days are pruned.
8. **Handle the compaction restart** — when `source=compact`, harvests the compaction summary into a handoff scratch file, preserving the session counter and start time across compaction. (No stub-filling or blackbox direction — the handoff is injected directly.)

### SessionStart vs UserPromptSubmit

SessionStart fires once and carries the bulk context load — too expensive to repeat per message. UserPromptSubmit fires on every prompt, so it does the one cheap, high-value thing that must be just-in-time: surfacing a correction the moment the prompt touches its topic (Hook 5). It exits before reading stdin in the common no-corrections case to stay under its 100ms budget. The heavy Obsidian reads still happen via MCP when Claude acts on the SessionStart pointer.

---

## Hook 2: PreCompact

**File:** `~/.claude/hooks/pre-compact.sh`

Fires before context compaction. Checkpoint stubs are retired — the hook now does one thing only: clear the read-once cache so the compacted session starts with a clean slate.

### What It Does

1. **Clear the read-once cache** — removes this session's dedup index (keyed on the hook input's `session_id`, falling back to `CLAUDE_SESSION_ID`; with neither, nothing is cleared) so the fresh compacted session can re-read files freely
2. **Inject nothing** — Claude can't act mid-compaction, so the hook emits no output. The continuation path is the handoff workflow: SessionStart with `source=compact` harvests the compaction summary into a handoff scratch file and injects it as `additionalContext` so the next session resumes automatically.

### Compaction as a Dormant Safety Net

Compaction is no longer the primary large-session path. The preferred workflow is `/handoff` → `/clear` (explicit, user-controlled) long before compaction would fire. Compaction stays enabled as a last-resort catch, but its hook no longer writes stubs or directs any agent to fill them.

### The Handoff Scratch Lifecycle

```
/handoff writes <slot>/handoff.md
    (the slot is ~/.claude/memory-staging/<slug>/)
    (fallback: session-end.sh harvests on a clear with no handoff,
     or session-start.sh harvests the compaction summary on source=compact)
  ↓
SessionStart(source=clear) injects handoff.md as additionalContext
  ↓
SessionStart renames it handoff.consumed.md
  ↓
/memory-sync deletes both handoff.md and handoff.consumed.md
```

A single-slot scratch file — one handoff at a time per project (the slot, `<slug>/`).

### hooks/handoff-lib.sh — Shared Library

`hooks/handoff-lib.sh` is a bash library that holds the handoff read/write functions used by multiple hooks. It is **not** registered as a hook event; it is sourced by `session-start.sh` (always), `session-end.sh` (clear branch only) and `stop-memory.sh` (lazily, for the token nudge), each behind an existence check:

```bash
LIBDIR="${BASH_SOURCE[0]%/*}"; [[ "$LIBDIR" == "${BASH_SOURCE[0]}" ]] && LIBDIR=.
if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1; else HANDOFF_LIB=0; fi
```

The CLI dispatcher inside `handoff-lib.sh` is guarded by `[[ "${BASH_SOURCE[0]}" == "${0}" ]]` so sourcing it never runs any code — only function definitions are loaded.

---

## Hook 3: Stop

**File:** `~/.claude/hooks/stop-memory.sh`

Fires when Claude finishes responding. Lightweight session tracking.

### What It Does

1. **Increment message counter** — one awk pass updates the count and last-activity time in `~/.claude/memory-staging/<slug>/sessions/<session_id>/.session-meta`, deriving duration from the `session_start_epoch` SessionStart wrote.
2. **Check thresholds** — fires at 15 and 30 messages (30 checked first, with independent sent-flags so a session that jumps past 15 still nudges), or after 45+ minutes.
3. **Check the handoff token threshold** — once the session passes 8 exchanges it reads the live token count from the transcript and nudges once at `memory.handoffTokenThreshold` (project then global `settings.json`, default 150000).
4. **Emit nudge** — via `systemMessage` (shown to the user, not Claude), e.g. "This session has 15 exchanges (~20min). Consider running /memory-sync to checkpoint progress to Obsidian." or "~155k tokens — consider /handoff then /clear to continue in a fresh session." Co-firing nudges are joined with ` | `.

### Why Not Auto-Write Sessions on Stop

The Stop hook fires on EVERY response, not just session end. Auto-writing would create noise. Instead, it tracks and nudges. The human decides when to sync.

---

## Hook 4: SessionEnd

**File:** `~/.claude/hooks/session-end.sh`

Fires when the session ends (close, `exit`, `logout`, or `/clear`). It catches the case the Stop nudge can't: a substantial session that simply ends without `/memory-sync`.

### What It Does

1. **Read the end reason** from stdin. A `clear` is a deliberate wipe — never flagged unsynced. If no handoff is armed, the hook builds a deterministic clear-fallback `handoff.md` from the transcript so the next SessionStart has something to inject, then exits.
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

This replaces the standard `/init` workflow for memory-enabled projects. It's a slash command (not a hook) because it needs Obsidian MCP access and interactive confirmation.

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

2. **Create Obsidian structure** via the Obsidian MCP server:
   ```
   5 Agent Memory/sessions/by-project/my-project/  (if not exists)
   ```

3. **Update project index** — add/update row in `5 Agent Memory/project-index.md`

4. **Load existing context** — search for prior sessions on this project
   ```
   search vault for "my-project"
   ```
   Present summary of what was found.

5. **Ingest auto-memory** — if `~/.claude/projects/<project>/memory/MEMORY.md` exists, offer to pull relevant items into Obsidian

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
│   ├── slug-lib.sh                        # The slug lookup (sourced by hooks, run by commands)
│   ├── state-lib.sh                       # Session state paths, command flags, auto marker
│   ├── session-start.sh                   # SessionStart hook
│   ├── pre-compact.sh                     # PreCompact hook (clears read-once cache)
│   ├── stop-memory.sh                     # Stop hook
│   ├── session-end.sh                     # SessionEnd hook
│   ├── prompt-corrections.sh              # UserPromptSubmit hook
│   └── read-once/hook.sh                  # PreToolUse hook
├── memory-staging/                        # Local staging for hook → MCP bridge
│   └── my-project/
│       ├── sessions/<session_id>/
│       │   ├── .session-meta              # Turn count, nudges, synced/synced_at, handoff_at
│       │   └── .transcript-path           # The /handoff breadcrumb for this session
│       ├── .last-session                  # Newest session id
│       ├── .corrections-index             # title|key index for UserPromptSubmit
│       ├── .unsynced                      # written by SessionEnd, cleared by /memory-sync
│       ├── handoff.md                     # Current-work-unit scratch (written by /handoff)
│       └── handoff.consumed.md            # Renamed by SessionStart after injection
└── settings.json                          # Hook configuration
```

Installed as a plugin, the hooks, agents, and commands live at the plugin root instead, registered via `hooks/hooks.json` and `.claude-plugin/plugin.json` with `${CLAUDE_PLUGIN_ROOT}` paths.

### Session state

Two sessions in one project used to share every staging file: each SessionStart reset the other's `.session-meta`. `hooks/state-lib.sh` splits per-session state from project state:

| State | Where |
|---|---|
| `.session-meta`, `.transcript-path` | `<slug>/sessions/<session_id>/`, keyed by the hook input's `session_id`. Folders untouched for 7 days are pruned at SessionStart |
| `handoff.md`, `handoff.consumed.md`, `.unsynced`, `.last-session` | the slot, `<slug>/` |
| `.corrections-index`, `.vault-cache-*`, `.last-dream`, `.dream-pending` | `<slug>/`, shared |

Hook input without a `session_id` (an older Claude Code, a hand run) keeps the old flat layout.

The commands learn their session id from `${CLAUDE_SESSION_ID}`, which Claude Code substitutes in commands and skills. If it is empty, the slot's `.last-session` stands in, and `/handoff` refuses when more than one transcript in the project's transcript folder was written in the last two minutes.

### Auto memory: `--auto` and `memory:auto=true`

`/memory-sync` and `/handoff` take `--auto`. A project opts into auto for every run with `<!-- memory:auto=true -->` in its `.claude/CLAUDE.md` (a linked worktree without its own file reads the main checkout's); `state-lib.sh args` then prints `AUTO=1` with `AUTO_WHY=project`, and SessionStart tells Claude it manages that project's memory. Flags are parsed by `state-lib.sh args`, which refuses ones it does not know. Each command has an "Auto mode" table naming what replaces every question or stop.

An auto sync writes learnings to `learnings/` like an attended one, with `auto: true`, `project:` and `session:` in the frontmatter. Nobody checked them, so every `--dream` reviews the unreviewed ones against the repo and the vault as they are now (Phase 3.5): accurate ones get `reviewed:`, ones with a wrong detail are patched, and wrong ones move to `5 Agent Memory/archive/learnings/`. Learnings without `auto: true` are never touched by that review. Both commands mark the session (`synced_at`, `handoff_at`) in its `.session-meta`.

---

## Hook ↔ MCP Bridge

The fundamental challenge: hooks are shell commands that can't call an MCP server. The solution is a two-stage pattern:

```
Hook (shell)                          Claude (MCP)
    │                                      │
    ├── writes to memory-staging/          │
    ├── injects additionalContext ────────►│
    │                                      ├── reads staging files
    │                                      ├── writes to Obsidian via MCP
    │                                      └── cleans staging files
```

### Handoff File Format

```yaml
---
slug: "my-project"
branch: "main"
created: "2026-03-17T14:30:00Z"
source: "handoff"        # handoff | clear-fallback | compact-fallback
live_tokens: 152000
consumed: false
supersedes: ""
---

## Current Work — Narrative
<!-- HANDOFF:NARRATIVE:START --> ... <!-- HANDOFF:NARRATIVE:END -->
## Do-Not-Redo
<!-- HANDOFF:DONOTREDO:START --> ... <!-- HANDOFF:DONOTREDO:END -->
## Git State
## Files Touched (this work unit)
```

`.session-meta` is plain `key=value` lines, not YAML.

On `source=clear`, the SessionStart hook checks for an armed handoff file and injects its narrative block as `additionalContext`, then renames it `handoff.consumed.md`. This closes the loop without requiring MCP access from shell scripts.

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
   - No memory:project-slug marker, so the slug is auto-detected
   - Injects context: "No memory config. Run /memory-init to set up. Using auto-detected slug ..."
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

### Continuing after `/handoff` + `/clear`

If Claude Code is closed and reopened instead, SessionStart is `source=startup` and does not inject the handoff; run `/memory-load`, which reads `handoff.md` (step 0.2).

```
1. User ran /handoff at the end of a large session → handoff.md written to staging
2. User ran /clear → session ended; SessionEnd skips the .unsynced flag (clear is deliberate)
3. The same Claude Code window starts the fresh session
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
| PreCompact | ≤100ms target (clears read-once cache only; spawn-dominated; recorded by the harness, no WARN check) |
| Stop | ≤50ms target |
| SessionEnd | ≤100ms |
| UserPromptSubmit | ≤100ms (fast-exits before stdin when no corrections exist) |

On Windows Git Bash the empty-bash spawn floor alone can exceed 100ms, so the Stop and UserPromptSubmit targets aren't reachable there — the harness warns and fails only on a >2× regression against the recorded per-machine baseline. The expensive operations (MCP-Obsidian reads/writes) happen in Claude's turn, not in the hooks, keeping the lifecycle fast and the memory operations in the model's control.
