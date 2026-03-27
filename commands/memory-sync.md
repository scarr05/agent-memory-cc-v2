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
