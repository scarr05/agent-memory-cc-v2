---
name: agent-memory
description: "Persistent memory system for AI agents using Obsidian as backing storage, with hook-enforced, project-scoped, three-tier storage. Use this skill when you need context about the user's preferences, want to recall previous work, need to log progress or decisions, when the user asks you to remember something, or when processing hook-injected staging files. Triggers on 'remember', 'what do you know about', 'continue where we left off', 'save this', 'log this decision', 'what did we decide', references to previous sessions, processing a staging handoff, or any memory operation. Also triggers when SessionStart hook injects pending items. Requires MCP-Obsidian server."
---

# Agent Memory v4

Persistent memory system stored in your Obsidian vault at `5 Agent Memory/`. Enforced by hooks, organised by project slug, with three tiers of storage.

## Architecture Overview

```
┌────────────────────────────────────────────────────┐
│  LAYER 4 — READ-ONCE  (PreToolUse hook)            │
│  Deduplicates source code Read calls               │
├────────────────────────────────────────────────────┤
│  LAYER 3 — SUBAGENTS  (Haiku, on-demand)           │
│  memberberry: vault retrieval via CLI               │
│  blackbox: checkpoint capture via CLI               │
├────────────────────────────────────────────────────┤
│  LAYER 2 — SESSION START  (CLI-driven, injected)    │
│  Git state, open tasks, project status, working/   │
├────────────────────────────────────────────────────┤
│  LAYER 1 — CLAUDE.MD  (~500 tokens, every turn)     │
│  Static: architecture, conventions, structure       │
└────────────────────────────────────────────────────┘

Hooks: SessionStart · PreToolUse · PreCompact · Stop · SessionEnd · UserPromptSubmit
Subagents: memberberry (retrieval, memory: user) · blackbox (checkpoint, memory: project)
Staging: ~/.claude/memory-staging/<slug>/
Commands: /memory-init  /memory-load  /memory-sync  /decision
```

Data flows upward. Hooks enforce the lifecycle deterministically. The agent handles MCP operations that hooks can't.

---

## Vault Structure

```
5 Agent Memory/
├── _context.md                    # Preferences, priorities (read on-demand)
├── project-index.md               # Quick-reference: all projects with pointers
├── sessions/
│   ├── by-project/                # Project-scoped session logs
│   │   ├── my-web-app/
│   │   ├── infrastructure/
│   │   └── <project-slug>/
│   └── general/                   # Cross-project or ad-hoc sessions
├── learnings/
│   ├── preferences/               # How the user likes things done
│   ├── technical/                 # Technical patterns and decisions
│   ├── workflow/                  # Process preferences
│   └── corrections/              # Things agents got wrong
└── working/                       # Agent scratchpad (unchanged)
```

---

## Core Principles

1. **Hooks detect, subagents retrieve, MCP writes** — SessionStart injects the project slug and dynamic state via CLI. Delegate vault reads to memberberry (Haiku). Write to Obsidian via MCP.
2. **Project slug drives routing** — all session paths use `sessions/by-project/<slug>/`. The slug comes from hook context or `.claude/CLAUDE.md` metadata.
3. **Log meaningful sessions** — not every interaction, only significant ones.
4. **Propose learnings** — never write to `learnings/` without the user's approval.
5. **Process staging files** — if hooks created staging files, process them to Obsidian before they pile up.
6. **Scratchpad is yours** — use `working/` freely for in-progress work.

---

## Hook Integration

Six hooks fire automatically. Know what they do so you can respond appropriately.

| Hook | Fires When | What It Does | Your Job |
|------|-----------|--------------|----------|
| **SessionStart** | Session begins (incl. `source=compact`) | Injects slug, a pending handoff, the unsynced-session flag, and init status via `additionalContext`. On `source=compact`, harvests the compaction summary into a handoff. | Process pending staging files. On a compaction restart, the handoff is injected automatically — review it and continue. Search Obsidian for prior context if the task is non-trivial. |
| **PreToolUse** (Read) | Before a Read | Blocks redundant re-reads (read-once) via `permissionDecision`. | Nothing — it's transparent. |
| **PreCompact** | Before compaction | Clears the read-once cache; checkpoint stubs are retired. Injects nothing — the handoff happens at the next SessionStart. | Nothing at compaction time; the post-compaction SessionStart drives the handoff. |
| **Stop** | Each response | Nudges via `systemMessage` if the session is long (15/30 messages, 45+ min); checks the 24-hour dream timer. | Acknowledge the nudge. Suggest `/memory-sync` if the session has been significant. |
| **SessionEnd** | Session ends | Writes `.unsynced` if a real-length session ended without `/memory-sync` (skips a deliberate `clear`). Side-effect only. | Nothing — the next SessionStart surfaces it. |
| **UserPromptSubmit** | Each prompt | If the prompt touches a logged correction's topic, injects a one-line pointer via `additionalContext`. | Load the correction via memberberry before acting on that topic. |

### Staging Directory

Hooks write to `~/.claude/memory-staging/<slug>/` because they can't call MCP. You bridge this to Obsidian:

1. **Handoff scratch** (`handoff.md`) — written by `/handoff` (or harvested by a hook). SessionStart injects it automatically and renames it `handoff.consumed.md`; `/memory-sync` deletes both. You normally don't process it by hand.
2. **Session meta** (`.session-meta`) — tracks message count and timing. Read-only for you; managed by hooks.

---

## Operations

### 1. Project Identification

**The project slug is your routing key.** It determines where sessions get written and where to search for context.

**How to get it:**
- SessionStart hook injects it (preferred)
- Read `.claude/CLAUDE.md` for `<!-- memory:project-slug=X -->` comment
- If neither available, ask the user or suggest `/memory-init`

**If no slug exists:** suggest the user runs `/memory-init` to set up the project.

---

### 2. Load Context

**When:** Non-trivial task that might have prior context. SessionStart hook will remind you.

**How:**
```
1. Use the project slug from hook context
2. Delegate to memberberry subagent:
   "Use memberberry to find prior context for <slug>"
3. memberberry searches via CLI: search → search:context → property:read → selective read
4. Main agent receives filtered summary (~200 tokens)
5. If memberberry unavailable, fall back to MCP search_notes
```

**Or:** the user runs `/memory-load` which does this automatically.

**_context.md:** Only read when you specifically need the user's current priorities or global preferences. Don't auto-load every session.

---

### 3. Log Session

**When to log:**
- Key decisions made
- Meaningful progress (good or bad)
- Long conversation approaching context limits
- Planning phase complete
- Major direction change / U-turn
- the user explicitly asks or runs `/memory-sync`

**When NOT to log:**
- Quick Q&A, trivial tasks, no meaningful decisions

**Where to write:**
```
5 Agent Memory/sessions/by-project/<slug>/YYYY-MM-DD-brief-topic.md
```

If the project folder doesn't exist under `by-project/`, create it.
For cross-project or ad-hoc sessions, use `sessions/general/`.

**Session Frontmatter:**
```yaml
---
title: "Session - Brief Topic"
created: YYYY-MM-DDTHH:MM:SS
type: session
status: [complete|in-progress|blocked|abandoned]
project: "project-slug"
area: "area-name"
tags: [tag1, tag2]
decisions:
  - "Decision 1"
  - "Decision 2"
outcomes:
  - "Outcome 1"
follow_up:
  - "Open item 1"
resumable: true|false
promoted_to: ""                    # Set when patterns promoted to learnings
source_agent: "claude-code|claude.ai|codex"
---
```

**Content structure:** See `references/memory-patterns.md` for full templates.

---

### 4. Propose Learning

**When:** You discover something about the user's preferences, workflows, or corrections.

**Process:**
1. Don't write directly — propose to the user first
2. State what you learned and ask for confirmation
3. Only write to `learnings/<category>/` after approval

**Categories map to subfolders:**
- `preferences/` — formatting, communication, style choices
- `technical/` — architecture patterns, tool preferences, code conventions
- `workflow/` — process preferences, how the user likes to work
- `corrections/` — things agents got wrong that shouldn't be repeated

**Learning Frontmatter:**
```yaml
---
title: "Learning - Topic"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: learning
category: [preference|workflow|context|correction]
confidence: [high|medium|low]
project: ""
area: ""
tags: []
source_session: "YYYY-MM-DD-session-name"
---
```

**Confidence:** high = the user confirmed. medium = inferred, not contradicted. low = single observation.

---

### 5. Use Scratchpad

`working/` is your free space. Use it for drafts, intermediate analysis, research notes, task context.

**Your responsibility:** clean up when work is complete. Don't leave stale files.

**Naming:** `YYYY-MM-DD-task-description.md`

No approval needed.

---

### 6. Update Context

**When:** the user explicitly asks to update priorities or context.

**Process:**
1. Read current `_context.md`
2. Propose specific changes to the user
3. After approval, update the relevant section
4. Update `modified` date in frontmatter

---

### 7. Update Project Index

**When:** After logging a session via `/memory-sync`, or when a new project is initialised.

**How:**
```
1. read_note("5 Agent Memory/project-index.md")
2. Find project row by slug
3. Update: last session date, key decisions, status
4. If project not listed, add a new row
```

---

## Session Resumption Pattern

When the user says "continue where we left off" or "resume X":

```
1. Get project slug from hook context or .claude/CLAUDE.md
2. search_notes("X") in sessions/by-project/<slug>/
3. Find most recent relevant session with resumable: true
4. Read full session note
5. Read any linked working/ files
6. Check staging directory for a pending handoff
7. Summarise: "Last session on [date], we [summary].
   Open items were: [list]. Ready to continue?"
8. Proceed with context loaded
```

---

## Slash Command Integration

Four slash commands handle the structured workflows. This skill provides the underlying operations they rely on.

| Command | What It Does | When to Suggest |
|---------|-------------|-----------------|
| `/memory-init` | Auto-detects project, creates CLAUDE.md metadata, sets up Obsidian structure, loads context | First time in a new project, or SessionStart flags no config |
| `/memory-load` | Searches Obsidian by slug, presents prior sessions and learnings | Session start for non-trivial work |
| `/memory-sync` | Writes structured session note, proposes learnings, appends decisions, marks the session synced, cleans staging | End of significant session |
| `/decision` | Logs a single decision to `_decisions.md` without a full sync | A decision worth recording mid-session |

If the user runs these commands, follow their instructions. If the user doesn't and the session is significant, suggest `/memory-sync` before ending.

---

## Cross-Referencing

| Field | Purpose | Example |
|-------|---------|---------|
| `project` | Links to project slug | `"my-project"` |
| `area` | Links to 2 Areas/ | `"AWS"` |
| `tags` | Searchable topics | `["project-name", "cost-optimisation"]` |
| `decisions` | Key choices made | `["Use Terraform over CFN"]` |
| `source_agent` | Which agent wrote it | `"claude-code"` |
| `promoted_to` | Learning path if promoted | `"learnings/technical/terraform-state.md"` |

---

## Token Efficiency

The architecture optimises tokens at every layer:

- **CLAUDE.md** — static only, ~500 tokens per turn (vs ~1500+ in v2)
- **SessionStart** — CLI snapshot, ~200-300 tokens once (vs MCP dump)
- **memberberry** — Haiku retrieval, main model gets ~200 token summary
- **blackbox** — Haiku checkpoint, no main model context cost
- **read-once** — blocks redundant source code reads, ~2000 tokens saved per prevented re-read

**Rules:**
- Never call MCP `search_notes` or `read_note` directly — delegate to memberberry
- For large sessions, run `/handoff` then `/clear`; delegate to blackbox only for explicit "save progress" requests
- Use `property:read` over `read` when you only need frontmatter
- Keep session summaries concise — details go in linked files

---

## Tools Reference

### Obsidian CLI (reads — via subagents)

| Command | Use For |
|---------|---------|
| `search` | Find notes by content (paths only) |
| `search:context` | Matching lines with context |
| `property:read` | Read frontmatter fields |
| `read` | Full note content (last resort) |
| `backlinks` / `links` | Graph traversal |
| `tasks` | Task queries (requires file path, not folder) |
| `create` / `append` | Note creation |
| `property:set` | Set frontmatter values |

### MCP-Obsidian (writes)

| Tool | Use For |
|------|---------|
| `write_note` | Create/update notes |
| `patch_note` | Update part of a note |
| `update_frontmatter` | Modify metadata only |
| `move_note` | Move/rename notes |
| `manage_tags` | Tag operations |

---

## Examples

### Starting work on a project (with hooks)

```
1. SessionStart hook injects: "Project: my-project, area: AWS.
   Pending handoff from yesterday — loaded into context."
2. Agent reviews the injected handoff and continues
3. Agent searches: sessions/by-project/my-project/ and learnings/ for "project-name"
4. Finds recent session and preferences
5. Agent: "Found prior project work. Last session: v5 pillar alignment.
   Open items: test coverage. Apply same approach?"
6. Proceeds with context
```

### Logging a session (project-scoped)

```
1. Long planning discussion for project v5
2. Decisions made: use Terraform state locking, skip multi-cloud modules
3. Agent: "Key decisions made. Logging to Obsidian."
4. Writes: sessions/by-project/my-project/2026-03-18-v5-planning.md
   - source_agent: "claude-code"
   - resumable: true with clear next steps
5. Updates project-index.md with last session date
```

### Resuming from a handoff

```
1. SessionStart(source=clear) reports: "Pending handoff at
   ~/.claude/memory-staging/my-project/handoff.md — loaded into context."
2. The hook injects the handoff content as additionalContext
3. The hook renames it handoff.consumed.md
4. Agent reviews the injected work unit and continues
5. /memory-sync later deletes handoff.md and handoff.consumed.md
```

### Handing off a large session

```
1. Stop hook nudges around ~150k tokens
2. User runs /handoff → current work unit captured to handoff.md
3. User runs /clear
4. Next session's SessionStart injects the handoff automatically
```

---

## References

For detailed templates and patterns, read:
- `references/memory-patterns.md` — Session, learning, working, and checkpoint templates with full frontmatter
