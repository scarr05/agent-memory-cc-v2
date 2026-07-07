# Handoff Harvest — Token-Bug Fixes (extract_block overflow + drop polluted decisions harvest)

**Date:** 2026-06-19
**Status:** Approved (design) — revised after codex adversarial review
**Branch:** `dev/handoff-clear-continue`
**Amends:** `2026-06-15-handoff-clear-continue-design.md` — hardens its `extract_block` parser, enforces the block-content constraint at finalize, and removes the `harvest_decisions` auto-harvest (the section and its `/memory-sync` consumers). No change to the handoff workflow itself.
**Follow-up (parked):** Task\* harvest + native restore (task #9) — depends on the hardened `extract_block` shipped here.

### Revision log

- **r1 (initial):** Bug #1 parser hardening + Bug #2 `harvest_decisions` filter-tightening.
- **r2 (this — post-codex):** codex adversarial review found the Bug #2 filter still leaks 6 of 15 polluted lines in the real R2 oracle (the long, decision-looking prose), and that the Bug #1 "safe fail" claim rested on a documented-but-unenforced content constraint. Resolutions: **Bug #2 → drop the auto-harvested section entirely** (Sam's call; the harvest has produced zero real decisions and only pollution in the one real sample, and the manual Do-Not-Redo block is authoritative). **Bug #1 → add a deterministic defang pass at `finalize_handoff`** so a filled body can never be mistaken for a section boundary, converting the constraint from documented to enforced. Codex's fence / markdown-prefix / JSON-heuristic findings are dissolved (no filter remains).

## Problem

A token-footprint diagnosis of the live memory system (run 2026-06-19 against the R1/R2 token-tax transcripts) found two bugs in the handoff harvest that inflate the context injected into every post-`/clear` session. Neither is a large share of the ~53k post-`/clear` floor — that floor is ~84% CC framework overhead, which we do not control — but both are real, both degrade the handoff *signal*, and one roughly **doubles** the memory system's own injection.

**Bug #1 — `extract_block` overflows to EOF when the `:END` marker is missing (~734 tok/session).**
`build_deterministic_handoff` (`hooks/handoff-lib.sh:200–212`) writes both `<!-- HANDOFF:NARRATIVE:START -->` and `<!-- HANDOFF:NARRATIVE:END -->`. But the `/handoff` Step-3 fill edit intermittently drops the `:END` line (the R1 consumed handoff kept it; the R2 one — `~/.claude/memory-staging/memory-architecture/handoff.consumed.md` — has `:START` at line 14 and **no `:END`**). `extract_block` (`hooks/handoff-lib.sh:116–124`) is:

```awk
{sub(/\r$/,"")} $0==s {f=1; next} $0==e {f=0} f
```

With no `:END`, `f` never resets, so it prints from `:START` to end-of-file — dragging Do-Not-Redo, Git State, Files Touched, Open TODOs, **and the polluted Tagged-Decisions section** into what `SessionStart(clear)` injects as the "narrative". Measured: the R2 injection was 6,264 chars (~1,566 tok) vs an intended narrative-only ~832 tok.

**Bug #2 — `harvest_decisions` harvests skill-doc fragments as "decisions" (~482 tok/session when present).**
`harvest_decisions` (`hooks/handoff-lib.sh:67–80`) greps *all* user-role text for decision phrases (`wrong`, `incorrect`, `always use`, `CORRECTED:`, …). When the `claude-api` skill doc was in-context during the `/handoff` capture, its SDK code and doc fragments matched and were harvested. The entire Tagged-Decisions section of the R2 handoff (lines 38–53, ~1,929 chars / ~482 tok) is `claude-api` noise — **not one real project decision** — and is currently injected on every post-`/clear` start (compounded by Bug #1).

A precision-tightening filter was prototyped (r1) and then traced line-by-line against the R2 oracle: it removes the nine short *code/JSON/comment* fragments but **6 of 15 lines survive** (39, 40, 44, 50, 51, 53 — all plain prose containing a trigger word such as `wrong`, `incorrect`, `switch to`, `actually`). Those survivors are the long, decision-*looking* lines — exactly the ones that mislead a fresh agent. A regex denylist has no clean discriminator for prose that reads like a decision, so the filter only ever half-fixes the harm.

**Why fix, given the floor barely moves:** signal quality. Bug #1 makes the injected "narrative" four sections long; Bug #2 misleads the fresh agent about what was decided. The handoff is a continuation tool — garbage in the narrative is the worst place for it. Bug #1's hardened parser is also a **prerequisite** for the parked Task\* work, which adds a third marked block that would inherit the identical fragility.

## Solution

1. **Harden `extract_block`** so a block can never overflow its own `##` section, even with the `:END` marker gone (deterministic; does not depend on the fill edit behaving).
2. **Enforce the block-content constraint** at `finalize_handoff`: defang any `## `- or `<!-- HANDOFF:`-leading line inside the filled narrative / do-not-redo body, so the hardened parser cannot mistake filled content for a section boundary. The `commands/handoff.md` Step-3 instruction is kept as defence in depth.
3. **Drop the `harvest_decisions` auto-harvest entirely** — remove the `## Tagged Decisions / Corrections` section from the assembled handoff, delete the dead function, and re-point its two `/memory-sync` consumers at clean sources.

All changes live in `hooks/handoff-lib.sh`, `commands/handoff.md`, `commands/memory-sync.md`, and `tests/handoff-lib-test.sh`. No change to hook registration, the handoff lifecycle, or any other component.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bug #1 primary fix | Deterministic parser hardening (`extract_block`), not a fill-time instruction | "Deterministic over agentic where reliability matters." The parser must be correct even when the LLM fill drops the marker — which it demonstrably does, intermittently. |
| Fallback boundary | Next `## ` heading **or** any `<!-- HANDOFF:` marker line, else EOF | Every *assembler-emitted* section begins with a `## ` heading, so this bounds any block to its own section. The `<!-- HANDOFF:` clause catches a following block's `:START`. One fix covers NARRATIVE, DONOTREDO, and the future TASKS block. |
| Block-content constraint | Filled narrative / Do-Not-Redo body must not be read as a section boundary | **Enforced, not just documented.** `finalize_handoff` defangs any `## `- or `<!-- HANDOFF:`-leading body line before arming (reusing the marker-defang at `handoff-lib.sh:148`). This closes codex's finding that a truncated-but-≥40-char body would otherwise arm with silently incomplete content. The `handoff.md` instruction stays as defence in depth. |
| Bug #1 secondary fix | `handoff.md` Step 3: replace only the `<!-- HANDOFF:NARRATIVE -->` sentinel; never touch `:START`/`:END` | Reduces how often the marker is dropped; the parser + defang make correctness independent of it. |
| Bug #2 approach | **Remove the auto-harvest**, not tighten it | Codex verified the tightened filter still leaks 6/15 polluted lines (the long decision-looking prose). In the one real sample the harvest produced **zero** genuine decisions and fifteen pollution lines; the manual Do-Not-Redo block in that same handoff was clean and authoritative. A best-effort supplement that has never delivered signal and reliably delivers plausible noise is not worth half-fixing. |
| `/memory-sync` fingerprint | Use the `## Files Touched` list alone | File-list overlap is already the documented effort-matcher (`memory-sync.md:67`); the decision lines were supplementary and are gone. |
| `/memory-sync` correction-routing | Re-point at the manual **Do-Not-Redo** block | Direction-change corrections live in Do-Not-Redo ("Do NOT trust X — verified Y"). It is clean and authoritative, so routing its correction-flavoured lines into `learnings/corrections/` keeps that feature working off a real source. `/decision` and `--dream` remain the other capture channels. |
| Scope | Bug #1 + Bug #2 (drop) only | Task\* harvest + native restore is parked (task #9), ordered *after* this since it depends on the hardened `extract_block`. |

## Architecture

### Bug #1 — hardened `extract_block`

Replace the parser at `hooks/handoff-lib.sh:116–124` with:

```awk
awk -v s="<!-- HANDOFF:${name}:START -->" -v e="<!-- HANDOFF:${name}:END -->" '
    {sub(/\r$/,"")}                          # CRLF tolerance (unchanged)
    $0==s                              {f=1; next}   # enter block on START
    f && $0==e                         {exit}        # normal: stop at END
    f && (/^## / || /^<!-- HANDOFF:/)  {exit}        # fallback: stop at next section/marker
    f                                              # print body lines
' "$file"
```

Behaviour:

- **`:END` present (normal):** byte-identical to today. The current parser already suppresses the `:END` line, because `$0==e {f=0}` fires *before* the trailing bare `f` print pattern on that line; swapping `f=0`→`exit` therefore changes only post-`:END` scanning, not a single emitted byte for a unique block.
- **`:END` missing:** prints the body, then stops at the next `## ` heading (e.g. `## Do-Not-Redo`) or `<!-- HANDOFF:` marker instead of running to EOF. Overflow is bounded to at most the section's own content.
- **Unfilled sentinel (fail-safe):** on an unfilled handoff the body is the bare sentinel `<!-- HANDOFF:NARRATIVE -->`. `extract_block` sets `f=1` on `:START`; the very next line is the sentinel, which matches the `/^<!-- HANDOFF:/` fallback boundary and triggers `exit` *before printing* — so the extract is empty, and `finalize_handoff` (`hooks/handoff-lib.sh:255–261`) aborts arming via its `length < 40` guard. The fail-safe is preserved, now via the boundary clause rather than run-to-`:END`.

`exit` (vs `f=0`) is safe because block names are unique — there is only ever one block per name to extract.

Why not `## `-only or marker-only: a marker-only boundary would not contain a missing `DONOTREDO:END`, because Git State / Files Touched / Open TODOs carry no `<!-- HANDOFF:` markers — overflow would still reach EOF. The `## ` heading clause is what actually bounds every section; the marker clause is defence in depth.

### Bug #1 — finalize-time enforcement (defang)

The manual narrative / do-not-redo are filled *in-context* by Claude after `build_deterministic_handoff` runs, so they cannot be defanged at build time (the build only writes a sentinel). `finalize_handoff` is the gate before arming and already reads and rewrites the file. Add a defang pass there, scoped to `source == handoff` and run **after** the fill guard passes (so it never sees the sentinel):

- A stateful awk tracks whether the current line is inside the NARRATIVE or DONOTREDO block *body* (between that block's `:START` and `:END`).
- For body lines only — never the structural `:START`/`:END` markers — any line beginning `## ` or `<!-- HANDOFF:` is rewritten by prefixing a single space, so the hardened `extract_block` no longer reads it as a section boundary.
- Normal narratives (3–5 prose sentences, do-not-redo bullets starting `- `) contain no such lines, so the pass is a no-op in the common case — no behavioural change there.
- **Note (post-implementation):** matching is CR-normalised; gawk in text mode (this repo's Windows/Git-Bash platform) strips a trailing CR on read, so this pass LF-normalises the file when it runs. That is harmless — every downstream reader is CR-tolerant, and the `supersedes` awk below already does the same.

This is the manual-path analogue of the marker-defang already applied to the compaction summary at `hooks/handoff-lib.sh:148`. Together with the hardened parser it converts the block-content constraint from "documented in `handoff.md`" to "enforced in code", closing codex's PT1/PT4/PT5 findings.

The auto-fallback paths need no finalize defang: `compact-fallback` content is already defanged at build (`:148`), and the `clear` / auto-`clear` notes are fixed strings with no markers.

### Bug #1 — fill-time preservation (`commands/handoff.md` Step 3)

Add an explicit instruction: when filling the narrative, replace **only** the `<!-- HANDOFF:NARRATIVE -->` sentinel line; leave `<!-- HANDOFF:NARRATIVE:START -->` and `<!-- HANDOFF:NARRATIVE:END -->` untouched. Same for Do-Not-Redo. Note the content constraint (no `## ` headings or `<!-- HANDOFF:`-leading lines inside the body) — now backed by the finalize defang, so a slip degrades gracefully rather than truncating.

### Bug #2 — remove the auto-harvested decisions section

In `build_deterministic_handoff` (`hooks/handoff-lib.sh:223–224`), delete the `## Tagged Decisions / Corrections` heading and the `harvest_decisions < "$win"` call. The last assembled section becomes `## Open TODOs`. Delete the now-dead `harvest_decisions` function (`hooks/handoff-lib.sh:67–80`). `window_transcript`, `harvest_files`, and `harvest_todos` still read `$win`, so the window is unchanged.

Re-point the two `/memory-sync` consumers:

- **`commands/memory-sync.md:65` (fingerprint):** drop the `## Tagged Decisions / Corrections` clause; the effort fingerprint is the `## Files Touched (this work unit)` list (already the matcher per `:67`).
- **`commands/memory-sync.md:185` (correction-routing):** source direction-change corrections from the handoff's **Do-Not-Redo** block instead of the removed section — the clean, authoritative channel. The "new since prior `.consumed`" diff logic is unchanged; only the section it reads moves.

### What does *not* change

`session-start.sh`, `stop-memory.sh`, `session-end.sh`, `pre-compact.sh`, `read-once`, `prompt-corrections.sh`, `memberberry`, hook registration, frontmatter, the `harvest_todos` Task\*/TodoWrite gap (parked task #9), and the handoff lifecycle are all untouched. `session-start.sh`'s `clear` branch keeps calling `extract_block NARRATIVE` exactly as today — it simply gets a correctly-bounded result.

## Delta vs the existing build

| Action | Component | Detail |
|--------|-----------|--------|
| Modify | `hooks/handoff-lib.sh` `extract_block` (116–124) | Add `## `/`<!-- HANDOFF:` fallback boundary + `exit`-on-end. |
| Modify | `hooks/handoff-lib.sh` `finalize_handoff` (239–275) | After the fill guard (source==handoff), defang `## `/`<!-- HANDOFF:`-leading lines inside the narrative/do-not-redo body. |
| Remove | `hooks/handoff-lib.sh` `harvest_decisions` (67–80) | Dead after the section is dropped. |
| Modify | `hooks/handoff-lib.sh` `build_deterministic_handoff` (223–224) | Delete the `## Tagged Decisions / Corrections` heading + `harvest_decisions` call. |
| Modify | `commands/handoff.md` Step 3 | Instruction: replace only the sentinel, preserve `:START`/`:END`; note the content constraint (now defang-enforced). |
| Modify | `commands/memory-sync.md` (65, 185) | Fingerprint = Files Touched only; correction-routing reads the Do-Not-Redo block. |
| Modify | `tests/handoff-lib-test.sh` | Remove the `harvest_decisions` unit test (59–61); update build-CLI assertions (143, 151) from "Tagged Decisions is the last section" to "Tagged Decisions absent; Open TODOs is the last section". Add the new Bug #1 fixtures below. |
| Unchanged | all hooks, registration, lifecycle, `harvest_todos`, other harvesters | — |

## Testing / verification gates

Fixtures in `tests/handoff-lib-test.sh` (Tier-1 scripted):

1. **Missing `:END`** — a handoff body with `NARRATIVE:START`, body text, then `## Do-Not-Redo` and no `NARRATIVE:END`. Assert `extract_block NARRATIVE` returns only the body, stopping before `## Do-Not-Redo` (not EOF).
2. **Normal `:START`/`:END`** — assert byte-identical output to the current parser (regression guard).
3. **Finalize defang** — a filled narrative whose body contains a line starting `## ` and a line starting `<!-- HANDOFF:`. After `finalize_handoff`, assert both are space-prefixed in the file *and* `extract_block NARRATIVE` returns the whole body (no truncation), and that the `:START`/`:END` markers are intact.
4. **Unfilled handoff still aborts** — build a manual handoff, do not fill the sentinel, run `finalize_handoff`; assert it aborts (the defang never runs because the guard fires first).
5. **Section dropped** — build via the CLI (both `handoff` and `compact-fallback` sources); assert the assembled file contains no `## Tagged Decisions / Corrections` heading and that `## Open TODOs` is the final section.

Plus a manual check that a real `/handoff` → `/clear` cycle injects the narrative *only* (not the trailing sections, no decisions section), confirming the end-to-end fix against the bug's original symptom.

## Out of scope (YAGNI)

- **Task\* harvest + native restore** — parked (task #9); ordered after this because it depends on the hardened `extract_block`.
- **Re-introducing a cleaner decisions harvest** — corrections are captured by the manual Do-Not-Redo block, `/decision`, and `--dream` (transcript mining, approval-gated). No automated phrase-grep is reinstated.
- **Widening the harvest window for task events across an in-session `/compact`** — consistent with all other harvesters staying windowed.
