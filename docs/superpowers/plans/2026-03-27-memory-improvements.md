# Memory System Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add three improvements to the memory system: append-only decisions log, subagent-driven codebase analysis in `/memory-init`, and dream consolidation (`/memory-sync --dream`).

**Architecture:** All three features are slash command extensions — no new hooks, no new services. The decisions log adds a new Obsidian file type and two write paths (sync + ad-hoc command). Codebase analysis adds subagent-dispatched analysis to the existing `/memory-init` flow. Dream adds transcript scanning and cross-referencing to `/memory-sync`. Hook changes are limited to timer checks in `stop-memory.sh` and nudge detection in `session-start.sh`.

**Tech Stack:** Bash (hooks), Markdown (slash commands), MCP-Obsidian (vault operations), Claude Code subagents (codebase analysis, dream transcript scanning)

**Spec:** `docs/superpowers/specs/2026-03-27-memory-improvements-design.md`

---

## File Structure

### New Files

| File | Purpose |
|------|---------|
| `commands/decision.md` | `/decision` slash command for ad-hoc decision logging |
| `config/decisions-template.md` | Template for `_decisions.md` files created in Obsidian |

### Modified Files

| File | Change |
|------|--------|
| `commands/memory-sync.md` | Add Step 3.5 (decisions append), add `--dream` flag handling |
| `commands/memory-init.md` | Add Phase 4.5 (decisions log setup/backfill), Phase 4.6 (codebase analysis), update Phase 2 and Phase 5 |
| `hooks/stop-memory.sh` | Add 24hr dream timer check |
| `hooks/session-start.sh` | Add `.dream-pending` detection and nudge |
| `config/project-claude-md-template.md` | Add Architecture subsection structure for codebase analysis output |

---

## Phase 1: Decisions Log

### Task 1: Create `_decisions.md` Template

**Files:**
- Create: `config/decisions-template.md`

- [ ] **Step 1: Write the template file**

```markdown
---
title: "Decisions — <Display Name>"
type: decisions
project: "<slug>"
created: <date>
modified: <date>
---

# Decisions — <Display Name>

Append-only log of significant decisions for this project. Each entry includes context, rationale, and a source link back to the session or conversation where the decision was made.

<!-- Entries are appended below this line. Do not reorder or rewrite existing entries. -->
```

- [ ] **Step 2: Verify the template renders correctly**

Open the file and confirm the frontmatter is valid YAML and the markdown renders as expected.

- [ ] **Step 3: Commit**

```bash
git add config/decisions-template.md
git commit -m "feat: add _decisions.md template for per-project decision logs"
```

---

### Task 2: Create `/decision` Slash Command

**Files:**
- Create: `commands/decision.md`

- [ ] **Step 1: Write the command file**

```markdown
---
description: "Log a decision to the project's _decisions.md without a full session sync. Use for ad-hoc decisions in quick conversations."
user-invocable: true
allowed-tools:
  - "obsidian:read_note"
  - "obsidian:write_note"
  - "obsidian:search_notes"
  - "obsidian:patch_note"
  - "obsidian:get_frontmatter"
  - "obsidian:update_frontmatter"
  - "obsidian:list_directory"
  - "Bash"
  - "Read"
  - "Grep"
---

# /decision

Log a decision to this project's decisions log. $ARGUMENTS

## Step 1: Detect Project

Read the project slug from `.claude/CLAUDE.md` metadata:

```bash
grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' .claude/CLAUDE.md 2>/dev/null || echo ""
```

If no slug found, check git remote:

```bash
git remote get-url origin 2>/dev/null | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | tr '[:upper:]' '[:lower:]'
```

If still no slug, ask the user which project this decision belongs to.

## Step 2: Parse Arguments

If `$ARGUMENTS` contains the decision text, extract it. Look for these patterns:

- Full entry: `/decision Use pnpm over npm because it's faster and has better lockfile handling`
- Just a title: `/decision Use pnpm over npm`
- Empty: `/decision` (prompt for details)

If context or rationale are missing, ask for them:

1. **What's the decision?** (if not provided)
2. **What's the context?** (what problem or question led to this)
3. **What's the rationale?** (why this choice over alternatives)

## Step 3: Check for Existing Decisions Log

```
list_directory("5 Agent Memory/sessions/by-project/<slug>/")
```

If `_decisions.md` exists, read it to check for duplicates:

```
read_note("5 Agent Memory/sessions/by-project/<slug>/_decisions.md")
```

If the decision is already logged (same topic), tell the user and ask if they want to update or add a new entry.

## Step 4: Write Entry

If `_decisions.md` doesn't exist, create it using this frontmatter:

```yaml
---
title: "Decisions — <Display Name>"
type: decisions
project: "<slug>"
created: <today's date>
modified: <today's date>
---

# Decisions — <Display Name>

Append-only log of significant decisions for this project.

<!-- Entries are appended below this line. Do not reorder or rewrite existing entries. -->
```

Append the new entry using `patch_note`:

```markdown

### <date> — <Decision Title>
**Context:** <what problem or question led to this>
**Decision:** <what was decided>
**Rationale:** <why this choice>
**Source:** ad-hoc
```

Update the `modified` date in frontmatter.

## Step 5: Confirm

Tell the user:
- What was written
- Where it was written (`5 Agent Memory/sessions/by-project/<slug>/_decisions.md`)
```

- [ ] **Step 2: Test the command can be invoked**

```bash
# Verify the file parses correctly (valid frontmatter)
head -12 commands/decision.md
```

Confirm the `---` fences are correct and all required frontmatter fields are present.

- [ ] **Step 3: Commit**

```bash
git add commands/decision.md
git commit -m "feat: add /decision command for ad-hoc decision logging"
```

---

### Task 3: Add Decisions Append Step to `/memory-sync`

**Files:**
- Modify: `commands/memory-sync.md:47-93` (after Step 3: Write Session Note, before Step 4: Pattern Detection)

- [ ] **Step 1: Add Step 3.5 to memory-sync.md**

Insert the following after the Step 3 session note writing section (after line 93, before `### Step 4: Pattern Detection`):

```markdown
### Step 3.5: Append to Decisions Log

If any decisions were made this session (from the `decisions:` frontmatter array in the session note just written):

1. Check if `_decisions.md` exists in the project folder:

```
list_directory("5 Agent Memory/sessions/by-project/<project-slug>/")
```

2. If `_decisions.md` doesn't exist, create it:

```
write_note("5 Agent Memory/sessions/by-project/<project-slug>/_decisions.md", <content>)
```

Use the frontmatter template:

```yaml
---
title: "Decisions — <Project Name>"
type: decisions
project: "<project-slug>"
created: <today's date>
modified: <today's date>
---

# Decisions — <Project Name>

Append-only log of significant decisions for this project.

<!-- Entries are appended below this line. Do not reorder or rewrite existing entries. -->
```

3. For each decision in the session's `decisions:` array, append an entry using `patch_note`:

```markdown

### <date> — <Decision Title>
**Context:** <infer from session context>
**Decision:** <the decision as stated>
**Rationale:** <infer from session discussion>
**Source:** [[<session-note-filename>]]
```

4. Update the `modified` date in `_decisions.md` frontmatter using `update_frontmatter`.
```

- [ ] **Step 2: Verify the markdown nesting is correct**

Read the full file and confirm the new section integrates cleanly between Step 3 and Step 4 — no broken heading hierarchy, no orphaned code blocks.

- [ ] **Step 3: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: add decisions log append step to /memory-sync"
```

---

### Task 4: Add Decisions Log Setup and Backfill to `/memory-init`

**Files:**
- Modify: `commands/memory-init.md:185-234` (between Phase 4 and Phase 5)

- [ ] **Step 1: Add Phase 4.5 to memory-init.md**

Insert the following after Phase 4 (Create Obsidian Structure, after line 234) and before Phase 5 (Load and Present Context):

```markdown
## Phase 4.5: Decisions Log Setup

### 4.5.1 Check for Existing Decisions Log

```
list_directory("5 Agent Memory/sessions/by-project/<slug>/")
```

If `_decisions.md` already exists, skip this phase (idempotent).

### 4.5.2 Check for Existing Sessions with Decisions

If `_decisions.md` doesn't exist, scan existing session notes for `decisions:` frontmatter:

```
get_notes_info("5 Agent Memory/sessions/by-project/<slug>/")
```

For each session note that has a `decisions:` frontmatter array, collect the decisions.

### 4.5.3 Create and Backfill

If sessions with decisions were found:

1. Build the proposed `_decisions.md` content:
   - Frontmatter with `type: decisions`
   - One entry per decision, formatted as:

```markdown
### <session-date> — <Decision Title>
**Context:** <from session context section if available, otherwise "See source session">
**Decision:** <the decision text from frontmatter>
**Rationale:** <from session decisions section if available, otherwise "See source session">
**Source:** [[<session-note-filename>]]
```

2. Present the proposed content for confirmation:

```
## Decisions Log Backfill

Found <N> decisions across <M> sessions. Proposed _decisions.md:

<preview of content>

**Write this to Obsidian?**
```

3. After confirmation, write via MCP:

```
write_note("5 Agent Memory/sessions/by-project/<slug>/_decisions.md", <content>)
```

If no existing sessions have decisions, create an empty `_decisions.md` with frontmatter only — ready for the first `/memory-sync` or `/decision` to populate.
```

- [ ] **Step 2: Update Phase 5 to show decisions log summary**

In Phase 5 (Load and Present Context), after the existing context presentation, add:

```markdown
If `_decisions.md` exists and has entries, include in the context output:

```
**Decisions log:** <N> decisions recorded. Most recent: "<most recent decision title>" (<date>)
```
```

- [ ] **Step 3: Update Phase 2 confirmation table**

In Phase 2, add a note after the confirmation table:

```markdown
If git history is detected (more than 0 commits), add a row:

```
| Analyse codebase | Yes/No | git history detected (N commits) |
```

This row controls whether Phase 4.6 (Codebase Analysis) runs. Default suggestion is "Yes" for repos with 10+ commits, "No" for fewer.
```

- [ ] **Step 4: Verify the phase numbering is consistent**

Read the full file and confirm phases are numbered correctly: 1, 2, 3, 4, 4.5, 4.6, 5, 6. No gaps, no duplicates.

- [ ] **Step 5: Commit**

```bash
git add commands/memory-init.md
git commit -m "feat: add decisions log setup and backfill to /memory-init"
```

---

## Phase 2: Codebase Analysis

### Task 5: Add Codebase Analysis Phase to `/memory-init`

**Files:**
- Modify: `commands/memory-init.md` (after the Phase 4.5 added in Task 4)

- [ ] **Step 1: Add Phase 4.6 to memory-init.md**

Insert after Phase 4.5:

```markdown
## Phase 4.6: Codebase Analysis

Only runs if the user confirmed "Analyse codebase: Yes" in Phase 2.

### 4.6.1 Dispatch Subagents

Launch three subagents in parallel using the Agent tool:

**Subagent 1: Structure**

```
Analyse this codebase's structure. Report:
- Key directories and what they contain
- Entry points (main files, index files, CLI entry points)
- Module boundaries and how code is organised
- Any monorepo or workspace structure

Use Glob to find files by pattern, Read to examine key files, and LS to understand directory layout. Keep your report to 10-15 lines maximum. Focus on what a new developer needs to orient themselves.
```

**Subagent 2: Patterns**

```
Analyse this codebase's conventions and patterns. Read 5-8 representative files across different directories. Report:
- Naming conventions (files, functions, variables)
- Error handling approach
- Testing patterns (framework, file location, naming)
- Configuration approach (env vars, config files, etc.)
- Any notable architectural patterns (dependency injection, middleware, etc.)

Keep your report to 10-15 lines maximum. Focus on conventions a new contributor would need to follow.
```

**Subagent 3: History & Inferred Decisions**

```
Analyse this codebase's git history for insights. Run these commands:

git log --oneline -100
git shortlog -sn --no-merges
git log --format="%H %s" -50

Report:
- Areas of recent churn (directories/files with most recent commits)
- Major contributors
- General trajectory (what's being worked on recently)

Also scan commit messages for signals that indicate significant decisions or recurring issues:
- Migrations/breaking changes: "migrate", "breaking", "rename", "deprecate"
- Bug patterns: clusters of "fix", "hotfix", "revert", "workaround" in the same area
- Architecture shifts: "refactor", "extract", "split", "consolidate"
- Dependency changes: "upgrade", "bump", "replace", "remove"

For each inferred decision or issue, include:
- What happened (one line)
- The commit hash and date
- Confidence: high (explicit commit message) or medium (inferred from pattern)

Keep the activity report to 10-15 lines. List inferred decisions separately — there may be 0 or many.
```

### 4.6.2 Combine Results

Combine the three subagent reports into the Architecture section of the project CLAUDE.md:

```markdown
## Architecture

### Structure
<structure subagent output>

### Patterns
<patterns subagent output>

### Recent Activity
<history subagent activity output>
```

### 4.6.3 Present Inferred Decisions

If the history subagent found inferred decisions, present them for confirmation:

```markdown
### Inferred Decisions (from commit history)
These were inferred from commit messages — confirm which to seed into _decisions.md:

- [ ] <Decision 1> (<date>, commit <hash>, <confidence>)
- [ ] <Decision 2> (<date>, commit <hash>, <confidence>)
```

Confirmed decisions are written to `_decisions.md` with entries formatted as:

```markdown
### <date> — <Decision Title>
**Context:** Inferred from commit history.
**Decision:** <what the commit message indicates>
**Rationale:** <from commit message body if available, otherwise "See commit <hash>">
**Source:** inferred (git history, commit <hash>)
```

### 4.6.4 Write to CLAUDE.md

After the user confirms the Architecture section content, write it to the project `.claude/CLAUDE.md` — replacing the existing `## Architecture` section content if present, or inserting the section if missing.

For inferred decisions that were confirmed, append them to `_decisions.md` via MCP.
```

- [ ] **Step 2: Verify the subagent prompts are self-contained**

Each subagent prompt should contain everything the agent needs — tool names, output format, length constraints. Read through each prompt and confirm no implicit knowledge is required.

- [ ] **Step 3: Commit**

```bash
git add commands/memory-init.md
git commit -m "feat: add subagent-driven codebase analysis to /memory-init"
```

---

### Task 6: Update Project CLAUDE.md Template for Architecture Subsections

**Files:**
- Modify: `config/project-claude-md-template.md:32-33`

- [ ] **Step 1: Update the Architecture section in the template**

Replace the current Architecture section:

```markdown
## Architecture

<Brief description of project structure. Key directories, entry points, patterns.>
```

With:

```markdown
## Architecture

### Structure
<Key directories, entry points, module boundaries. Generated by /memory-init codebase analysis or filled in manually.>

### Patterns
<Coding conventions, error handling, testing approach, config patterns.>

### Recent Activity
<Areas of churn, trajectory. Updated on /memory-init re-run.>
```

- [ ] **Step 2: Commit**

```bash
git add config/project-claude-md-template.md
git commit -m "feat: update CLAUDE.md template with architecture subsections"
```

---

## Phase 3: Dream Consolidation

### Task 7: Add `--dream` Flag to `/memory-sync`

**Files:**
- Modify: `commands/memory-sync.md:18-25` (Modes section)

- [ ] **Step 1: Add --dream to the modes section**

In the Modes section of `memory-sync.md`, add `--dream` to the flag list. Replace the current modes block:

```markdown
## Modes

Parse $ARGUMENTS for mode flags:
- **(no args)** — Standard session sync (default)
- **--ingest** — Also pull auto-memory from this project into vault
- **--tidy** — Review old sessions for staleness and archive candidates
- **--status** — Show current memory state without writing anything
```

With:

```markdown
## Modes

Parse $ARGUMENTS for mode flags:
- **(no args)** — Standard session sync (default)
- **--dream** — Deep consolidation: mine transcripts, cross-reference vault, prune stale sessions (includes --ingest and --tidy)
- **--ingest** — Pull auto-memory from this project into vault (alias for dream Phase 3)
- **--tidy** — Review old sessions for staleness and archive candidates (alias for dream Phase 4)
- **--status** — Show current memory state without writing anything
```

- [ ] **Step 2: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: add --dream flag to /memory-sync modes"
```

---

### Task 8: Write Dream Phase 1 (Orient) and Phase 2 (Gather Signal)

**Files:**
- Modify: `commands/memory-sync.md` (append after the Status Mode section at end of file)

- [ ] **Step 1: Add Dream Mode section**

Append the following after the `## Status Mode (--status)` section at the end of `memory-sync.md`:

```markdown
---

## Dream Mode (--dream)

Deep memory consolidation across all three tiers. Mines recent session transcripts for decisions, corrections, and preferences that were never explicitly logged, then cross-references against the Obsidian vault.

Scope: current project only.

### Dream Phase 1: Orient

Read current state from both tiers to build a baseline of what's already captured.

**Tier 2 — auto-memory:**

```bash
# Find the auto-memory directory for this project
ls ~/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

If found, read `MEMORY.md` and note existing entries.

**Tier 3 — Obsidian vault (via MCP):**

```
read_note("5 Agent Memory/project-index.md")
list_directory("5 Agent Memory/sessions/by-project/<slug>/")
list_directory("5 Agent Memory/learnings/")
```

If `_decisions.md` exists, read it:

```
read_note("5 Agent Memory/sessions/by-project/<slug>/_decisions.md")
```

Read the 2-3 most recent session notes (frontmatter only via `get_frontmatter`) to understand what's already been captured.

Build a mental map: what topics are covered, what decisions are logged, what learnings exist. This is the deduplication baseline — dream only extracts what's genuinely new.

### Dream Phase 2: Gather Signal

Find recent JSONL session transcripts for the current project:

```bash
find ~/.claude/projects/ -path "*sessions/*.jsonl" -mtime -7 2>/dev/null | sort -r | head -20
```

**Token-efficient scanning strategy — never read full transcript files:**

1. **Grep first** — use the Grep tool to pattern match against JSONL files. This returns only matching lines with surrounding context, not entire files.

2. **Extract content with jq** — for each matching line, extract just the human-readable content:

```bash
# Extract user message content from a matching JSONL line
echo '<matching-line>' | jq -r 'select(.type == "human") | .message.content[] | select(.type == "text") | .text' 2>/dev/null
```

3. **Read context only for high-confidence hits** — if a grep match looks promising, read 5-10 surrounding lines from the JSONL file to verify the context.

**Signal patterns to grep for:**

| Signal Type | Grep Pattern | Destination |
|------------|-------------|-------------|
| Corrections | `actually\|no,\|wrong\|incorrect\|not right\|stop doing\|I meant` | `learnings/corrections/` |
| Preferences | `I prefer\|always use\|never use\|from now on\|default to\|remember that` | `learnings/preferences/` |
| Decisions | `let's go with\|I decided\|we're using\|the plan is\|switch to\|we agreed` | `_decisions.md` |
| Recurring patterns | `again\|every time\|keep forgetting\|as usual\|same as before\|we always` | `learnings/workflow/` |

For each hit, extract:
- **The fact** — what was said
- **The date** — from the JSONL file modification time
- **Confidence** — high (explicit, unambiguous statement), medium (likely but needs context), low (might be noise)

Discard low-confidence hits. Keep medium and high for the consolidation report.
```

- [ ] **Step 2: Verify the jq command works on a real JSONL file**

```bash
# Find a real session JSONL and test the jq extraction
find ~/.claude/projects/ -path "*sessions/*.jsonl" -mtime -7 2>/dev/null | head -1
```

If a file is found, test the `jq` extraction on one line to confirm the JSONL structure matches the expected format. If the structure differs, update the `jq` command in the plan.

- [ ] **Step 3: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: add dream Phase 1 (orient) and Phase 2 (gather signal)"
```

---

### Task 9: Write Dream Phase 3 (Consolidate) and Phase 4 (Prune & Index)

**Files:**
- Modify: `commands/memory-sync.md` (append after Dream Phase 2)

- [ ] **Step 1: Add Dream Phases 3 and 4**

Append after the Dream Phase 2 section:

```markdown
### Dream Phase 3: Consolidate

Cross-reference findings from Phase 2 against the baseline from Phase 1.

#### 3.1 Deduplicate

For each finding, search the vault for existing coverage:

- **Decisions** — search `_decisions.md` for the same topic. If already logged, skip.
- **Corrections** — search `5 Agent Memory/learnings/corrections/` for the same correction.
- **Preferences** — search `5 Agent Memory/learnings/preferences/` for the same preference.
- **Workflow patterns** — search `5 Agent Memory/learnings/workflow/` for the same pattern.

Use `search_notes(query="<key phrase>", searchContent=true)` for each finding.

#### 3.2 Detect Contradictions

If a new finding conflicts with an existing record, flag it:

```markdown
## Contradictions Found

| Existing | New | Source |
|----------|-----|--------|
| "<existing statement>" (<file>, <date>) | "<new statement>" (transcript <date>) | Transcript grep |
| **Action needed:** Is this a project-specific override or a change in preference? |
```

Never auto-resolve contradictions. Present them in the dream report for the user to decide.

#### 3.3 Categorise Findings

Route each non-duplicate, non-contradicting finding to its destination:

| Finding type | Destination | Action |
|-------------|-------------|--------|
| Decision | `_decisions.md` | Append entry with `source: dream (transcript: <date>)` |
| Correction | `learnings/corrections/` | Propose as new learning |
| Preference | `learnings/preferences/` | Propose as new learning |
| Workflow pattern | `learnings/workflow/` | Propose as new learning |

**All findings go into the approval report first.** Nothing is written until the user approves.

#### 3.4 Auto-Memory Ingest

If auto-memory exists at `~/.claude/projects/<project>/memory/`:

1. Read `MEMORY.md` and any topic files
2. For each item, search Obsidian for existing coverage (same deduplication as above)
3. Route genuinely new items:
   - Preferences/patterns → propose as learnings
   - Build commands/debug insights → propose for project session notes
   - Architecture context → propose for project CLAUDE.md

This absorbs the existing `--ingest` behaviour. Running `/memory-sync --ingest` now routes to this phase.

### Dream Phase 4: Prune & Index

#### 4.1 Stale Sessions

Search for sessions older than 90 days:

```
search_notes(query="status: complete", searchFrontmatter=true)
```

For each session older than 90 days with `status: complete` and no `promoted_to` field, add to the prune list in the dream report.

This absorbs the existing `--tidy` behaviour. Running `/memory-sync --tidy` now routes to this phase.

#### 4.2 Rebuild Project Index

Read `5 Agent Memory/project-index.md`. For the current project:
- Update last session date
- Update session count
- Update any other stale fields

```
patch_note("5 Agent Memory/project-index.md", <old row>, <new row>)
```

#### 4.3 Date Normalisation

Scan recent vault notes (last 30 days of session notes for this project) for relative dates:
- "yesterday", "today", "last week", "next Monday", etc.

Convert each to an absolute date based on the note's `created` frontmatter date. Use `patch_note` for each replacement.

#### 4.4 Write Dream Timestamp

```bash
date +%s > ~/.claude/memory-staging/<slug>/.last-dream
```

This resets the 24-hour timer checked by the Stop hook.

### Dream Report

After all four phases, present the full report for approval:

```markdown
## Dream Report — <date>

### New Decisions Found (<N>)
- [ ] <Decision 1> (<date>, <confidence>)
- [ ] <Decision 2> (<date>, <confidence>)

### New Learnings Proposed (<N>)
- [ ] Correction: "<correction text>" (<date>)
- [ ] Preference: "<preference text>" (<date>)
- [ ] Workflow: "<pattern text>" (<date>)

### Contradictions (<N>)
<contradiction table from Phase 3.2>

### Auto-Memory Items (<N>)
- [ ] <item 1> → <proposed destination>
- [ ] <item 2> → <proposed destination>

### Stale Sessions (<N>)
- [ ] <session filename> (<date>) — archive?

### Date Corrections (<N>)
- <file>: "yesterday" → "2026-03-26"

### Stats
- Transcripts scanned: <N>
- Findings: <N> (<breakdown by type>)
- Deduplicated: <N> (already in vault)
- Contradictions: <N>
```

The user checks boxes for what to write. For each checked item:
- **Decisions** → append to `_decisions.md` via `patch_note`
- **Learnings** → write to appropriate `learnings/<category>/` subfolder via `write_note`
- **Contradictions** → user states which version to keep; update or remove the stale record
- **Auto-memory items** → write to stated destination
- **Stale sessions** → move to archive or delete (as user directs)
- **Date corrections** → apply via `patch_note`

Unchecked items are discarded.

After writing approved items, update the dream timestamp (Phase 4.4).
```

- [ ] **Step 2: Verify the full memory-sync.md is coherent**

Read the complete file from top to bottom. Check:
- Heading hierarchy is consistent (## for modes, ### for phases, #### for sub-steps)
- No orphaned code blocks or broken markdown
- The --ingest and --tidy aliases are mentioned in both the modes section and their respective dream phases
- Step numbering in standard sync (Steps 1-7) doesn't conflict with dream phase numbering

- [ ] **Step 3: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: add dream Phase 3 (consolidate) and Phase 4 (prune & index) with approval report"
```

---

### Task 10: Add Dream Timer to Stop Hook

**Files:**
- Modify: `hooks/stop-memory.sh:59-79` (after significance check, before output)

- [ ] **Step 1: Add dream timer check**

Insert the following after the significance check block (after line 70, before `# Output nudge if significant` on line 73):

```bash
# --- Dream timer check ---
LAST_DREAM_FILE="$PROJECT_DIR/.last-dream"
LAST_DREAM=$(cat "$LAST_DREAM_FILE" 2>/dev/null || echo "0")
NOW_EPOCH_DREAM=$(date +%s)
HOURS_SINCE_DREAM=$(( (NOW_EPOCH_DREAM - LAST_DREAM) / 3600 ))

if [[ "$HOURS_SINCE_DREAM" -ge 24 ]] && [[ "$LAST_DREAM" != "0" || "$NEW_COUNT" -ge 5 ]]; then
    # Only create dream-pending if we've had at least one dream before,
    # or if this session has 5+ messages (avoid nudging on first-ever use)
    touch "$HOME/.claude/.dream-pending"
fi
```

The condition `LAST_DREAM != "0" || NEW_COUNT -ge 5` prevents dream nudges for projects that have never had a dream run (`.last-dream` doesn't exist yet). Once the first dream runs and writes `.last-dream`, the 24-hour timer activates.

- [ ] **Step 2: Verify the script still passes shellcheck**

```bash
shellcheck hooks/stop-memory.sh
```

If shellcheck isn't available:

```bash
bash -n hooks/stop-memory.sh
```

Expected: no syntax errors.

- [ ] **Step 3: Commit**

```bash
git add hooks/stop-memory.sh
git commit -m "feat: add 24hr dream timer check to stop hook"
```

---

### Task 11: Add Dream Pending Detection to Session Start Hook

**Files:**
- Modify: `hooks/session-start.sh:121-155` (context building section)

- [ ] **Step 1: Add dream-pending check**

Insert the following after the pending checkpoints block (after line 144, before `if [[ -n "$PRIOR_SESSION_INFO" ]]; then` on line 146):

```bash
# Check for pending dream consolidation
if [[ -f "$HOME/.claude/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending** (24+ hours since last dream). "
    CONTEXT+="Run \`/memory-sync --dream\` when you have a moment to consolidate recent session transcripts.\n\n"
fi
```

- [ ] **Step 2: Verify the script still passes syntax check**

```bash
bash -n hooks/session-start.sh
```

Expected: no syntax errors.

- [ ] **Step 3: Add cleanup of .dream-pending to dream Phase 4**

The `.dream-pending` file should be removed after a successful dream run. In `commands/memory-sync.md`, add to Dream Phase 4.4 (Write Dream Timestamp), after the `date +%s` line:

```markdown
```bash
date +%s > ~/.claude/memory-staging/<slug>/.last-dream
rm -f ~/.claude/.dream-pending
```
```

- [ ] **Step 4: Commit**

```bash
git add hooks/session-start.sh commands/memory-sync.md
git commit -m "feat: add dream-pending detection to session-start hook"
```

---

### Task 12: Final Integration Verification

- [ ] **Step 1: Verify all files are consistent**

Read each modified file in full and check:

| File | Check |
|------|-------|
| `commands/memory-sync.md` | Modes list matches actual sections. Step numbering in standard sync is 1-7 with 3.5 inserted. Dream phases are 1-4. `--ingest` and `--tidy` reference dream phases. |
| `commands/memory-init.md` | Phase numbering is 1, 2, 3, 4, 4.5, 4.6, 5, 6. Phase 2 mentions codebase analysis row. Phase 5 mentions decisions log summary. |
| `commands/decision.md` | Frontmatter is valid. Slug detection matches session-start.sh logic. |
| `hooks/stop-memory.sh` | Dream timer doesn't interfere with existing nudge logic. Exit 0 still at end. |
| `hooks/session-start.sh` | Dream-pending check doesn't interfere with existing context building. JSON output is still valid. |
| `config/decisions-template.md` | Frontmatter matches the format used in decision.md and memory-sync.md. |
| `config/project-claude-md-template.md` | Architecture subsections match the codebase analysis output format. |

- [ ] **Step 2: Run syntax checks on all hook scripts**

```bash
bash -n hooks/session-start.sh && bash -n hooks/stop-memory.sh && bash -n hooks/pre-compact.sh && echo "All hooks pass syntax check"
```

Expected: "All hooks pass syntax check"

- [ ] **Step 3: Test session-start hook with dream-pending**

```bash
# Create a .dream-pending file and test the hook output
touch ~/.claude/.dream-pending
cd /tmp && echo '{}' | bash ~/.claude/hooks/session-start.sh 2>/dev/null
rm -f ~/.claude/.dream-pending
```

Expected: JSON output containing "Dream consolidation pending" in the systemMessage.

Note: this test uses `/tmp` which won't have a CLAUDE.md, so the slug will be detected from the directory name. That's fine for testing the dream-pending detection.

- [ ] **Step 4: Final commit if any fixes were needed**

```bash
git add -A
git status
# Only commit if there are changes
git diff --cached --quiet || git commit -m "fix: integration fixes from final verification"
```
