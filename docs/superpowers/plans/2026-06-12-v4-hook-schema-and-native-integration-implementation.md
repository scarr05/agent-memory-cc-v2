# Agent Memory v4 Implementation Plan — Hook Schema Fixes & Native Integration

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the broken hook output schemas (the deterministic injection layer currently does not reach Claude), redesign the compaction checkpoint flow, hit the documented performance budgets, adopt native Claude Code features (subagent memory, SessionEnd, UserPromptSubmit, plugin packaging), and update the test harness in lockstep.

**Spec:** `docs/superpowers/specs/2026-06-12-v4-hook-schema-and-native-integration-design.md` — read it fully before starting. The Key Decisions table is binding.

**Architecture:** Bugs first (Tasks 1–6), then enhancements (Tasks 7–11), then packaging and docs (Tasks 12–13). Every hook change updates `tests/hook-validation.sh` in the same task — never leave the harness asserting a schema the hooks no longer emit.

**Tech Stack:** Bash (hooks, tests), Markdown (agents, commands, skills, docs), JSON (plugin manifest, hook registration)

---

## Review Findings Applied (2026-06-13)

A multi-agent review verified every bug claim against live code (all confirmed) and mapped the real file-level dependency graph. The following corrections are **binding** and override the original task text where they conflict:

1. **`session-start.sh` is the dominant serial bottleneck** — edited by Tasks 1, 2, 4, 5, 6, 8 (not the 2/5/8/9 the old header implied; Task 9 never touches it). A **single agent must own this file end-to-end in strict numeric order**. Do NOT split these tasks across parallel worktrees — the conflicts are semantic (function-call and field-write contracts), not textual.
2. **`tests/hook-validation.sh` is the second bottleneck** — edited by Tasks 2, 3, 4, 5, 6, 8, 9, 11. The results-table header/row is collided on by Tasks 5, 8, 9, 11; **Task 11 must run last** and re-derive the final table.
3. **Hidden contract — Task 2 ⟶ Task 4:** Task 2 must *extract* the output logic into a reusable `emit_context_and_exit` function (not merely swap the JSON), because Task 4's compact/clear branch calls it. This is a hard requirement on Task 2's deliverable shape.
4. **Hidden contract — Task 6 cross-file:** Task 6 must edit `session-start.sh` to *write* `session_start_epoch` into `.session-meta`, which its `stop-memory.sh` edit then reads. Both files change together in Task 6.
5. **Tasks 8 and 9 are NOT independent** — they share `config/settings.json` *and* the test results-table region. Run them serially under one owner, after Task 6 freezes `session-start.sh`. (The old "Tasks 7–10 parallelisable" note is wrong; only `{7, 10}` and `{12, 13}` are truly parallel.)
6. **Nudge `elif` bug (high):** the originally-proposed `if -ge 15 … elif -ge 30 …` is self-defeating — a session that jumps past 15 fires the 15 branch and never reaches 30. **Use two independent `if`s, checking 30 first** (see corrected Task 3 Step 2). Add a seed-29 → assert-30 test.
7. **Timing assertions are WARN, not hard FAIL:** `Stop ≤50ms` is almost certainly unreachable on Git Bash (empty bash spawn often exceeds 50ms). Tasks 5, 6, 9, 11 record measured times and **fail only on >2× regression against a recorded baseline**, never on an absolute target.
8. **Doc-injection is the load-bearing gate:** the empirical "what slug did the memory system inject?" check is elevated to a **Task 2 acceptance gate** — if `additionalContext` does not actually inject, stop and escalate. `MEMORY_HOOK_PLAINTEXT` only rescues SessionStart; UserPromptSubmit/PreToolUse have no plaintext fallback, so verify their injection independently (Task 9).
9. **`CLAUDE_SESSION_ID` scoping (Task 1):** verify it is exported into the PreCompact/PreToolUse hook env (Task 0). When unset, `$$` differs across processes, so the scoped clear no-ops — skip the clear in that case rather than wiping all sessions.
10. **Vault cache poisoning (Task 5):** key `.vault-cache.json` by **slug + branch**, and **always run the corrections query live** (exclude it from the cache) — a stale corrections fragment silently misses safety-critical overrides.

---

## CRITICAL: Doc Verification First

Hook output schemas have changed across Claude Code releases, and there is at least one known upstream issue affecting SessionStart `additionalContext` (#16538). Before writing any hook code:

1. Fetch and read https://code.claude.com/docs/en/hooks — record the exact current JSON output schema for: SessionStart, SessionEnd, UserPromptSubmit, PreToolUse, PreCompact, Stop.
2. Fetch https://code.claude.com/docs/en/sub-agents — confirm the `memory` frontmatter field name, allowed values, and version.
3. Fetch https://code.claude.com/docs/en/plugins — confirm `plugin.json` manifest fields and `hooks/hooks.json` registration format, including `${CLAUDE_PLUGIN_ROOT}`.
4. Write findings to `docs/superpowers/notes/2026-06-12-v4-schema-verification.md` (create the dir). If anything below contradicts the live docs, **the live docs win** — note the divergence and adjust.

---

## File Structure

```
agent-memory-cc-v2/
├── .claude-plugin/plugin.json          # NEW  (Task 12)
├── hooks/
│   ├── hooks.json                      # NEW  (Task 12)
│   ├── session-start.sh                # REWRITE (Tasks 1, 2, 4, 5, 6, 8) — dominant serial bottleneck, single-owner only
│   ├── session-end.sh                  # NEW  (Task 8)
│   ├── prompt-corrections.sh           # NEW  (Task 9)
│   ├── pre-compact.sh                  # UPDATE (Tasks 1, 4)
│   ├── stop-memory.sh                  # REWRITE (Tasks 3, 6)
│   └── read-once/hook.sh               # UPDATE (Task 3)
├── agents/memberberry.md               # UPDATE (Task 10)
├── agents/blackbox.md                  # UPDATE (Task 10)
├── commands/memory-sync.md             # UPDATE (Tasks 1, 7)
├── commands/{memory-init,memory-load,decision}.md  # UPDATE (Task 1)
├── config/settings.json                # UPDATE (Tasks 8, 9) — serialise: adjacent JSON keys
├── skills/agent-memory/SKILL.md        # UPDATE (Task 13)
├── docs/setup-guide-v4.md              # NEW  (Task 13)
└── tests/hook-validation.sh            # UPDATE (Tasks 2, 3, 4, 5, 6, 8, 9, 11) — shared results-table region, serialise
```

---

### Task 0: Branch hygiene and prerequisites

**Files:** none — git only

> **DECISION (2026-06-13):** Do **not** merge `dev/v3-cli-subagents` into `main` as part of this work. Pushing v3 straight to main would bypass the mandatory PR/`/simplify`/`/security-review` gates. The v3→main merge is deferred to its own PR. v4 is cut from the current v3 HEAD instead (v3 contains all prior work; `dev/v3-cli-subagents..dev/memory-improvements` is empty, confirmed).

- [x] **Step 1: Cut the working branch from v3 and push it** *(done 2026-06-13)*

```bash
git checkout -b dev/v4-schema-fixes   # from dev/v3-cli-subagents HEAD
git push -u origin dev/v4-schema-fixes
```

The v4 spec and plan are committed on this branch (commit `f1ea6a5`).

- [ ] **Step 2: Run the doc verification described above and commit the notes file**

```bash
git add docs/superpowers/notes/2026-06-12-v4-schema-verification.md
git commit -m "docs: record verified hook/plugin schema findings for v4"
```

Additionally record in the notes: whether `CLAUDE_SESSION_ID` is exported into the PreCompact/PreToolUse hook environment (finding 9), and the exact `mcp__<server>__<tool>` prefix from a live `/mcp` (finding for Task 1).

---

### Task 1: Quick defect fixes (no schema changes)

**Files:**
- Modify: `hooks/pre-compact.sh`, `hooks/session-start.sh`, `commands/memory-sync.md`, `commands/memory-load.md`, `commands/memory-init.md`, `commands/decision.md`

- [ ] **Step 1: Scope the read-once cache clear in `pre-compact.sh`**

Replace:
```bash
rm -rf "$HOME/.claude/read-once/cache/" 2>/dev/null || true
```
with (finding 9 — do NOT fall back to `$$`: pre-compact and the read-once PreToolUse hook are separate processes with different PIDs, so a `$$` fallback targets a non-existent dir and the clear silently no-ops while leaving every other session's cache intact only by accident):
```bash
# Clear read-once cache for THIS session only — other sessions keep theirs.
# Requires CLAUDE_SESSION_ID (the same key read-once/hook.sh uses). If it is
# unset, skip the clear rather than wipe all sessions or target a wrong PID dir.
if [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    RO_SESSION=$(echo "$CLAUDE_SESSION_ID" | tr -cd 'A-Za-z0-9_-')
    rm -rf "$HOME/.claude/read-once/cache/$RO_SESSION" 2>/dev/null || true
fi
```
Task 0 must confirm `CLAUDE_SESSION_ID` is actually exported into the PreCompact hook environment; if it is reliably set this scoping is correct. Add a test that seeds two session cache dirs and asserts only the matching one is removed.

- [ ] **Step 2: Stop `memory-state.json` dirtying git status**

In `session-start.sh`, after writing `$STATE_FILE`, add:

```bash
# Keep memory-state.json out of git status without touching tracked .gitignore
if git rev-parse --git-dir &>/dev/null 2>&1; then
    EXCLUDE_FILE="$(git rev-parse --git-dir)/info/exclude"
    if ! grep -q 'memory-state.json' "$EXCLUDE_FILE" 2>/dev/null; then
        echo ".claude/memory-state.json" >> "$EXCLUDE_FILE" 2>/dev/null || true
    fi
fi
```

- [ ] **Step 3: Fix command frontmatter across all four commands**

In `commands/*.md`:
- Remove the `user-invocable:` line (not a documented field).
- Rewrite every `allowed-tools` MCP entry from `obsidian:<tool>` to `mcp__obsidian__<tool>` (e.g. `mcp__obsidian__read_note`). Verify the exact prefix by running `/mcp` in a live session or checking the verification notes from Task 0.

- [ ] **Step 4: Run Tier 1, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture || true
git add hooks/ commands/
git commit -m "fix: scope read-once cache clear, exclude state file from git, correct command frontmatter"
```

(Tier 1 will still FAIL on timing/schema — that's expected until Tasks 2–6.)

---

### Task 2: SessionStart schema fix

**Files:**
- Modify: `hooks/session-start.sh`, `tests/hook-validation.sh`

- [ ] **Step 1: Replace the output block**

At the end of `session-start.sh`, replace:
```bash
jq -n --arg msg "$(echo -e "$CONTEXT")" '{"systemMessage": $msg}'
```
with:
```bash
# --- Output ---
# additionalContext is the documented injection channel for SessionStart.
# MEMORY_HOOK_PLAINTEXT=1 falls back to plain stdout (also documented) in case
# the upstream additionalContext bug (#16538) is still live for this CC version.
if [[ "${MEMORY_HOOK_PLAINTEXT:-0}" == "1" ]]; then
    echo -e "$CONTEXT"
else
    jq -n --arg ctx "$(echo -e "$CONTEXT")" \
        '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": $ctx}}'
fi
```

Adjust field names if the Task 0 verification notes differ.

**Finding 3 (hard requirement):** wrap this output logic in a function — `emit_context_and_exit()` — that both the full path and Task 4's compact/clear branch call. Task 2's deliverable is the *function*, not just the swapped JSON, because Task 4 calls it. Define it once; do not inline the output in two places.

- [ ] **Step 2: Update the Tier 1 assertions**

In `tests/hook-validation.sh`, the session-start section: replace the `systemMessage` extraction with:
```bash
SS_MSG=$(echo "$SS_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)
```
and rename the pass/fail labels accordingly. Slug extraction (`Project: \`...\``) operates on `$SS_MSG` as before — update the grep pattern to match the actual context format (`Project: \`slug\`` not `Project slug:`; check the hook's CONTEXT string and make test and hook agree).

- [ ] **Step 3: Run, verify session-start schema tests pass, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture || true
git add hooks/session-start.sh tests/hook-validation.sh
git commit -m "fix: SessionStart emits additionalContext instead of systemMessage"
```

- [ ] **Step 4: ACCEPTANCE GATE — confirm injection actually lands (finding 8)**

Tier 1 only proves the hook *emits* `additionalContext`; it cannot prove Claude *receives* it (upstream bug #16538). In a live session, ask: **"what project slug did the memory system inject?"** If Claude cannot see it, the JSON form is not landing — set `MEMORY_HOOK_PLAINTEXT=1` and re-test. **Do not proceed to Tasks 4–13 until one of the two forms verifiably injects** — every downstream task assumes the injection channel works. Record the working form (JSON vs plaintext) and the CC version in the Task 0 notes.

---

### Task 3: Stop and read-once schema fixes

**Files:**
- Modify: `hooks/stop-memory.sh`, `hooks/read-once/hook.sh`, `hooks/read-once/README.md`, `tests/hook-validation.sh`

- [ ] **Step 1: Fix the Stop nudge output**

In `stop-memory.sh`, replace the output block:
```bash
if [[ -n "$NUDGE" ]]; then
    cat << HOOKJSON
{
  "reason": "$NUDGE"
}
HOOKJSON
fi
```
with:
```bash
# systemMessage = user-visible nudge. Never block the agent for a reminder.
if [[ -n "$NUDGE" ]]; then
    printf '{"systemMessage": "%s"}\n' "$NUDGE"
fi
```
(`$NUDGE` contains no quotes/backslashes by construction; keep it that way.)

- [ ] **Step 2: Fix nudge thresholds to survive missed fires**

Replace the `-eq 15` / `-eq 30` checks with `-ge` plus sent-flags in `.session-meta`, mirroring the existing `duration_nudge_sent` pattern. **Check 30 BEFORE 15, using independent guards — NOT an elif chain starting at 15.**

```bash
# Highest threshold first. A session that jumps PAST 15 (a missed fire — the
# exact case -ge exists to survive) must still fire the 30 nudge. An
# `if -ge 15 … elif -ge 30` would fire the 15 branch and never reach 30.
if [[ "$NEW_COUNT" -ge 30 ]] && ! grep -q 'nudge30_sent=true' "$META_FILE" 2>/dev/null; then
    NUDGE="This session has $NEW_COUNT exchanges (~${DURATION_MINS}min). Consider running /memory-sync to checkpoint progress to Obsidian."
    echo "nudge30_sent=true" >> "$META_FILE"
elif [[ "$NEW_COUNT" -ge 15 ]] && ! grep -q 'nudge15_sent=true' "$META_FILE" 2>/dev/null; then
    NUDGE="This session has $NEW_COUNT exchanges (~${DURATION_MINS}min). Consider running /memory-sync to checkpoint progress to Obsidian."
    echo "nudge15_sent=true" >> "$META_FILE"
fi
```
(`elif` is correct here *because 30 is checked first*: at count ≥30 the first branch fires; at 15–29 it falls through to the second. Set `nudge30_sent` should also imply `nudge15_sent` is moot — once 30 fires, the 15 nudge is no longer wanted.)

- [ ] **Step 3: Fix read-once PreToolUse schema**

In `hooks/read-once/hook.sh`, replace every `{decision: "block", reason: ...}` / `{decision: "allow", reason: ...}` jq construction with the current PreToolUse form:

```bash
jq -n --arg reason "..." \
  '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": $reason}}'
```
(`deny` for the old `block`, `allow` for `allow`.) Also fix the two early-exit echo lines (jq-missing, bad-config) to the same schema. Note the divergence from upstream Boucle in `hooks/read-once/README.md`.

- [ ] **Step 4: Add read-once schema tests and update Stop tests**

In `tests/hook-validation.sh`:
- Stop section: assert no output below thresholds (existing); add a seeded test — write `message_count=14` into a temp `.session-meta`, fire the hook, assert output contains `systemMessage` and meta gains `nudge15_sent=true`. **Add the missed-fire test (finding 6):** seed `message_count=29` with NO `nudge15_sent` flag, fire once, assert `nudge30_sent=true` and the nudge fired — this is the case the elif ordering must survive and the seed-14 test does not cover. Restore meta afterwards.
- New read-once section: pipe a synthetic PreToolUse JSON (`{"tool_name":"Read","tool_input":{"file_path":"<this script>"}}`) twice; second response must contain `.hookSpecificOutput.permissionDecision == "allow"` with a reason in warn mode. With `READ_ONCE_MODE=deny`, second response must be `"deny"`. Clean the cache dir before and after.

- [ ] **Step 5: Run, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture || true
git add hooks/stop-memory.sh hooks/read-once/ tests/hook-validation.sh
git commit -m "fix: Stop nudge via systemMessage with -ge thresholds, read-once permissionDecision schema"
```

---

### Task 4: PreCompact redesign — stub only, handoff via SessionStart source

**Files:**
- Modify: `hooks/pre-compact.sh`, `hooks/session-start.sh`, `tests/hook-validation.sh`

- [ ] **Step 1: Strip PreCompact to its filesystem side effect**

In `pre-compact.sh`: keep slug detection, checkpoint-stub writing, state-file update, and the (now scoped) cache clear. Delete the entire `CONTEXT` build and the final `jq -n ... systemMessage` output. The hook emits nothing on stdout. Update the stub body text: remove "before compaction completes"; replace with "Process this checkpoint at the start of the post-compaction session (SessionStart source=compact will direct this)."

- [ ] **Step 2: Add source matching to `session-start.sh`**

Near the top, parse stdin (SessionStart receives JSON):
```bash
INPUT=$(cat || true)
SOURCE=$(echo "$INPUT" | jq -r '.source // "startup"' 2>/dev/null || echo "startup")
```
Then branch before the expensive context build:
```bash
if [[ "$SOURCE" == "compact" ]] || [[ "$SOURCE" == "clear" ]]; then
    CONTEXT="## Memory System (post-$SOURCE)\\n"
    CONTEXT+="Project: \`$SLUG\` | Area: \`${AREA:-unset}\`\\n"
    if [[ "$SOURCE" == "compact" ]] && [[ ${#PENDING_CHECKPOINTS[@]} -gt 0 ]]; then
        CONTEXT+="\\n**ACTION REQUIRED:** Delegate to the blackbox subagent NOW to fill in the pending checkpoint(s) with session state, then continue the interrupted work:\\n"
        for cp in "${PENDING_CHECKPOINTS[@]}"; do CONTEXT+="- \`$cp\`\\n"; done
    fi
    CONTEXT+="\\n→ memberberry for prior context, blackbox for checkpoints. No direct MCP vault reads.\\n"
    # emit via the same output block as the full path, then exit
    emit_context_and_exit   # refactor the Task 2 output block into a function both paths call
fi
```
Structure it however is cleanest — the requirement: compact/clear paths skip git inspection, all CLI vault queries, and state-file rewriting; they emit only slug + checkpoint handoff + delegation guidance.

- [ ] **Step 3: Tests**

- PreCompact section: replace the "valid JSON output" assertion with "stdout is empty"; keep stub-created and frontmatter assertions.
- New SessionStart test: invoke with `echo '{"source": "compact"}'`, assert output is slim (no `### Git` section) and contains `ACTION REQUIRED` when a checkpoint stub exists (create one first via the pre-compact hook, which the test already runs — order the compact-source test after the PreCompact section).

- [ ] **Step 4: Run, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture || true
git add hooks/pre-compact.sh hooks/session-start.sh tests/hook-validation.sh
git commit -m "feat: move compaction checkpoint handoff to SessionStart source=compact"
```

---

### Task 5: SessionStart performance — parallel CLI + vault cache

**Files:**
- Modify: `hooks/session-start.sh`, `tests/hook-validation.sh`

- [ ] **Step 1: Add the vault-state cache**

Before the CLI block: if the cache exists and is younger than 15 minutes (mtime check via `find -mmin -15`), read the pre-rendered context fragments from it and skip the cached CLI calls. After a cold run, write the fragments to the cache atomically (`.tmp` + `mv`).

**Finding 10 — cache scoping:** key the cache by **slug + branch**, e.g. `.vault-cache-$(git branch --show-current 2>/dev/null || echo nobranch).json`, so a concurrent session on another branch of the same repo does not read this branch's working files/tasks. **Exclude corrections from the cache entirely** — always run the corrections query live (one CLI call) and refresh `.corrections-index` on every start. A stale corrections fragment silently misses safety-critical overrides, which the system treats as the highest-stakes fragment.

- [ ] **Step 2: Parallelise the cold path**

Run the five CLI queries (index row, open tasks, working files, corrections, session depth) as background jobs, each redirecting to its own temp file under `$PROJECT_DIR/.ss-tmp/`, then a single `wait`. Assemble `CONTEXT` from the temp files in the original order. Wrap the whole cold block with a watchdog: launch jobs, `wait` with a bounded loop (poll up to ~3s using `kill -0`), and on timeout kill remaining jobs and fall through to minimal context plus the warning line. Also: the corrections query result additionally writes `$PROJECT_DIR/.corrections-index` (one line per correction: `<title>|<keywords>`) for Task 9.

- [ ] **Step 3: Timing tests**

Tier 1 session-start section: run the hook twice; record both timings in the metrics line (`cold Xms / warm Yms`). **WARN (not FAIL) when warm >300ms or cold >3000ms; FAIL only on >2× recorded baseline (finding 7).** Skip the cold check with a SKIP note when `obsidian version` fails (the CLI may be unavailable on the runner). Add the two timing columns to the results table row.

- [ ] **Step 4: Run, verify timings, commit**

```bash
rm -f ~/.claude/memory-staging/memory-architecture/.vault-cache.json
bash tests/hook-validation.sh "$(pwd)" memory-architecture
git add hooks/session-start.sh tests/hook-validation.sh
git commit -m "perf: parallel CLI queries with 15min vault cache and 3s budget in SessionStart"
```

---

### Task 6: Stop hook performance

**Files:**
- Modify: `hooks/stop-memory.sh`, `hooks/session-start.sh`, `tests/hook-validation.sh`

- [ ] **Step 1: Remove jq and consolidate file passes**

- Slug from state file: `sed -n 's/.*"slug": *"\([^"]*\)".*/\1/p' "$STATE_FILE"` instead of jq.
- Replace the multiple sed/grep/append passes over `.session-meta` with ONE awk invocation that increments `message_count`, updates/adds `last_activity`, and prints the new count — write to `.tmp` and `mv`.
- Drop the `date -d` duration parse if it costs a process: store `session_start_epoch=$(date +%s)` in `.session-meta` at SessionStart and subtract directly. **Finding 4 (cross-file contract):** this requires editing `session-start.sh` to WRITE `session_start_epoch` into `.session-meta` — both files change in this task. If only `stop-memory.sh` is edited, the duration calc reads a field that was never written. The single-awk consolidation here must also subsume the `nudge15_sent`/`nudge30_sent` flag writes Task 3 added, so author this with Task 3's `-ge`/sent-flag logic already present (hard ordering dependency: Task 3 before Task 6).

- [ ] **Step 2: Move the dream-timer check to SessionStart**

Delete the `.last-dream` / `.dream-pending` block from `stop-memory.sh` entirely. In `session-start.sh` (full path only), add the equivalent check: if `.last-dream` is older than 24h → touch `.dream-pending` (the surfacing logic already exists there). Keep the first-ever-use rule: in SessionStart, flag dream-pending if no `.last-dream` exists AND prior session meta shows `message_count >= 5`.

- [ ] **Step 3: Measure the Stop hot path (WARN, not hard FAIL — finding 7)**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture
```
`≤50ms` on Git Bash is almost certainly unreachable (an empty `bash -c exit 0` often exceeds it on Windows; each binary spawn is ~10–30ms). So the harness **records** the measured Stop time and **WARNs** if over 50ms, but only **FAILs on >2× the recorded baseline** (regression guard). First measure the empty-bash-spawn floor on the target box and note it in the results file as the real lower bound. Still minimise spawns — state-file read + single awk + conditional printf, nothing else — and document the final measured time.

- [ ] **Step 4: Commit**

```bash
git add hooks/stop-memory.sh hooks/session-start.sh tests/hook-validation.sh
git commit -m "perf: single-pass Stop hook under 50ms, dream timer moved to SessionStart"
```

---

### Task 7: `/memory-sync` sets the synced flag

**Files:**
- Modify: `commands/memory-sync.md`

- [ ] **Step 1: Extend Step 6 (Clean Up Staging)**

After the existing cleanup commands, add:
```bash
echo "synced=true" >> ~/.claude/memory-staging/<slug>/.session-meta
rm -f ~/.claude/memory-staging/<slug>/.unsynced
```
And note: SessionStart resets `.session-meta` each session, so `synced=true` naturally applies to the current session only.

- [ ] **Step 2: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: memory-sync records synced flag and clears unsynced marker"
```

---

### Task 8: SessionEnd hook — deterministic unsynced detection

**Files:**
- Create: `hooks/session-end.sh`
- Modify: `hooks/session-start.sh`, `config/settings.json`, `tests/hook-validation.sh`

- [ ] **Step 1: Write `hooks/session-end.sh`**

Slim, same style as stop-memory: fast slug detection (state file → CLAUDE.md → dirname), read `.session-meta`; if `message_count >= 10` and no `synced=true`, write `$PROJECT_DIR/.unsynced`:
```
ended=<ISO timestamp>
messages=<count>
```
No stdout output needed. Always exit 0. Verify against the Task 0 notes whether SessionEnd receives a `reason` field on stdin (e.g. `clear`, `logout`, `exit`) and skip flag-writing when reason is `clear` (a cleared session was deliberate).

- [ ] **Step 2: Surface in SessionStart (full path)**

If `$PROJECT_DIR/.unsynced` exists, prepend to CONTEXT:
"⚠ Previous session (<messages> msgs, ended <date>) was never synced. Consider `/memory-sync` or check staging checkpoints."
Do not delete the flag here — `/memory-sync` owns its removal (Task 7).

- [ ] **Step 3: Register in `config/settings.json`** (SessionEnd event, same command pattern as the others).

- [ ] **Step 4: Tier 1 section for session-end**

Seed meta with `message_count=12`, fire hook, assert `.unsynced` exists with both keys. Re-seed with `synced=true` appended, fire, assert no flag. Timing ≤ 100ms. Clean up.

- [ ] **Step 5: Run, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture
git add hooks/session-end.sh hooks/session-start.sh config/settings.json tests/hook-validation.sh
git commit -m "feat: SessionEnd hook writes unsynced flag, surfaced at next SessionStart"
```

---

### Task 9: UserPromptSubmit corrections injection

**Files:**
- Create: `hooks/prompt-corrections.sh`
- Modify: `config/settings.json`, `tests/hook-validation.sh`

- [ ] **Step 1: Write `hooks/prompt-corrections.sh`**

Budget <100ms — no jq on the happy path, no CLI calls:
1. Slug via state file (sed) → fall back to dirname. `INDEX="$HOME/.claude/memory-staging/$SLUG/.corrections-index"`.
2. `[[ -f "$INDEX" ]] || exit 0` (instant exit — the common case).
3. Read the prompt from stdin JSON. Extract with sed/grep (`"prompt":"..."` field) — jq acceptable here only if measured under budget.
4. Case-insensitive match of any index keyword against the prompt (`grep -iqF` per line, or one `grep -iE` over a joined pattern). On hit, emit:
```json
{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "Correction on record: <titles>. Load details via memberberry before proceeding."}}
```
(Verify field names against Task 0 notes; plain stdout is also documented as injected for UserPromptSubmit and is an acceptable simpler alternative — choose based on verification.) **Finding 8:** `MEMORY_HOOK_PLAINTEXT` does NOT cover this hook. If `additionalContext` injection is unreliable for UserPromptSubmit (sibling of #16538), corrections injection silently no-ops — reproducing the exact v3 class of bug. Verify injection independently with a Tier 2 check ("after a corrections hit, does Claude actually see it?"); if unreliable, default this hook to plain stdout from the outset.
5. No match → exit 0 silently.

- [ ] **Step 2: Register in `config/settings.json`** under UserPromptSubmit.

- [ ] **Step 3: Tier 1 section**

Write a temp `.corrections-index` with a known keyword; pipe `{"prompt": "tell me about <keyword> handling"}`; assert additionalContext emitted. Pipe a non-matching prompt; assert empty. Remove index; assert instant clean exit. All three ≤ 100ms.

- [ ] **Step 4: Run, commit**

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture
git add hooks/prompt-corrections.sh config/settings.json tests/hook-validation.sh
git commit -m "feat: UserPromptSubmit hook injects matching corrections just-in-time"
```

---

### Task 10: Native subagent memory

**Files:**
- Modify: `agents/memberberry.md`, `agents/blackbox.md`

- [ ] **Step 1: Confirm syntax from Task 0 notes** (field name, values, minimum CC version). If the field differs from `memory: user` / `memory: project`, follow the docs.

- [ ] **Step 2: memberberry** — add `memory: user` to frontmatter. Append to the prompt body:

```markdown
## Agent Memory

You have persistent memory. Before searching, check it for known-good
search paths and vault layout notes for this project slug. After a
successful retrieval, record (briefly): which query/path combination
found the answer, and any vault layout discoveries (new folders,
renamed indexes). Do not record session content — only search strategy.
```

- [ ] **Step 3: blackbox** — add `memory: project` to frontmatter. Append a parallel section: record checkpoint file locations written and merge decisions taken; check memory before creating a new checkpoint to avoid duplicates.

- [ ] **Step 4: Manual verification + commit**

Verification is session-level (playbook, see Task 13): invoke memberberry twice in a live session and confirm the second run references remembered strategy. For now, lint the frontmatter (valid YAML) and commit:

```bash
git add agents/
git commit -m "feat: enable native persistent memory on memberberry and blackbox"
```

---

### Task 11: Tier 1 results table update

**Files:**
- Modify: `tests/hook-validation.sh`

- [ ] **Step 1: Extend the results table** header and row to:

```
| Project | Slug | SS chars | SS cold ms | SS warm ms | PC stub bytes | PC ms | Stop ms | SE ms | UPS ms | Result |
```

Wire in the values captured by Tasks 5, 8, 9. Run the full suite, confirm a complete row and overall PASS:

```bash
bash tests/hook-validation.sh "$(pwd)" memory-architecture
cat tests/results/baseline-$(date +%Y-%m-%d).md
```

- [ ] **Step 2: Commit**

```bash
git add tests/hook-validation.sh
git commit -m "feat: extend Tier 1 results with warm-start, session-end, prompt-hook metrics"
```

---

### Task 12: Plugin packaging

**Files:**
- Create: `.claude-plugin/plugin.json`, `hooks/hooks.json`

- [ ] **Step 1: Write the manifest** (fields per Task 0 verification notes):

```json
{
  "name": "agent-memory",
  "version": "4.0.0",
  "description": "Hook-enforced persistent memory for Claude Code backed by an Obsidian vault. Three-tier storage, Haiku retrieval subagents, deterministic lifecycle hooks."
}
```

- [ ] **Step 2: Write `hooks/hooks.json`** registering all six hooks with `${CLAUDE_PLUGIN_ROOT}` paths, mirroring `config/settings.json`:

SessionStart, SessionEnd, UserPromptSubmit, PreToolUse (matcher `Read`), PreCompact, Stop. Exact registration format per Task 0 notes.

- [ ] **Step 3: Verify agents/, commands/, skills/ are at the locations the plugin system expects** (per docs — plugins auto-discover `agents/`, `commands/`, `skills/` at plugin root; this repo already matches). Adjust paths only if the docs say otherwise.

- [ ] **Step 4: Local install test**

In a separate Claude Code session: install the plugin from the local path (per docs, e.g. `/plugin install <path>` or marketplace-add of a local dir), then confirm `/hooks` lists all six hooks, `/agents` shows memberberry and blackbox, and `/memory-sync` autocompletes. Record results in the verification notes.

- [ ] **Step 5: Commit**

```bash
git add .claude-plugin/ hooks/hooks.json
git commit -m "feat: package agent-memory as an installable Claude Code plugin"
```

---

### Task 13: Docs, skill update, and final verification

**Files:**
- Create: `docs/setup-guide-v4.md`
- Modify: `skills/agent-memory/SKILL.md`, `tests/playbook.md`, `README.md`, `CLAUDE.md`, `docs/hooks-architecture.md`

- [ ] **Step 1: `docs/setup-guide-v4.md`** — plugin install as the primary path (3 steps), manual copy as fallback (carried from v2 guide). Include `MEMORY_HOOK_PLAINTEXT` escape hatch and the new hooks.

- [ ] **Step 2: Update `skills/agent-memory/SKILL.md`** — hook table gains SessionEnd and UserPromptSubmit rows; PreCompact row rewritten (stub only; checkpoint processing happens at SessionStart source=compact); layer diagram updated.

- [ ] **Step 3: Update `tests/playbook.md`** — Tier 2 gains: "ask Claude 'what project slug did the memory system inject?'" (verifies additionalContext actually landed — THE critical schema check); memberberry-memory two-invocation check. Tier 3 gains: compact → verify SessionStart source=compact handoff fires and blackbox fills the stub; unsynced-flag check (end session without sync, restart, confirm warning).

- [ ] **Step 4: Update `README.md`, root `CLAUDE.md`, `docs/hooks-architecture.md`** — v4 architecture: six hooks, corrected schemas, plugin install, performance budgets (SessionStart warm ≤300ms / cold ≤3s, Stop ≤50ms, UserPromptSubmit ≤100ms).

- [ ] **Step 5: Full verification**

```bash
# Tier 1 on this repo and one other project — must PASS clean
bash tests/hook-validation.sh "$(pwd)" memory-architecture
bash tests/hook-validation.sh /c/Users/user/Documents/Projects/WAFR-discovery
```
Then run playbook Tier 2 + Tier 3 in a live session (manual). Fix anything found.

- [ ] **Step 6: Final commit and PR**

```bash
git add docs/ skills/ tests/playbook.md README.md CLAUDE.md
git commit -m "docs: v4 setup guide, skill and playbook updates"
git push -u origin dev/v4-schema-fixes
```

Open a PR to main summarising: schema fixes (the headline), compaction redesign, performance results (before/after table from baselines), new hooks, plugin packaging.

---

## Execution Notes

- **Order is binding for Tasks 0–6** (each builds on the prior). **Only `{Task 7, Task 10}` and `{Task 12, Task 13}` are truly parallel** (disjoint files). Tasks 8 and 9 are NOT independent (shared `settings.json` + test results table) and Task 8 edits `session-start.sh`, so run 8→9 serially after Task 6. Task 11 is a barrier after 5/8/9. (Corrects the original "Tasks 7–10 parallelisable" claim — see Review Findings 1, 5.)
- **Windows/Git Bash is the primary platform.** Watch process-spawn costs in hot-path hooks (Stop, UserPromptSubmit) — every external binary call is ~10–30ms there. Measure, don't assume.
- **LF line endings** on all `.sh` files (CRLF breaks bash). If editing on Windows, verify with `file hooks/*.sh`.
- **Never leave a task with the harness asserting an old schema.** Hook + test change together, same commit.
