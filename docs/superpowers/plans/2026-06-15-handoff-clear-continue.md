# Handoff → Clear → Continue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken PreCompact checkpoint-stub mechanism with a deliberate `/handoff` → `/clear` → auto-continue workflow backed by a deterministic transcript harvester.

**Architecture:** A new sourceable Bash library (`hooks/handoff-lib.sh`) harvests the current work unit from the session transcript ~90% deterministically (jq/git), windowed to entries after the last compaction boundary. `/handoff` writes a single-slot scratch file (`~/.claude/memory-staging/<slug>/handoff.md`) — deterministic skeleton + one in-context narrative fill — then the user runs `/clear`; the fresh session's `SessionStart(source=clear)` injects it and renames it `.consumed`. Bare `/clear` and auto-compaction are caught by `SessionEnd(reason=clear)` and `SessionStart(source=compact)` through the same harvest code path. `/memory-sync` consolidates the scratch into the vault and deletes it.

**Tech Stack:** Bash (`set -euo pipefail`, jq, git, awk, sed), Markdown slash commands, Claude Code hooks API, MCP-Obsidian (writes only, unchanged).

**Spec:** `docs/superpowers/specs/2026-06-15-handoff-clear-continue-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `hooks/handoff-lib.sh` | Create | Shared harvest library: window, git/file/decision/todo/token extraction, deterministic-handoff assembly, finalise. Sourced by hooks; dispatched as a CLI by the `/handoff` command. |
| `tests/handoff-lib-test.sh` | Create | Scripted unit tests for the library against fixture transcripts. |
| `tests/fixtures/transcript-windowed.jsonl` | Create | Fixture transcript with two compaction boundaries + tool_use/user/usage entries. |
| `commands/handoff.md` | Create | `/handoff` slash command (deterministic build → narrative fill → finalise → tell user to `/clear`). |
| `hooks/session-start.sh` | Modify | Replace the compact/clear fast-path: inject `handoff.md` on `clear`, harvest+inject CC summary on `compact`; remove blackbox/checkpoint surfacing. |
| `hooks/session-end.sh` | Modify | Add `reason=clear` fallback harvest when no manual handoff is armed. |
| `hooks/stop-memory.sh` | Modify | Add one off-hot-path token-read branch emitting the ~150k handoff nudge. |
| `hooks/pre-compact.sh` | Modify | Gut the empty-stub writer; keep only the read-once cache clear. |
| `commands/memory-sync.md` | Modify | Staging cleanup (drop checkpoints, add handoff lifecycle), handoff supersedes-dedup sub-step, direction-change correction capture. |
| `config/settings.json` | Modify | Add `memory.handoffTokenThreshold` default. |
| `config/global-claude-md-v2.md` | Modify | Replace the dead "~50%" blackbox trigger with the handoff workflow. |
| `docs/hooks-architecture.md`, `CLAUDE.md`, `.claude/CLAUDE.md`, `docs/setup-guide-v4.md` | Modify | Document the new command, the gutted PreCompact, and the handoff lifecycle. |
| `tests/playbook.md` | Modify | Add the four verification gates as manual test procedures. |

**Convention note for the implementer:** the existing project convention duplicates *slug detection* across hooks deliberately (each hook self-contained). This plan keeps that — every hook and the command resolves its own slug inline as today. Only the large new *harvest* logic is centralised in `handoff-lib.sh`, and every consumer sources it defensively (degrades to a no-op branch if the library is missing) so a partial manual install never crashes a hook.

---

## Task 1: Library scaffold + test harness + fixture

**Files:**
- Create: `hooks/handoff-lib.sh`
- Create: `tests/fixtures/transcript-windowed.jsonl`
- Create: `tests/handoff-lib-test.sh`

- [ ] **Step 1: Create the fixture transcript**

Create `tests/fixtures/transcript-windowed.jsonl` with exactly these lines (each line is one JSON object; the two `compactMetadata` lines are the boundaries the windower must respect — only entries after the *second* one are "current"):

```jsonl
{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/old/before-first-compact.txt"}}]}}
{"type":"system","compactMetadata":{"trigger":"manual","preTokens":120000,"postTokens":30000}}
{"type":"assistant","message":{"usage":{"input_tokens":40000,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0},"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/mid/between-compacts.txt"}}]}}
{"type":"system","compactMetadata":{"trigger":"manual","preTokens":150000,"postTokens":40000}}
{"type":"user","message":{"content":"actually let's switch to the deterministic harvester instead"}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/handoff-lib.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/src/handoff-lib.sh"}}]}}
{"type":"user","message":{"content":[{"type":"text","text":"no, the threshold should be 150k not 50%"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"ignore me — not a text message"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/src/session-start.sh"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"wire the clear branch","status":"pending"},{"content":"old finished thing","status":"completed"},{"content":"benchmark the token read","status":"in_progress"}]}}]}}
{"type":"assistant","message":{"usage":{"input_tokens":150000,"cache_read_input_tokens":2000,"cache_creation_input_tokens":3000},"content":[{"type":"text","text":"done"}]}}
{"type":"system","subtype":"post-summary"}
```

- [ ] **Step 2: Create the library scaffold**

Create `hooks/handoff-lib.sh` with the header and a sourcing guard. Functions are added in later tasks; the CLI dispatcher is added in Task 6.

```bash
#!/usr/bin/env bash
# handoff-lib.sh — shared deterministic harvest library for the handoff workflow.
# Sourced by session-start.sh / session-end.sh / stop-memory.sh, and dispatched
# as a CLI by the /handoff command. All functions are pure-ish: they take a
# transcript path or read windowed JSONL on stdin and write to stdout, so they
# are unit-testable against fixture transcripts (tests/handoff-lib-test.sh).
#
# Sourcing contract: callers `source` this file and guard every call on the
# library being present, e.g.
#   LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1; else HANDOFF_LIB=0; fi
# so a partial install degrades to a no-op rather than crashing the hook.

# (functions added in Tasks 2-6)

# ---- CLI dispatcher (added in Task 6) ----
```

- [ ] **Step 3: Create the test harness**

Create `tests/handoff-lib-test.sh`. It sources the library, defines a tiny assert helper, and will accrue one test block per function in later tasks.

```bash
#!/usr/bin/env bash
# handoff-lib-test.sh — scripted unit tests for hooks/handoff-lib.sh.
# Run: bash tests/handoff-lib-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../hooks/handoff-lib.sh"
FIX="$HERE/fixtures/transcript-windowed.jsonl"

PASS=0; FAIL=0
assert_eq() { # $1=label $2=expected $3=actual
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"; fi
}
assert_contains() { # $1=label $2=needle $3=haystack
    if [[ "$3" == *"$2"* ]]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected to contain: %q\n  in: %q\n' "$1" "$2" "$3"; fi
}
assert_not_contains() { # $1=label $2=needle $3=haystack
    if [[ "$3" != *"$2"* ]]; then PASS=$((PASS+1)); else
        FAIL=$((FAIL+1)); printf 'FAIL: %s\n  expected NOT to contain: %q\n  in: %q\n' "$1" "$2" "$3"; fi
}

# (test blocks added in Tasks 2-6)

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 4: Run the harness to confirm it executes**

Run: `bash tests/handoff-lib-test.sh`
Expected: prints `PASS=0 FAIL=0` and exits 0 (no tests yet, but sourcing the empty library succeeds).

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh tests/fixtures/transcript-windowed.jsonl
git commit -m "test: scaffold handoff-lib harvest library + fixture transcript"
```

---

## Task 2: `window_transcript`

**Files:**
- Modify: `hooks/handoff-lib.sh`
- Test: `tests/handoff-lib-test.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/handoff-lib-test.sh` before the `echo "----"` line:

```bash
# window_transcript: keeps only entries after the LAST compaction boundary
WIN="$(window_transcript "$FIX")"
assert_contains   "window keeps post-boundary edit" "/src/handoff-lib.sh" "$WIN"
assert_not_contains "window drops pre-first-compact" "/old/before-first-compact.txt" "$WIN"
assert_not_contains "window drops between-compacts"  "/mid/between-compacts.txt" "$WIN"
# A transcript with no compaction returns unchanged (use a temp file: the function
# reads its argument twice, so a /dev/stdin pipe would not survive the second read).
NC="$(mktemp)"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' > "$NC"
assert_eq "no-compaction passthrough" "$(cat "$NC")" "$(window_transcript "$NC")"
rm -f "$NC"
# Adversarial: a nested (non-top-level) "compactMetadata" key must NOT be treated
# as a boundary. grep matches it; the structural jq guard rejects it, so both lines
# survive (no real boundary => whole file).
ADV="$(mktemp)"
printf '%s\n' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}],"meta":{"compactMetadata":"just discussing it"}}}' \
  '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/after/real-edit.txt"}}]}}' > "$ADV"
ADVWIN="$(window_transcript "$ADV")"
assert_contains "adversarial: nested key is not a boundary" "/after/real-edit.txt" "$ADVWIN"
assert_contains "adversarial: keeps the nested-key line"     "just discussing it"   "$ADVWIN"
rm -f "$ADV"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: FAIL — `window_transcript: command not found` / non-zero exit.

- [ ] **Step 3: Implement `window_transcript`**

Add to `hooks/handoff-lib.sh` (in the functions section):

```bash
# Print transcript entries after the LAST compaction boundary. Boundary detection
# is STRUCTURAL: a cheap grep prefilter finds candidate lines containing the
# marker substring, then each candidate is confirmed with jq to carry a TOP-LEVEL
# compactMetadata key — so the token nested inside ordinary tool output is never
# mistaken for a boundary. grep tolerates malformed lines elsewhere in the file;
# only the few candidate lines are jq-parsed. No compaction => whole file (a fresh
# post-/clear session is already its own transcript).
window_transcript() {
    local t="$1"
    [[ -f "$t" ]] || return 0
    local last="" ln rest
    while IFS= read -r ln; do
        rest="${ln#*:}"
        if printf '%s' "$rest" | jq -e 'has("compactMetadata")' >/dev/null 2>&1; then
            last="${ln%%:*}"
        fi
    done < <(grep -n '"compactMetadata"' "$t" 2>/dev/null || true)
    if [[ -n "$last" ]]; then
        tail -n +"$((last + 1))" "$t"
    else
        cat "$t"
    fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: PASS count increases by 6, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "feat: window transcript to current work unit (structural boundary detection)"
```

---

## Task 3: `harvest_files` + `harvest_git`

**Files:**
- Modify: `hooks/handoff-lib.sh`
- Test: `tests/handoff-lib-test.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/handoff-lib-test.sh`:

```bash
# harvest_files: frequency table from Edit/Write/MultiEdit/NotebookEdit, post-window
FILES="$(window_transcript "$FIX" | harvest_files)"
assert_contains "files lists the twice-edited lib" "/src/handoff-lib.sh" "$FILES"
assert_contains "files lists session-start"        "/src/session-start.sh" "$FILES"
assert_not_contains "files excludes pre-window"     "/old/before-first-compact.txt" "$FILES"
# /src/handoff-lib.sh edited twice => count 2, must sort above the single-edit file
TOPFILE="$(printf '%s\n' "$FILES" | head -1)"
assert_contains "most-frequent file is the lib" "/src/handoff-lib.sh" "$TOPFILE"

# harvest_git: emits a Branch line when run inside this repo
GIT="$(harvest_git)"
assert_contains "git emits Branch" "Branch:" "$GIT"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: FAIL — `harvest_files: command not found`.

- [ ] **Step 3: Implement both functions**

Add to `hooks/handoff-lib.sh`:

```bash
# Frequency table of files edited this work unit. Reads windowed JSONL on stdin.
# Covers Edit/Write/MultiEdit (file_path) and NotebookEdit (notebook_path).
harvest_files() {
    jq -r 'select(.type=="assistant") | .message.content[]?
           | select(.type=="tool_use")
           | select(.name=="Edit" or .name=="Write" or .name=="MultiEdit" or .name=="NotebookEdit")
           | (.input.file_path // .input.notebook_path // empty)' 2>/dev/null \
        | sort | uniq -c | sort -rn | sed -E 's/^[[:space:]]*//'
}

# Git snapshot for the handoff: branch, dirty count, last 3 commits. Operates on
# the current working directory (the command/hook runs in the repo root).
harvest_git() {
    if ! { command -v git &>/dev/null && git rev-parse --is-inside-work-tree &>/dev/null 2>&1; }; then
        echo "Not a git repo."
        return 0
    fi
    local branch dirty
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
    echo "Branch: \`$branch\` ($dirty dirty files)"
    echo "Recent commits:"
    git log --oneline -3 2>/dev/null | sed 's/^/- /' || true
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: PASS increases by 5, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "feat: harvest touched files and git state"
```

---

## Task 4: `harvest_decisions` (polymorphic user content)

**Files:**
- Modify: `hooks/handoff-lib.sh`
- Test: `tests/handoff-lib-test.sh`

This is the spec's named risk: user-message `content` is polymorphic (bare string, `[{type:text}]`, `[{type:tool_result}]`). The extractor must read the first two and silently drop the third, with the slash-command wrapper stripped so a correction issued as a plain prompt is not missed.

- [ ] **Step 1: Write the failing test**

Add to `tests/handoff-lib-test.sh`:

```bash
# harvest_decisions: tags correction/decision language from BOTH string and
# [{type:text}] user messages; ignores tool_result-only messages.
DEC="$(window_transcript "$FIX" | harvest_decisions)"
assert_contains "decisions: string-form correction" "switch to the deterministic harvester" "$DEC"
assert_contains "decisions: array-text correction"  "threshold should be 150k" "$DEC"
assert_not_contains "decisions: drops tool_result"  "ignore me" "$DEC"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: FAIL — `harvest_decisions: command not found`.

- [ ] **Step 3: Implement `harvest_decisions`**

Add to `hooks/handoff-lib.sh`. The jq filter normalises all three content shapes to plain text lines; the pattern table mirrors `/memory-sync --dream` (corrections + decisions + preferences) so the two stay consistent.

```bash
# Tagged decisions/corrections from user messages this work unit. Reads windowed
# JSONL on stdin. Handles polymorphic content (bare string | [text] | [tool_result])
# — tool_result-only messages yield nothing. Strips a leading slash-command token
# so "/handoff actually do X" still surfaces "actually do X".
harvest_decisions() {
    jq -r 'select(.type=="user") | .message.content
           | if type=="string" then .
             elif type=="array" then (.[]
                 | if type=="string" then .
                   elif (.type=="text") then .text
                   else empty end)
             else empty end' 2>/dev/null \
        | sed -E 's#^/[a-z][a-z-]* ##' \
        | grep -iE "actually|no,|wrong|incorrect|not right|stop doing|i meant|i prefer|always use|never use|from now on|let's go with|i decided|we're using|switch to|we agreed" \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | awk 'length > 0 && length < 300' \
        | head -15
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: PASS increases by 3, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "feat: harvest tagged decisions handling polymorphic user content"
```

---

## Task 5: `harvest_todos` + `read_live_tokens`

**Files:**
- Modify: `hooks/handoff-lib.sh`
- Test: `tests/handoff-lib-test.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/handoff-lib-test.sh`:

```bash
# harvest_todos: pending/in-progress items from the LAST TodoWrite; drops completed
TODOS="$(window_transcript "$FIX" | harvest_todos)"
assert_contains "todos keeps pending"        "wire the clear branch" "$TODOS"
assert_contains "todos keeps in_progress"    "benchmark the token read" "$TODOS"
assert_not_contains "todos drops completed"  "old finished thing" "$TODOS"

# read_live_tokens: sum of the LAST usage-bearing assistant entry (150000+2000+3000)
TOK="$(read_live_tokens "$FIX")"
assert_eq "live tokens = last usage entry sum" "155000" "$TOK"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: FAIL — `harvest_todos: command not found`.

- [ ] **Step 3: Implement both functions**

Add to `hooks/handoff-lib.sh`:

```bash
# Open TODOs from the LAST TodoWrite this work unit (later arrays supersede
# earlier ones). Reads windowed JSONL on stdin. Drops completed items.
harvest_todos() {
    local last
    last=$(jq -c 'select(.type=="assistant") | .message.content[]?
                  | select(.type=="tool_use" and .name=="TodoWrite") | .input.todos' 2>/dev/null \
           | tail -1 || true)
    [[ -n "$last" ]] || return 0
    printf '%s' "$last" \
        | jq -r '.[] | select(.status != "completed") | "- [ ] " + (.content // .activeForm // "task")' 2>/dev/null || true
}

# Live context size = the LAST usage-bearing assistant entry's
# input + cache_read + cache_creation. tail -1 of a transcript is often a
# type:system line with no usage, so scan BACK (bounded to the last 100 lines —
# the last usage entry is always within a few of the tail) and take the first hit.
read_live_tokens() {
    local t="$1"
    [[ -f "$t" ]] || { echo 0; return 0; }
    local line u
    while IFS= read -r line; do
        u=$(printf '%s' "$line" | jq -r '
            (.message.usage // empty)
            | if . == "" then empty
              else ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
              end' 2>/dev/null || true)
        if [[ "$u" =~ ^[0-9]+$ ]] && [[ "$u" -gt 0 ]]; then echo "$u"; return 0; fi
    done < <(tail -n 100 "$t" | tac)
    echo 0
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: PASS increases by 4, `FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "feat: harvest open todos and read live token count"
```

---

## Task 6: Assembly (`harvest_compact_summary`, `build_deterministic_handoff`, `finalize_handoff`) + CLI dispatcher

**Files:**
- Modify: `hooks/handoff-lib.sh`
- Test: `tests/handoff-lib-test.sh`

- [ ] **Step 1: Write the failing test**

Add to `tests/handoff-lib-test.sh`:

```bash
# build_deterministic_handoff (source=handoff) writes QUOTED frontmatter + a
# marker-delimited narrative placeholder + deterministic sections.
TMPD="$(mktemp -d)"
OUT="$TMPD/handoff.md"
build_deterministic_handoff --transcript "$FIX" --slug "demo-proj" --source handoff --out "$OUT"
BODY="$(cat "$OUT")"
assert_contains "build: slug frontmatter"        'slug: "demo-proj"' "$BODY"
assert_contains "build: source frontmatter"      'source: "handoff"' "$BODY"
assert_contains "build: live_tokens stamped"     "live_tokens: 155000" "$BODY"
assert_contains "build: narrative start marker"  "<!-- HANDOFF:NARRATIVE:START -->" "$BODY"
assert_contains "build: narrative end marker"    "<!-- HANDOFF:NARRATIVE:END -->" "$BODY"
assert_contains "build: narrative fill sentinel" "<!-- HANDOFF:NARRATIVE -->" "$BODY"
assert_contains "build: files section populated" "/src/handoff-lib.sh" "$BODY"
assert_contains "build: consumed false"          "consumed: false" "$BODY"

# extract_block returns only the lines between the markers (exclusive)
assert_contains "extract_block: unfilled => sentinel" "<!-- HANDOFF:NARRATIVE -->" "$(extract_block NARRATIVE "$OUT")"

# finalize refuses to arm an unfilled handoff (sentinel still between markers)
FIN_UNFILLED="$(finalize_handoff --out "$OUT" --consumed "$TMPD/none.md"; echo "rc=$?")"
assert_contains "finalize aborts unfilled" "ABORTED" "$FIN_UNFILLED"
assert_eq "finalize aborted => file removed" "no" "$([[ -f "$OUT" ]] && echo yes || echo no)"

# A filled handoff arms, and stamps supersedes from a prior consumed file whose
# created value is double-quoted (finalize must strip quotes before re-stamping).
build_deterministic_handoff --transcript "$FIX" --slug "demo-proj" --source handoff --out "$OUT"
# simulate Claude filling the narrative (replaces the sentinel line; markers remain)
sed -i 's/<!-- HANDOFF:NARRATIVE -->/We are mid-way through wiring the clear branch; next edit session-start.sh:165./' "$OUT"
assert_contains "extract_block: filled => prose" "mid-way through wiring" "$(extract_block NARRATIVE "$OUT")"
printf -- '---\ncreated: "2026-06-14T09:00:00Z"\n---\n' > "$TMPD/consumed.md"
FIN_OK="$(finalize_handoff --out "$OUT" --consumed "$TMPD/consumed.md"; echo "rc=$?")"
assert_contains "finalize arms filled handoff" "ARMED" "$FIN_OK"
assert_contains "finalize stamps supersedes"   'supersedes: "2026-06-14T09:00:00Z"' "$(cat "$OUT")"

# Regression: a real narrative that merely MENTIONS the token (not the full
# sentinel comment) must still arm — the thin-guard matches the exact collapsed
# comment only. (| delimiter avoids the / in the replacement.)
build_deterministic_handoff --transcript "$FIX" --slug "demo-proj" --source handoff --out "$OUT"
sed -i 's|<!-- HANDOFF:NARRATIVE -->|Next, replace the HANDOFF:NARRATIVE token in session-start.sh; this narrative is long enough to pass.|' "$OUT"
FIN_MENTION="$(finalize_handoff --out "$OUT" --consumed "$TMPD/none.md"; echo "rc=$?")"
assert_contains "finalize arms narrative mentioning the token" "ARMED" "$FIN_MENTION"

# compact-fallback embeds CC's isCompactSummary instead of the fill sentinel...
OUT2="$TMPD/compact.md"
printf '%s\n' '{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued from a previous conversation about the harvester."}}' > "$TMPD/compact.jsonl"
build_deterministic_handoff --transcript "$TMPD/compact.jsonl" --slug "demo-proj" --source compact-fallback --out "$OUT2"
assert_contains "compact-fallback embeds summary" "continued from a previous conversation" "$(cat "$OUT2")"
assert_not_contains "compact-fallback has no fill sentinel" "<!-- HANDOFF:NARRATIVE -->" "$(cat "$OUT2")"

# ...and reads isCompactSummary from the alternate top-level .content shape too
OUT3="$TMPD/compact2.md"
printf '%s\n' '{"type":"user","isCompactSummary":true,"content":"Continued via the alternate content shape."}' > "$TMPD/compact2.jsonl"
build_deterministic_handoff --transcript "$TMPD/compact2.jsonl" --slug "demo-proj" --source compact-fallback --out "$OUT3"
assert_contains "compact-fallback reads .content shape" "alternate content shape" "$(cat "$OUT3")"
rm -rf "$TMPD"
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: FAIL — `build_deterministic_handoff: command not found`.

- [ ] **Step 3: Implement the assembly functions**

Add to `hooks/handoff-lib.sh`:

```bash
# Print the lines between <!-- HANDOFF:<NAME>:START --> and its matching :END
# marker (exclusive). One shared extractor so no reader depends on the
# human-readable section header. NAME is e.g. NARRATIVE or DONOTREDO.
extract_block() {
    local name="$1" file="$2"
    [[ -f "$file" ]] || return 0
    # sub(/\r$/,"") strips a trailing CR so markers match on CRLF files (a Windows
    # editor, or jq-written content, can introduce CR) regardless of which awk
    # implementation is in use.
    awk -v s="<!-- HANDOFF:${name}:START -->" -v e="<!-- HANDOFF:${name}:END -->" '
        {sub(/\r$/,"")} $0==s {f=1; next} $0==e {f=0} f' "$file"
}

# Extract CC's own compaction summary (isCompactSummary:true). Content may be a
# bare string or a [text] array, under either .message.content or a top-level
# .content (the shape has varied across versions). Capped so a huge summary
# cannot bloat the scratch.
harvest_compact_summary() {
    local t="$1"
    [[ -f "$t" ]] || return 0
    local s
    s=$(grep '"isCompactSummary"' "$t" 2>/dev/null | tail -1 \
        | jq -r '(.message.content // .content)
                 | if type=="string" then .
                   elif type=="array" then (.[] | if .type=="text" then .text else empty end)
                   else empty end' 2>/dev/null \
        | head -c 4000)
    # Guarantee exactly one trailing newline so the START/END markers always sit on
    # their own lines (head -c can truncate mid-line without one); empty => nothing.
    [[ -n "$s" ]] && printf '%s\n' "$s"
}

# Assemble the deterministic handoff scratch. For source=handoff the narrative is
# a fill sentinel Claude replaces in-context; for the fallbacks it is filled
# deterministically (CC summary / a clear note) with no LLM call. The narrative
# and do-not-redo blocks are wrapped in START/END comment markers so every reader
# extracts them via extract_block, independent of the human header.
# Args: --transcript T --slug S --source SRC --out OUT
build_deterministic_handoff() {
    local T="" SLUG="" SRC="handoff" OUT=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --transcript) T="$2"; shift 2;;
        --slug) SLUG="$2"; shift 2;;
        --source) SRC="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        *) shift;;
    esac; done
    [[ -n "$OUT" ]] || return 1
    mkdir -p "$(dirname "$OUT")"

    # Stream the window through a temp file (avoids buffering a multi-MB transcript
    # in a shell variable). Every harvest helper below is abort-safe (guarded jq /
    # || true), so build cannot die mid-way and orphan $win; the explicit rm at the
    # end is the single cleanup path.
    local win branch tokens created
    win=$(mktemp)
    window_transcript "$T" > "$win" 2>/dev/null || true
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    tokens=$(read_live_tokens "$T")
    [[ "$tokens" =~ ^[0-9]+$ ]] || tokens=0
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    {
        echo "---"
        # Quote string scalars so a branch with /, :, #, [ or leading * stays valid YAML.
        echo "slug: \"$SLUG\""
        echo "branch: \"$branch\""
        echo "created: \"$created\""
        echo "source: \"$SRC\""
        echo "live_tokens: $tokens"
        echo "consumed: false"
        echo 'supersedes: ""'
        echo "---"
        echo
        echo "# Handoff — $SLUG ($branch)"
        echo
        echo "## Current Work — Narrative"
        echo "<!-- HANDOFF:NARRATIVE:START -->"
        case "$SRC" in
            handoff)          echo "<!-- HANDOFF:NARRATIVE -->";;
            compact-fallback) harvest_compact_summary "$T";;
            *)                echo "Auto-harvested on bare /clear — no manual handoff was armed. Deterministic facts below.";;
        esac
        echo "<!-- HANDOFF:NARRATIVE:END -->"
        echo
        echo "## Do-Not-Redo"
        echo "<!-- HANDOFF:DONOTREDO:START -->"
        if [[ "$SRC" == "handoff" ]]; then echo "<!-- HANDOFF:DONOTREDO -->"; else echo "(none captured)"; fi
        echo "<!-- HANDOFF:DONOTREDO:END -->"
        echo
        echo "## Git State"
        harvest_git
        echo
        echo "## Files Touched (this work unit)"
        harvest_files < "$win" | sed 's/^/- /'
        echo
        echo "## Open TODOs"
        harvest_todos < "$win"
        echo
        echo "## Tagged Decisions / Corrections"
        harvest_decisions < "$win"
    } > "$OUT"

    rm -f "$win"
}

# Finalise a handoff: enforce the empty/thin guard for manual handoffs, stamp
# supersedes from any prior consumed file. Prints ARMED:/ABORTED:. Returns
# non-zero on abort. Args: --out OUT --consumed CONSUMED_FILE
finalize_handoff() {
    local OUT="" CONSUMED=""
    while [[ $# -gt 0 ]]; do case "$1" in
        --out) OUT="$2"; shift 2;;
        --consumed) CONSUMED="$2"; shift 2;;
        *) shift;;
    esac; done
    [[ -f "$OUT" ]] || { echo "ABORTED: no handoff file at $OUT"; return 1; }

    # source is a quoted scalar; tr strips the quotes AND any trailing CR (CRLF).
    local src; src=$(sed -n 's/^source: //p' "$OUT" | head -1 | tr -d '\r"')
    if [[ "$src" == "handoff" ]]; then
        # Refuse to arm only if the narrative is still the EXACT fill sentinel
        # (collapsed comment) or too thin — match the full collapsed comment, not a
        # bare "HANDOFF:NARRATIVE" substring, so a real narrative that merely
        # mentions the token still arms.
        local narr
        narr=$(extract_block NARRATIVE "$OUT" | tr -d '[:space:]')
        if [[ "$narr" == *"<!--HANDOFF:NARRATIVE-->"* ]] || [[ "${#narr}" -lt 40 ]]; then
            rm -f "$OUT"
            echo "ABORTED: handoff narrative not filled — not armed."
            return 1
        fi
    fi

    if [[ -n "$CONSUMED" && -f "$CONSUMED" ]]; then
        local prior; prior=$(sed -n 's/^created: //p' "$CONSUMED" | head -1 | tr -d '\r"')
        if [[ -n "$prior" ]]; then
            # Rewrite the supersedes line with awk: prior is passed as a literal
            # variable, so no sed regex/replacement metacharacters (&, /, \) in the
            # value can corrupt the output.
            awk -v p="$prior" '!d && /^supersedes:/ {print "supersedes: \"" p "\""; d=1; next} {print}' \
                "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
        fi
    fi
    echo "ARMED: $OUT"
}
```

- [ ] **Step 4: Add the CLI dispatcher**

Append to the bottom of `hooks/handoff-lib.sh` (below all functions). The `BASH_SOURCE`/`$0` guard means this runs ONLY when the file is executed (`bash handoff-lib.sh build ...`), never when sourced by a hook:

```bash
# ---- CLI dispatcher ----
# Lets the /handoff command drive the library: bash handoff-lib.sh <subcmd> [args]
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    set -euo pipefail
    cmd="${1:-}"; shift || true
    case "$cmd" in
        build)    build_deterministic_handoff "$@";;
        finalize) finalize_handoff "$@";;
        tokens)   read_live_tokens "$@";;
        *) echo "usage: handoff-lib.sh {build|finalize|tokens} ..." >&2; exit 2;;
    esac
fi
```

- [ ] **Step 5: Run to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: all earlier tests plus the new block pass, `FAIL=0`. Then confirm the dispatcher:

Run: `bash hooks/handoff-lib.sh tokens tests/fixtures/transcript-windowed.jsonl`
Expected: prints `155000`.

- [ ] **Step 6: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "feat: assemble + finalise deterministic handoff, add CLI dispatcher"
```

---

## Task 7: `/handoff` command

**Files:**
- Create: `commands/handoff.md`

The command resolves slug + transcript, calls the library to build the deterministic skeleton, fills the narrative *from in-context knowledge* (no transcript re-read), finalises, then tells the user to `/clear`.

- [ ] **Step 1: Write the command file**

Create `commands/handoff.md`:

````markdown
---
description: "Capture the current work unit into a handoff scratch file, then arm it for pickup. Run /clear afterwards to continue in a fresh session."
allowed-tools:
  - "Bash"
  - "Read"
  - "Edit"
  - "Write"
---

# /handoff

Capture where we are right now into a single-slot scratch file so a fresh session can pick it up after `/clear`. $ARGUMENTS

## Step 1: Resolve slug, transcript, and library

```bash
# Slug: CLAUDE.md metadata -> state file -> git remote -> dir name
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md 2>/dev/null | head -1)
[[ -z "$SLUG" ]] && SLUG=$(jq -r '.slug // empty' .claude/memory-state.json 2>/dev/null || true)
[[ -z "$SLUG" ]] && SLUG=$(git remote get-url origin 2>/dev/null | sed -E 's/.*[:/]([^/]+)\.git$/\1/' | sed -E 's/.*[:/]([^/]+)$/\1/' | tr '[:upper:]' '[:lower:]')
[[ -z "$SLUG" ]] && SLUG=$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
SLUG=$(printf '%s' "$SLUG" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g'); [[ -z "$SLUG" ]] && SLUG="unknown"

# Library path: plugin root if present, else manual-install location
LIB="$HOME/.claude/hooks/handoff-lib.sh"
[[ -n "${CLAUDE_PLUGIN_ROOT:-}" && -f "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-lib.sh" ]] && LIB="${CLAUDE_PLUGIN_ROOT}/hooks/handoff-lib.sh"

STAGING="$HOME/.claude/memory-staging/$SLUG"
HANDOFF="$STAGING/handoff.md"
CONSUMED="$STAGING/handoff.consumed.md"
mkdir -p "$STAGING"

# Transcript resolution. CLAUDE_SESSION_ID is NOT exported into the command's Bash
# env (confirmed), and the .transcript-path breadcrumb is shared per-slug, so it
# can point at a CONCURRENT same-repo session that wrote it more recently.
# Therefore the ambiguity guard runs FIRST as a gate: if >1 transcript was modified
# in the last 2 minutes, refuse — never let the breadcrumb (or newest-wins) silently
# pick the wrong live session. Only when unambiguous do we choose a path:
#   1. .transcript-path breadcrumb (authoritative for a single active session)
#   2. $CLAUDE_SESSION_ID-derived path (only if the env var is ever populated)
#   3. newest *.jsonl
# Claude Code encodes the projects dir from the OS-native path. On Windows git bash
# $PWD is POSIX-form (/c/Users/...), which mis-encodes (-c-Users-... vs CC's
# C--Users-...) and breaks PROJDIR — defeating both the newest-wins fallback AND the
# ambiguity gate. cygpath -w yields the native path on Windows; on macOS/Linux cygpath
# is absent and the fallback keeps $PWD, which CC already encodes directly.
ENCODED=$(printf '%s' "$(cygpath -w "$PWD" 2>/dev/null || printf '%s' "$PWD")" | sed 's#[/\\:]#-#g')
PROJDIR="$HOME/.claude/projects/$ENCODED"
TRANSCRIPT=""; AMBIGUOUS=0
RECENT=$(find "$PROJDIR" -maxdepth 1 -name '*.jsonl' -mmin -2 2>/dev/null | wc -l | tr -d ' ')
if [[ "${RECENT:-0}" -gt 1 ]]; then
    AMBIGUOUS=1
elif [[ -f "$STAGING/.transcript-path" ]] && IFS= read -r _tp < "$STAGING/.transcript-path" && [[ -f "$_tp" ]]; then
    TRANSCRIPT="$_tp"
elif [[ -n "${CLAUDE_SESSION_ID:-}" && -f "$PROJDIR/$CLAUDE_SESSION_ID.jsonl" ]]; then
    TRANSCRIPT="$PROJDIR/$CLAUDE_SESSION_ID.jsonl"
else
    TRANSCRIPT=$(ls -t "$PROJDIR"/*.jsonl 2>/dev/null | head -1 || true)
fi

echo "SLUG=$SLUG"; echo "LIB=$LIB"; echo "TRANSCRIPT=${TRANSCRIPT:-<none>}"; echo "HANDOFF=$HANDOFF"; echo "AMBIGUOUS=$AMBIGUOUS"
```

If `AMBIGUOUS=1`, two or more sessions are active in this repo and newest-wins would be unsafe — tell the user to disambiguate (close the other session, or pass the transcript path) and stop. If `TRANSCRIPT` is `<none>` for any other reason, tell the user the transcript could not be located and stop — do not write a blind handoff.

## Step 2: Build the deterministic skeleton

```bash
bash "$LIB" build --transcript "$TRANSCRIPT" --slug "$SLUG" --source handoff --out "$HANDOFF"
cat "$HANDOFF"
```

## Step 3: Fill the narrative from your in-context knowledge

You have the live conversation in context — do NOT re-read the transcript. Use the Edit tool on the handoff file to replace the two placeholders:

1. Replace `<!-- HANDOFF:NARRATIVE -->` with 3–5 sentences: what we are mid-way through **right now**, why, and the **exact next action** a fresh agent should take first — file + line + intent (e.g. "Edit `hooks/session-start.sh:165` to add the clear-injection branch").
2. Replace `<!-- HANDOFF:DONOTREDO -->` with the dead ends already ruled out this session, so the fresh agent does not repeat them. If none, write `- None.`

Keep it tight. The deterministic sections already carry git state, touched files, TODOs, and tagged corrections — the narrative is only the irreducible "what/why/next".

## Step 4: Finalise (thin-guard + supersedes)

```bash
bash "$LIB" finalize --out "$HANDOFF" --consumed "$CONSUMED"
```

If the output starts with `ABORTED`, the narrative was left unfilled — go back to Step 3 and fill it, then re-run finalise. Do not tell the user it is armed until finalise prints `ARMED`.

## Step 5: Tell the user

On `ARMED`, tell the user:

> Handoff armed at `~/.claude/memory-staging/<slug>/handoff.md`. Run **`/clear`** now — the fresh session will auto-load it. (`/clear` is a CLI keystroke; I cannot run it for you.)

Do not run `/memory-sync` — handoff and sync are deliberately separate.
````

- [ ] **Step 2: Smoke-test the deterministic half**

There is no automated test for the markdown command, but verify the library calls it uses work end-to-end against the fixture:

```bash
TMPD=$(mktemp -d)
bash hooks/handoff-lib.sh build --transcript tests/fixtures/transcript-windowed.jsonl --slug smoke --source handoff --out "$TMPD/h.md"
grep -q 'HANDOFF:NARRATIVE' "$TMPD/h.md" && echo "skeleton OK"
sed -i 's/<!-- HANDOFF:NARRATIVE -->/Mid-way through wiring the clear branch; next edit hooks\/session-start.sh:165 to add the injection./' "$TMPD/h.md"
bash hooks/handoff-lib.sh finalize --out "$TMPD/h.md" --consumed "$TMPD/none.md"
rm -rf "$TMPD"
```

Expected: prints `skeleton OK` then `ARMED: <path>`.

- [ ] **Step 3: Commit**

```bash
git add commands/handoff.md
git commit -m "feat: add /handoff command"
```

---

## Task 8: `session-start.sh` — clear branch injects the handoff

**Files:**
- Modify: `hooks/session-start.sh`

The current fast path (lines 158–176) handles `compact`/`clear` together and emits the blackbox/checkpoint instruction. This task rewrites the **clear** half; Task 9 does the **compact** half and removes the checkpoint vestiges. Both need the library, so source it first.

- [ ] **Step 1: Source the library near the top**

In `hooks/session-start.sh`, after the `OBS=...` line (line 10), add:

```bash
# Shared handoff harvest library (degrade gracefully if a partial install omits it).
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1
else
    HANDOFF_LIB=0
fi
```

- [ ] **Step 2: Capture the transcript path from stdin**

Replace the single stdin read (line 125):

```bash
SOURCE=$(cat | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
```

with a capture that also extracts `transcript_path`:

```bash
STDIN_JSON=$(cat || true)
SOURCE=$(printf '%s' "$STDIN_JSON" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
```

- [ ] **Step 2b: Persist the transcript breadcrumb after `PROJECT_DIR` is set**

`PROJECT_DIR` (the staging dir for the slug) is set at `hooks/session-start.sh:137` (`PROJECT_DIR="$STAGING_DIR/$SLUG"`). Immediately after that line, persist the transcript path so `/handoff` can resolve it without `CLAUDE_SESSION_ID` (which is not exported into the command Bash env). This runs on every source:

```bash
# Authoritative transcript breadcrumb for /handoff (CLAUDE_SESSION_ID is unset in
# the command Bash env). The Stop hook refreshes this every turn; writing it here
# covers the window before the first Stop.
if [[ -n "${TRANSCRIPT:-}" ]]; then
    mkdir -p "$PROJECT_DIR"
    printf '%s\n' "$TRANSCRIPT" > "$PROJECT_DIR/.transcript-path" 2>/dev/null || true
fi
```

- [ ] **Step 3: Replace the fast-path clear handling**

Replace the entire fast-path block (the `if [[ "$SOURCE" == "compact" ]] || [[ "$SOURCE" == "clear" ]]; then ... fi`, lines 165–176) with a `clear`-only block for now (the `compact` block is added in Task 9):

```bash
# --- Fast path: post-/clear restart ---
# /clear wipes conversation memory but keeps on-disk state. If a handoff was
# armed (manually via /handoff or by the SessionEnd clear-fallback), inject it
# and mark it consumed so a second /clear cannot re-inject stale state.
if [[ "$SOURCE" == "clear" ]]; then
    HANDOFF_FILE="$PROJECT_DIR/handoff.md"
    if [[ -f "$HANDOFF_FILE" ]]; then
        if [[ "$HANDOFF_LIB" == "1" ]]; then
            NARR=$(extract_block NARRATIVE "$HANDOFF_FILE")
            CONTEXT="## RESUMING FROM HANDOFF — \`$SLUG\`\\n"
            CONTEXT+="A handoff scratch from the prior session is being restored. Full file: \`$HANDOFF_FILE\`\\n\\n"
            CONTEXT+="$(printf '%s' "$NARR" | sed 's/$/\\n/' | tr -d '\n')\\n"
            CONTEXT+="\\n(Full git state, touched files, open TODOs and tagged corrections are in the file above.)\\n"
            CONTEXT+="\\n→ Continue the work. Run \`/memory-sync\` when the effort is done to consolidate into the vault.\\n"
            mv "$HANDOFF_FILE" "$PROJECT_DIR/handoff.consumed.md" 2>/dev/null || true
            emit_context_and_exit "$CONTEXT"
        fi
        # Library missing on a continuation-critical path — fail LOUD rather than
        # silently dropping the armed handoff (do not consume it).
        CONTEXT="## ⚠ Handoff present but harvest library missing — \`$SLUG\`\\n"
        CONTEXT+="An armed handoff exists at \`$HANDOFF_FILE\` but \`hooks/handoff-lib.sh\` is not installed, so it cannot be parsed. Install it (see docs/setup-guide-v4.md) or read the file manually before continuing.\\n"
        emit_context_and_exit "$CONTEXT"
    fi
    # No armed handoff — slim restart context.
    CONTEXT="## Memory System (post-clear)\\n"
    CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n"
    CONTEXT+="\\n→ memberberry for prior context. No armed handoff was found.\\n"
    emit_context_and_exit "$CONTEXT"
fi
```

- [ ] **Step 4: Manually verify the clear injection**

```bash
# Arm a fake handoff (with the narrative markers extract_block needs), then
# simulate SessionStart(source=clear)
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
mkdir -p "$HOME/.claude/memory-staging/$SLUG"
printf -- '---\nslug: "%s"\nsource: "handoff"\n---\n\n## Current Work — Narrative\n<!-- HANDOFF:NARRATIVE:START -->\nResuming the handoff test; next edit foo.\n<!-- HANDOFF:NARRATIVE:END -->\n\n## Git State\nBranch: x\n' "$SLUG" > "$HOME/.claude/memory-staging/$SLUG/handoff.md"
echo '{"source":"clear","transcript_path":""}' | bash hooks/session-start.sh
ls "$HOME/.claude/memory-staging/$SLUG/"
```

Expected: JSON output whose `additionalContext` contains `RESUMING FROM HANDOFF` and `Resuming the handoff test`; the directory now shows `handoff.consumed.md` and no `handoff.md`.

- [ ] **Step 5: Confirm a second clear does not re-inject**

```bash
echo '{"source":"clear","transcript_path":""}' | bash hooks/session-start.sh | grep -q 'No armed handoff' && echo "idempotent OK"
```

Expected: prints `idempotent OK`.

- [ ] **Step 6: Commit**

```bash
git add hooks/session-start.sh
git commit -m "feat: inject armed handoff on SessionStart(clear)"
```

---

## Task 9: `session-start.sh` — compact branch + remove blackbox/checkpoint vestiges

**Files:**
- Modify: `hooks/session-start.sh`

- [ ] **Step 1: Add the compact harvest branch**

Immediately after the `clear` fast-path block from Task 8, add:

```bash
# --- Fast path: post-compaction restart ---
# Auto-compaction is a dormant safety net. If it fires, harvest CC's own summary
# into a compact-fallback handoff (deterministic, zero LLM) and inject it. No
# blackbox-fill instruction — the stub mechanism it served is retired.
if [[ "$SOURCE" == "compact" ]]; then
    if [[ "$HANDOFF_LIB" == "1" && -n "$TRANSCRIPT" ]]; then
        CF="$PROJECT_DIR/handoff.md"
        # Do not clobber an active manual handoff if one somehow exists.
        if [[ ! -f "$CF" ]]; then
            build_deterministic_handoff --transcript "$TRANSCRIPT" --slug "$SLUG" --source compact-fallback --out "$CF" 2>/dev/null || true
            # Stamp supersedes from any prior consumed handoff so /memory-sync can
            # dedup the chain (source!=handoff => the thin-guard is skipped).
            finalize_handoff --out "$CF" --consumed "$PROJECT_DIR/handoff.consumed.md" >/dev/null 2>&1 || true
        fi
        CONTEXT="## Memory System (post-compact) — \`$SLUG\`\\n"
        if [[ -f "$CF" ]]; then
            SUMM=$(extract_block NARRATIVE "$CF")
            CONTEXT+="Recovered context from the compaction summary (full file: \`$CF\`):\\n\\n"
            CONTEXT+="$(printf '%s' "$SUMM" | sed 's/$/\\n/' | tr -d '\n')\\n"
        fi
        CONTEXT+="\\n→ memberberry for prior context. Consider \`/handoff\` then \`/clear\` next time instead of compaction.\\n"
        emit_context_and_exit "$CONTEXT"
    fi
    # Library or transcript unavailable — minimal restart, surfaced loudly so a
    # missing install is visible rather than a silent no-harvest.
    CONTEXT="## Memory System (post-compact)\\n"
    if [[ "$HANDOFF_LIB" != "1" ]]; then
        CONTEXT+="⚠ \`hooks/handoff-lib.sh\` not installed — could not harvest the compaction summary. Install it (docs/setup-guide-v4.md).\\n"
    fi
    CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n"
    CONTEXT+="\\n→ memberberry for prior context.\\n"
    emit_context_and_exit "$CONTEXT"
fi
```

- [ ] **Step 2: Stop gathering/surfacing checkpoint stubs**

Replace the `PENDING_CHECKPOINTS` gathering block (lines 142–147) with a constant, since nothing writes checkpoints anymore:

```bash
# Checkpoint stubs are retired (replaced by the handoff scratch). Keep the field
# in the state file as an empty array for backward compatibility.
PENDING_CHECKPOINTS=()
```

Then replace the `CHECKPOINT_JSON` build (lines 199–209) with:

```bash
CHECKPOINT_JSON="[]"
```

And delete the full-path "Pending Checkpoints" surfacing block (lines 440–447) entirely:

```bash
# --- Pending checkpoints ---
if [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
    ...
fi
```

(Remove the whole block.)

- [ ] **Step 3: Update the delegation guidance**

Replace the delegation guidance block (lines 467–471):

```bash
# --- Delegation guidance ---
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ For checkpoint capture: delegate to **blackbox** subagent.\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"
```

with:

```bash
# --- Delegation guidance ---
CONTEXT+="### Memory Agents\\n"
CONTEXT+="→ For prior context: delegate to **memberberry** subagent.\\n"
CONTEXT+="→ To hand off before \`/clear\`: run \`/handoff\` (blackbox remains only for explicit \"save progress\").\\n"
CONTEXT+="→ Do NOT call MCP search_notes or read vault notes directly.\\n"
```

- [ ] **Step 4: Verify the compact harvest**

```bash
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
rm -f "$HOME/.claude/memory-staging/$SLUG/handoff.md"
T=$(mktemp); printf '%s\n' '{"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued from a previous conversation about the compact harvest."}}' > "$T"
echo "{\"source\":\"compact\",\"transcript_path\":\"$T\"}" | bash hooks/session-start.sh | grep -q 'continued from a previous conversation' && echo "compact harvest OK"
rm -f "$T"
```

Expected: prints `compact harvest OK`.

- [ ] **Step 5: Verify the full path still runs (startup) and no longer mentions checkpoints**

```bash
echo '{"source":"startup"}' | bash hooks/session-start.sh | grep -qi 'pending checkpoint' && echo "STILL PRESENT (bad)" || echo "checkpoints gone OK"
```

Expected: prints `checkpoints gone OK`.

- [ ] **Step 6: Commit**

```bash
git add hooks/session-start.sh
git commit -m "feat: harvest compaction summary on SessionStart(compact); retire checkpoint surfacing"
```

---

## Task 10: `session-end.sh` — bare `/clear` fallback harvest

**Files:**
- Modify: `hooks/session-end.sh`

- [ ] **Step 1: Source the library near the top**

After the `STATE_FILE=...` line (line 11) in `hooks/session-end.sh`, add:

```bash
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1
else
    HANDOFF_LIB=0
fi
```

- [ ] **Step 2: Capture stdin (reason + transcript) once**

Replace the reason read (lines 13–17):

```bash
# SessionEnd receives JSON on stdin with a `reason`
REASON=$(jq -r '.reason // empty' 2>/dev/null || true)
[[ "$REASON" == "clear" ]] && exit 0
```

with a capture that keeps the transcript and, on `clear`, runs the fallback harvest **before** exiting (slug detection below still runs because we need `$PROJECT_DIR`; restructure so the clear branch falls through to slug detection, then harvests):

```bash
# SessionEnd receives JSON on stdin: { reason, transcript_path }.
STDIN_JSON=$(cat || true)
REASON=$(printf '%s' "$STDIN_JSON" | jq -r '.reason // empty' 2>/dev/null || true)
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
```

(Remove the early `exit 0` on clear — the clear case now needs to fall through to slug detection so it can harvest a fallback handoff. The non-clear unsynced logic must still skip when `reason=clear`, handled in Step 4.)

- [ ] **Step 3: Add the clear-fallback harvest after `PROJECT_DIR`/`META_FILE` are set**

After the line `META_FILE="$PROJECT_DIR/.session-meta"` (line 38), and before the `[[ -f "$META_FILE" ]] || exit 0` guard, insert:

```bash
# Bare /clear with no armed handoff: deterministically harvest a clear-fallback
# so the thread is never silently lost. Never clobber an active manual handoff.
if [[ "$REASON" == "clear" ]]; then
    if [[ "$HANDOFF_LIB" == "1" && -n "$TRANSCRIPT" && ! -f "$PROJECT_DIR/handoff.md" ]]; then
        mkdir -p "$PROJECT_DIR"
        build_deterministic_handoff --transcript "$TRANSCRIPT" --slug "$SLUG" --source clear-fallback --out "$PROJECT_DIR/handoff.md" 2>/dev/null || true
        # Route through finalize so the supersedes chain is stamped. source is
        # clear-fallback (not handoff), so the narrative thin-guard is skipped and
        # the deterministic-only fallback always arms.
        finalize_handoff --out "$PROJECT_DIR/handoff.md" --consumed "$PROJECT_DIR/handoff.consumed.md" >/dev/null 2>&1 || true
    fi
    exit 0
fi
```

This makes the `clear` branch self-contained and exits before the unsynced logic (a deliberate clear is never "unsynced").

- [ ] **Step 4: Verify the clear fallback**

```bash
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
rm -f "$HOME/.claude/memory-staging/$SLUG/handoff.md"
echo "{\"reason\":\"clear\",\"transcript_path\":\"$PWD/tests/fixtures/transcript-windowed.jsonl\"}" | bash hooks/session-end.sh
test -f "$HOME/.claude/memory-staging/$SLUG/handoff.md" && grep -q 'clear-fallback' "$HOME/.claude/memory-staging/$SLUG/handoff.md" && echo "clear fallback OK"
rm -f "$HOME/.claude/memory-staging/$SLUG/handoff.md"
```

Expected: prints `clear fallback OK`.

- [ ] **Step 5: Verify a manual handoff is NOT clobbered**

```bash
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
mkdir -p "$HOME/.claude/memory-staging/$SLUG"
printf -- '---\nsource: handoff\n---\nMANUAL\n' > "$HOME/.claude/memory-staging/$SLUG/handoff.md"
echo "{\"reason\":\"clear\",\"transcript_path\":\"$PWD/tests/fixtures/transcript-windowed.jsonl\"}" | bash hooks/session-end.sh
grep -q 'MANUAL' "$HOME/.claude/memory-staging/$SLUG/handoff.md" && echo "no-clobber OK"
rm -f "$HOME/.claude/memory-staging/$SLUG/handoff.md"
```

Expected: prints `no-clobber OK`.

- [ ] **Step 6: Commit**

```bash
git add hooks/session-end.sh
git commit -m "feat: harvest clear-fallback handoff on bare /clear"
```

---

## Task 11: `stop-memory.sh` — off-hot-path token nudge

**Files:**
- Modify: `hooks/stop-memory.sh`

- [ ] **Step 1: Source the library and capture stdin transcript**

In `hooks/stop-memory.sh`, after the `STATE_FILE=...` line (line 12), add:

```bash
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$LIBDIR/handoff-lib.sh" ]]; then
    # shellcheck source=/dev/null
    source "$LIBDIR/handoff-lib.sh"; HANDOFF_LIB=1
else
    HANDOFF_LIB=0
fi
# Stop receives { transcript_path } on stdin; capture it for the token nudge.
STDIN_JSON=$(cat || true)
TRANSCRIPT=$(printf '%s' "$STDIN_JSON" | jq -r '.transcript_path // empty' 2>/dev/null || true)
```

(Reading stdin here is safe: the hot path below is unchanged; the one new `jq` runs once per Stop on a tiny payload. The expensive token scan stays gated.)

- [ ] **Step 2: Add the gated token-read branch before the nudge output**

After the `mv "$META_FILE.tmp" "$META_FILE"` block (around line 92) and before the `if [[ -n "$NUDGE" ]]` output block, insert:

```bash
# Refresh the transcript breadcrumb for /handoff every turn (tiny, unconditional —
# keeps the authoritative path current as the session grows).
if [[ -n "${TRANSCRIPT:-}" ]]; then
    printf '%s\n' "$TRANSCRIPT" > "$PROJECT_DIR/.transcript-path" 2>/dev/null || true
fi

# --- Handoff token nudge (off hot path) ---
# Cheap pre-checks gate the expensive transcript scan: skip entirely until the
# session is plausibly large (>= 8 exchanges) and only fire once. 150k tokens is
# implausible before a handful of exchanges, so the jq scan runs at most a few
# times per session, never on the common short turn.
MSG_NOW=$(sed -n 's/^message_count=\([0-9]*\).*/\1/p' "$META_FILE" | head -1); MSG_NOW="${MSG_NOW:-0}"
if [[ "$HANDOFF_LIB" == "1" ]] && [[ -n "$TRANSCRIPT" ]] \
   && [[ "$MSG_NOW" -ge 8 ]] && ! grep -q '^handoff_nudge_sent=true' "$META_FILE" 2>/dev/null; then
    # Threshold: project settings -> global settings -> 150000 default.
    THRESH=$(jq -r '.memory.handoffTokenThreshold // empty' .claude/settings.json 2>/dev/null || true)
    [[ -z "$THRESH" ]] && THRESH=$(jq -r '.memory.handoffTokenThreshold // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
    [[ "$THRESH" =~ ^[0-9]+$ ]] || THRESH=150000
    LIVE=$(read_live_tokens "$TRANSCRIPT")
    if [[ "$LIVE" =~ ^[0-9]+$ ]] && [[ "$LIVE" -ge "$THRESH" ]]; then
        # Upsert the once-per-session flag (replace if present, else append) so it
        # can never accumulate duplicate lines across runs.
        if grep -q '^handoff_nudge_sent=' "$META_FILE" 2>/dev/null; then
            sed -i 's/^handoff_nudge_sent=.*/handoff_nudge_sent=true/' "$META_FILE"
        else
            echo "handoff_nudge_sent=true" >> "$META_FILE"
        fi
        HANDOFF_MSG="~$((LIVE / 1000))k tokens — consider /handoff then /clear to continue in a fresh session."
        if [[ -n "$NUDGE" ]]; then NUDGE="$NUDGE | $HANDOFF_MSG"; else NUDGE="$HANDOFF_MSG"; fi
    fi
fi
```

- [ ] **Step 2b: Confirm the nudge emitter handles the combined message**

The existing emitter at the end builds JSON with `printf '{"systemMessage": "%s"}\n' "$NUDGE"`. The new text contains `/` and `~` only (no `"` or `\`), so it remains JSON-safe — no change needed. Leave the emitter as-is.

- [ ] **Step 3: Verify the nudge fires at threshold**

```bash
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
META="$HOME/.claude/memory-staging/$SLUG/.session-meta"
mkdir -p "$(dirname "$META")"
printf 'session_start_epoch=%s\nmessage_count=9\nproject_slug=%s\n' "$(date +%s)" "$SLUG" > "$META"
# Fixture's last usage entry sums to 155000 >= default 150000
echo "{\"transcript_path\":\"$PWD/tests/fixtures/transcript-windowed.jsonl\"}" | bash hooks/stop-memory.sh
grep -q 'handoff_nudge_sent=true' "$META" && echo "nudge fired OK"
```

Expected: stdout includes a `systemMessage` containing `/handoff then /clear`, and prints `nudge fired OK`.

- [ ] **Step 4: Verify it does NOT fire twice or below the message floor**

```bash
# Second run: already flagged => no handoff text
echo "{\"transcript_path\":\"$PWD/tests/fixtures/transcript-windowed.jsonl\"}" | bash hooks/stop-memory.sh | grep -q '/handoff then /clear' && echo "FIRED AGAIN (bad)" || echo "once-only OK"
# Reset with low message count => gated out
printf 'session_start_epoch=%s\nmessage_count=3\nproject_slug=%s\n' "$(date +%s)" "$SLUG" > "$META"
echo "{\"transcript_path\":\"$PWD/tests/fixtures/transcript-windowed.jsonl\"}" | bash hooks/stop-memory.sh | grep -q '/handoff then /clear' && echo "FIRED EARLY (bad)" || echo "floor-gate OK"
```

Expected: prints `once-only OK` then `floor-gate OK`.

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-memory.sh
git commit -m "feat: nudge /handoff near the configurable token threshold"
```

---

## Task 12: `pre-compact.sh` — gut the stub writer

**Files:**
- Modify: `hooks/pre-compact.sh`

- [ ] **Step 1: Replace the file body**

Replace the entire contents of `hooks/pre-compact.sh` with the slimmed version — it keeps only the read-once cache clear (useful, unrelated to stubs) and drops all checkpoint-stub writing and state-file mutation:

```bash
#!/usr/bin/env bash
# pre-compact.sh — PreCompact hook for memory system.
# The checkpoint-stub mechanism this hook used to drive is retired (see
# docs/superpowers/specs/2026-06-15-handoff-clear-continue-design.md). Real
# pre-/clear capture is now /handoff; auto-compaction recovery is the
# SessionStart(source=compact) harvest. This hook keeps only one side effect:
# clearing the read-once dedup cache for THIS session so a post-compaction
# re-read of source files is allowed.

set -euo pipefail

# Clear read-once cache for THIS session only — other sessions keep theirs.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    RO_SESSION=$(echo "$CLAUDE_SESSION_ID" | tr -cd 'A-Za-z0-9_-')
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi

# No stdout. Post-compaction recovery is delivered by session-start.sh
# (source=compact), which harvests CC's own summary into a handoff scratch.
exit 0
```

- [ ] **Step 2: Verify it runs clean and writes no stub**

```bash
SLUG=$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)
BEFORE=$(find "$HOME/.claude/memory-staging/$SLUG" -name 'checkpoint-*.md' 2>/dev/null | wc -l | tr -d ' ')
echo '{}' | bash hooks/pre-compact.sh; echo "exit=$?"
AFTER=$(find "$HOME/.claude/memory-staging/$SLUG" -name 'checkpoint-*.md' 2>/dev/null | wc -l | tr -d ' ')
[[ "$BEFORE" == "$AFTER" ]] && echo "no new stub OK"
```

Expected: `exit=0` and `no new stub OK`.

- [ ] **Step 3: Commit**

```bash
git add hooks/pre-compact.sh
git commit -m "refactor: gut pre-compact stub writer, keep read-once cache clear"
```

---

## Task 13: `memory-sync.md` — staging cleanup, handoff dedup, direction-change capture

**Files:**
- Modify: `commands/memory-sync.md`

- [ ] **Step 1: Rewrite Step 6 "Clean Up Staging"**

Replace the Step 6 block (lines 168–185) with handoff-aware cleanup (no more checkpoints):

````markdown
### Step 6: Clean Up Staging

Check `~/.claude/memory-staging/<slug>/` for:

1. **Handoff scratch** — after the session note is written, `handoff.md` and `handoff.consumed.md` are superseded by the vault note. Delete them.
2. **Session meta** — reset `message_count=0` for the next session.
3. **Synced flag** — record that this session has been synced and clear any stale `.unsynced` marker.

```bash
rm -f ~/.claude/memory-staging/<slug>/handoff.md ~/.claude/memory-staging/<slug>/handoff.consumed.md
META=~/.claude/memory-staging/<slug>/.session-meta
sed -i 's/message_count=[0-9]*/message_count=0/' "$META"

# Mark synced (SessionEnd reads this) and clear any stale unsynced marker. Upsert
# the flag (replace if present, else append) so repeat syncs never pile up
# duplicate synced= lines.
if grep -q '^synced=' "$META" 2>/dev/null; then
    sed -i 's/^synced=.*/synced=true/' "$META"
else
    echo "synced=true" >> "$META"
fi
rm -f ~/.claude/memory-staging/<slug>/.unsynced
```

A fresh SessionStart resets `.session-meta`, so `synced=true` applies only to the current session.
````

- [ ] **Step 2: Insert the handoff dedup sub-step before Step 4**

Add a new `### Step 3.7: Consolidate handoff chain (dedup)` immediately after Step 3.6 (after line 139):

````markdown
### Step 3.7: Consolidate Handoff Chain (Dedup)

A long effort spans several clears, each producing a handoff stamped with `supersedes` pointing at the prior one. To avoid writing N near-duplicate session notes for one effort:

1. Read the current scratch pair if present:

```bash
cat ~/.claude/memory-staging/<slug>/handoff.md 2>/dev/null
cat ~/.claude/memory-staging/<slug>/handoff.consumed.md 2>/dev/null
```

2. Extract this effort's **fingerprint**: the `## Files Touched` list plus the `## Tagged Decisions / Corrections` lines.

3. Search the vault for an existing session note from the **same effort** (overlapping file list — the same files touched across consecutive sessions signal one continuous effort):

```
search_notes(query="<2-3 distinctive file basenames from the fingerprint>", searchContent=true)
```

4. **If an overlapping recent session note exists** (same project, file-list overlap, `resumable: true`): UPDATE it in place — append new Progress/Decisions/Open Items — instead of creating a new note. Set its `status` to reflect the latest state.

5. **If none overlaps:** proceed to Step 3 normally (write a fresh session note).

This collapses redundancy by construction: each `/handoff` overwrites the prior scratch (no stacking), and consolidation matches against the vault before writing. If a `supersedes` stamp is missing, you may produce one duplicate — `--dream` backstops that later.
````

- [ ] **Step 3: Add direction-change correction capture to Step 4**

At the end of Step 4 "Pattern Detection" (after line 159), append:

````markdown
**Direction-change corrections (from the handoff scratch):** the handoff's `## Tagged Decisions / Corrections` section is non-empty only when the direction shifted this effort. For each line there that is not already in `5 Agent Memory/learnings/corrections/`:

```
search_notes(query="<key phrase from the correction>", searchContent=true)
```

If genuinely new, propose it as a correction learning (needs the user's approval, per the rules). Once approved and written, `prompt-corrections.sh` will surface it live whenever a future prompt touches that topic. A correction counts as "new" when the current handoff's corrections differ from the prior `.consumed` handoff's.
````

- [ ] **Step 4: Smoke-check the markdown is well-formed**

```bash
grep -c '^### Step' commands/memory-sync.md
grep -q 'handoff.consumed.md' commands/memory-sync.md && echo "handoff cleanup present"
grep -q 'Consolidate Handoff Chain' commands/memory-sync.md && echo "dedup step present"
```

Expected: a higher step count than before, plus both `present` lines.

- [ ] **Step 5: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: handoff-aware staging cleanup, dedup, and correction capture in memory-sync"
```

---

## Task 14: `config/settings.json` threshold + global CLAUDE.md + docs

**Files:**
- Modify: `config/settings.json`
- Modify: `config/global-claude-md-v2.md`
- Modify: `docs/hooks-architecture.md`
- Modify: `CLAUDE.md`
- Modify: `.claude/CLAUDE.md`
- Modify: `docs/setup-guide-v4.md`

- [ ] **Step 1: Add the threshold default to `config/settings.json`**

`config/settings.json` currently holds only a `"hooks"` object. Add a sibling `"memory"` key so the template documents the configurable default. Change the top of the file from:

```json
{
  "hooks": {
```

to:

```json
{
  "memory": {
    "handoffTokenThreshold": 150000
  },
  "hooks": {
```

(Leave the rest of the file unchanged. The Stop hook falls back to 150000 even if a user's merged settings omit this, so it is documentation + override point, not load-bearing.)

- [ ] **Step 2: Replace the dead ~50% trigger in `config/global-claude-md-v2.md`**

Find the global-CLAUDE.md instruction that triggers a blackbox capture at "~50%" context (search for `50%`):

```bash
grep -n '50%' config/global-claude-md-v2.md
```

Replace that sentence/bullet with the handoff workflow. The replacement text:

```markdown
- When the session grows large (the Stop hook nudges around ~150k tokens, configurable via `memory.handoffTokenThreshold`), run `/handoff` to capture the current work unit, then `/clear` and continue in a fresh session — it auto-loads the handoff. Avoid relying on compaction; it stays on only as a dormant safety net.
```

Also, if the global file references the blackbox 50% rule elsewhere (the "If context hits ~50%, delegate to blackbox" line), update it to point at `/handoff` and note blackbox is now only for explicit "save progress" asks.

- [ ] **Step 3: Update `docs/hooks-architecture.md`**

The hook table / PreCompact section describes the stub mechanism. Update:
- PreCompact row: change its purpose to "clears the read-once cache only; checkpoint stubs retired".
- Add a short section describing the handoff scratch lifecycle (written by `/handoff` or fallback harvest → injected by `SessionStart(clear)` → `.consumed` → deleted by `/memory-sync`).
- Note the new `hooks/handoff-lib.sh` shared library and that hooks source it defensively.

```bash
grep -n -i 'checkpoint\|pre-compact\|blackbox' docs/hooks-architecture.md
```

Edit each hit to match the new design (no empty stubs; compact recovery via SessionStart harvest).

- [ ] **Step 4: Update both CLAUDE.md files**

In the root `CLAUDE.md` "Hook Scripts" table, change the `pre-compact.sh` purpose to "Clear read-once cache (checkpoint stubs retired)", and add `handoff-lib.sh` to Key Files. In `.claude/CLAUDE.md`, update the "Structure" bullet that says "Three bash scripts ... (SessionStart, PreCompact, Stop)" and the commands list to include `/handoff`.

```bash
grep -n 'pre-compact\|Three bash scripts\|checkpoint' CLAUDE.md .claude/CLAUDE.md
```

- [ ] **Step 5: Update `docs/setup-guide-v4.md`**

Add `hooks/handoff-lib.sh` to the manual-copy file list (it must land in `~/.claude/hooks/` alongside the other scripts), and add `commands/handoff.md` to the slash-command copy list.

```bash
grep -n 'hooks/\|commands/' docs/setup-guide-v4.md | head -20
```

- [ ] **Step 6: Verify settings.json is valid JSON**

```bash
jq . config/settings.json > /dev/null && echo "settings.json valid"
```

Expected: prints `settings.json valid`.

- [ ] **Step 7: Commit**

```bash
git add config/settings.json config/global-claude-md-v2.md docs/hooks-architecture.md CLAUDE.md .claude/CLAUDE.md docs/setup-guide-v4.md
git commit -m "docs: document handoff workflow, threshold config, and retired stubs"
```

---

## Task 15: Verification gates in the playbook + final integration sweep

**Files:**
- Modify: `tests/playbook.md`

The spec mandates empirical verification of four items before shipping. Three are testable here; gates 3 and 4 require a live Claude Code session, so they go into the manual playbook.

- [ ] **Step 1: Add the four gates to `tests/playbook.md`**

Append a `## Handoff Workflow Verification Gates` section:

````markdown
## Handoff Workflow Verification Gates

Run before merging the handoff workflow. Gates 1–2 are scripted; 3–4 are live-session manual.

### Gate 1 — Transcript windowing (scripted)
```bash
bash tests/handoff-lib-test.sh
```
Expect `FAIL=0`. The fixture has two compaction boundaries; the window tests prove only post-last-boundary entries survive, and an adversarial case proves a nested (non-top-level) `compactMetadata` key is not mistaken for a boundary.

### Gate 2 — Stop token-read off hot path (scripted)
Build a large synthetic transcript and time the gated read:
```bash
T=$(mktemp)
for i in $(seq 1 50000); do printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}'; done > "$T"
printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":160000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"content":[]}}' >> "$T"
printf '%s\n' '{"type":"system","subtype":"tail"}' >> "$T"
time (source hooks/handoff-lib.sh; read_live_tokens "$T")
rm -f "$T"
```
Expect the printed value `160000` (back-scan finds the usage entry past the trailing system line) and a sub-second `real` time.

### Gate 3 — Post-/clear additionalContext injection (LIVE)
In a real Claude Code session: run `/handoff`, fill the narrative, `/clear`. In the fresh session, confirm Claude actually receives the `RESUMING FROM HANDOFF` context (ask it "what are you resuming?"). If it does not, set `MEMORY_HOOK_PLAINTEXT=1` and retry — confirm the plaintext fallback injects.

### Gate 4 — Transcript resolution for /handoff (LIVE)
In a real session, run `/handoff` and inspect its Step 1 output: confirm `TRANSCRIPT` resolved to a real `.jsonl` (not `<none>`) and `AMBIGUOUS=0`. `CLAUDE_SESSION_ID` is expected to be unset, so the resolver should hit the `.transcript-path` breadcrumb persisted by the Stop/SessionStart hooks. Separately, open two sessions in the same repo, let both write a turn, then run `/handoff` in one and confirm the recency guard reports `AMBIGUOUS=1` rather than guessing.
````

- [ ] **Step 2: Run the full scripted suite and the existing hook validation**

```bash
bash tests/handoff-lib-test.sh
bash tests/hook-validation.sh "$PWD" "$(sed -n 's/.*memory:project-slug=\([a-z0-9-]*\).*/\1/p' .claude/CLAUDE.md | head -1)"
```

Expected: `FAIL=0` from the lib suite; the hook-validation suite reports the session-start/stop/session-end hooks still emit valid output (no regressions from the edits).

- [ ] **Step 3: Run Gate 2 benchmark and record the timing**

Run the Gate 2 snippet from Step 1. Record the `real` time in the commit message. Expected: sub-second.

- [ ] **Step 4: Commit**

```bash
git add tests/playbook.md
git commit -m "test: document handoff verification gates; record token-read benchmark"
```

---

## Self-Review

Checked the plan against the spec with fresh eyes:

**1. Spec coverage**

| Spec element | Task |
|--------------|------|
| Handoff scratch file + frontmatter | Task 6 (build), Task 7 (command) |
| Deterministic layer (git/files/decisions/todos/compact summary) | Tasks 3–6 |
| One focused LLM narrative call | Task 7 Step 3 |
| Transcript windowing | Task 2 |
| Polymorphic user-content handling | Task 4 |
| Empty/thin guard | Task 6 (`finalize_handoff`) |
| `supersedes` stamping | Task 6 |
| `/handoff` flow (locate transcript, CLAUDE_SESSION_ID + fallback) | Task 7 Step 1 |
| `SessionStart(clear)` injection + `.consumed` rename + idempotency | Task 8 |
| `SessionStart(compact)` summary harvest, no blackbox instruction | Task 9 |
| `SessionEnd(clear)` auto-catch, no-clobber | Task 10 |
| Stop ~150k configurable nudge, off hot path, last-usage back-scan | Task 11 |
| `pre-compact.sh` gutted | Task 12 |
| `/memory-sync` dedup + direction-change capture + cleanup | Task 13 |
| `memory.handoffTokenThreshold` | Task 14 Step 1 + Task 11 |
| Dead ~50% trigger replaced | Task 14 Step 2 |
| Four verification gates | Task 15 |
| Structural compaction-boundary detection (jq) | Task 2 |
| Marker-based narrative parsing (`extract_block`) | Tasks 6, 8, 9 |
| Transcript-path breadcrumb resolution | Tasks 7, 8, 11 |
| Quoted YAML frontmatter + quote-stripping reads | Task 6 |
| Fail-loud on missing library (clear/compact) | Tasks 8, 9 |
| Stub purge | Already done 2026-06-15 (no task needed) |

No gaps found.

**2. Placeholder scan:** No "TBD"/"implement later"/"add error handling" placeholders. Every code step shows the actual code. The `<!-- HANDOFF:NARRATIVE -->` / `<!-- HANDOFF:DONOTREDO -->` tokens are intentional runtime fill sentinels (replaced by Claude), and `<!-- HANDOFF:NARRATIVE:START/END -->` are intentional extraction markers — not plan placeholders.

**3. Type/name consistency:** Function names are consistent across tasks (`window_transcript`, `harvest_files`, `harvest_git`, `harvest_decisions`, `harvest_todos`, `read_live_tokens`, `harvest_compact_summary`, `extract_block`, `build_deterministic_handoff`, `finalize_handoff`). The CLI subcommands (`build`/`finalize`/`tokens`) used in Task 7 match the dispatcher defined in Task 6. Frontmatter keys (`slug`, `branch`, `created`, `source`, `live_tokens`, `consumed`, `supersedes`) are written quoted in Task 6 and read with quote-stripping in `finalize_handoff`. The narrative/do-not-redo blocks are delimited by `<!-- HANDOFF:<NAME>:START/END -->` markers written in Task 6 and read via `extract_block` in Tasks 6, 8, 9 (no reader depends on the human header). Meta flag `handoff_nudge_sent` is upserted and read in Task 11; `synced` is upserted in Task 13. The `.transcript-path` breadcrumb is written in Tasks 8 and 11 and read in Task 7. Source values (`handoff`, `compact-fallback`, `clear-fallback`) are consistent across Tasks 6, 9, 10.

**Codex review — round 1 (2026-06-15):** 11 findings; 10 folded in, 1 (a write-temp→fsync→rename→ack protocol) rejected as over-engineering for single-user Bash tooling and recorded in the spec's Out-of-scope. Folded: structural (jq) boundary detection + adversarial fixture (was brittle substring grep); `extract_block` marker parsing (resolves the em-dash-header coupling that was previously the one open risk); `.transcript-path` breadcrumb resolution (`CLAUDE_SESSION_ID` is empirically unset in the command Bash env) with a recency guard against concurrent sessions; clear/compact fallbacks routed through `finalize_handoff` for supersedes-chaining; `harvest_compact_summary` tolerating both `.message.content` and `.content`; quoted YAML frontmatter; `.session-meta` flag upserts; and fail-loud injection when the library is missing on a continuation-critical path.

**Codex review — round 2, adversarial (2026-06-15):** 6 findings; 5 folded in, 1 (jq "gluing" multi-line array summaries) rejected after empirically confirming jq `-r` newline-separates. Folded: the transcript ambiguity guard now runs **first** as a gate (the per-slug breadcrumb could otherwise name a concurrent same-repo session that wrote it more recently); `extract_block` strips a trailing CR so markers survive CRLF (verified jq emits CRLF on Windows); the window now streams through a temp file again (round 1's in-memory variable risked OOM on large sessions) with explicit abort-safe cleanup instead of a fragile RETURN trap; the thin-guard matches the exact collapsed sentinel `<!--HANDOFF:NARRATIVE-->` (a real narrative mentioning the token no longer false-aborts) with a regression test; and `supersedes` is stamped with awk (literal variable) instead of `sed` to neutralise `&`/`/`/`\` in the value.

**No open risks outstanding.** The em-dash-header coupling is resolved by the centralised `extract_block`; both codex passes are folded or explicitly rejected with rationale.
