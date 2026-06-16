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

# harvest_decisions: tags correction/decision language from BOTH string and
# [{type:text}] user messages; ignores tool_result-only messages.
DEC="$(window_transcript "$FIX" | harvest_decisions)"
assert_contains "decisions: string-form correction" "switch to the deterministic harvester" "$DEC"
assert_contains "decisions: array-text correction"  "threshold should be 150k" "$DEC"
assert_not_contains "decisions: drops tool_result"  "ignore me" "$DEC"

# harvest_todos: pending/in-progress items from the LAST TodoWrite; drops completed
TODOS="$(window_transcript "$FIX" | harvest_todos)"
assert_contains "todos keeps pending"        "wire the clear branch" "$TODOS"
assert_contains "todos keeps in_progress"    "benchmark the token read" "$TODOS"
assert_not_contains "todos drops completed"  "old finished thing" "$TODOS"

# read_live_tokens: sum of the LAST usage-bearing assistant entry (150000+2000+3000)
TOK="$(read_live_tokens "$FIX")"
assert_eq "live tokens = last usage entry sum" "155000" "$TOK"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
