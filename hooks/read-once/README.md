# read-once — PreToolUse Hook

Catches redundant file re-reads within a Claude Code session. Saves ~2,000 tokens per **blocked** re-read; warn mode blocks nothing, so it saves nothing.

**Vendored from:** [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once)

> **Divergence from upstream Boucle:** upstream emits the legacy PreToolUse
> decision schema `{"decision": "allow"|"block", "reason": ...}`. This vendored
> copy emits the current documented PreToolUse form instead:
> `{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision":
> "allow"|"deny", "permissionDecisionReason": ...}}` — `deny` replaces the old
> `block`. Re-syncing from upstream will reintroduce the legacy schema; re-apply
> this change and the two below.
>
> **Session key:** upstream keys the cache on `CLAUDE_SESSION_ID`, which Claude
> Code does not set in the hook env, so every call fell back to `$$` and got a
> fresh cache dir: the hook never fired. This copy reads `session_id` from the
> stdin JSON (fallback `CLAUDE_CODE_SESSION_ID`) and skips dedup when neither is
> present.
>
> **Channels:** an `allow` decision's `permissionDecisionReason` only reaches the
> debug log (confirmed with a probe hook), and `allow` also bypasses the normal
> permission prompt. So this copy never emits `allow`: warn mode emits
> `additionalContext` with no decision, while deny mode and diff mode emit `deny`,
> whose reason Claude does see. The jq-missing and bad-config exits use
> `systemMessage` so the user sees them.

## How It Works

- Intercepts every `Read` tool call via PreToolUse hook
- Tracks file paths + modification times in a session cache
- **First read:** allowed, cached
- **Re-read, unchanged:** blocked (deny mode) or flagged to Claude via `additionalContext` (warn mode; the read still happens)
- **Re-read, changed + diff enabled:** blocked, with the diff as the deny reason (either mode). A touched-but-identical file is blocked as unchanged
- **Retry after a block:** the next Read of a file that was just blocked is always allowed in full, so a block can never deadlock Edit (which needs a fresh Read after an external change)
- **Partial reads** (offset/limit): always allowed (different content each time)
- **TTL expiry:** cache entries expire after configurable seconds (default 1200 = 20 min)

## Configuration

Set via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `READ_ONCE_MODE` | `warn` | `warn` = read goes ahead, Claude gets an advisory; `deny` = block unchanged re-reads |
| `READ_ONCE_TTL` | `1200` | Cache validity in seconds (20 min default) |
| `READ_ONCE_DIFF` | `0` | Set to `1` to block a changed-file re-read and return the diff instead (any mode) |
| `READ_ONCE_DIFF_MAX` | `40` | Max diff lines before falling back to full re-read |
| `READ_ONCE_DISABLED` | `0` | Set to `1` to disable entirely |

## Installation

The hook is registered in `~/.claude/settings.json` as part of the agent-memory system:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/read-once/hook.sh"
          }
        ]
      }
    ]
  }
}
```

## Recommended Starting Config

For actual savings, use deny mode with diff enabled:

```bash
export READ_ONCE_MODE=deny
export READ_ONCE_DIFF=1
```

Deny mode blocks unchanged re-reads; diff mode saves tokens on iterative editing
(3 changed lines in a 200-line file = ~30 tokens instead of ~2,000). Neither can
deadlock Edit: after any block, repeating the Read is allowed in full. `warn` (the
default) is the observe-only setting: it costs a few tokens per re-read and saves
none.

## Cache Management

```bash
# Clear the session cache manually
rm -rf ~/.claude/read-once/cache/

# Cache auto-cleans entries older than 24 hours
```

The PreCompact hook (`pre-compact.sh`) clears this session's cache (same
stdin `session_id` key) to prevent stale state after context compaction.

## Integration Notes

- **No conflict with memberberry/blackbox subagents** — they use Bash tool (CLI calls), not Read tool
- **PreCompact cache clear** — handled by `pre-compact.sh`
- **Session-scoped** — each Claude Code session gets its own cache directory, keyed on the stdin `session_id`
