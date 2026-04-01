---
description: "Load relevant context from Obsidian vault for the current project. Use at session start or when switching to a different area of work. Lightweight alternative to manually searching memory."
user-invocable: true
allowed-tools:
  - "obsidian:read_note"
  - "obsidian:search_notes"
  - "obsidian:get_frontmatter"
  - "obsidian:list_directory"
  - "obsidian:read_multiple_notes"
  - "obsidian:get_notes_info"
---

# /memory-load

Pull relevant context from the Obsidian vault for the current task. $ARGUMENTS

## Behaviour

If $ARGUMENTS is provided, use it as the search topic. Otherwise, infer from:
1. The current project directory name
2. The project CLAUDE.md
3. The most recent conversation context

## Steps

### 0. Restore Memory Context

Before loading Obsidian context, restore the hook-level context that SessionStart normally provides.

#### 0.1 Read State File

```bash
cat .claude/memory-state.json 2>/dev/null || echo "NOT FOUND"
```

If the state file exists, use its values:
- `slug` → project slug for all subsequent searches
- `area` → Obsidian area
- `sessionPath` → where to find sessions
- `pendingCheckpoints` → files to process
- `dreamPending` → whether to nudge for dream consolidation

If the state file does NOT exist, fall back to detecting the slug:
1. Check `.claude/CLAUDE.md` for `<!-- memory:project-slug=X -->`
2. Check git remote origin
3. Use directory name
Warn the user: "State file missing — using auto-detected slug. Consider running `/memory-init` to set up properly."

#### 0.2 Check Pending Checkpoints

```bash
ls ~/.claude/memory-staging/<slug>/checkpoint-*.md 2>/dev/null
```

If any exist, list them and remind to process to Obsidian `5 Agent Memory/working/`.

#### 0.3 Check Dream Status

If `dreamPending` is true in the state file (or `~/.claude/memory-staging/<slug>/.dream-pending` exists), note: "Dream consolidation pending — run `/memory-sync --dream` when ready."

#### 0.4 Present Context Block

Output a summary matching the SessionStart format:

```
## Memory System Active (restored via /memory-load)
Project slug: `<slug>`
Area: `<area>`
Obsidian session path: `<sessionPath>`
[pending checkpoints if any]
[dream status if pending]
```

Then continue with the normal Obsidian context loading below.

### 1. Identify Context Needed

Use the project slug from Step 0. If $ARGUMENTS is provided, use it as an additional search topic alongside the slug.

### 2. Check Project Index

```
read_note("5 Agent Memory/project-index.md")
```

Find the relevant project row. Note last session date and key decisions.

### 3. Load Recent Sessions

```
search_notes(query="<project-name>", searchContent=true)
```

Search `5 Agent Memory/sessions/by-project/<project-slug>/` for the most recent 2-3 sessions.

Use `get_frontmatter` first to scan dates and status — only read full content of the most recent resumable session and the most recent completed session.

### 4. Load Relevant Learnings

```
search_notes(query="<project-name OR technology>", searchContent=true)
```

Search `5 Agent Memory/learnings/` for anything tagged with the current project or technology area.

### 5. Check Working Files

```
list_directory("5 Agent Memory/working/")
```

If there are any active working files for this project, read them — they might contain in-progress state from a prior session.

### 6. Summarise

Present a concise summary to the user:

**Format:**
```
## Memory Loaded: <Project>

**Last session:** <date> — <brief summary>
**Status:** <resumable/complete/blocked>
**Key decisions:** <list>
**Open items:** <list>
**Relevant learnings:** <list>

Ready to continue. What are we working on?
```

Keep the summary SHORT. Don't dump entire session notes. The goal is enough context to avoid re-explaining, not a full history lesson.

### 7. If Nothing Found

If no relevant memory exists, say so cleanly:

"No prior sessions found for <project>. Starting fresh. I'll log this session when we're done if it's significant."

Don't treat missing memory as an error — it just means this is the first session on this topic.