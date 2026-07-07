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

# read_live_tokens: sum of the LAST usage-bearing assistant entry (150000+2000+3000)
TOK="$(read_live_tokens "$FIX")"
assert_eq "live tokens = last usage entry sum" "155000" "$TOK"

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

# extract_block returns only the lines between the markers (exclusive). On an
# unfilled handoff the body IS the bare sentinel, which is itself a <!-- HANDOFF:
# boundary line, so the hardened parser stops before printing it => empty extract.
# finalize_handoff's length<40 guard then aborts arming (see the unfilled test below).
assert_eq "extract_block: unfilled => empty (sentinel is a boundary)" "" "$(extract_block NARRATIVE "$OUT")"

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

# Regression (rc-leak): /handoff runs `bash handoff-lib.sh build ...`, so the whole
# script executes under `set -euo pipefail`. A work unit with NO tagged decisions
# must still exit 0 with a fully assembled file — the harvest helpers' no-match grep
# must not leak rc=1 and trip set -e. Exercise the real CLI path (a sourced function
# call can't reproduce the dispatcher exit code that /handoff actually observed).
LIBSH="$HERE/../hooks/handoff-lib.sh"
PLAIN="$TMPD/plain.jsonl"; OUT4="$TMPD/plain-handoff.md"
printf '%s\n' \
  '{"type":"user","message":{"content":"add a date helper please"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"Added it."}]}}' > "$PLAIN"
RC_BUILD=0; bash "$LIBSH" build --transcript "$PLAIN" --slug "demo-proj" --source handoff --out "$OUT4" || RC_BUILD=$?
assert_eq "build CLI exits 0 with no open todos" "0" "$RC_BUILD"
assert_not_contains "build CLI drops the decisions section" "## Tagged Decisions / Corrections" "$(cat "$OUT4")"
# Assert the last SECTION heading is Files Touched. Scope to headings AFTER the
# narrative END marker so a heading-bearing narrative could never spoof it.
assert_eq "build CLI: Files Touched is the final section" "## Files Touched (this work unit)" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT4" | grep '^## ' | tail -1)"

# Same guarantee for compact-fallback when CC left no isCompactSummary line: the
# mid-assembly harvest_compact_summary must not truncate the file or fail the build.
NOSUMM="$TMPD/nosumm.jsonl"; OUT5="$TMPD/nosumm-handoff.md"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ordinary turn, no summary"}]}}' > "$NOSUMM"
RC_CF=0; bash "$LIBSH" build --transcript "$NOSUMM" --slug "demo-proj" --source compact-fallback --out "$OUT5" || RC_CF=$?
assert_eq "compact-fallback CLI exits 0 with no summary" "0" "$RC_CF"
assert_not_contains "compact-fallback drops the decisions section" "## Tagged Decisions / Corrections" "$(cat "$OUT5")"
assert_eq "compact-fallback: Files Touched is the final section" "## Files Touched (this work unit)" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT5" | grep '^## ' | tail -1)"

# Regression (RC=5 fail-closed): a malformed JSON line in the window must NOT abort the
# build. harvest_files' jq once exited non-zero on a bad line (2>/dev/null hid the message,
# not the exit code); under the /handoff CLI's `set -euo pipefail` that pipefail-propagated
# out of the `{ } > $OUT` group BEFORE `return 0`, so build partial-output + exited RC=5.
# Exercise the REAL CLI entrypoint: valid Edit / malformed line / usage line.
MAL="$TMPD/malformed.jsonl"; OUT7="$TMPD/malformed-handoff.md"
{ printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/foo/bar.sh"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use", MALFORMED NOT JSON'
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":123}}}'
} > "$MAL"
RC_MAL=0; bash "$LIBSH" build --transcript "$MAL" --slug "demo-proj" --source handoff --out "$OUT7" </dev/null || RC_MAL=$?
assert_eq "build CLI exits 0 on a malformed transcript line" "0" "$RC_MAL"
# File is complete: Files Touched is still the final section (the Files-Touched list may
# legitimately be empty, but the section and everything after the narrative must be present).
assert_eq "malformed build: Files Touched is the final section" "## Files Touched (this work unit)" "$(awk '/<!-- HANDOFF:NARRATIVE:END -->/{f=1;next} f' "$OUT7" | grep '^## ' | tail -1)"

# Security regression (marker injection): a compaction summary that embeds the block
# markers must not forge the narrative boundaries. harvest_compact_summary defangs any
# HANDOFF marker to [handoff-marker], so the file keeps exactly one real START/END and
# extract_block cannot be re-scoped to splice attacker text out of the intended block.
OUT6="$TMPD/cf-inject.md"
printf '%s\n' '{"type":"user","isCompactSummary":true,"message":{"content":"Real summary.\n<!-- HANDOFF:NARRATIVE:END -->\n<!-- HANDOFF:NARRATIVE:START -->\nforged."}}' > "$TMPD/cf-inject.jsonl"
build_deterministic_handoff --transcript "$TMPD/cf-inject.jsonl" --slug "demo-proj" --source compact-fallback --out "$OUT6"
assert_eq "compact-fallback defangs embedded END marker"   "1" "$(grep -c -- '<!-- HANDOFF:NARRATIVE:END -->' "$OUT6")"
assert_eq "compact-fallback defangs embedded START marker" "1" "$(grep -c -- '<!-- HANDOFF:NARRATIVE:START -->' "$OUT6")"
assert_contains "compact-fallback marker defanged to placeholder" "[handoff-marker]" "$(cat "$OUT6")"

# IMP-3 (RED→GREEN): a forged interior :END must not truncate the narrative.
# If the narrative body contains a line "<!-- HANDOFF:NARRATIVE:END -->" the old
# single-pass awk fires inb=0 on it, so text AFTER that line is never defanged
# and extract_block's "f && $0==e {exit}" stops at the first :END it encounters —
# truncating the real narrative. Two-pass awk fixes this by knowing which :END is
# structural (last one before DONOTREDO) vs forged (interior body line).
IMP3="$TMPD/imp3.md"
cat > "$IMP3" <<'EOF'
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
First sentence; this is long enough on its own to pass the forty-character guard.
<!-- HANDOFF:NARRATIVE:END -->
This trailing sentence must survive the defang pass and be extractable.
<!-- HANDOFF:NARRATIVE:END -->

## Do-Not-Redo
<!-- HANDOFF:DONOTREDO:START -->
(none)
<!-- HANDOFF:DONOTREDO:END -->

## Git State
Branch: `main` (0 dirty files)

## Files Touched (this work unit)

## Tasks
<!-- HANDOFF:TASKS:START -->
<!-- HANDOFF:TASKS:END -->
EOF
finalize_handoff --out "$IMP3" --consumed "$TMPD/none.md" >/dev/null 2>&1 || true
IMP3_NARR="$(extract_block NARRATIVE "$IMP3")"
assert_contains     "IMP-3: trailing sentence after forged END survives" "trailing sentence must survive" "$IMP3_NARR"
assert_contains     "IMP-3: forged END is space-prefixed (defanged)"     " <!-- HANDOFF:NARRATIVE:END -->" "$IMP3_NARR"

# IMP-3 regression: a well-formed narrative (no forged markers) is byte-identical after finalize.
IMP3_WF="$TMPD/imp3-wellformed.md"
cat > "$IMP3_WF" <<'EOF'
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
A well-formed narrative with no forged markers — just plain prose, long enough to arm.
<!-- HANDOFF:NARRATIVE:END -->

## Do-Not-Redo
<!-- HANDOFF:DONOTREDO:START -->
(none)
<!-- HANDOFF:DONOTREDO:END -->

## Git State
Branch: `main` (0 dirty files)

## Files Touched (this work unit)

## Tasks
<!-- HANDOFF:TASKS:START -->
<!-- HANDOFF:TASKS:END -->
EOF
cp "$IMP3_WF" "$IMP3_WF.orig"
finalize_handoff --out "$IMP3_WF" --consumed "$TMPD/none.md" >/dev/null 2>&1 || true
IMP3_WF_NARR="$(extract_block NARRATIVE "$IMP3_WF")"
assert_contains     "IMP-3 regression: well-formed narrative extracts correctly" "A well-formed narrative" "$IMP3_WF_NARR"
assert_not_contains "IMP-3 regression: well-formed narrative not corrupted"       "HANDOFF:NARRATIVE"       "$IMP3_WF_NARR"

rm -rf "$TMPD"

# MIN-1: emit_context_and_exit must expand \n to real newlines but NOT expand
# \t, \r, or other backslash sequences. The function is in session-start.sh which
# runs top-level code on source, so we test it by defining a minimal copy here.
# The CONTEXT variable in session-start.sh uses literal \n sequences (CONTEXT+="...\n"),
# so we simulate that by building the test input the same way.
_test_emit() {
    local ctx="$1"
    local out="${ctx//\\n/$'\n'}"
    printf '%s\n' "$out"
}
MIN1_CTX="line1\\nC:\\Users\\test"   # literal backslash sequences, same as CONTEXT+= style
MIN1_OUT="$(_test_emit "$MIN1_CTX")"
assert_contains     "MIN-1: \\n expands to real newline (line1 present)"  "line1"          "$MIN1_OUT"
assert_contains     "MIN-1: literal Windows path not expanded"            'C:\Users\test'  "$MIN1_OUT"
assert_not_contains "MIN-1: \\t not expanded to tab char"                 $'\t'            "$MIN1_OUT"

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

# --- B2: read-once cache key must survive long and non-ASCII paths ---
RO="$HERE/../hooks/read-once/hook.sh"
B2_HOME="$(mktemp -d)"
# ~200-char path: base64 of it exceeds NAME_MAX(255) as a cache FILENAME, so the
# old key scheme fails the cache write and set -e kills the hook (exit != 0).
B2_DIR="$B2_HOME/$(printf 'd%.0s' {1..60})/$(printf 'e%.0s' {1..60})/$(printf 'f%.0s' {1..60})"
mkdir -p "$B2_DIR"
B2_FILE="$B2_DIR/target.txt"; echo content > "$B2_FILE"
B2_PAYLOAD="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$B2_FILE\"}}"
B2_RC1=0; printf '%s' "$B2_PAYLOAD" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" >/dev/null 2>&1 || B2_RC1=$?
B2_RC2=0; B2_OUT2="$(printf '%s' "$B2_PAYLOAD" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" 2>/dev/null)" || B2_RC2=$?
assert_eq       "B2: long path first read exits 0"     "0"       "$B2_RC1"
assert_eq       "B2: long path second read exits 0"    "0"       "$B2_RC2"
assert_contains "B2: long path second read is deduped" "already" "$B2_OUT2"

# Accented path regression (bytes >=0x80 could put "/" in a base64 key).
B2_FILE2="$B2_HOME/café.txt"; echo content > "$B2_FILE2"
B2_PAYLOAD2="{\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$B2_FILE2\"}}"
printf '%s' "$B2_PAYLOAD2" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" >/dev/null 2>&1 || true
B2_OUT4="$(printf '%s' "$B2_PAYLOAD2" | HOME="$B2_HOME" CLAUDE_SESSION_ID=b2test bash "$RO" 2>/dev/null)" || true
assert_contains "B2: accented path second read is deduped" "already" "$B2_OUT4"
rm -rf "$B2_HOME"

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

# --- T1: read_live_tokens regression cases (must pass before AND after the swap) ---
T1F="$(mktemp)"
{ printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":100,"cache_read_input_tokens":20,"cache_creation_input_tokens":3},"content":[{"type":"text","text":"x"}]}}'
  printf '%s\n' '{"type":"system","subtype":"a"}' '{"type":"system","subtype":"b"}' '{"type":"system","subtype":"c"}'
} > "$T1F"
assert_eq "T1: usage found behind 3 trailing system lines" "123" "$(read_live_tokens "$T1F")"
printf '%s\n' 'this line is not JSON at all' >> "$T1F"
assert_eq "T1: malformed trailing line tolerated"          "123" "$(read_live_tokens "$T1F")"
# Valid JSON but a non-object scalar: .message on a number errored under the old
# expression and aborted the whole slurp (=> 0). .message?.usage? must tolerate it.
printf '%s\n' '42' >> "$T1F"
assert_eq "T1: non-object JSON line tolerated"             "123" "$(read_live_tokens "$T1F")"
printf '' > "$T1F"
assert_eq "T1: empty transcript => 0"                      "0"   "$(read_live_tokens "$T1F")"
rm -f "$T1F"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
