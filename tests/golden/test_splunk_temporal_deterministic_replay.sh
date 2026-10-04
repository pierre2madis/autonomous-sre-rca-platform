#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODEL="$REPO_ROOT/src/correlation/splunk_temporal_pair_correlation_model_v1_1_0_candidate.sh"
BASE_CAUSE="$REPO_ROOT/tests/fixtures/splunk/temporal/causal_semantic_cause.json"
BASE_EFFECT="$REPO_ROOT/tests/fixtures/splunk/temporal/causal_semantic_effect.json"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

EXPECTED_MODEL_SHA="d81d9b0213a112fd6c289de3a0289d4a9a191f3b79e657bb8be11a9946069d5f"

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

echo "============================================================"
echo " M2.3D-5E-R11-5 — DETERMINISTIC REPLAY / BYTE IDENTITY"
echo "============================================================"

MODEL_SHA="$(sha256sum "$MODEL" | awk '{print $1}')"

[[ "$MODEL_SHA" == "$EXPECTED_MODEL_SHA" ]] \
    && pass "candidate model SHA unchanged" \
    || fail "candidate model SHA changed"

BASE_CAUSE_SHA="$(sha256sum "$BASE_CAUSE" | awk '{print $1}')"
BASE_EFFECT_SHA="$(sha256sum "$BASE_EFFECT" | awk '{print $1}')"

CAUSE_TS="2026-10-02T15:00:00Z"

make_pair() {
    local NAME="$1"
    local EFFECT_TS="$2"

    jq \
      --arg ts "$CAUSE_TS" \
      '.temporal.observed_at.value=$ts' \
      "$BASE_CAUSE" \
      > "$WORK/${NAME}_cause.json"

    jq \
      --arg ts "$EFFECT_TS" \
      '.temporal.observed_at.value=$ts' \
      "$BASE_EFFECT" \
      > "$WORK/${NAME}_effect.json"
}

make_pair inside_window \
          "2026-10-02T15:03:20Z"

make_pair exact_boundary \
          "2026-10-02T15:05:00Z"

make_pair outside_window \
          "2026-10-02T15:05:01Z"

make_pair reverse_order \
          "2026-10-02T14:55:00Z"

make_pair simultaneous \
          "2026-10-02T15:00:00Z"

jq '
  .temporal.observed_at.value=null
  | .temporal.observed_at.available=false
  | .temporal.observed_at.authoritative=false
' "$BASE_CAUSE" > "$WORK/not_evaluable_cause.json"

cp "$BASE_EFFECT" "$WORK/not_evaluable_effect.json"

run_replay_case() {
    local NAME="$1"
    local EXPECT_RC="$2"

    local CAUSE="$WORK/${NAME}_cause.json"
    local EFFECT="$WORK/${NAME}_effect.json"

    echo
    echo "------------------------------------------------------------"
    echo "CASE=$NAME"
    echo "------------------------------------------------------------"

    local FIRST_SHA=""
    local FIRST_RC=""
    local FIRST_OUT=""

    for RUN in 1 2 3 4 5
    do
        OUT="$WORK/${NAME}_run_${RUN}.json"
        ERR="$WORK/${NAME}_run_${RUN}.err"

        set +e
        "$MODEL" "$CAUSE" "$EFFECT" 300 \
            > "$OUT" \
            2> "$ERR"
        RC=$?
        set -e

        SHA="$(sha256sum "$OUT" | awk '{print $1}')"
        ERR_SHA="$(sha256sum "$ERR" | awk '{print $1}')"

        echo "run=$RUN rc=$RC output_sha=$SHA stderr_sha=$ERR_SHA"

        [[ "$RC" -eq "$EXPECT_RC" ]] \
            && pass "$NAME run $RUN rc stable" \
            || fail "$NAME run $RUN expected rc=$EXPECT_RC actual=$RC"

        if [[ "$RUN" -eq 1 ]]; then
            FIRST_SHA="$SHA"
            FIRST_RC="$RC"
            FIRST_OUT="$OUT"

            pass "$NAME deterministic baseline captured"
        else
            [[ "$RC" -eq "$FIRST_RC" ]] \
                && pass "$NAME run $RUN rc equals baseline" \
                || fail "$NAME run $RUN rc differs from baseline"

            [[ "$SHA" == "$FIRST_SHA" ]] \
                && pass "$NAME run $RUN SHA equals baseline" \
                || fail "$NAME run $RUN SHA differs from baseline"

            if cmp -s "$FIRST_OUT" "$OUT"; then
                pass "$NAME run $RUN byte-identical output"
            else
                fail "$NAME run $RUN output differs byte-for-byte"
            fi
        fi
    done

    echo
    echo "baseline_output_sha=$FIRST_SHA"

    CAUSE_SHA="$(sha256sum "$CAUSE" | awk '{print $1}')"
    EFFECT_SHA="$(sha256sum "$EFFECT" | awk '{print $1}')"

    jq -e \
      --arg csha "$CAUSE_SHA" \
      --arg esha "$EFFECT_SHA" '
        .pair_provenance.cause.artifact_sha256 == $csha
        and
        .pair_provenance.effect.artifact_sha256 == $esha
      ' "$FIRST_OUT" >/dev/null \
        && pass "$NAME provenance deterministic" \
        || fail "$NAME provenance incorrect"

    jq -e '
        .causal_admissibility.confirmed_causality_admissible == false
        and
        .boundaries.causal_claim_confirmed == false
        and
        .boundaries.parent_event_assigned == false
        and
        .boundaries.incident_created == false
        and
        .boundaries.remediation_authorized == false
      ' "$FIRST_OUT" >/dev/null \
        && pass "$NAME authority boundaries deterministic" \
        || fail "$NAME authority boundaries changed"
}

run_replay_case inside_window 0
run_replay_case exact_boundary 0
run_replay_case outside_window 0
run_replay_case reverse_order 0
run_replay_case simultaneous 0
run_replay_case not_evaluable 20

echo
echo "=== INPUT IMMUTABILITY ==="

FINAL_BASE_CAUSE_SHA="$(
    sha256sum "$BASE_CAUSE" |
    awk '{print $1}'
)"

FINAL_BASE_EFFECT_SHA="$(
    sha256sum "$BASE_EFFECT" |
    awk '{print $1}'
)"

FINAL_MODEL_SHA="$(
    sha256sum "$MODEL" |
    awk '{print $1}'
)"

[[ "$FINAL_BASE_CAUSE_SHA" == "$BASE_CAUSE_SHA" ]] \
    && pass "baseline cause unchanged" \
    || fail "baseline cause changed"

[[ "$FINAL_BASE_EFFECT_SHA" == "$BASE_EFFECT_SHA" ]] \
    && pass "baseline effect unchanged" \
    || fail "baseline effect changed"

[[ "$FINAL_MODEL_SHA" == "$EXPECTED_MODEL_SHA" ]] \
    && pass "candidate model remained byte-identical" \
    || fail "candidate model changed"

echo
echo "=== REPLAY OUTPUT SHA MATRIX ==="

for CASE in \
    inside_window \
    exact_boundary \
    outside_window \
    reverse_order \
    simultaneous \
    not_evaluable
do
    echo
    echo "CASE=$CASE"

    sha256sum "$WORK/${CASE}"_run_*.json
done

echo
echo "=== MODEL IDENTITY ==="
sha256sum "$MODEL"

echo
echo "============================================================"
echo " M2.3D-5E-R11-5 SUMMARY"
echo "============================================================"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
echo "TOTAL=$((PASS + FAIL))"

if (( FAIL == 0 )); then
    echo "V1.1 DETERMINISTIC REPLAY / BYTE IDENTITY: PASS"
    exit 0
else
    echo "V1.1 DETERMINISTIC REPLAY / BYTE IDENTITY: FAIL"
    exit 1
fi
