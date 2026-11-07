---
description: "Consolidate session memory into Obsidian vault. Writes a structured session note, proposes learnings, optionally ingests auto-memory. Use at end of significant sessions or when switching context."
allowed-tools:
  - "mcp__obsidian__read_note"
  - "mcp__obsidian__write_note"
  - "mcp__obsidian__search_notes"
  - "mcp__obsidian__patch_note"
  - "mcp__obsidian__get_frontmatter"
  - "mcp__obsidian__update_frontmatter"
  - "mcp__obsidian__list_directory"
  - "mcp__obsidian__read_multiple_notes"
  - "mcp__obsidian__get_notes_info"
  - "mcp__obsidian__vault_write"
  - "mcp__obsidian__vault_append"
  - "mcp__obsidian__vault_patch"
  - "mcp__obsidian__search_query"
  - "AskUserQuestion"
  - "Agent"
  - "Bash"
  - "Read"
  - "Grep"
  - "Glob"
---

# /memory-sync

Consolidate this session's context into the Obsidian vault. $ARGUMENTS

## Modes

Mode flags, parsed by Step 0 (an unknown flag, or two modes at once, stops there):
- **(no args)** — Standard session sync (default)
- **--dream** — Deep consolidation: mine transcripts, cross-reference vault, prune stale sessions (includes --ingest and --tidy)
- **--ingest** — Pull auto-memory from this project into vault (alias for dream Phase 3)
- **--tidy** — Review old sessions for staleness and archive candidates (alias for dream Phase 4)
- **--status** — Show current memory state without writing anything
- **--auto**: combines with any of the above: ask nothing, wait for nothing (see Auto mode). Always on in a Chief lead (`CHIEF_LEAD=1`).

### Step 0: Mode and paths

```bash
HOOKS="$HOME/.claude/hooks"
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]] && HOOKS="${CLAUDE_PLUGIN_ROOT}/hooks"
bash "$HOOKS/state-lib.sh" args memory-sync <<'SYNC_ARGS' || exit 2
$ARGUMENTS
SYNC_ARGS
# This session's own staging: Claude Code substitutes the session id below. SLOT_DIR
# holds the handoff pair (Sam: the project folder; a lead: leads/<worktree>/).
bash "$HOOKS/state-lib.sh" paths --session "${CLAUDE_SESSION_ID}"
```

Use the printed `MODE`, `AUTO`, `SLUG`, `SLOT_DIR` and `TRANSCRIPT` below. `AUTO=1` means every rule in Auto mode applies.

## Auto mode

`AUTO=1` (from `--auto`, or a Chief lead) is for a session nobody is watching: Chief sends `/memory-sync` and waits for the turn to end, so a question would leave the lead waiting for good (a question in prose still ends the turn as `done`, spike H). Never call `AskUserQuestion` and never end on a question or an offer. Each place the interactive sync asks does this instead:

| Where it asks | What auto does instead |
|---|---|
| Step 1: a trivial session ("ask if the user still wants to log it") | Log it anyway: a short session note (Context and Progress, a line each), then on to Step 6, so the sync marker is written |
| Step 4: the `AskUserQuestion` multi-select for learnings | Approve nothing. Write each candidate to the project's own memory as a proposal (below); never to `5 Agent Memory/learnings/`, so a lead's output never reaches `learnings/corrections/` or global preferences, which Sam's own sessions load (SPEC section 8) |
| `--ingest`: items that would go through Step 4 | Proposals, as above; the rest go where Ingest Step 3 says |
| `--dream` and `--tidy`: the report Sam ticks | Write the Dream Report (or the tidy proposal) to `5 Agent Memory/working/<YYYY-MM-DD>-dream-<slug>.md` with frontmatter, and write nothing else: no `_decisions.md` entries from transcripts, no index or date patches, no archive, no Phase 4.4 timestamp, so `.dream-pending` still nudges Sam |
| Contradictions | Listed in the proposal or report, never resolved |
| Step 7 and `--status`: the closing summary | Plain lines of what was written; no offer, no "tell me if" |

A learning proposal is one note per learning at `5 Agent Memory/sessions/by-project/<slug>/proposed-learnings/<YYYY-MM-DD>-<kebab-title>.md`:

```yaml
---
title: "<title>"
created: <ISO datetime>
type: learning-proposal
status: proposed
category: <preferences|technical|workflow|corrections>
project: "<slug>"
source: <lead if CHIEF_LEAD=1, else auto>
auto: true
session: "<session note filename>"
---
```

Then the learning in a sentence or two, and why this session showed it. No `- [ ]` lines: SessionStart lists those as open items. Chief's weekly review puts proposals in front of Sam; only his approval moves one into `learnings/`.

## Standard Sync (default)

### Step 1: Assess the Session

Review the current conversation and determine:
- **Project name** (from repo, CLAUDE.md, or conversation context)
- **Key decisions** made this session
- **Outcomes** produced (files, configs, fixes, designs)
- **Open items** remaining
- **Patterns observed** (preferences, corrections, recurring approaches)

If this session was trivial (quick Q&A, no decisions), say so and ask if the user still wants to log it. Under `AUTO=1`, log it anyway (Auto mode).

### Step 2: Check for Prior Sessions

```
search vault for "<project-name>"
```

Search `5 Agent Memory/sessions/` for recent sessions on the same project. Note any continuity (is this a continuation of prior work?).

### Step 2.5: Consolidate Handoff Chain (Dedup)

A long effort spans several clears, each producing a handoff stamped with `supersedes` pointing at the prior one. To avoid writing N near-duplicate session notes for one effort:

1. Read the current scratch pair if present (`SLOT_DIR` from Step 0):

```bash
cat "<SLOT_DIR>/handoff.md" 2>/dev/null
cat "<SLOT_DIR>/handoff.consumed.md" 2>/dev/null
```

2. Extract this effort's **fingerprint**: the `## Files Touched (this work unit)` list. (File-list overlap across consecutive sessions is the effort matcher — see step 3.)

3. Search the vault for an existing session note from the **same effort** (overlapping file list — the same files touched across consecutive sessions signal one continuous effort):

```
search vault for "<2-3 distinctive file basenames from the fingerprint>"
```

4. **If an overlapping recent session note exists** (same project, file-list overlap, `resumable: true`): UPDATE it in place — append new Progress/Decisions/Open Items — instead of creating a new note. Set its `status` to reflect the latest state.

5. **If none overlaps:** write the session note as described in Step 3 below.

This collapses redundancy by construction: each `/handoff` overwrites the prior scratch (no stacking), and consolidation matches against the vault before writing. If a `supersedes` stamp is missing, you may produce one duplicate — `--dream` backstops that later.

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

### Step 3.5: Set status via CLI (if available)

After writing the session note, if Obsidian CLI is available, set the status property:

```bash
"${OBSIDIAN_CLI_PATH:-obsidian}" property:set name="status" value="complete" path="<session note path>" 2>/dev/null || true
```

This is a convenience — the frontmatter already has the status, but the CLI property:set makes it queryable independently.

### Step 3.6: Append to Decisions Log

If any decisions were made this session (from the `decisions:` frontmatter array in the session note just written):

1. Check if `_decisions.md` exists in the project folder:

```
list folder "5 Agent Memory/sessions/by-project/<project-slug>/"
```

2. If `_decisions.md` doesn't exist, create it using the template from `config/decisions-template.md`, replacing `<Display Name>`, `<slug>`, and `<date>` placeholders:

```
write note "5 Agent Memory/sessions/by-project/<project-slug>/_decisions.md" with <content from template>
```

3. For each decision in the session's `decisions:` array, append an entry (patch under the `## Decisions` heading if the server supports structural patch, else plain append):

```markdown

### <date> — <Decision Title>
**Context:** <infer from session context>
**Decision:** <the decision as stated>
**Rationale:** <infer from session discussion>
**Source:** [[<session-note-filename>]]
```

4. Update the `modified` date in `_decisions.md` frontmatter by updating the note frontmatter.

### Step 4: Pattern Detection

Review the session for recurring patterns. Check against existing learnings:

```
search vault for "<pattern keywords>"
```

Search `5 Agent Memory/learnings/` for related learnings.

Gather every candidate first:

- **New patterns** (preference, workflow, technical, correction) not already captured. Subcategory: `preferences/`, `technical/`, `workflow/` or `corrections/`.
- **Updates** to an existing learning that this session showed is wrong or incomplete.
- **Direction-change corrections (from the handoff scratch):** the handoff's `## Do-Not-Redo` block (between its `<!-- HANDOFF:DONOTREDO:START -->` / `:END` markers) records the dead-ends and direction shifts of this effort — the clean, authoritative channel. A line counts as "new" when it isn't in the prior `.consumed` handoff's block (both were read in Step 2.5). For each new line not already in `5 Agent Memory/learnings/corrections/`:

```
search vault for "<key phrase from the correction>"
```

If none survive deduplication, skip to Step 5.

**Approve with one multi-select.** Under `AUTO=1`, skip this: write each candidate as a proposal (Auto mode) and go to Step 5. Otherwise call `AskUserQuestion` once for the whole list, every question `multiSelect: true`:

| Field | Value |
|---|---|
| question | "Which learnings should I save?" (add "(n of m)" when batched) |
| header | `Learnings` |
| option label | the learning's title, 5 words max |
| option description | new: `<category>: <one-line gist>`; update: `update: <what changes>` |

Each question takes 2–4 options and one call takes up to 4 questions, so:

- **1 learning:** the API rejects a one-option question. Ask single-select instead, options `Save` (description as above) and `Drop`.
- **2–16:** as few questions as needed, 2–4 options each (5 → 3 + 2, never 4 + 1).
- **More than 16:** ask about the first 16 and write the rest, unapproved, to `working/` (agent-memory skill §5 naming, with frontmatter). Tell the user they're there.

Then act on the answer:

- **Selected:** write it to `learnings/<category>/` with `confidence: high` (agent-memory skill §4 frontmatter), or patch the existing note for an update.
- **Not selected:** drop it, and don't propose it again this sync.
- **"Other" text:** an edit to the learning it names; apply it if that learning was selected. If it names an unselected learning or none, ask one plain follow-up rather than guess.

A standard sync and `--ingest` write learnings only through this prompt (`--dream` approves through its report). Once written, a correction is surfaced by `prompt-corrections.sh` whenever a later prompt touches that topic (its index is rebuilt at SessionStart).

### Step 5: Update Project Index

Read `5 Agent Memory/project-index.md` and **replace** (never append to) the project's row:
- Last session date
- Status: one short sentence
- Latest key decision: one short sentence — the single most recent, not a running list

Hard rules: each cell under 120 characters, no bold headlines, no wikilinks, no narrative. Detail belongs in the session note. If the project isn't in the index, add a row.

Before writing, check the result with:

```bash
# ponytail: any row over 400 chars means narrative crept in — rewrite that row, do not write the file
# (`length` with no field reference on purpose: slash-command argument substitution rewrites dollar-digit tokens)
awk '/^\| / && length > 400 { print "ROW TOO LONG at line " NR; bad=1 } END { exit bad }' "<vault>/5 Agent Memory/project-index.md"
```

### Step 6: Clean Up Staging

After the session note is written:

1. **Handoff scratch**: this slot's `handoff.md` and `handoff.consumed.md` are superseded by the vault note. Delete them.
2. **Session meta**: this session's `message_count` goes back to 0.
3. **Synced flag**: this session's meta gets `synced=true` and `synced_at=<epoch>` (SessionEnd reads the flag; Chief compares the time with a ticket's start), and the slot's stale `.unsynced` marker goes.

Only this session's meta changes, so a sync in a lead never marks Sam's session synced, or the other way round.

```bash
HOOKS="$HOME/.claude/hooks"
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -d "${CLAUDE_PLUGIN_ROOT}/hooks" ]] && HOOKS="${CLAUDE_PLUGIN_ROOT}/hooks"
SLOT=$(bash "$HOOKS/state-lib.sh" paths --session "${CLAUDE_SESSION_ID}" | sed -n 's/^SLOT_DIR=//p')
[[ -n "$SLOT" ]] && rm -f "$SLOT/handoff.md" "$SLOT/handoff.consumed.md"
bash "$HOOKS/state-lib.sh" mark synced --session "${CLAUDE_SESSION_ID}"
```

`MARKED: synced` means done. A fresh SessionStart gives the next session its own meta, so `synced=true` applies only to this session.

### Step 7: Confirm

Tell the user (under `AUTO=1`, as plain lines with no offer or question):
- What was written and where
- Learnings written, and how many were dropped or left in `working/`
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
search vault for "<key phrase from auto-memory>"
```

Skip anything already captured in vault learnings or sessions.

### Step 3: Write New Items

For each genuinely new item from auto-memory:
- If it's a preference/pattern → propose as learning through the Standard Sync Step 4 multi-select
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
read note "5 Agent Memory/project-index.md"
list folder "5 Agent Memory/sessions/by-project/<slug>/"
list folder "5 Agent Memory/learnings/"
```

If `_decisions.md` exists, read it:

```
read note "5 Agent Memory/sessions/by-project/<slug>/_decisions.md"
```

Read the 2-3 most recent session notes (frontmatter only) to understand what's already been captured.

Build a mental map: what topics are covered, what decisions are logged, what learnings exist. This is the deduplication baseline — dream only extracts what's genuinely new.

### Dream Phase 2: Gather Signal

Find recent JSONL session transcripts for the current project. They sit directly in `~/.claude/projects/<encoded-cwd>/`, not in a `sessions/` subfolder. Step 0 printed this session's transcript (`TRANSCRIPT`, from the hooks' per-session breadcrumb), so its directory is the project's transcript folder:

```bash
# The path may be a Windows one (backslashes): convert before dirname, or it returns "."
DIR=$(dirname "$(printf '%s' '<TRANSCRIPT>' | tr '\\' '/')")
# Skip headless `claude -p` runs (entrypoint sdk-cli): they are agent tests, not conversations
find "$DIR" -maxdepth 1 -name '*.jsonl' -mtime -7 2>/dev/null \
  | while IFS= read -r f; do grep -q '"entrypoint":"sdk-cli"' "$f" || printf '%s\n' "$f"; done \
  | sort -r | head -20
```

If `DIR` is `.` or doesn't exist, or the list is empty, say so in the report (`Transcripts scanned: 0 — <reason>`). Never report a silent zero.

**Token-efficient scanning strategy — never read full transcript files:**

1. **Grep first** — use the Grep tool to pattern match against JSONL files. This returns only matching lines with surrounding context, not entire files.

2. **Extract content with jq** — pipe the matching lines through jq to get just the user's words:

```bash
# User entries are type "user"; content is a string or an array of blocks.
# Drops tool results, meta entries and injected <command>/<system-reminder> text.
grep -h -i -E '<signal pattern>' "<transcript>" \
  | jq -r 'select(.type == "user" and (.isMeta | not)) | .message.content
           | if type == "string" then . else (map(select(.type == "text") | .text) | join(" ")) end
           | select(length > 0 and (startswith("<") | not))' 2>/dev/null
```

3. **Read context only for high-confidence hits** — if a grep match looks promising, read 5-10 surrounding lines from the JSONL file to verify the context.

**Signal patterns to grep for:**

| Signal Type | Grep Pattern | Destination |
|------------|-------------|-------------|
| Corrections | `actually\|no,\|"no \|wrong\|incorrect\|not right\|stop doing\|I meant` (`"no ` catches a message that opens with "no") | `learnings/corrections/` |
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

Use `search vault for "<key phrase>"` for each finding.

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
search vault frontmatter for status == "complete" under "5 Agent Memory/sessions/"
# REST server: search_query with JsonLogic; mcp-obsidian: search_notes(searchFrontmatter=true)
```

For each session older than 90 days with `status: complete` and no `promoted_to` field, add to the prune list in the dream report.

This absorbs the existing `--tidy` behaviour. Running `/memory-sync --tidy` now routes to this phase.

#### 4.2 Rebuild Project Index

Read `5 Agent Memory/project-index.md`. For the current project:
- Update last session date
- Update session count
- Update any other stale fields

```
patch note "5 Agent Memory/project-index.md": replace this project's row only (never rewrite the whole table)
```

#### 4.3 Date Normalisation

Scan recent vault notes (last 30 days of session notes for this project) for relative dates:
- "yesterday", "today", "last week", "next Monday", etc.

Convert each to an absolute date based on the note's `created` frontmatter date. Patch the note for each replacement.

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
- **Decisions** → append to `_decisions.md` by appending to the note
- **Learnings** → write to appropriate `learnings/<category>/` subfolder by writing the note
- **Contradictions** → user states which version to keep; update or remove the stale record
- **Auto-memory items** → write to stated destination
- **Stale sessions** → move to archive or delete (as user directs)
- **Date corrections** → patch the note

Unchecked items are discarded.

After writing approved items, update the dream timestamp (Phase 4.4).
