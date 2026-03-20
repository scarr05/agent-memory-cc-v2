# Persistent Agent Memory Architecture

## The Problem

Claude Code agents don't consistently use MCP-Obsidian for memory. The built-in auto-memory writes to `~/.claude/projects/<project>/memory/` which is isolated from the Obsidian vault. There's no bridge between what Claude Code learns per-session and what lives in [your-vault-name]. The result: context evaporates between sessions, agents don't pull from prior work, and you end up re-explaining things.

## Design Principles

1. **Agents shouldn't need reminding** — the global CLAUDE.md forces memory behaviour in every project
2. **Three tiers, one brain** — session memory flows up to project memory, project memory flows up to vault
3. **Any agent, same context** — Obsidian vault is the single source of truth, accessible from any MCP-capable agent
4. **Human curation at the top** — agents propose, the user approves what gets promoted to permanent knowledge
5. **Token-conscious** — don't load everything; load what's relevant for the current task

---

## Three-Tier Storage

```
┌─────────────────────────────────────────────────────────┐
│  TIER 3 — COLD (Obsidian Vault)                        │
│  [your-vault-name]/5 Agent Memory/                            │
│  Cross-project knowledge, consolidated learnings        │
│  Human-curated, permanent, searchable                   │
│  Accessible: Claude.ai, Claude Code, any MCP agent      │
├─────────────────────────────────────────────────────────┤
│  TIER 2 — WARM (Project)                                │
│  .claude/memory/ + project CLAUDE.md                    │
│  Project-specific decisions, patterns, architecture     │
│  Auto-memory writes here naturally                      │
│  Per-project, persists across sessions                  │
├─────────────────────────────────────────────────────────┤
│  TIER 1 — HOT (Session)                                 │
│  Active context window + working/ scratchpad            │
│  Current task state, in-flight decisions                │
│  Ephemeral — lost on /clear unless checkpointed         │
└─────────────────────────────────────────────────────────┘
```

### Tier 1 — Hot (Session)

What's in the active context window right now. Claude Code's conversation history, any files read, any decisions made this session.

- **Location:** Context window + `5 Agent Memory/working/`
- **Lifespan:** Single session (dies on /clear or session end)
- **Write trigger:** Automatic (it's just the conversation)
- **Promotion:** `/memory-sync` promotes to Tier 2 and Tier 3

### Tier 2 — Warm (Project)

Claude Code's built-in auto-memory system. Project-specific patterns, build commands, architecture decisions that Claude accumulates naturally.

- **Location:** `~/.claude/projects/<project>/memory/` (auto-memory) + project `.claude/CLAUDE.md`
- **Lifespan:** Persists across sessions, per-project, per-machine
- **Write trigger:** Auto-memory writes automatically; CLAUDE.md is manual
- **Promotion:** `/memory-sync` consolidates and pushes significant items to Tier 3

### Tier 3 — Cold (Vault)

The permanent shared brain. Cross-project knowledge, accumulated learnings, session history. This is what makes multi-agent failover work — any agent that can read Obsidian can pick up context.

- **Location:** `[your-vault-name]/5 Agent Memory/`
- **Lifespan:** Permanent until archived
- **Write trigger:** `/memory-sync` command or explicit agent action
- **Access:** MCP-Obsidian from Claude Code, MCP-Obsidian from Claude.ai, direct file access from any agent

---

## Data Flow

```
Session Work (Tier 1)
    │
    ├──► Auto-memory writes (Tier 2, automatic)
    │    Claude Code saves build commands, patterns,
    │    debugging insights to project memory
    │
    └──► /memory-sync (explicit trigger)
         │
         ├──► Session note → 5 Agent Memory/sessions/
         │    Structured summary with frontmatter
         │
         ├──► Pattern promotion → 5 Agent Memory/learnings/
         │    Recurring patterns get proposed as learnings
         │
         └──► Context update → 5 Agent Memory/_context.md
              Current priorities/state refreshed
```

### Ingest Flow (kb_ingest pattern)

The reverse direction — pulling Tier 2 auto-memory into Tier 3:

```
~/.claude/projects/<project>/memory/MEMORY.md
    │
    └──► /memory-sync --ingest
         │
         ├──► Reads auto-memory files
         ├──► Deduplicates against existing vault content
         ├──► Writes new items as session notes or learnings
         └──► Cleans stale auto-memory entries
```

---

## Multi-Agent Failover

The Obsidian vault (synced via Nextcloud) is the shared brain:

```
                    ┌──────────────┐
                    │  [your-vault-name] │
                    │  (Nextcloud) │
                    └──────┬───────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼─────┐ ┌───▼────┐ ┌────▼─────┐
        │ Claude.ai  │ │ Claude │ │ Future   │
        │ (MCP-Obs)  │ │ Code   │ │ Agent    │
        │            │ │(MCP-Obs│ │(file read│
        └────────────┘ └────────┘ └──────────┘
```

**Why this works without a KB server:**

- Obsidian vault is already synced across machines via Nextcloud
- MCP-Obsidian provides structured read/write from any Claude interface
- The frontmatter format means any agent can parse session notes programmatically
- No Express server, no VPS, no attack surface — just files and sync

**For agents without MCP-Obsidian** (e.g. Codex, Gemini via CLI):

- They can read vault files directly from the filesystem (Nextcloud sync)
- A lightweight wrapper script could expose search via `grep -r` + frontmatter parsing
- The structured format (YAML frontmatter + consistent headings) makes this trivial

---

## File Structures

### Global CLAUDE.md (`~/.claude/CLAUDE.md`)

This is the enforcement layer. Every Claude Code session, every project, reads this first.

See `global-claude-md.md` for the full file.

### Project CLAUDE.md Template (`.claude/CLAUDE.md`)

Each project gets a CLAUDE.md that references the global memory system and adds project-specific context.

See `project-claude-md-template.md` for the template.

### `/memory-sync` Slash Command

Custom slash command that consolidates session memory.

See `memory-sync-command.md` for the full command.

### `/memory-load` Slash Command

Lightweight command to pull relevant context from Obsidian at session start.

See `memory-load-command.md` for the full command.

---

## Vault Structure (Updated)

```
5 Agent Memory/
├── _context.md              # Current priorities, active projects, preferences
├── sessions/
│   ├── by-project/          # NEW: project-scoped session logs
│   │   ├── my-project/
│   │   │   ├── 2026-03-15-feature-planning.md
│   │   │   └── 2026-03-10-architecture-review.md
│   │   └── another-project/
│   └── general/             # Cross-project or ad-hoc sessions
│       └── 2026-03-17-memory-architecture.md
├── learnings/
│   ├── preferences/         # How the user likes things done
│   ├── technical/           # Technical patterns and decisions
│   ├── workflow/            # Process preferences
│   └── corrections/         # Things agents got wrong
├── working/                 # Agent scratchpad (unchanged)
└── project-index.md         # NEW: index of active projects with pointers
```

### Project Index (`project-index.md`)

Quick-reference for agents to find relevant context without searching everything:

```yaml
---
title: "Project Index"
modified: 2026-03-17
type: index
---
```

```markdown
## Active Projects

| Project | Vault Path | Last Session | Key Decisions |
|---------|-----------|--------------|---------------|
| My Web App | 1 Projects/my-web-app | 2026-03-15 | React, PostgreSQL |
| Infrastructure | 1 Projects/infrastructure | 2026-03-01 | Terraform, multi-account |

## Recently Active Areas

| Area | Recent Activity | Key Context |
|------|----------------|-------------|
| AWS | Infrastructure provisioning | Terraform modules |
| Web | Frontend rebuild | React 19 migration |
```

---

## Consolidation Pattern

The `/memory-sync` command doesn't just dump — it consolidates:

### Session → Learning Promotion

When `/memory-sync` detects a pattern appearing across 3+ sessions:

1. Agent proposes: "I've seen [pattern] across [sessions]. Promote to learning?"
2. The user approves/edits
3. Learning written to `learnings/` with `source_session` references
4. Original sessions get `promoted_to: learnings/[filename]` in frontmatter

### Staleness Detection

Sessions older than 90 days with `status: complete` and no `promoted_to` field get flagged for archive review. The `/memory-sync --tidy` variant handles this.

### Context Drift Prevention

The three-tier system prevents context drift because:

- **Hot** (session) is always fresh — it's the current conversation
- **Warm** (project) is scoped — only loads for the current project
- **Cold** (vault) is selective — agents search by project/area/tag, not load everything
- Consolidation prevents the "100 session notes that all say the same thing" problem

---

## Implementation Order

1. **Global CLAUDE.md** — immediate impact, forces memory behaviour everywhere
2. **`/memory-sync` slash command** — the bridge between auto-memory and vault
3. **`/memory-load` slash command** — lightweight context pull at session start
4. **Project index** — makes cross-project search efficient
5. **Vault restructure** — add `by-project/` to sessions, create project-index.md
6. **Multi-agent wrapper** — lightweight script for non-MCP agents to read vault

---

## What This Replaces vs Extends

| Current | New | Change |
|---------|-----|--------|
| agent-memory skill | Same skill, updated | Add project-scoping, consolidation patterns |
| No global CLAUDE.md | Global CLAUDE.md | Forces memory behaviour in every session |
| Manual session logging | `/memory-sync` | Structured, semi-automated |
| Flat sessions/ folder | `sessions/by-project/` | Better retrieval by project |
| No auto-memory bridge | `/memory-sync --ingest` | Pulls CC auto-memory into vault |
| Single agent | Vault as shared brain | Any MCP agent can participate |