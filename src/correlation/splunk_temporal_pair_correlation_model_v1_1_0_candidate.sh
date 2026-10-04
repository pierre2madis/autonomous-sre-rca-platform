#!/usr/bin/env bash

set -uo pipefail

MODEL_NAME="splunk_temporal_pair_correlation_model"
MODEL_VERSION="1.1.0-candidate"

usage() {
    echo "Usage: $0 <cause-envelope.json> <effect-envelope.json> <correlation-window-seconds>" >&2
    exit 2
}

[[ $# -eq 3 ]] || usage

CAUSE="$1"
EFFECT="$2"
WINDOW="$3"

[[ -f "$CAUSE" ]] || {
    echo "ERROR: cause envelope not found: $CAUSE" >&2
    exit 3
}

[[ -f "$EFFECT" ]] || {
    echo "ERROR: effect envelope not found: $EFFECT" >&2
    exit 4
}

jq -e . "$CAUSE" >/dev/null 2>&1 || {
    echo "ERROR: invalid cause JSON" >&2
    exit 5
}

jq -e . "$EFFECT" >/dev/null 2>&1 || {
    echo "ERROR: invalid effect JSON" >&2
    exit 6
}

[[ "$WINDOW" =~ ^[0-9]+$ ]] || {
    echo "ERROR: correlation window must be a positive integer" >&2
    exit 7
}

(( WINDOW > 0 )) || {
    echo "ERROR: correlation window must be greater than zero" >&2
    exit 7
}

#
# Artifact identity is computed from the exact bytes consumed.
#
CAUSE_SHA="$(sha256sum "$CAUSE" | awk '{print $1}')"
EFFECT_SHA="$(sha256sum "$EFFECT" | awk '{print $1}')"

#
# Semantic provenance.
#
CAUSE_ENTITY_TYPE="$(jq -r '.entity.type // "null"' "$CAUSE")"
CAUSE_HOST="$(jq -r '.entity.host // "null"' "$CAUSE")"
CAUSE_GUID="$(jq -r '.entity.guid // "null"' "$CAUSE")"
CAUSE_DOMAIN="$(jq -r '.event.domain // "null"' "$CAUSE")"
CAUSE_EVENT_TYPE="$(jq -r '.event.type // "null"' "$CAUSE")"

EFFECT_ENTITY_TYPE="$(jq -r '.entity.type // "null"' "$EFFECT")"
EFFECT_HOST="$(jq -r '.entity.host // "null"' "$EFFECT")"
EFFECT_GUID="$(jq -r '.entity.guid // "null"' "$EFFECT")"
EFFECT_ENTITY_DOMAIN="$(jq -r '.entity.domain // "null"' "$EFFECT")"
EFFECT_DOMAIN="$(jq -r '.event.domain // "null"' "$EFFECT")"
EFFECT_EVENT_TYPE="$(jq -r '.event.type // "null"' "$EFFECT")"

#
# Authoritative event time only.
#
CAUSE_AVAILABLE="$(jq -r '
    if .temporal.observed_at.available == null
    then "null"
    else .temporal.observed_at.available
    end
' "$CAUSE")"

CAUSE_AUTHORITATIVE="$(jq -r '
    if .temporal.observed_at.authoritative == null
    then "null"
    else .temporal.observed_at.authoritative
    end
' "$CAUSE")"

CAUSE_TS="$(jq -r '.temporal.observed_at.value // "null"' "$CAUSE")"

EFFECT_AVAILABLE="$(jq -r '
    if .temporal.observed_at.available == null
    then "null"
    else .temporal.observed_at.available
    end
' "$EFFECT")"

EFFECT_AUTHORITATIVE="$(jq -r '
    if .temporal.observed_at.authoritative == null
    then "null"
    else .temporal.observed_at.authoritative
    end
' "$EFFECT")"

EFFECT_TS="$(jq -r '.temporal.observed_at.value // "null"' "$EFFECT")"

#
# Missing or non-authoritative event time is evidence unavailability,
# not malformed representation.
#
if [[ "$CAUSE_AVAILABLE" != "true" ||
      "$CAUSE_AUTHORITATIVE" != "true" ||
      "$CAUSE_TS" == "null" ||
      "$EFFECT_AVAILABLE" != "true" ||
      "$EFFECT_AUTHORITATIVE" != "true" ||
      "$EFFECT_TS" == "null" ]]; then

    jq -n \
      --arg model_name "$MODEL_NAME" \
      --arg model_version "$MODEL_VERSION" \
      --arg cause_sha "$CAUSE_SHA" \
      --arg effect_sha "$EFFECT_SHA" \
      --arg cause_entity_type "$CAUSE_ENTITY_TYPE" \
      --arg cause_host "$CAUSE_HOST" \
      --arg cause_guid "$CAUSE_GUID" \
      --arg cause_domain "$CAUSE_DOMAIN" \
      --arg cause_event_type "$CAUSE_EVENT_TYPE" \
      --arg cause_ts "$CAUSE_TS" \
      --arg effect_entity_type "$EFFECT_ENTITY_TYPE" \
      --arg effect_host "$EFFECT_HOST" \
      --arg effect_guid "$EFFECT_GUID" \
      --arg effect_entity_domain "$EFFECT_ENTITY_DOMAIN" \
      --arg effect_domain "$EFFECT_DOMAIN" \
      --arg effect_event_type "$EFFECT_EVENT_TYPE" \
      --arg effect_ts "$EFFECT_TS" \
      --argjson window "$WINDOW" \
      '{
        schema_version: "1.1",

        model: {
          name: $model_name,
          version: $model_version
        },

        decision_valid: true,

        pair_provenance: {
          cause: {
            artifact_sha256: $cause_sha,
            entity: {
              type: (
                if $cause_entity_type == "null"
                then null else $cause_entity_type end
              ),
              host: (
                if $cause_host == "null"
                then null else $cause_host end
              ),
              guid: (
                if $cause_guid == "null"
                then null else $cause_guid end
              )
            },
            event: {
              domain: (
                if $cause_domain == "null"
                then null else $cause_domain end
              ),
              type: (
                if $cause_event_type == "null"
                then null else $cause_event_type end
              )
            },
            observed_at: (
              if $cause_ts == "null" then null else $cause_ts end
            )
          },

          effect: {
            artifact_sha256: $effect_sha,
            entity: {
              type: (
                if $effect_entity_type == "null"
                then null else $effect_entity_type end
              ),
              host: (
                if $effect_host == "null"
                then null else $effect_host end
              ),
              guid: (
                if $effect_guid == "null"
                then null else $effect_guid end
              ),
              domain: (
                if $effect_entity_domain == "null"
                then null else $effect_entity_domain end
              )
            },
            event: {
              domain: (
                if $effect_domain == "null"
                then null else $effect_domain end
              ),
              type: (
                if $effect_event_type == "null"
                then null else $effect_event_type end
              )
            },
            observed_at: (
              if $effect_ts == "null" then null else $effect_ts end
            )
          }
        },

        temporal_state: "NOT_EVALUABLE",
        reason: "AUTHORITATIVE_EVENT_TIMESTAMPS_UNAVAILABLE",
        ordering: null,
        delta_seconds: null,
        correlation_window_seconds: $window,
        within_correlation_window: null,

        causal_admissibility: {
          temporal_evidence_admissible: false,
          confirmed_causality_admissible: false
        },

        boundaries: {
          causal_claim_confirmed: false,
          parent_event_assigned: false,
          incident_created: false,
          remediation_authorized: false
        }
      }'

    exit 20
fi

CAUSE_EPOCH="$(date -u -d "$CAUSE_TS" +%s 2>/dev/null)" || {
    echo "ERROR: invalid cause observed_at timestamp" >&2
    exit 8
}

EFFECT_EPOCH="$(date -u -d "$EFFECT_TS" +%s 2>/dev/null)" || {
    echo "ERROR: invalid effect observed_at timestamp" >&2
    exit 9
}

DELTA=$((EFFECT_EPOCH - CAUSE_EPOCH))

if (( DELTA < 0 )); then
    ORDERING="EFFECT_BEFORE_CAUSE"
    STATE="TEMPORALLY_NOT_ADMISSIBLE"
    REASON="INVALID_CAUSAL_ORDERING"
    WITHIN=false
    ADMISSIBLE=false

elif (( DELTA == 0 )); then
    ORDERING="SIMULTANEOUS_OBSERVATION"
    STATE="TEMPORALLY_INDETERMINATE"
    REASON="CAUSAL_ORDERING_NOT_ESTABLISHED"
    WITHIN=true
    ADMISSIBLE=false

elif (( DELTA <= WINDOW )); then
    ORDERING="CAUSE_BEFORE_EFFECT"
    STATE="TEMPORALLY_ADMISSIBLE"
    REASON="CAUSE_EFFECT_WITHIN_CORRELATION_WINDOW"
    WITHIN=true
    ADMISSIBLE=true

else
    ORDERING="CAUSE_BEFORE_EFFECT"
    STATE="TEMPORALLY_NOT_ADMISSIBLE"
    REASON="CAUSE_EFFECT_OUTSIDE_CORRELATION_WINDOW"
    WITHIN=false
    ADMISSIBLE=false
fi

jq -n \
  --arg model_name "$MODEL_NAME" \
  --arg model_version "$MODEL_VERSION" \
  --arg cause_sha "$CAUSE_SHA" \
  --arg effect_sha "$EFFECT_SHA" \
  --arg cause_entity_type "$CAUSE_ENTITY_TYPE" \
  --arg cause_host "$CAUSE_HOST" \
  --arg cause_guid "$CAUSE_GUID" \
  --arg cause_domain "$CAUSE_DOMAIN" \
  --arg cause_event_type "$CAUSE_EVENT_TYPE" \
  --arg cause_ts "$CAUSE_TS" \
  --arg effect_entity_type "$EFFECT_ENTITY_TYPE" \
  --arg effect_host "$EFFECT_HOST" \
  --arg effect_guid "$EFFECT_GUID" \
  --arg effect_entity_domain "$EFFECT_ENTITY_DOMAIN" \
  --arg effect_domain "$EFFECT_DOMAIN" \
  --arg effect_event_type "$EFFECT_EVENT_TYPE" \
  --arg effect_ts "$EFFECT_TS" \
  --arg state "$STATE" \
  --arg reason "$REASON" \
  --arg ordering "$ORDERING" \
  --argjson delta "$DELTA" \
  --argjson window "$WINDOW" \
  --argjson within "$WITHIN" \
  --argjson admissible "$ADMISSIBLE" \
  '{
    schema_version: "1.1",

    model: {
      name: $model_name,
      version: $model_version
    },

    decision_valid: true,

    pair_provenance: {
      cause: {
        artifact_sha256: $cause_sha,
        entity: {
          type: (
            if $cause_entity_type == "null"
            then null else $cause_entity_type end
          ),
          host: (
            if $cause_host == "null"
            then null else $cause_host end
          ),
          guid: (
            if $cause_guid == "null"
            then null else $cause_guid end
          )
        },
        event: {
          domain: (
            if $cause_domain == "null"
            then null else $cause_domain end
          ),
          type: (
            if $cause_event_type == "null"
            then null else $cause_event_type end
          )
        },
        observed_at: $cause_ts
      },

      effect: {
        artifact_sha256: $effect_sha,
        entity: {
          type: (
            if $effect_entity_type == "null"
            then null else $effect_entity_type end
          ),
          host: (
            if $effect_host == "null"
            then null else $effect_host end
          ),
          guid: (
            if $effect_guid == "null"
            then null else $effect_guid end
          ),
          domain: (
            if $effect_entity_domain == "null"
            then null else $effect_entity_domain end
          )
        },
        event: {
          domain: (
            if $effect_domain == "null"
            then null else $effect_domain end
          ),
          type: (
            if $effect_event_type == "null"
            then null else $effect_event_type end
          )
        },
        observed_at: $effect_ts
      }
    },

    temporal_state: $state,
    reason: $reason,
    ordering: $ordering,
    delta_seconds: $delta,
    correlation_window_seconds: $window,
    within_correlation_window: $within,

    causal_admissibility: {
      temporal_evidence_admissible: $admissible,
      confirmed_causality_admissible: false
    },

    boundaries: {
      causal_claim_confirmed: false,
      parent_event_assigned: false,
      incident_created: false,
      remediation_authorized: false
    }
  }'
