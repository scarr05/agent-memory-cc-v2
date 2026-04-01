# Agent Memory for Claude Code

A hook-enforced persistent memory system that extends Claude Code with deterministic memory persistence across sessions, using Obsidian (via MCP-Obsidian) as the backing vault.

This is a configuration and tooling package — not a traditional software project with a build system.

**v3** introduces Obsidian CLI for token-efficient reads, Haiku subagents for retrieval (memberberry) and checkpoint capture (blackbox), a vendored read-once hook for source code deduplication, and slimmed CLAUDE.md templates.

## Why Hooks?

`CLAUDE.md` instructions are advisory. The model can choose to ignore them, forget them after compaction, or simply not follow through. Hooks are deterministic — they fire on every session start, before every compaction, and after every response. Memory operations happen reliably, not just when the model remembers to do them.

## Architecture

The system uses a three-tier design:

1. **Hooks** (shell scripts) — fire automatically on Claude Code events (SessionStart, PreCompact, Stop)
2. **Local staging** (`~/.claude/memory-staging/<slug>/`) — ephemeral bridge between hooks and MCP
3. **Obsidian vault** (`5 Agent Memory/`) — structured, permanent, cross-project storage

Hooks cannot call MCP directly. Instead, they write to local staging files and inject context into the conversation via JSON stdout. Claude then reads the staging files and pushes content to Obsidian through MCP-Obsidian.

See [docs/hooks-architecture.md](docs/hooks-architecture.md) for the full design document covering the hook-MCP bridge pattern, slug detection logic, and interaction flows.

### Subagents

| Agent | Model | Purpose |
|-------|-------|---------|
| `memberberry` | Haiku | Memory retrieval — progressive CLI search → filter → summarise |
| `blackbox` | Haiku | Session checkpoint — captures state before compaction |

Agent definitions live in `agents/` and are deployed to `~/.claude/agents/`.

### read-once Hook

A vendored PreToolUse hook that prevents redundant file re-reads within a session. Saves ~2,000 tokens per blocked re-read.

Vendored from [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once).

Configuration via environment variables — see `hooks/read-once/README.md`.

## Repository Structure

```
├── agents/
│   ├── memberberry.md          # Haiku subagent for vault retrieval via CLI
│   └── blackbox.md             # Haiku subagent for session checkpoint capture
├── hooks/
│   ├── session-start.sh        # Detect project slug, CLI-driven vault state, inject context
│   ├── pre-compact.sh          # Create checkpoint stub, clear read-once cache
│   ├── stop-memory.sh          # Track message count, nudge for /memory-sync at thresholds
│   └── read-once/
│       ├── hook.sh             # PreToolUse hook — block/warn on redundant file reads
│       └── README.md           # Configuration and integration docs
├── commands/
│   ├── memory-init.md          # One-time project setup and Obsidian folder creation
│   ├── memory-sync.md          # End-of-session sync to Obsidian vault
│   ├── memory-load.md          # Load prior context from vault for current project
│   └── decision.md             # Ad-hoc decision logging without full session sync
├── config/
│   ├── global-claude-md-v2.md  # Global CLAUDE.md with memory system rules
│   ├── settings.json           # Hook registration for Claude Code
│   ├── project-claude-md-template.md  # Template for per-project CLAUDE.md
│   └── decisions-template.md   # Template for per-project _decisions.md
├── docs/
│   ├── hooks-architecture.md   # Full system design document
│   ├── memory-architecture.md  # Architecture deep-dive and design decisions
│   ├── setup-guide-v2.md       # Step-by-step installation guide
│   ├── cli-setup.md            # Per-platform Obsidian CLI PATH setup
│   └── project-index-template.md  # Template for Obsidian project index
├── skills/obsidian-cli/        # Obsidian CLI command reference skill
│   └── SKILL.md
└── skills/agent-memory/        # Claude Code skill for memory operations
    ├── SKILL.md                # Skill definition — memory read/write patterns
    ├── INSTALL.md              # Skill installation instructions
    └── references/             # Templates and patterns for session/learning notes
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and working
- [MCP-Obsidian](https://github.com/smithery-ai/mcp-obsidian) server configured and connected
- An Obsidian vault with a `5 Agent Memory/` folder
- Obsidian 1.12+ with CLI enabled — see [docs/cli-setup.md](docs/cli-setup.md) for per-platform setup
- Claude Code with subagent support
- Max subscription (for Haiku subagent delegation)

## Quick Start

See [docs/setup-guide-v2.md](docs/setup-guide-v2.md) for full installation steps.

In short: hook scripts from `hooks/` go to `~/.claude/hooks/`, slash commands from `commands/` go to `~/.claude/commands/`, `config/settings.json` gets merged into `~/.claude/settings.json`, agent definitions from `agents/` go to `~/.claude/agents/`, and read-once hook from `hooks/read-once/` goes to `~/.claude/hooks/read-once/`.

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
4. **Stop hook** runs after each response, incrementing a message counter. At 15 and 30 messages (or after 45+ minutes), it nudges you to run `/memory-sync`. Also checks a 24-hour dream timer and sets a `.dream-pending` flag when consolidation is due.
5. **PreCompact hook** fires before context compaction, creating a checkpoint stub so nothing is lost when the context window is trimmed.
6. **`/memory-sync`** writes a structured session note to the Obsidian vault, proposes learnings, appends decisions to the project's `_decisions.md` log, and cleans up staging files.

## New Features

### Decisions Log (`_decisions.md`)

Per-project append-only log of significant decisions in lightweight ADR format. Each entry includes context, rationale, and a source link. Three routes to the log:

- **`/memory-sync`** — automatically extracts decisions from the session note and appends them
- **`/decision`** — ad-hoc decision logging without a full session sync
- **`/memory-init`** — backfills decisions from existing session notes on first run

### Codebase Analysis (`/memory-init`)

When initialising a brownfield project (git history detected), `/memory-init` can dispatch three subagents in parallel to analyse the codebase:

- **Structure** — key directories, entry points, module boundaries
- **Patterns** — naming conventions, error handling, testing approach
- **History** — areas of churn, trajectory, and inferred decisions from commit messages

Results populate the `## Architecture` section of the project CLAUDE.md. Inferred decisions can be seeded into `_decisions.md` after user confirmation.

### Dream Consolidation (`/memory-sync --dream`)

Deep consolidation that mines recent session transcripts (JSONL files) for decisions, corrections, and preferences that were never explicitly logged. Uses a token-efficient grep-first scanning strategy. Produces an approval report covering:

- New decisions and learnings found in transcripts
- Contradictions between new findings and existing vault records
- Stale sessions (90+ days) for archival
- Auto-memory ingest from Claude Code's built-in memory

The stop hook checks a 24-hour timer and the session-start hook nudges when dream consolidation is due. `--ingest` and `--tidy` are now aliases for dream phases 3 and 4.

## Troubleshooting

### `obsidian: command not found` in Claude Code (Windows)

Git Bash doesn't resolve `.com` extensions, so `obsidian` won't find `Obsidian.com` even when its directory is on PATH. Fix with both:

1. **Symlink:** `ln -s "/c/Program Files/Obsidian/Obsidian.com" ~/.local/bin/obsidian`
2. **Env var** in `~/.claude/settings.json`: `"OBSIDIAN_CLI_PATH": "/c/Program Files/Obsidian/Obsidian.com"`

See [docs/cli-setup.md](docs/cli-setup.md) for full details.

## Related Documentation

- [docs/hooks-architecture.md](docs/hooks-architecture.md) — System design document explaining the hook-MCP bridge pattern, detection logic, and interaction flows
- [docs/setup-guide-v2.md](docs/setup-guide-v2.md) — Step-by-step installation and daily workflow guide
- [docs/memory-architecture.md](docs/memory-architecture.md) — Architecture deep-dive and design decisions
