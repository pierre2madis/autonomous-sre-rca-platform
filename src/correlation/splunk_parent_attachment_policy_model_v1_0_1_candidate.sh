#!/usr/bin/env bash

set -uo pipefail

VERSION="1.0.1-candidate"

usage() {
    cat <<USAGE
Usage:
  $0 INCIDENT_GRAPH_POLICY_INPUT.json

Purpose:
  Evaluate whether a proposed child event is eligible for attachment
  to an existing parent event inside an existing incident graph.

Authority:
  POLICY DECISION ONLY.

This model does NOT:
  - mutate the incident graph
  - assign the parent
  - create or suppress incidents
  - mutate incident state
  - authorize notifications
  - authorize remediation
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

INPUT="${1:-}"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
    echo "ERROR: incident graph policy input missing" >&2
    exit 3
fi

if ! jq -e . "$INPUT" >/dev/null 2>&1; then
    echo "ERROR: invalid incident graph policy input JSON" >&2
    exit 4
fi

INPUT_SHA="$(sha256sum "$INPUT" | awk '{print $1}')"

#
# ---------------------------------------------------------------
# Required proposed attachment identities.
# ---------------------------------------------------------------
#
INCIDENT_ID="$(
    jq -r '.proposed_attachment.incident_id // "UNAVAILABLE"' "$INPUT"
)"

PARENT_EVENT_ID="$(
    jq -r '.proposed_attachment.parent_event_id // "UNAVAILABLE"' "$INPUT"
)"

CHILD_EVENT_ID="$(
    jq -r '.proposed_attachment.child.event_id // "UNAVAILABLE"' "$INPUT"
)"

#
# Policy.
#
MAX_DEPTH="$(
    jq -r '
      if .policy.max_causal_depth == null
      then "UNAVAILABLE"
      else (.policy.max_causal_depth | tostring)
      end
    ' "$INPUT"
)"

MULTIPLE_PARENT_POLICY="$(
    jq -r '
      .policy.multiple_parent_policy // "UNAVAILABLE"
    ' "$INPUT"
)"

#
# ---------------------------------------------------------------
# Basic input contract validation.
# ---------------------------------------------------------------
#
INPUT_VALID=true

if [[ "$INCIDENT_ID" == "UNAVAILABLE" ||
      "$PARENT_EVENT_ID" == "UNAVAILABLE" ||
      "$CHILD_EVENT_ID" == "UNAVAILABLE" ||
      "$MAX_DEPTH" == "UNAVAILABLE" ]]; then
    INPUT_VALID=false
fi

if ! [[ "$MAX_DEPTH" =~ ^[0-9]+$ ]] || (( MAX_DEPTH < 1 )); then
    INPUT_VALID=false
fi

#
# ---------------------------------------------------------------
# Incident existence.
# ---------------------------------------------------------------
#
INCIDENT_COUNT="$(
    jq \
      --arg incident "$INCIDENT_ID" '
        [
          .graph.incidents[]? |
          select(.incident_id == $incident)
        ] |
        length
      ' "$INPUT"
)"

if (( INCIDENT_COUNT == 1 )); then
    INCIDENT_EXISTS=true
else
    INCIDENT_EXISTS=false
fi

#
# ---------------------------------------------------------------
# Parent existence anywhere in graph.
# ---------------------------------------------------------------
#
PARENT_GLOBAL_COUNT="$(
    jq \
      --arg parent "$PARENT_EVENT_ID" '
        [
          .graph.incidents[]?.events[]? |
          select(.event_id == $parent)
        ] |
        length
      ' "$INPUT"
)"

if (( PARENT_GLOBAL_COUNT > 0 )); then
    PARENT_EXISTS=true
else
    PARENT_EXISTS=false
fi

#
# Parent belongs to requested incident.
#
PARENT_INCIDENT_COUNT="$(
    jq \
      --arg incident "$INCIDENT_ID" \
      --arg parent "$PARENT_EVENT_ID" '
        [
          .graph.incidents[]? |
          select(.incident_id == $incident) |
          .events[]? |
          select(.event_id == $parent)
        ] |
        length
      ' "$INPUT"
)"

if (( PARENT_INCIDENT_COUNT == 1 )); then
    PARENT_BELONGS=true
else
    PARENT_BELONGS=false
fi

#
# ---------------------------------------------------------------
# Duplicate child detection.
# ---------------------------------------------------------------
#
CHILD_GLOBAL_COUNT="$(
    jq \
      --arg child "$CHILD_EVENT_ID" '
        [
          .graph.incidents[]?.events[]? |
          select(.event_id == $child)
        ] |
        length
      ' "$INPUT"
)"

if (( CHILD_GLOBAL_COUNT > 0 )); then
    CHILD_ALREADY_EXISTS=true
else
    CHILD_ALREADY_EXISTS=false
fi

#
# ---------------------------------------------------------------
# Existing parent detection.
#
# We inspect both the event parent_event_id and graph edges.
# ---------------------------------------------------------------
#
CHILD_PARENT_COUNT="$(
    jq \
      --arg child "$CHILD_EVENT_ID" '
        [
          .graph.incidents[]?.events[]? |
          select(
            .event_id == $child
            and
            .parent_event_id != null
          )
        ] |
        length
      ' "$INPUT"
)"

CHILD_EDGE_PARENT_COUNT="$(
    jq \
      --arg child "$CHILD_EVENT_ID" '
        [
          .graph.incidents[]?.edges[]? |
          select(.child_event_id == $child)
        ] |
        length
      ' "$INPUT"
)"

if (( CHILD_PARENT_COUNT > 0 || CHILD_EDGE_PARENT_COUNT > 0 )); then
    CHILD_HAS_PARENT=true
else
    CHILD_HAS_PARENT=false
fi

#
# ---------------------------------------------------------------
# Cycle protection.
#
# Immediate self-cycle:
#
#     parent_event_id == child_event_id
#
# Transitive cycle:
#
# If the proposed child is already an ancestor of the proposed
# parent, adding parent -> child would close a cycle.
#
# Because the graph contract already carries parent_event_id,
# ancestry can be evaluated deterministically.
# ---------------------------------------------------------------
#
SELF_CYCLE=false
TRANSITIVE_CYCLE=false

if [[ "$PARENT_EVENT_ID" == "$CHILD_EVENT_ID" ]]; then
    SELF_CYCLE=true
fi

#
# Walk from proposed parent toward the root.
# If proposed child appears in that ancestry, adding the edge
# parent -> child would create a cycle.
#
CURRENT="$PARENT_EVENT_ID"
SEEN="|"
ITER=0
MAX_ITER=1024

while [[ "$CURRENT" != "UNAVAILABLE" &&
         "$CURRENT" != "null" &&
         -n "$CURRENT" ]]; do

    if [[ "$CURRENT" == "$CHILD_EVENT_ID" ]]; then
        TRANSITIVE_CYCLE=true
        break
    fi

    if [[ "$SEEN" == *"|$CURRENT|"* ]]; then
        #
        # Existing malformed graph cycle.
        #
        TRANSITIVE_CYCLE=true
        break
    fi

    SEEN="${SEEN}${CURRENT}|"

    NEXT="$(
        jq -r \
          --arg current "$CURRENT" '
            [
              .graph.incidents[]?.events[]? |
              select(.event_id == $current) |
              .parent_event_id
            ][0] // "UNAVAILABLE"
          ' "$INPUT"
    )"

    CURRENT="$NEXT"

    ITER=$((ITER + 1))

    if (( ITER > MAX_ITER )); then
        TRANSITIVE_CYCLE=true
        break
    fi
done

if [[ "$SELF_CYCLE" == true || "$TRANSITIVE_CYCLE" == true ]]; then
    CYCLE_DETECTED=true
else
    CYCLE_DETECTED=false
fi

#
# ---------------------------------------------------------------
# Proposed causal depth.
# ---------------------------------------------------------------
#
PARENT_DEPTH="$(
    jq -r \
      --arg incident "$INCIDENT_ID" \
      --arg parent "$PARENT_EVENT_ID" '
        [
          .graph.incidents[]? |
          select(.incident_id == $incident) |
          .events[]? |
          select(.event_id == $parent) |
          .causal_depth
        ][0] // "UNAVAILABLE"
      ' "$INPUT"
)"

PROPOSED_DEPTH="UNAVAILABLE"
DEPTH_EXCEEDED="UNAVAILABLE"

if [[ "$PARENT_DEPTH" =~ ^[0-9]+$ &&
      "$MAX_DEPTH" =~ ^[0-9]+$ ]]; then
    PROPOSED_DEPTH=$((PARENT_DEPTH + 1))

    if (( PROPOSED_DEPTH > MAX_DEPTH )); then
        DEPTH_EXCEEDED=true
    else
        DEPTH_EXCEEDED=false
    fi
fi

#
# ---------------------------------------------------------------
# Deterministic policy decision.
#
# Precedence is intentional.
# ---------------------------------------------------------------
#
STATE=""
REASON=""
ELIGIBLE=false


#
# ================================================================
# V1.0.1 — Graph Integrity Admission Gate
#
# Graph integrity is evaluated before relationship policy.
# Integrity-invalid evidence produces a modeled fail-closed
# decision with rc=0.
#
# parent_event_id is the canonical stored parent relation.
# edges[] is a redundant representation that must be
# referentially valid and consistent when present.
# ================================================================
#

INTEGRITY_STRUCTURAL="VALID"
INTEGRITY_POLICY="VALID"
INTEGRITY_IDENTITY="VALID"
INTEGRITY_EDGE="VALID"
INTEGRITY_OWNERSHIP="VALID"
INTEGRITY_EXISTING_CYCLE="ACYCLIC"
INTEGRITY_OVERALL="VALID"

INTEGRITY_STATE=""
INTEGRITY_REASON=""

TARGET_COUNT=0
PARENT_GLOBAL_COUNT=0
PARENT_TARGET_COUNT=0
CHILD_GLOBAL_COUNT=0

#
# ------------------------------------------------
# 1. Structural integrity
# ------------------------------------------------
#
STRUCTURE_VALID="$(
    jq -r '
      (
        (type == "object")
        and
        (.policy | type == "object")
        and
        (.graph | type == "object")
        and
        (.proposed_attachment | type == "object")
        and
        (.graph.incidents | type == "array")
      )
    ' "$INPUT" 2>/dev/null || printf '%s\n' false
)"

if [[ "$STRUCTURE_VALID" != "true" ]]; then
    INTEGRITY_STRUCTURAL="INVALID"
    INTEGRITY_OVERALL="INVALID"
    INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
    INTEGRITY_REASON="INCIDENT_GRAPH_STRUCTURE_INVALID"
fi

#
# ------------------------------------------------
# 2. Policy vocabulary integrity
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" ]]; then

    POLICY_VALID="$(
        jq -r '
          (
            .policy.multiple_parent_policy
              == "SINGLE_PARENT_ONLY"
            and
            .policy.duplicate_event_policy
              == "REJECT_DUPLICATE_ATTACHMENT"
            and
            .policy.cycle_policy
              == "REJECT_CYCLE"
            and
            (
              (.policy.max_causal_depth | type) == "number"
              and
              (.policy.max_causal_depth | floor)
                == .policy.max_causal_depth
              and
              .policy.max_causal_depth >= 0
            )
          )
        ' "$INPUT" 2>/dev/null || printf '%s\n' false
    )"

    if [[ "$POLICY_VALID" != "true" ]]; then
        INTEGRITY_POLICY="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="UNKNOWN_OR_INVALID_POLICY"
    fi
fi

#
# ------------------------------------------------
# 3. Identity cardinality
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" ]]; then

    TARGET_COUNT="$(
        jq -r \
          --arg incident "$INCIDENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
            ]
            | length
          ' "$INPUT"
    )"

    PARENT_GLOBAL_COUNT="$(
        jq -r \
          --arg parent "$PARENT_EVENT_ID" '
            [
              .graph.incidents[]?.events[]?
              |
              select(.event_id == $parent)
            ]
            | length
          ' "$INPUT"
    )"

    PARENT_TARGET_COUNT="$(
        jq -r \
          --arg incident "$INCIDENT_ID" \
          --arg parent "$PARENT_EVENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
              |
              .events[]?
              |
              select(.event_id == $parent)
            ]
            | length
          ' "$INPUT"
    )"

    CHILD_GLOBAL_COUNT="$(
        jq -r \
          --arg child "$CHILD_EVENT_ID" '
            [
              .graph.incidents[]?.events[]?
              |
              select(.event_id == $child)
            ]
            | length
          ' "$INPUT"
    )"

    if [[ ! "$TARGET_COUNT" =~ ^[0-9]+$ ||
          ! "$PARENT_GLOBAL_COUNT" =~ ^[0-9]+$ ||
          ! "$PARENT_TARGET_COUNT" =~ ^[0-9]+$ ||
          ! "$CHILD_GLOBAL_COUNT" =~ ^[0-9]+$ ]]; then

        INTEGRITY_IDENTITY="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="INCIDENT_GRAPH_IDENTITY_AMBIGUOUS"

    elif (( TARGET_COUNT > 1 ||
            PARENT_GLOBAL_COUNT > 1 ||
            PARENT_TARGET_COUNT > 1 ||
            CHILD_GLOBAL_COUNT > 1 )); then

        INTEGRITY_IDENTITY="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="INCIDENT_GRAPH_IDENTITY_AMBIGUOUS"
    fi
fi

#
# Missing identities remain policy semantics, not corruption:
#
# TARGET_COUNT == 0        -> TARGET_INCIDENT_NOT_FOUND
# PARENT_GLOBAL_COUNT == 0 -> PARENT_EVENT_NOT_FOUND
#
# The integrity gate handles ambiguity; the existing V1.0.0
# decision tree preserves absence semantics.
#

#
# ------------------------------------------------
# 4. Target incident structural integrity
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" &&
      "$TARGET_COUNT" == "1" ]]; then

    TARGET_STRUCTURE_VALID="$(
        jq -r \
          --arg incident "$INCIDENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
            ][0]
            |
            (
              (.events | type) == "array"
              and
              (.edges | type) == "array"
            )
          ' "$INPUT" 2>/dev/null || printf '%s\n' false
    )"

    if [[ "$TARGET_STRUCTURE_VALID" != "true" ]]; then
        INTEGRITY_STRUCTURAL="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="INCIDENT_GRAPH_STRUCTURE_INVALID"
    fi
fi

#
# ------------------------------------------------
# 5. Edge referential integrity
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" &&
      "$TARGET_COUNT" == "1" ]]; then

    EDGE_VALID="$(
        jq -r \
          --arg incident "$INCIDENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
            ][0] as $i

            |

            (
              [
                $i.edges[]? as $e
                |
                (
                  (($e.parent_event_id | type) == "string")
                  and
                  (($e.parent_event_id | length) > 0)
                  and
                  (($e.child_event_id | type) == "string")
                  and
                  (($e.child_event_id | length) > 0)
                  and
                  (
                    [
                      $i.events[]?
                      |
                      select(.event_id == $e.parent_event_id)
                    ]
                    | length
                  ) == 1
                  and
                  (
                    [
                      $i.events[]?
                      |
                      select(.event_id == $e.child_event_id)
                    ]
                    | length
                  ) == 1
                )
              ]
              | all
            )

            and

            (
              [
                $i.edges[]?
                |
                "\(.parent_event_id)\u0000\(.child_event_id)"
              ] as $keys
              |
              ($keys | length)
                ==
              ($keys | unique | length)
            )
          ' "$INPUT" 2>/dev/null || printf '%s\n' false
    )"

    if [[ "$EDGE_VALID" != "true" ]]; then
        INTEGRITY_EDGE="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="INCIDENT_GRAPH_EDGE_INTEGRITY_INVALID"
    fi
fi

#
# ------------------------------------------------
# 6. Parent ownership consistency
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" &&
      "$TARGET_COUNT" == "1" ]]; then

    OWNERSHIP_VALID="$(
        jq -r \
          --arg incident "$INCIDENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
            ][0] as $i

            |

            [
              $i.events[]? as $event

              |

              (
                [
                  $i.edges[]?
                  |
                  select(
                    .child_event_id == $event.event_id
                  )
                  |
                  .parent_event_id
                ]
                | unique
              ) as $edge_parents

              |

              if $event.parent_event_id == null
              then
                (($edge_parents | length) == 0)

              elif
                (
                  ($event.parent_event_id | type) != "string"
                  or
                  ($event.parent_event_id | length) == 0
                )
              then
                false

              else
                (
                  (($edge_parents | length) <= 1)
                  and
                  (
                    (($edge_parents | length) == 0)
                    or
                    ($edge_parents[0] == $event.parent_event_id)
                  )
                )
              end
            ]
            | all
          ' "$INPUT" 2>/dev/null || printf '%s\n' false
    )"

    if [[ "$OWNERSHIP_VALID" != "true" ]]; then
        INTEGRITY_OWNERSHIP="INVALID"
        INTEGRITY_OVERALL="INVALID"
        INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
        INTEGRITY_REASON="INCIDENT_GRAPH_PARENT_OWNERSHIP_INCONSISTENT"
    fi
fi

#
# ------------------------------------------------
# 7. Existing target-incident cycle integrity
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" == "VALID" &&
      "$TARGET_COUNT" == "1" ]]; then

    CYCLE_RESULT="$(
        jq -r \
          --arg incident "$INCIDENT_ID" '
            [
              .graph.incidents[]?
              |
              select(.incident_id == $incident)
            ][0] as $i

            |

            (
            reduce $i.events[]? as $e
              ({};
               .[$e.event_id] = $e.parent_event_id)
              ) as $parents

            |

            def walk_parent($current; $visited; $steps):

              if $steps > 1024
              then
                "LIMIT"

              elif $current == null
              then
                "OK"

              elif ($visited | index($current)) != null
              then
                "CYCLE"

              elif ($parents | has($current) | not)
              then
                "OK"

              else
                walk_parent(
                  $parents[$current];
                  ($visited + [$current]);
                  ($steps + 1)
                )
              end;

            [
              $i.events[]?.event_id as $id
              |
              walk_parent($id; []; 0)
            ]

            |

            if index("CYCLE") != null
            then
              "CYCLE"
            elif index("LIMIT") != null
            then
              "LIMIT"
            else
              "ACYCLIC"
            end
          ' "$INPUT" 2>/dev/null || printf '%s\n' INVALID
    )"

    case "$CYCLE_RESULT" in

        ACYCLIC)
            INTEGRITY_EXISTING_CYCLE="ACYCLIC"
            ;;

        CYCLE)
            INTEGRITY_EXISTING_CYCLE="CYCLE_DETECTED"
            INTEGRITY_OVERALL="INVALID"
            INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
            INTEGRITY_REASON="INCIDENT_GRAPH_EXISTING_CYCLE"
            ;;

        *)
            INTEGRITY_EXISTING_CYCLE="NOT_EVALUATED"
            INTEGRITY_OVERALL="INVALID"
            INTEGRITY_STATE="PARENT_ATTACHMENT_INDETERMINATE"
            INTEGRITY_REASON="INCIDENT_GRAPH_EXISTING_CYCLE"
            ;;
    esac
fi

#
# ------------------------------------------------
# Integrity admission precedes V1.0.0 relationship policy.
# ------------------------------------------------
#
if [[ "$INTEGRITY_OVERALL" != "VALID" ]]; then
    STATE="$INTEGRITY_STATE"
    REASON="$INTEGRITY_REASON"
    ELIGIBLE=false

elif [[ "$INPUT_VALID" != true ]]; then


    STATE="PARENT_ATTACHMENT_INDETERMINATE"
    REASON="INVALID_POLICY_INPUT"

elif [[ "$INCIDENT_EXISTS" != true ]]; then

    STATE="NO_PARENT_CANDIDATE"
    REASON="TARGET_INCIDENT_NOT_FOUND"

elif [[ "$PARENT_EXISTS" != true ]]; then

    STATE="NO_PARENT_CANDIDATE"
    REASON="PARENT_EVENT_NOT_FOUND"

elif [[ "$PARENT_BELONGS" != true ]]; then

    STATE="PARENT_ATTACHMENT_NOT_ELIGIBLE"
    REASON="PARENT_NOT_MEMBER_OF_TARGET_INCIDENT"

elif [[ "$CYCLE_DETECTED" == true ]]; then

    STATE="CAUSAL_CYCLE_REJECTED"
    REASON="PROPOSED_ATTACHMENT_CREATES_CAUSAL_CYCLE"

elif [[ "$CHILD_HAS_PARENT" == true &&
        "$MULTIPLE_PARENT_POLICY" == "SINGLE_PARENT_ONLY" ]]; then

    STATE="PARENT_ATTACHMENT_NOT_ELIGIBLE"
    REASON="CHILD_ALREADY_HAS_PARENT"

elif [[ "$CHILD_ALREADY_EXISTS" == true ]]; then

    STATE="DUPLICATE_EVENT"
    REASON="CHILD_EVENT_ALREADY_PRESENT_IN_INCIDENT_GRAPH"

elif [[ "$PROPOSED_DEPTH" == "UNAVAILABLE" ]]; then

    STATE="PARENT_ATTACHMENT_INDETERMINATE"
    REASON="PARENT_CAUSAL_DEPTH_UNAVAILABLE"

elif [[ "$DEPTH_EXCEEDED" == true ]]; then

    STATE="CAUSAL_DEPTH_EXCEEDED"
    REASON="PROPOSED_CAUSAL_DEPTH_EXCEEDS_POLICY"

else

    STATE="PARENT_ATTACHMENT_ELIGIBLE"
    REASON="PARENT_CHILD_ATTACHMENT_POLICY_SATISFIED"
    ELIGIBLE=true
fi

#
# ---------------------------------------------------------------
# Output.
# ---------------------------------------------------------------
#
jq -n \
  --arg version "$VERSION" \
  --arg input_sha "$INPUT_SHA" \
  --arg incident "$INCIDENT_ID" \
  --arg parent "$PARENT_EVENT_ID" \
  --arg child "$CHILD_EVENT_ID" \
  --argjson input_valid "$INPUT_VALID" \
  --argjson incident_exists "$INCIDENT_EXISTS" \
  --argjson parent_exists "$PARENT_EXISTS" \
  --argjson parent_belongs "$PARENT_BELONGS" \
  --argjson child_exists "$CHILD_ALREADY_EXISTS" \
  --argjson child_has_parent "$CHILD_HAS_PARENT" \
  --argjson self_cycle "$SELF_CYCLE" \
  --argjson transitive_cycle "$TRANSITIVE_CYCLE" \
  --argjson cycle "$CYCLE_DETECTED" \
  --arg parent_depth "$PARENT_DEPTH" \
  --arg proposed_depth "$PROPOSED_DEPTH" \
  --arg depth_exceeded "$DEPTH_EXCEEDED" \
  --arg integrity_structural "$INTEGRITY_STRUCTURAL" \
  --arg integrity_policy "$INTEGRITY_POLICY" \
  --arg integrity_identity "$INTEGRITY_IDENTITY" \
  --arg integrity_edge "$INTEGRITY_EDGE" \
  --arg integrity_ownership "$INTEGRITY_OWNERSHIP" \
  --arg integrity_existing_cycle "$INTEGRITY_EXISTING_CYCLE" \
  --arg integrity_overall "$INTEGRITY_OVERALL" \
  --arg state "$STATE" \
  --arg reason "$REASON" \
  --argjson eligible "$ELIGIBLE" '
{
  "schema_version": "1.0",

  "model": {
    "name": "splunk_parent_attachment_policy_model",
    "version": $version
  },

  "authority": {
    "phase": "M2.3D-5G",
    "type": "PARENT_ATTACHMENT_POLICY_DECISION",
    "graph_mutation_authority": false,
    "incident_mutation_authority": false
  },

  "input": {
    "artifact_sha256": $input_sha,
    "valid": $input_valid,

    "proposed_attachment": {
      "incident_id": $incident,
      "parent_event_id": $parent,
      "child_event_id": $child
    }
  },

  "evaluation": {
    "incident_exists": $incident_exists,
    "parent_exists": $parent_exists,
    "parent_belongs_to_incident": $parent_belongs,

    "child_already_exists": $child_exists,
    "child_has_parent": $child_has_parent,

    "cycle": {
      "self_cycle": $self_cycle,
      "transitive_cycle": $transitive_cycle,
      "detected": $cycle
    },

    "depth": {
      "parent": (
        if ($parent_depth | test("^[0-9]+$"))
        then ($parent_depth | tonumber)
        else null
        end
      ),

      "proposed": (
        if ($proposed_depth | test("^[0-9]+$"))
        then ($proposed_depth | tonumber)
        else null
        end
      ),

      "exceeded": (
        if $depth_exceeded == "UNAVAILABLE"
        then null
        elif $depth_exceeded == "true"
        then true
        else false
        end
      )
    }
  },

  "integrity": {
    "structural": $integrity_structural,
    "policy_vocabulary": $integrity_policy,
    "identity_cardinality": $integrity_identity,
    "edge_referential": $integrity_edge,
    "parent_ownership": $integrity_ownership,
    "existing_cycle": $integrity_existing_cycle,
    "overall": $integrity_overall
  },

  "decision": {
    "state": $state,
    "reason": $reason,
    "attachment_eligible": $eligible
  },

  "boundaries": {
    "causal_claim_confirmed": false,
    "graph_mutated": false,
    "parent_event_assigned": false,
    "incident_created": false,
    "incident_suppressed": false,
    "incident_state_mutated": false,
    "notification_authorized": false,
    "remediation_authorized": false
  }
}
'
