# Persistent Memory Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make memory context survive compaction and `/clear` by adding a persistent state file, PreCompact re-injection, `/memory-load` recovery, and fixing `grep -oP` portability.

**Architecture:** SessionStart writes `.claude/memory-state.json` as ground truth. PreCompact reads it to re-inject context after compaction. `/memory-load` reads it as a fast path for manual recovery after `/clear`. All `grep -oP` calls replaced with portable `sed`.

**Tech Stack:** Bash (hook scripts), Markdown (slash commands), JSON (state file), `jq` + `sed`

**Spec:** `docs/superpowers/specs/2026-03-30-persistent-memory-context-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `hooks/session-start.sh` | Modify | Fix `grep -oP`, write `memory-state.json`, add `detectedVia` tracking |
| `hooks/pre-compact.sh` | Modify | Fix `grep -oP`, read state file for slug, update pending checkpoints, re-inject full context |
| `hooks/stop-memory.sh` | Modify | Fix `grep -oP`, read slug from state file first |
| `commands/memory-load.md` | Modify | Add Step 0 preamble: read state file, restore hook-level context |
| `commands/memory-init.md` | Modify | Add instruction to write `memory-state.json` after slug setup |
| `config/global-claude-md-v2.md` | Modify | Add recovery instruction for post-clear |

---

### Task 1: Fix `grep -oP` in session-start.sh

All `grep -oP` calls in this file use PCRE lookbehinds that fail silently on Windows Git Bash. Replace with portable `sed`.

**Files:**
- Modify: `hooks/session-start.sh:17` (slug detection)
- Modify: `hooks/session-start.sh:76` (area detection)

- [ ] **Step 1: Replace slug detection grep**

In `hooks/session-start.sh`, replace line 17:

```bash
# Before:
slug=$(grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' "$CLAUDE_MD" 2>/dev/null || true)

# After:
slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
```

- [ ] **Step 2: Replace area detection grep**

In `hooks/session-start.sh`, replace line 76:

```bash
# Before:
area=$(grep -oP '(?<=memory:area=)[^\s]+' "$CLAUDE_MD" 2>/dev/null || true)

# After:
area=$(sed -n 's/.*memory:area=\([^ ]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
```

- [ ] **Step 3: Test slug detection from CLAUDE.md metadata**

Create a temporary test file and verify:

```bash
mkdir -p /tmp/test-memory-hooks/.claude
cat > /tmp/test-memory-hooks/.claude/CLAUDE.md << 'EOF'
# Test Project
<!-- memory:project-slug=wafr-discovery -->
<!-- memory:area=AWS -->
EOF

cd /tmp/test-memory-hooks && echo '{}' | bash ~/.claude/hooks/session-start.sh 2>/dev/null
```

Expected: JSON output containing `"wafr-discovery"` as the slug and `"AWS"` as the area.

- [ ] **Step 4: Test fallback when no CLAUDE.md metadata exists**

```bash
mkdir -p /tmp/test-no-metadata/.claude
cat > /tmp/test-no-metadata/.claude/CLAUDE.md << 'EOF'
# Test Project
No memory metadata here.
EOF

cd /tmp/test-no-metadata && echo '{}' | bash ~/.claude/hooks/session-start.sh 2>/dev/null
```

Expected: JSON output with slug detected via git remote or directory name fallback. Should contain `"No memory configuration found"` warning.

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh
git commit -m "fix: replace grep -oP with portable sed in session-start.sh

grep -oP (PCRE lookbehind) fails silently on Windows Git Bash due to
locale issues, causing Priority 1 slug detection to always fail."
```

---

### Task 2: Fix `grep -oP` in stop-memory.sh

Same portability fix for the stop hook. This hook fires on every response, so it must stay fast.

**Files:**
- Modify: `hooks/stop-memory.sh:14` (slug detection)
- Modify: `hooks/stop-memory.sh:37` (message count)
- Modify: `hooks/stop-memory.sh:49` (session start time)

- [ ] **Step 1: Replace slug detection grep**

In `hooks/stop-memory.sh`, replace line 14:

```bash
# Before:
grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' "$CLAUDE_MD" 2>/dev/null && return 0

# After:
local slug
slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1)
if [[ -n "$slug" ]]; then echo "$slug"; return 0; fi
```

Note: The original used `grep ... && return 0` (grep both prints and gates). The replacement needs an explicit variable + check because `sed` always exits 0.

- [ ] **Step 2: Replace message count grep**

In `hooks/stop-memory.sh`, replace line 37:

```bash
# Before:
CURRENT_COUNT=$(grep -oP '(?<=message_count=)\d+' "$META_FILE" 2>/dev/null || echo "0")

# After:
CURRENT_COUNT=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$META_FILE" 2>/dev/null | head -1)
CURRENT_COUNT="${CURRENT_COUNT:-0}"
```

- [ ] **Step 3: Replace session start grep**

In `hooks/stop-memory.sh`, replace line 49:

```bash
# Before:
SESSION_START=$(grep -oP '(?<=session_start=).*' "$META_FILE" 2>/dev/null || echo "")

# After:
SESSION_START=$(sed -n 's/.*session_start=\(.*\)/\1/p' "$META_FILE" 2>/dev/null | head -1)
SESSION_START="${SESSION_START:-}"
```

- [ ] **Step 4: Test stop hook**

```bash
mkdir -p /tmp/test-stop/.claude
cat > /tmp/test-stop/.claude/CLAUDE.md << 'EOF'
<!-- memory:project-slug=test-stop -->
EOF

cd /tmp/test-stop && echo '{}' | bash ~/.claude/hooks/stop-memory.sh 2>/dev/null
# Should exit 0 with no output (no nudge on first message)

# Check that session-meta was created with correct slug
cat ~/.claude/memory-staging/test-stop/.session-meta
```

Expected: `.session-meta` file exists with `project_slug=test-stop` and `message_count=1`.

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-memory.sh
git commit -m "fix: replace grep -oP with portable sed in stop-memory.sh"
```

---

### Task 3: Fix `grep -oP` in pre-compact.sh

Same portability fix for the pre-compact hook.

**Files:**
- Modify: `hooks/pre-compact.sh:15` (slug detection)
- Modify: `hooks/pre-compact.sh:42` (message count)
- Modify: `hooks/pre-compact.sh:43` (session start time)

- [ ] **Step 1: Replace slug detection grep**

In `hooks/pre-compact.sh`, replace line 15:

```bash
# Before:
slug=$(grep -oP '(?<=memory:project-slug=)[^\s-]+[a-z0-9-]*' "$CLAUDE_MD" 2>/dev/null || true)

# After:
slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
```

- [ ] **Step 2: Replace message count and session start greps**

In `hooks/pre-compact.sh`, replace lines 42-43:

```bash
# Before:
MESSAGE_COUNT=$(grep -oP '(?<=message_count=)\d+' "$PROJECT_DIR/.session-meta" || echo "0")
SESSION_START=$(grep -oP '(?<=session_start=).*' "$PROJECT_DIR/.session-meta" || echo "unknown")

# After:
MESSAGE_COUNT=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$PROJECT_DIR/.session-meta" 2>/dev/null | head -1)
MESSAGE_COUNT="${MESSAGE_COUNT:-0}"
SESSION_START=$(sed -n 's/.*session_start=\(.*\)/\1/p' "$PROJECT_DIR/.session-meta" 2>/dev/null | head -1)
SESSION_START="${SESSION_START:-unknown}"
```

- [ ] **Step 3: Test pre-compact hook**

```bash
mkdir -p /tmp/test-compact/.claude
cat > /tmp/test-compact/.claude/CLAUDE.md << 'EOF'
<!-- memory:project-slug=test-compact -->
EOF
mkdir -p ~/.claude/memory-staging/test-compact
cat > ~/.claude/memory-staging/test-compact/.session-meta << 'EOF'
session_start=2026-03-30T10:00:00Z
message_count=5
project_slug=test-compact
area=
EOF

cd /tmp/test-compact && echo '{}' | bash ~/.claude/hooks/pre-compact.sh 2>/dev/null
```

Expected: JSON output with systemMessage about checkpoint. A `checkpoint-*.md` file created in `~/.claude/memory-staging/test-compact/`.

- [ ] **Step 4: Commit**

```bash
git add hooks/pre-compact.sh
git commit -m "fix: replace grep -oP with portable sed in pre-compact.sh"
```

---

### Task 4: Add persistent state file to session-start.sh

SessionStart writes `.claude/memory-state.json` after slug detection, providing ground truth that survives compaction and clear.

**Files:**
- Modify: `hooks/session-start.sh` (add state file write after detection, add `detectedVia` tracking)

- [ ] **Step 1: Add `detectedVia` tracking to detect_slug**

Refactor `detect_slug` to also report which method found the slug. Change the function to set two variables instead of printing:

```bash
# Replace the entire detect_slug function with:
detect_slug() {
    # Priority 1: Existing CLAUDE.md metadata
    if [[ -f "$CLAUDE_MD" ]]; then
        local slug
        slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
        if [[ -n "$slug" ]]; then
            DETECTED_VIA="claude-md-metadata"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 1b: .claude/memory-state.json from prior session
    if [[ -f ".claude/memory-state.json" ]]; then
        local slug
        slug=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            DETECTED_VIA="memory-state-file"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 2: .claude/settings.json custom field
    if [[ -f ".claude/settings.json" ]]; then
        local slug
        slug=$(jq -r '.memory.projectSlug // empty' .claude/settings.json 2>/dev/null || true)
        if [[ -n "$slug" ]]; then
            DETECTED_VIA="settings-json"
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
                DETECTED_VIA="git-remote"
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
            DETECTED_VIA="package-json"
            echo "$slug"
            return 0
        fi
    fi

    if [[ -f "pyproject.toml" ]]; then
        local slug
        slug=$(sed -n 's/.*name = "\([^"]*\)".*/\1/p' pyproject.toml 2>/dev/null | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' || true)
        if [[ -n "$slug" ]]; then
            DETECTED_VIA="pyproject-toml"
            echo "$slug"
            return 0
        fi
    fi

    # Priority 5: Directory name
    DETECTED_VIA="directory-name"
    basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

DETECTED_VIA=""
```

Note: Priority 1b reads `.claude/memory-state.json` from a prior session. This means if CLAUDE.md metadata is missing (e.g. not committed, wrong branch), the state file from the last session provides continuity. This directly addresses the "different branch" issue.

- [ ] **Step 2: Write memory-state.json after detection**

After the `SLUG=$(detect_slug)` and `AREA=$(detect_area)` lines (around line 88), add the state file write. Insert before the checkpoint scanning section:

```bash
# --- Write persistent state file ---
STATE_FILE=".claude/memory-state.json"
mkdir -p .claude

# Scan pending checkpoints for state file
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

# Check dream-pending
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
```

- [ ] **Step 3: Reuse checkpoint scan results**

The existing checkpoint scanning code (lines 94-97) duplicates the work we just did. Replace it to use the array we already built:

```bash
# Check for pending checkpoints from prior sessions
# (already scanned above for state file — reuse results)
PENDING_CHECKPOINTS=()
while IFS= read -r -d '' file; do
    PENDING_CHECKPOINTS+=("$file")
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)
```

This stays as-is (the array is needed for the context injection loop), but the `find` only runs once since we moved the state file write to after directory creation but the checkpoint scan was already there. Alternatively, just leave both — the `find` is fast and the duplication is clearer than trying to share state between JSON generation and array building.

- [ ] **Step 4: Test state file creation**

```bash
mkdir -p /tmp/test-state/.claude
cat > /tmp/test-state/.claude/CLAUDE.md << 'EOF'
# Test
<!-- memory:project-slug=test-state -->
<!-- memory:area=Personal -->
EOF

cd /tmp/test-state && echo '{}' | bash ~/.claude/hooks/session-start.sh 2>/dev/null
cat /tmp/test-state/.claude/memory-state.json
```

Expected: Valid JSON with `"slug": "test-state"`, `"area": "Personal"`, `"detectedVia": "claude-md-metadata"`.

- [ ] **Step 5: Test state file as fallback when CLAUDE.md has no metadata**

```bash
mkdir -p /tmp/test-state-fallback/.claude
# No memory metadata in CLAUDE.md
echo "# Just a project" > /tmp/test-state-fallback/.claude/CLAUDE.md
# But state file from prior session exists
cat > /tmp/test-state-fallback/.claude/memory-state.json << 'EOF'
{
  "slug": "my-real-project",
  "area": "AWS",
  "sessionPath": "5 Agent Memory/sessions/by-project/my-real-project/",
  "detectedVia": "claude-md-metadata",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "2026-03-29T10:00:00Z"
}
EOF

cd /tmp/test-state-fallback && echo '{}' | bash ~/.claude/hooks/session-start.sh 2>/dev/null
```

Expected: Slug detected as `my-real-project` (from state file, Priority 1b). `detectedVia` should be `"memory-state-file"`.

- [ ] **Step 6: Commit**

```bash
git add hooks/session-start.sh
git commit -m "feat: write persistent memory-state.json from session-start hook

Writes .claude/memory-state.json with slug, area, checkpoints, and
detection method. Survives compaction and /clear. Also serves as
Priority 1b fallback for slug detection when CLAUDE.md metadata is
missing (wrong branch, worktree, etc)."
```

---

### Task 5: Update pre-compact.sh to re-inject full context

PreCompact reads `memory-state.json` and re-injects the full memory context block so Claude retains awareness after compaction.

**Files:**
- Modify: `hooks/pre-compact.sh` (read state file, build context block, update checkpoints)

- [ ] **Step 1: Replace slug detection with state file read**

Replace the `detect_slug` function and `SLUG=$(detect_slug)` call with a state-file-first approach:

```bash
# --- Slug detection: state file first, then fallback ---
STATE_FILE=".claude/memory-state.json"
SLUG=""
AREA=""
SESSION_PATH=""

if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null || true)
    AREA=$(jq -r '.area // empty' "$STATE_FILE" 2>/dev/null || true)
    SESSION_PATH=$(jq -r '.sessionPath // empty' "$STATE_FILE" 2>/dev/null || true)
fi

# Fallback: detect slug if state file missing or empty
if [[ -z "$SLUG" ]]; then
    detect_slug() {
        if [[ -f "$CLAUDE_MD" ]]; then
            local slug
            slug=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1 || true)
            if [[ -n "$slug" ]]; then echo "$slug"; return 0; fi
        fi

        if command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
            local remote
            remote=$(git remote get-url origin 2>/dev/null || true)
            if [[ -n "$remote" ]]; then
                echo "$remote" | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]'
                return 0
            fi
        fi

        basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
    }
    SLUG=$(detect_slug)
    SESSION_PATH="5 Agent Memory/sessions/by-project/$SLUG/"
fi
```

- [ ] **Step 2: Update state file with new checkpoint**

After the existing checkpoint file creation (the `cat > "$CHECKPOINT_FILE"` block), add:

```bash
# Update state file with new checkpoint
if [[ -f "$STATE_FILE" ]]; then
    # Add the new checkpoint to pendingCheckpoints array
    jq --arg cp "$CHECKPOINT_FILE" '.pendingCheckpoints += [$cp] | .lastUpdated = now | todate' "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null && mv "${STATE_FILE}.tmp" "$STATE_FILE" || true
fi
```

- [ ] **Step 3: Build and inject full memory context block**

Replace the final `cat << HOOKJSON` block with a combined context + checkpoint message:

```bash
# --- Build context re-injection ---
CONTEXT="## Memory System Active (restored after compaction)\\n"
CONTEXT+="Project slug: \`$SLUG\`\\n"

if [[ -n "$AREA" ]]; then
    CONTEXT+="Area: \`$AREA\`\\n"
fi

CONTEXT+="Obsidian session path: \`${SESSION_PATH:-5 Agent Memory/sessions/by-project/$SLUG/}\`\\n\\n"

# List all pending checkpoints (including the one just created)
CONTEXT+="📋 **Pending checkpoints:**\\n"
CONTEXT+="- \`$CHECKPOINT_FILE\` (just created — fill in session state before compaction completes)\\n"
while IFS= read -r -d '' file; do
    if [[ "$file" != "$CHECKPOINT_FILE" ]]; then
        CONTEXT+="- \`$file\` (from prior session)\\n"
    fi
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)
CONTEXT+="Process these to Obsidian \`5 Agent Memory/working/\` when appropriate, then delete the staging files.\\n\\n"

# Dream pending
if [[ -f "$PROJECT_DIR/.dream-pending" ]]; then
    CONTEXT+="💤 **Dream consolidation pending.** Run \`/memory-sync --dream\` when you have a moment.\\n\\n"
fi

CONTEXT+="**For non-trivial tasks:** Search Obsidian for prior context before starting:\\n"
CONTEXT+="\`search_notes(query=\\"$SLUG\\", searchContent=true)\` in \`5 Agent Memory/\`\\n"

# Output combined context
cat << HOOKJSON
{
  "systemMessage": "$(echo -e "$CONTEXT" | sed 's/"/\\\\"/g' | tr '\n' ' ')"
}
HOOKJSON
```

- [ ] **Step 4: Test pre-compact with state file**

```bash
mkdir -p /tmp/test-compact2/.claude
cat > /tmp/test-compact2/.claude/memory-state.json << 'EOF'
{
  "slug": "my-project",
  "area": "AWS",
  "sessionPath": "5 Agent Memory/sessions/by-project/my-project/",
  "detectedVia": "claude-md-metadata",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "2026-03-30T10:00:00Z"
}
EOF
mkdir -p ~/.claude/memory-staging/my-project
cat > ~/.claude/memory-staging/my-project/.session-meta << 'EOF'
session_start=2026-03-30T10:00:00Z
message_count=12
project_slug=my-project
area=AWS
EOF

cd /tmp/test-compact2 && echo '{}' | bash ~/.claude/hooks/pre-compact.sh 2>/dev/null
```

Expected: JSON systemMessage contains "Memory System Active", slug `my-project`, area `AWS`, and the new checkpoint path.

- [ ] **Step 5: Test pre-compact fallback without state file**

```bash
mkdir -p /tmp/test-compact3/.claude
cat > /tmp/test-compact3/.claude/CLAUDE.md << 'EOF'
<!-- memory:project-slug=fallback-test -->
EOF
mkdir -p ~/.claude/memory-staging/fallback-test
cat > ~/.claude/memory-staging/fallback-test/.session-meta << 'EOF'
session_start=2026-03-30T10:00:00Z
message_count=5
project_slug=fallback-test
area=
EOF

cd /tmp/test-compact3 && echo '{}' | bash ~/.claude/hooks/pre-compact.sh 2>/dev/null
```

Expected: Still works — detects slug from CLAUDE.md metadata via `sed` fallback.

- [ ] **Step 6: Commit**

```bash
git add hooks/pre-compact.sh
git commit -m "feat: re-inject full memory context from pre-compact hook

Reads .claude/memory-state.json for slug/area, builds the same context
block as session-start, and injects it as systemMessage. Claude retains
full memory awareness after compaction. Falls back to slug detection
if state file is missing."
```

---

### Task 6: Update stop-memory.sh to read state file

The stop hook fires on every response and must be fast. Add state file as primary slug source to avoid misdetection.

**Files:**
- Modify: `hooks/stop-memory.sh` (read slug from state file first)

- [ ] **Step 1: Add state file read before detect_slug_fast**

Replace the `detect_slug_fast` function and its call:

```bash
# Fast slug detection: state file first, then minimal fallback
STATE_FILE=".claude/memory-state.json"
SLUG=""

# Try state file first (fastest, most reliable)
if [[ -f "$STATE_FILE" ]]; then
    SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null || true)
fi

# Fallback: minimal detection
if [[ -z "$SLUG" ]]; then
    if [[ -f "$CLAUDE_MD" ]]; then
        SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' "$CLAUDE_MD" 2>/dev/null | head -1)
    fi
fi

if [[ -z "$SLUG" ]]; then
    SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
fi
```

This removes the `detect_slug_fast` function entirely and inlines the logic. State file read via `jq` is fast (< 5ms).

- [ ] **Step 2: Test stop hook with state file**

```bash
mkdir -p /tmp/test-stop2/.claude
cat > /tmp/test-stop2/.claude/memory-state.json << 'EOF'
{
  "slug": "correct-slug",
  "area": "AI",
  "sessionPath": "5 Agent Memory/sessions/by-project/correct-slug/",
  "detectedVia": "claude-md-metadata",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "2026-03-30T10:00:00Z"
}
EOF

cd /tmp/test-stop2 && echo '{}' | bash ~/.claude/hooks/stop-memory.sh 2>/dev/null
cat ~/.claude/memory-staging/correct-slug/.session-meta
```

Expected: `.session-meta` created with `project_slug=correct-slug`.

- [ ] **Step 3: Commit**

```bash
git add hooks/stop-memory.sh
git commit -m "feat: read slug from memory-state.json in stop hook

State file provides consistent slug across all hooks, avoiding
misdetection from worktree paths or wrong git remote."
```

---

### Task 7: Update /memory-load command

Add a Step 0 preamble that restores hook-level context from the state file before loading Obsidian context. This is the manual recovery path after `/clear`.

**Files:**
- Modify: `commands/memory-load.md`

- [ ] **Step 1: Add Step 0 preamble**

Insert a new section before the existing `## Steps` / `### 1. Identify Context Needed`:

```markdown
### 0. Restore Memory Context

Before loading Obsidian context, restore the hook-level context that SessionStart normally provides.

#### 0.1 Read State File

```bash
cat .claude/memory-state.json 2>/dev/null || echo "NOT FOUND"
```

If the state file exists, use its values:
- `slug` → project slug for all subsequent searches
- `area` → Obsidian area
- `sessionPath` → where to find sessions
- `pendingCheckpoints` → files to process
- `dreamPending` → whether to nudge for dream consolidation

If the state file does NOT exist, fall back to detecting the slug:
1. Check `.claude/CLAUDE.md` for `<!-- memory:project-slug=X -->`
2. Check git remote origin
3. Use directory name
Warn the user: "State file missing — using auto-detected slug. Consider running `/memory-init` to set up properly."

#### 0.2 Check Pending Checkpoints

```bash
ls ~/.claude/memory-staging/<slug>/checkpoint-*.md 2>/dev/null
```

If any exist, list them and remind to process to Obsidian `5 Agent Memory/working/`.

#### 0.3 Check Dream Status

If `dreamPending` is true in the state file (or `~/.claude/memory-staging/<slug>/.dream-pending` exists), note: "Dream consolidation pending — run `/memory-sync --dream` when ready."

#### 0.4 Present Context Block

Output a summary matching the SessionStart format:

```
## Memory System Active (restored via /memory-load)
Project slug: `<slug>`
Area: `<area>`
Obsidian session path: `<sessionPath>`
[pending checkpoints if any]
[dream status if pending]
```

Then continue with the normal Obsidian context loading below.
```

- [ ] **Step 2: Update Step 1 to use slug from Step 0**

Change the `### 1. Identify Context Needed` section to reference the slug from Step 0 rather than re-detecting:

```markdown
### 1. Identify Context Needed

Use the project slug from Step 0. If $ARGUMENTS is provided, use it as an additional search topic alongside the slug.
```

- [ ] **Step 3: Commit**

```bash
git add commands/memory-load.md
git commit -m "feat: add state file recovery preamble to /memory-load

Step 0 reads .claude/memory-state.json to restore hook-level context
after /clear. Falls back to slug detection if state file missing."
```

---

### Task 8: Update /memory-init to write state file

When the user runs `/memory-init`, it should write `memory-state.json` so that the state file exists immediately, not just after the next SessionStart.

**Files:**
- Modify: `commands/memory-init.md`

- [ ] **Step 1: Add state file write instruction to Phase 3**

In `commands/memory-init.md`, after the Phase 3 section (`## Phase 3: Create Project CLAUDE.md`), add a subsection:

```markdown
### 3.1 Write Persistent State File

After creating/updating `.claude/CLAUDE.md`, write the state file:

```bash
cat > .claude/memory-state.json << 'STATEJSON'
{
  "slug": "<confirmed-slug>",
  "area": "<confirmed-area>",
  "sessionPath": "5 Agent Memory/sessions/by-project/<confirmed-slug>/",
  "detectedVia": "memory-init",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "<current-ISO-timestamp>"
}
STATEJSON
```

This ensures the state file exists immediately, rather than waiting for the next SessionStart hook to create it.
```

- [ ] **Step 2: Commit**

```bash
git add commands/memory-init.md
git commit -m "feat: write memory-state.json from /memory-init

Ensures state file exists immediately after init, not just after
the next SessionStart hook fires."
```

---

### Task 9: Update global CLAUDE.md template

Add the recovery instruction so Claude knows what to do after compaction or `/clear`.

**Files:**
- Modify: `config/global-claude-md-v2.md`

- [ ] **Step 1: Add recovery instruction**

In `config/global-claude-md-v2.md`, find the `### During Work` section and add after the bullet about PreCompact:

```markdown
- If memory context is missing after compaction or `/clear`, run `/memory-load` to restore it. Persistent state is in `.claude/memory-state.json`.
```

- [ ] **Step 2: Commit**

```bash
git add config/global-claude-md-v2.md
git commit -m "docs: add /memory-load recovery instruction to global CLAUDE.md"
```

---

### Task 10: End-to-end verification

Run through the full lifecycle to verify all pieces work together.

**Files:** None (testing only)

- [ ] **Step 1: Clean slate test — full SessionStart**

```bash
rm -rf /tmp/test-e2e
mkdir -p /tmp/test-e2e/.claude
cat > /tmp/test-e2e/.claude/CLAUDE.md << 'EOF'
# E2E Test
<!-- memory:project-slug=e2e-test -->
<!-- memory:area=Personal -->
EOF

cd /tmp/test-e2e && echo '{}' | bash ~/.claude/hooks/session-start.sh
```

Verify:
- JSON output contains slug `e2e-test`, area `Personal`
- `.claude/memory-state.json` exists with correct values
- `detectedVia` is `claude-md-metadata`

- [ ] **Step 2: Simulate work — stop hook increments**

```bash
cd /tmp/test-e2e && echo '{}' | bash ~/.claude/hooks/stop-memory.sh
echo '{}' | bash ~/.claude/hooks/stop-memory.sh
echo '{}' | bash ~/.claude/hooks/stop-memory.sh
cat ~/.claude/memory-staging/e2e-test/.session-meta
```

Verify: `message_count=3`, `project_slug=e2e-test`.

- [ ] **Step 3: Simulate compaction — pre-compact re-injects**

```bash
cd /tmp/test-e2e && echo '{}' | bash ~/.claude/hooks/pre-compact.sh
```

Verify:
- JSON systemMessage contains "Memory System Active (restored after compaction)"
- Checkpoint file created
- `memory-state.json` updated with new checkpoint in `pendingCheckpoints`

- [ ] **Step 4: Simulate state-file-only recovery (no CLAUDE.md metadata)**

```bash
rm -rf /tmp/test-e2e2
mkdir -p /tmp/test-e2e2/.claude
echo "# No metadata" > /tmp/test-e2e2/.claude/CLAUDE.md
# Copy state file from prior session
cat > /tmp/test-e2e2/.claude/memory-state.json << 'EOF'
{
  "slug": "e2e-test",
  "area": "Personal",
  "sessionPath": "5 Agent Memory/sessions/by-project/e2e-test/",
  "detectedVia": "claude-md-metadata",
  "pendingCheckpoints": [],
  "dreamPending": false,
  "lastUpdated": "2026-03-30T10:00:00Z"
}
EOF

cd /tmp/test-e2e2 && echo '{}' | bash ~/.claude/hooks/session-start.sh
```

Verify: Slug detected as `e2e-test` from state file (Priority 1b). `detectedVia` is `memory-state-file`.

- [ ] **Step 5: Clean up test files**

```bash
rm -rf /tmp/test-e2e /tmp/test-e2e2 /tmp/test-memory-hooks /tmp/test-no-metadata /tmp/test-stop /tmp/test-compact /tmp/test-state /tmp/test-state-fallback /tmp/test-stop2 /tmp/test-compact2 /tmp/test-compact3
# Clean up staging entries created during testing
rm -rf ~/.claude/memory-staging/e2e-test ~/.claude/memory-staging/test-stop ~/.claude/memory-staging/test-compact ~/.claude/memory-staging/test-state ~/.claude/memory-staging/fallback-test ~/.claude/memory-staging/correct-slug ~/.claude/memory-staging/my-project
```

- [ ] **Step 6: Final commit — update spec status**

Update `docs/superpowers/specs/2026-03-30-persistent-memory-context-design.md`, change `**Status:** Draft` to `**Status:** Implemented`.

```bash
git add docs/superpowers/specs/2026-03-30-persistent-memory-context-design.md
git commit -m "docs: mark persistent memory context spec as implemented"
```
