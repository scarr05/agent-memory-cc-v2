# Sprint 1 — CLAUDE.md Quick Wins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill three recurring transcript-audit time sinks with pure documentation edits: the Codex-mandate contradiction, the Windows platform tax, and the security-review nested-findings retry loop.

**Architecture:** Every change edits TWO files identically: the live `~/.claude/CLAUDE.md` and its versioned master `config/global-claude-md-v2.md` in this repo. The repo copy is the source of truth for fresh installs (setup guide v5, Sprint 4).

**Tech Stack:** Markdown only. No code, no tests — verification is grep.

## Global Constraints

- British English throughout (organisation, behaviour).
- The two files must end up byte-identical in the edited sections — diff them after each task.
- Commit after each task, message prefix `docs:`.
- Repo path: `C:\Users\user\Documents\Projects\agent-memory-cc-v2-files` (bash: `~/Documents/Projects/agent-memory-cc-v2-files`). Work on a branch: `git checkout -b sprint1-claude-md-quick-wins`.
- Context note: `~/.claude/CLAUDE.md` is loaded into every session — keep additions terse; every line added is a permanent token cost.

---

### Task 1: Codex reconciliation

Background: global CLAUDE.md mandates Codex review of all specs/plans, but a vault correction bans default Codex use after it fabricated findings twice. Decision (Sam, 2026-07-08): on-demand only.

**Files:**
- Modify: `~/.claude/CLAUDE.md` (section "## Development Workflow (MANDATORY)")
- Modify: `config/global-claude-md-v2.md` (same section)

**Interfaces:**
- Produces: the reconciled Codex rule text that Sprint 4's setup guide references verbatim.

- [ ] **Step 1: Locate the current text**

Run: `grep -n "reviewed by codex" ~/.claude/CLAUDE.md config/global-claude-md-v2.md`
Expected: one hit per file, the line reading:

```
All spec and plans will be reviewed by codex and findings passed back in to resolve.
```

(If the repo master lacks the line, only edit the live file and note the divergence in the commit message.)

- [ ] **Step 2: Replace it in both files**

Replace that line (Edit tool, both files) with:

```markdown
Codex review is on-demand only — invoke `/codex:rescue` explicitly when a second opinion is wanted. Never treat Codex findings as authoritative without verification: it has fabricated findings before. It is not a pipeline gate.
```

- [ ] **Step 3: Verify**

Run: `grep -c "on-demand only" ~/.claude/CLAUDE.md config/global-claude-md-v2.md && grep -c "reviewed by codex" ~/.claude/CLAUDE.md config/global-claude-md-v2.md`
Expected: `1` for each file on the first grep; the second grep exits non-zero (no matches).

- [ ] **Step 4: Commit**

```bash
git add config/global-claude-md-v2.md
git commit -m "docs: reconcile Codex rule - on-demand via /codex:rescue, no mandatory gate"
```

(`~/.claude/CLAUDE.md` is outside the repo; only the master copy is committed.)

---

### Task 2: Windows gotchas section

Background: 20+ transcript incidents of the same Windows traps re-derived from scratch.

**Files:**
- Modify: `~/.claude/CLAUDE.md` (insert new section after "## Technical Preferences")
- Modify: `config/global-claude-md-v2.md` (same position)

**Interfaces:**
- Produces: a `## Windows` section that the setup guide (Sprint 4) lists as required global-CLAUDE.md content.

- [ ] **Step 1: Insert the section in both files**

Insert after the `## Technical Preferences` section's last line:

```markdown
## Windows

This machine is Windows 11; Bash tool = Git Bash (MSYS), PowerShell also available. Known traps — apply pre-emptively, don't rediscover:

- MSYS mangles leading-slash args (`/c/...` rewrites). Prefix `MSYS_NO_PATHCONV=1` or use relative/Windows paths.
- CRLF: `sed` won't strip `\r` — use `tr -d '\r'`. Shell scripts must stay LF (`.gitattributes` pins `eol=lf`).
- `/tmp` in Git Bash is not the Windows temp dir and PowerShell can't see it — use the session scratchpad dir.
- Python defaults to cp1252: always pass `encoding="utf-8"` on `open()`, and set `PYTHONIOENCODING=utf-8` when piping.
- Stderr silencing: `2>$null` in PowerShell, `2>/dev/null` in bash — never mix.
- `git mv`/deletes fail with "file in use" when node/esbuild watchers hold locks — kill dev servers first.
```

- [ ] **Step 2: Verify**

Run: `grep -c "MSYS_NO_PATHCONV" ~/.claude/CLAUDE.md config/global-claude-md-v2.md`
Expected: `1` per file. Then confirm the sections are identical:
`diff <(sed -n '/^## Windows$/,/^## /p' ~/.claude/CLAUDE.md) <(sed -n '/^## Windows$/,/^## /p' config/global-claude-md-v2.md)` → no output.

- [ ] **Step 3: Commit**

```bash
git add config/global-claude-md-v2.md
git commit -m "docs: add Windows gotchas section - MSYS, CRLF, encoding, file locks"
```

---

### Task 3: Security-review findings-shape correction

Background: review agents returned `{"findings": {"findings": []}}` instead of a flat array 15–20 times in the audit window, each a failed parse + retry. The schema lives in the `security-guidance` plugin (`hooks/review_api.py`, `FINDINGS_SCHEMA`) — plugin-owned, so we can't patch it durably; a standing correction in global CLAUDE.md is the mitigation.

**Files:**
- Modify: `~/.claude/CLAUDE.md` (append to the "## Rules" numbered list)
- Modify: `config/global-claude-md-v2.md` (same)

**Interfaces:**
- Consumes: nothing.
- Produces: rule text; Sprint 4 setup guide references it.

- [ ] **Step 1: Append the rule in both files**

Add as the next number in the existing `## Rules` list (currently ends at 6):

```markdown
7. Security/code-review findings are returned as `{"findings": [...]}` — a FLAT array of finding objects. Never nest a `findings` key inside `findings`.
```

- [ ] **Step 2: Verify**

Run: `grep -c "FLAT array" ~/.claude/CLAUDE.md config/global-claude-md-v2.md`
Expected: `1` per file.

- [ ] **Step 3: Commit**

```bash
git add config/global-claude-md-v2.md
git commit -m "docs: add findings flat-array rule - kills nested-schema retry loop"
```

---

### Task 4: Merge

- [ ] **Step 1: Final diff check**

Run: `git diff main --stat`
Expected: only `config/global-claude-md-v2.md` changed, 3 commits on the branch.

- [ ] **Step 2: Merge**

```bash
git checkout main && git merge sprint1-claude-md-quick-wins && git branch -d sprint1-claude-md-quick-wins
```
