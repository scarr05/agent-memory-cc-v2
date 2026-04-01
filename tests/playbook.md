# Session Testing Playbook

Manual protocol for Tier 2 (session baseline) and Tier 3 (full lifecycle) testing.
Run Tier 1 (`bash tests/hook-validation.sh`) first.

## Prerequisites

- Obsidian 1.12+ running with CLI enabled
- `obsidian version` works from Claude Code's bash shell
- Hooks installed and registered (`/hooks` shows session-start, pre-compact, stop)
- At least one prior session note in vault for the project (for memberberry to find)

## Tier 2 — Session Baseline (~3 min per project)

Run this on each project to measure the context cost of the v3 memory system.

### Steps

1. Open a **fresh** Claude Code session in the project directory
2. **Before typing anything**, note the context % shown in the status bar
   - Record as `Post-SessionStart %`
3. Send exactly: **"What did we work on last session?"**
   - This triggers memberberry retrieval
4. After memberberry responds, note the context % again
   - Record as `Post-Memberberry %`
5. Assess memberberry quality:
   - **yes** — returned what you'd need to pick up where you left off
   - **partial** — got some of it, missed something you'd expect
   - **no** — useless or wrong
6. Record results in the table below

### Results Table

Copy this table into your baseline results file (`tests/results/baseline-YYYY-MM-DD.md`):

```
## Tier 2 — Session Baseline

| Project | Post-SessionStart % | Post-Memberberry % | Memberberry Quality | Notes |
|---------|--------------------|--------------------|---------------------|-------|
|         |                    |                    |                     |       |
```

## Tier 3 — Full Lifecycle (~10 min, only when needed)

Run after changes to subagents, slash commands, or `pre-compact.sh`. Also before merging to main.

### When to Run

- After modifying `memberberry.md`, `blackbox.md`, or any slash command
- After changing `pre-compact.sh`
- Before merging to main

### Steps (after completing Tier 2)

1. Do some real work in the session (any small task — doesn't matter what)
2. Trigger context compaction (naturally or via `/clear` as proxy)
3. Check: did blackbox capture a checkpoint?
   - Look in `~/.claude/memory-staging/<slug>/` for `checkpoint-*.md`
   - Or check vault: `obsidian search query="checkpoint" path="5 Agent Memory/working"`
4. Note context % after compaction → `Post-Compact %`
5. Send exactly: **"What were we just working on?"**
   - Tests checkpoint recovery
6. Assess resume quality:
   - **yes** — session resumed coherently, knew what was happening
   - **partial** — got some context but missed key details
   - **no** — lost or confused
7. Run `/memory-sync`
8. Verify:
   - Session note written to vault? (`obsidian search query="type: session" path="5 Agent Memory/sessions/by-project/<slug>"`)
   - Staging files cleaned up? (`ls ~/.claude/memory-staging/<slug>/`)
9. Record results

### Results Table

Append to your baseline results file:

```
## Tier 3 — Full Lifecycle

| Project | Blackbox Captured | Post-Compact % | Resume Quality | Sync Clean | Notes |
|---------|-------------------|----------------|----------------|------------|-------|
|         |                   |                |                |            |       |
```

## When to Run Each Tier

| Trigger                        | Tier 1 | Tier 2 | Tier 3 |
|--------------------------------|--------|--------|--------|
| Any hook script change         | Yes    | No     | No     |
| Subagent definition change     | Yes    | Yes    | Yes    |
| Slash command change           | Yes    | No     | Yes    |
| Before merge to main           | Yes    | Yes    | Yes    |
| Routine baseline check         | Yes    | Yes    | No     |
