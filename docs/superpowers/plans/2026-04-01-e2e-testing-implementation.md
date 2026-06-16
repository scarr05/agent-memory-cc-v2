# E2E Testing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a semi-automated test suite that validates v3 hook outputs, measures context cost, and provides a repeatable manual playbook for session-level testing across multiple projects.

**Architecture:** Two-phase approach — a bash script (`tests/hook-validation.sh`) that tests hooks in isolation and captures metrics, plus a markdown playbook (`tests/playbook.md`) for manual session-level testing. Results from both phases are recorded in `tests/results/baseline-YYYY-MM-DD.md` for comparison across runs.

**Tech Stack:** Bash (test script), Markdown (playbook + results)

---

## File Structure

```
tests/
├── hook-validation.sh          # Tier 1: scripted hook tests + metrics capture
├── playbook.md                 # Tier 2 + 3: manual session protocol
├── results/
│   └── .gitkeep                # Results dir (actual files gitignored)
└── .gitignore                  # Ignore result files (project-specific data)
```

- `hook-validation.sh` — Single entry point for all scripted tests. Accepts a project path and optional expected slug. Runs each hook, validates output, captures metrics, appends to results file.
- `playbook.md` — Step-by-step manual protocol for Tier 2 (session baseline) and Tier 3 (full lifecycle). Includes blank results tables to copy-paste.
- `tests/results/` — Output directory for baseline files. Gitignored because results contain project-specific paths and vault data.

---

### Task 1: Create test directory structure

**Files:**
- Create: `tests/.gitignore`
- Create: `tests/results/.gitkeep`

- [ ] **Step 1: Create the directory structure and gitignore**

```bash
mkdir -p tests/results
```

- [ ] **Step 2: Write the gitignore**

Create `tests/.gitignore`:
```
# Results contain project-specific paths and vault data
results/*.md
results/*.log
!results/.gitkeep
```

- [ ] **Step 3: Create the .gitkeep**

```bash
touch tests/results/.gitkeep
```

- [ ] **Step 4: Commit**

```bash
git add tests/.gitignore tests/results/.gitkeep
git commit -m "chore: add test directory structure"
```

---

### Task 2: Build hook-validation.sh — setup and session-start tests

**Files:**
- Create: `tests/hook-validation.sh`

This task builds the script skeleton, argument parsing, helper functions, and the session-start hook test. The script must work from any directory (it `cd`s to the target project).

- [ ] **Step 1: Write the script skeleton with argument parsing and helpers**

Create `tests/hook-validation.sh`:

```bash
#!/usr/bin/env bash
# hook-validation.sh — Tier 1: Validate hook outputs and capture metrics
# Usage: bash tests/hook-validation.sh /path/to/project [expected-slug]

set -euo pipefail

# --- Args ---
PROJECT_DIR="${1:?Usage: hook-validation.sh /path/to/project [expected-slug]}"
EXPECTED_SLUG="${2:-}"
HOOKS_DIR="$HOME/.claude/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
TODAY=$(date +%Y-%m-%d)
RESULTS_FILE="$RESULTS_DIR/baseline-$TODAY.md"
ERROR_LOG="$RESULTS_DIR/errors-$TODAY.log"

# Resolve project name for display
PROJECT_NAME=$(basename "$PROJECT_DIR")

# Counters
PASS_COUNT=0
FAIL_COUNT=0

# --- Helpers ---

pass() {
    echo "  PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "  FAIL: $1"
    echo "[$(date -u +%H:%M:%S)] $PROJECT_NAME — FAIL: $1" >> "$ERROR_LOG"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

measure_ms() {
    # Runs a command, prints elapsed ms to stdout, output to fd 3
    local start end elapsed
    start=$(date +%s%N 2>/dev/null || echo "0")
    eval "$@" 3>&1 1>&2 2>&3 3>&-
    end=$(date +%s%N 2>/dev/null || echo "0")
    if [[ "$start" == "0" ]] || [[ "$end" == "0" ]]; then
        echo "0"
    else
        elapsed=$(( (end - start) / 1000000 ))
        echo "$elapsed"
    fi
}

echo "=== Hook Validation: $PROJECT_NAME ==="
echo "Project: $PROJECT_DIR"
echo "Expected slug: ${EXPECTED_SLUG:-<auto>}"
echo ""

# Ensure we're in the project dir for hooks that use relative paths
cd "$PROJECT_DIR"
```

- [ ] **Step 2: Add the session-start hook test**

Append to `tests/hook-validation.sh`:

```bash
# --- Test: session-start.sh ---
echo "--- session-start.sh ---"

SS_HOOK="$HOOKS_DIR/session-start.sh"
if [[ ! -f "$SS_HOOK" ]]; then
    fail "session-start.sh not found at $SS_HOOK"
else
    # Capture output and timing
    SS_OUTPUT=""
    SS_STDERR=""
    SS_START=$(date +%s%N 2>/dev/null || echo "0")
    SS_OUTPUT=$(echo '{}' | bash "$SS_HOOK" 2>"$RESULTS_DIR/.ss-stderr-tmp" || true)
    SS_END=$(date +%s%N 2>/dev/null || echo "0")
    SS_STDERR=$(cat "$RESULTS_DIR/.ss-stderr-tmp" 2>/dev/null || true)
    rm -f "$RESULTS_DIR/.ss-stderr-tmp"

    # Timing
    if [[ "$SS_START" != "0" ]] && [[ "$SS_END" != "0" ]]; then
        SS_MS=$(( (SS_END - SS_START) / 1000000 ))
    else
        SS_MS=0
    fi

    # Check: valid JSON
    if echo "$SS_OUTPUT" | jq empty 2>/dev/null; then
        pass "Valid JSON output"
    else
        fail "Output is not valid JSON: $(echo "$SS_OUTPUT" | head -c 200)"
    fi

    # Check: systemMessage key exists
    SS_MSG=$(echo "$SS_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)
    if [[ -n "$SS_MSG" ]]; then
        pass "systemMessage key present"
    else
        fail "systemMessage key missing from output"
    fi

    # Check: slug detection (extract from systemMessage)
    SS_DETECTED_SLUG=$(echo "$SS_MSG" | grep -oP 'Project slug: `\K[^`]+' || true)
    if [[ -n "$SS_DETECTED_SLUG" ]]; then
        pass "Slug detected: $SS_DETECTED_SLUG"
        if [[ -n "$EXPECTED_SLUG" ]] && [[ "$SS_DETECTED_SLUG" != "$EXPECTED_SLUG" ]]; then
            fail "Slug mismatch: got '$SS_DETECTED_SLUG', expected '$EXPECTED_SLUG'"
        fi
    else
        fail "Could not extract slug from systemMessage"
    fi

    # Check: no errors on stderr
    if [[ -z "$SS_STDERR" ]]; then
        pass "No stderr output"
    else
        fail "Stderr: $(echo "$SS_STDERR" | head -c 200)"
    fi

    # Metrics
    SS_CHARS=${#SS_MSG}
    echo "  Metrics: ${SS_CHARS} chars, ${SS_MS}ms"
fi
echo ""
```

- [ ] **Step 3: Run the script against this repo to verify it works so far**

```bash
cd /c/Users/user/Documents/Projects/agent-memory-cc-v2-files
bash tests/hook-validation.sh "$(pwd)" memory-architecture
```

Expected: session-start tests run, PASS/FAIL printed, metrics shown. Some tests may fail if Obsidian CLI isn't running — that's fine, it tests graceful degradation.

- [ ] **Step 4: Commit**

```bash
git add tests/hook-validation.sh
git commit -m "feat: add hook-validation script with session-start tests"
```

---

### Task 3: Add pre-compact and stop hook tests

**Files:**
- Modify: `tests/hook-validation.sh`

- [ ] **Step 1: Add the pre-compact hook test**

Append to `tests/hook-validation.sh` (before any summary section):

```bash
# --- Test: pre-compact.sh ---
echo "--- pre-compact.sh ---"

PC_HOOK="$HOOKS_DIR/pre-compact.sh"
if [[ ! -f "$PC_HOOK" ]]; then
    fail "pre-compact.sh not found at $PC_HOOK"
else
    # Need a state file for pre-compact to work with
    STAGING_SLUG="${SS_DETECTED_SLUG:-$PROJECT_NAME}"
    PC_STAGING="$HOME/.claude/memory-staging/$STAGING_SLUG"

    PC_START=$(date +%s%N 2>/dev/null || echo "0")
    PC_OUTPUT=$(echo '{}' | bash "$PC_HOOK" 2>"$RESULTS_DIR/.pc-stderr-tmp" || true)
    PC_END=$(date +%s%N 2>/dev/null || echo "0")
    PC_STDERR=$(cat "$RESULTS_DIR/.pc-stderr-tmp" 2>/dev/null || true)
    rm -f "$RESULTS_DIR/.pc-stderr-tmp"

    # Timing
    if [[ "$PC_START" != "0" ]] && [[ "$PC_END" != "0" ]]; then
        PC_MS=$(( (PC_END - PC_START) / 1000000 ))
    else
        PC_MS=0
    fi

    # Check: valid JSON output
    if echo "$PC_OUTPUT" | jq empty 2>/dev/null; then
        pass "Valid JSON output"
    else
        fail "Output is not valid JSON: $(echo "$PC_OUTPUT" | head -c 200)"
    fi

    # Check: checkpoint stub created
    LATEST_CP=$(find "$PC_STAGING" -name 'checkpoint-*.md' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
    if [[ -n "$LATEST_CP" ]] && [[ -f "$LATEST_CP" ]]; then
        pass "Checkpoint stub created: $(basename "$LATEST_CP")"
        # Check frontmatter
        if head -1 "$LATEST_CP" | grep -q '^---'; then
            pass "Checkpoint has YAML frontmatter"
        else
            fail "Checkpoint missing YAML frontmatter"
        fi
        CP_SIZE=$(wc -c < "$LATEST_CP")
    else
        fail "No checkpoint stub found in $PC_STAGING"
        CP_SIZE=0
    fi

    # Check: no stderr
    if [[ -z "$PC_STDERR" ]]; then
        pass "No stderr output"
    else
        fail "Stderr: $(echo "$PC_STDERR" | head -c 200)"
    fi

    echo "  Metrics: stub ${CP_SIZE} bytes, ${PC_MS}ms"
fi
echo ""
```

- [ ] **Step 2: Add the stop hook test**

Append to `tests/hook-validation.sh`:

```bash
# --- Test: stop-memory.sh ---
echo "--- stop-memory.sh ---"

STOP_HOOK="$HOOKS_DIR/stop-memory.sh"
if [[ ! -f "$STOP_HOOK" ]]; then
    fail "stop-memory.sh not found at $STOP_HOOK"
else
    # Read current count before test
    STAGING_SLUG="${SS_DETECTED_SLUG:-$PROJECT_NAME}"
    STOP_STAGING="$HOME/.claude/memory-staging/$STAGING_SLUG"
    META_FILE="$STOP_STAGING/.session-meta"
    COUNT_BEFORE=0
    if [[ -f "$META_FILE" ]]; then
        COUNT_BEFORE=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$META_FILE" 2>/dev/null | head -1 || true)
        COUNT_BEFORE="${COUNT_BEFORE:-0}"
    fi

    STOP_START=$(date +%s%N 2>/dev/null || echo "0")
    STOP_OUTPUT=$(echo '{}' | bash "$STOP_HOOK" 2>"$RESULTS_DIR/.stop-stderr-tmp" || true)
    STOP_END=$(date +%s%N 2>/dev/null || echo "0")
    STOP_STDERR=$(cat "$RESULTS_DIR/.stop-stderr-tmp" 2>/dev/null || true)
    rm -f "$RESULTS_DIR/.stop-stderr-tmp"

    # Timing
    if [[ "$STOP_START" != "0" ]] && [[ "$STOP_END" != "0" ]]; then
        STOP_MS=$(( (STOP_END - STOP_START) / 1000000 ))
    else
        STOP_MS=0
    fi

    # Check: counter incremented
    COUNT_AFTER=0
    if [[ -f "$META_FILE" ]]; then
        COUNT_AFTER=$(sed -n 's/.*message_count=\([0-9]*\).*/\1/p' "$META_FILE" 2>/dev/null | head -1 || true)
        COUNT_AFTER="${COUNT_AFTER:-0}"
    fi
    if [[ "$COUNT_AFTER" -gt "$COUNT_BEFORE" ]]; then
        pass "Counter incremented: $COUNT_BEFORE -> $COUNT_AFTER"
    else
        fail "Counter did not increment: before=$COUNT_BEFORE, after=$COUNT_AFTER"
    fi

    # Check: under 50ms target
    if [[ "$STOP_MS" -le 50 ]]; then
        pass "Execution time ${STOP_MS}ms (target: <50ms)"
    else
        fail "Execution time ${STOP_MS}ms exceeds 50ms target"
    fi

    # Check: output is valid JSON if present (stop hook only outputs on nudge)
    if [[ -n "$STOP_OUTPUT" ]]; then
        if echo "$STOP_OUTPUT" | jq empty 2>/dev/null; then
            pass "Nudge output is valid JSON"
        else
            fail "Nudge output is not valid JSON"
        fi
    else
        pass "No nudge output (expected for low message count)"
    fi

    echo "  Metrics: ${STOP_MS}ms"
fi
echo ""
```

- [ ] **Step 3: Run against this repo**

```bash
cd /c/Users/user/Documents/Projects/agent-memory-cc-v2-files
bash tests/hook-validation.sh "$(pwd)" memory-architecture
```

Expected: All three hook sections run. Verify PASS/FAIL output for each.

- [ ] **Step 4: Commit**

```bash
git add tests/hook-validation.sh
git commit -m "feat: add pre-compact and stop hook tests"
```

---

### Task 4: Add results output and summary

**Files:**
- Modify: `tests/hook-validation.sh`

- [ ] **Step 1: Add the results table output and summary**

Append to the end of `tests/hook-validation.sh`:

```bash
# --- Summary ---
TOTAL=$((PASS_COUNT + FAIL_COUNT))
OVERALL="PASS"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    OVERALL="FAIL"
fi

echo "=== Summary: $PASS_COUNT/$TOTAL passed — $OVERALL ==="
echo ""

# --- Append to results file ---
mkdir -p "$RESULTS_DIR"

# Write header if file doesn't exist
if [[ ! -f "$RESULTS_FILE" ]]; then
    cat > "$RESULTS_FILE" << 'EOF'
# Baseline Results

## Tier 1 — Hook Validation

| Project | Slug | SS chars | SS ms | PC stub bytes | PC ms | Stop ms | Result |
|---------|------|----------|-------|---------------|-------|---------|--------|
EOF
fi

# Append row
SS_CHARS="${SS_CHARS:-0}"
SS_MS="${SS_MS:-0}"
CP_SIZE="${CP_SIZE:-0}"
PC_MS="${PC_MS:-0}"
STOP_MS="${STOP_MS:-0}"

echo "| $PROJECT_NAME | ${SS_DETECTED_SLUG:-unknown} | $SS_CHARS | $SS_MS | $CP_SIZE | $PC_MS | $STOP_MS | $OVERALL |" >> "$RESULTS_FILE"

echo "Results appended to: $RESULTS_FILE"

# Exit with failure code if any test failed
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
```

- [ ] **Step 2: Run against this repo and verify results file**

```bash
cd /c/Users/user/Documents/Projects/agent-memory-cc-v2-files
bash tests/hook-validation.sh "$(pwd)" memory-architecture
cat tests/results/baseline-$(date +%Y-%m-%d).md
```

Expected: Results file created with header and one data row.

- [ ] **Step 3: Run against a second project to verify append behaviour**

```bash
bash tests/hook-validation.sh /c/Users/user/Documents/Projects/<another-project>
cat tests/results/baseline-$(date +%Y-%m-%d).md
```

Expected: Same file now has two data rows.

- [ ] **Step 4: Commit**

```bash
git add tests/hook-validation.sh
git commit -m "feat: add results output and summary to hook validation"
```

---

### Task 5: Write the session playbook

**Files:**
- Create: `tests/playbook.md`

- [ ] **Step 1: Write the playbook**

Create `tests/playbook.md`:

```markdown
# Session Testing Playbook

Manual protocol for Tier 2 (session baseline) and Tier 3 (full lifecycle) testing.
Run Tier 1 (`bash tests/hook-validation.sh`) first.

## Prerequisites

- Obsidian 1.12+ running with CLI enabled
- `obsidian version` works from Claude Code's bash shell
- Hooks installed and registered (`/hooks` shows session-start, pre-compact, stop)
- At least one prior session note in vault for the project (for memberberry to find)

## Tier 2 — Session Baseline (~3 min per project)

Run this on each project to measure the context cost of the v3 memory system.

### Steps

1. Open a **fresh** Claude Code session in the project directory
2. **Before typing anything**, note the context % shown in the status bar
   - Record as `Post-SessionStart %`
3. Send exactly: **"What did we work on last session?"**
   - This triggers memberberry retrieval
4. After memberberry responds, note the context % again
   - Record as `Post-Memberberry %`
5. Assess memberberry quality:
   - **yes** — returned what you'd need to pick up where you left off
   - **partial** — got some of it, missed something you'd expect
   - **no** — useless or wrong
6. Record results in the table below

### Results Table

Copy this table into your baseline results file (`tests/results/baseline-YYYY-MM-DD.md`):

```
## Tier 2 — Session Baseline

| Project | Post-SessionStart % | Post-Memberberry % | Memberberry Quality | Notes |
|---------|--------------------|--------------------|---------------------|-------|
|         |                    |                    |                     |       |
```

## Tier 3 — Full Lifecycle (~10 min, only when needed)

Run after changes to subagents, slash commands, or `pre-compact.sh`. Also before merging to main.

### When to Run

- After modifying `memberberry.md`, `blackbox.md`, or any slash command
- After changing `pre-compact.sh`
- Before merging to main

### Steps (after completing Tier 2)

1. Do some real work in the session (any small task — doesn't matter what)
2. Trigger context compaction (naturally or via `/clear` as proxy)
3. Check: did blackbox capture a checkpoint?
   - Look in `~/.claude/memory-staging/<slug>/` for `checkpoint-*.md`
   - Or check vault: `obsidian search query="checkpoint" path="5 Agent Memory/working"`
4. Note context % after compaction → `Post-Compact %`
5. Send exactly: **"What were we just working on?"**
   - Tests checkpoint recovery
6. Assess resume quality:
   - **yes** — session resumed coherently, knew what was happening
   - **partial** — got some context but missed key details
   - **no** — lost or confused
7. Run `/memory-sync`
8. Verify:
   - Session note written to vault? (`obsidian search query="type: session" path="5 Agent Memory/sessions/by-project/<slug>"`)
   - Staging files cleaned up? (`ls ~/.claude/memory-staging/<slug>/`)
9. Record results

### Results Table

Append to your baseline results file:

```
## Tier 3 — Full Lifecycle

| Project | Blackbox Captured | Post-Compact % | Resume Quality | Sync Clean | Notes |
|---------|-------------------|----------------|----------------|------------|-------|
|         |                   |                |                |            |       |
```

## When to Run Each Tier

| Trigger                        | Tier 1 | Tier 2 | Tier 3 |
|--------------------------------|--------|--------|--------|
| Any hook script change         | Yes    | No     | No     |
| Subagent definition change     | Yes    | Yes    | Yes    |
| Slash command change           | Yes    | No     | Yes    |
| Before merge to main           | Yes    | Yes    | Yes    |
| Routine baseline check         | Yes    | Yes    | No     |
```

- [ ] **Step 2: Review the playbook reads clearly**

Read through `tests/playbook.md` and verify the steps are unambiguous and the tables are correctly formatted.

- [ ] **Step 3: Commit**

```bash
git add tests/playbook.md
git commit -m "docs: add session testing playbook for Tier 2 and Tier 3"
```

---

### Task 6: Verify end-to-end by running Tier 1 on this project

**Files:**
- None created/modified — validation only

- [ ] **Step 1: Run hook-validation.sh on this repo**

```bash
cd /c/Users/user/Documents/Projects/agent-memory-cc-v2-files
bash tests/hook-validation.sh "$(pwd)" memory-architecture
```

Review output. Fix any script bugs found.

- [ ] **Step 2: Check the results file**

```bash
cat tests/results/baseline-$(date +%Y-%m-%d).md
```

Verify: header present, one row with data, no formatting issues.

- [ ] **Step 3: Check the error log (if any failures)**

```bash
cat tests/results/errors-$(date +%Y-%m-%d).log 2>/dev/null || echo "No errors logged"
```

- [ ] **Step 4: Fix any issues found, re-run, commit fixes if needed**

```bash
git add tests/hook-validation.sh
git commit -m "fix: address issues found in Tier 1 validation run"
```

Only commit if changes were needed.

---

### Task 7: Final commit — update docs

**Files:**
- Modify: `CLAUDE.md` (root)

- [ ] **Step 1: Add testing section to root CLAUDE.md**

Add after the `## Conventions` section in the root `CLAUDE.md`:

```markdown
## Testing

Semi-automated test suite in `tests/`:
- **Tier 1 (scripted):** `bash tests/hook-validation.sh /path/to/project [expected-slug]` — validates hook outputs and captures metrics
- **Tier 2-3 (manual):** Follow `tests/playbook.md` for session-level testing
- **Results:** `tests/results/baseline-YYYY-MM-DD.md` (gitignored)

See `docs/superpowers/specs/2026-04-01-e2e-testing-design.md` for the full design.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: add testing section to CLAUDE.md"
```
