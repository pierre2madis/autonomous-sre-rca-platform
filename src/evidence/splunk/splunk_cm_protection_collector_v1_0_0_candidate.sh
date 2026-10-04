#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Splunk Cluster Manager Data Protection Collector
# Version: 1.0.0-candidate
#
# Collects cluster-wide service guarantees:
#   - Replication Factor
#   - Search Factor
#   - Global data searchability
#   - Indexing readiness
#
# Important:
#   Missing protection evidence MUST NOT be interpreted as healthy.
###############################################################################

VERSION="1.0.0-candidate"

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK="${SPLUNK_HOME}/bin/splunk"

HOST="$(hostname -s 2>/dev/null || hostname)"
OBSERVED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

###############################################################################
# UNAVAILABLE response
###############################################################################

unavailable()
{
    local reason="$1"

    jq -n \
      --arg version "$VERSION" \
      --arg host "$HOST" \
      --arg observed_at "$OBSERVED_AT" \
      --arg reason "$reason" \
      '{
        schema_version:"1.0",

        collector:{
          name:"splunk_cm_protection_collector",
          version:$version
        },

        identity:{
          host:$host,
          observed_at:$observed_at
        },

        evidence:{
          status:"UNAVAILABLE",
          confidence:"LOW",
          reason:$reason
        },

        data_protection:null
      }'

    exit 0
}

###############################################################################
# Runtime gates
###############################################################################

[[ -x "$SPLUNK" ]] ||
    unavailable "SPLUNK_NOT_INSTALLED"

pgrep -x splunkd >/dev/null 2>&1 ||
    unavailable "SPLUNK_STOPPED"

ss -lnt 2>/dev/null |
awk '{print $4}' |
grep -Eq ':8089$' ||
    unavailable "MANAGEMENT_ENDPOINT_UNAVAILABLE"

###############################################################################
# Verify Cluster Manager role
###############################################################################

MODE="$(
    "$SPLUNK" btool server list clustering 2>/dev/null |
    awk -F= '
      {
        k=$1
        gsub(/^[ \t]+|[ \t]+$/, "", k)

        if (k=="mode") {
            sub(/^[^=]*=/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
      }
    '
)"

[[ "${MODE,,}" == "manager" ]] ||
    unavailable "NOT_CLUSTER_MANAGER"

###############################################################################
# Obtain cluster protection status
###############################################################################

RAW="$(
    timeout 10 \
      "$SPLUNK" show cluster-status </dev/null 2>&1
)"

RC=$?

###############################################################################
# Authentication must never become interactive.
###############################################################################

if grep -Eqi \
    'Please login|Splunk username:|Password:|session is invalid' \
    <<<"$RAW"
then
    unavailable "AUTHENTICATION_REQUIRED"
fi

if (( RC == 124 )); then
    unavailable "CLUSTER_STATUS_TIMEOUT"
fi

if (( RC != 0 )); then
    unavailable "CLUSTER_STATUS_COMMAND_FAILED"
fi

###############################################################################
# Parse explicit Splunk assertions
###############################################################################

RF_MET=""

if grep -Eq '^[[:space:]]*Replication factor met[[:space:]]*$' <<<"$RAW"; then
    RF_MET="true"
elif grep -Eq '^[[:space:]]*Replication factor not met[[:space:]]*$' <<<"$RAW"; then
    RF_MET="false"
fi


SF_MET=""

if grep -Eq '^[[:space:]]*Search factor met[[:space:]]*$' <<<"$RAW"; then
    SF_MET="true"
elif grep -Eq '^[[:space:]]*Search factor not met[[:space:]]*$' <<<"$RAW"; then
    SF_MET="false"
fi


ALL_SEARCHABLE=""

if grep -Eq '^[[:space:]]*All data is searchable[[:space:]]*$' <<<"$RAW"; then
    ALL_SEARCHABLE="true"
elif grep -Eq '^[[:space:]]*All data is not searchable[[:space:]]*$' <<<"$RAW"; then
    ALL_SEARCHABLE="false"
fi


INDEXING_READY=""

if grep -Eq '^[[:space:]]*Indexing Ready[[:space:]]+YES[[:space:]]*$' <<<"$RAW"; then
    INDEXING_READY="true"
elif grep -Eq '^[[:space:]]*Indexing Ready[[:space:]]+NO[[:space:]]*$' <<<"$RAW"; then
    INDEXING_READY="false"
fi

###############################################################################
# Contract completeness
###############################################################################

MISSING=()

[[ -n "$RF_MET" ]] ||
    MISSING+=("replication_factor_met")

[[ -n "$SF_MET" ]] ||
    MISSING+=("search_factor_met")

[[ -n "$ALL_SEARCHABLE" ]] ||
    MISSING+=("all_data_searchable")

[[ -n "$INDEXING_READY" ]] ||
    MISSING+=("indexing_ready")

if (( ${#MISSING[@]} > 0 )); then
    REASON="INCOMPLETE_PROTECTION_EVIDENCE:$(IFS=,; echo "${MISSING[*]}")"
    unavailable "$REASON"
fi

###############################################################################
# Output
###############################################################################

jq -n \
  --arg version "$VERSION" \
  --arg host "$HOST" \
  --arg observed_at "$OBSERVED_AT" \
  --argjson rf "$RF_MET" \
  --argjson sf "$SF_MET" \
  --argjson searchable "$ALL_SEARCHABLE" \
  --argjson indexing "$INDEXING_READY" \
  '{
    schema_version:"1.0",

    collector:{
      name:"splunk_cm_protection_collector",
      version:$version
    },

    identity:{
      host:$host,
      observed_at:$observed_at
    },

    evidence:{
      status:"AVAILABLE",
      confidence:"HIGH"
    },

    data_protection:{
      replication_factor_met:$rf,
      search_factor_met:$sf,
      all_data_searchable:$searchable,
      indexing_ready:$indexing
    }
  }'
