#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

check_file() {
    local file="$1"

    if [[ -s "$ROOT/$file" ]]; then
        echo "PASS: $file"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $file"
        FAIL=$((FAIL + 1))
    fi
}

echo "============================================================"
echo " REPOSITORY CONTRACT VALIDATION"
echo "============================================================"

echo
echo "=== REQUIRED FILES ==="

check_file "README.md"
check_file "ROADMAP.md"
check_file "ARCHITECTURE.md"
check_file "docs/sre/sre-model.md"
check_file "Makefile"
check_file ".gitignore"

echo
echo "=== ARCHITECTURE CONTRACT ==="

ARCH_SECTIONS="$(grep -c '^## ' "$ROOT/ARCHITECTURE.md" || true)"
echo "ARCHITECTURE_SECTIONS=$ARCH_SECTIONS"

if [[ "$ARCH_SECTIONS" -eq 7 ]]; then
    echo "PASS: architecture section count"
    PASS=$((PASS + 1))
else
    echo "FAIL: architecture section count"
    FAIL=$((FAIL + 1))
fi

echo
echo "=== SRE CONTRACT ==="

SRE_SECTIONS="$(grep -c '^## ' "$ROOT/docs/sre/sre-model.md" || true)"
echo "SRE_SECTIONS=$SRE_SECTIONS"

if [[ "$SRE_SECTIONS" -eq 9 ]]; then
    echo "PASS: SRE section count"
    PASS=$((PASS + 1))
else
    echo "FAIL: SRE section count"
    FAIL=$((FAIL + 1))
fi

echo
echo "=== SEMANTIC CONTRACT ==="

REQUIRED_TERMS=(
    "SLI"
    "SLO"
    "MTTR"
    "Splunk"
    "Dynatrace"
    "n8n"
)

for term in "${REQUIRED_TERMS[@]}"; do
    if grep -Rqs "$term" \
        "$ROOT/README.md" \
        "$ROOT/ARCHITECTURE.md" \
        "$ROOT/docs/sre"; then
        echo "PASS: required concept: $term"
        PASS=$((PASS + 1))
    else
        echo "FAIL: required concept: $term"
        FAIL=$((FAIL + 1))
    fi
done

echo
echo "============================================================"
echo "VALIDATION_PASS=$PASS"
echo "VALIDATION_FAIL=$FAIL"

if [[ "$FAIL" -eq 0 ]]; then
    echo "REPOSITORY_VALIDATION=PASS"
    exit 0
else
    echo "REPOSITORY_VALIDATION=FAIL"
    exit 1
fi
