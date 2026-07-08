# Claude Code Workflow Optimisation — Design

**Date:** 2026-07-08
**Status:** Approved 2026-07-08. Plan-phase recon found items 1.3, 2.2 and 2.3 already implemented (Jul 2–7 review-fixes merge: once-per-session nudge flags and handoff token nudge in `stop-memory.sh`; checkpoint-stub mechanism retired in the 2026-06-15 redesign) — dropped from the plans. Item 1.1 confirmed plugin-owned (`security-guidance/hooks/review_api.py`) → CLAUDE.md correction path. Plans: `../plans/2026-07-08-sprint{1..4}-*.md`.
**Source:** Transcript audit of 418 sessions (2026-05-25 → 2026-07-07), 27-chunk parallel Haiku digest, synthesised findings approved by Sam.

## Problem

The audit found seven recurring time sinks. Ranked by cost:

| # | Inefficiency | Evidence |
|---|--------------|----------|
| 1 | Context-ceiling ceremony | 17 compactions in one session; spec re-read 5×; 1,500-word manual re-brief (session 9d49505a); 64 empty checkpoint stubs; stubs manually deleted ×11 (112d0a91) |
| 2 | Security-review gate waste | ~90+ near-identical review sessions; `{"findings": {"findings": []}}` nested-schema bug fired 15–20×; 4 duplicate-pair reviews of identical diffs (one pair 17s apart) |
| 3 | Windows platform tax | 20+ cwd/path errors: MSYS path mangling, CRLF stripping, `/tmp` unreadable, cp1252 encoding, `2>$null` vs `2>/dev/null`, esbuild file locks blocking `git mv` |
| 4 | Manual visual verification | 9 render→crop→inspect cycles for a single draw.io diagram (112d0a91) |
| 5 | AWS diagnostic boilerplate | Same 6-metric CloudWatch queries rebuilt repeatedly; SSM instance-id looked up ×4; `gh run watch` exit code lied with 3 deploys running |
| 6 | Stop-hook nudge repetition | Same memory-sync nudge 7–10× after an explicit pause, across 3 sessions |
| 7 | Codex reliability variance | Fabricated findings twice → vault correction bans default use, but global CLAUDE.md still mandates it |

## Decisions (settled with Sam, 2026-07-08)

| Decision | Choice |
|----------|--------|
| Home for artefacts | **This repo** (agent-memory-cc-v2). Hooks, scripts, config templates, setup guide all versioned here; `~/.claude` is the install target. |
| Codex rule | **On-demand only.** Remove the mandatory spec/plan review gate from global CLAUDE.md; `/codex:rescue` invoked explicitly. This programme's specs/plans skip Codex unless asked. |
| Consolidation depth | **Audit + apply agreed cuts.** Keep/cut table with per-item context cost → Sam approves → disable/uninstall as a sprint task. |
| Sprint structure | **By effort tier** (quick wins → hooks/quota → scripts → consolidation + guide). |
| read-once hook | **Already implemented and working** (wired as PreToolUse on Read, warn mode, 197 active session caches). No build. Optional: document it in the setup guide; leave in warn mode. |

## Non-goals

- No changes to the memory system architecture itself (v4 schema, memberberry/blackbox) beyond the fast-path and stub-discard items.
- No CI/CD or cloud automation — everything runs locally.
- Not rebuilding the superpowers pipeline; the review gates stay, they just stop wasting cycles.

---

## Sprint 1 — Quick wins (each ≤ 1h)

### 1.1 Security-review findings-schema fix
The nested `{"findings": {"findings": []}}` shape fired 15–20 times, each costing a failed parse + retry.
- Locate where the findings schema is stated (repo command vs plugin prompt). If it's in this repo's commands/skills, pin the exact flat JSON shape with a literal example. If it's plugin-owned (not editable), add a one-line correction to global CLAUDE.md: "security-review findings are a flat array — never nest `findings` inside `findings`".
- **Lives in:** repo command file if ours; else global CLAUDE.md.

### 1.2 Windows-gotchas section in global CLAUDE.md
One `## Windows` section listing the recurring traps: MSYS path mangling (`//c/` prefixes), CRLF (`sed` can't strip it — use `tr -d '\r'`), `/tmp` unreadable from PowerShell, cp1252 default encoding (always pass `encoding="utf-8"`), `2>$null` (PS) vs `2>/dev/null` (bash), node/esbuild file locks blocking `git mv` (kill watchers first).
- **Lives in:** global CLAUDE.md; master copy in `config/CLAUDE.global.md` in this repo.

### 1.3 Stop-hook once-only guard
`stop-memory.sh` re-fires the same nudge 7–10× per session. Add a per-session flag file (staging dir already exists per-slug); nudge once, set flag, stay silent after.
- **Lives in:** `hooks/stop-memory.sh` (this repo → installed to `~/.claude/hooks/`).

### 1.4 Codex reconciliation in global CLAUDE.md
Replace "All spec and plans will be reviewed by codex" with: Codex is on-demand via `/codex:rescue`; never treated as authoritative without verification (it has fabricated findings). Keep the plugin installed.
- **Lives in:** global CLAUDE.md (+ master copy in repo).

## Sprint 2 — Hooks & quota optimisation

### 2.1 Review dedupe guard
Four duplicate-pair reviews ran on byte-identical diffs. Add a guard: before a `/security-review` or `/code-review` run, hash the current diff (`git diff | sha256`); if the hash matches the last reviewed hash for this repo (stored in `.claude/` state file), inject a warning: "identical diff already reviewed at <time> — skip?".
- **Lives in:** new `hooks/review-dedupe.sh`, wired as UserPromptSubmit (matches `/security-review`, `/code-review`).

### 2.2 Handoff-over-compaction nudge
Sam's target workflow: `/handoff` → `/clear` rather than compaction, unless mid-task. Extend the Stop hook's token nudge: at the context threshold, recommend `/handoff` + `/clear` explicitly (not compaction), once per session (uses the 1.3 guard mechanism).
- **Lives in:** `hooks/stop-memory.sh`.

### 2.3 Empty-checkpoint auto-discard
64 empty checkpoint stubs accumulated; Sam deleted them by hand ×11. In `pre-compact.sh` / SessionStart staging processing: a checkpoint file with no body beyond frontmatter/heading is deleted automatically, never surfaced as a pending item.
- **Lives in:** `hooks/pre-compact.sh` and `hooks/session-start.sh`.

### 2.4 memory-sync fast path
Full `/memory-sync` ceremony is overkill for short sessions. Add `--quick`: writes the session note from the transcript summary without the interactive learnings-proposal pass; propose learnings only when the correction/decision count is non-zero.
- **Lives in:** `commands/memory-sync.md` (this repo).

## Sprint 3 — Scripts

### 3.1 AWS ops helpers (float landing zone)
A `scripts/aws/` toolkit plus a `float-ops` skill documenting:
- **Landing zone setup:** the float landing zone account structure (management + workload accounts), written down once so no session re-derives it.
- **Auth:** CLI auth is **SSO to the management account under profile `float-management`** — `aws sso login --profile float-management`; all helper scripts default `--profile float-management` and fail fast with the login command when the token is expired.
- **Helpers:** `cw-dash.sh` (the recurring 6-metric CloudWatch query set, one command), `ssm-ids.sh` (cached instance-id lookup), `deploy-watch.sh` (wraps `gh run watch` but verifies actual run conclusion via `gh run view --json conclusion` — the exit code lied before).
- **Lives in:** `scripts/aws/` + `skills/float-ops/SKILL.md` in this repo.

### 3.2 render-verify script
Kills the 9-cycle render→crop→inspect loop. `scripts/render-verify.py`: takes a `.drawio` (or docx) file, renders to PNG, auto-crops, emits the image path for a single Read — one command instead of a manual loop. The drawio skill gets a pointer to it.
- **Lives in:** `scripts/render-verify.py` + one-line addition to `~/.claude/skills/drawio/SKILL.md`.

## Sprint 4 — Consolidation & setup guide

### 4.1 Context-bloat consolidation
Inventory everything loaded at session start: 17 plugins, 12 personal skills, 6 hooks, MCP servers (obsidian, aws-documentation, aws-iac, aws-mcp, claude-in-chrome, Context7). Produce a keep/cut table: name, what it injects into context, last observed use in the 418-session corpus, verdict. Sam approves; cuts applied to `~/.claude/settings.json` (plugins disabled, skills archived to repo, unused MCP servers removed). Known candidates from the audit: two stale `temp_subdir` plugin-cache clone dirs; overlapping code-review tooling (pr-review-toolkit vs code-review vs feature-dev reviewer); skills superseded by sam-carr-unified-voice.
- **Lives in:** analysis note in `docs/`, applied changes in `~/.claude/settings.json` (template mirrored to `config/settings.template.json`).

### 4.2 Fresh setup guide (v5)
`docs/setup-guide-v5.md`, replacing v4 after consolidation lands. For a brand-new Claude Code install: clone this repo, run bootstrap (install hooks, agents, commands, skills, statusline), apply `config/settings.template.json`, global CLAUDE.md master copy, plugin list (post-consolidation), MCP server setup, Obsidian CLI requirement, AWS SSO profile setup (`float-management`), read-once hook. The guide points at repos/tools, not prose theory — a checklist a fresh install can execute top to bottom.
- **Lives in:** `docs/setup-guide-v5.md` + `scripts/bootstrap.ps1` (or extend existing install mechanism if one exists — check during planning).

---

## Risks / open items

- **1.1 schema source unknown** until we grep the plugin cache — the fix text depends on whether we own the prompt.
- **4.1 disabling plugins** changes behaviour mid-flight for other projects; apply cuts in one sitting and verify a fresh session starts clean.
- **Bootstrap script scope** (4.2): check whether the repo already has an installer before writing a new one.

## Success criteria

- Review runs stop failing on schema and stop duplicating identical diffs.
- No session needs a manual re-brief after `/clear` — handoff covers it.
- Zero empty checkpoint stubs surface at SessionStart.
- One command each for: CloudWatch dashboard pull, SSM ids, deploy watch, render-verify.
- Session-start context injection measurably smaller after consolidation (before/after token count recorded in the 4.1 note).
- A new machine reaches full working setup from `setup-guide-v5.md` alone.
