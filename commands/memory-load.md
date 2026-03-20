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

### 1. Identify Context Needed

Determine the project/topic to search for. Be specific — use the project slug rather than vague terms.

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