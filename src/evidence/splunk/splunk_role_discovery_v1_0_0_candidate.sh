#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# Splunk Role Discovery Engine
# Version: 1.0.0-candidate
#
# Purpose:
#   Deterministically discover Splunk platform roles and runtime capabilities
#   from effective configuration.
#
# Important:
#   Role identity and role health are intentionally separate concepts.
###############################################################################

VERSION="1.0.0-candidate"

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
SPLUNK="${SPLUNK_HOME}/bin/splunk"

HOST="$(hostname -s 2>/dev/null || hostname)"
OBSERVED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

bool=false

###############################################################################
# Installation
###############################################################################

INSTALLED=false
VERSION_STRING="UNAVAILABLE"

if [[ -x "$SPLUNK" ]]; then
    INSTALLED=true

    VERSION_STRING="$("$SPLUNK" version 2>/dev/null | head -1 || true)"

    [[ -n "$VERSION_STRING" ]] || VERSION_STRING="UNKNOWN"
fi

###############################################################################
# Runtime
###############################################################################

SPLUNKD_RUNNING=false
PORT_8089=false
PORT_8000=false
PORT_9997=false

if pgrep -x splunkd >/dev/null 2>&1; then
    SPLUNKD_RUNNING=true
fi

port_listening()
{
    local port="$1"

    ss -lnt 2>/dev/null |
        awk '{print $4}' |
        grep -Eq ":${port}$"
}

port_listening 8089 && PORT_8089=true
port_listening 8000 && PORT_8000=true
port_listening 9997 && PORT_9997=true

###############################################################################
# Default values
###############################################################################

SERVER_NAME="$HOST"
SITE=""

CLUSTER_MODE="disabled"
MANAGER_URI=""

SHC_DISABLED="true"
SHC_MGMT_URI=""
SHC_DEPLOYER_URI=""

###############################################################################
# Effective configuration
###############################################################################

if [[ "$INSTALLED" == true ]]; then

    GENERAL="$("$SPLUNK" btool server list general 2>/dev/null || true)"
    CLUSTER="$("$SPLUNK" btool server list clustering 2>/dev/null || true)"
    SHC="$("$SPLUNK" btool server list shclustering 2>/dev/null || true)"

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

    V="$(printf '%s\n' "$GENERAL" | value serverName)"
    [[ -n "$V" ]] && SERVER_NAME="$V"

    V="$(printf '%s\n' "$GENERAL" | value site)"
    [[ -n "$V" ]] && SITE="$V"

    V="$(printf '%s\n' "$CLUSTER" | value mode)"
    [[ -n "$V" ]] && CLUSTER_MODE="$V"

    V="$(printf '%s\n' "$CLUSTER" | value manager_uri)"
    [[ -n "$V" ]] && MANAGER_URI="$V"

    V="$(printf '%s\n' "$SHC" | value disabled)"
    [[ -n "$V" ]] && SHC_DISABLED="$V"

    V="$(printf '%s\n' "$SHC" | value mgmt_uri)"
    [[ -n "$V" ]] && SHC_MGMT_URI="$V"

    V="$(printf '%s\n' "$SHC" | value conf_deploy_fetch_url)"
    [[ -n "$V" ]] && SHC_DEPLOYER_URI="$V"
fi

###############################################################################
# Authoritative role classification
###############################################################################

CLUSTER_MANAGER=false
INDEXER_PEER=false
SHC_MEMBER=false

case "${CLUSTER_MODE,,}" in
    manager)
        CLUSTER_MANAGER=true
        ;;
    peer)
        INDEXER_PEER=true
        ;;
esac

case "${SHC_DISABLED,,}" in
    false|0|no)
        if [[ -n "$SHC_MGMT_URI" ]]; then
            SHC_MEMBER=true
        fi
        ;;
esac

###############################################################################
# Administrative roles
#
# These require stronger local evidence than directory existence.
###############################################################################

DEPLOYMENT_SERVER=false
SHC_DEPLOYER=false

if [[ "$INSTALLED" == true ]]; then

    SERVERCLASS="$("$SPLUNK" btool serverclass list --debug 2>/dev/null || true)"

    # At least one non-default serverClass is evidence that this instance
    # is configured to act as a Deployment Server.
    if printf '%s\n' "$SERVERCLASS" |
       grep -Eq '\[serverClass:[^]]+\]'; then
        DEPLOYMENT_SERVER=true
    fi

    # A populated deployer repository alone is not sufficient.
    # Presence of shcluster/apps plus a member pointing to this host will
    # eventually provide stronger distributed evidence.
    #
    # For V1.0.0 we expose deployer capability separately and do not assert
    # authoritative deployer role solely from the directory.
fi

###############################################################################
# Capabilities
###############################################################################

FORWARDS_TO_INDEXERS=false
RECEIVES_SPLUNKTCP="$PORT_9997"
SEARCH_UI_AVAILABLE="$PORT_8000"
MANAGEMENT_AVAILABLE="$PORT_8089"

if [[ "$INSTALLED" == true ]]; then

    OUTPUTS="$("$SPLUNK" btool outputs list 2>/dev/null || true)"

    if printf '%s\n' "$OUTPUTS" |
       grep -Eq '^[[:space:]]*server[[:space:]]*='; then
        FORWARDS_TO_INDEXERS=true
    fi
fi

###############################################################################
# Applicability
###############################################################################

APPLICABLE="$INSTALLED"

###############################################################################
# Evidence confidence
###############################################################################

DISCOVERY_CONFIDENCE="HIGH"

if [[ "$INSTALLED" != true ]]; then
    DISCOVERY_CONFIDENCE="HIGH"
elif [[ "$SPLUNKD_RUNNING" != true ]]; then
    # Configuration can still identify a stopped Splunk instance.
    DISCOVERY_CONFIDENCE="HIGH"
fi

###############################################################################
# JSON
###############################################################################

jq -n \
  --arg engine_version "$VERSION" \
  --arg observed_at "$OBSERVED_AT" \
  --arg host "$HOST" \
  --arg server_name "$SERVER_NAME" \
  --arg splunk_version "$VERSION_STRING" \
  --arg site "$SITE" \
  --arg cluster_mode "$CLUSTER_MODE" \
  --arg manager_uri "$MANAGER_URI" \
  --arg shc_mgmt_uri "$SHC_MGMT_URI" \
  --arg shc_deployer_uri "$SHC_DEPLOYER_URI" \
  --arg confidence "$DISCOVERY_CONFIDENCE" \
  --argjson applicable "$APPLICABLE" \
  --argjson installed "$INSTALLED" \
  --argjson splunkd_running "$SPLUNKD_RUNNING" \
  --argjson port8089 "$PORT_8089" \
  --argjson port8000 "$PORT_8000" \
  --argjson port9997 "$PORT_9997" \
  --argjson cluster_manager "$CLUSTER_MANAGER" \
  --argjson indexer_peer "$INDEXER_PEER" \
  --argjson shc_member "$SHC_MEMBER" \
  --argjson deployment_server "$DEPLOYMENT_SERVER" \
  --argjson shc_deployer "$SHC_DEPLOYER" \
  --argjson forwards "$FORWARDS_TO_INDEXERS" \
  --argjson receives "$RECEIVES_SPLUNKTCP" \
  '
  {
    schema_version: "1.0",

    discovery: {
      name: "splunk_role_discovery",
      version: $engine_version,
      observed_at: $observed_at,
      confidence: $confidence
    },

    identity: {
      host: $host,
      server_name: $server_name,
      site: $site
    },

    splunk: {
      applicable: $applicable,
      installed: $installed,
      version: $splunk_version
    },

    runtime: {
      splunkd_running: $splunkd_running,

      listeners: {
        management_8089: $port8089,
        web_8000: $port8000,
        splunktcp_9997: $port9997
      }
    },

    roles: {
      cluster_manager: $cluster_manager,
      indexer_peer: $indexer_peer,
      shc_member: $shc_member,
      shc_deployer: $shc_deployer,
      deployment_server: $deployment_server
    },

    capabilities: {
      forwards_to_indexers: $forwards,
      receives_splunktcp: $receives,
      management_endpoint_local: $port8089,
      web_endpoint_local: $port8000
    },

    relationships: {
      cluster_mode: $cluster_mode,
      cluster_manager_uri:
        (if $manager_uri == "" then null else $manager_uri end),

      shc_management_uri:
        (if $shc_mgmt_uri == "" then null else $shc_mgmt_uri end),

      shc_deployer_uri:
        (if $shc_deployer_uri == "" then null else $shc_deployer_uri end)
    }
  }'
