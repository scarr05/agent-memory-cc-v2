# Setup Guide — Agent Memory v4

Two ways to install: as a Claude Code **plugin** (recommended — one command registers all six hooks, both subagents, and the slash commands together) or by **manual copy** into `~/.claude/` (the v2 method, still supported as a fallback).

## What You're Installing

### Hooks (six, deterministic)

| Hook | Event | Does |
|------|-------|------|
| `session-start.sh` | SessionStart | Detect slug, inject the prior-context pointer, flag a pending handoff and unsynced sessions, run the post-compaction handoff |
| `read-once/hook.sh` | PreToolUse (Read) | Deduplicate source-code re-reads |
| `pre-compact.sh` | PreCompact | Clear the read-once cache before compaction (checkpoint stubs retired — injects nothing) |
| `stop-memory.sh` | Stop | Track message count, nudge for `/memory-sync`, check the 24-hour dream timer |
| `session-end.sh` | SessionEnd | Flag a real-length session that ended without `/memory-sync` |
| `prompt-corrections.sh` | UserPromptSubmit | Surface a logged correction when the prompt touches its topic |

### Subagents

- **memberberry** (Haiku) — vault retrieval, native `memory: user`
- **blackbox** (Haiku) — checkpoint capture, native `memory: project`

### Slash commands

`/memory-init`, `/memory-sync`, `/memory-load`, `/handoff`, `/decision`.

---

## Option A: Plugin install (recommended)

The plugin bundles the hooks (`hooks/hooks.json`), subagents (`agents/`), and commands (`commands/`) under one manifest (`.claude-plugin/plugin.json`). Hook commands use `${CLAUDE_PLUGIN_ROOT}`, so nothing is copied into `~/.claude/`.

### 1. Get the plugin

```bash
git clone <repo-url> ~/agent-memory-cc-v2
```

### 2. Load it

For a local clone, load it for the session:

```bash
claude --plugin-dir ~/agent-memory-cc-v2
```

After editing plugin files, hot-reload with `/reload-plugins`. Once the repo is published as a marketplace, `/plugin install agent-memory@<marketplace>` installs it permanently.

### 3. Verify

In the session:

- `/hooks` — lists all six hooks
- `/agents` — shows `memberberry` and `blackbox`
- `/help` — lists `/memory-init`, `/memory-sync`, `/memory-load`, `/handoff`, `/decision`

Then run `/memory-init` in a project to set its slug and create the Obsidian folders.

---

## Option B: Manual copy (fallback)

Use this if you'd rather not run as a plugin, or you're on a Claude Code build without plugin support.

### 1. Hooks

```bash
mkdir -p ~/.claude/hooks/read-once
cp hooks/handoff-lib.sh hooks/session-start.sh hooks/pre-compact.sh hooks/stop-memory.sh \
   hooks/session-end.sh hooks/prompt-corrections.sh ~/.claude/hooks/
cp hooks/read-once/hook.sh ~/.claude/hooks/read-once/
chmod +x ~/.claude/hooks/*.sh ~/.claude/hooks/read-once/hook.sh
```

### 2. Hook registration

Merge the `hooks` block from `config/settings.json` into `~/.claude/settings.json` (all six events). With no existing settings, copy it wholesale:

```bash
cp config/settings.json ~/.claude/settings.json
```

Run `/hooks` to confirm all six are registered.

### 3. Subagents

```bash
mkdir -p ~/.claude/agents
cp agents/memberberry.md agents/blackbox.md ~/.claude/agents/
```

### 4. Slash commands

```bash
mkdir -p ~/.claude/commands
cp commands/memory-init.md commands/memory-sync.md \
   commands/memory-load.md commands/handoff.md commands/decision.md ~/.claude/commands/
```

### 5. Global CLAUDE.md

```bash
cp config/global-claude-md-v2.md ~/.claude/CLAUDE.md   # merge if one exists
```

### 6. Staging directory

```bash
mkdir -p ~/.claude/memory-staging
```

Hooks write here; `/memory-sync` cleans it.

---

## Obsidian Vault

Either install path uses the same vault layout. Create the folders once (or let `/memory-init` create them via MCP on first run):

```bash
VAULT="$HOME/path-to-vault/<your-vault>"   # adjust
mkdir -p "$VAULT/5 Agent Memory/sessions/by-project"
mkdir -p "$VAULT/5 Agent Memory/sessions/general"
mkdir -p "$VAULT/5 Agent Memory/learnings/"{preferences,technical,workflow,corrections}
mkdir -p "$VAULT/5 Agent Memory/working"
```

Obsidian 1.12+ with the CLI enabled is required for memberberry/blackbox reads — see [cli-setup.md](cli-setup.md).

---

## The MEMORY_HOOK_PLAINTEXT escape hatch

SessionStart and UserPromptSubmit inject their context via `hookSpecificOutput.additionalContext` — a JSON field Claude reads. Both also accept plain stdout as a documented fallback. If a Claude Code build ever fails to inject the JSON form (for example under upstream issue #16538), set:

```json
// ~/.claude/settings.json → "env"
"MEMORY_HOOK_PLAINTEXT": "1"
```

The two hooks then emit their context as plain stdout instead. Leave it unset unless injection visibly fails — on current builds the JSON form works (verified 2026-06-14).

---

## Verifying It Works

| Check | How |
|-------|-----|
| Slug injects | Fresh session, ask "what project slug did the memory system inject?" — should return your slug, no plaintext flag needed |
| Six hooks registered | `/hooks` |
| Subagents present | `/agents` shows memberberry + blackbox |
| Unsynced flag | End a long session without `/memory-sync`, reopen the project — SessionStart warns it was never synced |
| Corrections surface | With a correction logged, mention its topic — UserPromptSubmit points you at memberberry |

For full session-level testing, follow [tests/playbook.md](../tests/playbook.md) (Tier 2 and Tier 3).

---

## Performance Budgets

Measured per hook, WARN (not FAIL) on the Tier 1 harness:

| Hook | Budget |
|------|--------|
| SessionStart | warm ≤300ms / cold ≤3s |
| Stop | ≤50ms target |
| UserPromptSubmit | ≤100ms |
| SessionEnd | ≤100ms |

On Windows Git Bash the empty-bash spawn floor alone can exceed 100ms, so these are WARN-only and the harness fails only on a >2× regression against the recorded per-machine baseline — never on the absolute number.

---

## Troubleshooting

Slug detection, MCP availability, Stop-hook latency, and auto-memory vs vault memory are unchanged from v2 — the [setup-guide-v2.md](setup-guide-v2.md) troubleshooting section still applies. Two v4-specific notes:

- **`.sh` must stay LF.** The repo pins `eol=lf` via `.gitattributes`; if you copy hooks through a tool that rewrites line endings, CRLF will break bash. Re-check with `file ~/.claude/hooks/*.sh`.
- **Timing budgets are advisory.** See the table above — judge against the recorded baseline, not the absolute target.
