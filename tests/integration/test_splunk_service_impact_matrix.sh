#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODEL="$REPO_ROOT/src/evidence/splunk/splunk_indexer_service_impact_model_v1_0_1_candidate.sh"
BASE="$REPO_ROOT/tests/fixtures/splunk/service-impact/indexer_consistency.json"
CM_DIR="$REPO_ROOT/tests/fixtures/splunk/service-impact"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1"
    FAIL=$((FAIL + 1))
}

run_case() {
    local NAME="$1"
    local LOCAL="$2"
    local CM="$3"
    local EXPECT_RC="$4"
    local EXPECT_VALID="$5"
    local EXPECT_STATE="$6"
    local EXPECT_IMPACT="$7"

    local OUT="$WORK/${NAME}.json"

    echo
    echo "------------------------------------------------------------"
    echo "CASE=$NAME"
    echo "------------------------------------------------------------"

    "$MODEL" "$LOCAL" "$CM" > "$OUT"
    local RC=$?

    echo "rc=$RC"
    jq . "$OUT"

    if [[ "$RC" -eq "$EXPECT_RC" ]]; then
        pass "$NAME rc=$EXPECT_RC"
    else
        fail "$NAME rc expected=$EXPECT_RC actual=$RC"
    fi

    if jq -e \
       --argjson v "$EXPECT_VALID" \
       '.decision_valid == $v' \
       "$OUT" >/dev/null; then
        pass "$NAME decision_valid=$EXPECT_VALID"
    else
        fail "$NAME decision_valid"
    fi

    if [[ "$EXPECT_STATE" == "null" ]]; then
        if jq -e '.state == null' "$OUT" >/dev/null; then
            pass "$NAME state=null"
        else
            fail "$NAME state=null"
        fi
    else
        if jq -e \
           --arg s "$EXPECT_STATE" \
           '.state == $s' \
           "$OUT" >/dev/null; then
            pass "$NAME state=$EXPECT_STATE"
        else
            fail "$NAME state=$EXPECT_STATE"
        fi
    fi

    if [[ "$EXPECT_IMPACT" == "null" ]]; then
        if jq -e '.service_impact == null' "$OUT" >/dev/null; then
            pass "$NAME service_impact=null"
        else
            fail "$NAME service_impact=null"
        fi
    else
        if jq -e \
           --argjson i "$EXPECT_IMPACT" \
           '.service_impact == $i' \
           "$OUT" >/dev/null; then
            pass "$NAME service_impact=$EXPECT_IMPACT"
        else
            fail "$NAME service_impact=$EXPECT_IMPACT"
        fi
    fi

    if jq -e '
        .boundaries.remediation_authorized == false
        and .boundaries.incident_created == false
        and (has("incident_recommended") | not)
    ' "$OUT" >/dev/null; then
        pass "$NAME architectural boundaries"
    else
        fail "$NAME architectural boundaries"
    fi
}

echo "============================================================"
echo " M2.3D-4E-R2 — SERVICE IMPACT REPLAY MATRIX"
echo "============================================================"

echo
echo "=== PREREQUISITES ==="

for F in \
    "$MODEL" \
    "$BASE" \
    "$CM_DIR/normal.json" \
    "$CM_DIR/protection_degraded.json" \
    "$CM_DIR/peer_down.json" \
    "$CM_DIR/insufficient.json"
do
    if [[ -s "$F" ]]; then
        pass "available: $F"
    else
        fail "unavailable: $F"
    fi
done

if ! jq empty "$BASE" >/dev/null 2>&1; then
    fail "baseline consistency JSON invalid"
fi

(( FAIL == 0 )) || {
    echo "FAIL: prerequisites"
    exit 1
}

echo
echo "=== SYNTHETIC CONSISTENCY INPUTS ==="

make_consistency() {
    local STATE="$1"
    local OUT="$2"

    jq \
      --arg state "$STATE" \
      '.consistency.state = $state' \
      "$BASE" > "$OUT"
}

make_consistency \
    "CONSISTENT_HEALTHY" \
    "$WORK/local_healthy.json"

make_consistency \
    "CROSS_SOURCE_CONTRADICTION" \
    "$WORK/contradiction.json"

make_consistency \
    "LOCAL_FAILURE_NOT_YET_CORROBORATED" \
    "$WORK/local_failure.json"

make_consistency \
    "CORROBORATED_NODE_FAILURE" \
    "$WORK/corroborated_failure.json"

for F in \
    "$WORK/local_healthy.json" \
    "$WORK/contradiction.json" \
    "$WORK/local_failure.json" \
    "$WORK/corroborated_failure.json"
do
    jq empty "$F" >/dev/null 2>&1 || {
        fail "generated consistency JSON invalid: $F"
        exit 1
    }
done

echo
echo "=== REPLAY CASES ==="

# 1. Healthy node + healthy protected cluster.
run_case \
    "case01_service_healthy" \
    "$WORK/local_healthy.json" \
    "$CM_DIR/normal.json" \
    0 true \
    "SERVICE_HEALTHY" \
    false

# 2. Corroborated peer failure, but cluster guarantees remain protected.
run_case \
    "case02_redundancy_absorbed" \
    "$WORK/corroborated_failure.json" \
    "$CM_DIR/normal.json" \
    0 true \
    "NODE_FAILURE_REDUNDANCY_ABSORBED" \
    false

# 3. Corroborated peer failure + RF/SF violation,
#    but data remains searchable and indexing remains ready.
run_case \
    "case03_protection_degraded" \
    "$WORK/corroborated_failure.json" \
    "$CM_DIR/protection_degraded.json" \
    0 true \
    "NODE_FAILURE_PROTECTION_DEGRADED" \
    false

# 4. Corroborated peer failure + explicit global searchability loss.
run_case \
    "case04_service_impact" \
    "$WORK/corroborated_failure.json" \
    "$CM_DIR/peer_down.json" \
    0 true \
    "NODE_FAILURE_SERVICE_IMPACT" \
    true

# 5. Protection evidence unavailable: fail closed.
run_case \
    "case05_insufficient_cluster_evidence" \
    "$WORK/corroborated_failure.json" \
    "$CM_DIR/insufficient.json" \
    21 false \
    null \
    null

# 6. Local/CM contradiction remains contradiction.
run_case \
    "case06_observability_contradiction" \
    "$WORK/contradiction.json" \
    "$CM_DIR/normal.json" \
    0 true \
    "OBSERVABILITY_CONTRADICTION" \
    false

# 7. Local failure not yet corroborated by CM,
#    while cluster protection remains healthy.
run_case \
    "case07_local_failure_cluster_protected" \
    "$WORK/local_failure.json" \
    "$CM_DIR/normal.json" \
    0 true \
    "LOCAL_FAILURE_CLUSTER_PROTECTED" \
    false

echo
echo "=== OUTPUT HASHES ==="
sha256sum "$WORK"/case*.json

echo
echo "============================================================"
echo " M2.3D-4E-R2 SUMMARY"
echo "============================================================"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
echo "TOTAL=$((PASS + FAIL))"

if (( FAIL == 0 )); then
    echo "SERVICE IMPACT REPLAY MATRIX: PASS"
    exit 0
else
    echo "SERVICE IMPACT REPLAY MATRIX: FAIL"
    exit 1
fi
