#!/usr/bin/env bash
# review-dedupe-test.sh — tests for hooks/review-dedupe.sh
set -u
# MSYS mangles leading-slash jq args ("/security-review" -> C:/...); argv-only issue — real hook input arrives on stdin
export MSYS_NO_PATHCONV=1
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
# tracked: the hook hashes HEAD + git diff HEAD (staged+worktree); untracked files are invisible to it by design
git add f.txt

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

# 7. Repo with no commits (unborn HEAD): silent, exit 0
cd "$(mktemp -d)"
git init -q
OUT=$(payload "/security-review" | bash "$HOOK"); RC=$?
check "unborn-HEAD silent" EMPTY "$OUT"
check "unborn-HEAD exit 0" "0" "$RC"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
