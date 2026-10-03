#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "============================================================"
echo " PUBLIC REPOSITORY SECURITY AUDIT"
echo "============================================================"

SECRET_FILES="$(
    find "$ROOT" -type f \
      \( -name '.env' -o -name '*.pem' -o -name '*.key' \
      -o -iname '*credentials*' -o -iname '*secrets*' \) \
      ! -path "$ROOT/.git/*"
)"

if [[ -z "$SECRET_FILES" ]]; then
    echo "PASS: no secret-like files"
else
    echo "FAIL: secret-like files detected"
    printf '%s\n' "$SECRET_FILES"
    FAIL=$((FAIL + 1))
fi

echo
echo "SECURITY_AUDIT_FAILURES=$FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "SECURITY_AUDIT_STATUS=PASS"
    exit 0
fi

echo "SECURITY_AUDIT_STATUS=FAIL"
exit 1
