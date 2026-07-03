# Memory System Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix five hook bugs/hardenings (B1, B2, B3, H1, T1) and delete the dead `harvest_tasks` pipeline (B4), per `docs/superpowers/specs/2026-07-03-review-fixes-design.md`.

**Architecture:** Six independent, small diffs to the bash hook scripts, each with regression tests in the single suite `tests/handoff-lib-test.sh`. B4 is a pure deletion (native task persistence across `/clear` supersedes it). All hooks keep `set -euo pipefail` and the silent-fallback (`|| true`) convention.

**Tech Stack:** Bash (Git Bash on Windows), jq, awk, coreutils. No new dependencies.

## Global Constraints

- Every hook script keeps `set -euo pipefail`. Suite file uses `set -uo pipefail` (no `-e`).
- Slug-detection duplication across hooks is deliberate (self-containment) — do not refactor it.
- NEVER run `tests/hook-validation.sh` against the live project — throwaway `mktemp -d` project dir only (its slug is then a harmless temp name).
- Test entrypoints for real (`bash hooks/<script>.sh` with piped stdin, throwaway `HOME`), not just sourced functions — sourced-function tests have missed entrypoint bugs on this project before (2026-06-16 vault learning).
- British English in all comments and docs. Deliberate shortcuts get a `ponytail:` comment naming the ceiling.
- Baseline before Task 1: `bash tests/handoff-lib-test.sh` → `PASS=76 FAIL=0`.
- Commit per task on branch `dev/review-fixes-2026-07`; never merge (Sam's sign-off required).
- Commit trailer (every commit):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01J62DaRcdzwmZkFct32T8gA
  ```

---

### Task 1: B4 — delete the dead `harvest_tasks` pipeline

**Files:**
- Modify: `tests/handoff-lib-test.sh` (delete lines 59–129; edit lines 292–295 and 304)
- Delete: `tests/fixtures/transcript-tasks.jsonl`
- Modify: `hooks/handoff-lib.sh` (delete lines 63–111 and the Tasks section emit at 243–247)
- Modify: `hooks/session-start.sh` (delete the OPEN_TASKS extraction and injection, lines 189–192 and 197–201)

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `build_deterministic_handoff` output whose FINAL section is `## Files Touched (this work unit)` (no `## Tasks` section, no `HANDOFF:TASKS` markers). Later tasks do not depend on this, but Task 7's grep sweep asserts no `harvest_tasks`/`HANDOFF:TASKS` references remain in `hooks/`.

Note: the synthetic handoff heredocs inside the test file (IMP-3 blocks, lines ~354–356 and ~393–395) still contain `## Tasks` + `HANDOFF:TASKS` marker lines. Leave them — they are inert *inputs* to `extract_block`/`finalize_handoff` tests, which are shape-agnostic.

- [ ] **Step 1: Update the tests (red)**

In `tests/handoff-lib-test.sh`:

1. Delete the entire harvest_tasks block — everything from the comment line
   `# harvest_tasks: reconstruct end-of-session task state from TaskCreate/TaskUpdate events.`
   (line 59) through `rm -f "$TCTRL"` (line 129), inclusive. That removes 14 asserts.
2. Replace the three build-CLI section asserts (lines 292–295):

```bash
# Assert the last SECTION heading is Tasks. Scope to headings AFTER the
# narrative END marker so a heading-bearing narrative could never spoof it.
assert_eq "build CLI: Tasks is the final section" "## Tasks" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT4" | grep '^## ' | tail -1)"
assert_contains "build CLI: TASKS:START marker present" "<!-- HANDOFF:TASKS:START -->" "$(cat "$OUT4")"
assert_contains "build CLI: TASKS:END marker present"   "<!-- HANDOFF:TASKS:END -->"   "$(cat "$OUT4")"
```

with:

```bash
# Assert the last SECTION heading is Files Touched. Scope to headings AFTER the
# narrative END marker so a heading-bearing narrative could never spoof it.
assert_eq "build CLI: Files Touched is the final section" "## Files Touched (this work unit)" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT4" | grep '^## ' | tail -1)"
```

3. Replace the compact-fallback section assert (line 304):

```bash
assert_eq "compact-fallback: Tasks is the final section" "## Tasks" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT5" | grep '^## ' | tail -1)"
```

with:

```bash
assert_eq "compact-fallback: Files Touched is the final section" "## Files Touched (this work unit)" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT5" | grep '^## ' | tail -1)"
```

4. Delete the fixture:

```bash
git rm tests/fixtures/transcript-tasks.jsonl
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=58 FAIL=2` — the two modified "final section" asserts fail because the library still emits `## Tasks` last.

- [ ] **Step 3: Delete the code**

In `hooks/handoff-lib.sh`:

1. Delete lines 63–111 — the comment block starting
   `# End-of-session task list from native TaskCreate/TaskUpdate events.` through the
   closing `}` of `harvest_tasks()` (the line before the `# Live context size =` comment).
2. In `build_deterministic_handoff`, replace:

```bash
        echo "## Files Touched (this work unit)"
        harvest_files < "$win" | sed 's/^/- /'
        echo
        echo "## Tasks"
        echo "<!-- HANDOFF:TASKS:START -->"
        harvest_tasks < "$win"
        echo "<!-- HANDOFF:TASKS:END -->"
    } > "$OUT"
```

with:

```bash
        echo "## Files Touched (this work unit)"
        harvest_files < "$win" | sed 's/^/- /'
        # ponytail: no Tasks section — native task state survives /clear within the
        # same CLI process (~/.claude/tasks/), the only path that injects a handoff.
        # If a future harness drops that persistence, re-add a harvester reading the
        # entry-level .toolUseResult fields (shapes recorded in
        # docs/superpowers/specs/2026-07-03-review-fixes-design.md).
    } > "$OUT"
```

In `hooks/session-start.sh` (the `source == "clear"` branch), delete these two chunks:

```bash
            # Extract only the open/in-progress tasks ([~] and [ ]) for native restore.
            # Completed tasks ([x]) are historical record only and are not re-created.
            OPEN_TASKS=$(extract_block TASKS "$HANDOFF_FILE" 2>/dev/null \
                | grep -E '^\- \[[~ ]\] ' || true)
```

and:

```bash
            if [[ -n "$OPEN_TASKS" ]]; then
                CONTEXT+="\\n**Open tasks to re-create (use TaskCreate for each):**\\n"
                CONTEXT+="$(printf '%s' "$OPEN_TASKS" | sed 's/$/\\n/' | tr -d '\n')\\n"
                CONTEXT+="(The \`[~]\` item is the one in progress — resume it first.)\\n"
            fi
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=60 FAIL=0`

Also confirm the CLI entrypoint still builds a well-formed handoff end-to-end:

```bash
TMP=$(mktemp -d)
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/x/y.sh"}}]}}' > "$TMP/t.jsonl"
bash hooks/handoff-lib.sh build --transcript "$TMP/t.jsonl" --slug demo --source handoff --out "$TMP/h.md" && echo BUILD_OK
grep -c 'HANDOFF:TASKS' "$TMP/h.md" || echo "no TASKS markers (expected)"
rm -rf "$TMP"
```

Expected: `BUILD_OK`, then `no TASKS markers (expected)` (grep -c exits 1 on zero matches).

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh hooks/session-start.sh tests/handoff-lib-test.sh
git commit -m "refactor: delete dead harvest_tasks pipeline (B4)

Validated live 2026-07-03: both assumed transcript field paths never
existed, so the TASKS block has always rendered empty. Native task
persistence across /clear (~/.claude/tasks/) covers the only path that
injects a handoff. Re-add shapes recorded in the design spec."
```

(Include the standard trailer from Global Constraints in this and every commit.)

---

### Task 2: B1 — `.last-dream` numeric guard in session-start.sh

**Files:**
- Modify: `hooks/session-start.sh:281-284`
- Test: `tests/handoff-lib-test.sh` (append before the final `echo "----"` summary block)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing other tasks use. Test helpers stay local to the appended block.

- [ ] **Step 1: Write the failing tests**

Append to `tests/handoff-lib-test.sh` (before the `echo "----"` summary):

```bash
# --- B1: a garbled .last-dream must not kill session-start (real entrypoint) ---
# Uses the hook's own dir-basename slug derivation so the seeded staging dir
# matches what the hook computes. OBSIDIAN_CLI_PATH=/nonexistent keeps the run
# fast and vault-free; HOME is throwaway so live staging is never touched.
B1_HOME="$(mktemp -d)"; B1_PROJ="$(mktemp -d)"
B1_SLUG="$(basename "$B1_PROJ" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
B1_STAGE="$B1_HOME/.claude/memory-staging/$B1_SLUG"
mkdir -p "$B1_STAGE"
printf '%s\n' '!!corrupt!!' > "$B1_STAGE/.last-dream"
B1_RC=0
B1_OUT="$(cd "$B1_PROJ" && echo '{"source":"startup"}' \
    | HOME="$B1_HOME" OBSIDIAN_CLI_PATH=/nonexistent bash "$HERE/../hooks/session-start.sh" 2>/dev/null)" || B1_RC=$?
assert_eq       "B1: garbled .last-dream exits 0"  "0" "$B1_RC"
assert_contains "B1: context still emitted"        "Memory System Active" "$B1_OUT"

# Clobber regression: a RECENT epoch written without a trailing newline was read
# but then discarded by the old `|| LAST_DREAM=0` (read returns 1 at EOF), which
# wrongly aged the dream timer to 1970 and flagged a consolidation.
printf '%s' "$(date +%s)" > "$B1_STAGE/.last-dream"
rm -f "$B1_STAGE/.dream-pending"
B1_OUT2="$(cd "$B1_PROJ" && echo '{"source":"startup"}' \
    | HOME="$B1_HOME" OBSIDIAN_CLI_PATH=/nonexistent bash "$HERE/../hooks/session-start.sh" 2>/dev/null)" || true
assert_not_contains "B1: recent no-newline .last-dream not clobbered" "Dream consolidation pending" "$B1_OUT2"
rm -rf "$B1_HOME" "$B1_PROJ"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=60 FAIL=3` — `!!corrupt!!` reaches `$(( ... ))`, the arithmetic
syntax error kills the hook under `set -e` (rc≠0, no output), and the
no-trailing-newline value is clobbered to 0 (dream nudge wrongly appears).

- [ ] **Step 3: Implement the guard**

In `hooks/session-start.sh`, replace:

```bash
if [[ -f "$LAST_DREAM_FILE" ]]; then
    read -r LAST_DREAM < "$LAST_DREAM_FILE" || LAST_DREAM=0
    LAST_DREAM="${LAST_DREAM:-0}"
    if [[ $(( (NOW_EPOCH - LAST_DREAM) / 3600 )) -ge 24 ]]; then
```

with:

```bash
if [[ -f "$LAST_DREAM_FILE" ]]; then
    # `|| true` (not `|| LAST_DREAM=0`): read returns 1 at EOF-without-newline
    # even though it delivered the value — do not discard it. The numeric guard
    # is what keeps garbled scratch bytes out of $((...)) (an arithmetic error
    # there would kill the whole hook under set -e).
    read -r LAST_DREAM < "$LAST_DREAM_FILE" || true
    [[ "${LAST_DREAM:-}" =~ ^[0-9]+$ ]] || LAST_DREAM=0
    if [[ $(( (NOW_EPOCH - LAST_DREAM) / 3600 )) -ge 24 ]]; then
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=63 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/handoff-lib-test.sh
git commit -m "fix: numeric guard on .last-dream so a garbled scratch file cannot kill session-start (B1)"
```

---

### Task 3: H1 — jq guard in `emit_context_and_exit`

**Files:**
- Modify: `hooks/session-start.sh:28-38`
- Test: `tests/handoff-lib-test.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `emit_context_and_exit` gains a no-jq plaintext path; its signature and both existing output channels are unchanged.

- [ ] **Step 1: Write the failing test**

The test sed-extracts the REAL function from the hook (so it cannot drift from
production code) and shadows the `command` builtin so `command -v jq` fails:

```bash
# --- H1: emit_context_and_exit falls back to plaintext when jq is missing ---
H1S="$(mktemp)"
{
    echo 'command() { return 1; }   # simulate: no jq on PATH (command -v fails)'
    sed -n '/^emit_context_and_exit()/,/^}/p' "$HERE/../hooks/session-start.sh"
    echo 'emit_context_and_exit "H1 plaintext line\\nsecond line"'
} > "$H1S"
H1_RC=0; H1_OUT="$(bash "$H1S")" || H1_RC=$?
assert_eq           "H1: no-jq emitter exits 0"      "0"                  "$H1_RC"
assert_contains     "H1: plaintext fallback emitted" "H1 plaintext line"  "$H1_OUT"
assert_not_contains "H1: no JSON wrapper without jq" "hookSpecificOutput" "$H1_OUT"
rm -f "$H1S"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=65 FAIL=1` — without the guard the function calls the real jq
(present on this machine), so the output contains `hookSpecificOutput`.

- [ ] **Step 3: Implement the guard**

In `hooks/session-start.sh`, inside `emit_context_and_exit`, insert the guard
after the `local out=...` line:

```bash
emit_context_and_exit() {
    local ctx="$1"
    local out="${ctx//\\n/$'\n'}"          # expand only the \n we control; leave \t \r etc literal
    # No jq => degrade to the documented plaintext channel rather than dying
    # having injected nothing (this is the highest-value hook).
    command -v jq >/dev/null 2>&1 || { printf '%s\n' "$out"; exit 0; }
    if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]]; then
```

(The rest of the function is unchanged.)

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=66 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/session-start.sh tests/handoff-lib-test.sh
git commit -m "harden: plaintext fallback in emit_context_and_exit when jq is missing (H1)"
```

---

### Task 4: B2 — sha1 cache key in read-once

**Files:**
- Modify: `hooks/read-once/hook.sh:60-65`
- Test: `tests/handoff-lib-test.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: cache filenames under `$HOME/.claude/read-once/cache/<session>/` become 40-char sha1 hex (was base64). Old-format cache entries simply miss once and re-cache — no migration needed (cache is ephemeral, auto-cleaned >24h).

- [ ] **Step 1: Write the failing tests**

```bash
# --- B2: read-once cache key must survive long and non-ASCII paths ---
RO="$HERE/../hooks/read-once/hook.sh"
B2_HOME="$(mktemp -d)"
# ~200-char path: base64 of it exceeds NAME_MAX(255) as a cache FILENAME, so the
# old key scheme fails the cache write and set -e kills the hook (exit != 0).
B2_DIR="$(mktemp -d)/$(printf 'd%.0s' {1..60})/$(printf 'e%.0s' {1..60})/$(printf 'f%.0s' {1..60})"
mkdir -p "$B2_DIR"
B2_FILE="$B2_DIR/target.txt"; echo content > "$B2_FILE"
B2_PAYLOAD="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$B2_FILE\"}}"
B2_RC1=0; printf '%s' "$B2_PAYLOAD" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" >/dev/null 2>&1 || B2_RC1=$?
B2_RC2=0; B2_OUT2="$(printf '%s' "$B2_PAYLOAD" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" 2>/dev/null)" || B2_RC2=$?
assert_eq       "B2: long path first read exits 0"     "0"       "$B2_RC1"
assert_eq       "B2: long path second read exits 0"    "0"       "$B2_RC2"
assert_contains "B2: long path second read is deduped" "already" "$B2_OUT2"

# Accented path regression (bytes >=0x80 could put "/" in a base64 key).
B2_FILE2="$(mktemp -d)/café.txt"; echo content > "$B2_FILE2"
B2_PAYLOAD2="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$B2_FILE2\"}}"
printf '%s' "$B2_PAYLOAD2" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" >/dev/null 2>&1 || true
B2_OUT4="$(printf '%s' "$B2_PAYLOAD2" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" 2>/dev/null)" || true
assert_contains "B2: accented path second read is deduped" "already" "$B2_OUT4"
rm -rf "$B2_HOME"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=67 FAIL=3` — the long-path cache write fails ENAMETOOLONG, so
both invocations exit non-zero and nothing is deduped. (The accented assert may
pass or fail depending on the base64 output — either is acceptable at red; the
three long-path asserts are the guaranteed failures, so FAIL is 3 or 4.)

- [ ] **Step 3: Implement the sha1 key**

In `hooks/read-once/hook.sh`, replace:

```bash
# --- Cache key ---
# Use base64 of file path as cache filename to handle special chars
CACHE_KEY=$(echo -n "$FILE_PATH" | base64 -w 0 2>/dev/null || echo -n "$FILE_PATH" | base64 2>/dev/null | tr -d '\n')
if [[ -z "$CACHE_KEY" ]]; then
    exit 0  # Cannot create cache key — allow read
fi
```

with:

```bash
# --- Cache key ---
# sha1 of the path: fixed 40-char filename, safe for non-ASCII and >NAME_MAX
# paths (raw base64 can emit "/" for bytes >=0x80 and overflow NAME_MAX).
# sha1sum ships with Git Bash / coreutils.
CACHE_KEY=$(printf '%s' "$FILE_PATH" | sha1sum 2>/dev/null | cut -d' ' -f1 || true)
if [[ -z "$CACHE_KEY" ]]; then
    exit 0  # Cannot create cache key — allow read
fi
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=70 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/read-once/hook.sh tests/handoff-lib-test.sh
git commit -m "fix: sha1 cache key in read-once — base64 keys broke on non-ASCII and long paths (B2)"
```

---

### Task 5: B3 — merge co-firing Stop-hook nudges

**Files:**
- Modify: `hooks/stop-memory.sh:74-86` (awk END block)
- Test: `tests/handoff-lib-test.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: when the count and duration nudges co-fire, the systemMessage is `"<count msg> | <duration msg>"` — same `" | "` joiner the handoff-token nudge already uses at line 138.

- [ ] **Step 1: Write the failing test**

```bash
# --- B3: co-firing count + duration nudges must BOTH be shown ---
SM="$HERE/../hooks/stop-memory.sh"
B3_HOME="$(mktemp -d)"; B3_PROJ="$(mktemp -d)"
B3_SLUG="$(basename "$B3_PROJ" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')"
B3_META="$B3_HOME/.claude/memory-staging/$B3_SLUG/.session-meta"
mkdir -p "$(dirname "$B3_META")"
B3_NOW=$(date +%s)
# message_count=29 => this turn hits 30 (count nudge); start 46min ago (duration nudge)
cat > "$B3_META" <<EOF3
session_start=2026-07-03T00:00:00Z
session_start_epoch=$((B3_NOW - 2760))
message_count=29
project_slug=$B3_SLUG
area=
EOF3
B3_OUT="$(cd "$B3_PROJ" && echo '{}' | HOME="$B3_HOME" bash "$SM" 2>/dev/null)" || true
assert_contains "B3: count nudge survives co-fire"    "This session has 30 exchanges" "$B3_OUT"
assert_contains "B3: duration nudge present"          "running for 46 minutes"        "$B3_OUT"
rm -rf "$B3_HOME" "$B3_PROJ"
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=71 FAIL=1` — the duration message overwrites `msg`, so the count
nudge is consumed (its sent-flag is written) but never shown.

- [ ] **Step 3: Implement the merge**

In `hooks/stop-memory.sh`, in the awk END block, replace:

```awk
        if (dur >= 45 && !ndur) {
            print "duration_nudge_sent=true" > tmp
            msg = "This session has been running for " dur " minutes with " newcount " exchanges. Consider running /memory-sync before context gets too large."
        }
```

with:

```awk
        if (dur >= 45 && !ndur) {
            print "duration_nudge_sent=true" > tmp
            dmsg = "This session has been running for " dur " minutes with " newcount " exchanges. Consider running /memory-sync before context gets too large."
            # Merge, do not overwrite — a co-firing count nudge must still be shown
            # (same " | " joiner as the handoff-token nudge appends with below).
            msg = (msg == "") ? dmsg : msg " | " dmsg
        }
```

- [ ] **Step 4: Run the suite to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=72 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/stop-memory.sh tests/handoff-lib-test.sh
git commit -m "fix: merge co-firing Stop-hook nudges instead of overwriting the count message (B3)"
```

---

### Task 6: T1 — single-jq `read_live_tokens`

**Files:**
- Modify: `hooks/handoff-lib.sh` (`read_live_tokens`, lines ~113-130 pre-Task-1 numbering)
- Test: `tests/handoff-lib-test.sh` (append)

**Interfaces:**
- Consumes: nothing.
- Produces: `read_live_tokens <transcript-path>` — same contract as today: prints one non-negative integer (0 on missing file / no usage / unparseable), always returns 0. Callers (`stop-memory.sh:128`, `build_deterministic_handoff`, the `tokens` CLI subcommand) keep their numeric guards and need no changes.

This is a behaviour-preserving performance refactor, so the new tests are
characterisation tests: they must pass BEFORE the swap (against the loop
implementation) and AFTER it. The win is jq spawn count: one per call instead
of up to 100 on the Stop hot path.

- [ ] **Step 1: Write the characterisation tests**

```bash
# --- T1: read_live_tokens regression cases (must pass before AND after the swap) ---
T1F="$(mktemp)"
{ printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":3},"content":[{"type":"text","text":"x"}]}}'
  printf '%s\n' '{"type":"system","subtype":"a"}' '{"type":"system","subtype":"b"}' '{"type":"system","subtype":"c"}'
} > "$T1F"
assert_eq "T1: usage found behind 3 trailing system lines" "123" "$(read_live_tokens "$T1F")"
printf '%s\n' 'this line is not JSON at all' >> "$T1F"
assert_eq "T1: malformed trailing line tolerated"          "123" "$(read_live_tokens "$T1F")"
printf '' > "$T1F"
assert_eq "T1: empty transcript => 0"                      "0"   "$(read_live_tokens "$T1F")"
rm -f "$T1F"
```

- [ ] **Step 2: Run the suite — all three must already pass**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=75 FAIL=0` (green on the old implementation — that is the point:
the swap must not change observable behaviour, including the existing
`live tokens = last usage entry sum` assert at 155000).

- [ ] **Step 3: Swap the implementation**

In `hooks/handoff-lib.sh`, replace the whole function (comment included):

```bash
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

with:

```bash
# Live context size = the LAST usage-bearing entry's input + cache_read +
# cache_creation. tail -1 of a transcript is often a type:system line with no
# usage, so take the last usage-bearing line within the final 100 (the last
# usage entry is always within a few of the tail). ONE jq spawn per call — this
# runs on the Stop hot path, where the old per-line loop cost up to 100 spawns
# (~30-50ms each on Git Bash). fromjson? skips a malformed line instead of
# failing the whole slurp, preserving the old per-line tolerance.
read_live_tokens() {
    local t="$1"
    [[ -f "$t" ]] || { echo 0; return 0; }
    local u
    u=$(tail -n 100 "$t" | jq -rRs '
        [ split("\n")[] | fromjson? | .message.usage | select(.)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0))
          | select(. > 0) ] | last // 0' 2>/dev/null || true)
    [[ "$u" =~ ^[0-9]+$ ]] || u=0
    echo "$u"
}
```

Deviation from the review-plan snippet (which used plain `jq -rs`): `-Rs` +
`fromjson?` is the same single spawn but skips malformed lines individually —
plain slurp would fail the WHOLE read (tokens=0, handoff nudge never fires) on
one bad line. Same size, correct on the edge case.

- [ ] **Step 4: Run the suite to verify it still passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=75 FAIL=0`

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "perf: single-jq read_live_tokens — one spawn instead of up to 100 on the Stop hot path (T1)"
```

---

### Task 7: Full verification sweep

**Files:**
- No modifications (verification only; fix anything it surfaces).

**Interfaces:**
- Consumes: all prior tasks' deliverables.
- Produces: green suite + Tier-1 run + reference sweep; the branch is then ready for the `/simplify` → `/security-review` gates.

- [ ] **Step 1: Unit suite**

Run: `bash tests/handoff-lib-test.sh`
Expected: `PASS=75 FAIL=0`

- [ ] **Step 2: Tier-1 hook validation against a THROWAWAY project**

```bash
TMPP=$(mktemp -d)
HOOKS_DIR=./hooks bash tests/hook-validation.sh "$TMPP"
rm -rf "$TMPP"
```

Expected: all PASS (baseline was 39/39; timing lines are advisory WARNs, not
failures). NEVER pass the real project dir — the throwaway dir confines staging
writes to a temp slug.

- [ ] **Step 3: Reference sweep**

```bash
grep -rn 'harvest_tasks\|HANDOFF:TASKS' hooks/ commands/ config/ agents/ skills/ CLAUDE.md .claude/CLAUDE.md || echo "clean"
```

Expected: `clean`. (Historical specs/plans and `graphify-out/` keep their
references — they are records, not live docs.)

- [ ] **Step 4: Manual smoke (real entrypoints, throwaway HOME)**

```bash
# B1/H1: garbled .last-dream + startup source => context still emitted, exit 0
TH=$(mktemp -d); TP=$(mktemp -d)
S=$(basename "$TP" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
mkdir -p "$TH/.claude/memory-staging/$S"
printf '%s\n' '!!corrupt!!' > "$TH/.claude/memory-staging/$S/.last-dream"
(cd "$TP" && echo '{"source":"startup"}' | HOME="$TH" OBSIDIAN_CLI_PATH=/nonexistent bash "$OLDPWD/hooks/session-start.sh" | head -3)
echo "rc=$?"; rm -rf "$TH" "$TP"
```

Expected: JSON with `additionalContext` containing "Memory System Active", `rc=0`.

- [ ] **Step 5: Stop for gates**

Do NOT merge. Report completion to Sam; the pipeline continues with `/simplify`
→ `/security-review` → fix anything flagged → Sam's sign-off via
`superpowers:finishing-a-development-branch`.
