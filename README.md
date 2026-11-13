# Agent Memory for Claude Code

**Codex:** A separate adapter supports the same Obsidian vault through a user-level skill and global `AGENTS.md` instructions. See [Codex setup and review](docs/codex-setup.md). The adapter does not install the Claude lifecycle hooks.

A hook-enforced persistent memory system that extends Claude Code with deterministic memory persistence across sessions, using Obsidian as the backing vault (reads via the Obsidian CLI, writes via an Obsidian MCP server).

This is a configuration and tooling package — not a traditional software project with a build system.

**v3** introduced the Obsidian CLI for token-efficient reads, Haiku subagents for retrieval (memberberry) and checkpoint capture (blackbox), a vendored read-once hook for source-code deduplication, and slimmed CLAUDE.md templates.

**v4** corrects the hook output schemas to the form Claude Code actually reads, adds two hooks (SessionEnd flags unsynced sessions; UserPromptSubmit surfaces corrections just-in-time), replaces the old checkpoint-stub mechanism with the handoff workflow (`/handoff` → `/clear`, with SessionStart harvesting the compaction summary into a handoff on `source=compact`), gives the subagents native memory, sets per-hook performance budgets, and packages everything as an installable plugin.

## Why Hooks?

`CLAUDE.md` instructions are advisory. The model can choose to ignore them, forget them after compaction, or simply not follow through. Hooks are deterministic — they fire on every session start and end, before every compaction, on every prompt, and after every response. Memory operations happen reliably, not just when the model remembers to do them.

## Architecture

The system has three layers (not to be confused with the hot/warm/cold memory tiers in [docs/hooks-architecture.md](docs/hooks-architecture.md)):

1. **Hooks** (shell scripts) — fire automatically on Claude Code events (SessionStart, PreToolUse, PreCompact, Stop, SessionEnd, UserPromptSubmit)
2. **Local staging** (`~/.claude/memory-staging/<slug>/`) — ephemeral hook state: handoff scratch, per-session counters, flags
3. **Obsidian vault** (`5 Agent Memory/`) — structured, permanent, cross-project storage

Hooks cannot call MCP. They keep their state in local staging (handoff scratch, per-session counters, flags) and inject context via JSON stdout; `/memory-sync` writes the vault note through the Obsidian MCP server and clears the handoff scratch.

See [docs/hooks-architecture.md](docs/hooks-architecture.md) for the full design document covering the hook-MCP bridge pattern, slug detection logic, and interaction flows.

### Subagents

| Agent | Model | Purpose |
|-------|-------|---------|
| `memberberry` | Haiku | Memory retrieval — progressive CLI search → filter → summarise |
| `blackbox` | Haiku | Session checkpoint — captures state on an explicit "save progress" request |

Agent definitions live in `agents/` and are deployed to `~/.claude/agents/`. In v4 both carry native subagent memory: memberberry `memory: user` (cross-project search strategy), blackbox `memory: project` (per-project checkpoint and merge context).

### read-once Hook

A vendored PreToolUse hook that flags redundant file re-reads within a session. The default `warn` mode only advises; `READ_ONCE_MODE=deny` blocks them, saving ~2,000 tokens per blocked re-read.

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
│   ├── pre-compact.sh          # PreCompact — clear read-once cache (checkpoint stubs retired)
│   ├── stop-memory.sh          # Stop — track message count, nudge for /memory-sync and /handoff
│   ├── session-end.sh          # SessionEnd — flag a session that ended without /memory-sync
│   ├── prompt-corrections.sh   # UserPromptSubmit — surface a logged correction in context
│   ├── handoff-lib.sh          # Sourced library — handoff build/harvest functions
│   ├── slug-lib.sh             # Sourced library — the one slug lookup
│   ├── state-lib.sh            # Sourced library — session state paths, command flags, auto marker
│   └── read-once/
│       ├── hook.sh             # PreToolUse hook — block/warn on redundant file reads
│       └── README.md           # Configuration and integration docs
├── commands/
│   ├── memory-init.md          # One-time project setup and Obsidian folder creation
│   ├── memory-sync.md          # End-of-session sync to Obsidian vault
│   ├── memory-load.md          # Load prior context from vault for current project
│   ├── handoff.md              # Capture the current work unit before /clear
│   └── decision.md             # Ad-hoc decision logging without full session sync
├── config/
│   ├── global-claude-md-v2.md  # Global CLAUDE.md with memory system rules
│   ├── settings.json           # Hook registration for Claude Code
│   ├── project-claude-md-template.md  # Template for per-project CLAUDE.md
│   └── decisions-template.md   # Template for per-project _decisions.md
├── docs/
│   ├── hooks-architecture.md   # Full system design document
│   ├── setup-guide-v4.md       # v4 installation — plugin + manual
│   ├── cli-setup.md            # Per-platform Obsidian CLI PATH setup
│   ├── codex-setup.md          # Codex adapter setup
│   └── project-index-template.md  # Template for Obsidian project index
├── codex/                      # Codex adapter: installer, skill, global AGENTS.md block
├── tests/
│   ├── hook-validation.sh      # Tier 1 hook validation
│   ├── handoff-lib-test.sh     # Handoff library and hook unit tests
│   ├── test_memory_hooks.py    # pytest harness: hooks and command bash blocks in a temp HOME
│   └── playbook.md             # Manual session-level tests
├── skills/obsidian-cli/        # Obsidian CLI command reference skill
│   └── SKILL.md
└── skills/agent-memory/        # Claude Code skill for memory operations
    ├── SKILL.md                # Skill definition — memory read/write patterns
    ├── INSTALL.md              # Skill installation instructions
    └── references/             # Templates and patterns for session/learning notes
```

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed and working
- An Obsidian MCP server configured and connected — [MCPVault](https://github.com/bitbonsai/mcpvault) is the recommended one and works with Obsidian closed; the [Local REST API](https://github.com/coddingtonbear/obsidian-local-rest-api) plugin (v5+) is the alternative (structural patching and metadata search, but needs Obsidian running). See [docs/setup-guide-v4.md](docs/setup-guide-v4.md#obsidian-mcp-server)
- An Obsidian vault with a `5 Agent Memory/` folder
- Obsidian 1.12+ with CLI enabled — see [docs/cli-setup.md](docs/cli-setup.md) for per-platform setup
- Claude Code with subagent support
- Max subscription (for Haiku subagent delegation)

## Quick Start

See [docs/setup-guide-v4.md](docs/setup-guide-v4.md) for full installation steps — plugin install (recommended) or manual copy.

**Plugin:** `claude --plugin-dir <clone-path>` loads the hooks, subagents, and commands in one go.

**Manual:** hook scripts from `hooks/` go to `~/.claude/hooks/` (including `read-once/`), slash commands from `commands/` go to `~/.claude/commands/`, `config/settings.json` gets merged into `~/.claude/settings.json`, agent definitions from `agents/` go to `~/.claude/agents/`, the two skills from `skills/` go to `~/.claude/skills/`, and `config/global-claude-md-v2.md` is merged into `~/.claude/CLAUDE.md`.

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

1. **SessionStart hook** fires when Claude Code opens a project. It detects the project slug (from CLAUDE.md metadata, git remote, manifest files, or directory name), checks for a pending handoff, flags any prior session that ended without a sync, and injects prior context via `hookSpecificOutput.additionalContext`. On a full start it also checks the 24-hour dream timer and sets `.dream-pending` when consolidation is due. When the session restarts after compaction (`source=compact`) it harvests the compaction summary into a handoff and injects it.
2. **Claude searches Obsidian** for prior session notes and learnings relevant to the current project, picking up where previous sessions left off.
3. **UserPromptSubmit hook** runs on each prompt. If the prompt touches a topic with a logged correction, it surfaces a one-line pointer so the correction is loaded before Claude acts.
4. **You work normally.** The system stays out of the way during regular development. The read-once PreToolUse hook flags redundant file re-reads (advisory by default; `READ_ONCE_MODE=deny` blocks them).
5. **Stop hook** runs after each response, incrementing a message counter. At 15 and 30 messages (or after 45+ minutes), it nudges you to run `/memory-sync`. Past 8 exchanges it also reads the live token count and nudges once for `/handoff` then `/clear` at `memory.handoffTokenThreshold` (default 150000).
6. **PreCompact hook** fires before context compaction. It only clears the read-once cache and injects nothing — checkpoint stubs are retired. Continuity comes from the handoff workflow: the post-compaction SessionStart (`source=compact`) harvests Claude Code's own compaction summary into a handoff scratch file and injects it, so the trimmed session can pick up where it left off. The preferred path is `/handoff` → `/clear` before compaction ever fires.
7. **SessionEnd hook** fires when the session ends. If a real-length session ended without `/memory-sync` (and wasn't a deliberate `/clear`), it writes an `.unsynced` flag that the next SessionStart surfaces.
8. **`/memory-sync`** writes a structured session note to the Obsidian vault, chooses and saves the learnings worth keeping (it reports what it saved; it does not ask), appends decisions to the project's `_decisions.md` log, marks the session synced, and cleans up staging files.

## Features

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

Deep consolidation that mines recent session transcripts (JSONL files) for decisions, corrections, and preferences that were never explicitly logged. Uses a token-efficient grep-first scanning strategy. It saves the learnings it judges worth keeping and produces an approval report covering:

- New decisions found in transcripts, and the learnings it saved or dropped
- Contradictions between new findings and existing vault records
- Stale sessions (90+ days) for archival
- Auto-memory ingest from Claude Code's built-in memory

The session-start hook checks a 24-hour timer (on startup/resume) and nudges when dream consolidation is due. `--ingest` and `--tidy` are now aliases for dream phases 3 and 4.

## Troubleshooting

### `obsidian: command not found` in Claude Code (Windows)

Git Bash doesn't resolve `.com` extensions, so `obsidian` won't find `Obsidian.com` even when its directory is on PATH. Fix with both:

1. **Symlink:** `ln -s "/c/Program Files/Obsidian/Obsidian.com" ~/.local/bin/obsidian`
2. **Env var** in `~/.claude/settings.json`: `"OBSIDIAN_CLI_PATH": "/c/Program Files/Obsidian/Obsidian.com"`

See [docs/cli-setup.md](docs/cli-setup.md) for full details.

## Related Documentation

- [docs/hooks-architecture.md](docs/hooks-architecture.md) — System design document explaining the hook-MCP bridge pattern, detection logic, and interaction flows
- [docs/setup-guide-v4.md](docs/setup-guide-v4.md) — Installation (plugin or manual copy), MCP server setup and verification
