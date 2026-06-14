#!/usr/bin/env bash
# hook-validation.sh — Tier 1: Validate hook outputs and capture metrics
# Usage: bash tests/hook-validation.sh /path/to/project [expected-slug]

set -euo pipefail

# --- Args ---
PROJECT_DIR="${1:?Usage: hook-validation.sh /path/to/project [expected-slug]}"
EXPECTED_SLUG="${2:-}"
# Defaults to the deployed hooks; override (HOOKS_DIR=./hooks) to test repo hooks
# before deploying them to ~/.claude/hooks.
HOOKS_DIR="${HOOKS_DIR:-$HOME/.claude/hooks}"
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

# Timing budgets are advisory (finding 7): a Git Bash spawn floor makes the
# tightest targets unreachable. warn() reports without counting as a failure;
# only a >2x regression against the recorded baseline FAILs (see summary).
warn() {
    echo "  WARN: $1"
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

# --- Test: session-start.sh ---
echo "--- session-start.sh ---"

SS_HOOK="$HOOKS_DIR/session-start.sh"
if [[ ! -f "$SS_HOOK" ]]; then
    fail "session-start.sh not found at $SS_HOOK"
else
    # Determine CLI availability up front (decides whether the cold-timing
    # budget check applies, or is skipped).
    OBS_BIN="${OBSIDIAN_CLI_PATH:-obsidian}"
    if "$OBS_BIN" version >/dev/null 2>&1; then
        CLI_AVAIL=1
    else
        CLI_AVAIL=0
    fi

    # Clear the vault cache so run 1 measures the cold path. Cache is keyed by
    # slug+branch (.vault-cache-<branch>.txt), so glob all of them.
    if [[ -n "$EXPECTED_SLUG" ]]; then
        rm -f "$HOME/.claude/memory-staging/$EXPECTED_SLUG/.vault-cache-"*.txt 2>/dev/null || true
    fi

    # Cold run (cache cleared)
    SS_START=$(date +%s%N 2>/dev/null || echo "0")
    SS_OUTPUT=$(echo '{}' | bash "$SS_HOOK" 2>"$RESULTS_DIR/.ss-stderr-tmp" || true)
    SS_END=$(date +%s%N 2>/dev/null || echo "0")
    SS_STDERR=$(cat "$RESULTS_DIR/.ss-stderr-tmp" 2>/dev/null || true)
    rm -f "$RESULTS_DIR/.ss-stderr-tmp"
    if [[ "$SS_START" != "0" ]] && [[ "$SS_END" != "0" ]]; then
        SS_COLD_MS=$(( (SS_END - SS_START) / 1000000 ))
    else
        SS_COLD_MS=0
    fi

    # Warm run (cache now primed by the cold run)
    SS_W_START=$(date +%s%N 2>/dev/null || echo "0")
    echo '{}' | bash "$SS_HOOK" >/dev/null 2>&1 || true
    SS_W_END=$(date +%s%N 2>/dev/null || echo "0")
    if [[ "$SS_W_START" != "0" ]] && [[ "$SS_W_END" != "0" ]]; then
        SS_WARM_MS=$(( (SS_W_END - SS_W_START) / 1000000 ))
    else
        SS_WARM_MS=0
    fi

    # Check: valid JSON (cold output)
    if echo "$SS_OUTPUT" | jq empty 2>/dev/null; then
        pass "Valid JSON output"
    else
        fail "Output is not valid JSON: $(echo "$SS_OUTPUT" | head -c 200)"
    fi

    # Check: hookSpecificOutput.additionalContext key exists
    SS_MSG=$(echo "$SS_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if [[ -n "$SS_MSG" ]]; then
        pass "hookSpecificOutput.additionalContext present"
    else
        fail "hookSpecificOutput.additionalContext missing from output"
    fi

    # Check: slug detection (extract from additionalContext)
    SS_DETECTED_SLUG=$(echo "$SS_MSG" | grep -o 'Project: `[^`]*`' | head -1 | sed 's/Project: `//;s/`.*//' || true)
    if [[ -n "$SS_DETECTED_SLUG" ]]; then
        pass "Slug detected: $SS_DETECTED_SLUG"
        if [[ -n "$EXPECTED_SLUG" ]] && [[ "$SS_DETECTED_SLUG" != "$EXPECTED_SLUG" ]]; then
            fail "Slug mismatch: got '$SS_DETECTED_SLUG', expected '$EXPECTED_SLUG'"
        fi
    else
        fail "Could not extract slug from additionalContext"
    fi

    # Check: no errors on stderr (cold run)
    if [[ -z "$SS_STDERR" ]]; then
        pass "No stderr output"
    else
        fail "Stderr: $(echo "$SS_STDERR" | head -c 200)"
    fi

    # Timing budgets — WARN only (finding 7); regression FAIL handled in summary.
    if [[ "$CLI_AVAIL" == "1" ]]; then
        if [[ "$SS_COLD_MS" -gt 3000 ]]; then
            warn "Cold SessionStart ${SS_COLD_MS}ms over 3000ms budget"
        else
            pass "Cold SessionStart ${SS_COLD_MS}ms within 3000ms budget"
        fi
    else
        echo "  SKIP: cold timing (Obsidian CLI unavailable)"
    fi
    if [[ "$SS_WARM_MS" -gt 300 ]]; then
        warn "Warm SessionStart ${SS_WARM_MS}ms over 300ms budget"
    else
        pass "Warm SessionStart ${SS_WARM_MS}ms within 300ms budget"
    fi

    # Metrics
    SS_CHARS=${#SS_MSG}
    echo "  Metrics: ${SS_CHARS} chars, cold ${SS_COLD_MS}ms / warm ${SS_WARM_MS}ms"
fi
echo ""

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

    # Check: stdout is empty — PreCompact is now a filesystem side-effect only.
    # The post-compaction handoff is delivered by SessionStart source=compact.
    if [[ -z "$PC_OUTPUT" ]]; then
        pass "PreCompact emits no stdout (filesystem side-effect only)"
    else
        fail "PreCompact should emit nothing on stdout, got: $(echo "$PC_OUTPUT" | head -c 200)"
    fi

    # Check: checkpoint stub created (use ls -t instead of find -printf for Windows compat)
    LATEST_CP=$(find "$PC_STAGING" -name 'checkpoint-*.md' 2>/dev/null | while read -r f; do echo "$(stat -c %Y "$f" 2>/dev/null || echo 0) $f"; done | sort -rn | head -1 | cut -d' ' -f2- || true)
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

# --- Test: session-start.sh (source=compact) ---
# Ordered after PreCompact so a checkpoint stub already exists. The compact path
# must stay slim (skip the ### Git section) and surface the ACTION REQUIRED
# handoff that points at the pending stub.
echo "--- session-start.sh (source=compact) ---"
if [[ -f "$SS_HOOK" ]]; then
    SSC_OUTPUT=$(echo '{"source":"compact"}' | bash "$SS_HOOK" 2>/dev/null || true)
    SSC_MSG=$(echo "$SSC_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if echo "$SSC_MSG" | grep -q 'post-compact'; then
        pass "Compact source: slim post-compact context emitted"
    else
        fail "Compact source: expected post-compact context, got: $(echo "$SSC_MSG" | head -c 200)"
    fi
    if echo "$SSC_MSG" | grep -q '### Git'; then
        fail "Compact source: Git section present (should be skipped)"
    else
        pass "Compact source: Git section skipped"
    fi
    if echo "$SSC_MSG" | grep -q 'ACTION REQUIRED'; then
        pass "Compact source: ACTION REQUIRED handoff present"
    else
        fail "Compact source: ACTION REQUIRED handoff missing (a checkpoint stub exists)"
    fi
fi
echo ""

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

    # Check: under 50ms target — WARN only. <=50ms is unreachable on Git Bash
    # (the empty-bash floor measured below is the real lower bound); a >2x
    # regression FAIL is enforced in the summary.
    if [[ "$STOP_MS" -le 50 ]]; then
        pass "Execution time ${STOP_MS}ms (target: <=50ms)"
    else
        warn "Execution time ${STOP_MS}ms over 50ms target (Git Bash spawn floor)"
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

    # --- Seeded nudge tests (schema + threshold behaviour) ---
    # These mutate $META_FILE, so snapshot and restore it afterwards.
    META_BACKUP=""
    if [[ -f "$META_FILE" ]]; then
        META_BACKUP=$(cat "$META_FILE")
    fi

    seed_meta() {
        # seed_meta <count> [extra-line...]
        local count="$1"; shift
        mkdir -p "$STOP_STAGING"
        {
            echo "session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "message_count=$count"
            echo "project_slug=$STAGING_SLUG"
            echo "area="
            for extra in "$@"; do echo "$extra"; done
        } > "$META_FILE"
    }

    # Seed 14 -> hook increments to 15 -> systemMessage nudge + nudge15_sent=true
    seed_meta 14
    SEED15_OUTPUT=$(echo '{}' | bash "$STOP_HOOK" 2>/dev/null || true)
    SEED15_MSG=$(echo "$SEED15_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)
    if [[ -n "$SEED15_MSG" ]]; then
        pass "Seed-15: systemMessage nudge emitted"
    else
        fail "Seed-15: expected systemMessage nudge, got: $(echo "$SEED15_OUTPUT" | head -c 200)"
    fi
    if grep -q 'nudge15_sent=true' "$META_FILE" 2>/dev/null; then
        pass "Seed-15: nudge15_sent=true recorded"
    else
        fail "Seed-15: nudge15_sent flag not recorded in meta"
    fi

    # Missed-fire (finding 6): seed 29 with NO nudge15_sent -> hook increments to
    # 30 -> must fire the 30 nudge (elif checks 30 first) and set nudge30_sent.
    seed_meta 29
    SEED30_OUTPUT=$(echo '{}' | bash "$STOP_HOOK" 2>/dev/null || true)
    SEED30_MSG=$(echo "$SEED30_OUTPUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)
    if [[ -n "$SEED30_MSG" ]]; then
        pass "Seed-30 (missed fire): systemMessage nudge emitted"
    else
        fail "Seed-30 (missed fire): expected systemMessage nudge, got: $(echo "$SEED30_OUTPUT" | head -c 200)"
    fi
    if grep -q 'nudge30_sent=true' "$META_FILE" 2>/dev/null; then
        pass "Seed-30 (missed fire): nudge30_sent=true recorded"
    else
        fail "Seed-30 (missed fire): nudge30_sent flag not recorded in meta"
    fi

    # Restore original meta
    if [[ -n "$META_BACKUP" ]]; then
        printf '%s\n' "$META_BACKUP" > "$META_FILE"
    else
        rm -f "$META_FILE"
    fi
fi
echo ""

# --- Test: session-end.sh ---
echo "--- session-end.sh ---"

SE_HOOK="$HOOKS_DIR/session-end.sh"
SE_MS=0
if [[ ! -f "$SE_HOOK" ]]; then
    fail "session-end.sh not found at $SE_HOOK"
else
    STAGING_SLUG="${SS_DETECTED_SLUG:-$PROJECT_NAME}"
    SE_STAGING="$HOME/.claude/memory-staging/$STAGING_SLUG"
    SE_META="$SE_STAGING/.session-meta"
    SE_FLAG="$SE_STAGING/.unsynced"
    mkdir -p "$SE_STAGING"

    # Snapshot meta + any existing flag so the test leaves no residue.
    SE_META_BACKUP=""
    [[ -f "$SE_META" ]] && SE_META_BACKUP=$(cat "$SE_META")
    SE_FLAG_BACKUP=""
    [[ -f "$SE_FLAG" ]] && SE_FLAG_BACKUP=$(cat "$SE_FLAG")

    se_seed_meta() {
        # se_seed_meta <count> [extra-line...]
        local count="$1"; shift
        {
            echo "session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "message_count=$count"
            echo "project_slug=$STAGING_SLUG"
            echo "area="
            for extra in "$@"; do echo "$extra"; done
        } > "$SE_META"
    }

    # Case 1: count=12, not synced, normal end -> .unsynced with both keys.
    rm -f "$SE_FLAG"
    se_seed_meta 12
    SE_START=$(date +%s%N 2>/dev/null || echo "0")
    echo '{"reason":"other"}' | bash "$SE_HOOK" 2>/dev/null || true
    SE_END=$(date +%s%N 2>/dev/null || echo "0")
    if [[ "$SE_START" != "0" ]] && [[ "$SE_END" != "0" ]]; then
        SE_MS=$(( (SE_END - SE_START) / 1000000 ))
    fi
    if [[ -f "$SE_FLAG" ]] && grep -q '^ended=' "$SE_FLAG" && grep -q '^messages=12' "$SE_FLAG"; then
        pass "Unsynced flag written with ended + messages=12"
    else
        fail "Expected .unsynced with ended+messages=12, got: $(cat "$SE_FLAG" 2>/dev/null | head -c 200)"
    fi

    # Case 2: synced=true present -> no flag.
    rm -f "$SE_FLAG"
    se_seed_meta 12 "synced=true"
    echo '{"reason":"other"}' | bash "$SE_HOOK" 2>/dev/null || true
    if [[ ! -f "$SE_FLAG" ]]; then
        pass "Synced session leaves no unsynced flag"
    else
        fail "Synced session should not write .unsynced"
    fi

    # Case 3: reason=clear -> no flag even when long + unsynced.
    rm -f "$SE_FLAG"
    se_seed_meta 12
    echo '{"reason":"clear"}' | bash "$SE_HOOK" 2>/dev/null || true
    if [[ ! -f "$SE_FLAG" ]]; then
        pass "reason=clear skips the unsynced flag"
    else
        fail "reason=clear should not write .unsynced"
    fi

    # Case 4: below threshold (count=9) -> no flag.
    rm -f "$SE_FLAG"
    se_seed_meta 9
    echo '{"reason":"other"}' | bash "$SE_HOOK" 2>/dev/null || true
    if [[ ! -f "$SE_FLAG" ]]; then
        pass "Short session (<10 msgs) leaves no unsynced flag"
    else
        fail "Short session should not write .unsynced"
    fi

    # Timing — WARN only, budget 100ms.
    if [[ "$SE_MS" -le 100 ]]; then
        pass "SessionEnd ${SE_MS}ms within 100ms budget"
    else
        warn "SessionEnd ${SE_MS}ms over 100ms budget"
    fi

    echo "  Metrics: ${SE_MS}ms"

    # Restore meta + flag.
    rm -f "$SE_FLAG"
    [[ -n "$SE_FLAG_BACKUP" ]] && printf '%s\n' "$SE_FLAG_BACKUP" > "$SE_FLAG"
    if [[ -n "$SE_META_BACKUP" ]]; then
        printf '%s\n' "$SE_META_BACKUP" > "$SE_META"
    else
        rm -f "$SE_META"
    fi
fi
echo ""

# --- Test: prompt-corrections.sh (UserPromptSubmit) ---
echo "--- prompt-corrections.sh ---"

UPS_HOOK="$HOOKS_DIR/prompt-corrections.sh"
UPS_MS=0
if [[ ! -f "$UPS_HOOK" ]]; then
    fail "prompt-corrections.sh not found at $UPS_HOOK"
else
    STAGING_SLUG="${SS_DETECTED_SLUG:-$PROJECT_NAME}"
    UPS_STAGING="$HOME/.claude/memory-staging/$STAGING_SLUG"
    UPS_INDEX="$UPS_STAGING/.corrections-index"
    mkdir -p "$UPS_STAGING"

    # Snapshot any real index so the test leaves no residue.
    UPS_INDEX_BACKUP=""
    [[ -f "$UPS_INDEX" ]] && UPS_INDEX_BACKUP=$(cat "$UPS_INDEX")

    # Seed a known correction (title|key; key is lowercased, space-separated).
    printf '%s\n' "Widget Caching|widget caching" > "$UPS_INDEX"

    # Match: prompt mentions the key -> additionalContext surfaced.
    UPS_START=$(date +%s%N 2>/dev/null || echo "0")
    UPS_HIT=$(echo '{"prompt":"how does widget caching work here?"}' | bash "$UPS_HOOK" 2>/dev/null || true)
    UPS_END=$(date +%s%N 2>/dev/null || echo "0")
    if [[ "$UPS_START" != "0" ]] && [[ "$UPS_END" != "0" ]]; then
        UPS_MS=$(( (UPS_END - UPS_START) / 1000000 ))
    fi
    UPS_CTX=$(echo "$UPS_HIT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
    if echo "$UPS_CTX" | grep -qi 'Widget Caching'; then
        pass "Corrections hit: additionalContext surfaced for matching prompt"
    else
        fail "Corrections hit: expected additionalContext mentioning the title, got: $(echo "$UPS_HIT" | head -c 200)"
    fi

    # No match: unrelated prompt -> no output.
    UPS_MISS=$(echo '{"prompt":"what is the weather today?"}' | bash "$UPS_HOOK" 2>/dev/null || true)
    if [[ -z "$UPS_MISS" ]]; then
        pass "No match: hook emits nothing for unrelated prompt"
    else
        fail "No match: expected empty output, got: $(echo "$UPS_MISS" | head -c 200)"
    fi

    # No index: instant clean exit.
    rm -f "$UPS_INDEX"
    UPS_NONE=$(echo '{"prompt":"how does widget caching work here?"}' | bash "$UPS_HOOK" 2>/dev/null || true)
    if [[ -z "$UPS_NONE" ]]; then
        pass "No index: hook exits cleanly with no output"
    else
        fail "No index: expected empty output, got: $(echo "$UPS_NONE" | head -c 200)"
    fi

    # Timing — WARN only, budget 100ms.
    if [[ "$UPS_MS" -le 100 ]]; then
        pass "UserPromptSubmit ${UPS_MS}ms within 100ms budget"
    else
        warn "UserPromptSubmit ${UPS_MS}ms over 100ms budget"
    fi

    echo "  Metrics: ${UPS_MS}ms"

    # Restore any real index.
    if [[ -n "$UPS_INDEX_BACKUP" ]]; then
        printf '%s\n' "$UPS_INDEX_BACKUP" > "$UPS_INDEX"
    else
        rm -f "$UPS_INDEX"
    fi
fi
echo ""

# --- Test: read-once/hook.sh ---
echo "--- read-once/hook.sh ---"

RO_HOOK="$HOOKS_DIR/read-once/hook.sh"
if [[ ! -f "$RO_HOOK" ]]; then
    fail "read-once/hook.sh not found at $RO_HOOK"
else
    RO_CACHE_DIR="$HOME/.claude/read-once/cache"
    # Clean cache before: the second read must hit a cache seeded by the first.
    rm -rf "$RO_CACHE_DIR" 2>/dev/null || true

    # Synthetic PreToolUse input pointing at this script (a stable, existing
    # file). Use an absolute path so the hook's existence check resolves
    # regardless of the hook's working directory.
    RO_TARGET="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
    RO_INPUT="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$RO_TARGET\"}}"
    # Fixed session id so both reads share one cache dir
    export CLAUDE_SESSION_ID="hookval-readonce-test"

    # warn mode (default): first read primes cache, second read warns with allow
    RO_FIRST=$(echo "$RO_INPUT" | READ_ONCE_MODE=warn bash "$RO_HOOK" 2>/dev/null || true)
    RO_SECOND=$(echo "$RO_INPUT" | READ_ONCE_MODE=warn bash "$RO_HOOK" 2>/dev/null || true)
    RO_WARN_DECISION=$(echo "$RO_SECOND" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    if [[ "$RO_WARN_DECISION" == "allow" ]]; then
        pass "Read-once warn: second read -> permissionDecision allow"
    else
        fail "Read-once warn: expected allow, got '$RO_WARN_DECISION' ($(echo "$RO_SECOND" | head -c 200))"
    fi

    # deny mode: reset cache, prime, second read denies
    rm -rf "$RO_CACHE_DIR" 2>/dev/null || true
    RO_D_FIRST=$(echo "$RO_INPUT" | READ_ONCE_MODE=deny bash "$RO_HOOK" 2>/dev/null || true)
    RO_D_SECOND=$(echo "$RO_INPUT" | READ_ONCE_MODE=deny bash "$RO_HOOK" 2>/dev/null || true)
    RO_DENY_DECISION=$(echo "$RO_D_SECOND" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)
    if [[ "$RO_DENY_DECISION" == "deny" ]]; then
        pass "Read-once deny: second read -> permissionDecision deny"
    else
        fail "Read-once deny: expected deny, got '$RO_DENY_DECISION' ($(echo "$RO_D_SECOND" | head -c 200))"
    fi

    # Clean cache after and unset the test session id
    rm -rf "$RO_CACHE_DIR" 2>/dev/null || true
    unset CLAUDE_SESSION_ID
fi
echo ""

# --- Empty bash spawn floor ---
# The real lower bound for any hook on this box: an empty `bash -c exit 0`. Stop
# cannot beat this, so it is the honest reference for the <=50ms target.
echo "--- timing floor ---"
FLOOR_START=$(date +%s%N 2>/dev/null || echo "0")
bash -c 'exit 0'
FLOOR_END=$(date +%s%N 2>/dev/null || echo "0")
if [[ "$FLOOR_START" != "0" ]] && [[ "$FLOOR_END" != "0" ]]; then
    FLOOR_MS=$(( (FLOOR_END - FLOOR_START) / 1000000 ))
else
    FLOOR_MS=0
fi
echo "  Empty 'bash -c exit 0' floor: ${FLOOR_MS}ms (Stop cannot beat this)"
echo ""

# --- Timing regression guard (finding 7) ---
# Budgets are WARN-only inline; here we FAIL only on a >2x regression against the
# per-machine baseline. Delete results/.timing-baseline to re-baseline.
SS_COLD_MS="${SS_COLD_MS:-0}"
SS_WARM_MS="${SS_WARM_MS:-0}"
STOP_MS="${STOP_MS:-0}"
BASELINE_FILE="$RESULTS_DIR/.timing-baseline"
if [[ -f "$BASELINE_FILE" ]]; then
    BL_SS_COLD=$(sed -n 's/^ss_cold=\([0-9]*\).*/\1/p' "$BASELINE_FILE" | head -1); BL_SS_COLD="${BL_SS_COLD:-0}"
    BL_SS_WARM=$(sed -n 's/^ss_warm=\([0-9]*\).*/\1/p' "$BASELINE_FILE" | head -1); BL_SS_WARM="${BL_SS_WARM:-0}"
    BL_STOP=$(sed -n 's/^stop=\([0-9]*\).*/\1/p' "$BASELINE_FILE" | head -1); BL_STOP="${BL_STOP:-0}"
    if [[ "$BL_SS_COLD" -gt 0 ]] && [[ "$SS_COLD_MS" -gt $(( BL_SS_COLD * 2 )) ]]; then
        fail "SS cold regression: ${SS_COLD_MS}ms > 2x baseline (${BL_SS_COLD}ms)"
    fi
    if [[ "$BL_SS_WARM" -gt 0 ]] && [[ "$SS_WARM_MS" -gt $(( BL_SS_WARM * 2 )) ]]; then
        fail "SS warm regression: ${SS_WARM_MS}ms > 2x baseline (${BL_SS_WARM}ms)"
    fi
    if [[ "$BL_STOP" -gt 0 ]] && [[ "$STOP_MS" -gt $(( BL_STOP * 2 )) ]]; then
        fail "Stop regression: ${STOP_MS}ms > 2x baseline (${BL_STOP}ms)"
    fi
else
    {
        echo "ss_cold=$SS_COLD_MS"
        echo "ss_warm=$SS_WARM_MS"
        echo "stop=$STOP_MS"
        echo "floor=$FLOOR_MS"
        echo "# baseline recorded $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$BASELINE_FILE"
    echo "Recorded timing baseline: cold ${SS_COLD_MS}ms / warm ${SS_WARM_MS}ms / stop ${STOP_MS}ms (floor ${FLOOR_MS}ms)"
    echo ""
fi

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

| Project | Slug | SS chars | SS cold ms | SS warm ms | PC stub bytes | PC ms | Stop ms | Result |
|---------|------|----------|------------|------------|---------------|-------|---------|--------|
EOF
fi

# Append row (SS_COLD_MS / SS_WARM_MS / STOP_MS already defaulted in the
# regression-guard block above; default only the rest here)
SS_CHARS="${SS_CHARS:-0}"
CP_SIZE="${CP_SIZE:-0}"
PC_MS="${PC_MS:-0}"

echo "| $PROJECT_NAME | ${SS_DETECTED_SLUG:-unknown} | $SS_CHARS | $SS_COLD_MS | $SS_WARM_MS | $CP_SIZE | $PC_MS | $STOP_MS | $OVERALL |" >> "$RESULTS_FILE"

echo "Results appended to: $RESULTS_FILE"

# Exit with failure code if any test failed
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi
