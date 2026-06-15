# Global Instructions

## Memory System (MANDATORY)

I use a three-tier persistent memory system backed by Obsidian ([your-vault-name]). Hooks enforce this automatically — you'll receive context injection from SessionStart telling you the project slug and any pending items.

### Hook-Injected Context

The SessionStart hook fires before your first response and injects:
- Current **project slug** (auto-detected from git/folder/CLAUDE.md)
- Any **pending checkpoints** from prior sessions (in `~/.claude/memory-staging/`)
- Whether `/memory-init` has been run for this project

**If the hook reports pending checkpoints:** read the staging files, write their content to Obsidian `5 Agent Memory/working/` via MCP, then delete the staging files.

**If the hook reports no memory config:** suggest running `/memory-init` before starting significant work.

### At Session Start (non-trivial tasks)

The hook gives you the slug and dynamic state. For prior context:

1. Delegate to the **memberberry** subagent — it searches the vault using the Obsidian CLI and returns a filtered summary.
2. Do NOT call MCP `search_notes` or read vault notes directly — memberberry handles this more efficiently via Haiku.
3. Briefly state what memberberry found and how it applies.
4. Do NOT read `5 Agent Memory/_context.md` unless you specifically need my current priorities.

### During Work

- Use `5 Agent Memory/working/` freely as scratchpad for in-progress state
- If the Stop hook nudges about session length, acknowledge it
- If context hits ~50%, delegate to **blackbox** subagent to capture a checkpoint before compaction
- The PreCompact hook creates a staging file automatically — blackbox can fill it or write its own checkpoint directly to the vault
- If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.

### Session End

When I run `/memory-sync`, follow that command's instructions. If I forget and the session was significant (decisions made, meaningful progress, direction changes), remind me.

### What Counts as Significant

Log sessions where: key decisions were made, meaningful progress occurred, a direction changed, planning completed, or a long session is approaching context limits. Don't log quick Q&A.

## Writing & Voice

- Never use AI slop: "dive into", "leverage", "it's important to note", "game-changer", "robust", "seamless"
- British English spelling (organisation, colour, behaviour)
- I have a unified voice skill and humaniser skill — use them when writing content for me
- Tables over bullet lists for comparisons
- Be direct and concise. If something's shit, say so.

## Technical Preferences

- Terraform over CloudFormation (always)
- Deterministic scripting over agentic approaches where reliability matters
- SQLite over heavy databases for local tooling
- Python for scripts, Node.js for services
- draw.io for architecture diagrams (I have a skill for this)

## Tools Available

### Obsidian CLI (reads — used by subagents)

Requires Obsidian 1.12+ with CLI enabled. Used by memberberry and blackbox subagents for token-efficient vault reads.

Key commands: `search`, `search:context`, `property:read`, `read`, `backlinks`, `links`, `tasks`, `create`, `append`

### MCP-Obsidian (writes — and fallback reads)

- **Writes:** write_note, patch_note, update_frontmatter, move_note, manage_tags
- **Reads (fallback if subagents unavailable):** read_note, search_notes, get_frontmatter, list_directory, read_multiple_notes, get_notes_info

### Subagents

- **memberberry** — Memory retrieval. Delegate all vault read operations here.
- **blackbox** — Session checkpoint capture before compaction.

### Context7

- **Context7**: resolve-library-id, get-library-docs (USE THIS for any library/framework docs — don't rely on training data)

## Memory File Paths

```
~/.claude/memory-staging/<slug>/       # Hook staging (local, ephemeral)
    .session-meta                      # Message count, timestamps
    checkpoint-*.md                    # Pre-compaction checkpoints

5 Agent Memory/sessions/by-project/<slug>/  # Obsidian (permanent)
5 Agent Memory/learnings/                   # Cross-project knowledge
5 Agent Memory/working/                     # Agent scratchpad
5 Agent Memory/project-index.md             # Project quick-reference
```

## Vault Structure

```
[your-vault-name]/
├── 0 Daily Notes/
├── 1 Projects/
├── 2 Areas of Interest/
├── 3 Resources/
├── 4 Archive/
├── 5 Agent Memory/
│   ├── _context.md
│   ├── sessions/by-project/ and sessions/general/
│   ├── learnings/ (preferences/ technical/ workflow/ corrections/)
│   ├── working/
│   └── project-index.md
└── _Inbox/
```

## Rules

1. When writing to Obsidian, ALWAYS include proper YAML frontmatter
2. When writing code that uses libraries, ALWAYS use Context7 first
3. Never write to `learnings/` without my approval — propose first
4. Use `working/` freely, but clean up when done
5. If MCP-Obsidian isn't responding, tell me — don't silently skip memory operations
6. Process staging files before they pile up — the hooks create them, you clean them up
