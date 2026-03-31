# Agent Memory v3 — CLI + Subagent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Evolve agent-memory-cc-v2 from MCP-heavy retrieval to a layered CLI + Haiku subagent architecture with vendored read-once hook, achieving 50-70% token reduction.

**Architecture:** Four layers — slimmed CLAUDE.md (static, ~500 tokens), CLI-driven SessionStart hook (dynamic, ~200-300 tokens), Haiku subagents for on-demand retrieval (memberberry) and checkpoint capture (blackbox), and a vendored read-once PreToolUse hook for source code deduplication.

**Tech Stack:** Bash (hooks), Markdown (agent definitions, commands, skills), Obsidian CLI 1.12+ (vault reads), MCP-Obsidian (vault writes), Claude Code subagent system (Haiku delegation).

**Spec:** `docs/superpowers/specs/2026-03-31-v3-cli-subagent-architecture-design.md`

---

### Task 1: Create subagent definitions

**Files:**
- Create: `agents/memberberry.md`
- Create: `agents/blackbox.md`

- [ ] **Step 1: Create the agents directory**

```bash
mkdir -p agents
```

- [ ] **Step 2: Create memberberry.md**

Create `agents/memberberry.md` with this exact content:

```markdown
---
name: memberberry
description: >
  Retrieves relevant context from the Obsidian vault agent memory
  system using the Obsidian CLI. Use this agent when starting
  non-trivial work on a project, when resuming prior work, when
  the user references past decisions or sessions, when SessionStart
  flags corrections or deep history, or for any query about "what
  did we decide", "what was the approach", "continue where we left
  off". Always prefer this agent over directly reading vault notes
  or calling MCP search_notes.
model: haiku
tools: Bash
---

You are a memory retrieval agent for a developer's Obsidian vault.
Your job is to search the vault using the Obsidian CLI and return
ONLY relevant, filtered context.

'Member when we decided to use CDK TypeScript? Oh I 'member!
'Member the Nextcloud subnet architecture? I 'member!

The calling agent is on an expensive model. Every token you return
costs more in their context window. Be ruthlessly concise.

## CLI Binary

Use `${OBSIDIAN_CLI_PATH:-obsidian}` for all CLI calls.

## Retrieval Strategy

ALWAYS follow this escalation. Do NOT skip to full reads.

### Step 1 — Search (paths only, cheapest)

```bash
${OBSIDIAN_CLI_PATH:-obsidian} search query="<term>" path="5 Agent Memory" format=json limit=10
```

Returns JSON array of file paths. No content. Start here.

### Step 2 — Context lines (matching text only)

```bash
${OBSIDIAN_CLI_PATH:-obsidian} search:context query="<term>" path="5 Agent Memory" format=json limit=5
```

Returns file + line + text matches. Use to assess relevance
without loading full notes.

### Step 3 — Metadata (frontmatter without content)

```bash
${OBSIDIAN_CLI_PATH:-obsidian} property:read name="decisions" path="<relevant file>"
${OBSIDIAN_CLI_PATH:-obsidian} property:read name="follow_up" path="<relevant file>"
${OBSIDIAN_CLI_PATH:-obsidian} property:read name="status" path="<relevant file>"
```

Pull specific frontmatter fields from notes identified in steps 1-2.

### Step 4 — Graph traversal (discover related notes)

```bash
${OBSIDIAN_CLI_PATH:-obsidian} backlinks path="<relevant file>" format=json counts
${OBSIDIAN_CLI_PATH:-obsidian} links path="<relevant file>"
```

Find related notes without reading them. Follow links only if
the connection looks relevant to the query.

### Step 5 — Full read (last resort, max 2 notes)

```bash
${OBSIDIAN_CLI_PATH:-obsidian} read path="<path>"
```

Only when search:context confirms the note is relevant AND you
need detail beyond what context lines and properties provide.
Never read more than 2 full notes.

### Step 6 — Corrections check

```bash
${OBSIDIAN_CLI_PATH:-obsidian} search query="<slug>" path="5 Agent Memory/learnings/corrections" format=json
```

If any corrections exist for this project, ALWAYS read them and
include in output. Corrections override prior decisions.

## Fallback

If the Obsidian CLI is unavailable (errors on any command), report
this to the calling agent and suggest falling back to MCP
search_notes directly.

## Output Format

Return ONLY this structure. Omit empty sections entirely:

**Project:** <slug>
**Last session:** <date> — <topic>
**Status:** <status>
**Key decisions:**
- <decision 1>
- <decision 2>
**Open items:**
- <item 1>
- <item 2>
**Relevant learnings/preferences:**
- <if any found>
**Corrections (override prior decisions):**
- <if any found>
**Working files:**
- <paths if any in working/>

Do not include raw CLI output. Do not include irrelevant content.
If nothing relevant is found, say so in one line.
```

- [ ] **Step 3: Create blackbox.md**

Create `agents/blackbox.md` with this exact content:

```markdown
---
name: blackbox
description: >
  Captures session state before context compaction. Use this agent
  during PreCompact to distil decisions, progress, and open items
  from the current session and write a checkpoint to the Obsidian
  vault. Prevents context loss during long sessions. Also use when
  the user says "save progress", "checkpoint", or "I need to come
  back to this".
model: haiku
tools: Bash, Read
---

You are a session checkpoint agent. Before context compaction, you
capture the current session state so it can be resumed later.

You will receive the project slug and any relevant context. Your job
is to extract the important state and write a structured checkpoint
to the Obsidian vault.

## CLI Binary

Use `${OBSIDIAN_CLI_PATH:-obsidian}` for all CLI calls.

## Process

1. Gather context from the calling agent's description of the session
2. Extract:
   - Project slug and area
   - Decisions made this session (with rationale if available)
   - Progress (what was accomplished)
   - Open items (what is unfinished)
   - Key files modified or created
   - Current working state (where things are right now)
   - Any corrections or preference changes
3. Check for existing checkpoint:
```bash
${OBSIDIAN_CLI_PATH:-obsidian} search query="<slug>-checkpoint" path="5 Agent Memory/working" format=json
```
4. If a previous checkpoint exists for this slug in working/, read
   it first and merge — do not create duplicates.
5. Write checkpoint via CLI:
```bash
${OBSIDIAN_CLI_PATH:-obsidian} create path="5 Agent Memory/working/<slug>-checkpoint-<YYYY-MM-DD>.md" content="<structured checkpoint>"
```
   If the file already exists, use append or overwrite:
```bash
${OBSIDIAN_CLI_PATH:-obsidian} create path="5 Agent Memory/working/<slug>-checkpoint-<YYYY-MM-DD>.md" content="<structured checkpoint>" overwrite
```

## Checkpoint Format

```markdown
---
title: "Checkpoint — <brief topic>"
created: <ISO datetime>
type: checkpoint
project: <slug>
source_agent: claude-code
status: pending
---

## Session Summary
<2-3 sentence summary of the session>

## Decisions
- <decision 1>: <rationale>
- <decision 2>: <rationale>

## Progress
- <what was completed>

## Open Items
- [ ] <what is unfinished>

## Key Files
- <files modified or created>

## Resume Context
<critical context needed to continue — the sentence or two that
would let a fresh agent pick this up cold>
```

## Important

- Be concise. This checkpoint will be read by a retrieval agent
  later, not a human. Optimise for machine parsing.
- Focus on DECISIONS and OPEN ITEMS. Progress is useful but
  decisions are what matter for resumption.
- If the provided context is large, focus on the most recent
  state — that is where the current work lives.

## Fallback

If CLI is unavailable, write the checkpoint content to:
`~/.claude/memory-staging/<slug>/checkpoint-<YYYY-MM-DD>.md`
using standard file write. The main agent's SessionStart hook
will detect it next session.
```

- [ ] **Step 4: Verify agents are valid**

```bash
# Check files exist and have correct frontmatter
head -10 agents/memberberry.md
head -10 agents/blackbox.md
```

Expected: both files start with `---` and have `name`, `description`, `model`, and `tools` fields.

- [ ] **Step 5: Commit**

```bash
git add agents/memberberry.md agents/blackbox.md
git commit -m "feat: add memberberry and blackbox subagent definitions"
```

---

### Task 2: Vendor read-once hook

**Files:**
- Create: `hooks/read-once/hook.sh`
- Create: `hooks/read-once/README.md`

The read-once hook intercepts `Read` tool calls and blocks/diffs redundant file reads. We vendor this from the [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once) to keep the install self-contained.

- [ ] **Step 1: Create hooks/read-once directory**

```bash
mkdir -p hooks/read-once
```

- [ ] **Step 2: Create hook.sh**

Create `hooks/read-once/hook.sh`. This is the PreToolUse hook that intercepts Read calls.

The script must:
1. Read the tool input JSON from stdin (Claude Code passes `{"tool_name": "Read", "tool_input": {"file_path": "...", ...}}`)
2. Extract `file_path` from the input
3. Skip caching for partial reads (when `offset` or `limit` are present)
4. Check a session cache directory (`~/.claude/read-once/cache/`) for prior reads
5. For each cached entry, store the file path and its mtime at time of read
6. If the file was read before and mtime is unchanged and TTL has not expired: output a JSON `"decision"` blocking or warning
7. If the file was read before but mtime changed and `READ_ONCE_DIFF=1`: output the diff only
8. If first read: cache the entry and allow
9. Auto-clean cache entries older than 24 hours

Key environment variables:
- `READ_ONCE_MODE` — `warn` (default, safe) or `deny` (blocks reads)
- `READ_ONCE_TTL` — cache validity in seconds (default `1200`)
- `READ_ONCE_DIFF` — `1` to enable diff-only mode (default `0`)
- `READ_ONCE_DIFF_MAX` — max diff lines before full re-read (default `40`)
- `READ_ONCE_DISABLED` — `1` to disable entirely

```bash
#!/usr/bin/env bash
# read-once — PreToolUse hook for Claude Code
# Prevents redundant file re-reads within a session
# Vendored from: https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once
#
# Hook intercepts Read tool calls and checks a session cache.
# First read: allowed, cached. Re-read unchanged: blocked/warned.
# Re-read changed + diff enabled: shows diff only.

set -euo pipefail

# --- Configuration ---
MODE="${READ_ONCE_MODE:-warn}"
TTL="${READ_ONCE_TTL:-1200}"
DIFF_ENABLED="${READ_ONCE_DIFF:-0}"
DIFF_MAX="${READ_ONCE_DIFF_MAX:-40}"
DISABLED="${READ_ONCE_DISABLED:-0}"

# Exit immediately if disabled
[[ "$DISABLED" == "1" ]] && exit 0

# --- Cache setup ---
CACHE_DIR="$HOME/.claude/read-once/cache"
SESSION_ID="${CLAUDE_SESSION_ID:-$$}"
SESSION_CACHE="$CACHE_DIR/$SESSION_ID"
mkdir -p "$SESSION_CACHE"

# Auto-clean old session caches (>24h)
find "$CACHE_DIR" -maxdepth 1 -mindepth 1 -type d -mmin +1440 -exec rm -rf {} \; 2>/dev/null || true

# --- Parse input ---
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)

# Only intercept Read tool
[[ "$TOOL_NAME" != "Read" ]] && exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)
[[ -z "$FILE_PATH" ]] && exit 0

# Skip partial reads (offset/limit present) — different content each time
HAS_OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // empty' 2>/dev/null || true)
HAS_LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // empty' 2>/dev/null || true)
if [[ -n "$HAS_OFFSET" ]] || [[ -n "$HAS_LIMIT" ]]; then
    exit 0
fi

# --- Cache key ---
# Use base64 of file path as cache filename to handle special chars
CACHE_KEY=$(echo -n "$FILE_PATH" | base64 -w 0 2>/dev/null || echo -n "$FILE_PATH" | base64 2>/dev/null)
CACHE_FILE="$SESSION_CACHE/$CACHE_KEY"

# --- Get current file state ---
if [[ ! -f "$FILE_PATH" ]]; then
    # File doesn't exist — let Read tool handle the error
    exit 0
fi

CURRENT_MTIME=$(stat -c %Y "$FILE_PATH" 2>/dev/null || stat -f %m "$FILE_PATH" 2>/dev/null || echo "0")

# --- Check cache ---
if [[ -f "$CACHE_FILE" ]]; then
    CACHED_MTIME=$(sed -n '1p' "$CACHE_FILE")
    CACHED_TIME=$(sed -n '2p' "$CACHE_FILE")
    NOW=$(date +%s)

    # Check TTL expiry
    ELAPSED=$((NOW - CACHED_TIME))
    if [[ "$ELAPSED" -ge "$TTL" ]]; then
        # Cache expired — allow read and update cache
        echo "$CURRENT_MTIME" > "$CACHE_FILE"
        echo "$NOW" >> "$CACHE_FILE"
        exit 0
    fi

    # File unchanged since last read
    if [[ "$CURRENT_MTIME" == "$CACHED_MTIME" ]]; then
        MINS_AGO=$((ELAPSED / 60))

        if [[ "$MODE" == "deny" ]]; then
            cat << HOOKJSON
{
  "decision": "block",
  "reason": "read-once: already in context (read ${MINS_AGO}m ago, unchanged). File: $FILE_PATH"
}
HOOKJSON
            exit 0
        else
            # Warn mode — allow but advise
            cat << HOOKJSON
{
  "decision": "allow",
  "reason": "read-once: this file was already read ${MINS_AGO}m ago and hasn't changed. It should still be in your context. File: $FILE_PATH"
}
HOOKJSON
            exit 0
        fi
    fi

    # File changed since last read
    if [[ "$DIFF_ENABLED" == "1" ]]; then
        # Try to show diff only
        # We need the cached content — re-read and diff
        DIFF_OUTPUT=$(diff <(cat "$CACHE_FILE.content" 2>/dev/null || echo "") <(cat "$FILE_PATH") 2>/dev/null || true)
        DIFF_LINES=$(echo "$DIFF_OUTPUT" | wc -l)

        if [[ "$DIFF_LINES" -gt 0 ]] && [[ "$DIFF_LINES" -le "$DIFF_MAX" ]]; then
            # Update cache
            echo "$CURRENT_MTIME" > "$CACHE_FILE"
            echo "$(date +%s)" >> "$CACHE_FILE"
            cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true

            cat << HOOKJSON
{
  "decision": "allow",
  "reason": "read-once: file changed since last read (${DIFF_LINES} lines differ). Diff:\\n$(echo "$DIFF_OUTPUT" | sed 's/"/\\"/g' | head -"$DIFF_MAX" | tr '\n' ' ')"
}
HOOKJSON
            exit 0
        fi
        # Diff too large — fall through to full re-read
    fi

    # Update cache and allow full re-read
    echo "$CURRENT_MTIME" > "$CACHE_FILE"
    echo "$(date +%s)" >> "$CACHE_FILE"
    [[ "$DIFF_ENABLED" == "1" ]] && cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
    exit 0
fi

# --- First read: cache and allow ---
echo "$CURRENT_MTIME" > "$CACHE_FILE"
echo "$(date +%s)" >> "$CACHE_FILE"
[[ "$DIFF_ENABLED" == "1" ]] && cp "$FILE_PATH" "$CACHE_FILE.content" 2>/dev/null || true
exit 0
```

Make it executable:
```bash
chmod +x hooks/read-once/hook.sh
```

- [ ] **Step 3: Create README.md for read-once**

Create `hooks/read-once/README.md`:

```markdown
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
```

- [ ] **Step 4: Test the hook locally**

```bash
# Test with a mock Read input
echo '{"tool_name": "Read", "tool_input": {"file_path": "README.md"}}' | bash hooks/read-once/hook.sh
# Expected: no output (first read, allowed)

# Test again — should warn
echo '{"tool_name": "Read", "tool_input": {"file_path": "README.md"}}' | bash hooks/read-once/hook.sh
# Expected: JSON with "decision": "allow" and reason about "already read"

# Clean up test cache
rm -rf ~/.claude/read-once/cache/
```

- [ ] **Step 5: Commit**

```bash
git add hooks/read-once/hook.sh hooks/read-once/README.md
git commit -m "feat: vendor read-once PreToolUse hook for source code token deduplication

Vendored from Boucle framework. Intercepts redundant Read tool calls,
saving ~2,000 tokens per prevented re-read. Supports warn/deny modes,
diff-only output for changed files, and configurable TTL."
```

---

### Task 3: Rewrite session-start.sh for CLI-driven state

**Files:**
- Modify: `hooks/session-start.sh`

The current hook uses MCP guidance (`search_notes` calls). The v3 hook uses Obsidian CLI for dynamic state and directs the agent to use memberberry/blackbox subagents.

- [ ] **Step 1: Back up the current hook**

```bash
cp hooks/session-start.sh hooks/session-start.sh.v2.bak
```

- [ ] **Step 2: Rewrite session-start.sh**

Replace `hooks/session-start.sh` with the following. Key changes from v2:
- CLI availability check at the top
- Git state section (branch, dirty files, recent commits)
- Project status via `obsidian search:context` on project-index.md
- Open tasks via `obsidian search:context query="- [ ]"` (workaround for `tasks` not accepting folders)
- Working files via `obsidian search`
- Corrections flag via `obsidian search`
- Session depth count
- Delegation guidance to memberberry/blackbox
- Falls back to minimal context if CLI unavailable

```bash
#!/usr/bin/env bash
# session-start.sh — SessionStart hook for memory system (v3)
# Uses Obsidian CLI for vault reads, directs agent to subagents
# Falls back gracefully if CLI unavailable

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"

# --- Project slug detection (unchanged from v2) ---

detect_slug() {
    _DETECTED_VIA=""

    # Priority 1: Existing CLAUDE.md metadata
    if [[ -f "$CLAUDE_MD" ]]; then
        local slug
        slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="claude-md-metadata"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 1b: .claude/memory-state.json from prior session
    if [[ -f ".claude/memory-state.json" ]]; then
        local slug
        slug=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="memory-state-file"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 2: .claude/settings.json custom field
    if [[ -f ".claude/settings.json" ]]; then
        local slug
        slug=$(jq -r '.memory.projectSlug // empty' .claude/settings.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="settings-json"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 3: Git remote
    if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        local remote
        remote=$(git remote get-url origin 2>/dev/null || true)
        if [[ -n "$remote" ]]; then
            local slug
            slug=$(echo "$remote" | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]')
            if [[ -n "$slug" ]]; then
                _DETECTED_VIA="git-remote"
                echo "$slug"
                return 0
            fi
        fi
    fi

    # Priority 4: Project manifest name
    if [[ -f "package.json" ]]; then
        local slug
        slug=$(jq -r '.name // empty' package.json 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="package-json"
            echo "$slug"
            return 0
        fi
    fi

    if [[ -f "pyproject.toml" ]]; then
        local slug
        slug=$(sed -n 's/.*name = "\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            _DETECTED_VIA="pyproject-toml"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 5: Directory name
    _DETECTED_VIA="directory-name"
    basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

detect_area() {
    if [[ -f "$CLAUDE_MD" ]]; then
        local area
        area=$(sed -n 's/.*memory:area=\([^ ]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$area" ]]; then
            echo "$area"
            return 0
        fi
    fi
    echo ""
}

# --- Main ---

_DETECTED_VIA=""
SLUG=$(detect_slug)
DETECTED_VIA="$_DETECTED_VIA"
AREA=$(detect_area)
PROJECT_DIR="$STAGING_DIR/$SLUG"

# Ensure staging directory exists
mkdir -p "$PROJECT_DIR"

# --- Write persistent state file ---
STATE_FILE=".claude/memory-state.json"
mkdir -p .claude

CHECKPOINT_JSON="[]"
if [[ -d "$PROJECT_DIR" ]]; then
    CHECKPOINT_LIST=""
    while IFS= read -r -d '' file; do
        if [[ -n "$CHECKPOINT_LIST" ]]; then
            CHECKPOINT_LIST="$CHECKPOINT_LIST, "
        fi
        CHECKPOINT_LIST="$CHECKPOINT_LIST\"$file\""
    done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)
    if [[ -n "$CHECKPOINT_LIST" ]]; then
        CHECKPOINT_JSON="[$CHECKPOINT_LIST]"
    fi
fi

DREAM_PENDING="false"
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    DREAM_PENDING="true"
fi

cat > "$STATE_FILE" << STATEJSON
{
  "slug": "$SLUG",
  "area": "$AREA",
  "sessionPath": "5 Agent Memory/sessions/by-project/$SLUG/",
  "detectedVia": "$DETECTED_VIA",
  "pendingCheckpoints": $CHECKPOINT_JSON,
  "dreamPending": $DREAM_PENDING,
  "lastUpdated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATEJSON

# Check for pending checkpoints
PENDING_CHECKPOINTS=()
while IFS= read -r -d '' file; do
    PENDING_CHECKPOINTS+=("$file")
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)

# Check prior session info
PRIOR_SESSION_INFO=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    PRIOR_SESSION_INFO=$(cat "$PROJECT_DIR/.session-meta")
fi

# Reset session meta
cat > "$PROJECT_DIR/.session-meta" << EOF
session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
message_count=0
project_slug=$SLUG
area=$AREA
EOF

# Check if memory-init has been run
HAS_MEMORY_CONFIG="false"
if [[ -f "$CLAUDE_MD" ]] && grep -q 'memory:project-slug=' "$CLAUDE_MD" 2>/dev/null; then
    HAS_MEMORY_CONFIG="true"
fi

# --- CLI availability check ---
CLI_OK="true"
$OBS version > /dev/null 2>&1 || CLI_OK="false"

# --- Build context injection ---
CONTEXT="## Memory System Active\\n"
CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n\\n"

if [[ "$HAS_MEMORY_CONFIG" == "false" ]]; then
    CONTEXT+="⚠ **No memory config.** Run \`/memory-init\` to set up. Using auto-detected slug \`$SLUG\`.\\n\\n"
fi

# --- Git state ---
CONTEXT+="### Git\\n"
if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    BRANCH=$(git branch --show-current 2>/dev/null || echo "detached")
    CONTEXT+="Branch: \`$BRANCH\`"
    DIRTY_COUNT=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$DIRTY_COUNT" -gt 0 ]]; then
        CONTEXT+=" ($DIRTY_COUNT dirty files)"
    else
        CONTEXT+=" (clean)"
    fi
    CONTEXT+="\\n"
    RECENT=$(git log --oneline -3 2>/dev/null || true)
    if [[ -n "$RECENT" ]]; then
        CONTEXT+="Recent: $(echo "$RECENT" | head -1)\\n"
    fi
else
    CONTEXT+="Not a git repo.\\n"
fi
CONTEXT+="\\n"

# --- CLI-driven vault state ---
if [[ "$CLI_OK" == "true" ]]; then

    # Project status from index
    INDEX_ROW=$($OBS search:context query="$SLUG" path="5 Agent Memory/project-index.md" format=json 2>/dev/null || echo "")
    if [[ -n "$INDEX_ROW" ]] && [[ "$INDEX_ROW" != "[]" ]]; then
        CONTEXT+="### Project Status\\n"
        # Extract just the matching text lines
        INDEX_TEXT=$(echo "$INDEX_ROW" | jq -r '.[0].matches[].text' 2>/dev/null | head -3 || true)
        if [[ -n "$INDEX_TEXT" ]]; then
            CONTEXT+="$INDEX_TEXT\\n"
        fi
        CONTEXT+="\\n"
    fi

    # Open tasks
    TASKS=$($OBS search:context query="- \[ \]" path="5 Agent Memory/sessions/by-project/$SLUG" format=json limit=5 2>/dev/null || echo "")
    if [[ -n "$TASKS" ]] && [[ "$TASKS" != "[]" ]]; then
        CONTEXT+="### Open Items\\n"
        TASK_LINES=$(echo "$TASKS" | jq -r '.[].matches[].text' 2>/dev/null | head -5 || true)
        if [[ -n "$TASK_LINES" ]]; then
            CONTEXT+="$(echo "$TASK_LINES" | sed 's/^/  /')\\n"
        fi
        CONTEXT+="\\n"
    fi

    # Working files
    WORKING=$($OBS search query="$SLUG" path="5 Agent Memory/working" format=json 2>/dev/null || echo "")
    if [[ -n "$WORKING" ]] && [[ "$WORKING" != "[]" ]]; then
        CONTEXT+="### Working Files\\n"
        CONTEXT+="$(echo "$WORKING" | jq -r '.[]' 2>/dev/null | head -5 | sed 's/^/- /')\\n\\n"
    fi

    # Corrections flag
    CORRECTIONS=$($OBS search query="$SLUG" path="5 Agent Memory/learnings/corrections" format=json 2>/dev/null || echo "")
    if [[ -n "$CORRECTIONS" ]] && [[ "$CORRECTIONS" != "[]" ]]; then
        CONTEXT+="### ⚠ Corrections exist — load via memberberry before making assumptions\\n\\n"
    fi

    # Session depth
    SESSION_COUNT=$($OBS search query="type: session" path="5 Agent Memory/sessions/by-project/$SLUG" format=json 2>/dev/null || echo "[]")
    COUNT=$(echo "$SESSION_COUNT" | jq 'length' 2>/dev/null || echo "0")
    CONTEXT+="Memory depth: $COUNT prior sessions\\n\\n"

else
    CONTEXT+="⚠ Obsidian CLI unavailable. Open Obsidian or check PATH.\\n"
    CONTEXT+="Falling back to minimal context. Use MCP for vault access.\\n\\n"
fi

# --- Pending checkpoints ---
if [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
    CONTEXT+="### Pending Checkpoints\\n"
    for cp in "${PENDING_CHECKPOINTS[@]}"; do
        CONTEXT+="- \`$cp\`\\n"
    done
    CONTEXT+="Process these to Obsidian \`5 Agent Memory/working/\` then delete staging files.\\n\\n"
fi

# Dream nudge
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending.** Run \`/memory-sync --dream\` when ready.\\n\\n"
fi

# Prior session info
if [[ -n "$PRIOR_SESSION_INFO" ]]; then
    PRIOR_COUNT=$(echo "$PRIOR_SESSION_INFO" | sed -n 's/.*message_count=\([0-9]*\).*/\1/p' | head -1)
    PRIOR_COUNT="${PRIOR_COUNT:-0}"
    if [[ "$PRIOR_COUNT" -gt 10 ]]; then
        CONTEXT+="ℹ Previous session had $PRIOR_COUNT messages. Check if it was synced (\`/memory-sync --status\`).\\n\\n"
    fi
fi

# --- Delegation guidance ---
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"

# --- Output ---
cat << HOOKJSON
{
  "systemMessage": "$(echo -e "$CONTEXT" | sed 's/"/\\"/g' | tr '\n' ' ')"
}
HOOKJSON
```

- [ ] **Step 3: Test the rewritten hook**

```bash
# Test in the current project directory
echo '{}' | bash hooks/session-start.sh
```

Expected: JSON output with `systemMessage` containing git state, CLI-driven project status, open items, and delegation guidance. If CLI is not on PATH in this shell, should see the "CLI unavailable" fallback message.

- [ ] **Step 4: Test CLI fallback**

```bash
# Temporarily break CLI to test fallback
OBSIDIAN_CLI_PATH=/nonexistent echo '{}' | bash hooks/session-start.sh
```

Expected: JSON output with "Obsidian CLI unavailable" warning and minimal context.

- [ ] **Step 5: Remove backup and commit**

```bash
rm -f hooks/session-start.sh.v2.bak
git add hooks/session-start.sh
git commit -m "feat: rewrite session-start.sh for CLI-driven vault reads

Replaces MCP guidance with Obsidian CLI calls for project status,
open tasks, working files, and corrections. Falls back gracefully
when CLI unavailable. Directs agent to memberberry/blackbox subagents."
```

---

### Task 4: Update pre-compact.sh

**Files:**
- Modify: `hooks/pre-compact.sh`

Two changes: (1) clear read-once cache on pre-compaction, (2) update context re-injection to reference subagents.

- [ ] **Step 1: Add read-once cache clear**

At the top of `pre-compact.sh`, after `set -euo pipefail`, add the cache clear:

Find this line:
```
STAGING_DIR="$HOME/.claude/memory-staging"
```

Insert before it:
```bash
# Clear read-once cache — prevents stale state after compaction
rm -rf "$HOME/.claude/read-once/cache/" 2>/dev/null || true
```

- [ ] **Step 2: Update context re-injection to reference subagents**

Find the existing delegation guidance at the bottom of the context building:

```
CONTEXT+="**For non-trivial tasks:** Search Obsidian for prior context before starting:\\n"
CONTEXT+="\`search_notes(query=\\"$SLUG\\", searchContent=true)\` in \`5 Agent Memory/\`\\n"
```

Replace with:

```bash
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"
```

- [ ] **Step 3: Add OBS variable for CLI path**

After the `CLAUDE_MD=".claude/CLAUDE.md"` line, add:

```bash
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"
```

This isn't used in pre-compact.sh directly (it writes staging files, not CLI calls), but keeps the pattern consistent if we add CLI calls later.

- [ ] **Step 4: Test**

```bash
echo '{}' | bash hooks/pre-compact.sh
```

Expected: JSON output with context re-injection mentioning memberberry and blackbox.

- [ ] **Step 5: Commit**

```bash
git add hooks/pre-compact.sh
git commit -m "feat: update pre-compact.sh with read-once cache clear and subagent references"
```

---

### Task 5: Update config files

**Files:**
- Modify: `config/settings.json`
- Modify: `config/global-claude-md-v2.md`
- Modify: `config/project-claude-md-template.md`

- [ ] **Step 1: Update settings.json — add read-once PreToolUse hook**

Replace the entire `config/settings.json` with:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/session-start.sh"
          }
        ]
      }
    ],
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
    ],
    "PreCompact": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/pre-compact.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/stop-memory.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: Update global-claude-md-v2.md — add subagent delegation rules**

In `config/global-claude-md-v2.md`, find the section:

```
### At Session Start (non-trivial tasks)

The hook gives you the slug. Use it:

1. Search Obsidian for prior context:
   ```
   search_notes(query="<slug>", searchContent=true)
   ```
   Search in: `5 Agent Memory/sessions/by-project/<slug>/`, `5 Agent Memory/learnings/`

2. Briefly state what you found and how it applies. Don't dump everything.

3. Check `5 Agent Memory/project-index.md` if cross-project context would help.

4. Do NOT read `5 Agent Memory/_context.md` unless you specifically need my current priorities.
```

Replace with:

```
### At Session Start (non-trivial tasks)

The hook gives you the slug and dynamic state. For prior context:

1. Delegate to the **memberberry** subagent — it searches the vault using the Obsidian CLI and returns a filtered summary.
2. Do NOT call MCP `search_notes` or read vault notes directly — memberberry handles this more efficiently via Haiku.
3. Briefly state what memberberry found and how it applies.
4. Do NOT read `5 Agent Memory/_context.md` unless you specifically need my current priorities.
```

Also find the section:

```
### During Work

- Use `5 Agent Memory/working/` freely as scratchpad for in-progress state
- If the Stop hook nudges about session length, acknowledge it
- If context hits ~50%, checkpoint to `working/` before compaction
- The PreCompact hook creates a staging file automatically — fill it in with actual session state when you can
- If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.
```

Replace with:

```
### During Work

- Use `5 Agent Memory/working/` freely as scratchpad for in-progress state
- If the Stop hook nudges about session length, acknowledge it
- If context hits ~50%, delegate to **blackbox** subagent to capture a checkpoint before compaction
- The PreCompact hook creates a staging file automatically — blackbox can fill it or write its own checkpoint directly to the vault
- If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.
```

Also find the MCP Tools Available section:

```
## MCP Tools Available

- **MCP-Obsidian**: read_note, write_note, search_notes, get_frontmatter, list_directory, update_frontmatter, move_note, manage_tags, read_multiple_notes, get_notes_info, patch_note
```

Replace with:

```
## Tools Available

### Obsidian CLI (reads — used by subagents)

Requires Obsidian 1.12+ with CLI enabled. Used by memberberry and blackbox subagents for token-efficient vault reads.

Key commands: `search`, `search:context`, `property:read`, `read`, `backlinks`, `links`, `tasks`, `create`, `append`

### MCP-Obsidian (writes)

- **MCP-Obsidian**: write_note, patch_note, update_frontmatter, move_note, manage_tags

### Subagents

- **memberberry** — Memory retrieval. Delegate all vault read operations here.
- **blackbox** — Session checkpoint capture before compaction.
```

- [ ] **Step 3: Rewrite project-claude-md-template.md — slim to ~500 tokens**

Replace `config/project-claude-md-template.md` with:

```markdown
# <Project Name>

<!-- memory:project-slug=<slug> -->
<!-- memory:area=<area> -->

## Architecture

<2-4 sentences. Stack, structure, key patterns.>

## Conventions

- <Code style, tooling choices, naming conventions>
- <Testing approach>
- <Key dependencies>

## Structure

```
<Top 2 levels of project directory tree>
```

## Memory

- **Obsidian sessions:** `5 Agent Memory/sessions/by-project/<slug>/`
- Use **memberberry** agent for prior context retrieval
- Use **blackbox** agent for checkpoint capture before compaction
- Do NOT call MCP search_notes or read vault notes directly
- SessionStart hook provides current state automatically

## Project-Specific Rules

<Any rules specific to this project.>
```

- [ ] **Step 4: Commit**

```bash
git add config/settings.json config/global-claude-md-v2.md config/project-claude-md-template.md
git commit -m "feat: update configs for v3 subagent delegation and read-once hook

- settings.json: add PreToolUse read-once hook registration
- global CLAUDE.md: replace MCP read guidance with subagent delegation
- project template: slim to ~500 token target with subagent instructions"
```

---

### Task 6: Update slash commands

**Files:**
- Modify: `commands/memory-load.md`
- Modify: `commands/memory-sync.md`
- Modify: `commands/memory-init.md`

- [ ] **Step 1: Update memory-load.md — delegate to memberberry**

In `commands/memory-load.md`, find the `allowed-tools` frontmatter:

```yaml
allowed-tools:
  - "obsidian:read_note"
  - "obsidian:search_notes"
  - "obsidian:get_frontmatter"
  - "obsidian:list_directory"
  - "obsidian:read_multiple_notes"
  - "obsidian:get_notes_info"
```

Replace with:

```yaml
allowed-tools:
  - "Agent"
  - "Bash"
  - "obsidian:read_note"
  - "obsidian:search_notes"
  - "obsidian:get_frontmatter"
  - "obsidian:list_directory"
  - "obsidian:read_multiple_notes"
  - "obsidian:get_notes_info"
```

Then find the Steps section starting with `### 1. Identify Context Needed`. Replace Steps 1-5 (everything from `### 1.` up to but not including `### 6. Summarise`) with:

```markdown
### 1. Delegate to memberberry

After restoring hook-level context (Step 0), delegate the vault search to the memberberry subagent:

```
Use the memberberry agent to find prior context for project "<slug>".
```

If $ARGUMENTS was provided, pass it as the search topic:
```
Use the memberberry agent to find context about "<$ARGUMENTS>" for project "<slug>".
```

memberberry will:
- Search the vault using Obsidian CLI (progressive disclosure)
- Check for corrections
- Return a filtered summary

If memberberry is unavailable or errors, fall back to the MCP steps below.

### 2. Fallback: MCP Search (only if memberberry fails)

```
search_notes(query="<slug>", searchContent=true)
```

Search `5 Agent Memory/sessions/by-project/<slug>/` for recent sessions.
Use `get_frontmatter` to scan dates and status before reading full content.

### 3. Fallback: Load Learnings

```
search_notes(query="<slug OR technology>", searchContent=true)
```

Search `5 Agent Memory/learnings/` for project-related learnings.

### 4. Fallback: Check Working Files

```
list_directory("5 Agent Memory/working/")
```

Read any active working files for this project.
```

- [ ] **Step 2: Update memory-sync.md — add CLI property:set on completion**

In `commands/memory-sync.md`, find the section that writes the session note (search for the step that calls `write_note`). After the `write_note` call, add a new step:

Find the text that includes writing the session note to Obsidian. After that step, add:

```markdown
#### Set status via CLI (if available)

After writing the session note, if Obsidian CLI is available, set the status property:

```bash
${OBSIDIAN_CLI_PATH:-obsidian} property:set name="status" value="complete" path="<session note path>" 2>/dev/null || true
```

This is a convenience — the frontmatter already has the status, but the CLI property:set makes it queryable independently.
```

- [ ] **Step 3: Update memory-init.md — add CLI check and subagent guidance**

In `commands/memory-init.md`, find the section that sets up the project CLAUDE.md. Update the Memory section template to include subagent references:

Find the text that generates the Memory section in the project CLAUDE.md. It should contain references to `/memory-load` and `/memory-sync`. Add subagent delegation instructions:

After the line about Obsidian session path, add:
```
- Use **memberberry** agent for prior context retrieval
- Use **blackbox** agent for checkpoint capture before compaction
- Do NOT call MCP search_notes or read vault notes directly
```

Also add a CLI availability check near the start of the command. After the slug detection, add:

```markdown
#### Check CLI availability

```bash
${OBSIDIAN_CLI_PATH:-obsidian} version 2>/dev/null
```

If the CLI is available, note it. If not, warn:
"Obsidian CLI not available. The memory system will work via MCP but subagents (memberberry, blackbox) need the CLI for optimal performance. See docs/cli-setup.md for setup instructions."
```

- [ ] **Step 4: Commit**

```bash
git add commands/memory-load.md commands/memory-sync.md commands/memory-init.md
git commit -m "feat: update slash commands for v3 subagent delegation

- memory-load: delegate to memberberry, MCP as fallback
- memory-sync: add CLI property:set after session note write
- memory-init: add CLI check, subagent guidance in generated CLAUDE.md"
```

---

### Task 7: Update agent-memory skill

**Files:**
- Modify: `skills/agent-memory/SKILL.md`

- [ ] **Step 1: Update the architecture diagram**

In `skills/agent-memory/SKILL.md`, find the architecture overview:

```
┌────────────────────────────────────────────────────┐
│  TIER 3 — COLD  (Obsidian: 5 Agent Memory/)       │
```

Replace the entire architecture block (from the first `┌` to the line ending with `Commands:`) with:

```
┌────────────────────────────────────────────────────┐
│  LAYER 4 — READ-ONCE  (PreToolUse hook)            │
│  Deduplicates source code Read calls               │
├────────────────────────────────────────────────────┤
│  LAYER 3 — SUBAGENTS  (Haiku, on-demand)           │
│  memberberry: vault retrieval via CLI               │
│  blackbox: checkpoint capture via CLI               │
├────────────────────────────────────────────────────┤
│  LAYER 2 — SESSION START  (CLI-driven, injected)    │
│  Git state, open tasks, project status, working/   │
├────────────────────────────────────────────────────┤
│  LAYER 1 — CLAUDE.MD  (~500 tokens, every turn)     │
│  Static: architecture, conventions, structure       │
└────────────────────────────────────────────────────┘

Hooks: SessionStart → PreCompact → Stop
Subagents: memberberry (retrieval) → blackbox (checkpoint)
Staging: ~/.claude/memory-staging/<slug>/
Commands: /memory-init  /memory-load  /memory-sync
```

- [ ] **Step 2: Update Core Principles**

Find principle 1:

```
1. **Hooks handle detection, you handle MCP** — SessionStart injects the project slug and flags pending items. You read/write Obsidian via MCP in response.
```

Replace with:

```
1. **Hooks detect, subagents retrieve, MCP writes** — SessionStart injects the project slug and dynamic state via CLI. Delegate vault reads to memberberry (Haiku). Write to Obsidian via MCP.
```

- [ ] **Step 3: Update Hook Integration table**

Find the Hook Integration table and update PreCompact:

```
| **PreCompact** | Before compaction | Path to checkpoint staging file | Fill in the staging file with actual session state (decisions, progress, open items) before compaction completes. After compaction, push to `working/`. |
```

Replace with:

```
| **PreCompact** | Before compaction | Path to checkpoint staging file, clears read-once cache | Delegate to **blackbox** subagent for checkpoint capture. blackbox distils decisions, progress, and open items to the vault. |
```

- [ ] **Step 4: Update Load Context operation**

Find the "### 2. Load Context" section. Replace the "How:" block:

```
**How:**
```
1. Use the project slug from hook context
2. search_notes(query="<slug>", searchContent=true)
   - Search in: 5 Agent Memory/sessions/by-project/<slug>/
   - Also search: 5 Agent Memory/learnings/
3. For cross-project context: read_note("5 Agent Memory/project-index.md")
4. Summarise what's relevant — don't dump everything
```
```

Replace with:

```
**How:**
```
1. Use the project slug from hook context
2. Delegate to memberberry subagent:
   "Use memberberry to find prior context for <slug>"
3. memberberry searches via CLI: search → search:context → property:read → selective read
4. Main agent receives filtered summary (~200 tokens)
5. If memberberry unavailable, fall back to MCP search_notes
```
```

- [ ] **Step 5: Update MCP Tools Reference**

Find the `## MCP Tools Reference` section. Replace with:

```markdown
## Tools Reference

### Obsidian CLI (reads — via subagents)

| Command | Use For |
|---------|---------|
| `search` | Find notes by content (paths only) |
| `search:context` | Matching lines with context |
| `property:read` | Read frontmatter fields |
| `read` | Full note content (last resort) |
| `backlinks` / `links` | Graph traversal |
| `tasks` | Task queries (requires file path, not folder) |
| `create` / `append` | Note creation |
| `property:set` | Set frontmatter values |

### MCP-Obsidian (writes)

| Tool | Use For |
|------|---------|
| `write_note` | Create/update notes |
| `patch_note` | Update part of a note |
| `update_frontmatter` | Modify metadata only |
| `move_note` | Move/rename notes |
| `manage_tags` | Tag operations |
```

- [ ] **Step 6: Update Token Efficiency section**

Find the `## Token Efficiency` section. Replace with:

```markdown
## Token Efficiency

The v3 architecture optimises tokens at every layer:

- **CLAUDE.md** — static only, ~500 tokens per turn (vs ~1500+ in v2)
- **SessionStart** — CLI snapshot, ~200-300 tokens once (vs MCP dump)
- **memberberry** — Haiku retrieval, main model gets ~200 token summary
- **blackbox** — Haiku checkpoint, no main model context cost
- **read-once** — blocks redundant source code reads, ~2000 tokens saved per prevented re-read

**Rules:**
- Never call MCP `search_notes` or `read_note` directly — delegate to memberberry
- Never manually fill checkpoint stubs — delegate to blackbox
- Use `property:read` over `read` when you only need frontmatter
- Keep session summaries concise — details go in linked files
```

- [ ] **Step 7: Commit**

```bash
git add skills/agent-memory/SKILL.md
git commit -m "feat: update agent-memory skill for v3 CLI + subagent architecture

Replaces MCP read guidance with subagent delegation pattern.
Updates architecture diagram, hook integration, load context
operation, and tools reference for CLI + Haiku layered model."
```

---

### Task 8: Create obsidian-cli skill

**Files:**
- Create: `skills/obsidian-cli/SKILL.md`

- [ ] **Step 1: Create directory**

```bash
mkdir -p skills/obsidian-cli
```

- [ ] **Step 2: Create SKILL.md**

Create `skills/obsidian-cli/SKILL.md`:

```markdown
---
name: obsidian-cli
description: "Reference for Obsidian CLI commands used by the agent memory system. Use when you need to interact with the Obsidian vault via CLI — searching notes, reading properties, checking tasks, or creating content. Requires Obsidian 1.12+ with CLI enabled. Triggers on: Obsidian CLI commands, vault search, vault tasks, note properties, CLI troubleshooting."
---

# Obsidian CLI Reference

Command reference for Obsidian CLI 1.12+ as used by the agent memory system.

## CLI Binary

```bash
${OBSIDIAN_CLI_PATH:-obsidian}
```

On Windows, Obsidian registers `Obsidian.com` (terminal redirector) on PATH.
If the bare command fails, check `docs/cli-setup.md` for platform-specific setup.

## Search Commands

### search — Find notes by content (paths only)

```bash
obsidian search query="<text>" path="<folder>" format=json limit=<n>
```

Returns JSON array of matching file paths. Cheapest search — start here.

**Options:** `total` (count only), `case` (case sensitive)

### search:context — Matching lines with context

```bash
obsidian search:context query="<text>" path="<folder>" format=json limit=<n>
```

Returns JSON array of `{file, matches: [{line, text}]}`. Use to assess
relevance without loading full notes.

## Property Commands

### property:read — Read frontmatter field

```bash
obsidian property:read name="<field>" path="<file>"
```

Returns raw value. Use for `decisions`, `follow_up`, `status`, `tags`.

### property:set — Set frontmatter field

```bash
obsidian property:set name="<field>" value="<value>" path="<file>"
```

## File Commands

### read — Full note content

```bash
obsidian read path="<file>"
```

Returns full markdown content. **Last resort** — use search:context
and property:read first.

### create — Create a new note

```bash
obsidian create path="<path>" content="<text>"
obsidian create path="<path>" content="<text>" overwrite
```

### append — Append to a note

```bash
obsidian append path="<path>" content="<text>"
```

### outline — Heading structure

```bash
obsidian outline path="<file>" format=json
```

Returns heading tree without content. Useful for large notes.

## Graph Commands

### backlinks — Incoming links

```bash
obsidian backlinks path="<file>" format=json counts
```

### links — Outgoing links

```bash
obsidian links path="<file>"
```

## Task Commands

### tasks — List tasks

```bash
obsidian tasks path="<file>" todo format=json
```

**Important:** Requires a file path, not a folder path. To find tasks
across a folder, use `search:context query="- [ ]" path="<folder>"`.

## Tag Commands

### tags — List tags

```bash
obsidian tags path="<file>" counts format=json
```

## Daily Note Commands

### daily:append — Append to daily note

```bash
obsidian daily:append content="<text>"
```

### daily:read — Read daily note

```bash
obsidian daily:read
```

## Vault Info

```bash
obsidian version
obsidian vault
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `command not found` | Check PATH setup — see `docs/cli-setup.md` |
| `Obsidian is not running` | Open Obsidian app first |
| `folder, not a file` | Use `search:context` instead of `tasks` for folder-level queries |
| Slow response | Obsidian may be starting up — first command launches the app |
```

- [ ] **Step 3: Commit**

```bash
git add skills/obsidian-cli/SKILL.md
git commit -m "feat: add obsidian-cli skill with CLI command reference"
```

---

### Task 9: Create documentation

**Files:**
- Create: `docs/cli-setup.md`
- Modify: `README.md`

- [ ] **Step 1: Create docs/cli-setup.md**

```markdown
# Obsidian CLI Setup

The agent memory v3 system uses the Obsidian CLI (1.12+) for token-efficient vault reads. This guide covers per-platform setup.

## Prerequisites

- Obsidian 1.12.4+ **installer** (not just an app update — the installer adds the CLI binary)
- Catalyst licence (early access, as of March 2026)

## Enable CLI

1. Open Obsidian
2. Go to **Settings → General**
3. Enable **Command line interface**
4. Follow the registration prompt
5. Restart your terminal

## Platform-Specific Setup

### Windows (PowerShell / CMD)

The 1.12+ installer places `Obsidian.com` (terminal redirector) alongside `Obsidian.exe` and registers it on PATH. After enabling CLI in settings and restarting your terminal:

```powershell
obsidian version
# Expected: 1.12.x (installer 1.12.x)
```

### Windows (Git Bash / WSL / Claude Code)

Git Bash and WSL may not inherit the Windows PATH. Add manually:

```bash
# Add to ~/.bashrc or ~/.bash_profile
export PATH="/c/Program Files/Obsidian:$PATH"
```

Then restart your shell and test:

```bash
obsidian version
```

### macOS

CLI is registered via Settings → General → CLI. Available in all terminals after restart.

```bash
obsidian version
```

If not found, check if the Obsidian app bundle includes the CLI binary and add its location to PATH.

### Linux

CLI is registered via Settings → General → CLI. If using AppImage, the CLI binary may need manual PATH setup:

```bash
# Find the CLI binary
find / -name "obsidian" -type f 2>/dev/null

# Add to PATH
export PATH="/path/to/obsidian/cli:$PATH"
```

## Fallback: Environment Variable

If the bare `obsidian` command does not work in your shell, set the full path:

```bash
export OBSIDIAN_CLI_PATH="/c/Program Files/Obsidian/Obsidian.com"
```

All hooks and subagents use `${OBSIDIAN_CLI_PATH:-obsidian}` and will pick this up.

## Verify

```bash
# Check version
obsidian version

# Test search
obsidian search query="test" path="5 Agent Memory" format=json limit=1

# Test property read
obsidian property:read name="type" path="5 Agent Memory/project-index.md"
```

All three should return without error. If Obsidian is not running, the first command may take a few seconds to launch it.
```

- [ ] **Step 2: Update README.md**

Read the current README.md first, then make these changes:

**At the top**, update the project description to mention v3:

Find the first paragraph describing what the project is. Add after it:

```markdown
**v3** introduces Obsidian CLI for token-efficient reads, Haiku subagents for retrieval (memberberry) and checkpoint capture (blackbox), a vendored read-once hook for source code deduplication, and slimmed CLAUDE.md templates.
```

**In the Architecture section**, add a new subsection for subagents:

```markdown
### Subagents

| Agent | Model | Purpose |
|-------|-------|---------|
| `memberberry` | Haiku | Memory retrieval — progressive CLI search → filter → summarise |
| `blackbox` | Haiku | Session checkpoint — captures state before compaction |

Agent definitions live in `agents/` and are deployed to `~/.claude/agents/`.
```

**In the Architecture section**, add read-once:

```markdown
### read-once Hook

A vendored PreToolUse hook that prevents redundant file re-reads within a session. Saves ~2,000 tokens per blocked re-read.

Vendored from [Boucle framework](https://github.com/Bande-a-Bonnot/Boucle-framework/tree/main/tools/read-once).

Configuration via environment variables — see `hooks/read-once/README.md`.
```

**In the Installation section**, add:

```markdown
### Prerequisites

- Obsidian 1.12+ with CLI enabled — see `docs/cli-setup.md` for per-platform setup
- Claude Code with subagent support
- Max subscription (for Haiku subagent delegation)
```

And add agent deployment to the installation steps:

```markdown
- Agent definitions from `agents/` → `~/.claude/agents/`
- read-once hook from `hooks/read-once/` → `~/.claude/hooks/read-once/`
```

**In the Hook Scripts table**, add:

```markdown
| `hooks/read-once/hook.sh` | PreToolUse (Read) | Block/warn on redundant file reads | `~/.claude/hooks/read-once/hook.sh` |
```

- [ ] **Step 3: Commit**

```bash
git add docs/cli-setup.md README.md
git commit -m "docs: add CLI setup guide and update README for v3 architecture

- cli-setup.md: per-platform Obsidian CLI PATH setup
- README: v3 overview, subagents, read-once, prerequisites"
```

---

### Task 10: Update stop-memory.sh (minor)

**Files:**
- Modify: `hooks/stop-memory.sh`

- [ ] **Step 1: Add OBS variable for consistency**

After the `CLAUDE_MD=".claude/CLAUDE.md"` line, add:

```bash
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"
```

- [ ] **Step 2: Commit**

```bash
git add hooks/stop-memory.sh
git commit -m "chore: add OBSIDIAN_CLI_PATH variable to stop-memory.sh for consistency"
```

---

### Task 11: Integration testing

No files to create — this is manual verification.

- [ ] **Step 1: Deploy files to ~/.claude/**

```bash
# Agents
cp agents/memberberry.md ~/.claude/agents/
cp agents/blackbox.md ~/.claude/agents/

# Hooks
cp hooks/session-start.sh ~/.claude/hooks/
cp hooks/pre-compact.sh ~/.claude/hooks/
cp hooks/stop-memory.sh ~/.claude/hooks/
mkdir -p ~/.claude/hooks/read-once
cp hooks/read-once/hook.sh ~/.claude/hooks/read-once/

# Merge settings.json (careful — don't overwrite existing non-memory hooks)
# Compare config/settings.json with ~/.claude/settings.json and merge
```

- [ ] **Step 2: Verify agents are visible**

Start a new Claude Code session and run `/agents`. Both `memberberry` and `blackbox` should appear.

- [ ] **Step 3: Test SessionStart hook**

Start a new Claude Code session in a project with memory configured. The session context should show:
- Git state (branch, dirty files)
- Project status from vault (if CLI is working)
- Open items (if any exist)
- Delegation guidance mentioning memberberry and blackbox

- [ ] **Step 4: Test memberberry**

In a Claude Code session, ask:
```
Use memberberry to find prior context for memory-architecture
```

memberberry should:
1. Search the vault via CLI
2. Return a filtered summary
3. Complete in Haiku (check model indicator)

- [ ] **Step 5: Test blackbox**

In a Claude Code session, ask:
```
Use blackbox to checkpoint the current session for project memory-architecture
```

blackbox should:
1. Write a checkpoint to `5 Agent Memory/working/`
2. Include decisions, progress, open items
3. Complete in Haiku

- [ ] **Step 6: Test read-once**

In a Claude Code session:
1. Read a file (should work normally)
2. Read the same file again (should see warning about "already in context")
3. Edit the file
4. Read it again (should work — mtime changed)

- [ ] **Step 7: Test CLI fallback**

Close Obsidian, start a new Claude Code session. SessionStart should output "CLI unavailable" with minimal context and MCP fallback guidance.

- [ ] **Step 8: Verify token reduction**

Compare `/context` output before and after v3 deployment. The CLAUDE.md token count should be lower (~500 vs previous), and SessionStart injection should be more concise.
