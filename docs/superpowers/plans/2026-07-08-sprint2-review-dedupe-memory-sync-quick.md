# Sprint 2 — Review Dedupe Guard & memory-sync Quick Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop duplicate reviews of byte-identical diffs (a UserPromptSubmit hook) and add a low-ceremony `--quick` mode to `/memory-sync`.

**Architecture:** `review-dedupe.sh` follows the existing hook pattern exactly (see `hooks/prompt-corrections.sh`): bash, `set -euo pipefail`, fast exit on the common case, `additionalContext` JSON output via jq. State lives under `~/.claude/review-dedupe/` (outside repos, nothing to gitignore). Tests follow the `tests/handoff-lib-test.sh` pattern: standalone bash script, `FAIL=0` summary.

**Tech Stack:** Bash (Git Bash/MSYS — LF line endings mandatory, pinned by `.gitattributes`), jq, sha256sum, git.

## Global Constraints

- Repo: `~/Documents/Projects/agent-memory-cc-v2-files`. Branch: `git checkout -b sprint2-dedupe-quick-sync`.
- Hooks must NEVER block or fail the prompt: every exit path is `exit 0`; all writes `|| true`.
- Hot-path budget: a prompt that is not a review command must exit before spawning git or sha256sum (one jq call to parse the prompt is acceptable — prompt-corrections.sh already pays one).
- Scope note (spec items already done, do NOT re-implement): stop-hook once-only guard, handoff-over-compaction nudge, empty-checkpoint discard — all landed in the Jul 2–7 review-fixes merge.

---

### Task 1: review-dedupe hook

**Files:**
- Create: `hooks/review-dedupe.sh`
- Test: `tests/review-dedupe-test.sh`
- Modify: `hooks/hooks.json` (add to the existing `UserPromptSubmit` matcher group)
- Modify: `~/.claude/settings.json` (live wiring — user installs hooks by direct path, not plugin root)

**Interfaces:**
- Consumes: UserPromptSubmit stdin JSON `{"prompt": "...", ...}`; git state of `$PWD`.
- Produces: on duplicate — `{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "<warning>"}}` on stdout. Otherwise no output. State file `~/.claude/review-dedupe/<repo-key>` containing `<sha256> <iso-timestamp>`.

- [ ] **Step 1: Write the failing test**

Create `tests/review-dedupe-test.sh`:

```bash
#!/usr/bin/env bash
# review-dedupe-test.sh — tests for hooks/review-dedupe.sh
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/review-dedupe.sh"
PASS=0; FAIL=0

check() { # <desc> <expected-grep-or-EMPTY> <actual>
    local desc="$1" want="$2" got="$3"
    if [[ "$want" == "EMPTY" ]]; then
        [[ -z "$got" ]] && { PASS=$((PASS+1)); echo "PASS: $desc"; } \
                        || { FAIL=$((FAIL+1)); echo "FAIL: $desc — expected empty, got: $got"; }
    else
        grep -q "$want" <<<"$got" && { PASS=$((PASS+1)); echo "PASS: $desc"; } \
                                  || { FAIL=$((FAIL+1)); echo "FAIL: $desc — wanted '$want', got: $got"; }
    fi
}

payload() { jq -n --arg p "$1" '{"prompt": $p}'; }

# Isolated HOME so real state is untouched
export HOME="$(mktemp -d)"
REPO="$(mktemp -d)"
cd "$REPO"
git init -q
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo "line1" > f.txt

# 1. Non-review prompt: no output
OUT=$(payload "hello world" | bash "$HOOK")
check "non-review prompt silent" EMPTY "$OUT"

# 2. First review of a diff: no warning, state recorded
OUT=$(payload "/security-review" | bash "$HOOK")
check "first review silent" EMPTY "$OUT"
STATE_COUNT=$(ls "$HOME/.claude/review-dedupe" 2>/dev/null | wc -l)
check "state file written" "1" "$STATE_COUNT"

# 3. Identical diff reviewed again: warning fires
OUT=$(payload "/security-review" | bash "$HOOK")
check "duplicate diff warns" "already reviewed" "$OUT"
check "warning is additionalContext JSON" "hookSpecificOutput" "$OUT"

# 4. Diff changed: silent again
echo "line2" >> f.txt
OUT=$(payload "/security-review" | bash "$HOOK")
check "changed diff silent" EMPTY "$OUT"

# 5. /code-review also matched
OUT=$(payload "/code-review high" | bash "$HOOK")
check "code-review duplicate warns" "already reviewed" "$OUT"

# 6. Outside a git repo: silent, exit 0
cd "$(mktemp -d)"
OUT=$(payload "/security-review" | bash "$HOOK"); RC=$?
check "non-repo silent" EMPTY "$OUT"
check "non-repo exit 0" "0" "$RC"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/review-dedupe-test.sh`
Expected: FAIL (hook file does not exist — every case errors or is empty where output was wanted).

- [ ] **Step 3: Write the hook**

Create `hooks/review-dedupe.sh`:

```bash
#!/usr/bin/env bash
# review-dedupe.sh — UserPromptSubmit hook.
# Warns when /security-review or /code-review is invoked on a diff whose hash
# matches the last-reviewed hash for this repo (audit: 4 duplicate-pair reviews
# on byte-identical diffs, one pair 17s apart). Warn-only — never blocks.
set -euo pipefail

RAW=$(cat || true)
PROMPT=$(printf '%s' "$RAW" | jq -r '.prompt // empty' 2>/dev/null || true)

# Hot path: only review commands pay anything beyond the jq parse.
case "$PROMPT" in
    /security-review*|/code-review*) ;;
    *) exit 0 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Hash = HEAD commit + working+staged diff. Clean tree at the same commit
# hashes identically — that IS the duplicate-branch-review case we want caught.
HASH=$( { git rev-parse HEAD 2>/dev/null; git diff HEAD 2>/dev/null; } | sha256sum | cut -d' ' -f1)

STATE_DIR="$HOME/.claude/review-dedupe"
REPO_KEY=$(printf '%s' "$PWD" | sha256sum | cut -c1-16)
STATE_FILE="$STATE_DIR/$REPO_KEY"
mkdir -p "$STATE_DIR" 2>/dev/null || true

if [[ -f "$STATE_FILE" ]]; then
    read -r PREV_HASH PREV_TIME < "$STATE_FILE" || true
    if [[ "$HASH" == "${PREV_HASH:-}" ]]; then
        MSG="Review dedupe: this exact diff (${HASH:0:12}…) was already reviewed at ${PREV_TIME:-unknown}. Tell the user and confirm before re-running the review."
        jq -n --arg ctx "$MSG" \
            '{"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": $ctx}}'
        exit 0   # dupe: do NOT refresh the timestamp
    fi
fi

printf '%s %s\n' "$HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$STATE_FILE" 2>/dev/null || true
exit 0
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/review-dedupe-test.sh`
Expected: `PASS=9 FAIL=0`, exit 0.

- [ ] **Step 5: Wire it — plugin manifest and live settings**

In `hooks/hooks.json`, add a second command to the existing `UserPromptSubmit[0].hooks` array:

```json
{
  "type": "command",
  "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/review-dedupe.sh"
}
```

In `~/.claude/settings.json`, the `UserPromptSubmit` group currently runs `bash ~/.claude/hooks/prompt-corrections.sh`; add alongside it:

```json
{
  "type": "command",
  "command": "bash ~/.claude/hooks/review-dedupe.sh"
}
```

Then deploy the hook file to the live location:

```bash
cp hooks/review-dedupe.sh ~/.claude/hooks/review-dedupe.sh
file ~/.claude/hooks/review-dedupe.sh   # must NOT report CRLF
```

- [ ] **Step 6: Live smoke test**

In any git repo with changes, type `/security-review`, let it complete (or Escape after it starts), then type `/security-review` again — the second prompt should surface the dedupe warning in Claude's context (ask Claude "did a dedupe warning fire?").

- [ ] **Step 7: Commit**

```bash
git add hooks/review-dedupe.sh hooks/hooks.json tests/review-dedupe-test.sh
git commit -m "feat: review-dedupe UserPromptSubmit hook - warn on byte-identical re-review"
```

---

### Task 2: /memory-sync --quick

**Files:**
- Modify: `commands/memory-sync.md`
- Modify: `~/.claude/commands/memory-sync.md` if the live copy is a file (check; if the command is served from the repo/plugin, skip the second copy)

**Interfaces:**
- Consumes: existing memory-sync flag conventions (`--dream`, `--ingest`, `--tidy`, `--status` are documented near line 28 of `commands/memory-sync.md`).
- Produces: a `--quick` flag documented in the same style.

- [ ] **Step 1: Add the flag to the flags list**

In `commands/memory-sync.md`, in the flags list (around line 28, alongside `--dream`), add:

```markdown
- **--quick** — Fast path: write the session note from the current conversation without the interactive learnings-proposal pass. Only propose learnings if the session contains an explicit correction or decision; otherwise write the note and stop. Use for routine sessions where full ceremony isn't worth the tokens.
```

- [ ] **Step 2: Add the mode section**

Add a section after the main sync flow (before `## Dream Mode (--dream)`, around line 302):

```markdown
## Quick Mode (--quick)

Skip steps that need user interaction. Concretely:

1. Write the session note to `5 Agent Memory/sessions/by-project/<slug>/` as normal (frontmatter, summary, decisions, next steps).
2. Scan the session for corrections or explicit decisions. If NONE: mark `.session-meta` `synced=true`, clean staging, and finish — no learnings proposal, no questions.
3. If corrections/decisions exist: list them in one message for approval (rule 3 in global CLAUDE.md still applies — never write to `learnings/` unapproved), then finish.

Quick mode never runs --ingest or --tidy.
```

- [ ] **Step 3: Verify**

Run: `grep -n "\-\-quick" commands/memory-sync.md`
Expected: 2+ hits (flag list + section).

- [ ] **Step 4: Live check**

In this session run `/memory-sync --quick` and confirm it writes the note without the learnings interview (session has decisions, so expect the single approval message).

- [ ] **Step 5: Commit**

```bash
git add commands/memory-sync.md
git commit -m "feat: /memory-sync --quick - session note without learnings interview"
```

---

### Task 3: Merge

- [ ] **Step 1: Run the full hook regression suite**

```bash
HOOKS_DIR=./hooks bash tests/hook-validation.sh "$PWD" agent-memory
bash tests/review-dedupe-test.sh
```
Expected: `FAIL=0` on both.

- [ ] **Step 2: Merge**

```bash
git checkout main && git merge sprint2-dedupe-quick-sync && git branch -d sprint2-dedupe-quick-sync
```
