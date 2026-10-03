#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "============================================================"
echo " SHELLCHECK QUALITY GATE"
echo "============================================================"

if ! command -v shellcheck >/dev/null 2>&1; then
    echo "SHELLCHECK_AVAILABLE=false"
    echo "SHELLCHECK_STATUS=SKIPPED"
    echo "Install ShellCheck to enable local static analysis."
    exit 0
fi

echo "SHELLCHECK_AVAILABLE=true"

mapfile -t FILES < <(
    find "$ROOT" -type f -name '*.sh' | sort
)

echo "SHELL_FILES=${#FILES[@]}"

if [[ "${#FILES[@]}" -eq 0 ]]; then
    echo "SHELLCHECK_STATUS=PASS"
    exit 0
fi

shellcheck "${FILES[@]}"

echo "SHELLCHECK_STATUS=PASS"
