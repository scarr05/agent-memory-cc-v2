# read-once — PreToolUse Hook

Prevents redundant file re-reads within a Claude Code session. Saves ~2,000 tokens per blocked re-read.

**Vendored from:** [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once)

## How It Works

- Intercepts every `Read` tool call via PreToolUse hook
- Tracks file paths + modification times in a session cache
- **First read:** allowed, cached
- **Re-read, unchanged:** blocked (deny mode) or warned (warn mode)
- **Re-read, changed + diff enabled:** shows diff only
- **Partial reads** (offset/limit): always allowed (different content each time)
- **TTL expiry:** cache entries expire after configurable seconds (default 1200 = 20 min)

## Configuration

Set via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `READ_ONCE_MODE` | `warn` | `warn` = allow with advisory; `deny` = block re-reads |
| `READ_ONCE_TTL` | `1200` | Cache validity in seconds (20 min default) |
| `READ_ONCE_DIFF` | `0` | Set to `1` to show diff instead of full content on changed files |
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

Start with `warn` mode and diff enabled:

```bash
export READ_ONCE_MODE=warn
export READ_ONCE_DIFF=1
```

Warn mode prevents Edit tool deadlock (Edit requires a prior Read). Diff mode
saves tokens on iterative editing (3 changed lines in a 200-line file = ~30
tokens instead of ~2,000).

## Cache Management

```bash
# Clear the session cache manually
rm -rf ~/.claude/read-once/cache/

# Cache auto-cleans entries older than 24 hours
```

The PreCompact hook (`pre-compact.sh`) clears the read-once cache automatically
to prevent stale state after context compaction.

## Integration Notes

- **No conflict with memberberry/blackbox subagents** — they use Bash tool (CLI calls), not Read tool
- **PreCompact cache clear** — handled by `pre-compact.sh`
- **Session-scoped** — each Claude Code session gets its own cache directory
