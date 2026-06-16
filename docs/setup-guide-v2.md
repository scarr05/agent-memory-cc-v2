# Setup Guide — Hooks-Enforced Memory System

> **Deprecated — this is the v2 guide.** It documents the original three-hook system, including the retired pre-compaction checkpoint-stub mechanism. For the current install (v4: six hooks, the `/handoff` → `/clear` workflow, and the plugin path) see **[setup-guide-v4.md](setup-guide-v4.md)**.

## What You're Installing

### Hooks (deterministic enforcement)
- **session-start.sh** — auto-detects project, injects memory context, flags pending items
- **pre-compact.sh** — checkpoints session state before context compaction
- **stop-memory.sh** — tracks message count, nudges for `/memory-sync` on long sessions

### Slash Commands (interactive)
- **`/memory-init`** — one-time project setup (detects stack, creates CLAUDE.md, sets up Obsidian)
- **`/memory-sync`** — end-of-session consolidation (writes sessions, proposes learnings, ingests auto-memory)
- **`/memory-load`** — lightweight context pull (searches vault for relevant prior sessions)

### Configuration
- **Global CLAUDE.md** — always-loaded instructions for memory behaviour
- **settings.json** — hook registrations
- **Project CLAUDE.md template** — per-project memory metadata
- **Project Index** — vault-side quick-reference for agents

---

## Step 1: Hook Scripts

```bash
mkdir -p ~/.claude/hooks
cp hooks/session-start.sh ~/.claude/hooks/
cp hooks/pre-compact.sh ~/.claude/hooks/
cp hooks/stop-memory.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/*.sh
```

Test the session-start hook manually:

```bash
cd ~/your-project
echo '{}' | bash ~/.claude/hooks/session-start.sh
```

Should output JSON with the detected project slug. If it can't detect one, it falls back to the directory name.

## Step 2: Settings.json (Hook Registration)

If you DON'T have an existing `~/.claude/settings.json`:

```bash
cp settings.json ~/.claude/settings.json
```

If you DO have existing settings, merge the hooks section. Open `~/.claude/settings.json` and add the `hooks` key from `settings.json`. Don't overwrite other settings.

**To verify hooks are registered:**
Open Claude Code and run `/hooks` — you should see the three hooks listed.

## Step 3: Global CLAUDE.md

```bash
cp global-claude-md-v2.md ~/.claude/CLAUDE.md
```

If you have an existing global CLAUDE.md, merge the memory system section in rather than overwriting.

**Important:** Review this file. It includes your preferences, MCP tools, and vault paths. Adjust anything that's changed.

## Step 4: Slash Commands

```bash
mkdir -p ~/.claude/commands
cp memory-init.md ~/.claude/commands/memory-init.md
cp memory-sync.md ~/.claude/commands/memory-sync.md
cp memory-load.md ~/.claude/commands/memory-load.md
```

These will be available as `/memory-init`, `/memory-sync`, and `/memory-load` in any project.

**To verify:** Open Claude Code and type `/memory` — you should see all three commands in autocomplete.

## Step 5: Staging Directory

```bash
mkdir -p ~/.claude/memory-staging
```

This is where hooks write intermediate data. Claude Code picks it up and pushes to Obsidian. It gets cleaned by `/memory-sync`.

## Step 6: Vault Structure

In your Obsidian vault (or via Claude Code once the system is live):

```bash
# If vault is locally accessible via Nextcloud sync
VAULT="$HOME/path-to-vault/[your-vault-name]"  # Adjust this path

mkdir -p "$VAULT/5 Agent Memory/sessions/by-project"
mkdir -p "$VAULT/5 Agent Memory/sessions/general"
mkdir -p "$VAULT/5 Agent Memory/learnings/preferences"
mkdir -p "$VAULT/5 Agent Memory/learnings/technical"
mkdir -p "$VAULT/5 Agent Memory/learnings/workflow"
mkdir -p "$VAULT/5 Agent Memory/learnings/corrections"
```

Copy `project-index.md` to `5 Agent Memory/project-index.md` (either via file copy or MCP-Obsidian).

Or, just run `/memory-init` in your first project — it'll create the structure via MCP if it doesn't exist.

## Step 7: First Project Init

Open Claude Code in any active project and run:

```
/memory-init
```

This will:
1. Auto-detect project from git remote, manifest, folder name
2. Show you the detected values and ask for confirmation
3. Create `.claude/CLAUDE.md` with memory metadata
4. Create the Obsidian session folder for this project
5. Update the project index
6. Load any existing context

Repeat for each project you actively work in.

---

## How It Works Day-to-Day

### Starting a Session

```
You open Claude Code in ~/projects/my-project/
  ↓
SessionStart hook fires automatically
  ↓
Hook detects slug: my-project (from .claude/CLAUDE.md metadata)
Hook checks staging: 1 pending checkpoint from yesterday
Hook injects context: "Project: my-project. 1 pending checkpoint. Search Obsidian for prior context."
  ↓
Claude processes checkpoint → writes to Obsidian working/
Claude searches for prior sessions → finds last session from Friday
Claude tells you: "Last session was about v5 planning. Open items: pillar alignment tests. Ready to continue."
  ↓
You start working
```

### During a Session

```
Stop hook fires after each response (invisible, ~50ms)
  ↓
At 15 messages: Stop hook nudges "Consider /memory-sync to checkpoint"
  ↓
If context gets large, PreCompact hook fires before compaction
  → Creates checkpoint staging file
  → Claude fills in session state
  → After compaction, Claude pushes checkpoint to Obsidian working/
```

### Ending a Session

```
You type: /memory-sync
  ↓
Slash command:
  1. Writes structured session note to 5 Agent Memory/sessions/by-project/my-project/
  2. Proposes learnings if patterns detected
  3. Updates project index
  4. Cleans staging files
  ↓
Next time you open this project, SessionStart finds the session note
```

### First Time in a New Project

```
You open Claude Code in ~/projects/new-thing/
  ↓
SessionStart hook: no .claude/CLAUDE.md, no memory config
Hook injects: "No memory config. Run /memory-init."
  ↓
You type: /memory-init
  ↓
Auto-detects: slug=new-thing, Python 3.12, FastAPI, area=Personal
Asks for confirmation, you tweak the area to "AI"
Creates .claude/CLAUDE.md with metadata
Creates Obsidian folder, updates project index
"Fresh start. No prior sessions. What are we building?"
```

---

## Troubleshooting

### Hooks Not Firing

```bash
# Check hooks are registered
claude --debug  # Verbose mode shows hook execution

# Or toggle verbose in session
# Press Ctrl+O to see hook stdout/stderr
```

Verify `~/.claude/settings.json` has the correct hook paths and that scripts are executable.

### Slug Detection Wrong

The hook checks these in order:
1. `.claude/CLAUDE.md` → `<!-- memory:project-slug=X -->` comment
2. `.claude/settings.json` → `memory.projectSlug` field
3. Git remote origin → repo name
4. package.json / pyproject.toml → project name
5. Directory name

To override: run `/memory-init` and confirm the correct slug. It writes the metadata comment to `.claude/CLAUDE.md` which takes priority on all subsequent sessions.

### MCP-Obsidian Not Available

The hooks themselves don't need MCP — they only write to local staging files. But the slash commands (`/memory-sync`, `/memory-load`, `/memory-init`) need MCP-Obsidian.

If MCP isn't connected:
- Hooks still work (staging, tracking, context injection)
- Slash commands will fail gracefully and tell you to check MCP config
- Staging files accumulate until MCP is available again

### Stop Hook Slowing Things Down

The Stop hook should be <50ms. If you notice sluggishness:

```bash
time echo '{}' | bash ~/.claude/hooks/stop-memory.sh
```

If it's slow, the issue is likely disk I/O on the staging directory. Move `memory-staging/` to a tmpfs mount if needed, or simply remove the Stop hook — it's the least critical of the three.

### Auto-Memory vs Vault Memory

They're complementary:
- **Auto-memory** (`~/.claude/projects/*/memory/`) = fast, automatic, project-local, machine-local
- **Vault memory** (`5 Agent Memory/`) = structured, cross-project, multi-agent, human-curated
- **`/memory-sync --ingest`** = the bridge between them

Don't disable auto-memory. Let it do its thing. Run `--ingest` periodically to promote useful items to the vault.

### Existing Session Notes (Flat Structure)

If you have session notes in `5 Agent Memory/sessions/` from before this system:
- They still work — search finds them regardless of folder structure
- Optionally move them: tell Claude Code "move my existing flat session notes into the by-project structure"
- New sessions always go into `by-project/<slug>/`
