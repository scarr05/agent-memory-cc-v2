# Handoff Harvest Token-Bug Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the handoff harvest from over-injecting context into every post-`/clear` session by (a) hardening `extract_block` so a block can never overflow its own `##` section, (b) enforcing the block-content constraint with a finalize-time defang, and (c) dropping the polluted auto-harvested decisions section entirely.

**Architecture:** All executable changes live in one shared bash library (`hooks/handoff-lib.sh`), exercised by one scripted test file (`tests/handoff-lib-test.sh`). Two markdown consumers (`commands/handoff.md`, `commands/memory-sync.md`) are re-pointed to match. Bug #1 (parser overflow) is fixed by a parser change plus a finalize-time enforcement pass; Bug #2 (decision pollution) is fixed by removing the harvest, not filtering it.

**Tech Stack:** Bash (`set -euo pipefail`), awk, jq, Markdown. No build system. Tests run via `bash tests/handoff-lib-test.sh` and print `PASS=<n> FAIL=<n>`, exiting non-zero if any assertion failed.

**Spec:** `docs/superpowers/specs/2026-06-19-handoff-harvest-token-fixes-design.md` (Approved, revised after codex review).

## Global Constraints

- **Test runner:** `bash tests/handoff-lib-test.sh` — green = final line `PASS=<n> FAIL=0` and exit 0. Every task ends with the full suite green.
- **No real-slug test runs.** Do NOT run `tests/hook-validation.sh` with a real slug — it clobbers live `~/.claude/memory-staging/<slug>/`. This plan only touches the sandboxed `handoff-lib-test.sh`, which uses `mktemp`/`mktemp -d` and cleans up after itself; keep it that way.
- **Bash style:** `set -euo pipefail` (the library is sourced by hooks and dispatched as a CLI under `set -e`). Any harvester whose grep/jq can legitimately no-match must not leak rc=1.
- **Slug-detection duplication is deliberate** — do not refactor it. This plan does not touch it.
- **British English spelling** throughout (behaviour, neutralise, defence).
- **No AI-slop vocabulary** in any prose or comment: avoid "dive into", "leverage", "robust", "seamless", "game-changer", "it's important to note".
- **Branch:** `dev/handoff-clear-continue` (commits on this non-main branch are expected). Commit messages use the repo's lowercase-type convention (`fix:`, `harden:`, `test:`, `docs:`); the harness appends its own Co-Authored-By / Claude-Session trailers per the active session.
- **Block names are unique** — there is only ever one `<!-- HANDOFF:<NAME>:START -->` per name in a handoff file. `exit`-on-boundary in `extract_block` is safe because of this.

---

## File Structure

| File | Responsibility | This plan |
|------|----------------|-----------|
| `hooks/handoff-lib.sh` | Deterministic harvest functions (window, harvest_*, extract_block, build, finalize) | Modify `extract_block`; add defang to `finalize_handoff`; delete `harvest_decisions`; drop the decisions section from `build_deterministic_handoff` |
| `tests/handoff-lib-test.sh` | Tier-1 scripted unit tests over fixture transcripts | Add Bug #1 fixtures; update the unfilled-extract assertion; remove the `harvest_decisions` test; update the build-CLI last-section assertions |
| `commands/handoff.md` | `/handoff` command prose (Step 3 fill instructions) | Add marker-preservation + content-constraint instruction; drop the stale "tagged corrections" mention |
| `commands/memory-sync.md` | `/memory-sync` command prose (fingerprint + correction-routing) | Re-point fingerprint to Files-Touched only; re-point correction-routing to the Do-Not-Redo block |

No new files. No change to hook registration, the handoff lifecycle, `harvest_todos`, `harvest_files`, `harvest_git`, `harvest_compact_summary`, `window_transcript`, or any other hook script.

---

## Task 1: Harden `extract_block` against `:END`-marker overflow

**Files:**
- Modify: `hooks/handoff-lib.sh:116-124` (the `extract_block` function)
- Test: `tests/handoff-lib-test.sh` (add a new fixture block; update the line-92 unfilled assertion)

**Interfaces:**
- Consumes: nothing new.
- Produces: `extract_block <NAME> <file>` — prints the lines strictly between `<!-- HANDOFF:<NAME>:START -->` and the first of (`<!-- HANDOFF:<NAME>:END -->` | next `## ` heading | next `<!-- HANDOFF:` line | EOF), exclusive of all boundary lines. Unchanged signature; bounded output. `finalize_handoff` (Task 2) and `session-start.sh` both rely on this bounded behaviour.

**Context for the implementer:** Today's parser is `{sub(/\r$/,"")} $0==s {f=1; next} $0==e {f=0} f`. When the `:END` marker is missing (the `/handoff` fill edit drops it intermittently), `f` never resets and the function prints from `:START` to end-of-file, dragging every later section into what gets injected as the "narrative". The fix adds a fallback boundary: stop at the next `## ` heading or `<!-- HANDOFF:` marker line. Because block names are unique, switching `f=0` to `exit` is safe and changes not a single emitted byte for a well-formed block.

- [ ] **Step 1: Write the failing tests**

In `tests/handoff-lib-test.sh`, insert this block immediately after the `read_live_tokens` test (after the line `assert_eq "live tokens = last usage entry sum" "155000" "$TOK"`, currently line 74) and before the `build_deterministic_handoff` comment:

```bash
# --- Bug #1: extract_block must not overflow its section when :END is missing ---
# Missing :END — extract stops at the next "## " heading, not EOF.
EB1="$(mktemp)"
printf '%s\n' \
  '## Current Work — Narrative' \
  '<!-- HANDOFF:NARRATIVE:START -->' \
  'body line one' \
  'body line two' \
  '## Do-Not-Redo' \
  '<!-- HANDOFF:DONOTREDO:START -->' \
  'should not appear' > "$EB1"
EB1_OUT="$(extract_block NARRATIVE "$EB1")"
assert_eq          "extract stops at next ## when :END missing" "$(printf '%s\n%s' 'body line one' 'body line two')" "$EB1_OUT"
assert_not_contains "extract excludes the ## boundary line"      "Do-Not-Redo"     "$EB1_OUT"
assert_not_contains "extract does not overflow to later blocks"  "should not appear" "$EB1_OUT"
rm -f "$EB1"

# Regression: a well-formed :START/:END block extracts exactly its body (boundary
# lines excluded), byte-for-byte — the hardening must not alter the normal path.
EB2="$(mktemp)"
printf '%s\n' \
  '<!-- HANDOFF:NARRATIVE:START -->' \
  'alpha' \
  'beta' \
  '<!-- HANDOFF:NARRATIVE:END -->' \
  'trailing content outside the block' > "$EB2"
assert_eq "extract returns exact body for well-formed block" "$(printf '%s\n%s' 'alpha' 'beta')" "$(extract_block NARRATIVE "$EB2")"
assert_not_contains "extract excludes trailing content" "trailing content" "$(extract_block NARRATIVE "$EB2")"
rm -f "$EB2"
```

Then **update the existing unfilled-extract assertion** (currently line 92). Replace:

```bash
# extract_block returns only the lines between the markers (exclusive)
assert_contains "extract_block: unfilled => sentinel" "<!-- HANDOFF:NARRATIVE -->" "$(extract_block NARRATIVE "$OUT")"
```

with:

```bash
# extract_block returns only the lines between the markers (exclusive). On an
# unfilled handoff the body IS the bare sentinel, which is itself a <!-- HANDOFF:
# boundary line, so the hardened parser stops before printing it => empty extract.
# finalize_handoff's length<40 guard then aborts arming (see the unfilled test below).
assert_eq "extract_block: unfilled => empty (sentinel is a boundary)" "" "$(extract_block NARRATIVE "$OUT")"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL` ≥ 1, with failures for `extract stops at next ## when :END missing` (old parser runs to EOF, so the output includes the later lines) and `extract_block: unfilled => empty ...` (old parser prints the sentinel line). The two regression asserts (`extract returns exact body...`, `extract excludes trailing content`) should already PASS.

- [ ] **Step 3: Implement the hardened parser**

In `hooks/handoff-lib.sh`, replace the body of `extract_block` (the `awk` invocation at lines 122-123):

```bash
    awk -v s="<!-- HANDOFF:${name}:START -->" -v e="<!-- HANDOFF:${name}:END -->" '
        {sub(/\r$/,"")} $0==s {f=1; next} $0==e {f=0} f' "$file"
```

with:

```bash
    awk -v s="<!-- HANDOFF:${name}:START -->" -v e="<!-- HANDOFF:${name}:END -->" '
        {sub(/\r$/,"")}                         # CRLF tolerance (unchanged)
        $0==s                              {f=1; next}   # enter block on START
        f && $0==e                         {exit}        # normal: stop at END
        f && (/^## / || /^<!-- HANDOFF:/)  {exit}        # fallback: stop at next section/marker
        f                                                # print body lines
    ' "$file"
```

Leave the surrounding comment (lines 113-121) intact, but extend the trailing CRLF comment if you wish — not required.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL=0`, exit 0. All prior assertions plus the four new/updated ones pass.

- [ ] **Step 5: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh
git commit -m "harden: bound extract_block to its own section when :END is missing"
```

---

## Task 2: Enforce the block-content constraint with a finalize-time defang

**Files:**
- Modify: `hooks/handoff-lib.sh:250-262` (inside `finalize_handoff`, the `src == handoff` branch)
- Modify: `commands/handoff.md` Step 3 (lines 73-80)
- Test: `tests/handoff-lib-test.sh` (add a defang fixture block)

**Interfaces:**
- Consumes: hardened `extract_block` from Task 1.
- Produces: `finalize_handoff --out OUT --consumed CONSUMED` — unchanged signature and `ARMED:`/`ABORTED:` contract. New behaviour: for `source == handoff`, after the thin-guard passes, any line inside the NARRATIVE or DONOTREDO **body** that begins `## ` or `<!-- HANDOFF:` is rewritten with a single leading space, so the hardened `extract_block` cannot mistake filled content for a section boundary. The structural `:START`/`:END` markers are never altered.

**Context for the implementer:** The manual narrative is filled *in-context* by Claude after the build step, so it cannot be defanged at build time. `finalize_handoff` is the gate before arming and already rewrites the file (for `supersedes`). The defang pass goes inside the existing `if [[ "$src" == "handoff" ]]; then ... fi` branch, **after** the thin-guard `if` block (so it never runs on an unfilled sentinel — the guard aborts first) and **before** the `supersedes` stamping. This is the manual-path analogue of the marker-defang already applied to the compaction summary at `hooks/handoff-lib.sh:148`.

The defang awk must distinguish structural markers (`NARRATIVE`/`DONOTREDO` `:START`/`:END`) from body lines: it tracks an in-body flag, prints the structural markers verbatim, and only space-prefixes boundary-looking lines while in-body. It normalises a trailing CR **for matching only** — mirroring `extract_block`'s `sub(/\r$/,"")` (the one CR idiom already proven portable in this file) — but reprints each line from an unmodified copy (`raw`), so original line endings are preserved and the pass never rewrites CRLF→LF across the whole file. (Do NOT embed `\r?$` in the match patterns; that relies on `\r` being honoured inside a match regex, which is not POSIX-defined.)

- [ ] **Step 1: Write the failing test**

In `tests/handoff-lib-test.sh`, insert this block immediately **after** the existing "finalize arms narrative mentioning the token" test (after the line `assert_contains "finalize arms narrative mentioning the token" "ARMED" "$FIN_MENTION"`, currently line 116) and before the `compact-fallback` comment:

```bash
# --- Bug #1: finalize defangs boundary-looking lines inside the filled body ---
# A filled narrative whose body contains a "## " line and a "<!-- HANDOFF:" line
# would otherwise truncate under the hardened extract_block. finalize must space-
# prefix those body lines (so extract returns the WHOLE body), leave the structural
# :START/:END markers untouched, and still arm.
DFG="$TMPD/defang.md"
cat > "$DFG" <<'EOF'
---
slug: "demo-proj"
branch: "main"
created: "2026-06-19T00:00:00Z"
source: "handoff"
live_tokens: 1000
consumed: false
supersedes: ""
---

# Handoff — demo-proj (main)

## Current Work — Narrative
<!-- HANDOFF:NARRATIVE:START -->
We are mid-way through the parser fix; this first line is intentionally long enough to clear the forty-character thin guard on its own.
## A heading that looks like a section boundary
<!-- HANDOFF:FAKE:START -->
more narrative text after the fake marker line.
<!-- HANDOFF:NARRATIVE:END -->

## Do-Not-Redo
<!-- HANDOFF:DONOTREDO:START -->
- Do NOT re-run the old parser.
<!-- HANDOFF:DONOTREDO:END -->

## Git State
Branch: `main` (0 dirty files)

## Files Touched (this work unit)
- 1 /src/handoff-lib.sh

## Open TODOs
EOF
FIN_DFG="$(finalize_handoff --out "$DFG" --consumed "$TMPD/none.md"; echo "rc=$?")"
assert_contains "defang: finalize still arms" "ARMED" "$FIN_DFG"
# Body boundary-looking lines are space-prefixed (no longer line-anchored boundaries)...
assert_eq "defang: ## body line is space-prefixed"        "0" "$(grep -c '^## A heading' "$DFG")"
assert_eq "defang: ## body line present once, prefixed"   "1" "$(grep -c '^ ## A heading' "$DFG")"
assert_eq "defang: fake marker line is space-prefixed"    "0" "$(grep -c '^<!-- HANDOFF:FAKE:START -->' "$DFG")"
assert_eq "defang: fake marker present once, prefixed"    "1" "$(grep -c '^ <!-- HANDOFF:FAKE:START -->' "$DFG")"
# ...structural markers are intact (exactly one each, unprefixed)...
assert_eq "defang: NARRATIVE:START intact" "1" "$(grep -c '^<!-- HANDOFF:NARRATIVE:START -->' "$DFG")"
assert_eq "defang: NARRATIVE:END intact"   "1" "$(grep -c '^<!-- HANDOFF:NARRATIVE:END -->' "$DFG")"
# ...and extract_block now returns the WHOLE body (no truncation at the ## line).
DFG_EXTRACT="$(extract_block NARRATIVE "$DFG")"
assert_contains "defang: extract keeps the prefixed heading"   " ## A heading"                       "$DFG_EXTRACT"
assert_contains "defang: extract keeps post-marker text"        "more narrative text after the fake" "$DFG_EXTRACT"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL` ≥ 1. Before the defang exists, the body `## A heading` line stays unprefixed (`grep -c '^## A heading'` is `1`, not `0`) and `extract_block` truncates at that line, so `defang: extract keeps post-marker text` fails too. `defang: finalize still arms` passes (the long first line clears the thin guard).

- [ ] **Step 3: Implement the defang pass**

In `hooks/handoff-lib.sh`, inside `finalize_handoff`, the `src == handoff` branch currently reads:

```bash
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
```

Add the defang pass after the thin-guard `if`/`fi`, still inside the `src == handoff` branch:

```bash
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
        # Enforce the block-content constraint the hardened extract_block relies on:
        # a filled body line that begins "## " or "<!-- HANDOFF:" would be read as a
        # section boundary and silently truncate the block. Space-prefix any such
        # BODY line (inside a NARRATIVE/DONOTREDO :START..:END span) so it is no longer
        # line-anchored. The structural :START/:END markers themselves are printed
        # verbatim and never prefixed. Manual-path analogue of the compaction-summary
        # defang at the harvest_compact_summary helper.
        # CR-normalise for matching only (same idiom as extract_block); print from the
        # untouched `raw` copy so original line endings survive — no CRLF->LF rewrite.
        awk '
            { raw=$0; sub(/\r$/, "", $0) }
            /^<!-- HANDOFF:(NARRATIVE|DONOTREDO):START -->$/ {inb=1; print raw; next}
            /^<!-- HANDOFF:(NARRATIVE|DONOTREDO):END -->$/   {inb=0; print raw; next}
            inb && (/^## / || /^<!-- HANDOFF:/)              {print " " raw; next}
            {print raw}
        ' "$OUT" > "$OUT.tmp" && mv "$OUT.tmp" "$OUT"
    fi
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL=0`, exit 0. All defang assertions pass; the existing finalize tests (unfilled aborts, filled arms, supersedes stamped, token-mention arms) still pass because their narratives contain no boundary-looking body lines, so the defang is a no-op on them.

- [ ] **Step 5: Update the `/handoff` Step 3 fill instruction**

In `commands/handoff.md`, the Step 3 numbered list (lines 75-80) currently reads:

```markdown
You have the live conversation in context — do NOT re-read the transcript. Use the Edit tool on the handoff file to replace the two placeholders:

1. Replace `<!-- HANDOFF:NARRATIVE -->` with 3–5 sentences: what we are mid-way through **right now**, why, and the **exact next action** a fresh agent should take first — file + line + intent (e.g. "Edit `hooks/session-start.sh:165` to add the clear-injection branch").
2. Replace `<!-- HANDOFF:DONOTREDO -->` with the dead ends already ruled out this session, so the fresh agent does not repeat them. If none, write `- None.`

Keep it tight. The deterministic sections already carry git state, touched files, TODOs, and tagged corrections — the narrative is only the irreducible "what/why/next".
```

Replace that span with:

```markdown
You have the live conversation in context — do NOT re-read the transcript. Use the Edit tool on the handoff file to replace the two **fill sentinels**. Replace ONLY the collapsed sentinel line; never touch the surrounding `<!-- HANDOFF:NARRATIVE:START -->` / `:END` (or `:DONOTREDO:` `:START`/`:END`) markers — they delimit the block for every reader.

1. Replace `<!-- HANDOFF:NARRATIVE -->` with 3–5 sentences: what we are mid-way through **right now**, why, and the **exact next action** a fresh agent should take first — file + line + intent (e.g. "Edit `hooks/session-start.sh:165` to add the clear-injection branch").
2. Replace `<!-- HANDOFF:DONOTREDO -->` with the dead ends already ruled out this session, so the fresh agent does not repeat them. If none, write `- None.`

Keep it tight, and keep the body free of lines that begin `## ` or `<!-- HANDOFF:` — those read as section boundaries. (Finalise defangs any that slip through by space-prefixing them, so a slip degrades gracefully rather than truncating the block.) The deterministic sections already carry git state, touched files, and TODOs — the narrative is only the irreducible "what/why/next".
```

- [ ] **Step 6: Commit**

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh commands/handoff.md
git commit -m "harden: defang boundary-looking lines in filled handoff body at finalize"
```

---

## Task 3: Drop the polluted auto-harvested decisions section

**Files:**
- Modify: `hooks/handoff-lib.sh` — delete `harvest_decisions` (lines 63-80); delete the decisions section from `build_deterministic_handoff` (lines 222-224)
- Modify: `commands/memory-sync.md:65` (fingerprint) and `:185` (correction-routing)
- Modify: `commands/handoff.md` (already done in Task 2 — no stale "tagged corrections" mention remains)
- Test: `tests/handoff-lib-test.sh` — remove the `harvest_decisions` unit test (lines 59-64); update the two build-CLI last-section assertions (lines 143, 151)

**Interfaces:**
- Consumes: nothing from Tasks 1-2 (independent change; ordered last because it is the Bug #2 cluster).
- Produces: `build_deterministic_handoff` output whose final section is `## Open TODOs` (the `## Tagged Decisions / Corrections` heading and `harvest_decisions` call are gone). `harvest_decisions` no longer exists. `/memory-sync` reads its effort fingerprint from `## Files Touched` alone and its direction-change corrections from the `## Do-Not-Redo` block.

**Context for the implementer:** In the one real sample (the R2 oracle), the auto-harvest produced zero genuine decisions and fifteen lines of `claude-api` skill-doc pollution; the manual Do-Not-Redo block in the same handoff was clean and authoritative. A tightened denylist filter still leaked 6 of 15 polluted lines (the long decision-looking prose), so the harvest is removed rather than filtered. `window_transcript`, `harvest_files`, and `harvest_todos` still read the window, so the window is unchanged. After this change the last harvester emitted by the build is `harvest_todos`, which already returns 0 on empty — the existing rc-leak regression still holds.

- [ ] **Step 1: Update the tests to assert the new shape**

In `tests/handoff-lib-test.sh`:

**(a)** Remove the `harvest_decisions` unit test (currently lines 59-64):

```bash
# harvest_decisions: tags correction/decision language from BOTH string and
# [{type:text}] user messages; ignores tool_result-only messages.
DEC="$(window_transcript "$FIX" | harvest_decisions)"
assert_contains "decisions: string-form correction" "switch to the deterministic harvester" "$DEC"
assert_contains "decisions: array-text correction"  "threshold should be 150k" "$DEC"
assert_not_contains "decisions: drops tool_result"  "ignore me" "$DEC"
```

Delete that whole block (comment + three asserts). Leave the `harvest_todos` block that follows it intact.

**(b)** Update the build-CLI (`handoff` source) last-section assertion. Currently (lines 142-143):

```bash
assert_eq "build CLI exits 0 with no tagged decisions" "0" "$RC_BUILD"
assert_contains "build CLI still writes the last section" "## Tagged Decisions / Corrections" "$(cat "$OUT4")"
```

Replace with:

```bash
assert_eq "build CLI exits 0 with no open todos" "0" "$RC_BUILD"
assert_not_contains "build CLI drops the decisions section" "## Tagged Decisions / Corrections" "$(cat "$OUT4")"
# Assert the last SECTION heading is Open TODOs. Scope to headings AFTER the
# narrative END marker so a heading-bearing narrative could never spoof it.
assert_eq "build CLI: Open TODOs is the final section" "## Open TODOs" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT4" | grep '^## ' | tail -1)"
```

**(c)** Update the `compact-fallback` last-section assertion. Currently (lines 150-151):

```bash
assert_eq "compact-fallback CLI exits 0 with no summary" "0" "$RC_CF"
assert_contains "compact-fallback still writes the last section" "## Tagged Decisions / Corrections" "$(cat "$OUT5")"
```

Replace with:

```bash
assert_eq "compact-fallback CLI exits 0 with no summary" "0" "$RC_CF"
assert_not_contains "compact-fallback drops the decisions section" "## Tagged Decisions / Corrections" "$(cat "$OUT5")"
assert_eq "compact-fallback: Open TODOs is the final section" "## Open TODOs" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT5" | grep '^## ' | tail -1)"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL` ≥ 1. The two `assert_not_contains ... decisions section` assertions fail (the build still emits `## Tagged Decisions / Corrections`) and the two `Open TODOs is the final section` assertions fail (the current final section is Tagged Decisions). The removed `harvest_decisions` block no longer runs.

- [ ] **Step 3: Delete the `harvest_decisions` function**

In `hooks/handoff-lib.sh`, delete the comment and function (lines 63-80):

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
        | { grep -iE "actually|\bno,|wrong|incorrect|not right|stop doing|i meant|i prefer|always use|never use|from now on|let's go with|i decided|we're using|switch to|we agreed" || true; } \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | awk 'length > 0 && length < 300' \
        | head -15
}
```

Leave the blank line so `harvest_git` (ends line 61) and the `harvest_todos` comment (starts line 82) stay separated by one blank line.

- [ ] **Step 4: Drop the decisions section from the assembled handoff**

In `hooks/handoff-lib.sh`, `build_deterministic_handoff`, the tail of the assembled-document brace group currently reads (lines 219-225):

```bash
        echo
        echo "## Open TODOs"
        harvest_todos < "$win"
        echo
        echo "## Tagged Decisions / Corrections"
        harvest_decisions < "$win"
    } > "$OUT"
```

Replace with:

```bash
        echo
        echo "## Open TODOs"
        harvest_todos < "$win"
    } > "$OUT"
```

The explicit `return 0` later in the function (and its comment about not leaking the trailing harvester's rc) still applies — `harvest_todos` is now the trailing harvester and already returns 0 on empty.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL=0`, exit 0. The build no longer emits the decisions heading; `## Open TODOs` is the final `## ` heading for both sources; the rc-leak regression (`build CLI exits 0 ...`, `compact-fallback CLI exits 0 ...`) still passes.

- [ ] **Step 6: Re-point the `/memory-sync` fingerprint**

In `commands/memory-sync.md`, Step 2.5 item 2 (line 65) currently reads:

```markdown
2. Extract this effort's **fingerprint**: the `## Files Touched (this work unit)` list plus the `## Tagged Decisions / Corrections` lines.
```

Replace with:

```markdown
2. Extract this effort's **fingerprint**: the `## Files Touched (this work unit)` list. (File-list overlap across consecutive sessions is the effort matcher — see step 3.)
```

- [ ] **Step 7: Re-point the `/memory-sync` correction-routing**

In `commands/memory-sync.md`, the "Direction-change corrections" paragraph (lines 185-191) currently reads:

```markdown
**Direction-change corrections (from the handoff scratch):** the handoff's `## Tagged Decisions / Corrections` section is non-empty only when the direction shifted this effort. For each line there that is not already in `5 Agent Memory/learnings/corrections/`:
```

Replace that lead sentence with:

```markdown
**Direction-change corrections (from the handoff scratch):** the handoff's `## Do-Not-Redo` block (between its `<!-- HANDOFF:DONOTREDO:START -->` / `:END` markers) records the dead-ends and direction shifts of this effort — the clean, authoritative channel. For each line in that block that is not already in `5 Agent Memory/learnings/corrections/`:
```

Then update the closing sentence of that paragraph (line 191) — currently:

```markdown
If genuinely new, propose it as a correction learning (needs the user's approval, per the rules). Once approved and written, `prompt-corrections.sh` will surface it in future sessions whenever a prompt touches that topic (its index is rebuilt at SessionStart). A correction counts as "new" when the current handoff's corrections differ from the prior `.consumed` handoff's.
```

Replace its last sentence so the "new" diff reads from the Do-Not-Redo block:

```markdown
If genuinely new, propose it as a correction learning (needs the user's approval, per the rules). Once approved and written, `prompt-corrections.sh` will surface it in future sessions whenever a prompt touches that topic (its index is rebuilt at SessionStart). A correction counts as "new" when the current handoff's Do-Not-Redo lines differ from the prior `.consumed` handoff's.
```

- [ ] **Step 8: Run the full suite once more and commit**

Run: `bash tests/handoff-lib-test.sh`
Expected: `FAIL=0`, exit 0.

```bash
git add hooks/handoff-lib.sh tests/handoff-lib-test.sh commands/memory-sync.md
git commit -m "fix: drop polluted auto-harvested decisions section; re-point /memory-sync consumers"
```

---

## Final verification (manual, after all three tasks)

These confirm the end-to-end fix against the bug's original symptom. They are optional for the scripted gate but recommended before the branch is finished.

1. **Scripted suite green:** `bash tests/handoff-lib-test.sh` → `FAIL=0`.
2. **Missing-`:END` injection bound (sandboxed):** build a handoff fixture with `NARRATIVE:START`, body, then `## Do-Not-Redo` and no `NARRATIVE:END`; run `extract_block NARRATIVE` and confirm it returns the narrative only. (Covered by the Task 1 fixture; re-run if you want the explicit demonstration.)
3. **No decisions section:** `bash hooks/handoff-lib.sh build --transcript <any> --slug demo --source handoff --out /tmp/h.md && grep -c 'Tagged Decisions' /tmp/h.md` → `0`.
4. **Real cycle (optional, only if you run a genuine `/handoff` → `/clear`):** confirm the post-`/clear` SessionStart injects the narrative *only* — not Git State / Files Touched / Open TODOs, and no decisions section. Do this in a throwaway slug or a sandboxed `$HOME` so live project memory is not clobbered.

---

## Self-Review (completed by plan author)

**Spec coverage:**

| Spec item | Task |
|-----------|------|
| Harden `extract_block` (fallback boundary + `exit`-on-end) | Task 1, Step 3 |
| Fixture: missing `:END` stops before `## Do-Not-Redo` | Task 1, Step 1 |
| Fixture: normal block byte-identical regression | Task 1, Step 1 |
| Unfilled fail-safe preserved (empty extract → guard aborts) | Task 1 (line-92 update) + existing unfilled-abort test |
| Finalize-time defang, scoped to `source==handoff`, after the guard | Task 2, Step 3 |
| Fixture: defang space-prefixes both line types, no truncation, markers intact | Task 2, Step 1 |
| `handoff.md` Step 3: replace sentinel only, preserve `:START`/`:END`, note constraint | Task 2, Step 5 |
| Remove `harvest_decisions` function | Task 3, Step 3 |
| Drop `## Tagged Decisions / Corrections` section; Open TODOs becomes last | Task 3, Step 4 |
| Fixture: section dropped, Open TODOs final, both `handoff` and `compact-fallback` | Task 3, Steps 1(b)/(c) |
| Remove `harvest_decisions` unit test; update build-CLI assertions | Task 3, Step 1 |
| `memory-sync.md:65` fingerprint = Files Touched only | Task 3, Step 6 |
| `memory-sync.md:185` correction-routing reads Do-Not-Redo block | Task 3, Step 7 |
| Out of scope: Task\* harvest (#9), re-introducing a harvest, widening the window | Not in any task — correctly excluded |

No spec requirement is left without a task.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows the actual code; every test step shows the actual assertions; every command shows the expected output.

**Type/name consistency:** `extract_block`, `finalize_handoff`, `build_deterministic_handoff`, `harvest_decisions`, `harvest_todos` used consistently against their definitions in `hooks/handoff-lib.sh`. Section heading strings (`## Tagged Decisions / Corrections`, `## Open TODOs`) match the source exactly. Test helper names (`assert_eq`, `assert_contains`, `assert_not_contains`) match `tests/handoff-lib-test.sh`. Marker strings match the build output verbatim.
