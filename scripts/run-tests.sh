#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="${1:-}"

case "$SUITE" in
    unit|contracts|golden|integration|adversarial)
        ;;
    *)
        echo "Usage: $0 {unit|contracts|golden|integration|adversarial}" >&2
        exit 2
        ;;
esac

TEST_DIR="$ROOT/tests/$SUITE"

echo "============================================================"
echo " TEST SUITE: $SUITE"
echo "============================================================"

mapfile -t TESTS < <(
    find "$TEST_DIR" -maxdepth 1 -type f -name 'test_*.sh' | sort
)

echo "TEST_COUNT=${#TESTS[@]}"

if [[ "${#TESTS[@]}" -eq 0 ]]; then
    echo "TEST_SUITE_STATUS=EMPTY"
    exit 0
fi

PASS=0
FAIL=0

for test_file in "${TESTS[@]}"; do
    name="$(basename "$test_file")"

    if bash "$test_file"; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "TEST_PASS=$PASS"
echo "TEST_FAIL=$FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "TEST_SUITE_STATUS=PASS"
    exit 0
fi

echo "TEST_SUITE_STATUS=FAIL"
exit 1
