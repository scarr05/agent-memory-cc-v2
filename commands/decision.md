---
description: "Log a decision to the project's _decisions.md without a full session sync. Use for ad-hoc decisions in quick conversations."
allowed-tools:
  - "mcp__obsidian__read_note"
  - "mcp__obsidian__write_note"
  - "mcp__obsidian__search_notes"
  - "mcp__obsidian__patch_note"
  - "mcp__obsidian__get_frontmatter"
  - "mcp__obsidian__update_frontmatter"
  - "mcp__obsidian__list_directory"
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

If `_decisions.md` doesn't exist, create it using the template from `config/decisions-template.md`, replacing `<Display Name>`, `<slug>`, and `<date>` placeholders with the actual values.

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
