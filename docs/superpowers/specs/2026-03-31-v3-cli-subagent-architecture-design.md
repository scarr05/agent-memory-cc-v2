# Agent Memory v3 — CLI + Subagent Architecture Design

**Date:** 2026-03-31
**Status:** Approved
**Branch:** `dev/v3-cli-subagents`

## Problem

The v2 memory system wastes tokens on retrieval. MCP `search_notes` dumps full note content into the main agent's context window — 8 session notes at ~800 tokens each = ~6,400 tokens of "maybe relevant" before the agent starts working. The main model (Sonnet/Opus) does grunt work that a cheaper model handles perfectly. CLAUDE.md contains dynamic state that goes stale between sessions.

Additionally, source code files are re-read repeatedly during editing cycles, wasting ~2,000 tokens per redundant read.

## Solution

A layered architecture using the Obsidian CLI (1.12+) for reads and Haiku subagents for filtering, plus a vendored read-once hook for source code token deduplication.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Read backend | CLI first, MCP fallback per invocation | Runtime detection, no config needed |
| CLI path resolution | Bare `obsidian` on PATH; env var `OBSIDIAN_CLI_PATH` as fallback if testing fails | Clean default, escape hatch available |
| Write backend | MCP only (unchanged) | Proven, handles frontmatter well |
| Subagent model | Haiku | Retrieval/checkpoint is grunt work |
| Subagent names | memberberry (retrieval), blackbox (checkpoint) | memberberry: personality, memorable. blackbox: professional, self-explanatory |
| read-once source | Vendored from Boucle framework | Self-contained install, no external dependency |
| `tasks` on folders | Use `search:context` for `- [ ]` markers | Single CLI call vs N+1 file enumeration |
| Scope | Full spec, single release | All layers ship together |

## Architecture

### Layer 1 — CLAUDE.md (~500 tokens, every turn)

Static only: architecture, conventions, file structure, memory delegation instructions. No current state, priorities, or open items.

**What stays:**
- Project slug and area metadata (HTML comments)
- Architecture summary (2-4 sentences)
- Conventions (bulleted list)
- File structure (top 2 levels)
- Memory system delegation instructions ("use memberberry, not MCP directly")

**What moves out:**
- Current priorities → `5 Agent Memory/_context.md`
- Open items → vault session frontmatter `follow_up` field
- Recent decisions → vault session frontmatter `decisions` field
- Notes to agent / corrections → `5 Agent Memory/learnings/corrections/`
- Tech stack deep-dives → `5 Agent Memory/learnings/technical/`

### Layer 2 — SessionStart hook (~200-300 tokens, once)

Rewritten `session-start.sh` using CLI calls:

1. Git state (branch, dirty files, recent commits)
2. Project index row via `search:context` on project-index.md
3. Open tasks via `search:context query="- [ ]"` scoped to project folder
4. Working files via `search` scoped to `5 Agent Memory/working/`
5. Corrections flag via `search` in `5 Agent Memory/learnings/corrections/`
6. Staging file awareness (filesystem check, unchanged)
7. Session depth via `search` with `total` flag
8. Delegation guidance ("use memberberry for context, use blackbox for checkpoints")

CLI availability check at top — if `obsidian version` fails, output minimal context and suggest MCP fallback.

### Layer 3 — Subagents (on-demand, Haiku)

#### memberberry — Memory Retrieval

**Personality:** South Park member berries. Keeps its voice in the prompt.

**Tools:** Bash (for CLI calls)

**Retrieval strategy (progressive disclosure):**
1. `search` — paths only (cheapest)
2. `search:context` — matching lines with context
3. `property:read` — frontmatter fields without content
4. `backlinks` / `links` — graph traversal
5. `read` — full note content (last resort, max 2 notes)
6. Corrections check — always if corrections exist

**Fallback:** If CLI unavailable, report to calling agent, suggest MCP `search_notes`.

**Output:** Structured summary under ~300 tokens.

#### blackbox — Session Checkpoint

**Tone:** Professional. No personality. Does the job.

**Tools:** Bash (for CLI calls), Read (for transcript)

**Process:**
1. Read transcript at provided path
2. Extract: decisions (with rationale), progress, open items, key files, resume context
3. Write checkpoint via `obsidian create` to `5 Agent Memory/working/<slug>-checkpoint-<date>.md`
4. If prior checkpoint exists for slug, read and merge — no duplicates

**Fallback:** If CLI unavailable, write to `~/.claude/memory-staging/<slug>/checkpoint-<date>.md`.

**Output format:** Structured checkpoint with YAML frontmatter, optimised for machine parsing.

### Layer 4 — read-once (every Read call)

**Source:** Vendored from [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once)

**Mechanism:**
- PreToolUse hook intercepts `Read` tool calls
- Tracks file paths + modification times in session cache
- First read: allowed, cached
- Re-read unchanged: blocked/warned
- Re-read changed: diff only
- TTL expiry: configurable (default 1200s / 20 min)

**Default config:** `warn` mode + diff enabled (safe for Edit tool which requires prior Read)

**Integration:**
- PreCompact hook clears read-once cache to prevent stale state
- No conflict with memberberry/blackbox (they use Bash, not Read)

## Token Savings Model

| Layer | Mechanism | Estimated Savings |
|-------|-----------|-------------------|
| CLAUDE.md slimming | Static only, ~500 tokens | ~60% per turn |
| SessionStart | CLI snapshot vs MCP dump | ~50-70% on session start |
| memberberry | Haiku retrieval vs main model | ~80% on memory reads |
| blackbox | Haiku checkpoint vs main model | ~90% on pre-compaction |
| read-once | Block redundant source reads | ~60-90% on Read tool |

## Repo Structure

```
agent-memory-cc-v2/
├── hooks/
│   ├── session-start.sh          # REWRITE — CLI-driven
│   ├── pre-compact.sh            # UPDATE — add read-once cache clear
│   ├── stop-memory.sh            # MINOR UPDATE
│   └── read-once/                # NEW — vendored
│       ├── hook.sh
│       ├── cache.sh
│       └── README.md
├── agents/                        # NEW
│   ├── memberberry.md
│   └── blackbox.md
├── commands/
│   ├── memory-init.md            # UPDATE — CLI check, subagent guidance
│   ├── memory-sync.md            # UPDATE — CLI property:set on completion
│   ├── memory-load.md            # UPDATE — delegate to memberberry
│   └── decision.md               # UNCHANGED
├── config/
│   ├── settings.json             # UPDATE — add read-once PreToolUse hook
│   ├── global-claude-md-v2.md    # UPDATE — subagent delegation rules
│   └── project-claude-md-template.md  # REWRITE — slim to ~500 tokens
├── skills/
│   ├── agent-memory/             # UPDATE — CLI commands, subagent patterns
│   └── obsidian-cli/             # NEW — CLI command reference
├── docs/
│   ├── setup-guide-v3.md         # NEW
│   ├── cli-setup.md              # NEW — per-platform PATH setup
│   └── hooks-architecture.md     # UPDATE
└── README.md                     # UPDATE — v3 architecture, CLI prereqs
```

## Platform Support

### CLI PATH Setup

**Windows (PowerShell/CMD):** Obsidian 1.12+ installer registers CLI automatically. Restart terminal after enabling in Settings → General → CLI.

**Windows (Git Bash / WSL):** May require manual PATH addition:
```bash
export PATH="/c/Program Files/Obsidian:$PATH"
# or add to ~/.bashrc
```

**macOS:** CLI registered via Settings → General → CLI. Available in all terminals after restart.

**Linux:** CLI registered via Settings → General → CLI. May require AppImage-specific PATH setup.

**Fallback:** If bare `obsidian` doesn't work, set `OBSIDIAN_CLI_PATH` environment variable to the full binary path. All hooks and subagents will use `${OBSIDIAN_CLI_PATH:-obsidian}`.

## Testing Checklist

### Prerequisites
- [ ] Obsidian 1.12+ with CLI enabled
- [ ] `obsidian version` returns from Claude Code's bash shell
- [ ] Haiku available for subagent delegation on Max plan

### Token Measurement
- [ ] Measure v2 SessionStart token injection (baseline)
- [ ] Measure v3 SessionStart token injection
- [ ] Measure memberberry output tokens for typical retrieval
- [ ] Confirm 50-70% reduction target met

### Functional
- [ ] SessionStart outputs correct git state via CLI
- [ ] SessionStart surfaces open tasks via `search:context`
- [ ] SessionStart flags corrections when they exist
- [ ] SessionStart degrades gracefully with CLI unavailable
- [ ] memberberry retrieves relevant context for known project
- [ ] memberberry returns concise output (under 300 tokens)
- [ ] memberberry follows progressive disclosure
- [ ] blackbox captures checkpoint before compaction
- [ ] blackbox merges with existing checkpoint if present
- [ ] blackbox falls back to staging directory if CLI unavailable
- [ ] read-once blocks redundant file reads (warn mode)
- [ ] read-once sends diff for changed files
- [ ] read-once cache cleared on PreCompact
- [ ] Main model delegates to memberberry for non-trivial tasks
- [ ] Slimmed CLAUDE.md under 500 tokens

### Integration
- [ ] Full session lifecycle: start → work → compact → resume
- [ ] memberberry finds blackbox checkpoint on session resume
- [ ] Cross-session continuity maintained through checkpoint cycle
- [ ] No regression on `/memory-init`, `/memory-load`, `/memory-sync`
- [ ] Platform test: Windows (Git Bash), Windows (PowerShell terminal)
