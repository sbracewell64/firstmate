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
# owns the mechanics. Every write goes through this library, and exactly two
# callers are allowed to make one: bin/fm-model-verify.sh records what a probe
# observed, and bin/fm-route.sh's supported release retires an UNAVAILABLE entry
# the operator has explicitly overridden. Nothing else writes the file, and
# neither caller authors its schema.

# Idempotent guard: fm-route-lib.sh and fm-model-verify.sh may both be in one
# process tree.
if [ -n "${FM_AVAIL_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_AVAIL_LIB_SOURCED=1

# bin/fm-reasoning-lib.sh owns the closed reason-code enum, including the one
# code that is deliberately NOT a reasoning code. Sourced rather than copied so
# the gap block's reason_code IS that owner's value: a literal here would let
# the two drift silently, and the drift would only surface as a dispatch whose
# tooling gap no certification check recognised.
if [ -z "${FM_REASON_CODE_TOOLING_GAP:-}" ]; then
  # shellcheck source=bin/fm-reasoning-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-reasoning-lib.sh"
fi
if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
fi

# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_AVAIL_AVAILABLE=AVAILABLE
FM_AVAIL_UNAVAILABLE=UNAVAILABLE
FM_AVAIL_UNOBSERVABLE=UNOBSERVABLE
FM_AVAIL_OBSERVATION_SCHEMA=fm-model-observation.v1

# The reason code an UNOBSERVABLE result files repair work under, taken from its
# owner above rather than spelled again here.
FM_AVAIL_GAP_REASON_CODE=$FM_REASON_CODE_TOOLING_GAP

# The longest evidence string this library will store or print, and the marker
# that says a longer one was cut. A probe's output is attacker-adjacent text
# from a provider or a vendor CLI, and an unbounded one lands in an operator's
# terminal and in a record other tools read.
FM_AVAIL_EVIDENCE_MAX=600
FM_AVAIL_EVIDENCE_TRUNCATED=' [truncated]'
FM_AVAIL_REDACTED='[redacted]'

# Stable tokens. Tests and callers match these rather than prose. The exclusion
# token is spelled once here and re-exported by bin/fm-route-lib.sh as
# FM_ROUTE_TOKEN_UNOBSERVED, so the refusal a caller greps for is the same
# string whether it came from fm-route.sh or from the spawn chokepoint.
FM_AVAIL_TOKEN_UNOBSERVED=FM_SPAWN_ROUTE_MODEL_UNOBSERVED
FM_AVAIL_TOKEN_UNAVAILABLE=FM_SPAWN_ROUTE_MODEL_UNAVAILABLE_UNHELD
FM_AVAIL_TOKEN_SHAPE_UNMAPPED=FM_AVAIL_SHAPE_UNMAPPED
}

# ---------------------------------------------------------------------------
# Evidence hygiene
# ---------------------------------------------------------------------------

# fm_availability_sanitize <text>
# Probe evidence, made safe to STORE and to PRINT. Everything this library
# records or renders about a failure comes from a provider's response or a
# vendor CLI's stderr, which is text this fleet neither wrote nor controls, and
# it reaches two places that both matter: an operator's terminal and a durable
# record other tools read back.
#
# Three hazards, each closed here rather than at each call site:
#
#   TERMINAL CONTROL. An ANSI escape can move the cursor, recolour, or overwrite
#   the lines around it, so a refusal could be made to render as something other
#   than what it says. C0 controls and DEL are removed outright; tab, newline and
#   carriage return become spaces so the wire format's field boundaries survive.
#   ESC is inside the removed range, which is what actually disarms the escape.
#   CREDENTIALS. A client-side failure frequently echoes the request that caused
#   it, and this fleet's probe carries provider credentials. Known key shapes and
#   the generic `<secret-ish name> = <value>` form are replaced by a marker, so a
#   leak needs a NEW secret format rather than merely an unlucky error message.
#   UNBOUNDED LENGTH. A CLI that dumps a stack trace or a whole HTML error page
#   would otherwise be stored in full and printed in full.
#
# Idempotent: sanitizing sanitized text returns it unchanged, so a value that
# passes through more than one layer is not marked twice.
fm_availability_sanitize() {  # <text>
  local text=${1:-} keep
  # Field-safe first, then control-free: tab/newline/CR would otherwise be
  # deleted outright and run two words together.
  text=$(printf '%s' "$text" | tr '\t\n\r' '   ' | tr -d '\000-\010\013\014\016-\037\177')
  text=$(printf '%s' "$text" | LC_ALL=C sed -E \
    -e "s/(sk|rk|pk)-[A-Za-z0-9_-]{12,}/$FM_AVAIL_REDACTED/g" \
    -e "s/gh[pousr]_[A-Za-z0-9]{16,}/$FM_AVAIL_REDACTED/g" \
    -e "s/github_pat_[A-Za-z0-9_]{16,}/$FM_AVAIL_REDACTED/g" \
    -e "s/xox[abprs]-[A-Za-z0-9-]{10,}/$FM_AVAIL_REDACTED/g" \
    -e "s/AKIA[0-9A-Z]{16}/$FM_AVAIL_REDACTED/g" \
    -e "s/AIza[0-9A-Za-z_-]{20,}/$FM_AVAIL_REDACTED/g" \
    -e "s/eyJ[A-Za-z0-9._-]{20,}/$FM_AVAIL_REDACTED/g" \
    -e "s/([Bb]earer)[[:space:]]+[A-Za-z0-9._~+\/-]{16,}=*/\1 $FM_AVAIL_REDACTED/g" \
    -e "s/([Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd])([\"']?[[:space:]]*[:=][[:space:]]*[\"']?)[^[:space:],;\"']{8,}/\1\2$FM_AVAIL_REDACTED/g")
  # Bound to exactly FM_AVAIL_EVIDENCE_MAX including the marker, so a second
  # pass sees a string that is no longer over the limit and leaves it alone.
  if [ "${#text}" -gt "$FM_AVAIL_EVIDENCE_MAX" ]; then
    keep=$((FM_AVAIL_EVIDENCE_MAX - ${#FM_AVAIL_EVIDENCE_TRUNCATED}))
    text="${text:0:$keep}$FM_AVAIL_EVIDENCE_TRUNCATED"
  fi
  printf '%s\n' "$text"
}

fm_availability_has_substance() {  # <text>
  printf '%s' "${1:-}" | LC_ALL=C grep -q '[^[:space:]]'
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

fm_availability_record_lock_path() {  # [<state-dir>]
  printf '%s.lock\n' "$(fm_availability_record_path "${1:-}")"
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
fm_availability_record_write_locked() {
  local state=$1 model=$2 observation=$3 shape=$4 reader=$5 detail=$6 latency=$7 at=$8 gap=${9:-}
  local file tmp latency_json models
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
  # Sanitized HERE as well as at the caller, because this is the boundary the
  # record's own read-time contract is enforced against: a field that reached
  # the file with a control character in it would make the whole record refuse
  # on the next read, taking every unrelated exclusion down with it.
  detail=$(fm_availability_sanitize "$detail")
  shape=$(fm_availability_sanitize "$shape")
  reader=$(fm_availability_sanitize "$reader")
  at=$(fm_availability_sanitize "$at")
  fm_availability_has_substance "$detail" || detail="no detail recorded"
  latency_json=null
  case "$latency" in
    ''|*[!0-9]*) ;;
    *) latency_json=$latency ;;
  esac
  mkdir -p "$(dirname "$file")" || return 1
  local current
  if [ -f "$file" ]; then
    models=$(fm_availability_record_models "$state") || {
      echo "existing observation record is malformed: $file" >&2
      return 1
    }
    current=$(jq -cn --arg schema "$FM_AVAIL_OBSERVATION_SCHEMA" \
      --argjson models "$models" '{schema:$schema, models:$models}') || return 1
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

fm_availability_record_write() {
  local state=$1 lock rc
  lock=$(fm_availability_record_lock_path "$state")
  mkdir -p "$(dirname "$lock")" || return 1
  fm_lock_acquire_wait "$lock" || return 1
  fm_availability_record_write_locked "$@"
  rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# fm_availability_gap_block <reader> <model> <requested> <failure-class>
#                           <evidence> <at-iso> <affected-routes-csv>
#                           [<backlog-item>] [<backlog-item-status>]
# The machine-readable TOOLING_GAP evidence an UNOBSERVABLE result files, as one
# JSON object. Every field the repair needs is named here rather than left to a
# reader of prose: WHICH reader failed, on WHICH candidate, answering WHICH
# question, HOW it failed, with WHAT evidence, WHEN, WHICH routing decisions the
# failure is currently blocking, and WHICH backlog item repairs it.
#
# There is no separate issue store. The record is evidence; the repair work is
# an ordinary backlog item, which bin/fm-reasoning-lib.sh already requires a
# TOOLING_GAP dispatch to name and to find open.
#
# THE ITEM IS NOT OPTIONAL, ONLY SOMETIMES UNOBTAINABLE. `backlog_item: null`
# used to be the only value this ever produced, which closed broken reader ->
# evidence and left evidence -> repair work to whoever happened to read the
# record. A null now always travels with a status saying WHY there is no item,
# so an unfiled repair is an explicitly incomplete record rather than a silent
# one. bin/fm-model-verify.sh files the item through this home's ordinary
# backlog backend before it calls this.
fm_availability_gap_block() {
  local reader=$1 model=$2 requested=$3 class=$4 evidence=$5 at=$6 routes=${7:-} item=${8:-} status=${9:-}
  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$evidence" ] || evidence="the reader reported no evidence, which is itself the defect to repair"
  evidence=$(fm_availability_sanitize "$evidence")
  class=$(fm_availability_sanitize "$class")
  reader=$(fm_availability_sanitize "$reader")
  fm_availability_has_substance "$evidence" \
    || evidence="the reader reported no evidence, which is itself the defect to repair"
  if [ -n "$item" ]; then
    status=filed
  else
    [ -n "$status" ] || status=unfiled-reason-unrecorded
  fi
  jq -n --arg reader "$reader" --arg model "$model" --arg requested "$requested" \
        --arg class "$class" --arg evidence "$evidence" --arg at "$at" \
        --arg routes "$routes" --arg item "$item" --arg status "$status" \
        --arg code "$FM_AVAIL_GAP_REASON_CODE" '
    {reason_code:$code, reader:$reader, candidate:$model,
     requested_observation:$requested, failure_class:$class,
     failure_evidence:$evidence, at:$at,
     affected_routes: ($routes | split(",") | map(select(length > 0))),
     backlog_item: (if ($item | length) > 0 then $item else null end),
     backlog_item_status: $status}'
}

# fm_availability_record_retire <state-dir> <observation> <model-or-provider-prefix>
# Remove the entries an explicit operator decision has overridden, and print the
# models actually removed. Only entries carrying <observation> are touched.
#
# THIS EXISTS SO RELEASE STILL MEANS SOMETHING. Routing enforces an UNAVAILABLE
# observation independently of its hold, so releasing the hold alone would leave
# the candidate excluded by a record the operator was never told about, and the
# supported release command would silently stop working. Retiring the entry is
# what keeps an explicit override an override.
#
# UNOBSERVABLE entries are deliberately NOT retirable this way. A broken reader
# is not repaired by releasing anything, the refusal says so in those words, and
# letting a release clear it would turn "repair observability" back into "work
# around uncertainty" - the exact substitution this whole path exists to refuse.
fm_availability_record_retire_locked() {  # <state-dir> <observation> <subject>
  local state=$1 observation=$2 subject=$3 file tmp removed models
  file=$(fm_availability_record_path "$state")
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "jq is required to retire an observation" >&2; return 1; }
  if [ "$observation" != "$FM_AVAIL_UNAVAILABLE" ]; then
    echo "fm-availability: only an $FM_AVAIL_UNAVAILABLE observation may be retired by an operator decision" >&2
    return 1
  fi
  # A model key matches exactly; a provider matches every key in its namespace,
  # which is what a provider-scoped release is asking for.
  models=$(fm_availability_record_models "$state") || return 1
  removed=$(printf '%s' "$models" | jq -r --arg s "$subject" --arg o "$observation" '
    to_entries
    | map(select(.value.observation == $o and (.key == $s or (.key | startswith($s + "/")))))
    | .[].key' 2>/dev/null) || return 1
  [ -n "$removed" ] || return 0
  tmp=$(mktemp "$file.XXXXXX") || return 1
  chmod 600 "$tmp" 2>/dev/null || true
  if ! printf '%s' "$models" | jq --arg schema "$FM_AVAIL_OBSERVATION_SCHEMA" \
      --arg s "$subject" --arg o "$observation" '
      {schema:$schema,
       models:(with_entries(select((.value.observation == $o
          and (.key == $s or (.key | startswith($s + "/")))) | not)))}
    ' > "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "could not retire the observation record entry" >&2
    return 1
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  chmod 600 "$file" 2>/dev/null || true
  printf '%s\n' "$removed"
}

fm_availability_record_retire() {  # <state-dir> <observation> <subject>
  local state=$1 lock rc out
  lock=$(fm_availability_record_lock_path "$state")
  mkdir -p "$(dirname "$lock")" || return 1
  fm_lock_acquire_wait "$lock" || return 1
  out=$(fm_availability_record_retire_locked "$@")
  rc=$?
  fm_lock_release "$lock"
  [ -z "$out" ] || printf '%s\n' "$out"
  return "$rc"
}

# The record's shape, checked on every read, as a jq program returning either
# {ok:true, models:{...}} or {ok:false, reason:"..."}.
#
# WHY A PRESENT FILE IS NOT TRUSTED. This function's entire purpose is to fail
# closed, and the first version of it failed OPEN on one class of input: it
# recovered only from unparseable JSON, so a file that was valid JSON with a
# wrong or absent schema - `{"schema":"wrong","models":{}}`, a truncated write
# that landed as `{}`, or anything else another writer might leave - succeeded
# as an EMPTY exclusion set. Every recorded could-not-observe silently
# disappeared and every candidate they were excluding became eligible again.
# Parseability is not validity, and the difference is the whole defect class.
#
# So the schema string, the entry shape, the closed observation vocabulary and
# the tooling-gap fields are all verified here, and anything short of the full
# contract is a could-not-observe about the record itself.
#
# Control characters are rejected rather than sanitized on read: this library
# writes only sanitized evidence, so a record carrying them was written by
# something else, and that is a reason to refuse rather than to clean up and
# proceed. It also means every consumer can print a stored field directly.
# shellcheck disable=SC2016 # jq variables must reach jq unexpanded.
FM_AVAIL_RECORD_VALID_JQ='
  def bad($why): {ok:false, reason:$why};
  def clean_string: type == "string" and (test("[[:cntrl:]]") | not);
  def nonempty_clean_string: clean_string and test("[^[:space:]]");
  def obs_values: [$available, $unavailable, $unobservable];
  def entry_bad($k; $e):
    if ($e | type) != "object" then "model \($k) is not an object"
    elif (($e.observation // null) | IN(obs_values[]) | not)
      then "model \($k) records observation \($e.observation // "nothing"), which is not one of \(obs_values | join(", "))"
    elif ([$e.shape, $e.reader, $e.detail, $e.at] | map(nonempty_clean_string) | all | not)
      then "model \($k) is missing a shape, reader, detail or at field, or one carries control characters"
    elif (($e.latency_s // null) != null and ($e.latency_s | type) != "number")
      then "model \($k) records a non-numeric latency"
    elif ($e.observation == $unobservable and (($e.tooling_gap // null) | type) != "object")
      then "model \($k) is UNOBSERVABLE but carries no tooling-gap block, so nothing names the reader to repair"
    elif ($e.observation != $unobservable and (($e.tooling_gap // null) != null))
      then "model \($k) carries a tooling-gap block on an observation that succeeded"
    elif ($e.observation == $unobservable and (($e.tooling_gap.reason_code // "") != $gap_code))
      then "model \($k) files its tooling gap under \($e.tooling_gap.reason_code // "no reason code") rather than \($gap_code)"
    elif ($e.observation == $unobservable and ([$e.tooling_gap.reader, $e.tooling_gap.candidate,
            $e.tooling_gap.requested_observation, $e.tooling_gap.failure_class,
            $e.tooling_gap.failure_evidence, $e.tooling_gap.at]
          | map(nonempty_clean_string) | all | not))
      then "model \($k) has an incomplete tooling-gap block, so the failure it records cannot be repaired from it"
    elif ($e.observation == $unobservable and $e.tooling_gap.candidate != $k)
      then "model \($k) carries tooling-gap evidence for \($e.tooling_gap.candidate)"
    elif ($e.observation == $unobservable and (($e.tooling_gap.affected_routes | type) != "array"
            or ($e.tooling_gap.affected_routes | map(nonempty_clean_string) | all | not)))
      then "model \($k) does not name the routes its failed reader is blocking as a list of strings"
    elif ($e.observation == $unobservable and (($e.tooling_gap.backlog_item // null) != null
            and ($e.tooling_gap.backlog_item | nonempty_clean_string | not)))
      then "model \($k) records a backlog item that is not a plain string"
    elif ($e.observation == $unobservable and (($e.tooling_gap.backlog_item // null) != null
            and $e.tooling_gap.backlog_item_status != "filed"))
      then "model \($k) records a backlog item without filed status"
    elif ($e.observation == $unobservable and (($e.tooling_gap.backlog_item // null) == null
            and ($e.tooling_gap.backlog_item_status | nonempty_clean_string | not)))
      then "model \($k) has no backlog item and does not say why repair work is unfiled"
    else null end;
  if type != "object" then bad("the record is not a JSON object")
  elif (.schema // "") != $schema
    then bad("the record declares schema \(.schema // "none") rather than \($schema)")
  elif ((.models // null) | type) != "object"
    then bad("the record has no models object")
  else
    ([.models | to_entries[] | entry_bad(.key; .value)] | map(select(. != null))) as $errs
    | if ($errs | length) > 0 then bad($errs[0]) else {ok:true, models:.models} end
  end'

# fm_availability_record_models [<state-dir>]
# The record's validated model map on stdout, with the reason for any refusal on
# stderr. Return 0 for a valid record, 0 with an empty map for an ABSENT one,
# and 1 for a record that exists and could not be established.
#
# Absent and invalid are deliberately different answers. Absence means no
# attempted observation has failed, which is never a claim that anything is
# healthy; invalidity means the file that carries the exclusions could not be
# read, so nobody knows which candidates are excluded.
fm_availability_record_models() {  # [<state-dir>]
  local file out
  file=$(fm_availability_record_path "${1:-}")
  [ -f "$file" ] || { printf '{}\n'; return 0; }
  if ! command -v jq >/dev/null 2>&1; then
    # A present record this process cannot read is a could-not-observe, not an
    # empty one. Returning {} here was the same fail-open one layer down.
    printf 'fm-availability: jq is required to read %s\n' "$file" >&2
    return 1
  fi
  out=$(jq -c --arg schema "$FM_AVAIL_OBSERVATION_SCHEMA" \
           --arg available "$FM_AVAIL_AVAILABLE" \
           --arg unavailable "$FM_AVAIL_UNAVAILABLE" \
           --arg unobservable "$FM_AVAIL_UNOBSERVABLE" \
           --arg gap_code "$FM_AVAIL_GAP_REASON_CODE" \
           "$FM_AVAIL_RECORD_VALID_JQ" "$file" 2>/dev/null) || {
    printf 'fm-availability: %s is not parseable JSON\n' "$file" >&2
    return 1
  }
  if [ "$(printf '%s' "$out" | jq -r '.ok')" != true ]; then
    printf 'fm-availability: %s\n' "$(printf '%s' "$out" | jq -r '.reason')" >&2
    return 1
  fi
  printf '%s' "$out" | jq -c '.models'
}

# fm_availability_observed <observation> [<state-dir>]
# Every model whose last attempted observation recorded exactly <observation>,
# as {"models":{"<model>":{...}}}. Return 1 when the record could not be
# established, so a caller that cannot tell which candidates are excluded
# refuses instead of proceeding on an empty set.
fm_availability_observed() {  # <observation> [<state-dir>]
  local want=$1 models
  models=$(fm_availability_record_models "${2:-}") || return 1
  printf '%s' "$models" | jq -c --arg w "$want" \
    '{models: with_entries(select(.value.observation == $w))}' 2>/dev/null || return 1
}

# fm_availability_unobserved_active [<state-dir>]
# Every model whose LAST attempted observation could not observe, for the
# routing decision to exclude on.
#
# This function is one of the two seams routing reads exclusions through.
# Nothing else in the decision path consults the observation record, so a change
# to what excludes is a change here or in its sibling below.
fm_availability_unobserved_active() {  # [<state-dir>]
  fm_availability_observed "$FM_AVAIL_UNOBSERVABLE" "${1:-}"
}

# fm_availability_unavailable_active [<state-dir>]
# Every model a probe positively established as unavailable.
#
# WHY ROUTING READS THIS AT ALL, when an established unavailability also records
# a hold. Because the two records are written by two calls, and a safety
# invariant that depends on both succeeding is not an invariant. If the hold
# write fails, races another writer, or is lost, a durable observed-unavailable
# would otherwise sit in this record while routing treated the candidate as
# eligible - a positively measured negative fact, silently not enforced.
#
# In the ordinary case the hold exists and is what the refusal names, because a
# hold carries an expiry and a release command and is the more actionable of the
# two. This axis is what makes the observation enforce itself when the hold is
# NOT there, and bin/fm-route.sh's supported release retires the entry so an
# explicit operator override still restores the candidate.
fm_availability_unavailable_active() {  # [<state-dir>]
  fm_availability_observed "$FM_AVAIL_UNAVAILABLE" "${1:-}"
}

# fm_availability_unobserved_refusal <model> <entry-json> [<state-dir>] [<held-json>]
# The one wording for "routing cannot consider this candidate because the reader
# that would answer for it failed". It names the reader, the failure class, the
# evidence, and the record to repair, because a refusal an operator cannot trace
# to a broken reader is the refusal that cost a coordinator an hour by hand.
#
# THE HOLD ARGUMENT IS NOT DECORATION. The two exclusions are independent and
# can coexist - a provider outage recorded as a hold, then a later reader
# failure - and this refusal used to say unconditionally that no hold was
# excluding the candidate. When one was, that sentence was simply false, and it
# sent the operator away from a genuine hold that would still be there after the
# reader was fixed. So the closing clause is now decided by whether a hold was
# passed: with none, releasing really would not help and the refusal says so;
# with one, both repairs are named and neither is presented as sufficient.
fm_availability_unobserved_refusal() {  # <model> <entry-json> [<state-dir>] [<held-json>]
  local model=$1 entry=$2 state=${3:-} held=${4:-}
  [ -n "$held" ] || held=null
  printf '%s' "$entry" | jq -r --arg m "$model" --arg token "$FM_AVAIL_TOKEN_UNOBSERVED" \
    --argjson held "$held" \
    --arg file "$(fm_availability_record_path "$state")" '
    $token + ": " + $m + " has no availability observation: its last probe could not observe ("
    + (.tooling_gap.failure_class // .shape // "unclassified") + ") through "
    + (.reader // "an unnamed reader") + " at " + (.at // "an unrecorded time") + " - "
    + (.tooling_gap.failure_evidence // .detail // "no evidence was recorded")
    + ". This is a broken reader, not a provider fact, so it is neither available nor unavailable and must not be treated as either. Repair the reader named in "
    + $file + " (" + (.tooling_gap.reason_code // "TOOLING_GAP")
    + (if (.tooling_gap.backlog_item // null) != null
       then ", tracked as " + .tooling_gap.backlog_item
       else ", not yet filed as backlog work ("
            + (.tooling_gap.backlog_item_status // "reason unrecorded") + ")" end)
    + ")"
    + (if $held == null
       then "; do not release a hold to work around it, because no hold is what is excluding this candidate"
       else "; this candidate is ALSO held " + ($held.state // "under an unrecorded state")
            + " on the " + ($held.scope // "model") + " " + ($held.subject // $m)
            + ", which is a separate exclusion with a separate repair - releasing that hold will not restore this candidate while the reader is broken, and repairing the reader will not clear the hold"
       end)' 2>/dev/null
}

# fm_availability_unavailable_refusal <model> <entry-json> [<state-dir>]
# The wording for the state that should not exist: a probe positively
# established this candidate as unavailable, and no hold records it.
#
# It is reported as a record inconsistency rather than as an ordinary hold,
# because that is what it is. Either the hold write failed at the time the
# observation was recorded, or something removed the hold without retiring the
# observation. Both are repairable, and neither is a reason to route to a
# candidate a probe positively refused.
fm_availability_unavailable_refusal() {  # <model> <entry-json> [<state-dir>]
  local model=$1 entry=$2 state=${3:-}
  printf '%s' "$entry" | jq -r --arg m "$model" --arg token "$FM_AVAIL_TOKEN_UNAVAILABLE" \
    --arg file "$(fm_availability_record_path "$state")" '
    $token + ": " + $m + " was positively established as unavailable by " + (.reader // "an unnamed reader")
    + " at " + (.at // "an unrecorded time") + " (" + (.shape // "unclassified") + ") - "
    + (.detail // "no evidence was recorded")
    + ", and no availability hold records that fact. The probe observed a real provider refusal, so the candidate stays excluded; what is broken is the pairing, because the hold that should accompany this observation in "
    + $file + " is missing. Re-run bin/fm-model-verify.sh --model " + $m
    + " to re-establish both records, or clear the observation deliberately with bin/fm-route.sh availability release "
    + $m + "; do not dispatch to it on the strength of the missing hold"' 2>/dev/null
}
