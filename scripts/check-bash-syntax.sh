#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

echo "============================================================"
echo " BASH SYNTAX VALIDATION"
echo "============================================================"

while IFS= read -r file; do
    if bash -n "$file"; then
        echo "PASS: ${file#$ROOT/}"
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${file#$ROOT/}"
        FAIL=$((FAIL + 1))
    fi
done < <(find "$ROOT" -type f -name '*.sh' | sort)

echo
echo "BASH_SYNTAX_PASS=$PASS"
echo "BASH_SYNTAX_FAIL=$FAIL"

[[ "$FAIL" -eq 0 ]] || exit 1

echo "BASH_SYNTAX_STATUS=PASS"
