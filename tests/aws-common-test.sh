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
