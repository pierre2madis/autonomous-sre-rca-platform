#!/usr/bin/env bash

set -uo pipefail

CAUSAL="${1:-}"
CAUSE_ENV="${2:-}"
EFFECT_ENV="${3:-}"
TEMPORAL="${4:-}"

#
# Hard input failures.
#
[[ -n "$CAUSAL" && -f "$CAUSAL" ]] || {
    echo "ERROR: causal evidence artifact unavailable" >&2
    exit 3
}

[[ -n "$CAUSE_ENV" && -f "$CAUSE_ENV" ]] || {
    echo "ERROR: cause temporal envelope unavailable" >&2
    exit 4
}

[[ -n "$EFFECT_ENV" && -f "$EFFECT_ENV" ]] || {
    echo "ERROR: effect temporal envelope unavailable" >&2
    exit 5
}

[[ -n "$TEMPORAL" && -f "$TEMPORAL" ]] || {
    echo "ERROR: temporal decision artifact unavailable" >&2
    exit 6
}

jq -e . "$CAUSAL" >/dev/null 2>&1 || {
    echo "ERROR: invalid causal evidence JSON" >&2
    exit 7
}

jq -e . "$CAUSE_ENV" >/dev/null 2>&1 || {
    echo "ERROR: invalid cause envelope JSON" >&2
    exit 8
}

jq -e . "$EFFECT_ENV" >/dev/null 2>&1 || {
    echo "ERROR: invalid effect envelope JSON" >&2
    exit 9
}

jq -e . "$TEMPORAL" >/dev/null 2>&1 || {
    echo "ERROR: invalid temporal decision JSON" >&2
    exit 10
}

#
# Exact artifact identities are computed locally.
#
CAUSAL_SHA="$(sha256sum "$CAUSAL" | awk '{print $1}')"
CAUSE_ENV_SHA="$(sha256sum "$CAUSE_ENV" | awk '{print $1}')"
EFFECT_ENV_SHA="$(sha256sum "$EFFECT_ENV" | awk '{print $1}')"
TEMPORAL_SHA="$(sha256sum "$TEMPORAL" | awk '{print $1}')"

#
# ------------------------------------------------------------------
# Non-temporal causal candidate.
# ------------------------------------------------------------------
#
RELATIONSHIP="$(jq -r '.causal_candidate.relationship // "UNAVAILABLE"' "$CAUSAL")"
CAUSAL_STATUS="$(jq -r '.causal_candidate.causal_status // "UNAVAILABLE"' "$CAUSAL")"

CORRELATION_VALID="$(
    jq -r '
      if .observed_fact.evidence.correlation_valid == null
      then "UNAVAILABLE"
      else (.observed_fact.evidence.correlation_valid|tostring)
      end
    ' "$CAUSAL"
)"

IDENTITY_MATCH="$(
    jq -r '
      if .observed_fact.evidence.identity_match == null
      then "UNAVAILABLE"
      else (.observed_fact.evidence.identity_match|tostring)
      end
    ' "$CAUSAL"
)"

ENTITY_GUID="$(jq -r '.entity.identity.guid // "UNAVAILABLE"' "$CAUSAL")"

CAUSE_ENTITY_TYPE="$(
    jq -r '.causal_candidate.cause.entity_type // "UNAVAILABLE"' "$CAUSAL"
)"

CAUSE_GUID="$(
    jq -r '.causal_candidate.cause.entity_guid // "UNAVAILABLE"' "$CAUSAL"
)"

CAUSE_TYPE="$(
    jq -r '.causal_candidate.cause.type // "UNAVAILABLE"' "$CAUSAL"
)"

EFFECT_DOMAIN="$(
    jq -r '.causal_candidate.effect.domain // "UNAVAILABLE"' "$CAUSAL"
)"

EFFECT_TYPE="$(
    jq -r '.causal_candidate.effect.type // "UNAVAILABLE"' "$CAUSAL"
)"

NON_TEMPORAL_VALID=false

if [[ "$RELATIONSHIP" == "POTENTIAL_CAUSE" \
   && "$CAUSAL_STATUS" == "CANDIDATE" \
   && "$CORRELATION_VALID" == "true" \
   && "$IDENTITY_MATCH" == "true" \
   && "$ENTITY_GUID" != "UNAVAILABLE" \
   && "$CAUSE_GUID" == "$ENTITY_GUID" \
   && "$CAUSE_ENTITY_TYPE" != "UNAVAILABLE" \
   && "$CAUSE_TYPE" != "UNAVAILABLE" \
   && "$EFFECT_DOMAIN" != "UNAVAILABLE" \
   && "$EFFECT_TYPE" != "UNAVAILABLE" ]]
then
    NON_TEMPORAL_VALID=true
fi

#
# ------------------------------------------------------------------
# Semantic alignment against the exact temporal envelopes.
# ------------------------------------------------------------------
#
ENV_CAUSE_ENTITY_TYPE="$(jq -r '.entity.type // "UNAVAILABLE"' "$CAUSE_ENV")"
ENV_CAUSE_GUID="$(jq -r '.entity.guid // "UNAVAILABLE"' "$CAUSE_ENV")"
ENV_CAUSE_EVENT_TYPE="$(jq -r '.event.type // "UNAVAILABLE"' "$CAUSE_ENV")"

ENV_EFFECT_DOMAIN="$(
    jq -r '
      .event.domain //
      .entity.domain //
      "UNAVAILABLE"
    ' "$EFFECT_ENV"
)"

ENV_EFFECT_EVENT_TYPE="$(jq -r '.event.type // "UNAVAILABLE"' "$EFFECT_ENV")"

CAUSE_ENTITY_TYPE_MATCH=false
CAUSE_GUID_MATCH=false
CAUSE_EVENT_MATCH=false
EFFECT_DOMAIN_MATCH=false
EFFECT_EVENT_MATCH=false

[[ "$CAUSE_ENTITY_TYPE" == "$ENV_CAUSE_ENTITY_TYPE" ]] \
    && CAUSE_ENTITY_TYPE_MATCH=true

[[ "$CAUSE_GUID" == "$ENV_CAUSE_GUID" ]] \
    && CAUSE_GUID_MATCH=true

[[ "$CAUSE_TYPE" == "$ENV_CAUSE_EVENT_TYPE" ]] \
    && CAUSE_EVENT_MATCH=true

[[ "$EFFECT_DOMAIN" == "$ENV_EFFECT_DOMAIN" ]] \
    && EFFECT_DOMAIN_MATCH=true

[[ "$EFFECT_TYPE" == "$ENV_EFFECT_EVENT_TYPE" ]] \
    && EFFECT_EVENT_MATCH=true

SEMANTIC_PAIR_VALID=false

if [[ "$CAUSE_ENTITY_TYPE_MATCH" == true \
   && "$CAUSE_GUID_MATCH" == true \
   && "$CAUSE_EVENT_MATCH" == true \
   && "$EFFECT_DOMAIN_MATCH" == true \
   && "$EFFECT_EVENT_MATCH" == true ]]
then
    SEMANTIC_PAIR_VALID=true
fi

#
# ------------------------------------------------------------------
# Cryptographic binding between envelopes and temporal decision.
# ------------------------------------------------------------------
#
DECISION_CAUSE_SHA="$(
    jq -r '.pair_provenance.cause.artifact_sha256 // "UNAVAILABLE"' "$TEMPORAL"
)"

DECISION_EFFECT_SHA="$(
    jq -r '.pair_provenance.effect.artifact_sha256 // "UNAVAILABLE"' "$TEMPORAL"
)"

CAUSE_SHA_MATCH=false
EFFECT_SHA_MATCH=false

[[ "$CAUSE_ENV_SHA" == "$DECISION_CAUSE_SHA" ]] \
    && CAUSE_SHA_MATCH=true

[[ "$EFFECT_ENV_SHA" == "$DECISION_EFFECT_SHA" ]] \
    && EFFECT_SHA_MATCH=true

CRYPTOGRAPHIC_PAIR_VALID=false

if [[ "$CAUSE_SHA_MATCH" == true \
   && "$EFFECT_SHA_MATCH" == true ]]
then
    CRYPTOGRAPHIC_PAIR_VALID=true
fi

#
# ------------------------------------------------------------------
# Semantic provenance carried by temporal decision itself.
# This protects against a decision whose SHA references are correct
# but whose embedded semantic representation is incoherent.
# ------------------------------------------------------------------
#
TP_CAUSE_ENTITY_TYPE="$(
    jq -r '.pair_provenance.cause.entity.type // "UNAVAILABLE"' "$TEMPORAL"
)"

TP_CAUSE_GUID="$(
    jq -r '.pair_provenance.cause.entity.guid // "UNAVAILABLE"' "$TEMPORAL"
)"

TP_CAUSE_EVENT_TYPE="$(
    jq -r '.pair_provenance.cause.event.type // "UNAVAILABLE"' "$TEMPORAL"
)"

TP_EFFECT_DOMAIN="$(
    jq -r '
      .pair_provenance.effect.event.domain //
      .pair_provenance.effect.entity.domain //
      "UNAVAILABLE"
    ' "$TEMPORAL"
)"

TP_EFFECT_EVENT_TYPE="$(
    jq -r '.pair_provenance.effect.event.type // "UNAVAILABLE"' "$TEMPORAL"
)"

TEMPORAL_SEMANTIC_PROVENANCE_VALID=false

if [[ "$TP_CAUSE_ENTITY_TYPE" == "$ENV_CAUSE_ENTITY_TYPE" \
   && "$TP_CAUSE_GUID" == "$ENV_CAUSE_GUID" \
   && "$TP_CAUSE_EVENT_TYPE" == "$ENV_CAUSE_EVENT_TYPE" \
   && "$TP_EFFECT_DOMAIN" == "$ENV_EFFECT_DOMAIN" \
   && "$TP_EFFECT_EVENT_TYPE" == "$ENV_EFFECT_EVENT_TYPE" ]]
then
    TEMPORAL_SEMANTIC_PROVENANCE_VALID=true
fi

#
# ------------------------------------------------------------------
# Temporal decision.
# ------------------------------------------------------------------
#
DECISION_VALID="$(
    jq -r '
      if .decision_valid == null
      then "UNAVAILABLE"
      else (.decision_valid|tostring)
      end
    ' "$TEMPORAL"
)"

TEMPORAL_STATE="$(jq -r '.temporal_state // "UNAVAILABLE"' "$TEMPORAL")"
ORDERING="$(jq -r '.ordering // "UNAVAILABLE"' "$TEMPORAL")"

TEMPORAL_ADMISSIBLE="$(
    jq -r '
      if .causal_admissibility.temporal_evidence_admissible == null
      then "UNAVAILABLE"
      else (.causal_admissibility.temporal_evidence_admissible|tostring)
      end
    ' "$TEMPORAL"
)"

#
# ------------------------------------------------------------------
# Final composition state.
# ------------------------------------------------------------------
#
STATE=""
REASON=""

PROVENANCE_VALID=false

if [[ "$SEMANTIC_PAIR_VALID" == true \
   && "$CRYPTOGRAPHIC_PAIR_VALID" == true \
   && "$TEMPORAL_SEMANTIC_PROVENANCE_VALID" == true ]]
then
    PROVENANCE_VALID=true
fi

if [[ "$NON_TEMPORAL_VALID" != true ]]; then

    STATE="CAUSAL_EVIDENCE_NOT_ADMISSIBLE"
    REASON="NON_TEMPORAL_CAUSAL_CANDIDATE_INVALID"

elif [[ "$PROVENANCE_VALID" != true ]]; then

    STATE="CAUSAL_EVIDENCE_NOT_ADMISSIBLE"
    REASON="CROSS_ARTIFACT_PROVENANCE_INCOHERENT"

elif [[ "$DECISION_VALID" != "true" ]]; then

    STATE="CAUSAL_EVIDENCE_NOT_ADMISSIBLE"
    REASON="TEMPORAL_DECISION_INVALID"

elif [[ "$TEMPORAL_STATE" == "NOT_EVALUABLE" \
     || "$TEMPORAL_STATE" == "TEMPORALLY_INDETERMINATE" ]]; then

    STATE="CAUSAL_EVIDENCE_INDETERMINATE"
    REASON="TEMPORAL_CAUSAL_ORDERING_NOT_ESTABLISHED"

elif [[ "$TEMPORAL_STATE" == "TEMPORALLY_ADMISSIBLE" \
     && "$TEMPORAL_ADMISSIBLE" == "true" \
     && "$ORDERING" == "CAUSE_BEFORE_EFFECT" ]]; then

    STATE="CAUSAL_EVIDENCE_ADMISSIBLE"
    REASON="NON_TEMPORAL_AND_TEMPORAL_EVIDENCE_COHERENT"

else

    STATE="CAUSAL_EVIDENCE_REJECTED"
    REASON="TEMPORAL_EVIDENCE_REJECTS_CAUSAL_ADMISSIBILITY"

fi

jq -n \
  --arg causal_sha "$CAUSAL_SHA" \
  --arg cause_env_sha "$CAUSE_ENV_SHA" \
  --arg effect_env_sha "$EFFECT_ENV_SHA" \
  --arg temporal_sha "$TEMPORAL_SHA" \
  --arg relationship "$RELATIONSHIP" \
  --arg causal_status "$CAUSAL_STATUS" \
  --argjson non_temporal_valid "$NON_TEMPORAL_VALID" \
  --arg cause_entity_type "$CAUSE_ENTITY_TYPE" \
  --arg cause_guid "$CAUSE_GUID" \
  --arg cause_type "$CAUSE_TYPE" \
  --arg effect_domain "$EFFECT_DOMAIN" \
  --arg effect_type "$EFFECT_TYPE" \
  --argjson cause_entity_type_match "$CAUSE_ENTITY_TYPE_MATCH" \
  --argjson cause_guid_match "$CAUSE_GUID_MATCH" \
  --argjson cause_event_match "$CAUSE_EVENT_MATCH" \
  --argjson effect_domain_match "$EFFECT_DOMAIN_MATCH" \
  --argjson effect_event_match "$EFFECT_EVENT_MATCH" \
  --argjson semantic_pair_valid "$SEMANTIC_PAIR_VALID" \
  --arg decision_cause_sha "$DECISION_CAUSE_SHA" \
  --arg decision_effect_sha "$DECISION_EFFECT_SHA" \
  --argjson cause_sha_match "$CAUSE_SHA_MATCH" \
  --argjson effect_sha_match "$EFFECT_SHA_MATCH" \
  --argjson cryptographic_pair_valid "$CRYPTOGRAPHIC_PAIR_VALID" \
  --argjson temporal_semantic_valid "$TEMPORAL_SEMANTIC_PROVENANCE_VALID" \
  --argjson provenance_valid "$PROVENANCE_VALID" \
  --arg decision_valid "$DECISION_VALID" \
  --arg temporal_state "$TEMPORAL_STATE" \
  --arg ordering "$ORDERING" \
  --arg temporal_admissible "$TEMPORAL_ADMISSIBLE" \
  --arg state "$STATE" \
  --arg reason "$REASON" '
{
  schema_version: "1.1",

  composer: {
    name: "splunk_causal_admissibility_composer",
    version: "1.1.0-candidate"
  },

  authority: {
    layer: "M2.3D-5F",
    type: "CAUSAL_ADMISSIBILITY_COMPOSITION",

    causal_confirmation_authority: false,
    parent_assignment_authority: false,
    incident_creation_authority: false,
    remediation_authority: false
  },

  inputs: {
    causal_candidate: {
      artifact_sha256: $causal_sha,
      relationship: $relationship,
      causal_status: $causal_status
    },

    cause_temporal_envelope: {
      artifact_sha256: $cause_env_sha
    },

    effect_temporal_envelope: {
      artifact_sha256: $effect_env_sha
    },

    temporal_decision: {
      artifact_sha256: $temporal_sha,
      decision_valid:
        (if $decision_valid == "true" then true
         elif $decision_valid == "false" then false
         else null end)
    }
  },

  non_temporal_evidence: {
    valid: $non_temporal_valid,

    expected_relationship: {
      cause: {
        entity_type: $cause_entity_type,
        entity_guid: $cause_guid,
        event_type: $cause_type
      },

      effect: {
        domain: $effect_domain,
        event_type: $effect_type
      }
    }
  },

  provenance_coherence: {
    semantic: {
      cause_entity_type_match: $cause_entity_type_match,
      cause_guid_match: $cause_guid_match,
      cause_event_type_match: $cause_event_match,
      effect_domain_match: $effect_domain_match,
      effect_event_type_match: $effect_event_match,
      valid: $semantic_pair_valid
    },

    cryptographic: {
      decision_cause_artifact_sha256: $decision_cause_sha,
      actual_cause_artifact_sha256: $cause_env_sha,
      cause_match: $cause_sha_match,

      decision_effect_artifact_sha256: $decision_effect_sha,
      actual_effect_artifact_sha256: $effect_env_sha,
      effect_match: $effect_sha_match,

      valid: $cryptographic_pair_valid
    },

    temporal_semantic_provenance: {
      valid: $temporal_semantic_valid
    },

    valid: $provenance_valid
  },

  temporal_evidence: {
    state: $temporal_state,

    ordering:
      (if $ordering == "UNAVAILABLE"
       then null
       else $ordering end),

    admissible:
      (if $temporal_admissible == "true" then true
       elif $temporal_admissible == "false" then false
       else null end)
  },

  decision: {
    state: $state,
    reason: $reason
  },

  boundaries: {
    causal_claim_confirmed: false,
    parent_event_assigned: false,
    incident_created: false,
    remediation_authorized: false
  }
}'
