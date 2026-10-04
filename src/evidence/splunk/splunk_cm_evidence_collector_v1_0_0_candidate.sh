#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Splunk Cluster Manager Evidence Collector
# Version: 1.0.0-candidate
#
# Purpose:
#   Collect role-aware Cluster Manager evidence without requiring Splunk search.
#
# Contract:
#   - If Splunk is stopped, operational collection stops.
#   - Missing evidence is never converted to healthy evidence.
#   - Collection and decision are separate layers.
###############################################################################

VERSION="1.0.0-candidate"

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK="${SPLUNK_HOME}/bin/splunk"

HOST="$(hostname -s 2>/dev/null || hostname)"
OBSERVED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

###############################################################################
# Helpers
###############################################################################

json_unavailable()
{
    local reason="$1"

    jq -n \
      --arg version "$VERSION" \
      --arg host "$HOST" \
      --arg observed_at "$OBSERVED_AT" \
      --arg reason "$reason" \
      '{
        schema_version: "1.0",

        collector: {
          name: "splunk_cm_evidence_collector",
          version: $version
        },

        identity: {
          host: $host,
          observed_at: $observed_at
        },

        evidence: {
          status: "UNAVAILABLE",
          reason: $reason
        },

        cluster_manager: null
      }'

    exit 0
}

###############################################################################
# Applicability gates
###############################################################################

[[ -x "$SPLUNK" ]] ||
    json_unavailable "SPLUNK_NOT_INSTALLED"

if ! pgrep -x splunkd >/dev/null 2>&1; then
    json_unavailable "SPLUNK_STOPPED"
fi

if ! ss -lnt 2>/dev/null |
     awk '{print $4}' |
     grep -Eq ':8089$'; then
    json_unavailable "MANAGEMENT_ENDPOINT_UNAVAILABLE"
fi

###############################################################################
# Effective cluster configuration
###############################################################################

CLUSTER="$("$SPLUNK" btool server list clustering 2>/dev/null || true)"

value()
{
    local key="$1"

    awk -F= -v key="$key" '
    {
        k=$1
        gsub(/^[ \t]+|[ \t]+$/, "", k)

        if (k == key) {
            sub(/^[^=]*=/, "")
            gsub(/^[ \t]+|[ \t]+$/, "")
            print
            exit
        }
    }'
}

MODE="$(printf '%s\n' "$CLUSTER" | value mode)"
CLUSTER_LABEL="$(printf '%s\n' "$CLUSTER" | value cluster_label)"
MULTISITE="$(printf '%s\n' "$CLUSTER" | value multisite)"
AVAILABLE_SITES="$(printf '%s\n' "$CLUSTER" | value available_sites)"
MAINTENANCE="$(printf '%s\n' "$CLUSTER" | value maintenance_mode)"

RF="$(printf '%s\n' "$CLUSTER" | value replication_factor)"
SF="$(printf '%s\n' "$CLUSTER" | value search_factor)"

SITE_RF="$(printf '%s\n' "$CLUSTER" | value site_replication_factor)"
SITE_SF="$(printf '%s\n' "$CLUSTER" | value site_search_factor)"

###############################################################################
# Role gate
###############################################################################

if [[ "${MODE,,}" != "manager" ]]; then
    json_unavailable "NOT_CLUSTER_MANAGER"
fi

###############################################################################
# Peer evidence
###############################################################################

PEER_RAW="$("$SPLUNK" list cluster-peers 2>/dev/null || true)"

if [[ -z "$PEER_RAW" ]]; then
    json_unavailable "CLUSTER_PEER_EVIDENCE_UNAVAILABLE"
fi

###############################################################################
# Parse peers
###############################################################################

PEERS_JSON="$(
printf '%s\n' "$PEER_RAW" |
awk '
function trim(s) {
    gsub(/^[ \t]+|[ \t]+$/, "", s)
    return s
}

function flush() {
    if (guid == "")
        return

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
           guid,
           label,
           status,
           site,
           searchable,
           bucket_count,
           pending_jobs,
           replication_count,
           fixup_set

    guid=""
    label=""
    status=""
    site=""
    searchable=""
    bucket_count=""
    pending_jobs=""
    replication_count=""
    fixup_set=""
}

/^[[:space:]]*[A-Fa-f0-9]{8}-[A-Fa-f0-9-]{27,}[[:space:]]*$/ {
    flush()
    guid=trim($0)
    next
}

{
    line=$0
    sub(/^[ \t]+/, "", line)

    pos=index(line, ":")
    if (!pos)
        next

    key=substr(line,1,pos-1)
    val=substr(line,pos+1)

    key=trim(key)
    val=trim(val)

    if (key=="label")
        label=val
    else if (key=="status")
        status=val
    else if (key=="site")
        site=val
    else if (key=="is_searchable")
        searchable=val
    else if (key=="bucket_count")
        bucket_count=val
    else if (key=="pending_job_count")
        pending_jobs=val
    else if (key=="replication_count")
        replication_count=val
    else if (key=="fixup_set")
        fixup_set=val
}

END {
    flush()
}
' |
jq -R -s '
    split("\n")
    | map(select(length > 0))
    | map(
        split("\t")
        | {
            guid: .[0],
            label: .[1],
            status: .[2],
            site: .[3],

            searchable:
              (if .[4] == "1"
               then true
               elif .[4] == "0"
               then false
               else null
               end),

            bucket_count:
              (.[5] | tonumber?),

            pending_job_count:
              (.[6] | tonumber?),

            replication_count:
              (.[7] | tonumber?),

            fixup_set:
              (if .[8] == ""
               then null
               else .[8]
               end)
        }
    )
'
)"

###############################################################################
# Aggregate
###############################################################################

DISCOVERED="$(jq 'length' <<<"$PEERS_JSON")"

UP="$(jq '[.[] | select(.status=="Up")] | length' <<<"$PEERS_JSON")"

DOWN="$(jq \
    '[.[] | select(.status != "Up")] | length' \
    <<<"$PEERS_JSON")"

SEARCHABLE="$(jq \
    '[.[] | select(.searchable==true)] | length' \
    <<<"$PEERS_JSON")"

NOT_SEARCHABLE="$(jq \
    '[.[] | select(.searchable==false)] | length' \
    <<<"$PEERS_JSON")"

TOTAL_BUCKETS="$(jq \
    '[.[].bucket_count // 0] | add // 0' \
    <<<"$PEERS_JSON")"

PENDING_JOBS="$(jq \
    '[.[].pending_job_count // 0] | add // 0' \
    <<<"$PEERS_JSON")"

REPLICATION_JOBS="$(jq \
    '[.[].replication_count // 0] | add // 0' \
    <<<"$PEERS_JSON")"

###############################################################################
# Evidence quality
###############################################################################

EVIDENCE_STATUS="AVAILABLE"
CONFIDENCE="HIGH"

if [[ "$DISCOVERED" -eq 0 ]]; then
    EVIDENCE_STATUS="DEGRADED"
    CONFIDENCE="LOW"
fi

###############################################################################
# Final JSON
###############################################################################

jq -n \
  --arg version "$VERSION" \
  --arg host "$HOST" \
  --arg observed_at "$OBSERVED_AT" \
  --arg evidence_status "$EVIDENCE_STATUS" \
  --arg confidence "$CONFIDENCE" \
  --arg mode "$MODE" \
  --arg cluster_label "$CLUSTER_LABEL" \
  --arg multisite "$MULTISITE" \
  --arg available_sites "$AVAILABLE_SITES" \
  --arg maintenance "$MAINTENANCE" \
  --arg rf "$RF" \
  --arg sf "$SF" \
  --arg site_rf "$SITE_RF" \
  --arg site_sf "$SITE_SF" \
  --argjson peers "$PEERS_JSON" \
  --argjson discovered "$DISCOVERED" \
  --argjson up "$UP" \
  --argjson down "$DOWN" \
  --argjson searchable "$SEARCHABLE" \
  --argjson not_searchable "$NOT_SEARCHABLE" \
  --argjson buckets "$TOTAL_BUCKETS" \
  --argjson pending "$PENDING_JOBS" \
  --argjson replication_jobs "$REPLICATION_JOBS" \
  '
  {
    schema_version: "1.0",

    collector: {
      name: "splunk_cm_evidence_collector",
      version: $version
    },

    identity: {
      host: $host,
      observed_at: $observed_at
    },

    evidence: {
      status: $evidence_status,
      confidence: $confidence
    },

    cluster_manager: {
      role_verified: true,

      configuration: {
        mode: $mode,
        cluster_label:
          (if $cluster_label == ""
           then null
           else $cluster_label
           end),

        multisite:
          ($multisite | ascii_downcase == "true"),

        available_sites:
          ($available_sites
           | split(",")
           | map(gsub("^\\s+|\\s+$";""))
           | map(select(length > 0))),

        maintenance_mode:
          ($maintenance | ascii_downcase == "true"),

        replication_factor: ($rf | tonumber?),
        search_factor: ($sf | tonumber?),

        site_replication_factor:
          (if $site_rf == "" then null else $site_rf end),

        site_search_factor:
          (if $site_sf == "" then null else $site_sf end)
      },

      peers: {
        discovered: $discovered,
        up: $up,
        down: $down,
        searchable: $searchable,
        not_searchable: $not_searchable,

        total_buckets: $buckets,
        pending_jobs: $pending,
        replication_jobs: $replication_jobs,

        members: $peers
      }
    }
  }'
