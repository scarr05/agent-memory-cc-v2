# Memory System Improvements — Design Spec

**Date:** 2026-03-27
**Project:** agent-memory-cc-v2 (slug: `memory-architecture`)
**Status:** Approved (first pass)

## Summary

Three improvements to the hook-enforced persistent memory system:

1. **Append-only decisions log** — per-project `_decisions.md` with ADR-style entries, populated via `/memory-sync`, `/decision` command, and dream consolidation
2. **Codebase analysis in `/memory-init`** — subagent-driven brownfield analysis that summarises structure, patterns, and inferred decisions from git history
3. **Dream consolidation (`/memory-sync --dream`)** — periodic deep consolidation that mines session transcripts for missed decisions, corrections, and preferences

Implementation order: decisions log → codebase analysis → dream consolidation. Each phase builds on the previous.

---

## 1. Append-Only Decisions Log

### Purpose

Session notes capture "what happened today." The decisions log captures "why we chose X" — a single, searchable, append-only file per project. Lightweight ADRs designed for agent retrieval.

### Files

**`_decisions.md`** lives at `5 Agent Memory/sessions/by-project/<slug>/_decisions.md`.

Frontmatter:

```yaml
---
title: "Decisions — <Display Name>"
type: decisions
project: "<slug>"
created: <date>
modified: <date>
---
```

### Entry Format

```markdown
### 2026-03-17 — Use hooks over CLAUDE.md-only enforcement
**Context:** CLAUDE.md instructions are advisory and get ignored after compaction.
**Decision:** Three hooks (SessionStart, PreCompact, Stop) enforce memory behaviour deterministically.
**Rationale:** Hooks fire every time regardless of model behaviour. Belt and braces with CLAUDE.md.
**Source:** [[2026-03-17-persistent-memory-architecture]]
```

The `**Source:**` field varies by route:
- Session sync: wikilink to the session note (e.g. `[[2026-03-17-persistent-memory-architecture]]`)
- Ad-hoc: `ad-hoc`
- Dream: `dream (transcript: <date>)`
- Git history inference: `inferred (git history)`

### Three Routes to the Log

| Route | Trigger | Behaviour |
|-------|---------|-----------|
| `/memory-sync` | End of session | Extracts decisions from the session, appends each to `_decisions.md` with session backlink |
| `/decision` | Ad-hoc, mid-conversation | Prompts for context/rationale if not provided in `$ARGUMENTS`, appends a single entry with `source: ad-hoc` |
| `/memory-sync --dream` | Periodic consolidation | Mines transcripts for decisions that were never logged, appends with `source: dream (transcript: <date>)` |

### `/decision` Command

New slash command at `~/.claude/commands/decision.md`. Accepts `$ARGUMENTS` as the decision text. If context/rationale aren't provided inline, prompts for them. Writes a single entry to `_decisions.md` without creating a session note.

If `_decisions.md` doesn't exist, creates it with frontmatter first.

### Relationship to Session Frontmatter

Session notes keep their existing `decisions:` frontmatter array — it's useful for quick `search_notes` hits. The decisions log has the full ADR-style context. They're complementary: frontmatter for scanning, log for understanding.

### Migration via `/memory-init`

When `/memory-init` runs (or re-runs) on a project with existing sessions but no `_decisions.md`:

1. Check if `_decisions.md` exists in the project's session folder
2. If missing, scan existing session notes for `decisions:` frontmatter arrays
3. Format each as a log entry with the session as the `**Source:**` link
4. Present the proposed `_decisions.md` content for approval before writing
5. Write once approved

For projects with no sessions, `/memory-init` creates an empty `_decisions.md` with frontmatter only.

---

## 2. Codebase Analysis in `/memory-init`

### Purpose

`/memory-init` auto-detects tech stack and build commands but knows nothing about the codebase's structure, conventions, or history. For brownfield projects, subagents analyse the repo and write a summary into the project CLAUDE.md.

### When It Runs

During `/memory-init` Phase 2 (Confirm with Sam), if the repo has git history, a row is added:

```
| Analyse codebase | Yes/No | git history detected (N commits) |
```

Only runs if Sam confirms. Skipped for greenfield repos or if declined.

### Subagents

Three subagents run in parallel:

| Subagent | Input | Output |
|----------|-------|--------|
| **Structure** | `ls`, glob patterns, entry points | Key directories, entry points, module boundaries, project layout |
| **Patterns** | Read sample files across the codebase | Established conventions (naming, error handling, testing patterns, config approach) |
| **History & Inferred Decisions** | `git log --oneline -100`, `git shortlog -sn`, `git log --format="%s%n%b" -50` | Areas of recent churn, major contributors, and inferred decisions/issues from commit messages |

Each subagent returns a short summary (10-15 lines max).

### History Subagent: Decision Inference

The history subagent scans commit messages for signals:

| Signal | Pattern | Example |
|--------|---------|---------|
| Migration/breaking change | `migrate`, `breaking`, `rename`, `deprecate` | "Migrated from Knex to Drizzle ORM" → inferred decision |
| Bug patterns | `fix`, `hotfix`, `revert`, `workaround` | Cluster of fixes in `src/billing/` → inferred fragile area |
| Architecture shifts | `refactor`, `extract`, `split`, `consolidate` | "Extract auth into separate service" → inferred decision |
| Dependency changes | `upgrade`, `bump`, `replace`, `remove` | "Replace moment.js with date-fns" → inferred decision |

Inferred decisions are presented separately during the approval gate:

```markdown
### Inferred Decisions (from commit history)
These were inferred from commit messages — confirm which to seed into _decisions.md:

- [ ] Migrated from Knex to Drizzle ORM (2026-02-14, commit abc123)
- [ ] Replaced moment.js with date-fns (2026-01-20, commit def456)
- [ ] Extracted auth into separate service (2025-12-03, commit 789ghi)
```

Confirmed decisions are written to `_decisions.md` with `source: inferred (git history)`.

### Output Format

Combined subagent output populates the `## Architecture` section of the project CLAUDE.md:

```markdown
## Architecture

### Structure
- `src/api/` — Express route handlers, one file per resource
- `src/services/` — Business logic, called by route handlers
- `src/db/` — Knex migrations and query builders
- Entry point: `src/index.ts`

### Patterns
- Error handling via custom AppError class thrown in services, caught by Express middleware
- Tests colocated with source (`*.test.ts`), using Jest
- Config via environment variables loaded through `src/config.ts`

### Recent Activity
- Heavy churn in `src/services/billing/` (12 commits in last 30 days)
- `src/api/auth.ts` untouched since January — stable
```

### Depth Levels (future expansion)

Only `light` is implemented in this phase. The subagent pattern makes future levels straightforward:

| Level | What it adds | Output location |
|-------|-------------|-----------------|
| `light` (default) | Structure, patterns, recent activity, inferred decisions | CLAUDE.md `## Architecture` section |
| `medium` (future) | + dependency analysis, test coverage shape, ownership | Separate Obsidian note |
| `deep` (future) | + function-level hotspots, fragile areas, call graphs | Separate Obsidian note |

### Idempotency

On re-run, the analysis replaces the existing Architecture section content. Sam reviews the diff before it's written (same approval gate as the rest of `/memory-init`).

---

## 3. Dream Consolidation (`/memory-sync --dream`)

### Purpose

Regular `/memory-sync` captures the current session. Dream reviews the last week of session transcripts and catches what fell through the cracks: decisions made mid-conversation that didn't trigger a sync, corrections the agent acknowledged but never wrote to learnings, preferences expressed casually.

### The Four Phases

#### Phase 1: Orient

Read current state from both tiers to build a baseline of what's already captured:

- **Tier 2** — `~/.claude/projects/<project>/memory/MEMORY.md`
- **Tier 3** — Obsidian: `_decisions.md`, recent sessions in `by-project/<slug>/`, learnings, `project-index.md`

Dream only extracts what's genuinely new relative to this baseline.

#### Phase 2: Gather Signal

Find recent JSONL session transcripts for the current project:

```bash
find ~/.claude/projects/<project>/sessions/ -name "*.jsonl" -mtime -7
```

Token-efficient scanning strategy — the subagent never reads full transcript files:

1. **Grep** (via Grep tool) — pattern match against JSONL files, returns only matching lines with surrounding context
2. **Bash `jq`** — extract just the `content` field from matching JSONL lines, discarding metadata, token counts, and tool call noise
3. **Read context** — only for high-confidence hits, read a few surrounding lines to verify

Signal patterns:

| Signal Type | Grep Pattern | Destination |
|------------|-------------|-------------|
| Corrections | `actually`, `no,`, `wrong`, `stop doing`, `I meant` | `learnings/corrections/` |
| Preferences | `I prefer`, `always use`, `never use`, `from now on`, `default to` | `learnings/preferences/` |
| Decisions | `let's go with`, `I decided`, `we're using`, `the plan is` | `_decisions.md` |
| Recurring patterns | `again`, `every time`, `keep forgetting`, `as usual` | `learnings/workflow/` |

Each finding gets a confidence level (high/medium/low) based on how explicit the statement was.

#### Phase 3: Consolidate

Cross-reference findings against existing vault content:

1. **Deduplicate** — skip anything already in `_decisions.md` or learnings
2. **Detect contradictions** — flag conflicts between new findings and existing records:

```markdown
## Contradictions Found

| Existing | New | Source |
|----------|-----|--------|
| "Use pytest for all Python testing" (learnings/preferences/, 2026-03-01) | "Use unittest for this project" (session 2026-03-20) | Transcript grep |
| **Action needed:** Project-specific override or global preference change? |
```

3. **Categorise** — route findings to the right destination (decisions → `_decisions.md`, corrections → `learnings/corrections/`, preferences → `learnings/preferences/`)
4. **Auto-memory ingest** — pull genuinely new items from Tier 2 auto-memory into Obsidian (absorbs existing `--ingest` behaviour)

Contradictions are never auto-resolved — always presented for human decision.

#### Phase 4: Prune & Index

1. **Stale sessions** — flag sessions older than 90 days with `status: complete` and no `promoted_to` field. Propose archiving (absorbs existing `--tidy` behaviour)
2. **Rebuild project index** — update `project-index.md` with accurate session counts and dates
3. **Date normalisation** — scan recent vault notes for relative dates ("yesterday", "last week") and convert to absolute dates based on the note's creation date
4. **Write dream timestamp** — `date +%s > ~/.claude/memory-staging/<slug>/.last-dream`

### Approval Flow

Everything dream produces goes through the approval report. Nothing is written without Sam's explicit confirmation:

```markdown
## Dream Report — 2026-03-27

### New Decisions Found (3)
- [ ] Switched to pnpm over npm (2026-03-22, high confidence)
- [ ] API versioning via URL path not headers (2026-03-24, medium confidence)
- [ ] Dropped Redis caching for MVP (2026-03-25, high confidence)

### New Learnings Proposed (2)
- [ ] Correction: "Don't mock the database in integration tests" (2026-03-23)
- [ ] Preference: "Always use absolute imports in this project" (2026-03-24)

### Contradictions (1)
- pytest vs unittest — details above

### Stale Sessions (2)
- 2025-12-15-initial-setup.md — archive?
- 2025-12-20-api-scaffolding.md — archive?

### Stats
- Transcripts scanned: 12
- Findings: 8 (3 decisions, 2 learnings, 1 contradiction, 2 stale)
- Deduplicated: 4 (already in vault)
```

Sam checks the boxes for what to write. Unchecked items are discarded.

### Scope

Dream runs per-project only (current project). A future `--all` flag could scan all projects globally.

### What Dream Absorbs

| Current flag | After dream ships |
|-------------|-------------------|
| `--ingest` | Alias for dream Phase 3 (auto-memory ingest) |
| `--tidy` | Alias for dream Phase 4 (stale session pruning) |

Running `--dream` does both plus transcript mining.

### Auto-Trigger

Extend `stop-memory.sh` with a 24-hour timer check:

```bash
LAST_DREAM=$(cat "$PROJECT_DIR/.last-dream" 2>/dev/null || echo "0")
NOW=$(date +%s)
HOURS_SINCE=$(( (NOW - LAST_DREAM) / 3600 ))

if [[ "$HOURS_SINCE" -ge 24 ]]; then
    touch "$HOME/.claude/.dream-pending"
fi
```

`session-start.sh` detects `.dream-pending` and nudges:

> **Dream consolidation pending** (24+ hours since last dream). Run `/memory-sync --dream` when you have a moment.

It nudges only — never auto-runs. Dream requires the interactive approval flow.

---

## 4. Shared Patterns

### Frontmatter Conventions

All new Obsidian files use YAML frontmatter. New `type` values introduced:

| Type | File | Introduced by |
|------|------|---------------|
| `decisions` | `_decisions.md` | Decisions log |
| `codebase-analysis` | Future depth medium/deep output | Codebase analysis |

Existing types (`session`, `index`, `learning`) unchanged.

### Approval Gates

Nothing gets written to `learnings/` or resolved as a contradiction without Sam's explicit approval. This rule applies uniformly:

| Feature | Needs approval | Doesn't need approval |
|---------|---------------|----------------------|
| Decisions log (via `/memory-sync`) | Inferred decisions from git history | Decisions from current session (already implicitly approved) |
| Decisions log (via `/decision`) | Nothing — user is explicitly creating the entry | — |
| Codebase analysis | Architecture section content (shown in Phase 2 confirmation) | — |
| Dream | All findings: new learnings, contradiction resolution, stale session archival, new decisions | — |

### `/memory-init` Phase Changes

| Phase | Current | Change |
|-------|---------|--------|
| 1 | Detect Project Identity | Unchanged |
| 2 | Confirm with Sam | + row for "Analyse codebase?" if git history detected |
| 3 | Create Project CLAUDE.md | Unchanged |
| 4 | Create Obsidian Structure | Unchanged |
| **4.5** | — | **Decisions Log Setup** — create or backfill `_decisions.md` |
| **4.6** | — | **Codebase Analysis** — run subagents if approved in Phase 2 |
| 5 | Load and Present Context | + show `_decisions.md` summary if it exists |
| 6 | Check for Auto-Memory | Unchanged |

### `/memory-sync` Changes

Standard sync gains one new step after writing the session note:

**Step 3.5: Append to Decisions Log** — extract decisions from the session, append to `_decisions.md`, update `modified` in frontmatter.

New `--dream` flag adds the full four-phase dream consolidation.

After dream ships, `--ingest` and `--tidy` become aliases for dream phases 3 and 4.

### New Slash Command

| File | Command | Purpose |
|------|---------|---------|
| `decision.md` | `/decision` | Ad-hoc decision entry without full session sync |

### Hook Changes

| Hook | Change |
|------|--------|
| `stop-memory.sh` | Add 24hr dream timer check, write `.dream-pending` if overdue |
| `session-start.sh` | Add `.dream-pending` detection, include nudge in injected context |
| `pre-compact.sh` | No changes |

### Implementation Order

1. **Phase 1: Decisions log** — `_decisions.md` creation, `/decision` command, `/memory-sync` Step 3.5, `/memory-init` Phase 4.5 (backfill)
2. **Phase 2: Codebase analysis** — subagent briefs, `/memory-init` Phase 4.6, light depth only
3. **Phase 3: Dream consolidation** — transcript scanning, consolidation logic, approval report, hook timer extensions, `--ingest`/`--tidy` aliasing
