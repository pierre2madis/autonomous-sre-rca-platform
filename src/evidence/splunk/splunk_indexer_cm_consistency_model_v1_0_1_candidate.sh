#!/usr/bin/env bash
#
# Splunk Indexer <-> Cluster Manager Cross-Source Consistency Model
# Version: 1.0.1-candidate
#
# Purpose:
#   Correlate an indexer's local M2.3C health decision with the
#   Cluster Manager's distributed view of the same canonical peer.
#
# This model does NOT determine cluster protection or service impact.
#
# Exit codes:
#   0  = valid correlation decision
#   2  = usage error
#   3  = local artifact unavailable
#   4  = CM artifact unavailable
#   5  = invalid local JSON
#   6  = invalid CM JSON
#   20 = canonical identity correlation failure
#   21 = local health decision unavailable/invalid
#   22 = CM peer state insufficient
#

set -uo pipefail

VERSION="1.0.1-candidate"

usage() {
    echo "Usage: $0 <local_health.json> <cm_peer_state.json>"
}

[[ $# -eq 2 ]] || {
    usage >&2
    exit 2
}

LOCAL="$1"
CM="$2"

[[ -r "$LOCAL" ]] || {
    echo "ERROR: local health artifact unavailable: $LOCAL" >&2
    exit 3
}

[[ -r "$CM" ]] || {
    echo "ERROR: CM peer artifact unavailable: $CM" >&2
    exit 4
}

jq empty "$LOCAL" >/dev/null 2>&1 || {
    echo "ERROR: invalid local JSON" >&2
    exit 5
}

jq empty "$CM" >/dev/null 2>&1 || {
    echo "ERROR: invalid CM JSON" >&2
    exit 6
}

LOCAL_GUID="$(jq -r '.identity.guid // ""' "$LOCAL")"
LOCAL_HOST="$(jq -r '.identity.host // ""' "$LOCAL")"

LOCAL_VALID="$(jq -r '.node_health.decision_valid // false' "$LOCAL")"
LOCAL_STATE="$(jq -r '.node_health.state // ""' "$LOCAL")"
LOCAL_SEVERITY="$(jq -r '.node_health.severity // ""' "$LOCAL")"
LOCAL_SCORE="$(jq -r '.node_health.score // "null"' "$LOCAL")"
LOCAL_CONFIDENCE="$(jq -r '.node_health.confidence // ""' "$LOCAL")"
LOCAL_RCA="$(jq -r '.node_health.rca // ""' "$LOCAL")"

CM_GUID="$(jq -r '.identity.guid // ""' "$CM")"
CM_LABEL="$(jq -r '.identity.label // ""' "$CM")"
CM_SITE="$(jq -r '.identity.site // ""' "$CM")"
CM_STATUS="$(jq -r '.peer_state.status // ""' "$CM")"
CM_SEARCHABLE="$(jq -r 'if .peer_state.searchable == null then "null" else (.peer_state.searchable|tostring) end' "$CM")"
CM_HEARTBEAT="$(jq -r 'if .peer_state.heartbeat_started == null then "null" else (.peer_state.heartbeat_started|tostring) end' "$CM")"

LOCAL_GUID_NORM="$(printf '%s' "$LOCAL_GUID" | tr '[:lower:]' '[:upper:]')"
CM_GUID_NORM="$(printf '%s' "$CM_GUID" | tr '[:lower:]' '[:upper:]')"

CORRELATION_VALID=false
IDENTITY_MATCH=false
CONSISTENCY_STATE="UNAVAILABLE"
REASON=""
RC=0

#
# Stage 1 — canonical identity
#
if [[ -z "$LOCAL_GUID" ]]; then
    REASON="LOCAL_GUID_UNAVAILABLE"
    RC=20

elif [[ -z "$CM_GUID" ]]; then
    REASON="CM_GUID_UNAVAILABLE"
    RC=20

elif [[ "$LOCAL_GUID_NORM" != "$CM_GUID_NORM" ]]; then
    REASON="IDENTITY_MISMATCH"
    RC=20

else
    IDENTITY_MATCH=true
fi

#
# Stage 2 — evidence admissibility
#
if (( RC == 0 )); then

    if [[ "$LOCAL_VALID" != "true" || -z "$LOCAL_STATE" ]]; then
        REASON="LOCAL_HEALTH_UNAVAILABLE"
        RC=21

    elif [[ -z "$CM_STATUS" || "$CM_SEARCHABLE" == "null" ]]; then
        REASON="CM_PEER_STATE_INSUFFICIENT"
        RC=22
    fi
fi

#
# Stage 3 — cross-source consistency
#
if (( RC == 0 )); then

    CORRELATION_VALID=true

    CM_UP=false
    CM_SEARCHABLE_BOOL=false

    [[ "${CM_STATUS,,}" == "up" ]] && CM_UP=true
    [[ "$CM_SEARCHABLE" == "true" ]] && CM_SEARCHABLE_BOOL=true

    case "$LOCAL_STATE" in

        NORMAL)
            if [[ "$CM_UP" == true &&
                  "$CM_SEARCHABLE_BOOL" == true ]]; then

                CONSISTENCY_STATE="CONSISTENT_HEALTHY"
                REASON="LOCAL_NORMAL_CM_UP_SEARCHABLE"

            else
                CONSISTENCY_STATE="CROSS_SOURCE_CONTRADICTION"
                REASON="LOCAL_NORMAL_CM_IMPAIRED"
            fi
            ;;

        WATCH|DEGRADED)
            if [[ "$CM_UP" == true &&
                  "$CM_SEARCHABLE_BOOL" == true ]]; then

                CONSISTENCY_STATE="LOCAL_DEGRADATION"
                REASON="LOCAL_DEGRADED_CM_STILL_OPERATIONAL"

            else
                CONSISTENCY_STATE="CORROBORATED_DEGRADATION"
                REASON="LOCAL_DEGRADATION_CM_IMPAIRED"
            fi
            ;;

        CRITICAL)
            if [[ "$CM_UP" == true &&
                  "$CM_SEARCHABLE_BOOL" == true ]]; then

                CONSISTENCY_STATE="LOCAL_FAILURE_NOT_YET_CORROBORATED"
                REASON="LOCAL_CRITICAL_CM_STILL_OPERATIONAL"

            else
                CONSISTENCY_STATE="CORROBORATED_NODE_FAILURE"
                REASON="LOCAL_CRITICAL_CM_IMPAIRED"
            fi
            ;;

        *)
            CORRELATION_VALID=false
            CONSISTENCY_STATE="UNAVAILABLE"
            REASON="UNSUPPORTED_LOCAL_STATE"
            RC=21
            ;;
    esac
fi

jq -n \
  --arg version "$VERSION" \
  --arg local_guid "$LOCAL_GUID" \
  --arg local_host "$LOCAL_HOST" \
  --arg local_state "$LOCAL_STATE" \
  --arg local_severity "$LOCAL_SEVERITY" \
  --argjson local_score "$LOCAL_SCORE" \
  --arg local_confidence "$LOCAL_CONFIDENCE" \
  --arg local_rca "$LOCAL_RCA" \
  --arg cm_guid "$CM_GUID" \
  --arg cm_label "$CM_LABEL" \
  --arg cm_site "$CM_SITE" \
  --arg cm_status "$CM_STATUS" \
  --argjson cm_searchable "$CM_SEARCHABLE" \
  --argjson cm_heartbeat "$CM_HEARTBEAT" \
  --argjson identity_match "$IDENTITY_MATCH" \
  --argjson valid "$CORRELATION_VALID" \
  --arg consistency_state "$CONSISTENCY_STATE" \
  --arg reason "$REASON" \
  '{
    model:{
      name:"splunk_indexer_cm_consistency_model",
      version:$version
    },

    correlation:{
      canonical_key:"splunk_instance_guid",
      valid:$valid,
      identity_match:$identity_match
    },

    local:{
      identity:{
        guid:$local_guid,
        host:$local_host
      },

      health:{
        state:$local_state,
        severity:$local_severity,
        score:$local_score,
        confidence:$local_confidence,
        rca:$local_rca
      }
    },

    cluster_manager:{
      identity:{
        guid:$cm_guid,
        label:$cm_label,
        site:$cm_site
      },

      peer_state:{
        status:$cm_status,
        searchable:$cm_searchable,
        heartbeat_started:$cm_heartbeat
      }
    },

    consistency:{
      state:$consistency_state,
      reason:$reason
    },

    boundaries:{
      cluster_protection_evaluated:false,
      service_impact_evaluated:false,
      incident_decision_evaluated:false
    }
  }'

exit "$RC"
