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
   - PreCompact wrote **no** stub — confirm the staging dir has no `checkpoint-*.md` (`ls ~/.claude/memory-staging/<slug>/checkpoint-*.md` → "No such file"). It only cleared the read-once cache.
   - After compaction, `SessionStart` (`source=compact`) harvested Claude Code's own compaction summary into a handoff scratch and injected it as `additionalContext` — confirm the fresh context contains a `RESUMING FROM HANDOFF` block (no blackbox involvement)
   - The handoff scratch is present: `ls ~/.claude/memory-staging/<slug>/handoff*.md`
4. Note context % after compaction → `Post-Compact %`
5. Send exactly: **"What were we just working on?"**
   - Tests compaction-handoff recovery
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

| Project | Handoff Injected | Post-Compact % | Resume Quality | Sync Clean | Notes |
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

## Handoff Workflow Verification Gates

Run before merging the handoff workflow. Gates 1–2 are scripted; 3–4 are live-session manual.

### Gate 1 — Transcript windowing (scripted)
```bash
bash tests/handoff-lib-test.sh
```
Expect `FAIL=0`. The fixture has two compaction boundaries; the window tests prove only post-last-boundary entries survive, and an adversarial case proves a nested (non-top-level) `compactMetadata` key is not mistaken for a boundary.

### Gate 2 — Stop token-read off hot path (scripted)
Build a large synthetic transcript and time the gated read:
```bash
T=$(mktemp)
for i in $(seq 1 50000); do printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}'; done > "$T"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":160000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}' >> "$T"
printf '%s\n' '{"type":"system","subtype":"tail"}' >> "$T"
time (source hooks/handoff-lib.sh; read_live_tokens "$T")
rm -f "$T"
```
Expect the printed value `160000` (back-scan finds the usage entry past the trailing system line) and a sub-second `real` time.

### Gate 3 — Post-/clear additionalContext injection (LIVE)
In a real Claude Code session: run `/handoff`, fill the narrative, `/clear`. In the fresh session, confirm Claude actually receives the `RESUMING FROM HANDOFF` context (ask it "what are you resuming?"). If it does not, set `MEMORY_HOOK_PLAINTEXT=1` and retry — confirm the plaintext fallback injects.

### Gate 4 — Transcript resolution for /handoff (LIVE)
In a real session, run `/handoff` and inspect its Step 1 output: confirm `TRANSCRIPT` resolved to a real `.jsonl` (not `<none>`) and `AMBIGUOUS=0`. `CLAUDE_SESSION_ID` is expected to be unset, so the resolver should hit the `.transcript-path` breadcrumb persisted by the Stop/SessionStart hooks. Separately, open two sessions in the same repo, let both write a turn, then run `/handoff` in one and confirm the recency guard reports `AMBIGUOUS=1` rather than guessing.
