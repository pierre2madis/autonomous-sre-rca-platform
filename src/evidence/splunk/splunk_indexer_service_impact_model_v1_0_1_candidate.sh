#!/usr/bin/env bash

set -uo pipefail

VERSION="1.0.1-candidate"

RC_USAGE=2
RC_LOCAL_INPUT=3
RC_CLUSTER_INPUT=4
RC_LOCAL_JSON=5
RC_CLUSTER_JSON=6
RC_LOCAL_INVALID=20
RC_CLUSTER_INSUFFICIENT=21
RC_UNSUPPORTED_STATE=22

usage() {
    echo "Usage: $0 <consistency.json> <cluster-decision.json>" >&2
}

emit_unavailable() {
    local reason="$1"
    local confidence="$2"

    jq -n \
      --arg version "$VERSION" \
      --arg reason "$reason" \
      --arg confidence "$confidence" \
      '{
        schema_version: "1.0",
        model: {
          name: "splunk_indexer_service_impact_model",
          version: $version
        },
        decision_valid: false,
        state: null,
        severity: null,
        confidence: $confidence,
        reason: $reason,
        service_impact: null,
        boundaries: {
          remediation_authorized: false,
          incident_created: false
        }
      }'
}

[[ $# -eq 2 ]] || {
    usage
    exit "$RC_USAGE"
}

CONSISTENCY="$1"
CLUSTER="$2"

[[ -s "$CONSISTENCY" ]] || {
    emit_unavailable "CONSISTENCY_INPUT_UNAVAILABLE" "LOW"
    exit "$RC_LOCAL_INPUT"
}

[[ -s "$CLUSTER" ]] || {
    emit_unavailable "CLUSTER_DECISION_UNAVAILABLE" "LOW"
    exit "$RC_CLUSTER_INPUT"
}

jq empty "$CONSISTENCY" >/dev/null 2>&1 || {
    emit_unavailable "INVALID_CONSISTENCY_JSON" "LOW"
    exit "$RC_LOCAL_JSON"
}

jq empty "$CLUSTER" >/dev/null 2>&1 || {
    emit_unavailable "INVALID_CLUSTER_JSON" "LOW"
    exit "$RC_CLUSTER_JSON"
}

CONSISTENCY_VALID="$(
    jq -r '
      if .correlation.valid == null
      then "null"
      else (.correlation.valid | tostring)
      end
    ' "$CONSISTENCY"
)"

CONSISTENCY_STATE="$(
    jq -r '.consistency.state // "null"' "$CONSISTENCY"
)"

LOCAL_CONFIDENCE="$(
    jq -r '.local_node.confidence // "UNKNOWN"' "$CONSISTENCY"
)"

CLUSTER_VALID="$(
    jq -r '
      if .evidence.decision_valid == null
      then "null"
      else (.evidence.decision_valid | tostring)
      end
    ' "$CLUSTER"
)"

CLUSTER_CONFIDENCE="$(
    jq -r '.evidence.confidence // "UNKNOWN"' "$CLUSTER"
)"

CLUSTER_STATE="$(
    jq -r '.cluster_health.state // "null"' "$CLUSTER"
)"

CLUSTER_RCA="$(
    jq -r '.cluster_health.rca // "null"' "$CLUSTER"
)"

if [[ "$CONSISTENCY_VALID" != "true" ||
      "$CONSISTENCY_STATE" == "null" ]]; then

    emit_unavailable \
      "CONSISTENCY_DECISION_INVALID" \
      "$LOCAL_CONFIDENCE"

    exit "$RC_LOCAL_INVALID"
fi

if [[ "$CLUSTER_VALID" != "true" ||
      "$CLUSTER_STATE" == "null" ]]; then

    emit_unavailable \
      "INSUFFICIENT_CLUSTER_EVIDENCE" \
      "$CLUSTER_CONFIDENCE"

    exit "$RC_CLUSTER_INSUFFICIENT"
fi

RF="$(
    jq -r '
      if .service_guarantees.replication_factor_met == null
      then "null"
      else (.service_guarantees.replication_factor_met | tostring)
      end
    ' "$CLUSTER"
)"

SF="$(
    jq -r '
      if .service_guarantees.search_factor_met == null
      then "null"
      else (.service_guarantees.search_factor_met | tostring)
      end
    ' "$CLUSTER"
)"

SEARCHABLE="$(
    jq -r '
      if .service_guarantees.all_data_searchable == null
      then "null"
      else (.service_guarantees.all_data_searchable | tostring)
      end
    ' "$CLUSTER"
)"

INDEXING_READY="$(
    jq -r '
      if .service_guarantees.indexing_ready == null
      then "null"
      else (.service_guarantees.indexing_ready | tostring)
      end
    ' "$CLUSTER"
)"

if [[ "$RF" == "null" ||
      "$SF" == "null" ||
      "$SEARCHABLE" == "null" ||
      "$INDEXING_READY" == "null" ]]; then

    emit_unavailable \
      "SERVICE_GUARANTEES_UNAVAILABLE" \
      "$CLUSTER_CONFIDENCE"

    exit "$RC_CLUSTER_INSUFFICIENT"
fi

STATE=""
SEVERITY=""
REASON=""
SERVICE_IMPACT=""

case "$CONSISTENCY_STATE" in

    CONSISTENT_HEALTHY)

        if [[ "$CLUSTER_STATE" == "NORMAL" &&
              "$RF" == "true" &&
              "$SF" == "true" &&
              "$SEARCHABLE" == "true" &&
              "$INDEXING_READY" == "true" ]]; then

            STATE="SERVICE_HEALTHY"
            SEVERITY="none"
            REASON="NODE_AND_CLUSTER_HEALTHY"
            SERVICE_IMPACT="false"

        else

            STATE="CLUSTER_DEGRADATION_INDEPENDENT"
            SEVERITY="major"
            REASON="LOCAL_HEALTHY_CLUSTER_DEGRADED"
            SERVICE_IMPACT="false"
                    fi
        ;;

    CROSS_SOURCE_CONTRADICTION)

        STATE="OBSERVABILITY_CONTRADICTION"
        SEVERITY="warning"
        REASON="LOCAL_CM_STATE_DISAGREEMENT"
        SERVICE_IMPACT="false"
                ;;

    LOCAL_FAILURE_NOT_YET_CORROBORATED)

        if [[ "$CLUSTER_STATE" == "NORMAL" ]]; then

            STATE="LOCAL_FAILURE_CLUSTER_PROTECTED"
            SEVERITY="warning"
            REASON="LOCAL_FAILURE_NOT_VISIBLE_TO_CLUSTER"
            SERVICE_IMPACT="false"

        else

            STATE="CLUSTER_DEGRADED_LOCAL_CAUSALITY_UNCERTAIN"
            SEVERITY="major"
            REASON="LOCAL_FAILURE_AND_CLUSTER_DEGRADATION_NOT_CORROBORATED"
            SERVICE_IMPACT="false"
                    fi
        ;;

    CORROBORATED_NODE_FAILURE)

        if [[ "$CLUSTER_STATE" == "NORMAL" &&
              "$RF" == "true" &&
              "$SF" == "true" &&
              "$SEARCHABLE" == "true" &&
              "$INDEXING_READY" == "true" ]]; then

            STATE="NODE_FAILURE_REDUNDANCY_ABSORBED"
            SEVERITY="warning"
            REASON="NODE_FAILURE_CLUSTER_PROTECTED"
            SERVICE_IMPACT="false"

        elif [[ "$SEARCHABLE" == "false" ||
                "$INDEXING_READY" == "false" ]]; then

            STATE="NODE_FAILURE_SERVICE_IMPACT"
            SEVERITY="critical"
            REASON="CORROBORATED_NODE_FAILURE_WITH_SERVICE_LOSS"
            SERVICE_IMPACT="true"

        elif [[ "$RF" == "false" ||
                "$SF" == "false" ]]; then

            STATE="NODE_FAILURE_PROTECTION_DEGRADED"
            SEVERITY="major"
            REASON="CORROBORATED_NODE_FAILURE_WITH_REDUNDANCY_LOSS"
            SERVICE_IMPACT="false"

        else
            emit_unavailable \
              "UNSUPPORTED_CLUSTER_GUARANTEE_COMBINATION" \
              "$CLUSTER_CONFIDENCE"

            exit "$RC_UNSUPPORTED_STATE"
        fi
        ;;

    *)
        emit_unavailable \
          "UNSUPPORTED_CONSISTENCY_STATE" \
          "$LOCAL_CONFIDENCE"

        exit "$RC_UNSUPPORTED_STATE"
        ;;
esac

jq -n \
  --arg version "$VERSION" \
  --arg consistency_state "$CONSISTENCY_STATE" \
  --arg cluster_state "$CLUSTER_STATE" \
  --arg cluster_rca "$CLUSTER_RCA" \
  --arg rf "$RF" \
  --arg sf "$SF" \
  --arg searchable "$SEARCHABLE" \
  --arg indexing_ready "$INDEXING_READY" \
  --arg state "$STATE" \
  --arg severity "$SEVERITY" \
  --arg reason "$REASON" \
  --arg service_impact "$SERVICE_IMPACT" \
  --arg confidence "$CLUSTER_CONFIDENCE" \
  '{
    schema_version: "1.0",

    model: {
      name: "splunk_indexer_service_impact_model",
      version: $version
    },

    inputs: {
      consistency_state: $consistency_state,

      cluster: {
        state: $cluster_state,
        rca: $cluster_rca,

        service_guarantees: {
          replication_factor_met: ($rf == "true"),
          search_factor_met: ($sf == "true"),
          all_data_searchable: ($searchable == "true"),
          indexing_ready: ($indexing_ready == "true")
        }
      }
    },

    decision_valid: true,

    state: $state,
    severity: $severity,
    confidence: $confidence,
    reason: $reason,

    service_impact: ($service_impact == "true"),
    boundaries: {
      remediation_authorized: false,
      incident_created: false
    }
  }'
