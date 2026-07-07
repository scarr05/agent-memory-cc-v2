# Sprint 3 Prerequisite Fixes — Combined Spec + Plan

Branch: `dev/review-fixes-2026-07` (tip 94104ab). Two independent, correctness-sensitive
fixes that must land before Sprint 3 (branch integration). One commit per fix. Never merge.

Baselines reconfirmed before any change:
- Unit suite `bash tests/handoff-lib-test.sh`: **PASS=76 FAIL=0**.
- Tier-1 (throwaway dir, absolute HOOKS_DIR): **38/40**; the 2 FAILs are Item 2.

---

## Item 1 — RC=5 fail-closed in `build_deterministic_handoff`

### Defect (reproduced)
`hooks/handoff-lib.sh`. `harvest_files` (line 41) runs one bare `jq` over the whole
transcript window. A single malformed JSON line makes jq exit **5**; the `2>/dev/null`
hides the *message* but not the *exit code*. `build_deterministic_handoff` calls
`harvest_files < "$win" | sed ...` (line 193) inside a `{ ... } > "$OUT"` group. The
`/handoff` CLI dispatcher runs under `set -euo pipefail` (line 286), so `pipefail`
propagates jq's exit 5, `set -e` aborts the brace group **before** the explicit
`return 0` (line 207), and the whole `build` command exits 5 with a partial `$OUT`.
The line-199 comment ("every harvest helper below is abort-safe") is therefore false
for `harvest_files`.

Reproduction (confirmed): a 3-line window (valid Edit / malformed line / usage line)
run via `bash handoff-lib.sh build ... </dev/null` → **RC=5**, `$OUT` present.

### Root cause
`harvest_files` is not abort-safe at the source: its `jq` fails hard on a malformed
line instead of skipping it.

### Fix (tightest altitude — at the source)
Make `harvest_files`' own `jq` tolerant: read raw (`-Rs`), split on newlines, and use
`fromjson?` per line so a malformed line is skipped and jq still exits 0. Same tolerant
parsing pattern already used successfully in `read_live_tokens` (line 75). This is tighter
than the cruder call-site `harvest_files < "$win" | sed ... || true`, which would also
swallow a genuine `sed` failure **and** leave the line-199 abort-safety claim untrue.

**Invariant (codex finding 1):** the `-Rs` + `split("\n")[]` form treats each *physical
line* as exactly one JSON value — i.e. it assumes strict JSONL (one JSON value per line).
This is true of every transcript the system consumes and every fixture; a hypothetical
producer emitting two JSON values on one line would lose that line (the old streaming `jq`
would have parsed both). Acceptable and documented; a `ponytail:` note in the code names it.

### Test (TDD, RED first)
Add to `tests/handoff-lib-test.sh`, modelled on the existing rc-leak block (line 206):
a window with one malformed JSON line, built via the real `bash handoff-lib.sh build`
CLI entrypoint (piped/throwaway, under `set -e`). Assert:
- `build CLI exits 0 on a malformed transcript line` → RC=0.
- The file is complete: Files Touched is the final section (same awk-after-NARRATIVE-END
  probe as the existing tests). Files-Touched list may legitimately be empty.

Expected: RED before the fix (RC=5), GREEN after. Unit suite 76 → 77.

---

## Item 2 — Token-nudge Tier-1 validation failure (harness bug)

### Defect (reproduced)
`tests/hook-validation.sh` Token-nudge Case A (line 502) fails with empty Stop output;
`handoff_nudge_sent=true` never written. Pre-existing (fails identically at base 18a2bef),
not a regression.

### Root cause (confirmed — harness, not hook)
Line 499: `TOKEN_FIXTURE="$PWD/tests/fixtures/transcript-windowed.jsonl"`. The harness
`cd`s into the project-under-test at line 66, so `$PWD` is that arbitrary project, not the
repo. The fixture lives under the repo's `tests/fixtures/`, so the built path does not
exist → `read_live_tokens` returns 0 → below the 150000 threshold → no nudge → empty
output → both Token-nudge assertions fail. The hook is correct: `read_live_tokens` returns
155000 on the real fixture.

The harness already anchors every other path to `SCRIPT_DIR` (line 13,
`dirname "${BASH_SOURCE[0]}"` = the `tests/` dir): RESULTS_DIR, ERROR_LOG, RO_TARGET.
The fixture reference is the outlier.

Lines 628 and 639 (session-end Cases 5/6) carry the **identical** `$PWD/tests/fixtures/...`
bug; they pass only because their assertions (handoff armed / not clobbered) don't depend
on fixture *content*. Same root cause → same fix, so a future content-dependent assertion
can't silently false-pass.

### Fix
Replace all three `$PWD/tests/fixtures/transcript-windowed.jsonl` with
`$SCRIPT_DIR/fixtures/transcript-windowed.jsonl`.

### Test
The failing Tier-1 assertion IS the test: currently RED, GREEN after the fix. No new hook
test — the hook was never at fault. Verify by running the full harness against a throwaway
dir with absolute `HOOKS_DIR`; expect 40/40.

---

## Pipeline (both items)
1. This combined doc → codex review → fold findings.
2. Per fix: reproduce (done) → RED test → implement → GREEN.
3. `/simplify` then `/security-review` over the changes; fix anything flagged.
4. Commit per fix (never batched), required trailer. `bash -n` every touched hook.
5. Update `.superpowers/sdd/progress.md`. Verify DoD line-by-line. STOP — no Sprint 3.

## Constraints
- Hooks keep `set -euo pipefail`; suite keeps `set -uo pipefail`.
- Slug-detection duplication is deliberate — do not dedupe.
- British English. Deliberate shortcuts carry a `ponytail:` comment.
- Real entrypoints tested under `set -e` (piped stdin, throwaway HOME).
