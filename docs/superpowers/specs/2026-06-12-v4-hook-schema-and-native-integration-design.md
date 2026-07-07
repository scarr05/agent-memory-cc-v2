# Agent Memory v4 — Hook Schema Fixes & Native Integration Design

**Date:** 2026-06-12
**Status:** Approved
**Branch:** `dev/v4-schema-fixes` (cut from main after v3 merge)

## Problem

A June 2026 review found that the deterministic injection layer — the core premise of the system — is partly broken, and the system predates several native Claude Code features it should now use.

**Broken (bugs):**

1. **Wrong hook output schemas.** `session-start.sh` and `pre-compact.sh` emit `{"systemMessage": ...}`, which is shown to the *user*, not injected into Claude's context. Context injection requires `hookSpecificOutput.additionalContext` (or plain stdout for SessionStart). `stop-memory.sh` emits `{"reason": ...}` without `"decision": "block"` — Stop-hook nudges go nowhere. `read-once/hook.sh` emits `{"decision": "allow"}` — PreToolUse expects `hookSpecificOutput.permissionDecision: "allow"|"deny"|"ask"`, so warn-mode messages no-op.
2. **PreCompact design cannot work.** The checkpoint stub says blackbox should fill it in "before compaction completes", but compaction proceeds immediately — Claude cannot act on PreCompact output mid-compaction.
3. **Performance targets badly missed.** Baseline (2026-04-01): SessionStart 3.3–3.5s vs ~100ms target (5+ sequential Obsidian CLI calls); Stop 560–700ms vs <50ms target (fires every response, spawns jq/sed/date repeatedly).
4. **Smaller defects:** `pre-compact.sh` wipes the read-once cache for *all* sessions; `memory-state.json` dirties git status in every repo; `allowed-tools` entries use `obsidian:read_note` instead of `mcp__obsidian__read_note` so allowlists don't match; `user-invocable` is not a documented command frontmatter field; Stop nudges use exact equality (`-eq 15`) so a missed fire skips the nudge forever.

**Missing (native features now available):**

5. No plugin packaging — install is a manual file copy plus settings.json merge.
6. Subagents don't use the native `memory` frontmatter field (v2.1.33+), so memberberry cold-starts every invocation.
7. No SessionEnd hook — unsynced-session detection relies on Claude noticing a Stop nudge (which is currently broken anyway).
8. Corrections are only surfaced at SessionStart, not at the moment they matter (UserPromptSubmit).
9. The test harness asserts the old (wrong) schemas, so fixing the hooks breaks the tests unless they're updated together.

## Solution

Fix all hook output schemas against current documented formats, redesign the compaction checkpoint flow around `SessionStart source=compact`, hit the performance budgets with parallelism + caching, adopt native subagent memory and new hook events, and package the whole system as a Claude Code plugin.

**Doc-verification rule:** Hook schemas changed between releases and at least one upstream bug affects SessionStart `additionalContext`. The implementing agent MUST verify current schemas against https://code.claude.com/docs/en/hooks before writing each hook, and record what it found in the implementation notes.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| SessionStart injection | `hookSpecificOutput.additionalContext`, with `MEMORY_HOOK_PLAINTEXT=1` env escape hatch emitting plain stdout | additionalContext is the documented form; plain stdout is the documented SessionStart fallback if the known upstream bug (#16538) still bites |
| Stop nudge channel | `systemMessage` (user-visible), never `decision: block` | Blocking the agent to deliver a reminder is disproportionate; the nudge is for Sam, who runs `/memory-sync` |
| PreToolUse verdicts | `hookSpecificOutput.permissionDecision` (`allow`/`deny`/`ask`) + `permissionDecisionReason` | Current documented schema; legacy `decision` form is deprecated |
| Compaction checkpoint | PreCompact writes stub only; SessionStart matches `source=compact` and directs checkpoint processing | Claude cannot act during compaction; it can immediately after |
| SessionStart perf | Parallel CLI calls (`&`/`wait`) + vault-state cache in staging (TTL 15 min) + 3s hard budget | 5 sequential CLI calls are the bottleneck; cache makes warm starts near-instant |
| Stop hook perf | Drop jq, single awk pass, move dream-timer check to SessionStart | Stop fires every response; only counter + thresholds belong there |
| Nudge thresholds | `-ge` + sent-flags in `.session-meta` | Survives missed fires; mirrors existing duration-nudge pattern |
| read-once cache clear | Scope to `$CLAUDE_SESSION_ID` only | Concurrent sessions must not lose each other's caches |
| memory-state.json | Keep in `.claude/`, auto-append to `.git/info/exclude` on creation | Location solves the slug bootstrap problem; exclude keeps git status clean without touching tracked `.gitignore` |
| MCP tool names in allowed-tools | `mcp__obsidian__<tool>` format | Required for allowlists to match; verify exact names via `/mcp` at implementation time |
| Subagent memory | memberberry `memory: user`; blackbox `memory: project` | Vault layout/search strategy is user-wide; checkpoint merge context is per-project. Verify exact frontmatter syntax against sub-agents docs |
| SessionEnd hook | New `session-end.sh` writes `.unsynced` flag when count ≥ 10 and no sync occurred | Deterministic unsynced detection; SessionStart surfaces it next session |
| UserPromptSubmit corrections | New `prompt-corrections.sh` greps prompt against a corrections index cached by SessionStart; <100ms budget | Corrections matter at the moment of a related prompt, not only at session start |
| Packaging | Claude Code plugin (`.claude-plugin/plugin.json`) bundling hooks + agents + commands + skills | One-step versioned install; kills the manual copy + settings merge |
| Test harness | Update `hook-validation.sh` assertions to new schemas in the same task as each hook fix | Tests asserting the old schema would mask regressions |
| Scope | Single release on one branch, bugs before enhancements | Schema fixes unblock everything else; enhancements layer on a working base |

## Architecture

### Hook Output Schemas (corrected)

**session-start.sh**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "<memory context markdown>"
  }
}
```

With `MEMORY_HOOK_PLAINTEXT=1`, emit the context as plain text on stdout instead (documented SessionStart fallback). Tier 2 of the playbook verifies which form actually lands in context; default stays JSON unless verification fails.

SessionStart also receives a `source` field on stdin (`startup`, `resume`, `compact`, `clear`). New behaviour by source:

| source | Behaviour |
|--------|-----------|
| `startup` / `resume` | Full context build (as today, but parallel + cached). Surface `.unsynced` flag from prior session if present |
| `compact` | Slim output: slug + pending checkpoint paths + explicit instruction to delegate to blackbox NOW to fill the stub written by PreCompact |
| `clear` | Slim output: slug + delegation guidance only |

**pre-compact.sh** — keeps writing the checkpoint stub to staging (filesystem side effect is the point). Drops the `systemMessage` context block entirely; emits no JSON. The post-compaction handoff moves to SessionStart `source=compact`.

**stop-memory.sh**

```json
{
  "systemMessage": "<nudge text for the user>"
}
```

Only emitted when a threshold fires. No `decision`, no `reason`.

**read-once/hook.sh**

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "read-once: already in context (...)"
  }
}
```

`deny` replaces the old `block` in deny mode. Upstream-vendored file — document the divergence in `hooks/read-once/README.md`.

### Performance Design

**SessionStart (budget: warm ≤ 300ms, cold ≤ 3s):**

1. Vault-state cache: `~/.claude/memory-staging/<slug>/.vault-cache.json` with a 15-minute TTL. Warm start skips all CLI calls.
2. Cold start: the 5 CLI queries (index row, open tasks, working files, corrections, session depth) run as parallel background jobs writing temp files, gated by a single `wait`.
3. Hard budget: if the CLI is unreachable or jobs exceed ~3s, emit minimal context (slug, git state, staging flags) and a one-line warning. Never block session start on the vault.
4. Corrections query also writes `.corrections-index` (slug-relevant correction titles + keywords) for the UserPromptSubmit hook.

**Stop (budget: ≤ 50ms):**

- No jq. Slug from state file via grep/sed only.
- Single awk pass rewrites `.session-meta` (counter increment, last_activity, threshold flags) in one process.
- Dream-timer check moves to SessionStart (it only needs to be observed once per session, not per response).
- Nudges: `count -ge 15` with `nudge15_sent=true` flag, same for 30; duration nudge unchanged.

### New Hooks

**session-end.sh (SessionEnd):** reads `.session-meta`; if `message_count -ge 10` and no `synced=true` flag, writes `.unsynced` (timestamp + count + last topic line if available) to staging. `/memory-sync` Step 6 sets `synced=true` and removes `.unsynced`. SessionStart (`startup`/`resume`) surfaces the flag: "Previous session (N messages, <date>) was never synced — consider `/memory-sync` or checking the staging checkpoint."

**prompt-corrections.sh (UserPromptSubmit):** greps the prompt against `.corrections-index` keywords; on a hit, injects matching correction titles via `hookSpecificOutput.additionalContext` ("Correction on record: ... — load via memberberry before proceeding"). No index file → instant exit 0. Budget <100ms, no CLI calls, no jq on the hot path.

### Native Subagent Memory

- `agents/memberberry.md` gains `memory: user` — accumulates vault layout knowledge and which search strategies worked. Prompt addition: check memory for known-good search paths before escalating; record successful strategies after retrieval.
- `agents/blackbox.md` gains `memory: project` — remembers prior checkpoint locations and merge decisions per project.
- Exact frontmatter syntax MUST be verified against https://code.claude.com/docs/en/sub-agents at implementation time (field landed v2.1.33, Feb 2026).

### Plugin Packaging

```
agent-memory-cc-v2/
├── .claude-plugin/
│   └── plugin.json            # NEW — name, version 4.0.0, description
├── hooks/
│   ├── hooks.json             # NEW — plugin hook registration (replaces settings.json merge)
│   ├── session-start.sh       # REWRITE — schema, source matching, parallel + cache
│   ├── session-end.sh         # NEW
│   ├── prompt-corrections.sh  # NEW
│   ├── pre-compact.sh         # UPDATE — stub only, scoped cache clear, no JSON
│   ├── stop-memory.sh         # REWRITE — slim, systemMessage, -ge + flags
│   └── read-once/hook.sh      # UPDATE — permissionDecision schema
├── agents/                    # UPDATE — memory frontmatter
├── commands/                  # UPDATE — mcp__ tool names, drop user-invocable, sync sets synced flag
├── skills/                    # UPDATE — agent-memory SKILL.md reflects v4 flow
├── config/settings.json       # KEPT for manual install; plugin path preferred
└── docs/setup-guide-v4.md     # NEW — plugin install primary, manual fallback
```

Hook commands in `hooks.json` use `${CLAUDE_PLUGIN_ROOT}` paths. Manifest/registration format MUST be verified against https://code.claude.com/docs/en/plugins at implementation time. Manual install (copy to `~/.claude/`) remains documented as fallback.

### Test Harness Updates

`tests/hook-validation.sh` changes in lockstep with each hook fix:

- SessionStart: assert `hookSpecificOutput.additionalContext` present; extract slug from it; new test invoking with `{"source": "compact"}` asserting slim output; warm-vs-cold timing rows (warm ≤ 300ms, cold ≤ 3000ms against cache).
- Stop: assert empty output below thresholds; seed `message_count=14` and assert `systemMessage` nudge fires at 15; keep ≤ 50ms target.
- PreCompact: assert stub created and *no* JSON on stdout.
- read-once: new section asserting `permissionDecision` schema in warn and deny modes.
- New sections: session-end (`.unsynced` written when count ≥ 10 unsynced, not written when `synced=true`), prompt-corrections (hit injects context, no index exits clean, ≤ 100ms).
- Results table gains columns: SS warm ms, SE ms, UPS ms.

## Out of Scope

- Dream-mode changes (`/memory-sync --dream` logic untouched beyond the timer-check relocation).
- Marketplace publication of the plugin (local plugin install only).
- bats-core port of the test harness (candidate for a later release; `hook-validation.sh` remains the harness).

## Testing Checklist

### Prerequisites
- [ ] v3 branches merged to main; `dev/v4-schema-fixes` cut from main
- [ ] Obsidian 1.12+ with CLI enabled; `obsidian version` works from Claude Code bash
- [ ] Current hooks docs reviewed and schema findings recorded

### Schema
- [ ] SessionStart context visibly lands in Claude's context (Tier 2 manual check — ask "what project slug did the memory system inject?")
- [ ] Stop nudge appears to the user at message 15
- [ ] read-once warn reason surfaces; deny mode actually blocks the Read
- [ ] PreCompact emits no JSON; stub exists in staging after fire
- [ ] SessionStart `source=compact` produces slim checkpoint-handoff output

### Performance
- [ ] SessionStart warm ≤ 300ms, cold ≤ 3s (baseline row recorded)
- [ ] Stop ≤ 50ms
- [ ] UserPromptSubmit ≤ 100ms with and without index

### Functional
- [ ] `.unsynced` flag written on unsynced session end, surfaced next session, cleared by `/memory-sync`
- [ ] Corrections injection fires on a keyword-matching prompt
- [ ] memberberry memory persists across two invocations (records then reuses a search strategy)
- [ ] `memory-state.json` no longer appears in `git status` of a fresh project
- [ ] Concurrent-session read-once caches survive another session's compaction
- [ ] Plugin installs from local path; `/hooks` shows all six hooks; agents and commands available
- [ ] Manual-install fallback still works via config/settings.json

### Regression
- [ ] Full lifecycle (playbook Tier 3): start → work → compact → resume → sync
- [ ] `/memory-init`, `/memory-load`, `/memory-sync` unchanged behaviour
- [ ] Tier 1 harness passes clean on this repo and one other project
