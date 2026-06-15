---
name: obsidian-cli
description: "Reference for Obsidian CLI commands used by the agent memory system. Use when you need to interact with the Obsidian vault via CLI — searching notes, reading properties, checking tasks, or creating content. Requires Obsidian 1.12+ with CLI enabled. Triggers on: Obsidian CLI commands, vault search, vault tasks, note properties, CLI troubleshooting."
---

# Obsidian CLI Reference

Command reference for Obsidian CLI 1.12+ as used by the agent memory system.

## CLI Binary

```bash
${OBSIDIAN_CLI_PATH:-obsidian}
```

On Windows, Obsidian registers `Obsidian.com` (terminal redirector) on PATH.
If the bare command fails, check `docs/cli-setup.md` for platform-specific setup.

## Search Commands

### search — Find notes by content (paths only)

```bash
obsidian search query="<text>" path="<folder>" format=json limit=<n>
```

Returns JSON array of matching file paths. Cheapest search — start here.

**Options:** `total` (count only), `case` (case sensitive)

### search:context — Matching lines with context

```bash
obsidian search:context query="<text>" path="<folder>" format=json limit=<n>
```

Returns JSON array of `{file, matches: [{line, text}]}`. Use to assess
relevance without loading full notes.

## Property Commands

### property:read — Read frontmatter field

```bash
obsidian property:read name="<field>" path="<file>"
```

Returns raw value. Use for `decisions`, `follow_up`, `status`, `tags`.

### property:set — Set frontmatter field

```bash
obsidian property:set name="<field>" value="<value>" path="<file>"
```

## File Commands

### read — Full note content

```bash
obsidian read path="<file>"
```

Returns full markdown content. **Last resort** — use search:context
and property:read first.

### create — Create a new note

```bash
obsidian create path="<path>" content="<text>"
obsidian create path="<path>" content="<text>" overwrite
```

### append — Append to a note

```bash
obsidian append path="<path>" content="<text>"
```

### outline — Heading structure

```bash
obsidian outline path="<file>" format=json
```

Returns heading tree without content. Useful for large notes.

## Graph Commands

### backlinks — Incoming links

```bash
obsidian backlinks path="<file>" format=json counts
```

### links — Outgoing links

```bash
obsidian links path="<file>"
```

## Task Commands

### tasks — List tasks

```bash
obsidian tasks path="<file>" todo format=json
```

**Important:** Requires a file path, not a folder path. To find tasks
across a folder, use `search:context query="- [ ]" path="<folder>"`.

## Tag Commands

### tags — List tags

```bash
obsidian tags path="<file>" counts format=json
```

## Daily Note Commands

### daily:append — Append to daily note

```bash
obsidian daily:append content="<text>"
```

### daily:read — Read daily note

```bash
obsidian daily:read
```

## Vault Info

```bash
obsidian version
obsidian vault
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `command not found` | Check PATH setup — see `docs/cli-setup.md` |
| `Obsidian is not running` | Open Obsidian app first |
| `folder, not a file` | Use `search:context` instead of `tasks` for folder-level queries |
| Slow response | Obsidian may be starting up — first command launches the app |
