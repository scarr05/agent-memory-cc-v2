# Memory Patterns Reference v2

Templates and patterns for memory operations. Updated for project-scoped sessions, tiered storage, and hook integration.

---

## Session Templates

### Standard Session

Write to: `5 Agent Memory/sessions/by-project/<slug>/YYYY-MM-DD-brief-topic.md`

```markdown
---
title: "Session - [Brief Topic]"
created: YYYY-MM-DDTHH:MM:SS
type: session
status: complete
project: "[project-slug]"
area: "[area]"
tags: []
decisions: []
outcomes: []
follow_up: []
resumable: false
promoted_to: ""
source_agent: "claude-code"
---

## Context
[Why this session happened]

## Progress
[What was accomplished]

## Decisions
- [Decision]: [Rationale]

## Outcomes
- [Output or result]

## Open Items
- [ ] [Follow-up if any]
```

### Spec-Driven Planning Session

```markdown
---
title: "Session - [Project] Planning"
created: YYYY-MM-DDTHH:MM:SS
type: session
status: complete
project: "[project-slug]"
area: "[area]"
tags: [planning, spec]
decisions: 
  - "[Key architectural decision]"
  - "[Technology choice]"
outcomes:
  - "Spec document created"
follow_up:
  - "Implementation phase"
resumable: true
promoted_to: ""
source_agent: "claude-code"
---

## Context
Planning session for [project]. Goal: [what we needed to decide].

## Spec Summary
[High-level summary of the spec]

## Key Decisions

### [Decision 1]
- **Choice:** [What was decided]
- **Rationale:** [Why]
- **Alternatives considered:** [What was rejected and why]

## Out of Scope
- [Explicitly excluded items]

## Implementation Notes
[Anything relevant for implementation phase]

## Resumption Notes
To continue: [what to read/know to pick this up fresh]
```

### Long Conversation Checkpoint

Written proactively before compaction, or triggered by PreCompact hook.

```markdown
---
title: "Session - [Topic] Checkpoint"
created: YYYY-MM-DDTHH:MM:SS
type: session
status: in-progress
project: "[project-slug]"
area: "[area]"
tags: [checkpoint]
decisions: []
outcomes: []
follow_up: []
resumable: true
source_agent: "claude-code"
---

## Session So Far
[Summary of ground covered]

## Current State
[Where we are right now]

## Decisions Made
- [Decision 1]
- [Decision 2]

## Open Threads
- [Thing we were discussing]
- [Question still pending]

## Files/Artifacts
- [Links to any created files]
- [References to working/ scratchpad]

## To Continue
[Exact next step to resume]
```

### U-Turn / Direction Change

```markdown
---
title: "Session - [Topic] Direction Change"
created: YYYY-MM-DDTHH:MM:SS
type: session
status: complete
project: "[project-slug]"
area: "[area]"
tags: [u-turn, decision]
decisions:
  - "Changed from [old] to [new]"
outcomes: []
follow_up: []
resumable: false
source_agent: "claude-code"
---

## Original Direction
[What we were doing / planning]

## Why It Changed
[What prompted the U-turn]

## New Direction
[What we're doing instead]

## Implications
- [Impact on other work]
- [Things that need updating]

## Lessons
[What to remember for similar situations]
```

---

## Staging Checkpoint Template

Written by PreCompact hook to `~/.claude/memory-staging/<slug>/checkpoint-YYYY-MM-DD.md`.
The agent fills in the `[To be filled]` sections and then pushes to Obsidian `working/`.

```markdown
---
type: checkpoint
project-slug: [slug]
created: YYYY-MM-DDTHH:MM:SSZ
session-start: YYYY-MM-DDTHH:MM:SSZ
messages-before-compact: [N]
status: pending
---

## Pre-Compaction Checkpoint

## Session State
[Fill: summarise decisions, progress, current state]

## Key Files Modified
[Fill: list files changed this session]

## Next Steps
[Fill: what was about to happen before compaction]
```

After filling in and writing to Obsidian, delete the staging file.

---

## Learning Templates

Write to: `5 Agent Memory/learnings/<category>/[topic].md`

Categories: `preferences/`, `technical/`, `workflow/`, `corrections/`

### Preference Learning

```markdown
---
title: "Learning - [Topic] Preference"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: learning
category: preference
confidence: high
project: ""
area: ""
tags: []
source_session: "YYYY-MM-DD-session-name"
---

## Preference
[Clear statement of the preference]

## Context
[When this applies]

## Evidence
[How this was confirmed]

## Examples
- Do: [Example of correct approach]
- Don't: [Example of what to avoid]
```

### Technical Learning

```markdown
---
title: "Learning - [Topic] Technical"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: learning
category: technical
confidence: high
project: ""
area: ""
tags: []
source_session: "YYYY-MM-DD-session-name"
---

## Pattern
[Clear statement of the technical pattern or decision]

## Rationale
[Why this approach was chosen]

## Applies To
[Which projects/areas/technologies]

## Example
[Code snippet or config example if applicable]
```

### Workflow Learning

```markdown
---
title: "Learning - [Process] Workflow"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: learning
category: workflow
confidence: high
project: ""
area: ""
tags: []
source_session: "YYYY-MM-DD-session-name"
---

## Workflow
[Name of the workflow]

## Steps
1. [Step 1]
2. [Step 2]
3. [Step 3]

## Tools/Resources
- [Tool or resource used]

## Notes
[Any caveats or variations]
```

### Correction Learning

```markdown
---
title: "Learning - [Topic] Correction"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: learning
category: correction
confidence: high
project: ""
area: ""
tags: []
source_session: "YYYY-MM-DD-session-name"
---

## What Was Wrong
[The incorrect assumption or action]

## Correct Approach
[What should be done instead]

## Why
[Explanation if relevant]
```

---

## Working Scratchpad Patterns

Write to: `5 Agent Memory/working/YYYY-MM-DD-task-description.md`

No approval needed. Clean up when complete.

### Task Context

```markdown
---
title: "Working - [Task]"
created: YYYY-MM-DDTHH:MM:SS
type: working
task: "[brief description]"
project: "[slug]"
status: in-progress
---

## Goal
[What we're trying to accomplish]

## Current State
[Where we are]

## Notes
[Working notes, data, intermediate results]

## Next Steps
- [ ] [Next action]
```

### Research Notes

```markdown
---
title: "Working - Research [Topic]"
created: YYYY-MM-DDTHH:MM:SS
type: working
task: "research"
project: "[slug]"
---

## Question
[What we're researching]

## Findings
[Notes as we go]

## Sources
- [Source 1]

## Conclusions
[To be filled when complete]
```

---

## Project Index Template

Lives at: `5 Agent Memory/project-index.md`

Updated by `/memory-sync` and `/memory-init`.

```markdown
---
title: "Project Index"
created: YYYY-MM-DD
modified: YYYY-MM-DD
type: index
tags: [memory, index]
---

# Project Index

| Project | Slug | Area | Last Session | Status | Key Decisions |
|---------|------|------|--------------|--------|---------------|
| My Web App | my-web-app | Personal | 2026-03-18 | active | React, PostgreSQL |
| Infrastructure | infrastructure | AWS | 2026-03-01 | active | Terraform, multi-account |
```

---

## Search Patterns

### Find prior work on a project (slug-based)

```
search_notes(query="<project-slug>", searchContent=true)
```

### Find sessions in a specific project folder

```
list_directory("5 Agent Memory/sessions/by-project/<slug>/")
```

### Find resumable sessions

```
search_notes(query="resumable: true", searchFrontmatter=true)
```

### Find learnings by category

```
list_directory("5 Agent Memory/learnings/preferences/")
list_directory("5 Agent Memory/learnings/technical/")
```

### Find sessions from a specific agent

```
search_notes(query="source_agent: claude.ai", searchFrontmatter=true)
```

---

## Tag Conventions

### Session Tags
- `planning` — Spec/planning phase
- `implementation` — Building phase
- `review` — Review/feedback phase
- `checkpoint` — Mid-session save (manual or hook-triggered)
- `u-turn` — Direction change
- `decision` — Contains key decisions

### Learning Tags
- `formatting` — Output formatting preferences
- `communication` — How to communicate
- `technical` — Technical preferences
- `workflow` — Process preferences

### Project/Area Tags
Use consistent names matching folder structure:
- Projects: `brightsolid`, `druva`, `personal`, `blog`
- Areas: `aws`, `azure`, `ai`, `finops`, `devops`
