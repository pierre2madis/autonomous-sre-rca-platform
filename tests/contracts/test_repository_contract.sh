#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ARCH="$ROOT/ARCHITECTURE.md"
SRE="$ROOT/docs/sre/sre-model.md"

[[ -s "$ARCH" ]]
[[ -s "$SRE" ]]

[[ "$(grep -c '^## ' "$ARCH")" -eq 7 ]]
[[ "$(grep -c '^## ' "$SRE")" -eq 9 ]]

grep -Fxq "## Safety Model" "$ARCH"
grep -Fxq "## CI/CD Relationship" "$ARCH"

grep -Fxq "## Service Level Indicators" "$SRE"
grep -Fxq "## Service Level Objectives" "$SRE"
grep -Fxq "## Mean Time To Recovery" "$SRE"
grep -Fxq "## SLO Gate" "$SRE"

echo "REPOSITORY_CONTRACT=PASS"
