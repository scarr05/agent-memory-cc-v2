# Handoff → Clear → Continue — Conversation Capture Redesign

**Date:** 2026-06-15
**Status:** Approved (design)
**Branch:** `dev/v4-schema-fixes` (or a fresh `dev/handoff-workflow` cut after v4 merges)
**Supersedes:** the PreCompact checkpoint-stub mechanism from the v2/v3 design
**Revisions:** 2026-06-15 — codex review folded in: structural (jq) compaction-boundary detection, comment-marker narrative parsing (replaces the em-dash-header coupling), transcript-path persistence for `/handoff` resolution, quoted YAML frontmatter, and fail-loud on a missing harvest library. A second adversarial codex pass added: ambiguity-gate-first transcript resolution (the per-slug breadcrumb can name a concurrent same-repo session), CRLF-tolerant marker parsing, temp-file (not in-memory) window streaming, an exact-sentinel thin-guard, and awk-based supersedes stamping.

## Problem

The pre-compaction checkpoint mechanism does not work, and it was built for a context-window era that no longer matches how the system is used.

**Broken:**

1. **Checkpoint stubs are never filled.** `pre-compact.sh` writes an empty stub with `[To be filled by blackbox or Claude]` placeholders; filling depends on Claude voluntarily delegating to blackbox at the next `SessionStart(compact)`. Evidence: **every stub ever written was unfilled** — all `status: pending` with placeholder bodies (64 observed at investigation, 62 still present at purge time). All were removed on 2026-06-15 as part of this work.
2. **Stubs accumulate unbounded.** Nothing cleans them except `/memory-sync` Step 6, so any compaction in a session that ends without a sync leaves a permanent stub. They piled up — **29 in `aws-landing-zone`** alone — and re-surface as "ACTION REQUIRED" / "Pending Checkpoints" on every future start, where Claude dutifully writes empty placeholder notes into the vault.
3. **Contradictory directives.** `SessionStart(compact)` says "fill the stubs via blackbox NOW"; `/memory-sync` Step 6 says "they're superseded — delete them." Both target the same files; nothing says which wins, so the agent has to author the resolution at runtime.
4. **The proactive capture threshold is dead.** The global instruction triggers a blackbox capture at "~50%" context — calibrated for a 200k window (~100k). On a 1M window that is 500k, and Sam compacts manually at ~150–200k, so it never fires. The only path that could preserve *pre*-compaction detail is unreachable.

**Architectural reality:** the PreCompact stub claims to preserve context compaction destroys, but it is created empty *before* compaction (hooks cannot invoke subagents) and can only be filled *after*, by which point the detail is already gone.

**Usage reality (from transcripts):** Sam runs a 1M window, compacts manually in the 102k–214k band (100% `trigger:manual`), or starts fresh. He wants to *avoid* relying on compaction: run a deliberate `/handoff`, `/clear`, then continue in a fresh session that picks the work back up. Capture must be efficient *and* useful, split System‑1 (working scratch) vs System‑2 (vault), with `/memory-sync` deduplicating long‑running summaries and capturing corrections on direction changes.

## Solution

Replace the empty-stub mechanism with a deliberate **handoff scratch file**, captured ~90% deterministically from the transcript with a single focused LLM call for the irreducible narrative, windowed to the *current* work unit. The workflow is:

**`/handoff`** (one command, does all capture and arms pickup) → **`/clear`** (one CLI keystroke; cannot be automated) → fresh session **auto-loads** via `SessionStart(source=clear)` injection.

A bare `/clear` without `/handoff` is caught by `SessionEnd(reason=clear)`, which deterministically harvests a fallback handoff if none is armed. Auto-compaction stays on as a dormant safety net; if it ever fires, `SessionStart(source=compact)` harvests CC's own `isCompactSummary` summary through the same code path.

This is the recommended graft from the design workflow: **Design C's deterministic harvester** as the spine, **windowed** to fix C's cumulative-dump flaw, with **Design A's** minimal-migration discipline and **Design B's** refuse-to-arm-an-empty-handoff guard.

**Doc-verification rule:** before building, the implementing agent MUST empirically verify the three items in *Verification Gates* below and record findings in implementation notes. A silent injection no-op leaves the fresh session blind — the worst failure mode for a continuation tool.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| One-command flow | **Not possible.** `/handoff` + `/clear` keystroke + auto-pickup | `/clear` is CLI-core; no API to invoke or chain it from inside a session. Confirmed by research + all three critics. |
| Capture engine (primary) | Deterministic harvest (jq/git) + **one** focused LLM call for the narrative | Matches Sam's determinism preference; ~90% zero-LLM. Highest token-efficiency of the three designs. |
| Capture engine (fallback) | `SessionStart(compact)` harvests CC's `isCompactSummary` summary | Zero LLM; makes auto-compaction a real safety net on a shared code path. |
| Scratch scope | **Current work unit only**, windowed to entries after the last compaction boundary | Honours the System‑1 "current work" model; avoids reproducing the cumulative dump. |
| Scratch location | `~/.claude/memory-staging/<slug>/handoff.md` (HOME) | Consistent with existing staging; outside every repo tree; no gitignore needed. Survives `/clear`. |
| Bare-`/clear` guard | `SessionEnd(reason=clear)` auto-harvests a fallback handoff if none armed | A bare `/clear` never silently loses the thread; matches the safety-net stance. |
| Handoff ↔ sync | **Strictly separate.** No `/handoff --sync` | Preserves the System‑1 (fast) / System‑2 (slow) split; avoids cumulative-dump creep. Add later if needed (YAGNI). |
| Single-slot scratch | One file per slug, overwritten each `/handoff`; auto-harvest only writes if no active manual handoff exists | Prevents an auto-harvest clobbering a good manual handoff. |
| Empty-handoff guard | Refuse to arm if the scratch is empty/thin | A rushed `/handoff` must not arm a confidently-wrong blank. |
| Proactive threshold | ~150k live tokens via a Stop-hook nudge, **configurable** (`memory.handoffTokenThreshold` in settings.json), default 150k | The ~50%/500k threshold never fired; projects off a 1M window need a different value. |
| Autocompact | Stays ON, dormant safety net | On a 1M window it only fires near ~950k; Sam hands off at ~150k. Removing wall-risk for free. |
| blackbox | Retired from the critical path; kept for explicit "save progress" | The deterministic harvester replaces its PreCompact role. |
| Stale stubs | Purged (62 removed 2026-06-15) | Inert cruft the new design removes anyway. |

## Architecture

### The handoff scratch file

**Path:** `~/.claude/memory-staging/<slug>/handoff.md`, single-slot, overwritten each `/handoff`.

**Frontmatter (deterministic):**

```yaml
---
slug: <project-slug>
branch: <git branch>
created: <ISO datetime>
source: handoff | compact-fallback | clear-fallback
live_tokens: <int>
consumed: false
supersedes: <prior handoff id, or "">   # for /memory-sync chain dedup
---
```

All string scalars are emitted double-quoted, so a branch name containing `/`, `:`, `#`, `[` or a leading `*` cannot corrupt the YAML. Readers strip the surrounding quotes.

**Deterministic layer (jq/git, zero LLM):**

- **Git state** — branch, dirty-file count, last 3 commits.
- **Files touched this work-unit** — frequency table from `Edit`/`Write`/`MultiEdit`/`NotebookEdit` `tool_use` entries, *windowed* (see below).
- **Harvested compaction summary** — only on the `compact-fallback` path (`isCompactSummary` content).
- **Tagged decisions / corrections** — regex-tagged with the same pattern table `/memory-sync --dream` uses, after stripping slash-command wrapper noise. Must handle polymorphic user-message `content` (bare string, `["text"]`, `["tool_result"]` all occur) or it silently drops corrections issued as plain prompts.
- **Open TODOs** — from `TodoWrite` entries (last array wins), else tagged "next step" lines.

**LLM layer (one focused call — the only agentic step):**

- **Current Work — Narrative** (3–5 sentences): what we are mid-way through *right now*, why, and the **exact next action** (file + line + intent) a fresh agent should take first.
- **Do-Not-Redo**: dead ends already ruled out, so the fresh agent does not repeat them.

Both blocks are delimited by `<!-- HANDOFF:NARRATIVE:START -->`/`<!-- HANDOFF:NARRATIVE:END -->` and `<!-- HANDOFF:DONOTREDO:START -->`/`<!-- HANDOFF:DONOTREDO:END -->` comment markers. Every reader (the thin-guard in `finalize_handoff` and both SessionStart branches) extracts content between these markers via one shared `extract_block` helper, so parsing never depends on the human-readable `## Current Work — Narrative` header. `extract_block` strips a trailing CR before matching, so the markers survive CRLF line endings (Windows editors, or jq-written content which carries CR on Windows). The thin-guard matches the exact collapsed fill sentinel `<!--HANDOFF:NARRATIVE-->`, not a bare substring, so a real narrative that merely mentions the token still arms.

**Lifecycle:** written by `/handoff` (or a fallback harvest) → survives `/clear` → injected by `SessionStart(clear)` under a "RESUMING FROM HANDOFF" header → renamed `handoff.consumed.md` (idempotent: a second `/clear` will not re-inject stale state) → deleted by `/memory-sync` after consolidation.

### Transcript windowing

The scratch reflects the **current work unit only**. The harvester slices transcript entries to those *after the most recent `compactMetadata` boundary* in the active transcript file. Boundary detection is **structural**, not a raw substring match: a cheap `grep` prefilter finds candidate lines, then each candidate is confirmed with `jq` to carry a *top-level* `compactMetadata` key, so the token appearing nested inside ordinary tool output is never mistaken for a boundary. If there is no compaction in the file, the whole file is the current unit (a fresh post-`/clear` session is already a new transcript). This is the make-or-break for the System‑1 model — without it, a long multi-day/branch transcript reproduces the cumulative dump the design forbids.

### `/handoff` command flow

1. Locate the active transcript. `CLAUDE_SESSION_ID` is **unset** in the command's Bash env (confirmed empirically) and the `.transcript-path` breadcrumb is shared per-slug, so the **ambiguity guard runs first**: if ≥2 transcripts under the encoded-cwd dir were modified in the last 2 minutes, two same-repo sessions are active — refuse and let the user disambiguate rather than risk harvesting the wrong one (a recently-written breadcrumb could name the *other* session). Only when unambiguous, pick: (a) the `.transcript-path` breadcrumb the Stop/SessionStart hooks persist each turn (authoritative for a single active session); (b) `~/.claude/projects/<encoded-cwd>/$CLAUDE_SESSION_ID.jsonl` if the env var is ever populated; (c) newest `*.jsonl`. If none resolves, refuse to write a blind handoff.
2. Window the transcript (above).
3. Build the deterministic layer (jq/git).
4. One focused LLM call writes the narrative + do-not-redo.
5. Empty/thin guard — refuse to arm if there is nothing substantive.
6. Write `handoff.md`, stamp `supersedes` from any prior `handoff.consumed.md`.
7. Tell Sam it is armed and to `/clear`.

### SessionStart behaviour

| source | Behaviour |
|--------|-----------|
| `clear` | If `handoff.md` (unconsumed) exists, inject it under a "RESUMING FROM HANDOFF" header via `additionalContext`; rename to `.consumed`. Else slim output as today. |
| `compact` | Harvest CC's `isCompactSummary` from the transcript into a `compact-fallback` handoff (deterministic, zero LLM); inject it. No blackbox-fill instruction. |
| `startup` / `resume` | Full context build (unchanged). Surface `.unsynced` if present. |

Injection uses `hookSpecificOutput.additionalContext` with the existing `MEMORY_HOOK_PLAINTEXT=1` fallback. If the handoff is large, inject a header + the narrative + a pointer to the full file rather than the entire body.

On every source, SessionStart also persists the `transcript_path` it receives to `<staging>/.transcript-path` (the authoritative breadcrumb `/handoff` reads, since `CLAUDE_SESSION_ID` is unavailable to the command). The `clear`/`compact` branches require the harvest library; if it is missing on those continuation-critical paths, SessionStart **fails loud** — it injects a visible "handoff present but `handoff-lib.sh` not installed" warning rather than silently dropping an armed handoff.

### SessionEnd auto-catch

`session-end.sh` gains a `reason=clear` branch: if no unconsumed `handoff.md` exists, deterministically harvest a `clear-fallback` handoff from the transcript (same windowed deterministic layer, no LLM call) so a bare `/clear` never loses the thread. The existing `.unsynced` logic is unchanged.

### Stop hook token nudge

`stop-memory.sh` gains one token-read branch, **off the hot path**: gate the jq scan behind a cheap message-count pre-check so it only runs near the threshold. It also persists the `transcript_path` it receives to `<staging>/.transcript-path` on every Stop (one tiny jq on a small payload), keeping the `/handoff` breadcrumb current as the session progresses. Read context size from the *last usage-bearing* assistant entry (scan back — `tail -1` returns a `type:system` line with no `usage`, and the nudge would silently never fire). When `live_tokens ≥ memory.handoffTokenThreshold` (default 150k) and not already nudged this session, emit a `systemMessage`: "~150k tokens — consider `/handoff` then `/clear`." Once-per-session flag in `.session-meta`.

### pre-compact.sh

Gut the empty-stub writer. PreCompact becomes a thin breadcrumb (or is removed entirely) — the real capture is the `SessionStart(compact)` harvest. This structurally eliminates the stub accumulation and the `SessionStart(compact)`↔`/memory-sync` contradiction.

### `/memory-sync` changes

Two additions to the System‑1 → System‑2 valve:

- **Dedup overlapping summaries (mandatory).** A long effort produces several chained handoffs across successive clears, each stamped with `supersedes`. A new dedup sub-step walks the `supersedes` chain plus the deterministic file-list/decision sections, collapsing structurally-overlapping handoffs (same file list + same decision lines = overlap) into **one** vault session note for the whole effort, instead of N near-duplicates. Because each `/handoff` overwrites the prior scratch (no stacking) and consolidation matches against the vault before writing, redundancy collapses by construction. *Risk: a missing `supersedes` stamp produces duplicates — the harvester must stamp it reliably from the prior `.consumed` file.*
- **Capture direction-changes.** The scratch's Tagged Decisions/Corrections section is non-empty only when direction shifts; `/memory-sync` routes any not-yet-in-vault correction into `learnings/corrections/` via the existing approval flow, where `prompt-corrections.sh` surfaces it live thereafter. A correction is "new" when a handoff's corrections section differs from the prior's.

**Honest caveat:** the valve's correctness still rests partly on regex tagging plus one in-context narrative fill — not fully deterministic. `--dream` transcript-mining backstops under-reporting; this is the softest spot and is acknowledged rather than papered over.

## Verified Claude Code facts (ground truth)

- Every hook receives `transcript_path`; the full conversation is always on disk as JSONL at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (subagent transcripts under `.../subagents/`).
- Live context size = last assistant entry `.message.usage` → `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`.
- Compaction is two entries: `type:system` with `compactMetadata { trigger: manual|auto, preTokens, postTokens, preservedSegment, preservedMessages }`, and `type:user` with `isCompactSummary:true` whose `message.content` is the summary text ("This session is being continued from a previous conversation…"). `type:"summary"` does **not** exist. Both extractable with jq. Boundary detection must key off the *top-level* `compactMetadata` object structurally (jq-confirmed), not a raw `"compactMetadata"` substring, which can appear nested in tool output. `isCompactSummary` content may sit under `.message.content` or `.content` across versions; the harvester reads either.
- `CLAUDE_SESSION_ID` is **not** exported into the Bash environment of hooks or slash commands (confirmed empirically). Hooks receive the path via the `transcript_path` stdin field instead; the `/handoff` command relies on the persisted `.transcript-path` breadcrumb.
- `SessionStart.source ∈ {startup, resume, compact, clear}`; `source=clear` keeps on-disk files (it wipes conversation memory, touches no files).
- Native `/rewind` exists (file + conversation restore) but is **manual only**, no hook/programmatic API.
- Hooks **cannot** invoke subagents or slash commands; `/clear` cannot be triggered programmatically.
- `additionalContext` injection works in current versions; `MEMORY_HOOK_PLAINTEXT=1` is the documented stdout fallback (#16538).

## Delta vs the existing build

| Action | Component | Detail |
|--------|-----------|--------|
| Reuse | `session-start.sh` | Slug detection, `source` dispatch branch, `additionalContext` emitter + plaintext fallback, git block. Only the injected payload changes; add `clear`/`compact` harvest branches. |
| Reuse | `stop-memory.sh` | awk state-machine + `systemMessage` nudge + once-per-session flag. Add one off-hot-path token-read branch. |
| Reuse | `memory-sync` | All `--dream`/`--ingest`/`--tidy` machinery, by-project vault layout, dedup pattern table. Extended, not rewritten. |
| Reuse | `memberberry`, `prompt-corrections.sh`, `read-once` | Untouched. |
| Replace | `pre-compact.sh` | Gut the empty-stub writer → thin breadcrumb or remove; capture moves to `SessionStart(compact)` harvest. |
| Replace | proactive ~50% / 500k threshold | → configurable ~150k Stop nudge. |
| Replace | "pending checkpoint" vehicle | → single `handoff.md` scratch with a `consumed` lifecycle. |
| Extend | `session-end.sh` | Add `reason=clear` auto-catch harvest. |
| New | `/handoff` command | Deterministic harvest + one LLM narrative call. |
| New | `hooks/handoff-lib.sh` | Shared deterministic harvest library; sourced defensively by the hooks, dispatched as a CLI by `/handoff`. |
| New | `<staging>/.transcript-path` | Breadcrumb persisted by Stop/SessionStart so `/handoff` resolves the transcript without `CLAUDE_SESSION_ID`. |
| Delete | `SessionStart(compact)` blackbox-fill instruction | Removing stubs eliminates the contradiction structurally. |
| Delete | 62 accumulated empty stubs | Done 2026-06-15. |
| Retire | `blackbox` | Off the critical path; kept for explicit asks. |

## Verification gates (before shipping)

1. **Window the transcript** — confirm the post-last-compaction slice on a multi-compaction transcript, and confirm a *nested* (non-top-level) `compactMetadata` key is **not** treated as a boundary; without it, cumulative-dump leakage or a mis-cut window.
2. **Stop token-read off hot path** — benchmark on a large (multi-MB) transcript against the ≤50ms budget; confirm the back-scan finds the last usage-bearing entry.
3. **Post-`/clear` `additionalContext` injection** — empirically confirm the fresh session actually receives it (not a silent no-op); fall back to `MEMORY_HOOK_PLAINTEXT=1` if not.
4. **Transcript resolution for `/handoff`** — `CLAUDE_SESSION_ID` is unset in the command Bash env (confirmed), so verify the `.transcript-path` breadcrumb (persisted by Stop/SessionStart) resolves the exact transcript, and that the recency-guarded newest-jsonl last resort refuses when two sessions are concurrently active.

## Out of scope (YAGNI)

- A literal single command that also clears (impossible).
- `/handoff --sync` coupling.
- A hard block on bare `/clear` (no PreClear hook exists; the `SessionEnd` auto-catch is the mitigation).
- A write-temp → fsync → rename → injection-ack protocol for the scratch file (codex raised it). A Bash hook cannot get an injection acknowledgement from Claude, and for a single-user tool the single-slot no-clobber guard plus the `/memory-sync` sweep of stale `handoff.consumed.md` files is sufficient. Considered and rejected.
