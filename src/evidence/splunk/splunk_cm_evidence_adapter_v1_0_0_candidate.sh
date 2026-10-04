#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Splunk Cluster Manager Evidence Adapter
# Version: 1.0.0-candidate
#
# Inputs:
#   1. Peer evidence JSON
#   2. Data-protection evidence JSON
#
# Evidence semantics:
#   AVAILABLE   = both evidence sources available
#   DEGRADED    = only one source available
#   UNAVAILABLE = neither source available
###############################################################################

VERSION="1.0.0-candidate"

PEER_FILE="${1:-}"
PROTECTION_FILE="${2:-}"

if [[ -z "$PEER_FILE" || -z "$PROTECTION_FILE" ]]; then
    echo "Usage: $0 <peer-evidence.json> <protection-evidence.json>" >&2
    exit 2
fi

for f in "$PEER_FILE" "$PROTECTION_FILE"; do
    if [[ ! -r "$f" ]]; then
        echo "ERROR: unreadable input: $f" >&2
        exit 3
    fi

    if ! jq -e . "$f" >/dev/null 2>&1; then
        echo "ERROR: invalid JSON: $f" >&2
        exit 4
    fi
done

HOST="$(jq -r '.identity.host // empty' "$PEER_FILE")"
PROTECTION_HOST="$(jq -r '.identity.host // empty' "$PROTECTION_FILE")"

if [[ -z "$HOST" || -z "$PROTECTION_HOST" || "$HOST" != "$PROTECTION_HOST" ]]; then
    echo "ERROR: evidence host mismatch" >&2
    exit 5
fi

PEER_STATUS="$(jq -r '.evidence.status // "UNAVAILABLE"' "$PEER_FILE")"
PROTECTION_STATUS="$(jq -r '.evidence.status // "UNAVAILABLE"' "$PROTECTION_FILE")"

PEER_AVAILABLE=false
PROTECTION_AVAILABLE=false

[[ "$PEER_STATUS" == "AVAILABLE" ]] &&
    PEER_AVAILABLE=true

[[ "$PROTECTION_STATUS" == "AVAILABLE" ]] &&
    PROTECTION_AVAILABLE=true

if [[ "$PEER_AVAILABLE" == true && "$PROTECTION_AVAILABLE" == true ]]; then
    EVIDENCE_STATUS="AVAILABLE"
    CONFIDENCE="HIGH"

elif [[ "$PEER_AVAILABLE" == true || "$PROTECTION_AVAILABLE" == true ]]; then
    EVIDENCE_STATUS="DEGRADED"
    CONFIDENCE="MEDIUM"

else
    EVIDENCE_STATUS="UNAVAILABLE"
    CONFIDENCE="LOW"
fi

OBSERVED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

jq -n \
  --arg version "$VERSION" \
  --arg host "$HOST" \
  --arg observed_at "$OBSERVED_AT" \
  --arg evidence_status "$EVIDENCE_STATUS" \
  --arg confidence "$CONFIDENCE" \
  --arg peer_status "$PEER_STATUS" \
  --arg protection_status "$PROTECTION_STATUS" \
  --argjson peer_available "$PEER_AVAILABLE" \
  --argjson protection_available "$PROTECTION_AVAILABLE" \
  --slurpfile peer "$PEER_FILE" \
  --slurpfile protection "$PROTECTION_FILE" \
'
{
  schema_version:"1.0",

  adapter:{
    name:"splunk_cm_evidence_adapter",
    version:$version
  },

  identity:{
    host:$host,
    observed_at:$observed_at
  },

  evidence:{
    status:$evidence_status,
    confidence:$confidence,

    sources:{
      peer:{
        status:$peer_status,
        available:$peer_available
      },

      protection:{
        status:$protection_status,
        available:$protection_available
      }
    }
  },

  cluster_manager:
    (
      if $peer_available
      then $peer[0].cluster_manager
      else null
      end
    ),

  data_protection:
    (
      if $protection_available
      then $protection[0].data_protection
      else null
      end
    )
}'
