# Agent Memory v2 — Installation

## Prerequisites

1. MCP-Obsidian configured and working in Claude Code
2. `5 Agent Memory/` folder structure exists in vault (see vault-manager skill)
3. **Hooks deployed** — `session-start.sh`, `pre-compact.sh`, `stop-memory.sh` in `~/.claude/hooks/`
4. **Slash commands deployed** — `memory-init.md`, `memory-sync.md`, `memory-load.md` in `~/.claude/commands/`
5. **Global CLAUDE.md** — `~/.claude/CLAUDE.md` with v2 memory instructions
6. **settings.json** — hook registrations merged into `~/.claude/settings.json`

If the hooks and commands aren't deployed yet, the skill still works — it just won't have deterministic enforcement. The skill itself is the instruction set; hooks and commands are the enforcement and convenience layers.

## Install Skill

Copy the `agent-memory/` folder to your Claude Code skills directory:

```bash
cp -r agent-memory-v2/ /path/to/your/skills/agent-memory/
```

This overwrites the v1 skill. The v2 skill is backwards-compatible with existing session notes — it just adds project-scoping and hook awareness on top.

## Vault Structure Setup

If not already created, set up the v2 folder structure:

```bash
# Via Claude Code with MCP-Obsidian, or manually:
mkdir -p "5 Agent Memory/sessions/by-project"
mkdir -p "5 Agent Memory/sessions/general"
mkdir -p "5 Agent Memory/learnings/preferences"
mkdir -p "5 Agent Memory/learnings/technical"
mkdir -p "5 Agent Memory/learnings/workflow"
mkdir -p "5 Agent Memory/learnings/corrections"
```

Create `5 Agent Memory/project-index.md` using the template in `references/memory-patterns.md`.

Existing flat session notes in `5 Agent Memory/sessions/` still work — search finds them regardless. Move them to `by-project/` or `general/` when convenient.

## Per-Project Setup

For each active project, run `/memory-init` in Claude Code. This:

1. Auto-detects project slug, tech stack, area
2. Creates `.claude/CLAUDE.md` with memory metadata
3. Creates the Obsidian session folder for the project
4. Updates the project index
5. Loads any prior context

## Verify Setup

In Claude Code, test:

```
/memory-load
```

Should search Obsidian and show relevant prior context, or report "no prior sessions found."

Then:

```
"Search my agent memory for any existing sessions"
```

Should return results from `5 Agent Memory/sessions/`.

## Day-to-Day Usage

### Automatic (hooks handle it)
- **SessionStart** detects project, injects context pointer, flags pending items
- **PreCompact** checkpoints session state before context shrinks
- **Stop** tracks message count, nudges for sync on long sessions

### On-Demand (slash commands)
| Command | When |
|---------|------|
| `/memory-init` | First time in a new project |
| `/memory-load` | Pull context at session start |
| `/memory-sync` | Save session at end of significant work |
| `/memory-sync --ingest` | Pull auto-memory into Obsidian |
| `/memory-sync --tidy` | Review old sessions for archiving |
| `/memory-sync --status` | Show current memory state |

### Conversational (skill triggers)
| Phrase | Action |
|--------|--------|
| "Remember that..." | Proposes a learning |
| "What do you know about X?" | Searches sessions and learnings |
| "Continue where we left off" | Finds most recent resumable session |
| "Log this session" | Writes structured session note |
| "Save a checkpoint" | Writes to working/ |

## Migration from v1

The v2 skill is additive. Nothing breaks:

| v1 | v2 | Migration |
|----|-----|-----------|
| `sessions/YYYY-MM-DD-topic.md` | `sessions/by-project/<slug>/...` | Move when convenient, or leave in place |
| `learnings/topic.md` | `learnings/<category>/topic.md` | Move into subcategories when convenient |
| No project-index.md | `project-index.md` | Created by `/memory-init` |
| No hooks | Three hooks enforcing lifecycle | Deploy to `~/.claude/hooks/` |
| No slash commands | Three commands for structured workflows | Deploy to `~/.claude/commands/` |
| No staging directory | `~/.claude/memory-staging/` | Created automatically by hooks |

## What Changed from v1

| Aspect | v1 | v2 |
|--------|-----|-----|
| **Enforcement** | CLAUDE.md instructions (advisory) | Hooks + CLAUDE.md (deterministic + advisory) |
| **Session routing** | Flat `sessions/` folder | `sessions/by-project/<slug>/` |
| **Learning organisation** | Flat `learnings/` folder | `learnings/<category>/` subcategories |
| **Context loading** | Manual or skill-triggered | Hook auto-injects pointers at SessionStart |
| **Compaction safety** | Agent had to remember to checkpoint | PreCompact hook creates staging checkpoint |
| **Session tracking** | No tracking | Stop hook counts messages, nudges for sync |
| **Project awareness** | Manual project field in frontmatter | Auto-detected slug from git/manifest/folder |
| **Multi-agent** | Single agent assumed | `source_agent` field, vault as shared brain |
| **Slash commands** | "Future" section in INSTALL.md | `/memory-init`, `/memory-load`, `/memory-sync` |
