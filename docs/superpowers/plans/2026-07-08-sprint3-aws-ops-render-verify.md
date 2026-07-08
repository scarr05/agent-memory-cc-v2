# Sprint 3 — AWS Ops Helpers & render-verify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One-command replacements for the audit's repeated manual loops: float AWS diagnostics (CloudWatch metric pulls, SSM instance lookups, deploy watching) and draw.io render→crop→inspect cycles.

**Architecture:** Bash scripts in `scripts/aws/` sharing one common lib that enforces the float SSO profile; a `float-ops` skill documents the landing zone and points Claude at the scripts; a standalone Python script handles render-verify. Everything versioned in this repo.

**Tech Stack:** Bash (Git Bash), AWS CLI v2 (SSO), jq, gh CLI, Python 3 + Pillow, draw.io desktop CLI.

## Global Constraints

- Repo: `~/Documents/Projects/agent-memory-cc-v2-files`. Branch: `git checkout -b sprint3-aws-render`.
- AWS auth is **SSO to the management account under profile `float-management`** — every script defaults `AWS_PROFILE=float-management` and fails fast with the exact login command when the token is expired. Never embed keys.
- All `.sh` files LF (pinned by `.gitattributes`).
- Python: always `encoding="utf-8"` on `open()` (Windows cp1252 default).
- British English in docs.

---

### Task 1: Float landing zone doc (discovery + write-up)

**Files:**
- Create: `docs/float-landing-zone.md`

**Interfaces:**
- Produces: the doc `skills/float-ops/SKILL.md` (Task 5) links to; account IDs/regions consumed by Task 3's default config.

- [ ] **Step 1: Discover the real values**

Run in `~/Documents/Projects/float-platform`:

```bash
grep -rn "float-management\|sso_" ~/.aws/config | head -40
aws configure list-profiles | grep -i float
grep -rniE "account.?id|[0-9]{12}" --include="*.ts" --include="*.tf" --include="*.json" -l . | head -20
```

Record: every float-* profile, its SSO start URL, account ID, role, default region; the workload account structure (which accounts exist under the management account and what runs where).

- [ ] **Step 2: Write the doc**

Create `docs/float-landing-zone.md` with this skeleton, populated from Step 1 (no field left as a placeholder — if a value can't be discovered, ask Sam before committing):

```markdown
# Float Landing Zone

## Account structure

| Account | ID | Purpose |
|---------|----|---------|
| management | <from step 1> | SSO home, org root |
| <workload accounts from step 1> | | |

## CLI auth

Auth is AWS SSO to the **management account**, profile **`float-management`**:

```bash
aws sso login --profile float-management
```

Token expiry symptom: `Error loading SSO Token` / `The SSO session associated with this profile has expired`. Fix is always the login command above — do not switch to keys.

All helper scripts in `scripts/aws/` default to this profile; override with `AWS_PROFILE=<other> script.sh` only for cross-account work.

## Regions

Default region: <from step 1>.
```

- [ ] **Step 3: Commit**

```bash
git add docs/float-landing-zone.md
git commit -m "docs: float landing zone - accounts, SSO auth via float-management"
```

---

### Task 2: aws-common.sh (shared auth guard)

**Files:**
- Create: `scripts/aws/aws-common.sh`
- Test: `tests/aws-common-test.sh`

**Interfaces:**
- Produces: `require_aws` function — sourced by every other script; sets `AWS_PROFILE` (default `float-management`), verifies the SSO token with `aws sts get-caller-identity`, exits 1 with the login command on failure. Also `AWS_JSON=(--output json --no-cli-pager)` array.

- [ ] **Step 1: Write the failing test**

Create `tests/aws-common-test.sh`:

```bash
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../scripts/aws/aws-common.sh"
PASS=0; FAIL=0
check() { [[ "$2" == *"$1"* ]] && { PASS=$((PASS+1)); echo "PASS: $3"; } || { FAIL=$((FAIL+1)); echo "FAIL: $3 — got: $2"; }; }

# Fake aws binary that always fails auth
FAKE=$(mktemp -d)
cat > "$FAKE/aws" <<'EOF'
#!/usr/bin/env bash
echo "Error loading SSO Token: Token for float-management does not exist" >&2
exit 255
EOF
chmod +x "$FAKE/aws"

# 1. Default profile is float-management
OUT=$(PATH="$FAKE:$PATH" bash -c "source '$LIB'; require_aws" 2>&1); RC=$?
check "aws sso login --profile float-management" "$OUT" "expired token prints login command"
[[ $RC -ne 0 ]] && { PASS=$((PASS+1)); echo "PASS: non-zero exit on auth failure"; } || { FAIL=$((FAIL+1)); echo "FAIL: expected non-zero exit"; }

# 2. Explicit AWS_PROFILE respected
OUT=$(PATH="$FAKE:$PATH" AWS_PROFILE=other bash -c "source '$LIB'; require_aws" 2>&1) || true
check "aws sso login --profile other" "$OUT" "explicit profile respected"

echo "----"; echo "PASS=$PASS FAIL=$FAIL"; [[ $FAIL -eq 0 ]]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/aws-common-test.sh` — Expected: FAIL (lib missing).

- [ ] **Step 3: Implement**

Create `scripts/aws/aws-common.sh`:

```bash
#!/usr/bin/env bash
# aws-common.sh — shared guard for float AWS helper scripts.
# Auth model: SSO to the management account, profile float-management.

export AWS_PROFILE="${AWS_PROFILE:-float-management}"
AWS_JSON=(--output json --no-cli-pager)

require_aws() {
    if ! aws sts get-caller-identity "${AWS_JSON[@]}" >/dev/null 2>&1; then
        echo "AWS auth failed for profile '$AWS_PROFILE'. Run:" >&2
        echo "  aws sso login --profile $AWS_PROFILE" >&2
        return 1
    fi
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/aws-common-test.sh` — Expected: `PASS=3 FAIL=0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/aws/aws-common.sh tests/aws-common-test.sh
git commit -m "feat: aws-common.sh - float-management SSO guard for helper scripts"
```

---

### Task 3: cw-dash.sh (the recurring 6-metric pull)

**Files:**
- Create: `scripts/aws/cw-dash.sh`
- Create: `scripts/aws/metrics.json`

**Interfaces:**
- Consumes: `require_aws` from Task 2; `metrics.json` config.
- Produces: one-command table of the metric set Sam repeatedly hand-built (audit: same 6-metric CloudWatch query rebuilt across sessions).

- [ ] **Step 1: Recover the exact metric set**

The audit chunks live at `%LOCALAPPDATA%\Temp\claude\C--Users-user-Documents-Projects-cc-scratch\1902e258-16e5-4dd7-9adc-fed006642735\scratchpad\chunks\` (if purged, grep the float-platform transcripts directly):

```bash
grep -h "get-metric" ~/.claude/projects/*float*/*.jsonl | head -20
```

Record the 6 metrics (namespace, metric name, dimensions, stat). Populate `scripts/aws/metrics.json`:

```json
{
  "region": "<default region from docs/float-landing-zone.md>",
  "period": 300,
  "metrics": [
    {"id": "m1", "namespace": "<discovered>", "name": "<discovered>", "dimensions": [{"Name": "<d>", "Value": "<v>"}], "stat": "Average"}
  ]
}
```

(All six entries populated with discovered values — placeholder entries are a task failure; ask Sam if the transcripts are ambiguous.)

- [ ] **Step 2: Implement**

Create `scripts/aws/cw-dash.sh`:

```bash
#!/usr/bin/env bash
# cw-dash.sh [hours] — pull the standard float metric set for the last N hours (default 3).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aws-common.sh"
require_aws

HOURS="${1:-3}"
CFG="$SCRIPT_DIR/metrics.json"
REGION=$(jq -r '.region' "$CFG")
PERIOD=$(jq -r '.period' "$CFG")
START=$(date -u -d "-${HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

QUERIES=$(jq '[.metrics[] | {Id: .id, MetricStat: {Metric: {Namespace: .namespace, MetricName: .name, Dimensions: .dimensions}, Period: '"$PERIOD"', Stat: .stat}}]' "$CFG")

aws cloudwatch get-metric-data "${AWS_JSON[@]}" \
    --region "$REGION" \
    --start-time "$START" --end-time "$END" \
    --metric-data-queries "$QUERIES" \
| jq -r '.MetricDataResults[] | [.Id, .Label, (.Values | if length > 0 then (last | tostring) else "no data" end), (.Values | length | tostring) + " pts"] | @tsv' \
| column -t -s $'\t'
```

- [ ] **Step 3: Verify live**

Run: `bash scripts/aws/cw-dash.sh 3`
Expected: a table with one row per configured metric showing the latest value; or the SSO login instruction if the token is stale (run it and retry).

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/cw-dash.sh scripts/aws/metrics.json
git commit -m "feat: cw-dash.sh - one-command float CloudWatch metric pull"
```

---

### Task 4: ssm-ids.sh and deploy-watch.sh

**Files:**
- Create: `scripts/aws/ssm-ids.sh`
- Create: `scripts/aws/deploy-watch.sh`

**Interfaces:**
- Consumes: `require_aws`/`AWS_JSON` from Task 2; `gh` CLI (already authenticated).
- Produces: `ssm-ids.sh [--refresh]` prints `instance-id  name  state` lines (cached 1h at `~/.claude/aws-cache/ssm-ids-<profile>`); `deploy-watch.sh [run-id]` exits 0 only when the run's `conclusion` is `success`.

- [ ] **Step 1: Implement ssm-ids.sh**

```bash
#!/usr/bin/env bash
# ssm-ids.sh [--refresh] — instance ids/names/states, cached 1h.
# Audit: the same instance-id lookup ran 4x in one investigation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/aws-common.sh"

CACHE_DIR="$HOME/.claude/aws-cache"
CACHE="$CACHE_DIR/ssm-ids-$AWS_PROFILE"
mkdir -p "$CACHE_DIR"

if [[ "${1:-}" != "--refresh" && -f "$CACHE" ]]; then
    AGE=$(( $(date +%s) - $(stat -c %Y "$CACHE") ))
    if [[ $AGE -lt 3600 ]]; then cat "$CACHE"; exit 0; fi
fi

require_aws
aws ec2 describe-instances "${AWS_JSON[@]}" \
| jq -r '.Reservations[].Instances[] | [.InstanceId, ((.Tags // []) | map(select(.Key=="Name")) | .[0].Value // "-"), .State.Name] | @tsv' \
| column -t -s $'\t' | tee "$CACHE"
```

- [ ] **Step 2: Implement deploy-watch.sh**

```bash
#!/usr/bin/env bash
# deploy-watch.sh [run-id] — watch a GitHub Actions run and verify the REAL
# conclusion. Audit: `gh run watch` exit code reported success while 3 deploys
# were still running; never trust it alone.
set -euo pipefail

RUN_ID="${1:-$(gh run list --limit 1 --json databaseId --jq '.[0].databaseId')}"
[[ -n "$RUN_ID" ]] || { echo "no runs found" >&2; exit 1; }

gh run watch "$RUN_ID" || true   # progress display only; its exit code lies

STATUS=$(gh run view "$RUN_ID" --json status,conclusion --jq '"\(.status) \(.conclusion)"')
echo "run $RUN_ID: $STATUS"
[[ "$STATUS" == "completed success" ]]
```

- [ ] **Step 3: Verify**

```bash
bash scripts/aws/ssm-ids.sh          # live table, then instant on second call (cache)
bash scripts/aws/ssm-ids.sh          # second call: same output, no AWS call (~instant)
cd ~/Documents/Projects/float-platform && bash ~/Documents/Projects/agent-memory-cc-v2-files/scripts/aws/deploy-watch.sh
```
Expected: deploy-watch prints `run <id>: completed success` and exits 0 for the latest green run (pick a completed run id explicitly if the latest is in progress).

- [ ] **Step 4: Commit**

```bash
git add scripts/aws/ssm-ids.sh scripts/aws/deploy-watch.sh
git commit -m "feat: ssm-ids cache + deploy-watch with verified conclusion"
```

---

### Task 5: float-ops skill

**Files:**
- Create: `skills/float-ops/SKILL.md`

**Interfaces:**
- Consumes: everything from Tasks 1–4.

- [ ] **Step 1: Write the skill**

```markdown
---
name: float-ops
description: Operate and diagnose the float platform on AWS. Use for any float AWS work - checking metrics, instance lookups, deploy status, auth problems, or questions about the float landing zone/account structure. Triggers on "float", "landing zone", "float-management", CloudWatch/SSM/deploy checks in the float context.
---

# Float Ops

## Auth (read this first)

SSO to the management account, profile `float-management`. Expired token → run `aws sso login --profile float-management`. Full account structure: `docs/float-landing-zone.md` in the agent-memory-cc-v2 repo.

## Helpers (use these instead of hand-building CLI calls)

All in `~/Documents/Projects/agent-memory-cc-v2-files/scripts/aws/`:

| Script | Purpose |
|--------|---------|
| `cw-dash.sh [hours]` | The standard float metric set, one table |
| `ssm-ids.sh [--refresh]` | Instance id/name/state, cached 1h |
| `deploy-watch.sh [run-id]` | Watch GH Actions run; exit 0 ONLY on verified `completed success` — never trust `gh run watch`'s exit code |

Scripts fail fast with the login command when the SSO token is stale — relay it to the user, don't work around it.
```

- [ ] **Step 2: Deploy and verify**

```bash
cp -r skills/float-ops ~/.claude/skills/float-ops
```
In a fresh session ask: "check the float metrics" — confirm the skill triggers and Claude reaches for `cw-dash.sh`.

- [ ] **Step 3: Commit**

```bash
git add skills/float-ops/SKILL.md
git commit -m "feat: float-ops skill - landing zone auth + helper script index"
```

---

### Task 6: render-verify script

**Files:**
- Create: `scripts/render-verify.py`
- Modify: `~/.claude/skills/drawio/SKILL.md` (add pointer; master copy if the drawio skill is versioned elsewhere — it is a personal skill, live copy only)

**Interfaces:**
- Consumes: draw.io desktop CLI (`draw.io.exe --export`); Pillow.
- Produces: `python scripts/render-verify.py <file.drawio> [page]` → prints the path of a rendered, auto-cropped PNG for a single Read call.

- [ ] **Step 1: Write the failing test**

The draw.io CLI is slow; test the crop logic only. Create `tests/render-verify-test.py`:

```python
import subprocess, sys, tempfile, os
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from render_verify import autocrop  # noqa: E402

def test_autocrop_strips_border():
    img = Image.new("RGB", (200, 200), "white")
    for x in range(90, 110):
        for y in range(90, 110):
            img.putpixel((x, y), (255, 0, 0))
    cropped = autocrop(img, margin=5)
    assert cropped.size == (30, 30), cropped.size  # 20px content + 2*5 margin

if __name__ == "__main__":
    test_autocrop_strips_border()
    print("PASS=1 FAIL=0")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python tests/render-verify-test.py`
Expected: `ModuleNotFoundError: No module named 'render_verify'`.

- [ ] **Step 3: Implement**

Create `scripts/render-verify.py` (module name `render_verify` — hyphens break import; name the FILE `render_verify.py`, adjust the test import to match, and expose a `render-verify` alias nowhere — callers use the underscore name):

```python
"""render_verify.py — render a .drawio file to an auto-cropped PNG in one command.

Usage: python render_verify.py diagram.drawio [page-index]
Prints the PNG path on success. Replaces the manual render->crop->inspect loop
(audit: 9 cycles for one diagram).
"""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageChops

DRAWIO = r"C:\Program Files\draw.io\draw.io.exe"

def autocrop(img, margin=10):
    bg = Image.new(img.mode, img.size, (255, 255, 255))
    bbox = ImageChops.difference(img.convert("RGB"), bg.convert("RGB")).getbbox()
    if not bbox:
        return img
    left, top, right, bottom = bbox
    left = max(0, left - margin); top = max(0, top - margin)
    right = min(img.width, right + margin); bottom = min(img.height, bottom + margin)
    return img.crop((left, top, right, bottom))

def main():
    src = Path(sys.argv[1]).resolve()
    page = sys.argv[2] if len(sys.argv) > 2 else "0"
    out = Path(tempfile.gettempdir()) / f"{src.stem}-p{page}.png"
    subprocess.run(
        [DRAWIO, "--export", "--format", "png", "--scale", "2",
         "--page-index", page, "--output", str(out), str(src)],
        check=True, capture_output=True)
    img = Image.open(out)
    autocrop(img).save(out)
    print(out)

if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python tests/render-verify-test.py` — Expected: `PASS=1 FAIL=0`.

- [ ] **Step 5: End-to-end check**

Run against any existing `.drawio` file (there are several in `~/Documents/Projects` — e.g. from the Azure-Diagrams or Diagram-aaS projects):
`python scripts/render_verify.py <some>.drawio` → prints a PNG path; open/Read it and confirm it is cropped to content.

- [ ] **Step 6: Point the drawio skill at it**

Append to `~/.claude/skills/drawio/SKILL.md`:

```markdown
## Visual verification

To inspect a rendered result, run `python ~/Documents/Projects/agent-memory-cc-v2-files/scripts/render_verify.py <file.drawio> [page]` and Read the printed PNG path — one command, already cropped. Do NOT hand-build render/crop loops.
```

- [ ] **Step 7: Commit**

```bash
git add scripts/render_verify.py tests/render-verify-test.py
git commit -m "feat: render_verify.py - one-shot drawio render + autocrop"
```

---

### Task 7: Merge

- [ ] **Step 1: Full test pass**

```bash
bash tests/aws-common-test.sh && python tests/render-verify-test.py
```
Expected: `FAIL=0` on both.

- [ ] **Step 2: Merge**

```bash
git checkout main && git merge sprint3-aws-render && git branch -d sprint3-aws-render
```
