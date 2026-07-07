# E2E Testing Design — v3 CLI Subagent Features

## Problem

The v2 memory system front-loaded all session context at SessionStart, consuming 30-80k tokens before the user sent their first message. v3 replaces this with a progressive disclosure model: inject pointers via hooks, query on demand via cheap Haiku subagents. There is currently no test infrastructure to validate this works or to measure the context cost at each layer.

## Goals

1. **Validate functionality** — confirm hooks, subagents, and slash commands work correctly across multiple real projects
2. **Establish a repeatable protocol** — same steps every time, comparable results across runs
3. **Measure performance baseline** — context window % at key checkpoints, hook execution times, systemMessage character counts — so future optimisations can be measured against known values

## Non-Goals

- Full automation of subagent behaviour testing (requires live session, inherently subjective)
- Testing on platforms other than Windows Git Bash (current dev environment)
- Load testing or concurrency scenarios

## Design

### Progressive Disclosure Testing

Three tiers matching the system's own architecture. Test the cheapest/fastest layers first; only go deeper if something's off or after changes to deeper layers.

### Tier 1 — Hook Validation (scripted, seconds)

A single bash script (`tests/hook-validation.sh`) that runs all three hooks in isolation against a target project directory.

**Usage:**
```bash
bash tests/hook-validation.sh /path/to/project [expected-slug]
```

**Per-hook checks:**

| Hook | Validates | Captures |
|------|-----------|----------|
| `session-start.sh` | Valid JSON output, slug matches expected, `systemMessage` key present, no errors on stderr | Character count of `systemMessage`, execution time (ms) |
| `pre-compact.sh` | Checkpoint stub created at expected path, frontmatter present, staging dir exists | Stub file size (bytes), execution time (ms) |
| `stop-memory.sh` | Counter increments in `.session-meta`, nudge fires at message thresholds, completes under 50ms | Execution time (ms) |

**Output:** A markdown table row appended to `tests/results/baseline-YYYY-MM-DD.md`:

```
| Project | Slug | SessionStart chars | SessionStart ms | PreCompact ms | Stop ms | Pass/Fail |
|---------|------|--------------------|-----------------|---------------|---------|-----------|
```

**Failure handling:** Each check prints PASS/FAIL inline. Overall result is FAIL if any check fails. Stderr from hooks is captured to `tests/results/errors-YYYY-MM-DD.log`.

### Tier 2 — Session Baseline (manual, ~3 min per project)

A markdown playbook followed in a fresh Claude Code session. Same steps every time.

**Steps:**
1. Open fresh Claude Code session in the project directory
2. Note context % shown by Claude Code after SessionStart hook fires (before typing anything)
3. Send: "What did we work on last session?" (triggers memberberry retrieval)
4. Note context % after memberberry responds
5. Assess memberberry quality: did it return enough to pick up where you left off?
6. Record results

**Quality scoring:**
- **yes** — returned what you'd need to continue where you left off
- **partial** — got some of it, missed something you'd expect
- **no** — useless or wrong

**Results appended to the same baseline file:**

```
| Project | Post-SessionStart % | Post-Memberberry % | Memberberry Quality | Notes |
|---------|--------------------|--------------------|---------------------|-------|
```

### Tier 3 — Full Lifecycle (manual, ~10 min, only when needed)

Extends Tier 2 with the compaction and sync cycle. Only run after changes to subagents, slash commands, or `pre-compact.sh`, or before merging to main.

**Steps (after completing Tier 2):**
1. Do some real work in the session (any small task)
2. Trigger context compaction (naturally or via `/clear` as proxy)
3. Check: did blackbox capture a checkpoint? (check staging dir or vault)
4. Note context % after compaction
5. Send: "What were we just working on?" (tests checkpoint recovery)
6. Assess resume quality: did the session resume coherently? (yes/partial/no)
7. Run `/memory-sync`
8. Assess: session note written to vault? Decisions logged? Staging cleaned up?

**Results extend the same table:**

```
| Project | ... Tier 2 cols ... | Blackbox Captured | Post-Compact % | Resume Quality | Sync Clean |
|---------|---------------------|-------------------|----------------|----------------|------------|
```

### When to Run Each Tier

| Trigger | Tier 1 | Tier 2 | Tier 3 |
|---------|--------|--------|--------|
| Any hook script change | Yes | No | No |
| Subagent definition change | Yes | Yes | Yes |
| Slash command change | Yes | No | Yes |
| Before merge to main | Yes | Yes | Yes |
| Routine baseline check | Yes | Yes | No |

## File Structure

```
tests/
├── hook-validation.sh          # Tier 1 scripted tests
├── playbook.md                 # Tier 2 + 3 manual protocol (copy of steps above)
└── results/
    └── baseline-YYYY-MM-DD.md  # Combined results from all tiers
```

## Success Criteria

- **Tier 1:** All hooks pass validation across all tested projects, SessionStart `systemMessage` under 1500 characters, all hooks execute within target times
- **Tier 2:** Post-SessionStart context under 10%, memberberry quality rated "yes" or "partial" across tested projects
- **Tier 3:** Blackbox captures checkpoint, session resumes coherently, `/memory-sync` completes cleanly

## Performance Baseline Targets

These are initial targets based on v3 design goals. Actual baselines will be recorded on first run and used as the reference point for future comparisons.

| Metric | v2 Baseline | v3 Target |
|--------|-------------|-----------|
| Post-SessionStart context % | 3-8% (v2 front-loaded all context) | Under 10% of context window |
| SessionStart systemMessage | ~5000+ chars | Under 1500 chars |
| SessionStart execution time | N/A | Under 200ms |
| Stop hook execution time | N/A | Under 50ms |
| Memberberry context cost | N/A (all front-loaded) | Under 5% additional context |
