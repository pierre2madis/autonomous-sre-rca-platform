#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Splunk Cluster Manager Decision Model
# Version: 1.1.0-candidate
#
# Input:
#   Canonical combined evidence produced by:
#     splunk_cm_evidence_adapter_v1_0_0_candidate.sh
#
# Principles:
#   - Evidence availability and health are separate concepts.
#   - NORMAL requires complete peer AND protection evidence.
#   - Overall score = MAX(dimensions), never sum.
#   - RCA identifies the primary condition.
#   - Impact records secondary service consequences.
###############################################################################

VERSION="1.1.0-candidate"
INPUT="${1:-/dev/stdin}"

if [[ "$INPUT" != "/dev/stdin" && ! -r "$INPUT" ]]; then
    echo "ERROR: input not readable: $INPUT" >&2
    exit 2
fi

JSON="$(cat "$INPUT")"

if ! jq -e . >/dev/null 2>&1 <<<"$JSON"; then
    echo "ERROR: invalid JSON" >&2
    exit 3
fi

###############################################################################
# Evidence contract
###############################################################################

EVIDENCE_STATUS="$(jq -r '.evidence.status // "UNAVAILABLE"' <<<"$JSON")"
CONFIDENCE="$(jq -r '.evidence.confidence // "LOW"' <<<"$JSON")"

PEER_AVAILABLE="$(
    jq -r '.evidence.sources.peer.available // false' <<<"$JSON"
)"

PROTECTION_AVAILABLE="$(
    jq -r '.evidence.sources.protection.available // false' <<<"$JSON"
)"

###############################################################################
# No usable evidence
###############################################################################

if [[ "$EVIDENCE_STATUS" == "UNAVAILABLE" ]]; then
    jq -n \
      --arg version "$VERSION" \
      '{
        schema_version:"1.0",

        decision_model:{
          name:"splunk_cm_decision_model",
          version:$version
        },

        evidence_status:"UNAVAILABLE",
        decision_valid:false,

        state:null,
        severity:null,
        score:null,

        rca:"INSUFFICIENT_EVIDENCE",
        confidence:"LOW"
      }'

    exit 0
fi

###############################################################################
# Partial evidence
#
# V1.1 deliberately refuses to assert cluster health when either mandatory
# source is missing.
###############################################################################

if [[ "$PEER_AVAILABLE" != "true" ||
      "$PROTECTION_AVAILABLE" != "true" ]]; then

    jq -n \
      --arg version "$VERSION" \
      --arg evidence_status "$EVIDENCE_STATUS" \
      --arg confidence "$CONFIDENCE" \
      --argjson peer_available "$PEER_AVAILABLE" \
      --argjson protection_available "$PROTECTION_AVAILABLE" \
      '{
        schema_version:"1.0",

        decision_model:{
          name:"splunk_cm_decision_model",
          version:$version
        },

        evidence_status:$evidence_status,
        decision_valid:false,

        state:null,
        severity:null,
        score:null,

        rca:"INSUFFICIENT_EVIDENCE",
        confidence:$confidence,

        evidence_capabilities:{
          peer:$peer_available,
          protection:$protection_available
        }
      }'

    exit 0
fi

###############################################################################
# Peer evidence
###############################################################################

DISCOVERED="$(jq -r '.cluster_manager.peers.discovered // 0' <<<"$JSON")"
UP="$(jq -r '.cluster_manager.peers.up // 0' <<<"$JSON")"
DOWN="$(jq -r '.cluster_manager.peers.down // 0' <<<"$JSON")"

SEARCHABLE="$(
    jq -r '.cluster_manager.peers.searchable // 0' <<<"$JSON"
)"

NOT_SEARCHABLE="$(
    jq -r '.cluster_manager.peers.not_searchable // 0' <<<"$JSON"
)"

PENDING="$(
    jq -r '.cluster_manager.peers.pending_jobs // 0' <<<"$JSON"
)"

REPLICATION_JOBS="$(
    jq -r '.cluster_manager.peers.replication_jobs // 0' <<<"$JSON"
)"

FIXUP_COUNT="$(
    jq '
      [
        .cluster_manager.peers.members[]?
        | select(
            .fixup_set != null
            and .fixup_set != ""
          )
      ]
      | length
    ' <<<"$JSON"
)"

MAINTENANCE="$(
    jq -r \
      '.cluster_manager.configuration.maintenance_mode // false' \
      <<<"$JSON"
)"

###############################################################################
# Protection evidence
###############################################################################

RF_MET="$(
    jq -r '.data_protection.replication_factor_met' <<<"$JSON"
)"

SF_MET="$(
    jq -r '.data_protection.search_factor_met' <<<"$JSON"
)"

ALL_SEARCHABLE="$(
    jq -r '.data_protection.all_data_searchable' <<<"$JSON"
)"

INDEXING_READY="$(
    jq -r '.data_protection.indexing_ready' <<<"$JSON"
)"

###############################################################################
# Sanity
###############################################################################

if (( DISCOVERED == 0 )); then
    jq -n \
      --arg version "$VERSION" \
      '{
        schema_version:"1.0",

        decision_model:{
          name:"splunk_cm_decision_model",
          version:$version
        },

        evidence_status:"DEGRADED",
        decision_valid:false,

        state:null,
        severity:null,
        score:null,

        rca:"INSUFFICIENT_EVIDENCE",
        confidence:"LOW"
      }'

    exit 0
fi

###############################################################################
# Dimensions
###############################################################################

AVAILABILITY_SCORE=0
SEARCHABILITY_SCORE=0
PROTECTION_SCORE=0
INGESTION_SCORE=0
REPLICATION_ACTIVITY_SCORE=0
BACKLOG_SCORE=0
MAINTENANCE_SCORE=0

# Peer availability
if (( DOWN > 0 )); then
    if (( UP == 0 )); then
        AVAILABILITY_SCORE=100
    else
        AVAILABILITY_SCORE=70
    fi
fi

# Peer/global searchability
if [[ "$ALL_SEARCHABLE" != "true" ]]; then
    SEARCHABILITY_SCORE=80
elif (( NOT_SEARCHABLE > 0 )); then
    SEARCHABILITY_SCORE=70
fi

# RF/SF service guarantees
if [[ "$RF_MET" != "true" || "$SF_MET" != "true" ]]; then
    PROTECTION_SCORE=80
fi

# Indexing readiness
if [[ "$INDEXING_READY" != "true" ]]; then
    INGESTION_SCORE=100
fi

# Recovery/fixup activity
if (( REPLICATION_JOBS > 0 || FIXUP_COUNT > 0 )); then
    REPLICATION_ACTIVITY_SCORE=40
fi

# Cluster backlog
if (( PENDING > 0 )); then
    BACKLOG_SCORE=30
fi

# Maintenance is context rather than failure.
if [[ "$MAINTENANCE" == "true" ]]; then
    MAINTENANCE_SCORE=10
fi

###############################################################################
# Overall score = MAX
###############################################################################

SCORE="$(
    printf '%s\n' \
      "$AVAILABILITY_SCORE" \
      "$SEARCHABILITY_SCORE" \
      "$PROTECTION_SCORE" \
      "$INGESTION_SCORE" \
      "$REPLICATION_ACTIVITY_SCORE" \
      "$BACKLOG_SCORE" \
      "$MAINTENANCE_SCORE" |
    sort -nr |
    head -1
)"

###############################################################################
# State
###############################################################################

if (( SCORE >= 90 )); then
    STATE="CRITICAL"
    SEVERITY="critical"

elif (( SCORE >= 60 )); then
    STATE="DEGRADED"
    SEVERITY="major"

elif (( SCORE >= 20 )); then
    STATE="WATCH"
    SEVERITY="warning"

else
    STATE="NORMAL"
    SEVERITY="none"
fi

###############################################################################
# Primary RCA precedence
###############################################################################

if [[ "$INDEXING_READY" != "true" ]]; then
    RCA="INDEXING_NOT_READY"

elif (( UP == 0 && DOWN > 0 )); then
    RCA="ALL_PEERS_DOWN"

elif (( DOWN > 0 )); then
    RCA="PEER_DOWN"

elif [[ "$ALL_SEARCHABLE" != "true" ]]; then
    RCA="DATA_NOT_FULLY_SEARCHABLE"

elif [[ "$RF_MET" != "true" && "$SF_MET" != "true" ]]; then
    RCA="RF_SF_NOT_MET"

elif [[ "$RF_MET" != "true" ]]; then
    RCA="REPLICATION_FACTOR_NOT_MET"

elif [[ "$SF_MET" != "true" ]]; then
    RCA="SEARCH_FACTOR_NOT_MET"

elif (( NOT_SEARCHABLE > 0 )); then
    RCA="PEER_NOT_SEARCHABLE"

elif (( REPLICATION_JOBS > 0 || FIXUP_COUNT > 0 )); then
    RCA="CLUSTER_FIXUP_ACTIVITY"

elif (( PENDING > 0 )); then
    RCA="CLUSTER_JOB_BACKLOG"

elif [[ "$MAINTENANCE" == "true" ]]; then
    RCA="MAINTENANCE_MODE"

else
    RCA="NORMAL_CLUSTER"
fi

###############################################################################
# Secondary impacts
###############################################################################

IMPACTS="$(
    jq -n \
      --argjson peer_down "$([[ "$DOWN" -gt 0 ]] && echo true || echo false)" \
      --argjson peer_not_searchable "$([[ "$NOT_SEARCHABLE" -gt 0 ]] && echo true || echo false)" \
      --argjson rf_not_met "$([[ "$RF_MET" != "true" ]] && echo true || echo false)" \
      --argjson sf_not_met "$([[ "$SF_MET" != "true" ]] && echo true || echo false)" \
      --argjson data_not_searchable "$([[ "$ALL_SEARCHABLE" != "true" ]] && echo true || echo false)" \
      --argjson indexing_not_ready "$([[ "$INDEXING_READY" != "true" ]] && echo true || echo false)" \
      '[
        if $peer_down then "PEER_AVAILABILITY_LOSS" else empty end,
        if $peer_not_searchable then "PEER_SEARCHABILITY_LOSS" else empty end,
        if $rf_not_met then "REPLICATION_GUARANTEE_VIOLATION" else empty end,
        if $sf_not_met then "SEARCH_GUARANTEE_VIOLATION" else empty end,
        if $data_not_searchable then "GLOBAL_SEARCHABILITY_IMPACT" else empty end,
        if $indexing_not_ready then "INDEXING_AVAILABILITY_IMPACT" else empty end
      ]'
)"

###############################################################################
# Final output
###############################################################################

jq -n \
  --arg version "$VERSION" \
  --arg evidence_status "$EVIDENCE_STATUS" \
  --arg confidence "$CONFIDENCE" \
  --arg state "$STATE" \
  --arg severity "$SEVERITY" \
  --arg rca "$RCA" \
  --argjson score "$SCORE" \
  --argjson availability "$AVAILABILITY_SCORE" \
  --argjson searchability "$SEARCHABILITY_SCORE" \
  --argjson protection "$PROTECTION_SCORE" \
  --argjson ingestion "$INGESTION_SCORE" \
  --argjson replication_activity "$REPLICATION_ACTIVITY_SCORE" \
  --argjson backlog "$BACKLOG_SCORE" \
  --argjson maintenance "$MAINTENANCE_SCORE" \
  --argjson discovered "$DISCOVERED" \
  --argjson up "$UP" \
  --argjson down "$DOWN" \
  --argjson searchable "$SEARCHABLE" \
  --argjson not_searchable "$NOT_SEARCHABLE" \
  --argjson rf_met "$RF_MET" \
  --argjson sf_met "$SF_MET" \
  --argjson all_searchable "$ALL_SEARCHABLE" \
  --argjson indexing_ready "$INDEXING_READY" \
  --argjson impacts "$IMPACTS" \
'
{
  schema_version:"1.0",

  decision_model:{
    name:"splunk_cm_decision_model",
    version:$version
  },

  evidence_status:$evidence_status,
  decision_valid:true,

  state:$state,
  severity:$severity,
  score:$score,
  rca:$rca,
  confidence:$confidence,

  dimensions:{
    availability:$availability,
    searchability:$searchability,
    protection:$protection,
    ingestion:$ingestion,
    replication_activity:$replication_activity,
    backlog:$backlog,
    maintenance:$maintenance
  },

  service_guarantees:{
    replication_factor_met:$rf_met,
    search_factor_met:$sf_met,
    all_data_searchable:$all_searchable,
    indexing_ready:$indexing_ready
  },

  observations:{
    peers_discovered:$discovered,
    peers_up:$up,
    peers_down:$down,
    peers_searchable:$searchable,
    peers_not_searchable:$not_searchable
  },

  impacts:$impacts
}'
