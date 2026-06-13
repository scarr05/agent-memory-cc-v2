# v4 Schema Verification Notes

**Date verified:** 2026-06-13
**Verified by:** doc-verification gate (WebFetch of live docs at code.claude.com)
**Verdict:** **GO** — every core schema assumption in the spec is confirmed by the live docs. No structural divergence found.

Source pages:
- https://code.claude.com/docs/en/hooks
- https://code.claude.com/docs/en/sub-agents
- https://code.claude.com/docs/en/plugins

---

## 1. Hook output schemas (Task 2, 3, 4, 8, 9)

| Event | Context-injection / decision channel | Spec assumption | Status |
|-------|--------------------------------------|-----------------|--------|
| **SessionStart** | `hookSpecificOutput.additionalContext` (string) **or** any text on plain stdout — both injected into Claude's context | `additionalContext`, plaintext fallback via `MEMORY_HOOK_PLAINTEXT` | ✅ confirmed |
| **UserPromptSubmit** | `hookSpecificOutput.additionalContext` **or** plain stdout (injected alongside the prompt). Block via top-level `{"decision":"block","reason":...}` | `additionalContext` | ✅ confirmed — **plain stdout IS a documented fallback** (softens Review Finding 8: a plaintext escape hatch is available for this hook too) |
| **PreToolUse** | `hookSpecificOutput.permissionDecision` ∈ {`allow`,`deny`,`ask`,`defer`} + `permissionDecisionReason`. Optional `updatedInput`, `additionalContext` | `permissionDecision` (`allow`/`deny`/`ask`) | ✅ confirmed — note a 4th value `defer` exists (unused by us) |
| **Stop** | `systemMessage` (shown to **user only**, not Claude). Also supports `decision:block`+`reason` (continues convo) and `hookSpecificOutput.additionalContext` (Claude sees it). `continue:false` halts. | `systemMessage` for the nudge, never `decision:block` | ✅ confirmed — `systemMessage` is the correct channel for a user-facing nudge |
| **PreCompact** | Supports `decision:block`+`reason` and `hookSpecificOutput.additionalContext` | Spec emits **nothing** (stub-only; handoff via SessionStart `source=compact`) | ✅ valid — emitting nothing is fine. NOTE: `additionalContext` now exists at PreCompact, but the spec's premise (Claude can't act mid-compaction) and the SessionStart-source redesign remain the safe choice |
| **SessionEnd** | Receives `reason` on stdin ∈ {`clear`,`resume`,`logout`,`prompt_input_exit`,`bypass_permissions_disabled`,`other`}. Output is side-effect only (`systemMessage`, `terminalSequence`, `suppressOutput`); **no decision control** | Task 8: skip `.unsynced` write when reason is `clear` | ✅ confirmed — `reason` field exists with `clear` value, exactly as Task 8 assumes |

**#16538 (SessionStart additionalContext upstream bug):** not referenced in the docs (it is a GitHub issue, not documentation). Its current status could not be confirmed from docs. This is exactly why the **empirical Task 2 acceptance gate** ("what slug did the memory system inject?" in a live session) is load-bearing — verify injection actually lands before trusting the JSON form, and fall back to plaintext if not.

---

## 2. Sub-agent `memory` frontmatter (Task 10)

The `memory` field is **confirmed**. Accepted values and their directories:

| Value | Directory | Use when |
|-------|-----------|----------|
| `user` | `~/.claude/agent-memory/<name>/` | learnings apply across all projects |
| `project` | `.claude/agent-memory/<name>/` | project-specific, shareable via VCS |
| `local` | `.claude/agent-memory-local/<name>/` | project-specific, not checked in |

Spec mapping is valid: **memberberry `memory: user`** (vault layout/search strategy is user-wide), **blackbox `memory: project`** (checkpoint/merge context is per-project).

When `memory` is set: the subagent's system prompt gains read/write instructions + the first 200 lines / 25 KB of `MEMORY.md`; Read/Write/Edit tools are auto-enabled. Full valid frontmatter fields: `name`, `description`, `tools`, `disallowedTools`, `model`, `permissionMode`, `mcpServers`, `hooks`, `maxTurns`, `skills`, `initialPrompt`, `memory`, `effort`, `background`, `isolation`, `color`.

---

## 3. Plugin manifest & hook registration (Task 12)

**`.claude-plugin/plugin.json`** fields:

| Field | Required | Notes |
|-------|----------|-------|
| `name` | yes | unique id + skill namespace (`/agent-memory:<skill>`) |
| `description` | yes | shown in plugin manager |
| `version` | no | if set, users update only on bump; if omitted + git-distributed, commit SHA is the version |
| `author` | no | object, e.g. `{"name": "..."}` |

`homepage`, `repository`, `license` available — see `/en/plugins-reference#plugin-manifest-schema`.

**Directory layout:** `.claude-plugin/` holds **only** `plugin.json`. Everything else sits at **plugin root**: `hooks/` (with `hooks.json`), `agents/`, `commands/`, `skills/`. This repo already matches.

**`hooks/hooks.json`** uses the **same shape as `settings.json`'s `hooks` block**:
```json
{
  "hooks": {
    "EventName": [
      { "matcher": "Read", "hooks": [{ "type": "command", "command": "..." }] }
    ]
  }
}
```
So Task 12 copies the final `settings.json` hooks object (after Tasks 8/9 add SessionEnd + UserPromptSubmit) and swaps command paths to use `${CLAUDE_PLUGIN_ROOT}`.

**`${CLAUDE_PLUGIN_ROOT}`:** the create-plugins page does not show an explicit example; confirm exact usage against `/en/plugins-reference` before finalising. It is the established convention for plugin hook command paths.

**Local install/test (CORRECTION to Task 12 Step 4):** the documented dev method is:
```bash
claude --plugin-dir ./agent-memory-cc-v2      # load the local plugin for the session
/reload-plugins                                # hot-reload after edits
claude plugin validate                         # structural validation
```
Then confirm `/hooks` lists all six hooks, `/agents` shows memberberry + blackbox, `/help` lists the namespaced commands. (Not `/plugin install <localpath>`.) `--plugin-dir` also accepts a `.zip` (CC ≥ v2.1.128).

---

## Outstanding items for live verification (Sam, in-session)

1. **#16538 / additionalContext injection** — Task 2 acceptance gate: confirm the slug actually injects; record JSON-vs-plaintext working form + CC version.
2. **`CLAUDE_SESSION_ID` export** (Review Finding 9) — confirm it is set in the PreCompact/PreToolUse hook env (echo it from a throwaway hook); the scoped read-once clear depends on it.
3. **`/mcp` server prefix** (Task 1) — confirm the exact `mcp__<server>__<tool>` prefix matches the rename (server must be literally `obsidian`).
4. **UserPromptSubmit injection** (Finding 8) — verify corrections injection is actually seen by Claude; default to plain stdout if not.
