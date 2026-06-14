# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A hook-enforced persistent memory system for Claude Code. It extends Claude Code with deterministic memory persistence across sessions using Obsidian (via MCP-Obsidian) as the backing vault. This is a configuration/tooling package — not a traditional software project with a build system.

## Architecture

### Three-Tier Design

1. **Hooks (deterministic, shell scripts)** — fire automatically on Claude Code events
2. **Local staging (`~/.claude/memory-staging/<slug>/`)** — ephemeral bridge between hooks and MCP
3. **Obsidian vault (`5 Agent Memory/`)** — structured, permanent, cross-project storage

Hooks cannot call MCP directly. They write to local staging files and inject `additionalContext` via JSON stdout. Claude reads staging files and pushes content to Obsidian via MCP-Obsidian.

### Hook Scripts

Six hooks fire on Claude Code lifecycle events:

| Script | Event | Purpose | Budget |
|--------|-------|---------|--------|
| `session-start.sh` | SessionStart | Detect slug, inject prior-context pointer, flag pending checkpoints + unsynced sessions, run the post-compaction handoff | warm ≤300ms / cold ≤3s |
| `read-once/hook.sh` | PreToolUse (Read) | Deduplicate source-code re-reads | — |
| `pre-compact.sh` | PreCompact | Write a checkpoint stub before compaction (side-effect only) | ~200ms |
| `stop-memory.sh` | Stop | Increment counter, nudge at 15/30 messages or 45+ min, check 24hr dream timer | ≤50ms |
| `session-end.sh` | SessionEnd | Flag a real-length session that ended without `/memory-sync` | ≤100ms |
| `prompt-corrections.sh` | UserPromptSubmit | Surface a logged correction when the prompt touches its topic | ≤100ms |

### Slash Commands

| File | Command | Purpose |
|------|---------|---------|
| `memory-init.md` | `/memory-init` | One-time project setup: detect stack, create CLAUDE.md metadata, set up Obsidian folders, load prior context. Includes decisions log setup (Phase 4.5) and optional codebase analysis (Phase 4.6) |
| `memory-sync.md` | `/memory-sync` | End-of-session: write session note, append to decisions log, propose learnings, clean staging. Supports `--dream`, `--ingest`, `--tidy`, `--status` flags |
| `decision.md` | `/decision` | Ad-hoc decision logging to `_decisions.md` without full session sync |

### Project Slug Detection (priority order)

1. `.claude/CLAUDE.md` — `<!-- memory:project-slug=X -->` HTML comment
2. `.claude/settings.json` — `memory.projectSlug` field
3. Git remote origin — repo name extraction
4. `package.json` / `pyproject.toml` / `Cargo.toml` — project name
5. Directory basename (fallback)

The slug is the primary key for all memory operations — it determines staging paths, Obsidian folder structure, and context loading.

### Hook Output Schemas

Each hook emits the channel Claude Code actually reads for that event (corrected in v4 — the old "everything is `systemMessage`" form was never received by Claude):

| Hook | Channel |
|------|---------|
| SessionStart, UserPromptSubmit | `hookSpecificOutput.additionalContext` (a string Claude sees); plain stdout is a documented fallback via `MEMORY_HOOK_PLAINTEXT=1` |
| Stop | `systemMessage` (shown to the user, not Claude) — the correct nudge channel |
| PreToolUse (read-once) | `hookSpecificOutput.permissionDecision` (`allow` / `deny` / `ask`) |
| PreCompact | emits nothing — stub-only side effect; the post-compaction handoff comes from SessionStart with `source=compact` |
| SessionEnd | side-effect only (writes `.unsynced`); receives `reason` on stdin, cannot inject |

## Installation

Install as a Claude Code plugin (`claude --plugin-dir <repo>`) or copy files into `~/.claude/` manually — see `docs/setup-guide-v4.md` for both paths. The manual copy, in short:
- Hook scripts from `hooks/` → `~/.claude/hooks/` (including `read-once/`)
- `config/settings.json` → `~/.claude/settings.json` (merge if existing)
- `config/global-claude-md-v2.md` → `~/.claude/CLAUDE.md`
- Slash command `.md` files from `commands/` → `~/.claude/commands/`
- Subagent `.md` files from `agents/` → `~/.claude/agents/`

### Verification

```bash
# Test session-start hook manually
cd ~/your-project && echo '{}' | bash ~/.claude/hooks/session-start.sh

# Verify hooks are registered in Claude Code
/hooks
```

## Key Files

- `.claude-plugin/plugin.json` — Plugin manifest (name, version, description)
- `hooks/hooks.json` — Plugin hook registration (mirrors `config/settings.json` with `${CLAUDE_PLUGIN_ROOT}` paths)
- `config/global-claude-md-v2.md` — Global CLAUDE.md with preferences, memory rules, MCP tool list, and vault structure
- `docs/hooks-architecture.md` — System design document explaining the hook-MCP bridge pattern, detection logic, and interaction flows
- `docs/setup-guide-v4.md` — v4 installation (plugin + manual); `docs/setup-guide-v2.md` is the older manual-only guide
- `config/settings.json` — Hook registration config for `~/.claude/settings.json`

## Conventions

- All bash scripts use `set -euo pipefail`
- Slug detection logic is duplicated across hook scripts (each script must be self-contained). `stop-memory.sh` uses a minimal `detect_slug_fast` variant for performance
- Memory metadata in project CLAUDE.md files uses HTML comments (`<!-- memory:key=value -->`) for invisibility in rendered markdown
- Obsidian notes must always include YAML frontmatter
- British English spelling throughout (organisation, colour, behaviour)

## Testing

Semi-automated test suite in `tests/`:
- **Tier 1 (scripted):** `bash tests/hook-validation.sh /path/to/project [expected-slug]` — validates hook outputs and captures metrics
- **Tier 2-3 (manual):** Follow `tests/playbook.md` for session-level testing
- **Results:** `tests/results/baseline-YYYY-MM-DD.md` (gitignored)

See `docs/superpowers/specs/2026-04-01-e2e-testing-design.md` for the full design.
