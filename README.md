# Agent Memory for Claude Code

A hook-enforced persistent memory system that extends Claude Code with deterministic memory persistence across sessions, using Obsidian (via MCP-Obsidian) as the backing vault.

This is a configuration and tooling package — not a traditional software project with a build system.

**v3** introduced the Obsidian CLI for token-efficient reads, Haiku subagents for retrieval (memberberry) and checkpoint capture (blackbox), a vendored read-once hook for source-code deduplication, and slimmed CLAUDE.md templates.

**v4** corrects the hook output schemas to the form Claude Code actually reads, adds two hooks (SessionEnd flags unsynced sessions; UserPromptSubmit surfaces corrections just-in-time), redesigns the compaction handoff (PreCompact writes a stub, SessionStart picks it up with `source=compact`), gives the subagents native memory, sets per-hook performance budgets, and packages everything as an installable plugin.

## Why Hooks?

`CLAUDE.md` instructions are advisory. The model can choose to ignore them, forget them after compaction, or simply not follow through. Hooks are deterministic — they fire on every session start and end, before every compaction, on every prompt, and after every response. Memory operations happen reliably, not just when the model remembers to do them.

## Architecture

The system uses a three-tier design:

1. **Hooks** (shell scripts) — fire automatically on Claude Code events (SessionStart, PreToolUse, PreCompact, Stop, SessionEnd, UserPromptSubmit)
2. **Local staging** (`~/.claude/memory-staging/<slug>/`) — ephemeral bridge between hooks and MCP
3. **Obsidian vault** (`5 Agent Memory/`) — structured, permanent, cross-project storage

Hooks cannot call MCP directly. Instead, they write to local staging files and inject context into the conversation via JSON stdout. Claude then reads the staging files and pushes content to Obsidian through MCP-Obsidian.

See [docs/hooks-architecture.md](docs/hooks-architecture.md) for the full design document covering the hook-MCP bridge pattern, slug detection logic, and interaction flows.

### Subagents

| Agent | Model | Purpose |
|-------|-------|---------|
| `memberberry` | Haiku | Memory retrieval — progressive CLI search → filter → summarise |
| `blackbox` | Haiku | Session checkpoint — captures state before compaction |

Agent definitions live in `agents/` and are deployed to `~/.claude/agents/`. In v4 both carry native subagent memory: memberberry `memory: user` (cross-project search strategy), blackbox `memory: project` (per-project checkpoint and merge context).

### read-once Hook

A vendored PreToolUse hook that prevents redundant file re-reads within a session. Saves ~2,000 tokens per blocked re-read.

Vendored from [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once).

Configuration via environment variables — see `hooks/read-once/README.md`.

## Repository Structure

```
├── .claude-plugin/
│   └── plugin.json             # Plugin manifest (name, version, description)
├── agents/
│   ├── memberberry.md          # Haiku subagent for vault retrieval via CLI (memory: user)
│   └── blackbox.md             # Haiku subagent for session checkpoint capture (memory: project)
├── hooks/
│   ├── hooks.json              # Plugin hook registration (${CLAUDE_PLUGIN_ROOT} paths)
│   ├── session-start.sh        # SessionStart — slug, vault state, context injection, compaction handoff
│   ├── pre-compact.sh          # PreCompact — write checkpoint stub, clear read-once cache
│   ├── stop-memory.sh          # Stop — track message count, nudge for /memory-sync, dream timer
│   ├── session-end.sh          # SessionEnd — flag a session that ended without /memory-sync
│   ├── prompt-corrections.sh   # UserPromptSubmit — surface a logged correction in context
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
│   ├── setup-guide-v4.md       # v4 installation — plugin + manual
│   ├── setup-guide-v2.md       # Older manual-only installation guide
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

See [docs/setup-guide-v4.md](docs/setup-guide-v4.md) for full installation steps — plugin install (recommended) or manual copy.

**Plugin:** `claude --plugin-dir <clone-path>` loads the hooks, subagents, and commands in one go.

**Manual:** hook scripts from `hooks/` go to `~/.claude/hooks/` (including `read-once/`), slash commands from `commands/` go to `~/.claude/commands/`, `config/settings.json` gets merged into `~/.claude/settings.json`, and agent definitions from `agents/` go to `~/.claude/agents/`.

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

1. **SessionStart hook** fires when Claude Code opens a project. It detects the project slug (from CLAUDE.md metadata, git remote, manifest files, or directory name), checks for pending checkpoints, flags any prior session that ended without a sync, and injects prior context via `hookSpecificOutput.additionalContext`. When the session restarts after compaction (`source=compact`) it runs the checkpoint handoff.
2. **Claude searches Obsidian** for prior session notes and learnings relevant to the current project, picking up where previous sessions left off.
3. **UserPromptSubmit hook** runs on each prompt. If the prompt touches a topic with a logged correction, it surfaces a one-line pointer so the correction is loaded before Claude acts.
4. **You work normally.** The system stays out of the way during regular development. The read-once PreToolUse hook quietly blocks redundant file re-reads.
5. **Stop hook** runs after each response, incrementing a message counter. At 15 and 30 messages (or after 45+ minutes), it nudges you to run `/memory-sync`. It also checks a 24-hour dream timer and sets a `.dream-pending` flag when consolidation is due.
6. **PreCompact hook** fires before context compaction, writing a checkpoint stub to staging (a side effect only — it injects nothing). The post-compaction SessionStart surfaces the stub and directs blackbox to fill it, so nothing is lost when the context window is trimmed.
7. **SessionEnd hook** fires when the session ends. If a real-length session ended without `/memory-sync` (and wasn't a deliberate `/clear`), it writes an `.unsynced` flag that the next SessionStart surfaces.
8. **`/memory-sync`** writes a structured session note to the Obsidian vault, proposes learnings, appends decisions to the project's `_decisions.md` log, marks the session synced, and cleans up staging files.

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
