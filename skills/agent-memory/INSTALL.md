# Agent Memory — Skill Installation

This file covers the skill only. Hooks, slash commands, subagents, the Obsidian MCP server and the Obsidian CLI are set up in [`docs/setup-guide-v4.md`](../../docs/setup-guide-v4.md).

## Plugin install

Nothing to do. `claude --plugin-dir <clone-path>` loads this skill with the hooks, commands and subagents.

## Manual install

Copy the skill folder into your Claude Code skills directory, from the repo root:

```bash
mkdir -p ~/.claude/skills
cp -r skills/agent-memory skills/obsidian-cli ~/.claude/skills/
```

The skill is the instruction set; the hooks, commands and subagents are what enforce it. Without them it still works, but only as advice.

## Verify

1. Start Claude Code in a project: the first context should carry a `## Memory System Active` block from SessionStart.
2. Run `/memory-init` once per project.
3. Ask "what do you know about this project?": the agent should delegate to memberberry rather than search the vault itself.
