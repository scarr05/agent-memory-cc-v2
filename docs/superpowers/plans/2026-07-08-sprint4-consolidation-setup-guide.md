# Sprint 4 — Context Consolidation & Setup Guide v5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure and cut session-start context bloat (17 plugins, 12 personal skills, multiple MCP servers), then write the definitive fresh-install guide reflecting the optimised setup.

**Architecture:** Evidence-first: measure baseline context, build a keep/cut table grounded in the 418-session usage corpus, get Sam's approval (mandatory — this changes behaviour across all his projects), apply, re-measure. The setup guide is written LAST so it describes the post-cut state.

**Tech Stack:** PowerShell/bash for inventory, `~/.claude/settings.json` edits, Markdown.

## Global Constraints

- Repo: `~/Documents/Projects/agent-memory-cc-v2-files`. Branch: `git checkout -b sprint4-consolidation-guide`.
- **Nothing is disabled without Sam's explicit approval of the keep/cut table** (Task 2 → Task 3 gate). Decision on record (2026-07-08): "audit + apply agreed cuts".
- Back up `~/.claude/settings.json` before editing: `cp ~/.claude/settings.json ~/.claude/settings.json.bak-sprint4`.
- Disabled ≠ deleted: plugins are turned off in settings, personal skills are moved to a repo `archive/` dir (recoverable), never rm'd outright.
- British English.

---

### Task 1: Baseline measurement + inventory

**Files:**
- Create: `docs/consolidation-2026-07.md` (working note; the keep/cut table lives here)

**Interfaces:**
- Produces: baseline token/percentage figures and the full inventory that Task 2 scores.

- [ ] **Step 1: Record the baseline**

Open a fresh Claude Code session in any memory-enabled project (e.g. float-platform). Before typing anything, record the context % from the statusline. Then run `/context` (if available on this CC version) and record the breakdown: system prompt, skills list, MCP tools, CLAUDE.md, hook-injected context. Paste the numbers into `docs/consolidation-2026-07.md` under `## Baseline`.

- [ ] **Step 2: Enumerate everything loaded**

```bash
jq -r '.enabledPlugins | to_entries[] | .key' ~/.claude/settings.json   # 17 plugins (as of 2026-07-08: code-simplifier, typescript-lsp, context7, code-review, superpowers, commit-commands, security-guidance, claude-md-management, skill-creator, aws-serverless, feature-dev, frontend-design, pr-review-toolkit, claude-code-setup, codex, aws-core, ponytail)
ls ~/.claude/skills/                                                     # 12 personal skills
jq -r '.mcpServers | keys[]' ~/.claude/.mcp.json 2>/dev/null || claude mcp list   # MCP servers (obsidian, aws-documentation, aws-iac, aws-mcp, claude-in-chrome, ...)
ls ~/.claude/plugins/cache/                                              # note the two stale temp_subdir clone dirs
```

Add each item as a row in the inventory table (Step 3's format).

- [ ] **Step 3: Score usage from the transcript corpus**

For each plugin/skill/server, count invocations across the audit corpus:

```bash
for s in agent-memory brightsolid-voice chatgpt-to-obsidian document-builder drawio graphify obsidian-vault-manager prompt-optimiser sam-carr-unified-voice sam-humaniser skill-creator spec-builder; do
  n=$(grep -l "\"skill\"[: ]*\"$s\"\|/$s" ~/.claude/projects/*/*.jsonl 2>/dev/null | wc -l)
  echo "$s: $n sessions"
done
# Plugins: grep for their command/skill slugs the same way, e.g.:
for p in aws-serverless aws-core feature-dev frontend-design pr-review-toolkit claude-code-setup typescript-lsp codex commit-commands; do
  n=$(grep -l "$p" ~/.claude/projects/*/*.jsonl 2>/dev/null | wc -l)
  echo "$p: $n sessions"
done
```

Populate the table in `docs/consolidation-2026-07.md`:

```markdown
## Inventory

| Item | Type | Context cost (what it injects) | Sessions used (of 418) | Verdict (proposed) |
|------|------|-------------------------------|------------------------|--------------------|
```

Verdict heuristics (proposals only — Sam decides): 0–2 sessions in 6 weeks → cut; overlapping capability (pr-review-toolkit vs code-review vs feature-dev's reviewer; skill-creator plugin vs personal skill-creator skill; voice skills superseded by sam-carr-unified-voice) → keep one, cut the rest; used-but-rarely with heavy injection → cut, re-enable on demand.

Known candidates flagged by the audit (verify, don't assume): the two `temp_subdir` clone dirs in the plugin cache (pure cruft — delete), pr-review-toolkit (overlaps code-review), brightsolid-voice (explicit-invocation only — check usage), chatgpt-to-obsidian (check usage), aws-serverless vs aws-core overlap.

- [ ] **Step 4: Commit the analysis**

```bash
git add docs/consolidation-2026-07.md
git commit -m "docs: consolidation baseline + inventory with usage counts"
```

---

### Task 2: Approval gate

**Files:** none (conversation step).

- [ ] **Step 1: Present the keep/cut table to Sam**

Show the table with a one-line rationale per proposed cut and the estimated context saving. **STOP and wait for explicit approval of each cut.** Record his answers in the table (`Verdict (approved)` column). Do not proceed to Task 3 with any unresolved row.

---

### Task 3: Apply the cuts

**Files:**
- Modify: `~/.claude/settings.json` (`enabledPlugins` map)
- Modify: `config/settings.json` (repo template — mirror the same plugin list)
- Create: `archive/skills/` in this repo (destination for cut personal skills)
- Modify: `docs/consolidation-2026-07.md` (record what was done + after-measurement)

- [ ] **Step 1: Back up**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.bak-sprint4
```

- [ ] **Step 2: Apply plugin cuts**

For each approved plugin cut, set its entry to `false` (or remove it) in `enabledPlugins` in `~/.claude/settings.json`, and mirror in `config/settings.json`. Delete the stale clone dirs:

```bash
rm -rf ~/.claude/plugins/cache/temp_subdir* 2>/dev/null || true
```

- [ ] **Step 3: Archive cut personal skills**

```bash
mkdir -p archive/skills
# per approved cut:
git mv --force skills/<name> archive/skills/<name> 2>/dev/null || mv ~/.claude/skills/<name> archive/skills/<name>
rm -rf ~/.claude/skills/<name>
```

(Personal skills that aren't in this repo yet get moved INTO `archive/skills/` so they remain recoverable and versioned.)

- [ ] **Step 4: Remove approved MCP server cuts**

`claude mcp remove <name>` per approved cut (or edit the relevant `.mcp.json`).

- [ ] **Step 5: Re-measure**

Fresh session in the same project as Task 1 Step 1; record the new context % / `/context` breakdown in `docs/consolidation-2026-07.md` under `## After`. Include the delta in plain numbers ("session-start context: X% → Y%").

- [ ] **Step 6: Smoke test**

In the fresh session confirm: memory hooks still fire (SessionStart context block appears), a kept skill still triggers, no error toast about missing plugins.

- [ ] **Step 7: Commit**

```bash
git add config/settings.json docs/consolidation-2026-07.md archive/
git commit -m "feat: apply approved consolidation cuts - before/after context measurements recorded"
```

---

### Task 4: Setup guide v5

**Files:**
- Create: `docs/setup-guide-v5.md`
- Modify: `docs/setup-guide-v4.md` (deprecation banner at top only)

**Interfaces:**
- Consumes: post-cut plugin list (Task 3), `config/global-claude-md-v2.md` (Sprint 1 output), `scripts/aws/` + `skills/float-ops` (Sprint 3), install mechanics from setup-guide-v4 (plugin install path — reuse its wording where still accurate).

- [ ] **Step 1: Write the guide**

`docs/setup-guide-v5.md` — a checklist a fresh Claude Code install executes top to bottom. Required sections, each with exact commands:

```markdown
# Fresh Claude Code Setup (v5)

One pass, top to bottom, on a new machine. Everything lives in
https://github.com/scarr05/agent-memory-cc-v2 — clone it first.

## 1. Prerequisites
- Claude Code installed and authenticated
- Git Bash + jq (Windows: ship with Git / winget install jqlang.jq)
- Obsidian 1.12+ with CLI enabled, scarr-Brain vault
- AWS CLI v2; gh CLI authenticated
- Python 3 + Pillow (render_verify)

## 2. Clone
git clone https://github.com/scarr05/agent-memory-cc-v2.git ~/Documents/Projects/agent-memory-cc-v2-files

## 3. Memory system (hooks, agents, commands)
<install steps carried over from setup-guide-v4 Option A/B — verify each still matches the repo, copy the working text>
Includes the read-once hook (PreToolUse on Read, warn mode) — already part of the hook set.

## 4. Global CLAUDE.md
cp config/global-claude-md-v2.md ~/.claude/CLAUDE.md
(contains the Windows gotchas, Codex on-demand rule, findings flat-array rule)

## 5. Plugins (post-consolidation list)
<the exact approved list from docs/consolidation-2026-07.md, one /plugin install line each>

## 6. MCP servers
<the kept list with add commands: obsidian, context7, ...>

## 7. Personal skills
cp -r skills/* ~/.claude/skills/   (float-ops and any others versioned here)
<list any skills that live only in ~/.claude/skills and where to get them>

## 8. AWS
aws configure sso   # profile name MUST be float-management, management account
aws sso login --profile float-management
See docs/float-landing-zone.md for account structure.

## 9. Verify
- Fresh session in a memory-enabled project: SessionStart block appears, slug correct
- bash tests/hook-validation.sh → FAIL=0
- bash scripts/aws/cw-dash.sh 1 → metric table
- Context % at session start ≈ the post-consolidation baseline in docs/consolidation-2026-07.md
```

Every `<...>` above is filled with real values at write time from the named sources — the committed guide contains zero angle-bracket placeholders.

- [ ] **Step 2: Deprecate v4**

Prepend to `docs/setup-guide-v4.md`:

```markdown
> **Superseded by [setup-guide-v5.md](setup-guide-v5.md)** (2026-07 — post-consolidation plugin list, global CLAUDE.md master, AWS/float setup). v4 retained for the pre-consolidation record only.
```

- [ ] **Step 3: Verify by walkthrough**

Read v5 end to end and execute the Verify section's commands on THIS machine — all must pass. (A true fresh-machine run happens next time Sam sets one up; the guide notes are good enough when every command has been executed once.)

- [ ] **Step 4: Commit and merge**

```bash
git add docs/setup-guide-v5.md docs/setup-guide-v4.md
git commit -m "docs: setup guide v5 - fresh install checklist for the optimised setup"
git checkout main && git merge sprint4-consolidation-guide && git branch -d sprint4-consolidation-guide
```
