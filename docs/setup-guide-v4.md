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

### 3. macOS notes

Verified on macOS 15 (Darwin 25.6) with Claude Code 2.1.259:

- `/bin/bash` is **3.2.57** and there is no Homebrew bash by default. The hooks are written to run under it — do not reintroduce bash-4 constructs (`${var,,}`, `declare -A`, `mapfile`).
- The userland is BSD, so `sed -i EXPR FILE`, `grep -oP` and `sha1sum` are unavailable. Use the portable idioms already in the repo (`sed` to a temp + `mv`, `sed -n 's//p'`, `sha1sum || shasum -a 1`).
- `jq` ships with macOS at `/usr/bin/jq`; no install needed.
- Run the suite under the real interpreter before trusting a change: `HOOKS_DIR=./hooks bash tests/hook-validation.sh <project> <slug>`. `bash -n` is **not** sufficient — a bash-4 expansion is a runtime error, not a parse error, so a syntax check passes on a hook that dies on every invocation.

Recorded baseline on this machine: SessionStart cold 261ms / warm 91ms, Stop 14ms, SessionEnd 16ms, UserPromptSubmit 14ms.

**Re-run checklist after pulling `fix/macos-portability` (2026-09-03 changes):**

```bash
cd ~/agent-memory-cc-v2 && git pull
# 1. MCP server: MCPVault replaces the Local REST API registration
claude mcp remove obsidian -s user 2>/dev/null
npm i -g @bitbonsai/mcpvault
claude mcp add obsidian --scope user -- mcpvault "/path/to/scarr-Brain"
claude mcp list | grep obsidian        # expect ✔ Connected
# 2. Hooks under real bash 3.2 (the bash-4 gate has a 3.2 fallback branch that only this box exercises)
HOOKS_DIR=./hooks bash tests/hook-validation.sh "$PWD" memory-architecture   # expect 39/39
bash tests/handoff-lib-test.sh                                               # expect FAIL=0
# 3. Redeploy if on the manual path (plugin path: /reload-plugins instead)
cp hooks/*.sh ~/.claude/hooks/ && cp hooks/read-once/hook.sh ~/.claude/hooks/read-once/ && cp commands/*.md ~/.claude/commands/ && cp agents/*.md ~/.claude/agents/
# 4. Remove the REST cert env if you added it
grep -n NODE_EXTRA_CA_CERTS ~/.claude/settings.json
```

If either test suite fails on the 3.2 branch, the fault is in the `else` arm of the `BASH_VERSINFO` gate in `prompt-corrections.sh` or `session-end.sh`.

### 4. Verify

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

## Obsidian MCP Server

The vault **writes** (`/memory-init`, `/memory-sync`, `/decision`) go through MCP. Two servers can provide this and they expose **different tool names**, so `commands/` describe operations as verbs and allow both name sets. Register whichever you use under the server name `obsidian`. MCPVault is the one in use.

| Verb used in `commands/` | MCPVault (`@bitbonsai/mcpvault`) | Local REST API plugin (v5+) |
|---|---|---|
| read note | `read_note` | `vault_read` |
| read frontmatter only | `get_frontmatter` | `vault_read` (`targetType="frontmatter"`) |
| list folder | `list_directory` | `vault_list` |
| write note | `write_note` | `vault_write` |
| append to note | `patch_note` (old→new at end of file) | `vault_append` |
| patch note | `patch_note` (literal old→new) | `vault_patch` (heading / block / frontmatter) |
| update frontmatter | `update_frontmatter` | `vault_patch` (`targetType="frontmatter"`) |
| search vault | `search_notes` | `search_simple` |
| search vault frontmatter | `search_notes` (`searchFrontmatter=true`, `pathPrefix` to scope) | `search_query` (JsonLogic) |
| move / delete note | `move_note` / `delete_note` | `vault_move` / `vault_delete` |

### MCPVault (recommended)

[bitbonsai/mcpvault](https://github.com/bitbonsai/mcpvault) (formerly `@mauricio.wolff/mcp-obsidian`, renamed at 0.9.0) is the server both machines run. Install it globally and register the binary; do **not** run it as `npx ...@latest`, which hits the npm registry on every Claude Code start and times out (30s) whenever the registry is slow, leaving the session with no vault writes:

```bash
npm i -g @bitbonsai/mcpvault
claude mcp add obsidian --scope user -- mcpvault /path/to/vault                                    # macOS/Linux
MSYS_NO_PATHCONV=1 claude mcp add obsidian --scope user -- cmd /c mcpvault "C:\path\to\vault"   # Windows Git Bash
```

Upgrade with `npm i -g @bitbonsai/mcpvault@latest` and restart Claude Code. Runs as its own process straight against the vault files, so it works with Obsidian closed. Its patch is a literal string replace and its search scopes by `pathPrefix` only; that covers every write the commands make.

### Local REST API plugin (alternative — not used on Sam's machines since 2026-09-03)

The [Local REST API with MCP](https://github.com/coddingtonbear/obsidian-local-rest-api) community plugin (v5+) serves MCP directly from inside Obsidian, so there is no separate server process to install or keep alive. Its structural `vault_patch` and JsonLogic `search_query` are nicer than MCPVault's, but it needs Obsidian running, a trusted self-signed cert renewed yearly, and a second config to keep in step across machines. Dropped for those reasons; kept here because `commands/` still work with it.

1. Install **Local REST API** from Obsidian → Community plugins, and enable it.
2. Copy the API key from the plugin's settings.
3. Register it at user scope:

```bash
claude mcp add --transport http obsidian https://127.0.0.1:27124/mcp \
  --scope user --header "Authorization: Bearer <your-api-key>"
```

**TLS.** The plugin is HTTPS-only by default with a self-signed certificate, which Node rejects. Rather than disabling verification, trust the plugin's own CA:

```bash
curl -sk https://127.0.0.1:27124/obsidian-local-rest-api.crt \
  -o ~/.claude/obsidian-local-rest-api.crt
```

```json
// ~/.claude/settings.json → "env"
"NODE_EXTRA_CA_CERTS": "/Users/<you>/.claude/obsidian-local-rest-api.crt"
```

Confirm with `claude mcp list` — `obsidian` should report **✔ Connected**. The certificate is valid for one year; re-run the `curl` when the plugin regenerates it.

Because the server lives inside Obsidian, **the app must be running** for any write to succeed.

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
