# Handoff Harvest — Token-Bug Fixes (extract_block overflow + decisions pollution)

**Date:** 2026-06-19
**Status:** Approved (design)
**Branch:** `dev/handoff-clear-continue`
**Amends:** `2026-06-15-handoff-clear-continue-design.md` — hardens its `extract_block` parser and `harvest_decisions` filter; no behavioural change to the handoff workflow itself.
**Follow-up (parked):** Task\* harvest + native restore (task #9) — depends on the hardened `extract_block` shipped here.

## Problem

A token-footprint diagnosis of the live memory system (run 2026-06-19 against the R1/R2 token-tax transcripts) found two bugs in the handoff harvest that inflate the context injected into every post-`/clear` session. Neither is a large share of the ~53k post-`/clear` floor — that floor is ~84% CC framework overhead, which we do not control — but both are real, both degrade the handoff *signal*, and one roughly **doubles** the memory system's own injection.

**Bug #1 — `extract_block` overflows to EOF when the `:END` marker is missing (~734 tok/session).**
`build_deterministic_handoff` (`hooks/handoff-lib.sh:200–212`) writes both `<!-- HANDOFF:NARRATIVE:START -->` and `<!-- HANDOFF:NARRATIVE:END -->`. But the `/handoff` Step-3 fill edit intermittently drops the `:END` line (the R1 consumed handoff kept it; the R2 one — `~/.claude/memory-staging/memory-architecture/handoff.consumed.md` — has `:START` at line 14 and **no `:END`**). `extract_block` (`hooks/handoff-lib.sh:116–124`) is:

```awk
{sub(/\r$/,"")} $0==s {f=1; next} $0==e {f=0} f
```

With no `:END`, `f` never resets, so it prints from `:START` to end-of-file — dragging Do-Not-Redo, Git State, Files Touched, Open TODOs, **and the polluted Tagged-Decisions section** into what `SessionStart(clear)` injects as the "narrative". Measured: the R2 injection was 6,264 chars (~1,566 tok) vs an intended narrative-only ~832 tok.

**Bug #2 — `harvest_decisions` harvests skill-doc fragments as "decisions" (~482 tok/session when present).**
`harvest_decisions` (`hooks/handoff-lib.sh:67–80`) greps *all* user-role text for decision phrases (`wrong`, `incorrect`, `always use`, `CORRECTED:`, …). When the `claude-api` skill doc was in-context during the `/handoff` capture, its SDK code and doc fragments matched and were harvested. The entire Tagged-Decisions section of the R2 handoff (lines 38–53, ~1,929 chars / ~482 tok) is `claude-api` noise — not one real project decision — and is currently injected on every post-`/clear` start (compounded by Bug #1).

**Why fix, given the floor barely moves:** signal quality. Bug #1 makes the injected "narrative" four sections long; Bug #2 misleads the fresh agent about what was decided. The handoff is a continuation tool — garbage in the narrative is the worst place for it. Bug #1's hardened parser is also a **prerequisite** for the parked Task\* work, which adds a third marked block that would inherit the identical fragility.

## Solution

Two contained fixes in `hooks/handoff-lib.sh`, plus a one-line instruction in `commands/handoff.md`, plus fixtures in `tests/handoff-lib-test.sh`. No change to the handoff workflow, hook registration, or any other component.

1. **Harden `extract_block`** so a block can never overflow its own `##` section, even with the `:END` marker gone. Deterministic guarantee that does not depend on the fill edit behaving.
2. **Preserve `:END` at fill time** via a `commands/handoff.md` Step-3 instruction — defence in depth, not the load-bearing fix.
3. **Tighten `harvest_decisions`** to strip injected wrappers and exclude code/doc lines, biased toward precision.

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Bug #1 primary fix | Deterministic parser hardening (`extract_block`), not a fill-time instruction | "Deterministic over agentic where reliability matters." The parser must be correct even when the LLM fill drops the marker — which it demonstrably does, intermittently. |
| Fallback boundary | Next `## ` heading **or** any `<!-- HANDOFF:` marker line, else EOF | Every assembled section begins with a `## ` heading, so this bounds *any* block to its own section. The `<!-- HANDOFF:` clause is a bonus (catches a following block's `:START`). One fix covers NARRATIVE, DONOTREDO, and the future TASKS block. |
| Block-content constraint | Narrative / Do-Not-Redo text must not contain a `## ` heading or a line starting with `<!-- HANDOFF:` | The fallback boundary would treat them as section ends. The narrative is 3–5 sentences, so this is safe; documented in `handoff.md`. Fail mode is safe (a short extract makes `finalize_handoff` abort arming, not inject garbage). |
| Bug #1 secondary fix | `handoff.md` Step 3: replace only the `<!-- HANDOFF:NARRATIVE -->` sentinel; never touch `:START`/`:END` | Reduces how often the marker is dropped; the parser fix makes correctness independent of it. |
| Bug #2 approach | Strip injected wrappers + exclude code/doc lines + keep positive grep | The pollution is injected/skill content and code fragments, not Sam's prose. |
| Bug #2 precision bias | Prefer false-negatives over false-positives | The manual **Do-Not-Redo** block is the authoritative decision channel; `harvest_decisions` is a best-effort supplement. Better to miss a borderline decision than re-inject doc noise. |
| Residual Bug #2 limitation | A few plain-prose doc lines ("Cached data seems incorrect") survive any code-filter | Acknowledged, not papered over. No clean deterministic discriminator for prose that reads like a decision; accepted given the authoritative manual channel. |
| Scope | Bug #1 + Bug #2 only | Task\* harvest + native restore is parked (task #9) and ordered *after* this, since it depends on the hardened `extract_block`. |

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

- **`:END` present (normal):** identical to today — prints the body, stops at `:END`.
- **`:END` missing:** prints the body, stops at the next `## ` heading (e.g. `## Do-Not-Redo`) or `<!-- HANDOFF:` marker, instead of running to EOF. Overflow is bounded to at most the section's own content — never the rest of the file.
- **Unfilled sentinel:** the line `<!-- HANDOFF:NARRATIVE -->` matches `/^<!-- HANDOFF:/`, so an unfilled narrative extracts as empty → `finalize_handoff` (`hooks/handoff-lib.sh:255–261`) still aborts arming via its `length < 40` guard. Fail-safe preserved.

`exit` (vs the old `f=0`) is safe because block names are unique — there is only ever one block per name to extract.

Why not `## `-only or marker-only: a marker-only boundary would not contain a missing `DONOTREDO:END`, because Git State / Files Touched / Open TODOs / Tagged Decisions carry no `<!-- HANDOFF:` markers — the overflow would still reach EOF. The `## ` heading clause is what actually bounds every section; the marker clause is defence in depth.

### Bug #1 — fill-time preservation (`commands/handoff.md` Step 3)

Add an explicit instruction: when filling the narrative, replace **only** the `<!-- HANDOFF:NARRATIVE -->` sentinel line; leave `<!-- HANDOFF:NARRATIVE:START -->` and `<!-- HANDOFF:NARRATIVE:END -->` untouched. Same for Do-Not-Redo. Note the content constraint (no `## ` headings or `<!-- HANDOFF:`-leading lines inside the narrative).

### Bug #2 — tightened `harvest_decisions`

Insert a filter stage between the text extraction and the positive phrase-grep at `hooks/handoff-lib.sh:67–80`. After the existing jq text extraction and slash-command strip, run an awk pass that drops injected wrappers and code/doc lines:

```awk
awk '
    /<system-reminder>/                    {sr=1}
    /<\/system-reminder>/                  {sr=0; next}
    sr                                     {next}                 # injected reminders, not Sam
    /^[[:space:]]*```/                      {fence=!fence; next}   # toggle/skip code fences
    fence                                  {next}
    /^<(command-name|command-message|command-args|local-command-stdout)>/ {next}
    /^[[:space:]]*(\/\/|#|\*|-[[:space:]]\[)/ {next}              # // comments, # headings, * bullets, - [ ] checkboxes
    /content=|await |=>|}[[:space:]]*;?[[:space:]]*$|"[A-Za-z_]+":/ {next}  # code / JSON tells
    {print}
'
```

Then the unchanged positive grep + `length < 300` guard, with the cap tightened `head -15` → `head -8`. Net: injected reminders, fenced code, and code/markdown-structural lines are removed before the decision-phrase match, eliminating the observed `claude-api` pollution. Plain-prose doc lines that read like decisions are the documented residual.

### What does *not* change

`session-start.sh`, `stop-memory.sh`, `session-end.sh`, `pre-compact.sh`, `read-once`, `prompt-corrections.sh`, `memberberry`, hook registration, frontmatter, and the handoff lifecycle are all untouched. `session-start.sh`'s `clear` branch keeps calling `extract_block NARRATIVE` exactly as today — it simply gets a correctly-bounded result.

## Delta vs the existing build

| Action | Component | Detail |
|--------|-----------|--------|
| Modify | `hooks/handoff-lib.sh` `extract_block` (116–124) | Add `## `/`<!-- HANDOFF:` fallback boundary + `exit`-on-end. |
| Modify | `hooks/handoff-lib.sh` `harvest_decisions` (67–80) | Insert wrapper/code/doc filter stage; cap `head -15`→`head -8`. |
| Modify | `commands/handoff.md` Step 3 | Instruction: replace only the sentinel, preserve `:START`/`:END`; note the no-`## `-heading content constraint. |
| New | `tests/handoff-lib-test.sh` fixtures | Four cases below. |
| Unchanged | all hooks, registration, lifecycle, other harvesters | — |

## Testing / verification gates

Fixtures in `tests/handoff-lib-test.sh` (Tier-1 scripted):

1. **Missing `:END`** — a handoff body with `NARRATIVE:START`, body text, then `## Do-Not-Redo` and no `NARRATIVE:END`. Assert `extract_block NARRATIVE` returns only the body, stopping before `## Do-Not-Redo` (not EOF).
2. **Normal `:START`/`:END`** — assert byte-identical output to the current parser (regression guard).
3. **Decisions pollution** — feed a windowed transcript fixture containing representative `claude-api` fragments (`// ❌ Wrong`, `await sendMessage(...)`, `content="…"`, a `<system-reminder>` block, a fenced block, `# Wrong: …`). Assert none survive `harvest_decisions`.
4. **Genuine correction survives** — a real user line ("actually, let's switch to SQLite") passes the filter and is harvested.

Plus a manual check that a real `/handoff` → `/clear` cycle injects the narrative *only* (not the trailing sections), confirming the end-to-end fix against the bug's original symptom.

## Out of scope (YAGNI)

- **Task\* harvest + native restore** — parked (task #9); ordered after this because it depends on the hardened `extract_block`.
- **Plain-prose decision pollution** — a fully deterministic discriminator for prose that reads like a decision; accepted as residual given the authoritative manual Do-Not-Redo channel.
- **Re-architecting `harvest_decisions`** off regex onto a structural signal — the regex supplement is kept; only its precision is tightened.
- **Widening the harvest window for task/decision events across an in-session `/compact`** — consistent with all other harvesters staying windowed.
