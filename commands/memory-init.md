---
description: "Initialise a project for the memory system. Detects project from repo/folder, creates CLAUDE.md with memory metadata, sets up Obsidian folder structure, loads prior context. Run this once per project or re-run to refresh. The /init on steroids."
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
  - "Bash"
  - "Read"
  - "Write"
  - "Edit"
  - "Glob"
  - "Grep"
  - "Agent"
---

# /memory-init

Initialise this project for the persistent memory system. $ARGUMENTS

If $ARGUMENTS contains a project name/slug, use that. Otherwise, auto-detect.

## Phase 1: Detect Project Identity

Run these detection steps and collect results. Don't ask for confirmation until you have everything.

### 1.1 Git Remote

```bash
git remote get-url origin 2>/dev/null || echo ""
```

Extract repo name: `git@github.com:user/repo-name.git` → `repo-name`

### 1.2 Project Manifest

Check in order, stop at first hit:
- `package.json` → `.name` field
- `pyproject.toml` → `name` under `[project]`
- `Cargo.toml` → `name` under `[package]`
- `go.mod` → module path
- `*.sln` → solution name
- `terraform` files → terraform project

### 1.3 Existing CLAUDE.md

```bash
cat .claude/CLAUDE.md 2>/dev/null | grep 'memory:project-slug' || echo "none"
```

### 1.4 Directory Name

```bash
basename "$PWD"
```

### 1.5 README

If `README.md` exists, read the first 50 lines for project description.

### 1.6 Tech Stack Detection

```bash
# Detect languages and frameworks
ls -la *.py pyproject.toml requirements.txt setup.py 2>/dev/null    # Python
ls -la package.json tsconfig.json 2>/dev/null                        # Node/TS
ls -la Cargo.toml 2>/dev/null                                        # Rust
ls -la go.mod 2>/dev/null                                            # Go
ls -la *.tf 2>/dev/null                                              # Terraform
ls -la Dockerfile docker-compose* 2>/dev/null                        # Docker
ls -la .github/workflows/* 2>/dev/null                               # CI/CD
```

### 1.7 Infer Area

Based on detected stack and repo content, infer the Obsidian area:
- AWS SDKs, CloudFormation, Terraform with AWS → `AWS`
- Azure SDKs, ARM templates, Terraform with Azure → `Azure`
- ML libraries, AI APIs, LLM tooling → `AI`
- Blog content, markdown posts → `Blog`
- General tooling → `Personal`

### 1.8 Check Obsidian for Prior History

```
search_notes(query="<detected-slug>", searchContent=true)
```

Search `5 Agent Memory/sessions/` and `5 Agent Memory/learnings/` for any prior work on this project.

Also check `5 Agent Memory/project-index.md` for an existing entry.

## Phase 2: Confirm with the User

Present all detected values in a single confirmation block:

```
## Memory Init — Detected Configuration

| Field | Value | Source |
|-------|-------|--------|
| Project slug | `my-web-app` | git remote |
| Display name | My Web App | README.md |
| Area | Personal | tech stack inference |
| Vault path | 1 Projects/Personal/my-web-app | inferred |
| Tech stack | Node.js, React, PostgreSQL | detected files |
| Build command | `npm run build` | package.json |
| Test command | `npm test` | detected |

### Prior Context
Found 3 prior sessions and 2 learnings related to this project.
Most recent: 2026-03-15 — "API redesign planning"

**Confirm these values, or tell me what to change.**
```

If git history is detected (more than 0 commits), add a row to the table:

```
| Analyse codebase | Yes/No | git history detected (N commits) |
```

This row controls whether Phase 4.6 (Codebase Analysis) runs. Default suggestion is "Yes" for repos with 10+ commits, "No" for fewer.

Wait for the user's confirmation or corrections before proceeding.

## Phase 3: Create Project CLAUDE.md

Create or update `.claude/CLAUDE.md` with the confirmed values.

**If `.claude/CLAUDE.md` already exists**, merge — don't overwrite. Add the memory metadata comments and any missing sections. Preserve existing project-specific rules.

**If creating from scratch**, use this structure:

```markdown
# <Display Name>

<!-- memory:project-slug=<slug> -->
<!-- memory:area=<area> -->
<!-- memory:vault-path=<vault-path> -->

## Overview

<Description from README or user input. 1-3 sentences.>

## Tech Stack

- **Language:** <detected>
- **Framework:** <detected>
- **Infra:** <detected>
- **Key deps:** <from manifest>

## Build & Test

\`\`\`bash
# Install
<detected or prompted>

# Run
<detected or prompted>

# Test
<detected or prompted>

# Lint
<detected or prompted>
\`\`\`

## Architecture

<Brief description from codebase scan. Key directories, entry points, patterns.>
<If unknown, leave a TODO for the user to fill in.>

## Memory

This project uses the persistent memory system.
- **Obsidian sessions:** `5 Agent Memory/sessions/by-project/<slug>/`
- **Area:** `<area>`
- **Related vault notes:** `<vault-path>`

On session start, search for prior context before starting non-trivial work.
On session end, run `/memory-sync` if significant decisions or progress were made.

## Project-Specific Rules

<Leave empty for the user to populate. Add a comment: "Add project-specific rules here.">
```

### 3.1 Write Persistent State File

After creating/updating `.claude/CLAUDE.md`, write the state file:

```bash
cat > .claude/memory-state.json << 'STATEJSON'
{
  "slug": "<confirmed-slug>",
  "area": "<confirmed-area>",
  "sessionPath": "5 Agent Memory/sessions/by-project/<confirmed-slug>/",
  "detectedVia": "memory-init",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "<current-ISO-timestamp>"
}
STATEJSON
```

This ensures the state file exists immediately, rather than waiting for the next SessionStart hook to create it.

## Phase 4: Create Obsidian Structure

Via MCP-Obsidian:

### 4.1 Session Folder

```
list_directory("5 Agent Memory/sessions/by-project/")
```

If `<slug>/` doesn't exist:
```
write_note("5 Agent Memory/sessions/by-project/<slug>/.gitkeep", "")
```

Or create an index note:
```
write_note("5 Agent Memory/sessions/by-project/<slug>/_index.md", <content>)
```

With content:
```yaml
---
title: "<Display Name> — Session Index"
created: <today>
type: index
project: "<slug>"
area: "<area>"
---

# <Display Name> Sessions

Session history for the <display name> project.

## Quick Reference
- **Slug:** `<slug>`
- **Area:** `<area>`  
- **Vault path:** `<vault-path>`
- **Init date:** <today>
```

### 4.2 Project Index Update

Read `5 Agent Memory/project-index.md`.

If project exists in the table → update the row.
If project doesn't exist → add a new row.

If `project-index.md` doesn't exist → create it using the template from the architecture docs.

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

## Phase 5: Load and Present Context

If prior sessions or learnings were found in Phase 1.8:

1. Read the most recent resumable session (full content)
2. Read the most recent completed session (frontmatter + summary only)
3. List relevant learnings (frontmatter only)

Present:

```
## Context Loaded

**Last session:** <date> — <topic>
  Status: <status>
  Decisions: <list>
  Open items: <list>

**Relevant learnings:**
- <learning 1>
- <learning 2>

Ready to work on <project>. What are we doing today?
```

If `_decisions.md` exists and has entries, include in the context output:

```
**Decisions log:** <N> decisions recorded. Most recent: "<most recent decision title>" (<date>)
```

If no prior context exists:

```
## Fresh Start

No prior sessions found for <slug>. This is a clean slate.
I'll log this session when we're done if it's significant.

What are we building?
```

## Phase 6: Check for Auto-Memory

If `~/.claude/projects/` contains a directory matching this project:

```bash
ls ~/.claude/projects/*/memory/MEMORY.md 2>/dev/null
```

If auto-memory exists, mention it:

```
Found Claude Code auto-memory for this project. Run `/memory-sync --ingest`
to pull any useful items into the Obsidian vault.
```

## Re-run Behaviour

`/memory-init` is idempotent. On re-run:

1. Detects existing configuration (reads `.claude/CLAUDE.md` metadata)
2. Shows current vs detected values
3. Updates if anything changed (new dependencies, build commands)
4. Refreshes Obsidian context load
5. Never overwrites project-specific rules or custom sections

Think of re-running as a "refresh and resync" — not a destructive reset.
