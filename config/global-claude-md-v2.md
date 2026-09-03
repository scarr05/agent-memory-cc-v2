# Global Instructions

## Memory System (MANDATORY)

I use a three-tier persistent memory system backed by Obsidian ([your-vault-name]). Hooks enforce this automatically — you'll receive context injection from SessionStart telling you the project slug and any pending items.

### Hook-Injected Context

The SessionStart hook fires before your first response and injects:
- Current **project slug** (auto-detected from git/folder/CLAUDE.md)
- Any **pending handoff** from a prior `/handoff` + `/clear` (in `~/.claude/memory-staging/<slug>/handoff.md`)
- Whether `/memory-init` has been run for this project

**If the hook injects a pending handoff:** it is loaded automatically as `additionalContext` and renamed `handoff.consumed.md` — you do not need to process it manually. The handoff was written by `/handoff` and is cleaned up by `/memory-sync`.

**If the hook reports no memory config:** suggest running `/memory-init` before starting significant work.

### At Session Start (non-trivial tasks)

The hook gives you the slug and dynamic state. For prior context:

1. Delegate to the **memberberry** subagent — it searches the vault using the Obsidian CLI and returns a filtered summary.
2. Do NOT call MCP vault search or read vault notes directly — memberberry handles this more efficiently via Haiku.
3. Briefly state what memberberry found and how it applies.
4. Do NOT read `5 Agent Memory/_context.md` unless you specifically need my current priorities.

### During Work

- Use `5 Agent Memory/working/` freely as scratchpad for in-progress state
- If the Stop hook nudges about session length, acknowledge it
- If the UserPromptSubmit hook surfaces a logged correction (it fires when my prompt touches that topic), honour it — it flags a past mistake I don't want repeated
- When the session grows large (the Stop hook nudges around ~150k tokens, configurable via `memory.handoffTokenThreshold`), run `/handoff` to capture the current work unit, then `/clear` and continue in a fresh session — it auto-loads the handoff. Avoid relying on compaction; it stays on only as a dormant safety net.
- If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.

### Session End

When I run `/memory-sync`, follow that command's instructions. If I forget and the session was significant (decisions made, meaningful progress, direction changes), remind me. The SessionEnd hook backs this up: a real-length session (≥10 messages) that ends without `/memory-sync` writes a `.unsynced` flag, and the next SessionStart surfaces a ⚠ "never synced" warning — when you see it, prompt me to sync.

### What Counts as Significant

Log sessions where: key decisions were made, meaningful progress occurred, a direction changed, planning completed, or a long session is approaching context limits. Don't log quick Q&A.

### Dream Consolidation

Roughly every 24 hours the Stop hook surfaces a 💤 dream-pending nudge. When you see it (or when I ask), run `/memory-sync --dream` — it mines recent transcripts for un-logged decisions, corrections, and preferences, cross-references the vault, flags contradictions, and prunes stale sessions. It never writes without my approval — present the dream report first.

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

### Obsidian MCP (writes — and fallback reads)

Commands describe vault operations as verbs; map them to whichever server is registered as `obsidian`:

| Verb used in `commands/` | MCP-Obsidian (`@mauricio.wolff/mcp-obsidian`) | Local REST API plugin (v5+) |
|---|---|---|
| read note | `read_note` | `vault_read` |
| read frontmatter only | `get_frontmatter` | `vault_read` (`targetType="frontmatter"`) |
| list folder | `list_directory` | `vault_list` |
| write note | `write_note` | `vault_write` |
| append to note | `patch_note` (old→new at end of file) | `vault_append` |
| patch note | `patch_note` (literal old→new) | `vault_patch` (heading / block / frontmatter) |
| update frontmatter | `update_frontmatter` | `vault_patch` (`targetType="frontmatter"`) |
| search vault | `search_notes` | `search_simple` |
| search vault frontmatter | `search_notes` (`searchFrontmatter=true`) | `search_query` (JsonLogic) |
| move / delete note | `move_note` / `delete_note` | `vault_move` / `vault_delete` |

### Subagents

- **memberberry** — Memory retrieval. Delegate all vault read operations here.
- **blackbox** — Session checkpoint capture on explicit save-progress requests.

### Context7

- **Context7**: resolve-library-id, get-library-docs (USE THIS for any library/framework docs — don't rely on training data)

## Memory File Paths

```
~/.claude/memory-staging/<slug>/       # Hook staging (local, ephemeral)
    .session-meta                      # Message count, timestamps
    handoff.md                         # Current-work-unit scratch (written by /handoff)
    handoff.consumed.md                # Renamed by SessionStart after injection

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
5. If the Obsidian MCP server isn't responding, tell me — don't silently skip memory operations. It runs inside Obsidian, so it needs the app open.
6. Process staging files before they pile up — the hooks create them, you clean them up
