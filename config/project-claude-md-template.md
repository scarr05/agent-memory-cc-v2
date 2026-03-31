# <Project Name>

<!-- memory:project-slug=<slug> -->
<!-- memory:area=<area> -->

## Architecture

<2-4 sentences. Stack, structure, key patterns.>

## Conventions

- <Code style, tooling choices, naming conventions>
- <Testing approach>
- <Key dependencies>

## Structure

```
<Top 2 levels of project directory tree>
```

## Memory

- **Obsidian sessions:** `5 Agent Memory/sessions/by-project/<slug>/`
- Use **memberberry** agent for prior context retrieval
- Use **blackbox** agent for checkpoint capture before compaction
- Do NOT call MCP search_notes or read vault notes directly
- SessionStart hook provides current state automatically

## Project-Specific Rules

<Any rules specific to this project.>
