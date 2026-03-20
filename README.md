# Agent Memory for Claude Code

A hook-enforced persistent memory system that extends Claude Code with deterministic memory persistence across sessions, using Obsidian (via MCP-Obsidian) as the backing vault.

This is a configuration and tooling package — not a traditional software project with a build system.

## Why Hooks?

`CLAUDE.md` instructions are advisory. The model can choose to ignore them, forget them after compaction, or simply not follow through. Hooks are deterministic — they fire on every session start, before every compaction, and after every response. Memory operations happen reliably, not just when the model remembers to do them.

## Architecture

The system uses a three-tier design:

1. **Hooks** (shell scripts) — fire automatically on Claude Code events (SessionStart, PreCompact, Stop)
2. **Local staging** (`~/.claude/memory-staging/<slug>/`) — ephemeral bridge between hooks and MCP
3. **Obsidian vault** (`5 Agent Memory/`) — structured, permanent, cross-project storage

Hooks cannot call MCP directly. Instead, they write to local staging files and inject context into the conversation via JSON stdout. Claude then reads the staging files and pushes content to Obsidian through MCP-Obsidian.

See [docs/hooks-architecture.md](docs/hooks-architecture.md) for the full design document covering the hook-MCP bridge pattern, slug detection logic, and interaction flows.

## Repository Structure

```
├── hooks/
│   ├── session-start.sh        # Detect project slug, flag pending checkpoints, inject context
│   ├── pre-compact.sh          # Create checkpoint stub before context compaction
│   └── stop-memory.sh          # Track message count, nudge for /memory-sync at thresholds
├── commands/
│   ├── memory-init.md          # One-time project setup and Obsidian folder creation
│   ├── memory-sync.md          # End-of-session sync to Obsidian vault
│   └── memory-load.md          # Load prior context from vault for current project
├── config/
│   ├── global-claude-md-v2.md  # Global CLAUDE.md with memory system rules
│   ├── settings.json           # Hook registration for Claude Code
│   └── project-claude-md-template.md  # Template for per-project CLAUDE.md
├── docs/
│   ├── hooks-architecture.md   # Full system design document
│   ├── memory-architecture.md  # Architecture deep-dive and design decisions
│   ├── setup-guide-v2.md       # Step-by-step installation guide
│   └── project-index-template.md  # Template for Obsidian project index
└── skills/agent-memory/        # Claude Code skill for memory operations
    ├── SKILL.md                # Skill definition — memory read/write patterns
    ├── INSTALL.md              # Skill installation instructions
    └── references/             # Templates and patterns for session/learning notes
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [MCP-Obsidian](https://github.com/smithery-ai/mcp-obsidian) server configured and connected
- An Obsidian vault with a `5 Agent Memory/` folder

## Quick Start

See [docs/setup-guide-v2.md](docs/setup-guide-v2.md) for full installation steps.

In short: hook scripts from `hooks/` go to `~/.claude/hooks/`, slash commands from `commands/` go to `~/.claude/commands/`, and `config/settings.json` gets merged into `~/.claude/settings.json`.

## Vault Structure

```
5 Agent Memory/
├── _context.md
├── project-index.md
├── sessions/
│   ├── by-project/<slug>/
│   └── general/
├── learnings/
│   ├── preferences/
│   ├── technical/
│   ├── workflow/
│   └── corrections/
└── working/
```

- **sessions/** — timestamped session notes organised by project slug
- **learnings/** — extracted patterns, preferences, technical decisions, and corrections
- **working/** — scratch space for in-progress work

## How It Works

1. **SessionStart hook** fires when Claude Code opens a project. It detects the project slug (from CLAUDE.md metadata, git remote, manifest files, or directory name), checks for pending checkpoints, and injects prior context into the conversation.
2. **Claude searches Obsidian** for prior session notes and learnings relevant to the current project, picking up where previous sessions left off.
3. **You work normally.** The system stays out of the way during regular development.
4. **Stop hook** runs after each response, incrementing a message counter. At 15 and 30 messages (or after 45+ minutes), it nudges you to run `/memory-sync`.
5. **PreCompact hook** fires before context compaction, creating a checkpoint stub so nothing is lost when the context window is trimmed.
6. **`/memory-sync`** writes a structured session note to the Obsidian vault, proposes learnings, and cleans up staging files.

## Related Documentation

- [docs/hooks-architecture.md](docs/hooks-architecture.md) — System design document explaining the hook-MCP bridge pattern, detection logic, and interaction flows
- [docs/setup-guide-v2.md](docs/setup-guide-v2.md) — Step-by-step installation and daily workflow guide
- [docs/memory-architecture.md](docs/memory-architecture.md) — Architecture deep-dive and design decisions
