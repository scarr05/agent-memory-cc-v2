# Memory System Review Fixes — Design

**Date:** 2026-07-03
**Branch:** `dev/review-fixes-2026-07` (stacked on `dev/handoff-clear-continue`, unmerged per Sam's keep-as-is decision)
**Source of requirements:** `docs/superpowers/plans/2026-07-02-memory-system-review-fixes.md` (approved review findings)

## Goal

A bulletproof, token-efficient memory system. Five hook bugs/hardenings fixed, one dead
harvester deleted. Motivated by the elevated-token observation on v3.0; T1 is the
concrete token win (collapses up to 100 jq spawns per Stop-hook scan to one).

## Changes

| ID | File | Change |
|----|------|--------|
| B1 | `hooks/session-start.sh:281-284` | Validate `.last-dream` content is numeric after the read (`[[ "$LAST_DREAM" =~ ^[0-9]+$ ]] \|\| LAST_DREAM=0`); drop the `\|\| LAST_DREAM=0` clobber on the `read` itself (it discarded a value that WAS read when the file lacks a trailing newline). A garbled scratch file no longer kills the whole hook under `set -euo pipefail` |
| B2 | `hooks/read-once/hook.sh:62` | Cache key = `sha1sum` of the path: `CACHE_KEY=$(printf '%s' "$FILE_PATH" \| sha1sum \| cut -d' ' -f1)` — fixed 40-char filename, safe for non-ASCII and >NAME_MAX paths. Delete the base64 fallback chain. `sha1sum` ships with Git Bash |
| B3 | `hooks/stop-memory.sh:75-86` | In the awk END block, merge the 15/30-count nudge and the 45-min duration nudge (`" \| "` join) instead of the duration message overwriting the count message when both fire on the same turn |
| B4 | `hooks/handoff-lib.sh:63-111` + callers | **Delete** `harvest_tasks()`, the TASKS block emit in `build_deterministic_handoff`, the OPEN_TASKS extraction in `hooks/session-start.sh:191-193`, and the fixture/asserts in `tests/handoff-lib-test.sh`; update doc references to the TASKS block (`CLAUDE.md`, `docs/hooks-architecture.md`, command docs) in the same diff. See evidence below |
| H1 | `hooks/session-start.sh:28-38` | `command -v jq >/dev/null \|\| { printf '%s\n' "$out"; exit 0; }` at the top of `emit_context_and_exit` — plaintext stdout is the documented fallback channel; a machine without jq degrades instead of injecting nothing |
| T1 | `hooks/handoff-lib.sh:117-130` | Replace the per-line `while read`/jq loop in `read_live_tokens` with a single pass: `tail -n 100 "$t" \| jq -rs '[.[] \| .message.usage \| select(.) \| ((.input_tokens//0)+(.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0)) \| select(. > 0)] \| last // 0'`. One jq spawn instead of up to 100 (~30–50ms each on Git Bash) on the Stop hot path. Numeric guard stays in callers |

## B4 evidence (validated live, 2026-07-03)

`harvest_tasks` has never emitted anything on a real transcript. Both assumed field
paths are wrong:

| Event | Assumed by the jq | Actual live shape |
|-------|-------------------|-------------------|
| Create→id link | top-level `.taskId` on the tool_result content item | no such field anywhere in `message.content`; the user entry carries entry-level `.toolUseResult.task.{id,subject}` |
| Update | `.input.id` | `.input.taskId`; the user entry carries `.toolUseResult.{taskId,statusChange:{from,to}}` |

Piping this session's live transcript through `harvest_tasks` produced empty output —
the silently-empty failure the review predicted.

Deletion rather than repair, because the block duplicates native behaviour:

- The TASKS block is only injected on `source == "clear"` (`session-start.sh:184`),
  i.e. the same CLI process.
- Native task state persists across `/clear` within a CLI process
  (`~/.claude/tasks/session-<id>/N.json`, one JSON file per task with final
  `{id, subject, status, blocks, blockedBy}`), and the harness surfaces the full task
  list to the fresh session unprompted. Demonstrated live: tasks created before the
  previous `/clear` were listed in this session with numbering continued.
- Reading the task store from a hook is not viable: the `session-*` directory name
  matches nothing a hook receives (not the transcript UUID, not
  `CLAUDE_CODE_SESSION_ID`), so there is no reliable discovery path.

**Ceiling (recorded as a `ponytail:` comment at the deletion site):** if a future
harness version stops persisting tasks across `/clear`, re-add a harvester reading the
entry-level `.toolUseResult` fields — the live shapes are recorded in the table above.
The transcript JSONL format is not formally versioned; `toolUseResult` is
undocumented harness-internal, which is a further reason not to keep code coupled to
it when the native store does the job.

## Testing

Extend `tests/handoff-lib-test.sh` (same assert style, run via
`bash tests/handoff-lib-test.sh`):

- **T1 regression:** transcript fixture whose last usage-bearing line is more than one
  line from the tail (trailing `type:system` lines) — `read_live_tokens` must still
  return the correct total; and a no-usage fixture must return 0.
- **B1:** seed a garbled (non-numeric / no-trailing-newline) `.last-dream` into a
  throwaway `HOME`, run the real entrypoint
  (`echo '{"source":"startup"}' | HOME=$(mktemp -d) bash hooks/session-start.sh`) —
  must exit 0 and emit context.
- **B2:** invoke `hooks/read-once/hook.sh` twice with a fabricated stdin payload
  naming a path containing an accented character — second call returns the
  already-in-context decision, no non-zero exit.
- **H1:** run the emitter path with jq shadowed off `PATH` — plaintext context on
  stdout, exit 0.
- **B4:** delete the harvest_tasks fixture and asserts; the suite must still pass with
  the TASKS plumbing gone.

Real-entrypoint testing under `set -euo pipefail` is mandatory (2026-06-16 vault
learning: the `/simplify` and `/security-review` gates each caught a bug that
sourced-function tests missed). Never run `tests/hook-validation.sh` against the live
slug — throwaway slug or temp `HOME` only.

## Non-goals (decided; not to be re-litigated)

- **T2 — `harvest_files` marker-defang:** structurally safe. Every output line is
  prefixed `- <count> `, so a crafted path can never exact-match a HANDOFF marker
  (`extract_block` uses `$0==`), and the IMP-4 framing line covers prose injection.
  Uniformity polish, not a fix.
- **Stop-hook token-scan backoff:** T1 makes each scan a single spawn; a backoff
  mechanism costs more code than it saves.
- **Slug-detection deduplication:** deliberate per-script self-containment, documented
  convention.

## Error handling

All fixes preserve the silent-fallback convention (`|| true` on optional paths).
B1 and H1 specifically convert fatal hook exits into degraded-but-working behaviour —
the failure mode being eliminated is "one bad byte or missing binary silently disables
the memory system".

## Verification

- `bash tests/handoff-lib-test.sh` — all existing PASS plus the new cases.
- Manual smoke per the Testing section (B1/H1 garbled-file and no-jq runs, B2
  accented-path double-read).
- Gates: `/simplify` → `/security-review` → fix anything flagged → commit. Merge only
  with Sam's sign-off via `superpowers:finishing-a-development-branch`.
