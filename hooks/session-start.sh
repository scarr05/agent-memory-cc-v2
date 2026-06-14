#!/usr/bin/env bash
# session-start.sh — SessionStart hook for memory system (v3)
# Uses Obsidian CLI for vault reads, directs agent to subagents
# Falls back gracefully if CLI unavailable

set -euo pipefail

STAGING_DIR="$HOME/.claude/memory-staging"
CLAUDE_MD=".claude/CLAUDE.md"
OBS="${OBSIDIAN_CLI_PATH:-obsidian}"

# --- Output emitter ---
# additionalContext is the documented injection channel for SessionStart.
# MEMORY_HOOK_PLAINTEXT=1 falls back to plain stdout (also documented) in case
# the upstream additionalContext bug (#16538) is still live for this CC version.
# Takes the context string as an explicit argument so callers cannot emit a
# half-built payload — the full path and this script's compact/clear branch
# (Task 4) both call it the same way, with their context fully assembled.
emit_context_and_exit() {
    local ctx="$1"
    if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]]; then
        echo -e "$ctx"
    else
        jq -n --arg ctx "$(echo -e "$ctx")" \
            '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": $ctx}}'
    fi
    exit 0
}

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

# SessionStart receives JSON on stdin; `source` tells us why the session began
# (startup | resume | compact | clear). Read it once, early.
SOURCE=$(cat | jq -r '.source // "startup"' 2>/dev/null || echo "startup")

_DETECTED_VIA=""
SLUG=$(detect_slug)
# Defence in depth: detect_slug does not charset-filter the state-file,
# settings.json, or git-remote branches. Clamp to the slug charset so a crafted
# slug can never traverse out of the staging dir (it becomes part of rm -rf /
# mkdir paths) or inject extra key=value args into the Obsidian CLI.
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
[[ -z "$SLUG" ]] && SLUG="unknown"
DETECTED_VIA="$_DETECTED_VIA"
AREA=$(detect_area)
PROJECT_DIR="$STAGING_DIR/$SLUG"

# Ensure staging directory exists
[[ -d "$PROJECT_DIR" ]] || mkdir -p "$PROJECT_DIR"

# Gather pending checkpoints once — both the post-compaction fast path and the
# full path's handoff section use this list.
PENDING_CHECKPOINTS=()
while IFS= read -r -d '' file; do
    PENDING_CHECKPOINTS+=("$file")
done < <(find "$PROJECT_DIR" -name 'checkpoint-*.md' -print0 2>/dev/null || true)

# Capture the prior session's meta BEFORE the full path resets it. PRIOR_COUNT
# feeds both the dream timer and the "previous session" hint further down.
PRIOR_SESSION_INFO=""
if [[ -f "$PROJECT_DIR/.session-meta" ]]; then
    PRIOR_SESSION_INFO=$(cat "$PROJECT_DIR/.session-meta")
fi
PRIOR_COUNT=$(echo "$PRIOR_SESSION_INFO" | sed -n 's/.*message_count=\([0-9]*\).*/\1/p' | head -1)
PRIOR_COUNT="${PRIOR_COUNT:-0}"

# --- Fast path: post-compaction / post-clear restart ---
# Compaction and /clear keep the original on-disk state (slug, state file, meta).
# These restarts only need slug + checkpoint handoff + delegation guidance, so
# skip git inspection, all CLI vault queries, the state-file rewrite, and the
# session-meta reset. Skipping the reset deliberately preserves the prior
# session_start_epoch and message_count, so Stop's duration/count keep spanning
# the (still logically continuous) session across the compaction.
if [[ "$SOURCE" == "compact" ]] || [[ "$SOURCE" == "clear" ]]; then
    CONTEXT="## Memory System (post-$SOURCE)\\n"
    CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n"
    if [[ "$SOURCE" == "compact" ]] && [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
        CONTEXT+="\\n**ACTION REQUIRED:** Delegate to the blackbox subagent NOW to fill in the pending checkpoint(s) with session state, then continue the interrupted work:\\n"
        for cp in "${PENDING_CHECKPOINTS[@]}"; do
            CONTEXT+="- \`$cp\`\\n"
        done
    fi
    CONTEXT+="\\n→ memberberry for prior context, blackbox for checkpoints. No direct MCP vault reads.\\n"
    emit_context_and_exit "$CONTEXT"
fi

# ===== Full path (source=startup|resume) =====

# Dream timer (moved here from the Stop hot path). Flag a consolidation if the
# last dream was >24h ago, or on first-ever use once a prior session showed real
# activity (message_count >= 5). The surfacing nudge lives further down.
NOW_EPOCH=$(date +%s)
LAST_DREAM_FILE="$PROJECT_DIR/.last-dream"
if [[ -f "$LAST_DREAM_FILE" ]]; then
    read -r LAST_DREAM < "$LAST_DREAM_FILE" || LAST_DREAM=0
    LAST_DREAM="${LAST_DREAM:-0}"
    if [[ $(( (NOW_EPOCH - LAST_DREAM) / 3600 )) -ge 24 ]]; then
        touch "$PROJECT_DIR/.dream-pending"
    fi
elif [[ "$PRIOR_COUNT" -ge 5 ]]; then
    touch "$PROJECT_DIR/.dream-pending"
fi

# --- Write persistent state file ---
STATE_FILE=".claude/memory-state.json"
mkdir -p .claude

CHECKPOINT_JSON="[]"
if [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
    CHECKPOINT_LIST=""
    for file in "${PENDING_CHECKPOINTS[@]}"; do
        if [[ -n "$CHECKPOINT_LIST" ]]; then
            CHECKPOINT_LIST="$CHECKPOINT_LIST, "
        fi
        CHECKPOINT_LIST="$CHECKPOINT_LIST\"$file\""
    done
    CHECKPOINT_JSON="[$CHECKPOINT_LIST]"
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

# Keep memory-state.json out of git status without touching tracked .gitignore
GIT_DIR_PATH=$(git rev-parse --git-dir 2>/dev/null || true)
if [[ -n "$GIT_DIR_PATH" ]]; then
    EXCLUDE_FILE="$GIT_DIR_PATH/info/exclude"
    if ! grep -q 'memory-state.json' "$EXCLUDE_FILE" 2>/dev/null; then
        echo ".claude/memory-state.json" >> "$EXCLUDE_FILE" 2>/dev/null || true
    fi
fi

# Reset session meta. session_start_epoch is the cross-hook contract the Stop
# hook reads to compute session duration without a date -d parse (Task 6).
cat > "$PROJECT_DIR/.session-meta" << EOF
session_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
session_start_epoch=$NOW_EPOCH
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
"$OBS" version > /dev/null 2>&1 || CLI_OK="false"

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

# --- CLI-driven vault state (cached + parallelised) ---
if [[ "$CLI_OK" == "true" ]]; then

    # Cache the non-safety-critical fragments per slug+branch so a warm restart
    # skips four CLI round-trips. Corrections are deliberately NOT cached — a
    # stale corrections fragment could silently drop a safety override — so they
    # always run live below. The cache holds pre-rendered context text, keyed by
    # branch so a concurrent session on another branch does not read this
    # branch's tasks/working files. $BRANCH was already resolved by the Git
    # section above; reuse it instead of spawning `git branch` again.
    BRANCH_KEY=$(echo "${BRANCH:-nobranch}" | sed 's/[^A-Za-z0-9._-]/-/g')
    CACHE_FILE="$PROJECT_DIR/.vault-cache-$BRANCH_KEY.txt"
    VAULT_FRAGMENT=""

    # Warm hit: cache younger than 15 minutes.
    if [[ -n "$(find "$CACHE_FILE" -mmin -15 2>/dev/null || true)" ]]; then
        VAULT_FRAGMENT=$(cat "$CACHE_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$VAULT_FRAGMENT" ]]; then
        # Cold path: run the four cacheable queries in parallel, each to its own
        # temp file with a completion marker, then a single bounded wait (~3s).
        # PID-scoped temp dir so two sessions on the same project don't delete
        # each other's in-flight query output.
        SS_TMP="$PROJECT_DIR/.ss-tmp.$$"
        rm -rf "$SS_TMP" 2>/dev/null || true
        mkdir -p "$SS_TMP"

        # Each job marks .ok ONLY on a zero-exit query (the .done marker fires
        # unconditionally for the watchdog). A failed query writes an empty file
        # but no .ok, so the cache write below can refuse to persist a partial.
        PIDS=()
        { "$OBS" search:context query="$SLUG" path="5 Agent Memory/project-index.md" format=json > "$SS_TMP/index" 2>/dev/null && touch "$SS_TMP/index.ok"; touch "$SS_TMP/index.done"; } &
        PIDS+=($!)
        { "$OBS" search:context query="- \[ \]" path="5 Agent Memory/sessions/by-project/$SLUG" format=json limit=5 > "$SS_TMP/tasks" 2>/dev/null && touch "$SS_TMP/tasks.ok"; touch "$SS_TMP/tasks.done"; } &
        PIDS+=($!)
        { "$OBS" search query="$SLUG" path="5 Agent Memory/working" format=json > "$SS_TMP/working" 2>/dev/null && touch "$SS_TMP/working.ok"; touch "$SS_TMP/working.done"; } &
        PIDS+=($!)
        { "$OBS" search query="type: session" path="5 Agent Memory/sessions/by-project/$SLUG" format=json > "$SS_TMP/depth" 2>/dev/null && touch "$SS_TMP/depth.ok"; touch "$SS_TMP/depth.done"; } &
        PIDS+=($!)

        # Watchdog: poll completion markers up to ~3s. Marker presence (not
        # kill -0, which sees finished-but-unreaped jobs as alive) decides done.
        VAULT_TIMEOUT=1
        for ((i = 0; i < 30; i++)); do
            if [[ -f "$SS_TMP/index.done" && -f "$SS_TMP/tasks.done" \
               && -f "$SS_TMP/working.done" && -f "$SS_TMP/depth.done" ]]; then
                VAULT_TIMEOUT=0
                break
            fi
            sleep 0.1
        done

        if [[ "$VAULT_TIMEOUT" == "1" ]]; then
            for pid in "${PIDS[@]}"; do
                kill "$pid" 2>/dev/null || true
            done
        fi
        wait 2>/dev/null || true

        if [[ "$VAULT_TIMEOUT" == "1" ]]; then
            VAULT_FRAGMENT="⚠ Vault query timed out (>3s) — minimal context. Use memberberry for detail.\\n\\n"
        else
            FRAG=""
            INDEX_ROW=$(cat "$SS_TMP/index" 2>/dev/null || echo "")
            if [[ -n "$INDEX_ROW" ]] && [[ "$INDEX_ROW" != "[]" ]]; then
                INDEX_TEXT=$(echo "$INDEX_ROW" | jq -r '.[0].matches[].text' 2>/dev/null | head -3 || true)
                if [[ -n "$INDEX_TEXT" ]]; then
                    FRAG+="### Project Status\\n$INDEX_TEXT\\n\\n"
                fi
            fi
            TASKS=$(cat "$SS_TMP/tasks" 2>/dev/null || echo "")
            if [[ -n "$TASKS" ]] && [[ "$TASKS" != "[]" ]]; then
                TASK_LINES=$(echo "$TASKS" | jq -r '.[].matches[].text' 2>/dev/null | head -5 || true)
                if [[ -n "$TASK_LINES" ]]; then
                    FRAG+="### Open Items\\n$(echo "$TASK_LINES" | sed 's/^/  /')\\n\\n"
                fi
            fi
            WORKING=$(cat "$SS_TMP/working" 2>/dev/null || echo "")
            if [[ -n "$WORKING" ]] && [[ "$WORKING" != "[]" ]]; then
                WORKING_LIST=$(echo "$WORKING" | jq -r '.[]' 2>/dev/null | head -5 | sed 's/^/- /' || true)
                if [[ -n "$WORKING_LIST" ]]; then
                    FRAG+="### Working Files\\n$WORKING_LIST\\n\\n"
                fi
            fi
            SESSION_COUNT=$(cat "$SS_TMP/depth" 2>/dev/null || echo "[]")
            COUNT=$(echo "$SESSION_COUNT" | jq 'length' 2>/dev/null || echo "0")
            FRAG+="Memory depth: $COUNT prior sessions\\n\\n"
            VAULT_FRAGMENT="$FRAG"
            # Cache only when ALL four queries succeeded. A single failed query
            # writes an empty file but still marks .done, so without this guard a
            # transient failure would poison the 15-min warm cache with a
            # confidently-wrong partial render.
            ALL_OK=1
            for q in index tasks working depth; do
                [[ -f "$SS_TMP/$q.ok" ]] || ALL_OK=0
            done
            if [[ "$ALL_OK" == "1" ]]; then
                printf '%s' "$VAULT_FRAGMENT" > "$CACHE_FILE.tmp.$$" 2>/dev/null && mv "$CACHE_FILE.tmp.$$" "$CACHE_FILE" 2>/dev/null || true
            fi
        fi
        rm -rf "$SS_TMP" 2>/dev/null || true
    fi

    CONTEXT+="$VAULT_FRAGMENT"

    # Corrections — ALWAYS live (never cached); the highest-stakes fragment.
    # The CLI returns a JSON array on match and the literal "No matches found."
    # on none (exit 0 either way), so detect via jq array length, not emptiness.
    # On a genuine query failure (neither a JSON array nor the no-match
    # sentinel) FAIL CLOSED: keep the last-known index and warn from it rather
    # than silently dropping a safety override.
    CORRECTIONS=$("$OBS" search query="$SLUG" path="5 Agent Memory/learnings/corrections" format=json 2>/dev/null || true)
    CORR_LEN=$(printf '%s' "$CORRECTIONS" | jq -r 'if type=="array" then length else -1 end' 2>/dev/null || echo -1)
    # Normalise empty/garbled jq output to -1 so an empty CLI response is treated
    # as a failure (fail closed), not as a 0-length "genuinely empty" array.
    [[ "$CORR_LEN" =~ ^-?[0-9]+$ ]] || CORR_LEN=-1
    if [[ "$CORR_LEN" -gt 0 ]]; then
        CONTEXT+="### ⚠ Corrections exist — load via memberberry before making assumptions\\n\\n"
        # Build the index in one awk pass (title|keywords per correction) rather
        # than basename+tr+sed per file. POSIX awk only. Strip |/CR from the
        # title so a crafted vault filename can't corrupt the index format the
        # UserPromptSubmit hook (Task 9) parses on |.
        printf '%s' "$CORRECTIONS" | jq -r '.[]' 2>/dev/null | awk -F/ '
            $0 == "" { next }
            { name = $NF; sub(/\.md$/, "", name); gsub(/[|\r]/, "-", name);
              key = tolower(name); gsub(/[-_]/, " ", key); print name "|" key }
        ' > "$PROJECT_DIR/.corrections-index" 2>/dev/null || true
    elif [[ "$CORR_LEN" -eq 0 ]] || printf '%s' "$CORRECTIONS" | grep -qi 'No matches found'; then
        # Genuine empty (empty array or the no-match sentinel) — clear the index.
        rm -f "$PROJECT_DIR/.corrections-index" 2>/dev/null || true
    elif [[ -s "$PROJECT_DIR/.corrections-index" ]]; then
        # Query failed (not parseable, not the sentinel) — fail closed.
        CONTEXT+="### ⚠ Corrections exist (cached — live check failed) — load via memberberry\\n\\n"
    fi

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

# Previous-session sync status. The SessionEnd hook writes .unsynced when a
# session of real length ended without /memory-sync — a deterministic signal
# that supersedes the message-count heuristic below. Fall back to the heuristic
# only when the flag is absent. /memory-sync owns removing .unsynced (PRIOR_COUNT
# was captured before the meta reset above).
if [[ -f "$PROJECT_DIR/.unsynced" ]]; then
    UNSYNCED_MSGS=$(sed -n 's/^messages=\([0-9]*\).*/\1/p' "$PROJECT_DIR/.unsynced" | head -1)
    UNSYNCED_ENDED=$(sed -n 's/^ended=\(.*\)/\1/p' "$PROJECT_DIR/.unsynced" | head -1)
    CONTEXT+="⚠ **Previous session (${UNSYNCED_MSGS:-?} msgs, ended ${UNSYNCED_ENDED:-unknown}) was never synced.** Run \`/memory-sync\`, or check the pending checkpoints above.\\n\\n"
elif [[ "$PRIOR_COUNT" -gt 10 ]]; then
    CONTEXT+="ℹ Previous session had $PRIOR_COUNT messages. Check if it was synced (\`/memory-sync --status\`).\\n\\n"
fi

# --- Delegation guidance ---
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"

# --- Output ---
emit_context_and_exit "$CONTEXT"
