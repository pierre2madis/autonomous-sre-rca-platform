#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REQUIRED_SUITES=(
    contracts
    golden
    integration
    adversarial
)

FAIL=0

echo "============================================================"
echo " RELEASE TEST READINESS GATE"
echo "============================================================"

for suite in "${REQUIRED_SUITES[@]}"; do
    dir="$ROOT/tests/$suite"

    count="$(
        find "$dir" -maxdepth 1 -type f -name 'test_*.sh' | wc -l
    )"

    echo "${suite^^}_TEST_COUNT=$count"

    if [[ "$count" -gt 0 ]]; then
        echo "PASS: $suite"
    else
        echo "BLOCKED: $suite suite is empty"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "RELEASE_READINESS_FAILURES=$FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "RELEASE_TEST_READINESS=PASS"
    exit 0
fi

echo "RELEASE_TEST_READINESS=BLOCKED"
exit 1
