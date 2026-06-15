# Session Testing Playbook

Manual protocol for Tier 2 (session baseline) and Tier 3 (full lifecycle) testing.
Run Tier 1 (`bash tests/hook-validation.sh`) first.

## Prerequisites

- Obsidian 1.12+ running with CLI enabled
- `obsidian version` works from Claude Code's bash shell
- Hooks installed and registered (`/hooks` shows all six: session-start, read-once, pre-compact, stop, session-end, prompt-corrections)
- At least one prior session note in vault for the project (for memberberry to find)

## Tier 2 — Session Baseline (~3 min per project)

Run this on each project to measure the context cost of the v3 memory system.

### Steps

1. Open a **fresh** Claude Code session in the project directory
2. **Before typing anything**, note the context % shown in the status bar
   - Record as `Post-SessionStart %`
3. Send exactly: **"What project slug did the memory system inject?"**
   - **The critical schema check.** Claude should answer with the correct slug, proving `additionalContext` actually landed. If it has no idea, injection failed — set `MEMORY_HOOK_PLAINTEXT=1` in settings and retry.
4. Send exactly: **"What did we work on last session?"**
   - This triggers memberberry retrieval
5. After memberberry responds, note the context % again
   - Record as `Post-Memberberry %`
6. Assess memberberry quality:
   - **yes** — returned what you'd need to pick up where you left off
   - **partial** — got some of it, missed something you'd expect
   - **no** — useless or wrong
7. **memberberry memory check** — invoke memberberry a second time on a related query and confirm it records or reuses search strategy in its native memory (`~/.claude/agent-memory/memberberry/MEMORY.md` gains or reflects an entry). Verifies the `memory: user` grant.
8. Record results in the table below

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
- After changing `pre-compact.sh`, `session-start.sh`, `session-end.sh`, or `prompt-corrections.sh`
- Before merging to main

### Steps (after completing Tier 2)

1. Do some real work in the session (any small task — doesn't matter what)
2. Trigger **real context compaction** (let it auto-compact, or run `/compact`). Note: `/clear` is **not** a substitute — it starts SessionStart with `source=clear`, not `source=compact`, so it won't exercise the compaction handoff.
3. Check the PreCompact → SessionStart handoff:
   - PreCompact wrote a stub: `~/.claude/memory-staging/<slug>/checkpoint-*.md`
   - After compaction, the SessionStart (`source=compact`) context surfaces that stub with an ACTION REQUIRED handoff directing blackbox to fill it
   - blackbox filled it: the stub gains real session state, or a note lands in `5 Agent Memory/working/` (`obsidian search query="checkpoint" path="5 Agent Memory/working"`)
4. Note context % after compaction → `Post-Compact %`
5. Send exactly: **"What were we just working on?"**
   - Tests checkpoint recovery
6. Assess resume quality:
   - **yes** — session resumed coherently, knew what was happening
   - **partial** — got some context but missed key details
   - **no** — lost or confused
7. Run `/memory-sync` and verify:
   - Session note written to vault? (`obsidian search query="type: session" path="5 Agent Memory/sessions/by-project/<slug>"`)
   - Staging files cleaned up? (`ls ~/.claude/memory-staging/<slug>/`)
   - `.session-meta` now contains `synced=true`
8. **Unsynced-flag check:** in a fresh session, do 10+ exchanges, then end it (close or `exit`) **without** `/memory-sync`. Reopen the project and confirm SessionStart warns that the previous session was never synced. Run `/memory-sync` to clear it.
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
