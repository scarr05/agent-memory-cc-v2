---
description: "Consolidate session memory into Obsidian vault. Writes a structured session note, proposes learnings, optionally ingests auto-memory. Use at end of significant sessions or when switching context."
user-invocable: true
allowed-tools:
  - "obsidian:read_note"
  - "obsidian:write_note"
  - "obsidian:search_notes"
  - "obsidian:get_frontmatter"
  - "obsidian:list_directory"
  - "obsidian:update_frontmatter"
  - "obsidian:patch_note"
  - "obsidian:read_multiple_notes"
  - "obsidian:get_notes_info"
  - "Agent"
  - "Bash"
  - "Read"
  - "Grep"
  - "Glob"
---

# /memory-sync

Consolidate this session's context into the Obsidian vault. $ARGUMENTS

## Modes

Parse $ARGUMENTS for mode flags:
- **(no args)** — Standard session sync (default)
- **--dream** — Deep consolidation: mine transcripts, cross-reference vault, prune stale sessions (includes --ingest and --tidy)
- **--ingest** — Pull auto-memory from this project into vault (alias for dream Phase 3)
- **--tidy** — Review old sessions for staleness and archive candidates (alias for dream Phase 4)
- **--status** — Show current memory state without writing anything

## Standard Sync (default)

### Step 1: Assess the Session

Review the current conversation and determine:
- **Project name** (from repo, CLAUDE.md, or conversation context)
- **Key decisions** made this session
- **Outcomes** produced (files, configs, fixes, designs)
- **Open items** remaining
- **Patterns observed** (preferences, corrections, recurring approaches)

If this session was trivial (quick Q&A, no decisions), say so and ask if the user still wants to log it.

### Step 2: Check for Prior Sessions

```
search_notes(query="<project-name>", searchContent=true)
```

Search `5 Agent Memory/sessions/` for recent sessions on the same project. Note any continuity (is this a continuation of prior work?).

### Step 3: Write Session Note

Write to: `5 Agent Memory/sessions/by-project/<project-slug>/<date>-<topic>.md`

If the project folder doesn't exist, create it.

Use this structure:

```yaml
---
title: "Session - <Brief Topic>"
created: <ISO datetime>
type: session
status: <complete|in-progress|blocked>
project: "<project-name>"
area: "<area if applicable>"
tags: [<relevant tags>]
decisions:
  - "<decision 1>"
  - "<decision 2>"
outcomes:
  - "<outcome 1>"
follow_up:
  - "<open item 1>"
resumable: <true if work continues>
promoted_to: ""
source_agent: "claude-code"
---

## Context
<Why this session happened. 1-2 sentences.>

## Progress
<What was accomplished. Be specific about files changed, approaches taken.>

## Decisions
- <Decision>: <Rationale>

## Outcomes
- <What was produced>

## Open Items
- [ ] <Follow-up task>

## Notes for Resumption
<If resumable: true — include file paths, current state, exact next step. Enough context for a fresh agent to continue.>
```

### Step 3.5: Append to Decisions Log

If any decisions were made this session (from the `decisions:` frontmatter array in the session note just written):

1. Check if `_decisions.md` exists in the project folder:

```
list_directory("5 Agent Memory/sessions/by-project/<project-slug>/")
```

2. If `_decisions.md` doesn't exist, create it using the template from `config/decisions-template.md`, replacing `<Display Name>`, `<slug>`, and `<date>` placeholders:

```
write_note("5 Agent Memory/sessions/by-project/<project-slug>/_decisions.md", <content from template>)
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

### Step 4: Pattern Detection

Review the session for recurring patterns. Check against existing learnings:

```
search_notes(query="<pattern keywords>", searchContent=true)
```

Search `5 Agent Memory/learnings/` for related learnings.

If you spot a NEW pattern (preference, workflow, correction) not already captured:
- Propose it to the user: "I noticed [pattern]. Should I save this as a learning?"
- Only write to `learnings/` after approval
- Use appropriate subcategory: `preferences/`, `technical/`, `workflow/`, `corrections/`

If you spot an EXISTING learning that should be updated:
- Show the user the current version and proposed change
- Update after approval

### Step 5: Update Project Index

Read `5 Agent Memory/project-index.md` and update the relevant project row with:
- Last session date
- Any new key decisions

If the project isn't in the index, add it.

### Step 6: Clean Up Staging

Check `~/.claude/memory-staging/<slug>/` for:

1. **Checkpoint files** — if any exist, their content should now be superseded by the session note. Delete them.
2. **Session meta** — reset `message_count=0` for the next session.

```bash
rm -f ~/.claude/memory-staging/<slug>/checkpoint-*.md
sed -i 's/message_count=[0-9]*/message_count=0/' ~/.claude/memory-staging/<slug>/.session-meta
```

### Step 7: Confirm

Tell the user:
- What was written and where
- Any learnings proposed
- Any open items carried forward
- Staging files cleaned up
- Reminder of resumption state if applicable

---

## Ingest Mode (--ingest)

Pull Claude Code auto-memory into the Obsidian vault.

### Step 1: Read Auto-Memory

The auto-memory lives at: `~/.claude/projects/<project>/memory/`

Read `MEMORY.md` and any topic files in that directory.

### Step 2: Deduplicate

Search Obsidian for each auto-memory item:
```
search_notes(query="<key phrase from auto-memory>", searchContent=true)
```

Skip anything already captured in vault learnings or sessions.

### Step 3: Write New Items

For each genuinely new item from auto-memory:
- If it's a preference/pattern → propose as learning (needs the user's approval)
- If it's a build command/debug insight → write to project session note
- If it's architecture context → write to relevant project area

### Step 4: Report

Show the user what was ingested, what was deduplicated, and what needs approval.

---

## Tidy Mode (--tidy)

Review and consolidate old memory.

### Step 1: Find Stale Sessions

Search for sessions older than 90 days with `status: complete` and no `promoted_to` value.

### Step 2: Propose Consolidation

For each stale session cluster (same project):
- Summarise what they collectively capture
- Propose: archive, consolidate into a single summary, or promote key patterns to learnings

### Step 3: Execute After Approval

Only archive/consolidate after the user confirms.

---

## Status Mode (--status)

Show current memory state without writing anything:

1. Count of sessions by project (last 30 days)
2. Count of learnings by category
3. Any working/ files still active
4. Auto-memory file count for current project
5. Last sync date (from most recent session note)

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
rm -f ~/.claude/memory-staging/<slug>/.dream-pending
```

This resets the 24-hour timer checked by the Stop hook and clears the per-project pending nudge.

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
