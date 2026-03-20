# Hooks-Enforced Memory System

## The Problem with CLAUDE.md-Only Enforcement

CLAUDE.md instructions are advisory — the model can ignore them, especially after compaction or in long sessions where context drift kicks in. Hooks are deterministic. They fire every time, regardless of what the model decides to do.

## Hook Strategy

Three hooks enforce the memory system programmatically:

| Hook Event | Purpose | Type |
|-----------|---------|------|
| **SessionStart** | Detect project, inject context pointer, validate setup | command |
| **PreCompact** | Checkpoint session state to Obsidian before context shrinks | command |
| **Stop** | Log session metadata, nudge for /memory-sync if significant | command |

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

1. **Detect project slug** — reads `.claude/CLAUDE.md` for the `memory:project-slug` comment. If missing, falls back through detection priority chain.
2. **Validate Obsidian structure** — checks if `5 Agent Memory/sessions/by-project/<slug>/` exists (via file check if vault is locally synced).
3. **Inject context pointer** — outputs `additionalContext` telling Claude where to find memory and what slug to use.
4. **Flag if uninitialised** — if no slug found, context tells Claude to suggest running `/memory-init`.

### Why SessionStart, Not UserPromptSubmit

SessionStart fires once. UserPromptSubmit fires on every message — too expensive for memory loading. The SessionStart hook just injects a pointer; the actual Obsidian reads happen via MCP when Claude acts on that pointer.

---

## Hook 2: PreCompact

**File:** `~/.claude/hooks/pre-compact.sh`

Fires before context compaction. This is the safety net — if the session gets long and auto-compacts, we don't lose state.

### What It Does

1. **Read project slug** from `.claude/CLAUDE.md`
2. **Write checkpoint** — creates a timestamped checkpoint file in a local staging area (`~/.claude/memory-staging/<slug>/`)
3. **Inject context** — tells Claude that a pre-compaction checkpoint was saved and to write it to Obsidian working/ when it gets a chance

### Why Local Staging, Not Direct Obsidian Write

Hooks are shell commands — they can't call MCP-Obsidian directly. So the hook writes to a local staging directory that Claude Code can then pick up and push to Obsidian. The SessionStart hook also checks for unstaged checkpoints and reminds Claude to process them.

---

## Hook 3: Stop

**File:** `~/.claude/hooks/stop-memory.sh`

Fires when Claude finishes responding. Lightweight session tracking.

### What It Does

1. **Increment message counter** — tracks message count in `~/.claude/memory-staging/<slug>/.session-meta`
2. **Check significance threshold** — if message count > 10 OR session duration > 30 minutes, flag as potentially significant
3. **Inject nudge** — if significant, adds context: "This session looks substantial. Consider running /memory-sync before ending."

### Why Not Auto-Write Sessions on Stop

The Stop hook fires on EVERY response, not just session end. Auto-writing would create noise. Instead, it tracks and nudges. The human decides when to sync.

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

5. **Check for unstaged memory** — look in `~/.claude/memory-staging/<slug>/` for any checkpoints from prior sessions that never got synced

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
├── commands/
│   ├── memory-sync.md                     # /memory-sync slash command
│   ├── memory-load.md                     # /memory-load slash command
│   └── memory-init.md                     # /memory-init slash command
├── hooks/
│   ├── session-start.sh                   # SessionStart hook
│   ├── pre-compact.sh                     # PreCompact hook
│   └── stop-memory.sh                     # Stop hook
├── memory-staging/                        # Local staging for hook → MCP bridge
│   ├── my-project/
│   │   ├── .session-meta                  # Message count, timestamps
│   │   └── checkpoint-2026-03-17T14:30.md # Pre-compaction checkpoint
│   └── cairn/
└── settings.json                          # Hook configuration
```

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
type: checkpoint|session-meta|nudge
project-slug: my-project
created: 2026-03-17T14:30:00Z
---

## Session State
<content that needs to be written to Obsidian>
```

The SessionStart hook checks for pending staging files and injects context telling Claude to process them. This closes the loop without requiring MCP access from shell scripts.

---

## Settings.json Configuration

The hooks are registered in `~/.claude/settings.json` (user-level, applies to all projects):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/session-start.sh"
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-compact.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-memory.sh"
          }
        ]
      }
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
6. PreCompact fires if session gets long → checkpoints to staging
7. Stop fires after each response → tracks message count
8. User runs /memory-sync at end → structured session note to Obsidian
```

### Returning to an Existing Project

```
1. User opens Claude Code in ~/projects/my-project/
2. SessionStart hook fires:
   - Reads .claude/CLAUDE.md → slug=my-project, area=AWS
   - Checks staging → finds checkpoint from yesterday's session
   - Injects context:
     "Project: my-project (AWS)
      Unstaged checkpoint from 2026-03-16 — process to Obsidian.
      Prior sessions available — run /memory-load for context."
3. Claude processes checkpoint → writes to Obsidian working/
4. User types: /memory-load
5. Context loaded from prior sessions
6. Work continues with full context
```

---

## Performance Considerations

- **SessionStart hook:** ~100ms (file reads only, no network)
- **PreCompact hook:** ~200ms (one file write to local disk)
- **Stop hook:** ~50ms (increment counter in a file)
- **Total overhead:** Negligible. All hooks are local file operations.

The expensive operations (MCP-Obsidian reads/writes) happen in Claude's turn, not in the hooks. This keeps the hooks fast and the memory operations in the model's control.
