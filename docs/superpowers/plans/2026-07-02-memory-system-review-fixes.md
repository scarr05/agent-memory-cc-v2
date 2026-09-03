# Memory System Review — Bugs & Improvements Plan

## Context

Sam asked for a full codebase review (bugs + improvements) of the hook-enforced memory system, using graphify (knowledge graph) and ponytail (minimalism gate). Goal: **bulletproof memory system that is token efficient**. All six hooks, the harvest library, config registration, and the read-once dedup hook were reviewed line-by-line; graphify extraction agents were dispatched over the 51 docs (graph build completes at execution time — plan mode blocked the write steps).

Branch: `dev/handoff-clear-continue` (clean, all three gates passed, unmerged). Two open items from the prior session fold into this plan.

## Findings

### Bugs (fix)

**B1 — SessionStart dies silently on a garbled `.last-dream` file** — `hooks/session-start.sh:281-284`
`read -r LAST_DREAM < file || LAST_DREAM=0` clobbers a value that WAS read when the file lacks a trailing newline (read returns 1 at EOF), and a non-numeric value reaches `$(( ... ))` under `set -euo pipefail` → arithmetic error → the entire hook exits with no context injected. One bad byte in a scratch file = total memory-system outage for every subsequent full-path start.
Fix (2 lines): validate `[[ "$LAST_DREAM" =~ ^[0-9]+$ ]] || LAST_DREAM=0` after the read; drop the `||` clobber.

**B2 — read-once cache key breaks on non-ASCII / very long paths** — `hooks/read-once/hook.sh:62`
Cache filename is raw base64 of the path. Verified: pure-ASCII paths can never produce `/`, but any byte ≥0x80 (accented filename) can, and paths >~190 chars exceed NAME_MAX. Either way `write_cache` fails → `set -e` exits 1 → hook error noise on every Read of that file and dedup permanently dead for it.
Fix (1 line): hash the path instead — `CACHE_KEY=$(printf '%s' "$FILE_PATH" | sha1sum | cut -d' ' -f1)` (fixed 40-char safe filename; sha1sum ships with Git Bash). Delete the base64 fallback chain.

**B3 — Stop-hook duration nudge swallows the message-count nudge** — `hooks/stop-memory.sh:75-86`
In the awk END block, if the 15/30-count nudge and the 45-min duration nudge both fire on the same turn, `msg` is reassigned: the count flag is written (consumed forever) but its message never shown.
Fix (1 line): append instead of overwrite (`msg = msg ... " | " ...` style), or reorder so the count message wins. Cosmetic-adjacent; cheap.

**B4 — `harvest_tasks` transcript shape is unvalidated (open item 1)** — `hooks/handoff-lib.sh:71-111`
The jq assumes tool_result carries a top-level `.taskId` and `TaskUpdate.input.id` equals it. The fixture in `tests/handoff-lib-test.sh` asserts the same shape, so it isn't independent evidence. If wrong, the TASKS block silently renders empty.
Fix: validate empirically — TaskCreate/TaskUpdate a throwaway task in a live session, grep the session `.jsonl` for the recorded shape, pipe it through `harvest_tasks`. Only change the jq if the live shape differs (then update the fixture too).

### Hardening (small, worth it)

**H1 — `emit_context_and_exit` requires jq; missing jq = silent no-injection** — `hooks/session-start.sh:28-38`
Every emit path calls `jq -n`. On a machine without jq the hook dies emitting nothing. read-once already has a jq guard; session-start (the highest-value hook) does not.
Fix (2 lines): `command -v jq >/dev/null || { printf '%s\n' "$out"; exit 0; }` at the top of the emitter (plaintext stdout is the documented fallback channel anyway).

### Token-efficiency improvements

**T1 — `read_live_tokens` spawns jq per line** — `hooks/handoff-lib.sh:117-130`
`while read` + one `jq` per transcript line (up to 100) on the Stop hot path once a session passes 8 messages. Usually exits after a few lines, but worst case is 100 process spawns per turn on Git Bash (~30-50ms each).
Fix: single jq pass — `tail -n 100 "$t" | jq -rs '[.[] | .message.usage | select(.) | ((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0)) | select(. > 0)] | last // 0'` (one spawn, same semantics; keep the numeric guard in callers). Update the unit test expectations if output shape shifts.

**T2 — no fix: `harvest_files` raw file_path (open item 2)** — `hooks/handoff-lib.sh:40-46`
Structurally safe: every output line is prefixed `- <count> `, so a crafted path can never exact-match a HANDOFF marker (extract_block uses `$0==`), and the IMP-4 framing line covers prose injection. Adding the marker-defang the other harvesters have is uniformity polish, not a fix — YAGNI. Documented here so it isn't re-litigated.

### Explicitly not doing (ponytail)

- Backing off the Stop-hook token scan (runs each turn ≥8 msgs until threshold) — the T1 fix makes each scan one spawn; a backoff mechanism would cost more code than it saves.
- read-once TTL/diff-mode tuning — config knobs already exist (`READ_ONCE_*` env vars).
- Any restructuring of slug detection duplication — deliberate per-script self-containment, documented convention.

## Execution order

0. **Merge first (Sam's call):** run `superpowers:finishing-a-development-branch` for `dev/handoff-clear-continue` (PR/merge with Sam's sign-off), then create a fresh fix branch off main for everything below.
1. **Finish the graphify build.** The three extraction agents completed but plan mode blocked their chunk-JSON writes; their JSON is preserved in the agent outputs (chunk 3 confirmed complete — 55 nodes/85 edges incl. the full handoff-lib call graph). At execution: write the three chunk files from the agent results (SendMessage each agent to re-write, or re-dispatch), then merge → build → cluster → label → HTML + GRAPH_REPORT.md.
2. **B4 empirical validation first** (no code until evidence): live TaskCreate/TaskUpdate → grep this session's transcript → pipe through `harvest_tasks`. Fix jq + fixture only if the shape differs.
3. **Apply B1, B2, B3, H1, T1** — five small diffs, one commit each or one batched commit (all in `hooks/`).
4. **Tests**: extend `tests/handoff-lib-test.sh` with a T1 regression case (transcript whose last usage line is >1 line from the tail); run the full suite (`bash tests/handoff-lib-test.sh`, baseline PASS=80). For B1/B2/H1 add the minimal assert-style checks in the same suite style. Do NOT run `tests/hook-validation.sh` with the live slug (clobbers real staging) — use a throwaway slug.
5. **Gates** (Sam's pipeline): `/simplify` → `/security-review` → fix flagged → commit.
6. Stop before merge — `finishing-a-development-branch` needs Sam's sign-off.

## Files touched

| File | Change |
|------|--------|
| `hooks/session-start.sh` | B1 numeric guard on `.last-dream`; H1 jq guard in emitter |
| `hooks/read-once/hook.sh` | B2 sha1 cache key |
| `hooks/stop-memory.sh` | B3 nudge message merge |
| `hooks/handoff-lib.sh` | T1 single-jq `read_live_tokens`; B4 only if live shape differs |
| `tests/handoff-lib-test.sh` | regression cases for T1 (+ B4 fixture if shape changes) |

## Verification

- `bash tests/handoff-lib-test.sh` — all existing PASS plus new cases.
- Manual hook smoke with throwaway HOME: `echo '{"source":"startup"}' | HOME=$(mktemp -d) bash hooks/session-start.sh` with a garbled `.last-dream` seeded — must still emit context (B1/H1).
- read-once: invoke `hook.sh` twice with a fabricated stdin payload naming a path with an accented character — second call must return the "already in context" decision, no non-zero exit (B2).
- B4: real-transcript pipe shows the throwaway task with correct `[x]`/`[~]` symbol.
