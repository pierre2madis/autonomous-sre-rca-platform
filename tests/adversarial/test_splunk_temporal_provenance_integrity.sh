#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MODEL="$REPO_ROOT/src/correlation/splunk_temporal_pair_correlation_model_v1_1_0_candidate.sh"
CAUSE="$REPO_ROOT/tests/fixtures/splunk/temporal/causal_semantic_cause.json"
EFFECT="$REPO_ROOT/tests/fixtures/splunk/temporal/causal_semantic_effect.json"

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

run_valid_case() {
    local NAME="$1"
    local C="$2"
    local E="$3"

    local OUT="$WORK/${NAME}_decision.json"

    set +e
    "$MODEL" "$C" "$E" 300 > "$OUT"
    local RC=$?
    set -e

    echo
    echo "------------------------------------------------------------"
    echo "CASE=$NAME"
    echo "------------------------------------------------------------"
    echo "rc=$RC"

    [[ "$RC" -eq 0 ]] \
        && pass "$NAME execution" \
        || fail "$NAME execution rc=$RC"

    local C_SHA
    local E_SHA

    C_SHA="$(sha256sum "$C" | awk '{print $1}')"
    E_SHA="$(sha256sum "$E" | awk '{print $1}')"

    jq -e \
      --arg csha "$C_SHA" \
      --arg esha "$E_SHA" '
        .pair_provenance.cause.artifact_sha256 == $csha
        and
        .pair_provenance.effect.artifact_sha256 == $esha
      ' "$OUT" >/dev/null \
        && pass "$NAME exact byte provenance" \
        || fail "$NAME exact byte provenance"

    jq -e '
        .decision_valid == true
        and
        .temporal_state == "TEMPORALLY_ADMISSIBLE"
        and
        .ordering == "CAUSE_BEFORE_EFFECT"
        and
        .delta_seconds == 200
        and
        .causal_admissibility.temporal_evidence_admissible == true
      ' "$OUT" >/dev/null \
        && pass "$NAME temporal mathematics unchanged" \
        || fail "$NAME temporal mathematics changed"

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
      ' "$OUT" >/dev/null \
        && pass "$NAME authority boundaries" \
        || fail "$NAME authority boundaries"
}

run_hard_failure() {
    local NAME="$1"
    local C="$2"
    local E="$3"
    local WINDOW="$4"
    local EXPECT_RC="$5"

    local OUT="$WORK/${NAME}.out"

    set +e
    "$MODEL" "$C" "$E" "$WINDOW" > "$OUT" 2>&1
    local RC=$?
    set -e

    echo
    echo "------------------------------------------------------------"
    echo "CASE=$NAME"
    echo "------------------------------------------------------------"
    echo "rc=$RC"

    [[ "$RC" -eq "$EXPECT_RC" ]] \
        && pass "$NAME expected rc=$EXPECT_RC" \
        || fail "$NAME expected=$EXPECT_RC actual=$RC"

    if jq -e '
        .causal_admissibility.temporal_evidence_admissible == true
        or
        .causal_admissibility.confirmed_causality_admissible == true
        or
        .boundaries.causal_claim_confirmed == true
        or
        .boundaries.parent_event_assigned == true
        or
        .boundaries.incident_created == true
        or
        .boundaries.remediation_authorized == true
      ' "$OUT" >/dev/null 2>&1
    then
        fail "$NAME fabricated positive authority"
    else
        pass "$NAME no fabricated positive authority"
    fi
}

echo "============================================================"
echo " M2.3D-5E-R11-4 — ADVERSARIAL PROVENANCE INTEGRITY"
echo "============================================================"

echo
echo "=== MODEL IDENTITY ==="

MODEL_SHA="$(sha256sum "$MODEL" | awk '{print $1}')"

[[ "$MODEL_SHA" == "$EXPECTED_MODEL_SHA" ]] \
    && pass "V1.1 model SHA unchanged" \
    || fail "V1.1 model SHA changed"

BASE_CAUSE_SHA="$(sha256sum "$CAUSE" | awk '{print $1}')"
BASE_EFFECT_SHA="$(sha256sum "$EFFECT" | awk '{print $1}')"

#
# 1. GUID substitution.
#
jq '
  .entity.guid =
    "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
' "$CAUSE" > "$WORK/guid_substitution_cause.json"

run_valid_case \
    "guid_substitution" \
    "$WORK/guid_substitution_cause.json" \
    "$EFFECT"

jq -e '
    .pair_provenance.cause.entity.guid ==
      "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
' "$WORK/guid_substitution_decision.json" >/dev/null \
    && pass "GUID substitution represented exactly" \
    || fail "GUID substitution hidden or normalized"

GUID_MUTATED_SHA="$(
    sha256sum "$WORK/guid_substitution_cause.json" |
    awk '{print $1}'
)"

[[ "$GUID_MUTATED_SHA" != "$BASE_CAUSE_SHA" ]] \
    && pass "GUID substitution changes cause SHA" \
    || fail "GUID substitution did not change cause SHA"

#
# 2. Cause event semantic substitution.
#
jq '
  .event.type="SOME_OTHER_FAILURE"
' "$CAUSE" > "$WORK/cause_event_substitution.json"

run_valid_case \
    "cause_event_substitution" \
    "$WORK/cause_event_substitution.json" \
    "$EFFECT"

jq -e '
    .pair_provenance.cause.event.type ==
      "SOME_OTHER_FAILURE"
' "$WORK/cause_event_substitution_decision.json" >/dev/null \
    && pass "cause event substitution represented exactly" \
    || fail "cause event substitution hidden"

CAUSE_EVENT_SHA="$(
    sha256sum "$WORK/cause_event_substitution.json" |
    awk '{print $1}'
)"

[[ "$CAUSE_EVENT_SHA" != "$BASE_CAUSE_SHA" ]] \
    && pass "cause event substitution changes SHA" \
    || fail "cause event substitution did not change SHA"

#
# 3. Effect event semantic substitution.
#
jq '
  .event.type="SOME_OTHER_SERVICE_IMPACT"
' "$EFFECT" > "$WORK/effect_event_substitution.json"

run_valid_case \
    "effect_event_substitution" \
    "$CAUSE" \
    "$WORK/effect_event_substitution.json"

jq -e '
    .pair_provenance.effect.event.type ==
      "SOME_OTHER_SERVICE_IMPACT"
' "$WORK/effect_event_substitution_decision.json" >/dev/null \
    && pass "effect event substitution represented exactly" \
    || fail "effect event substitution hidden"

EFFECT_EVENT_SHA="$(
    sha256sum "$WORK/effect_event_substitution.json" |
    awk '{print $1}'
)"

[[ "$EFFECT_EVENT_SHA" != "$BASE_EFFECT_SHA" ]] \
    && pass "effect event substitution changes SHA" \
    || fail "effect event substitution did not change SHA"

#
# 4. Effect domain substitution.
#
jq '
  .entity.domain="OTHER_SERVICE"
  | .event.domain="OTHER_SERVICE"
' "$EFFECT" > "$WORK/effect_domain_substitution.json"

run_valid_case \
    "effect_domain_substitution" \
    "$CAUSE" \
    "$WORK/effect_domain_substitution.json"

jq -e '
    .pair_provenance.effect.entity.domain == "OTHER_SERVICE"
    and
    .pair_provenance.effect.event.domain == "OTHER_SERVICE"
' "$WORK/effect_domain_substitution_decision.json" >/dev/null \
    && pass "effect domain substitution represented exactly" \
    || fail "effect domain substitution hidden"

EFFECT_DOMAIN_SHA="$(
    sha256sum "$WORK/effect_domain_substitution.json" |
    awk '{print $1}'
)"

[[ "$EFFECT_DOMAIN_SHA" != "$BASE_EFFECT_SHA" ]] \
    && pass "effect domain substitution changes SHA" \
    || fail "effect domain substitution did not change SHA"

#
# Important:
# V1.1 is a temporal correlation model, not a semantic validator.
# The four mutations above must therefore remain visible in provenance;
# V1.1 must NOT silently normalize or hide them.
#
# Cross-artifact semantic rejection belongs to M2.3D-5F.
#

#
# 5. Unavailable cause event time.
#
jq '
  .temporal.observed_at.value=null
  | .temporal.observed_at.available=false
  | .temporal.observed_at.authoritative=false
' "$CAUSE" > "$WORK/unavailable_cause.json"

set +e
"$MODEL" \
  "$WORK/unavailable_cause.json" \
  "$EFFECT" \
  300 > "$WORK/unavailable_decision.json"
RC=$?
set -e

[[ "$RC" -eq 20 ]] \
    && pass "unavailable cause time rc=20" \
    || fail "unavailable cause time expected rc=20 actual=$RC"

UNAVAILABLE_SHA="$(
    sha256sum "$WORK/unavailable_cause.json" |
    awk '{print $1}'
)"

jq -e \
  --arg sha "$UNAVAILABLE_SHA" '
    .decision_valid == true
    and
    .temporal_state == "NOT_EVALUABLE"
    and
    .reason == "AUTHORITATIVE_EVENT_TIMESTAMPS_UNAVAILABLE"
    and
    .pair_provenance.cause.artifact_sha256 == $sha
    and
    .causal_admissibility.temporal_evidence_admissible == false
    and
    .causal_admissibility.confirmed_causality_admissible == false
  ' "$WORK/unavailable_decision.json" >/dev/null \
    && pass "unavailable evidence provenance preserved" \
    || fail "unavailable evidence provenance incorrect"

#
# 6. Malformed cause.
#
printf '{invalid cause\n' > "$WORK/malformed_cause.json"

run_hard_failure \
    "malformed_cause" \
    "$WORK/malformed_cause.json" \
    "$EFFECT" \
    300 \
    5

#
# 7. Malformed effect.
#
printf '{invalid effect\n' > "$WORK/malformed_effect.json"

run_hard_failure \
    "malformed_effect" \
    "$CAUSE" \
    "$WORK/malformed_effect.json" \
    300 \
    6

#
# 8. Invalid window.
#
run_hard_failure \
    "invalid_window" \
    "$CAUSE" \
    "$EFFECT" \
    0 \
    7

#
# 9. Invalid cause timestamp.
#
jq '
  .temporal.observed_at.value="NOT-A-TIMESTAMP"
' "$CAUSE" > "$WORK/invalid_cause_timestamp.json"

run_hard_failure \
    "invalid_cause_timestamp" \
    "$WORK/invalid_cause_timestamp.json" \
    "$EFFECT" \
    300 \
    8

#
# 10. Invalid effect timestamp.
#
jq '
  .temporal.observed_at.value="NOT-A-TIMESTAMP"
' "$EFFECT" > "$WORK/invalid_effect_timestamp.json"

run_hard_failure \
    "invalid_effect_timestamp" \
    "$CAUSE" \
    "$WORK/invalid_effect_timestamp.json" \
    300 \
    9

echo
echo "=== BASELINE IMMUTABILITY ==="

FINAL_CAUSE_SHA="$(sha256sum "$CAUSE" | awk '{print $1}')"
FINAL_EFFECT_SHA="$(sha256sum "$EFFECT" | awk '{print $1}')"
FINAL_MODEL_SHA="$(sha256sum "$MODEL" | awk '{print $1}')"

[[ "$FINAL_CAUSE_SHA" == "$BASE_CAUSE_SHA" ]] \
    && pass "baseline cause envelope unchanged" \
    || fail "baseline cause envelope changed"

[[ "$FINAL_EFFECT_SHA" == "$BASE_EFFECT_SHA" ]] \
    && pass "baseline effect envelope unchanged" \
    || fail "baseline effect envelope changed"

[[ "$FINAL_MODEL_SHA" == "$EXPECTED_MODEL_SHA" ]] \
    && pass "model remained byte-identical during adversarial test" \
    || fail "model changed during adversarial test"

echo
echo "=== KEY ARTIFACT IDENTITIES ==="

sha256sum \
    "$MODEL" \
    "$CAUSE" \
    "$EFFECT"

echo
echo "============================================================"
echo " M2.3D-5E-R11-4 SUMMARY"
echo "============================================================"
echo "PASS=$PASS"
echo "FAIL=$FAIL"
echo "TOTAL=$((PASS + FAIL))"

if (( FAIL == 0 )); then
    echo "V1.1 ADVERSARIAL PROVENANCE INTEGRITY: PASS"
    exit 0
else
    echo "V1.1 ADVERSARIAL PROVENANCE INTEGRITY: FAIL"
    exit 1
fi
