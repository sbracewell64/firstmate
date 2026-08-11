# shellcheck shell=bash
# fm-availability-lib.sh - single owner of what a model probe RESULT MEANS, and
# of the observation record routing reads it from.
# Usage: . bin/fm-availability-lib.sh
#
# THE DEFECT THIS EXISTS TO CLOSE. Two facts used to collapse into one recorded
# state, and they are materially different:
#
#   the probe could not run
#   the probe ran and positively established the candidate is unavailable
#
# The measured consequence: a routed model that is entitled and live was
# recorded `unknown` because no probe path existed for its harness, the routing
# chokepoint correctly refused every dispatch to the single-candidate pool it
# sits in, and the refusal named a hold nobody could repair because the reason
# it carried was the empty string. The enforcement was right and the reader was
# wrong, so this library repairs the reader rather than loosening the check.
#
# THE TYPE. An availability observation returns three values, never two:
#
#   AVAILABLE     the probe ran and positively established the required fact.
#   UNAVAILABLE   the probe ran successfully and positively established the
#                 candidate is unavailable or ineligible, for a named reason.
#   UNOBSERVABLE  the probe could not establish the state at all, because the
#                 reader itself could not execute, failed structurally, lacked a
#                 dependency, timed out, or otherwise could not observe reality.
#
# This is not a second observation type. It is bin/fm-verify-lib.sh's
# PASS / FAIL / NO_VERIFIER_RAN under the names the availability domain uses,
# bound to it by a total bijection here, and consumed through that library's own
# fm_verify_case so the exhaustiveness rule and the refusal to coerce a
# could-not-observe are the SAME code rather than a copy of it.
#
# UNOBSERVABLE IS NEVER SILENTLY ELIGIBLE, and it is never a hold either. A hold
# says the fleet cannot reach a model; a could-not-observe says nobody knows.
# Recording the second as the first is the collapse one level down, so the two
# land in different records with different repairs:
#
#   UNAVAILABLE   -> an availability hold, written through the supported writer
#                    in bin/fm-route-lib.sh, in that record's closed vocabulary.
#   UNOBSERVABLE  -> an observation entry carrying a TOOLING_GAP evidence block,
#                    which excludes the candidate from routing and names what
#                    has to be repaired to stop excluding it.
#   AVAILABLE     -> an observation entry and nothing else. A positive
#                    observation never releases a hold and never admits a
#                    candidate on its own: it only fails to exclude one, so a
#                    stale positive can never override a fresh negative.
#
# THE OBSERVATION RECORD IS EXCLUSION-ONLY BY CONSTRUCTION. Routing reads it to
# find candidates whose last attempted observation FAILED. A model that was
# never probed has no entry and is not excluded by this axis - "not yet
# observed" and "observation attempted and failed" are themselves two facts, and
# collapsing them would make an unprobed fleet unroutable.
#
# NOT BUILT: RUNTIME EVIDENCE AS A SECOND SOURCE OF A POSITIVE OBSERVATION.
# Worth stating rather than leaving to be rediscovered, because it looks obvious
# and this fleet's records cannot support it. The rule it would have to satisfy
# is that historical or current execution evidence proves a positive fact only
# if its FRESHNESS, IDENTITY and SCOPE are sufficient for the routing question
# being asked, and each of the three fails on measured grounds:
#
#   IDENTITY. state/<id>.meta and the wake ledger both record the model as the
#   bare alias a harness was handed (`opus`), not the registry key an
#   observation is about (`claude/opus`), and config/models.json's own entry for
#   that model records that the alias-to-model binding MOVES when the harness
#   updates, with no change to any config file. So a live task cannot identify
#   the model a routing decision is asking about; it can only name what somebody
#   typed.
#   FRESHNESS. Nothing records "the provider served an invocation at time T".
#   Status lines are wake events, and the ledger's task record is stamped when a
#   task ENDED, which can be hours after its last provider call.
#   SCOPE. A task outcome answers whether the work landed, which depends on the
#   pipeline, the code and the reviewer far more than on reachability. A success
#   therefore over-proves and a failure proves nothing, so neither maps onto this
#   question.
#
# A rule built on any of those would be `worked recently -> available`, which is
# the heuristic the captain ruled against, and the weakest form - "a
# conversation is using it" - was ruled out outright. If a per-invocation
# served-at record keyed on the RESOLVED model id ever exists, the question is
# worth reopening against these same three tests; until then a positive fact
# comes from a probe or from nowhere.
#
# docs/configuration.md "Model observation record" owns the schema; this header
# owns the mechanics. bin/fm-model-verify.sh is its only writer.

# Idempotent guard: fm-route-lib.sh and fm-model-verify.sh may both be in one
# process tree.
if [ -n "${FM_AVAIL_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_AVAIL_LIB_SOURCED=1

# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_AVAIL_AVAILABLE=AVAILABLE
FM_AVAIL_UNAVAILABLE=UNAVAILABLE
FM_AVAIL_UNOBSERVABLE=UNOBSERVABLE
FM_AVAIL_OBSERVATION_SCHEMA=fm-model-observation.v1

# The reason code an UNOBSERVABLE result files repair work under. Spelled from
# bin/fm-reasoning-lib.sh's closed enum rather than as a literal, so the two
# cannot drift; that library stays the owner of what the code means.
FM_AVAIL_GAP_REASON_CODE=TOOLING_GAP

# Stable tokens. Tests and callers match these rather than prose. The exclusion
# token is spelled once here and re-exported by bin/fm-route-lib.sh as
# FM_ROUTE_TOKEN_UNOBSERVED, so the refusal a caller greps for is the same
# string whether it came from fm-route.sh or from the spawn chokepoint.
FM_AVAIL_TOKEN_UNOBSERVED=FM_SPAWN_ROUTE_MODEL_UNOBSERVED
FM_AVAIL_TOKEN_SHAPE_UNMAPPED=FM_AVAIL_SHAPE_UNMAPPED
}

# ---------------------------------------------------------------------------
# The total map from a probe shape to an observation
# ---------------------------------------------------------------------------

# fm_availability_from_shape <shape>
# The one place a probe response shape becomes an observation. TOTAL by
# construction: every shape bin/fm-model-registry-lib.sh's classifier can emit
# is named, and anything else reaches UNOBSERVABLE by the default arm rather
# than by omission.
#
# The mapping is the model-onboarding skill's own rule, enforced rather than
# remembered. `client-error` is the case that matters most: the request never
# left the machine, so it is a configuration error HERE and never a provider
# fact, and recording a local typo as a provider outage is precisely the
# mistake that skill forbids. `timeout` joins it because a probe that never
# returned established nothing, and `unclassified` joins it because a reader
# that produced output nobody mapped did not observe - it emitted.
#
# Exit 0 always: an unmapped shape is a real answer (UNOBSERVABLE), not a
# failure to answer. It additionally reports the unmapped shape on stderr so a
# classifier that grows a value nobody wired up is visible rather than quietly
# absorbed.
fm_availability_from_shape() {  # <shape>
  case "${1:-}" in
    ok)
      printf '%s\n' "$FM_AVAIL_AVAILABLE" ;;
    entitlement-refused|unknown-model)
      printf '%s\n' "$FM_AVAIL_UNAVAILABLE" ;;
    unprobeable|client-error|timeout)
      printf '%s\n' "$FM_AVAIL_UNOBSERVABLE" ;;
    *)
      printf '%s: probe shape %s is not mapped, so it cannot establish availability\n' \
        "$FM_AVAIL_TOKEN_SHAPE_UNMAPPED" "${1:-<empty>}" >&2
      printf '%s\n' "$FM_AVAIL_UNOBSERVABLE" ;;
  esac
}

# fm_availability_hold_state <shape>
# The closed-vocabulary availability state an UNAVAILABLE observation records,
# for bin/fm-route-lib.sh's supported writer. Only the two shapes that
# positively establish unavailability have one; every other shape returns 1 with
# no output, because a hold state for a could-not-observe is a fact nobody
# measured.
#
# Neither state carries an expiry. A server-side entitlement refusal and an
# unrecognised model identity are both durable account facts that no amount of
# waiting clears, so an expiring hold would silently re-admit a model the
# provider will refuse again.
fm_availability_hold_state() {  # <shape>
  case "${1:-}" in
    entitlement-refused) printf 'auth_failure\n' ;;
    unknown-model)       printf 'model_unavailable\n' ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# The bijection onto bin/fm-verify-lib.sh's observation type
# ---------------------------------------------------------------------------

# Total both ways, so the availability names are a RENDERING of the fleet's one
# three-valued type rather than a second type that resembles it. An unrecognised
# input returns 1 rather than picking a value: guessing here would reintroduce
# the collapse at the seam built to prevent it.
fm_availability_to_verify_result() {  # <AVAILABLE|UNAVAILABLE|UNOBSERVABLE>
  case "${1:-}" in
    "$FM_AVAIL_AVAILABLE")    printf 'PASS\n' ;;
    "$FM_AVAIL_UNAVAILABLE")  printf 'FAIL\n' ;;
    "$FM_AVAIL_UNOBSERVABLE") printf 'NO_VERIFIER_RAN\n' ;;
    *) return 1 ;;
  esac
}

fm_availability_from_verify_result() {  # <PASS|FAIL|NO_VERIFIER_RAN>
  case "${1:-}" in
    PASS)            printf '%s\n' "$FM_AVAIL_AVAILABLE" ;;
    FAIL)            printf '%s\n' "$FM_AVAIL_UNAVAILABLE" ;;
    NO_VERIFIER_RAN) printf '%s\n' "$FM_AVAIL_UNOBSERVABLE" ;;
    *) return 1 ;;
  esac
}

# fm_availability_case <observation> <reader> <detail> <on_available>
#                      <on_unavailable> <on_unobservable>
# The only supported way to branch on an availability observation. It builds the
# bin/fm-verify.sh record for this observation and hands it to fm_verify_case,
# so a consumer that tries to branch two ways, or to route could-not-observe
# into the same handler as one of the other two, is refused by the library that
# already owns that rule.
#
# Requires bin/fm-verify-lib.sh to be sourced by the caller; it returns 3, the
# same status fm_verify_case uses for a consumer error, when it is not.
fm_availability_case() {
  local observation=${1:-} reader=${2:-} detail=${3:-} result record
  if [ "$#" -ne 6 ]; then
    printf 'fm-availability: consumer must handle all three observations\n' >&2
    return 3
  fi
  if ! declare -F fm_verify_case >/dev/null 2>&1; then
    printf 'fm-availability: bin/fm-verify-lib.sh must be sourced to read an observation\n' >&2
    return 3
  fi
  result=$(fm_availability_to_verify_result "$observation") || {
    printf 'fm-availability: %s is not an availability observation\n' "$observation" >&2
    return 3
  }
  # The record format is bin/fm-verify.sh's: two leading spaces, then
  # verifier,result,reason,evidence. Commas in the free-text detail would split
  # the reason field, and a reason that arrives truncated is the empty-reason
  # defect wearing a different hat, so they become semicolons here.
  record="  ${reader:-model-probe},${result},$(printf '%s' "${detail:-no detail recorded}" | tr ',\n' '; '),${reader}"
  fm_verify_case "$record" "$4" "$5" "$6"
}

# ---------------------------------------------------------------------------
# The observation record
# ---------------------------------------------------------------------------

fm_availability_record_path() {  # [<state-dir>]
  local st=${1:-}
  [ -n "$st" ] || st="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}"
  printf '%s\n' "$st/model-observation.json"
}

# fm_availability_record_write <state-dir> <model> <observation> <shape>
#                              <reader> <detail> <latency-or-empty> <at-iso>
#                              [<gap-json>]
# Record ONE model's latest observation, atomically and privately. <gap-json> is
# the TOOLING_GAP evidence block and belongs to an UNOBSERVABLE observation
# only; it is refused on the other two, because a repair item filed against an
# observation that succeeded is work nobody can close.
#
# This is the only writer. It never touches state/model-health.json: holds are
# bin/fm-route-lib.sh's, and one record with two writers is how the schemas
# crossed in the first place.
fm_availability_record_write() {
  local state=$1 model=$2 observation=$3 shape=$4 reader=$5 detail=$6 latency=$7 at=$8 gap=${9:-}
  local file tmp latency_json
  file=$(fm_availability_record_path "$state")
  command -v jq >/dev/null 2>&1 || { echo "jq is required to record a model observation" >&2; return 1; }
  if ! fm_availability_to_verify_result "$observation" >/dev/null; then
    echo "fm-availability: $observation is not an availability observation" >&2
    return 1
  fi
  if [ -n "$gap" ] && [ "$observation" != "$FM_AVAIL_UNOBSERVABLE" ]; then
    echo "fm-availability: a tooling-gap block belongs to an UNOBSERVABLE observation only, not to $observation" >&2
    return 1
  fi
  if [ -z "$gap" ] && [ "$observation" = "$FM_AVAIL_UNOBSERVABLE" ]; then
    echo "fm-availability: an UNOBSERVABLE observation must carry a tooling-gap block naming what to repair" >&2
    return 1
  fi
  [ -n "$detail" ] || detail="no detail recorded"
  latency_json=null
  case "$latency" in
    ''|*[!0-9]*) ;;
    *) latency_json=$latency ;;
  esac
  mkdir -p "$(dirname "$file")" || return 1
  local current
  if [ -f "$file" ]; then
    current=$(jq -c . "$file" 2>/dev/null) || {
      echo "existing observation record is malformed: $file" >&2
      return 1
    }
  else
    current="{\"schema\":\"$FM_AVAIL_OBSERVATION_SCHEMA\",\"models\":{}}"
  fi
  tmp=$(mktemp "$file.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s' "$current" | jq \
      --arg schema "$FM_AVAIL_OBSERVATION_SCHEMA" --arg m "$model" \
      --arg obs "$observation" --arg shape "$shape" --arg reader "$reader" \
      --arg detail "$detail" --arg at "$at" \
      --argjson latency "$latency_json" \
      --argjson gap "$(if [ -n "$gap" ]; then printf '%s' "$gap"; else printf 'null'; fi)" '
      .schema = $schema
      | .models = (.models // {})
      | .models[$m] = ({observation:$obs, shape:$shape, reader:$reader,
                        detail:$detail, latency_s:$latency, at:$at}
                       + (if $gap == null then {} else {tooling_gap:$gap} end))
      | .updated_at = $at
    ' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "could not update the observation record" >&2
    return 1
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  return 0
}

# fm_availability_gap_block <reader> <model> <requested> <failure-class>
#                           <evidence> <at-iso> <affected-routes-csv>
#                           [<backlog-item>]
# The machine-readable TOOLING_GAP evidence an UNOBSERVABLE result files, as one
# JSON object. Every field the repair needs is named here rather than left to a
# reader of prose: WHICH reader failed, on WHICH candidate, answering WHICH
# question, HOW it failed, with WHAT evidence, WHEN, and WHICH routing decisions
# the failure is currently blocking.
#
# There is no separate issue store. The record is evidence; the repair work is
# an ordinary backlog item, which bin/fm-reasoning-lib.sh already requires a
# TOOLING_GAP dispatch to name and to find open.
fm_availability_gap_block() {
  local reader=$1 model=$2 requested=$3 class=$4 evidence=$5 at=$6 routes=${7:-} item=${8:-}
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$evidence" ] || evidence="the reader reported no evidence, which is itself the defect to repair"
  jq -n --arg reader "$reader" --arg model "$model" --arg requested "$requested" \
        --arg class "$class" --arg evidence "$evidence" --arg at "$at" \
        --arg routes "$routes" --arg item "$item" \
        --arg code "$FM_AVAIL_GAP_REASON_CODE" '
    {reason_code:$code, reader:$reader, candidate:$model,
     requested_observation:$requested, failure_class:$class,
     failure_evidence:$evidence, at:$at,
     affected_routes: ($routes | split(",") | map(select(length > 0))),
     backlog_item: (if ($item | length) > 0 then $item else null end)}'
}

# fm_availability_unobserved_active [<state-dir>]
# Every model whose LAST attempted observation could not observe, as
# {"models":{"<model>":{...}}}, for the routing decision to exclude on.
#
# An absent record is an empty one: no attempted observation has failed, which
# is never a claim that anything is healthy. A record that exists and cannot be
# parsed returns 1 - refusing beats silently re-admitting every candidate whose
# exclusion the unreadable file was carrying.
#
# This function is the seam routing reads the exclusion through. Nothing else in
# the decision path consults the observation record, so a change to what
# excludes is a change here.
fm_availability_unobserved_active() {  # [<state-dir>]
  local file
  file=$(fm_availability_record_path "${1:-}")
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{"models":{}}\n'
    return 0
  fi
  jq -c --arg u "$FM_AVAIL_UNOBSERVABLE" '
    {models: ((.models // {}) | with_entries(select(.value.observation == $u)))}
  ' "$file" 2>/dev/null || return 1
}

# fm_availability_unobserved_refusal <model> <entry-json> [<state-dir>]
# The one wording for "routing cannot consider this candidate because the reader
# that would answer for it failed". It names the reader, the failure class, the
# evidence, and the record to repair, because a refusal an operator cannot trace
# to a broken reader is the refusal that cost a coordinator an hour by hand.
fm_availability_unobserved_refusal() {  # <model> <entry-json> [<state-dir>]
  local model=$1 entry=$2 state=${3:-}
  printf '%s' "$entry" | jq -r --arg m "$model" --arg token "$FM_AVAIL_TOKEN_UNOBSERVED" \
    --arg file "$(fm_availability_record_path "$state")" '
    $token + ": " + $m + " has no availability observation: its last probe could not observe ("
    + (.tooling_gap.failure_class // .shape // "unclassified") + ") through "
    + (.reader // "an unnamed reader") + " at " + (.at // "an unrecorded time") + " - "
    + (.tooling_gap.failure_evidence // .detail // "no evidence was recorded")
    + ". This is a broken reader, not a provider fact, so it is neither available nor unavailable and must not be treated as either. Repair the reader named in "
    + $file + " (" + (.tooling_gap.reason_code // "TOOLING_GAP")
    + (if (.tooling_gap.backlog_item // null) != null
       then ", tracked as " + .tooling_gap.backlog_item else ", not yet filed as backlog work" end)
    + "); do not release a hold to work around it, because no hold is what is excluding this candidate"' \
    2>/dev/null
}
