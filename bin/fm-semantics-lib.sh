#!/usr/bin/env bash
# fm-semantics-lib.sh - the four deterministic validators of firstmate's state
# and seam semantics, plus the loading rules they share.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-semantics-lib.sh
#   . "$SCRIPT_DIR/fm-semantics-lib.sh"
#
# WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
#
# It is a pure function over two inputs: the tracked semantic owner documents
# under semantics/, and one caller-supplied record. It opens no socket, reads no
# fleet state, holds no lock, spawns no subprocess beyond jq, and writes nothing.
# A restarted fleet computes the identical answer from the identical inputs,
# which is the property that makes restart a non-event rather than a
# reconstruction.
#
# It is NOT a runtime, a scheduler, a watcher, a queue, an event bus or a second
# decision surface. bin/fm-decision-surface.sh answers what a task is doing.
# This file answers whether a state, a transition, an effect phase or an
# identity mapping is LEGAL under the declared semantics, and nothing else.
#
# THE THREE-VALUED TYPE, IN ITS SECOND SPELLING
#
#   PASS    the checked dimension is legal
#   REFUSE  the checked dimension is ILLEGAL - a positive observed-bad claim
#   CNO     the fact may not be asserted at all
#
# CNO is never a pass and it is never a refusal-with-a-reason-you-can-fix. It
# means the input did not permit the question to be answered. bin/fm-verify-lib.sh
# owns the same three values for an OBSERVATION under the spellings PASS, FAIL
# and NO_VERIFIER_RAN; semantics/state-families.json declares both vocabularies
# with a total mapping in each direction, so a consumer converts by lookup rather
# than by inventing a conversion. The spellings differ because the subjects
# differ: one grades a SUBJECT, the other grades a STATE.
#
# Exit codes are 0 PASS, 2 usage, 3 REFUSE, 4 CNO - deliberately the shape
# bin/fm-decision-surface.sh already uses, so a caller that already handles a
# contradicted-or-unevaluable answer needs no second convention. A two-valued
# 0/nonzero read is not supported: the measured root cause of ten separate
# defects in this fleet was one exit status covering both a failure and a refusal.
#
# EVERY VERDICT IS SCOPED TO WHAT IT EXAMINED
#
# Every result line carries dimensions=, naming exactly the dimensions the call
# actually evaluated. A PASS on those dimensions is not a PASS on any other, and
# a caller that needs a dimension this call did not name has to ask for it. That
# is Gate Dominance made visible rather than remembered: a passing gate never
# implies a gate it did not run.
#
# ORDERING, AND WHY IT IS NOT ALPHABETICAL
#
# Within one validator, conditions are evaluated so that the MOST SPECIFIC true
# reason wins, because a refusal that names the wrong repair sends an operator to
# the wrong file. Two consequences are worth stating because they look like
# exceptions:
#
#   - A stale-resurrection check runs BEFORE the illegal-transition check. Any
#     move out of SUPERSEDED is already illegal, since that family declares no
#     successors at all, so the generic reason would always fire first and would
#     always name the weaker repair.
#   - A could-not-observe runs BEFORE a refusal wherever the refusal's own inputs
#     are what could not be observed. Refusals otherwise outrank could-not-observe,
#     but a comparison against a value that was never read is not a refusal - it
#     is a guess wearing one.
#
# WHAT THIS FILE MAY NEVER ACQUIRE
#
# No caching of a verdict, no persistence of a result, no notion of "the current
# state of X". A stored verdict is a verdict that keeps reading correct after the
# thing under it moved, and every validator here exists because of that class.

[ -n "${FM_SEMANTICS_LIB_SOURCED:-}" ] && return 0
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_SEMANTICS_LIB_SOURCED=1

_FM_SEMANTICS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Where the tracked owner documents live. Overridable so a test can point the
# validators at a fixture register without copying the whole repository, and so
# a refusal about a malformed owner can be driven red on purpose.
FM_SEMANTICS_DIR="${FM_SEMANTICS_DIR:-$(cd "$_FM_SEMANTICS_LIB_DIR/.." && pwd)/semantics}"

FM_SEMANTICS_RESULT_SCHEMA='fm-semantics-result.v1'

# The validator verdict vocabulary. Declared here and mapped onto the observation
# vocabulary in semantics/state-families.json; neither file restates the other.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_SEMANTICS_VERDICT_PASS=PASS
FM_SEMANTICS_VERDICT_REFUSE=REFUSE
FM_SEMANTICS_VERDICT_CNO=CNO
}

FM_SEMANTICS_EXIT_PASS=0
FM_SEMANTICS_EXIT_USAGE=2
FM_SEMANTICS_EXIT_REFUSE=3
FM_SEMANTICS_EXIT_CNO=4

# The four validators, named once. A law that declares a validator must name one
# of these, and semantics/schema.json refuses a fifth: the Seam Contract law has
# none on purpose, because a seam state is an observation of a crossing made by
# the seam owner and is not decidable from a declaration.
FM_SEMANTICS_VALIDATORS='validate_state validate_transition validate_effect_commit validate_identity_mapping'

# 0 if <name> is one of the four.
fm_semantics_validator_is_known() {  # <name>
  [ -n "${1:-}" ] || return 1
  case " $FM_SEMANTICS_VALIDATORS " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Path of one owner document. A caller asking for a document this register does
# not declare gets an empty answer and a non-zero status rather than a plausible
# path that does not exist.
fm_semantics_doc() {  # <document-name>
  local name=${1:-}
  case "$name" in
    schema|laws|state-families|reasons|identity|seams|census) ;;
    inheritance-manifest) printf '%s/inheritance-manifest.schema.json\n' "$FM_SEMANTICS_DIR"; return 0 ;;
    *) return 1 ;;
  esac
  printf '%s/%s.json\n' "$FM_SEMANTICS_DIR" "$name"
}

# 0 if every named owner document exists and parses. Loudly names the first one
# that does not, because an unreadable owner is could-not-observe about EVERY
# question that rests on it, and answering any of them anyway would be the
# vacuity this whole register exists to refuse.
fm_semantics_docs_readable() {  # <document-name>...
  local name path
  for name in "$@"; do
    path=$(fm_semantics_doc "$name") || {
      printf 'fm-semantics: no such owner document: %s\n' "$name" >&2
      return 1
    }
    [ -f "$path" ] || {
      printf 'fm-semantics: owner document is absent: %s\n' "$path" >&2
      return 1
    }
    jq -e . "$path" >/dev/null 2>&1 || {
      printf 'fm-semantics: owner document is not readable JSON: %s\n' "$path" >&2
      return 1
    }
  done
  return 0
}

# Resolve a reason code to its namespace by LOOKUP, never by prefix. Four
# observation-integrity codes deliberately carry an SFI_ or EFFECT_ prefix
# because those are the spellings the reviewed architecture ruled, so a consumer
# that read the prefix would attribute them to the wrong namespace and route the
# repair to the wrong owner.
fm_semantics_reason_namespace() {  # <code>
  local code=${1:-} reasons
  [ -n "$code" ] || return 1
  reasons=$(fm_semantics_doc reasons) || return 1
  jq -er --arg c "$code" '
    [ .namespaces[] | . as $n | ($n.codes[] | select(.code == $c) | $n.namespace) ]
    | if length == 1 then .[0] else empty end
  ' "$reasons" 2>/dev/null
}

# Emit one result line and return the matching exit code. This is the ONLY way a
# validator answers, so no caller can be handed a bare exit status with no reason
# and no scope.
fm_semantics_emit() {  # <validator> <verdict> <reason> <dimensions> <detail>
  local validator=$1 verdict=$2 reason=$3 dimensions=$4 detail=$5 namespace='-'
  if [ "$reason" != '-' ]; then
    namespace=$(fm_semantics_reason_namespace "$reason") || namespace='UNDECLARED_REASON'
  fi
  printf '%s validator=%s verdict=%s reason=%s namespace=%s authority=diagnostic dimensions=%s detail=%s\n' \
    "$FM_SEMANTICS_RESULT_SCHEMA" "$validator" "$verdict" "$reason" \
    "$namespace" "$dimensions" "$detail"
  case "$verdict" in
    PASS) return "$FM_SEMANTICS_EXIT_PASS" ;;
    REFUSE) return "$FM_SEMANTICS_EXIT_REFUSE" ;;
    CNO) return "$FM_SEMANTICS_EXIT_CNO" ;;
  esac
  return "$FM_SEMANTICS_EXIT_USAGE"
}

# Run one jq decision table and turn its single tab-separated row into a result
# line. A table that produces no row, more than one row, or an unparseable row is
# a defect in the table rather than a verdict about the caller's record, so it
# answers CNO and says which table.
fm_semantics_decide() {  # <validator> <jq-program> <record-path> <owner-path>... 
  local validator=$1 program=$2 record=$3
  shift 3
  local out rows verdict reason dimensions detail
  out=$(jq -r --slurpfile REC "$record" "$program" "$@" 2>/dev/null) || {
    fm_semantics_emit "$validator" CNO SFI_UNEVIDENCED 'input' \
      "the record or an owner document could not be read as JSON"
    return $?
  }
  rows=$(printf '%s\n' "$out" | grep -c . || true)
  [ "$rows" = 1 ] || {
    fm_semantics_emit "$validator" CNO SFI_UNEVIDENCED 'decision-table' \
      "the decision table produced $rows rows where exactly one is required"
    return $?
  }
  IFS=$'\t' read -r verdict reason dimensions detail <<<"$out"
  [ -n "${verdict:-}" ] && [ -n "${reason:-}" ] && [ -n "${dimensions:-}" ] || {
    fm_semantics_emit "$validator" CNO SFI_UNEVIDENCED 'decision-table' \
      "the decision table produced an incomplete row"
    return $?
  }
  fm_semantics_emit "$validator" "$verdict" "$reason" "$dimensions" "${detail:-}"
}

# --- validate_state -----------------------------------------------------------
#
# Decides whether ONE state record is honestly terminal or honestly nonterminal.
# Pure over durable inputs unless --for-effect is passed, which adds the one
# time-dependent dimension - evidence freshness - and names it in dimensions=,
# so a caller can always tell whether the clock was consulted.
#
# The multiple-actionable cardinality check is evaluated only when the record
# declares successors. When it does not, the dimension is absent from dimensions=
# rather than silently passing: a check that examined nothing must not be
# credited with having looked.
# shellcheck disable=SC2016  # jq program: $REC and friends are jq variables, not shell ones
FM_SEMANTICS_STATE_TABLE='
  ($REC[0]) as $s
  | (input) as $SF
  | ($SF.families | map({key: .name, value: .}) | from_entries) as $fam
  | ($s.family // null) as $f
  | ($s.obligation // null) as $ob
  | ($s.evidence // []) as $ev
  | ($s.successors // null) as $succ
  | (if $succ == null then "family,obligation,successor-bounds,evidence,subject"
     else "family,obligation,successor-bounds,successor-cardinality,evidence,subject" end) as $dimbase
  | (if $forEffect == "1" then $dimbase + ",freshness" else $dimbase end) as $dims
  | if ($f | type) != "string" or ($fam | has($f) | not) then
      ["REFUSE", "SFI_UNKNOWN_FAMILY", $dims,
       "family \($f // "<absent>") is not a declared member of the vocabulary; map it in the owner or fix the producer, never default it"]
    elif $fam[$f].terminal and $ob != null then
      ["REFUSE", "SFI_FALSE_TERMINAL", $dims,
       "terminal family \($f) carries an open continuation obligation; either it is not terminal or the obligation is discharged, and both cannot be true"]
    elif ($fam[$f].terminal | not) and $ob == null then
      ["REFUSE", "SFI_ORPHAN", $dims,
       "nonterminal family \($f) declares no obligation, so nothing names who owns it, what wakes it, or how it is re-observed"]
    elif ($fam[$f].terminal | not)
         and ((($ob.owner // "") == "") or (($ob.wake // "") == "") or (($ob.reobserve // "") == "")) then
      ["REFUSE", "SFI_ORPHAN", $dims,
       "nonterminal family \($f) names owner=\($ob.owner // "<absent>") wake=\($ob.wake // "<absent>") reobserve=\($ob.reobserve // "<absent>"); a nonterminal state whose reobservation has never fired is not patient, it is orphaned"]
    elif $ob != null
         and (($ob.legal_successors // []) - $fam[$f].legal_successors | length) > 0 then
      ["REFUSE", "SFI_UNBOUNDED_SUCCESSORS", $dims,
       "the state names successors \((($ob.legal_successors // []) - $fam[$f].legal_successors) | join(",")) that family \($f) does not declare, so the successor set is not enumerable from the family alone"]
    elif $succ != null and $f == "SUPERSEDED"
         and ([$succ[] | select(.family != "SUPERSEDED")] | length) > 1 then
      ["REFUSE", "SFI_MULTIPLE_ACTIONABLE", $dims,
       "\([$succ[] | select(.family != "SUPERSEDED")] | length) successors of a superseded predecessor are outside SUPERSEDED where at most one may be; this is a count, not a review question"]
    elif ($s.subject | type) != "object" or (($s.subject.digest // "") == "") then
      ["CNO", "IDENT_UNRESOLVABLE", $dims,
       "the subject reference does not resolve to a compilation record, so nothing addressed to it can be checked"]
    elif ($ev | length) == 0 or ([$ev[] | select(.verdict != "NO_VERIFIER_RAN")] | length) == 0 then
      ["CNO", "SFI_UNEVIDENCED", $dims,
       "the state carries \($ev | length) evidence entries and none of them is an observation that happened; a state with no evidence is not clean, it is unevidenced"]
    elif $forEffect == "1"
         and ([$ev[] | select((.freshness_seconds // null) != null)
                     | select(($now | tonumber) - ((.as_of_epoch // 0) | tonumber) > (.freshness_seconds | tonumber))] | length) > 0 then
      ["CNO", "SFI_STALE_FOR_EFFECT", $dims,
       "an effect-proximal caller was offered evidence outside its declared freshness; re-observe now, because a refusal composes forward from an early gate and a permission never does"]
    else
      ["PASS", "-", $dims,
       "family \($f) is honestly \(if $fam[$f].terminal then "terminal" else "nonterminal" end) on every dimension named above"]
    end
  | @tsv
'

fm_semantics_validate_state() {  # <record-path> [--for-effect] [--now <epoch>]
  local record=${1:-} for_effect=0 now
  shift || true
  now=$(date +%s 2>/dev/null || printf '0')
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for-effect) for_effect=1; shift ;;
      --now) now=${2:-0}; shift 2 ;;
      *) return "$FM_SEMANTICS_EXIT_USAGE" ;;
    esac
  done
  [ -n "$record" ] && [ -f "$record" ] || {
    fm_semantics_emit validate_state CNO SFI_UNEVIDENCED 'input' \
      "no state record was supplied at ${record:-<absent>}"
    return $?
  }
  fm_semantics_docs_readable state-families reasons || {
    fm_semantics_emit validate_state CNO SFI_UNEVIDENCED 'owner-documents' \
      "an owner document could not be read, so no dimension could be evaluated"
    return $?
  }
  fm_semantics_decide validate_state "$FM_SEMANTICS_STATE_TABLE" "$record" \
    --arg forEffect "$for_effect" --arg now "$now" \
    --null-input "$(fm_semantics_doc state-families)"
}

# --- validate_transition ------------------------------------------------------
#
# Decides whether ONE move from one family to another is legal, given the
# evidence offered for it. The stale-resurrection arm runs first for the reason
# given in the header: every move out of SUPERSEDED is already illegal, so the
# generic reason would always win and would always name the weaker repair.
# shellcheck disable=SC2016  # jq program: $REC and friends are jq variables, not shell ones
FM_SEMANTICS_TRANSITION_TABLE='
  ($REC[0]) as $c
  | (input) as $SF
  | ($SF.families | map({key: .name, value: .}) | from_entries) as $fam
  | ($c.from // null) as $from
  | ($c.to // null) as $to
  | ($c.evidence // []) as $ev
  | ($c.context // {}) as $ctx
  | "from-family,to-family,legality,evidence-family,revise-obligation,generation,authority" as $dims
  | if ($from | type) != "string" or ($fam | has($from) | not) then
      ["REFUSE", "SFI_UNKNOWN_FAMILY", $dims,
       "source family \($from // "<absent>") is not a declared member of the vocabulary"]
    elif ($to | type) != "string" or ($fam | has($to) | not) then
      ["REFUSE", "SFI_UNKNOWN_FAMILY", $dims,
       "target family \($to // "<absent>") is not a declared member of the vocabulary"]
    elif $from == "SUPERSEDED" and ($fam[$to].terminal | not) then
      ["REFUSE", "TRANS_STALE_RESURRECTION", $dims,
       "a SUPERSEDED subject may not be returned to nonterminal family \($to); create a successor - the predecessor stays where it is, permanently"]
    elif (($fam[$from].legal_successors | index($to)) == null) then
      ["REFUSE", "TRANS_ILLEGAL", $dims,
       "family \($from) declares successors [\($fam[$from].legal_successors | join(","))] and \($to) is not among them"]
    elif ([$ev[] | select((.family // $from) != $from)] | length) > 0 then
      ["REFUSE", "TRANS_CROSS_FAMILY_PROMOTION", $dims,
       "evidence produced in family \([$ev[] | select((.family // $from) != $from) | .family] | join(",")) was offered to advance a subject in \($from); availability does not qualify, openness does not make actionable, a green check does not review, and a passing review does not authorise landing"]
    elif $from == "REVISE" and $to == "ACTIVE"
         and ([$ev[] | select((.addresses // "") != "")] | length) == 0 then
      ["REFUSE", "TRANS_UNADDRESSED_REVISE", $dims,
       "no evidence entry names the finding it addresses, so the REVISE obligation is undischarged; the MAKER must act and no checker verdict discharges it"]
    elif ($ctx.generation_is_material // false)
         and ([$ev[] | select((.generation // ($ctx.generation // null)) != ($ctx.generation // null))] | length) > 0 then
      ["REFUSE", "TRANS_STALE_GENERATION", $dims,
       "evidence carries a generation the contract declares material and the context does not share it; re-observe under the current binding, and the old evidence stays attributed to the worker that produced it"]
    elif ($ctx.requires_authority // false)
         and ((($ctx.authority.state // "") != "granted")
              or (($ctx.authority.subject // "") != ($c.subject.digest // " "))) then
      ["REFUSE", "IDENT_AUTHORITY_BY_NAME", $dims,
       "the target requires an authority and none is granted for this exact subject; a permission is held as a spendable object, never as a property of the thing it authorises"]
    elif ($ev | length) == 0 or ([$ev[] | select(.verdict != "NO_VERIFIER_RAN")] | length) == 0 then
      ["CNO", "TRANS_UNEVIDENCED", $dims,
       "the evidence offered for this transition is unreadable or every entry is an observation that did not happen"]
    else
      ["PASS", "-", $dims,
       "\($from) to \($to) is declared legal and the evidence offered for it was produced in the family that governs it"]
    end
  | @tsv
'

fm_semantics_validate_transition() {  # <record-path>
  local record=${1:-}
  [ -n "$record" ] && [ -f "$record" ] || {
    fm_semantics_emit validate_transition CNO TRANS_UNEVIDENCED 'input' \
      "no transition record was supplied at ${record:-<absent>}"
    return $?
  }
  fm_semantics_docs_readable state-families reasons || {
    fm_semantics_emit validate_transition CNO TRANS_UNEVIDENCED 'owner-documents' \
      "an owner document could not be read, so no dimension could be evaluated"
    return $?
  }
  fm_semantics_decide validate_transition "$FM_SEMANTICS_TRANSITION_TABLE" "$record" \
    --null-input "$(fm_semantics_doc state-families)"
}

# --- validate_effect_commit ---------------------------------------------------
#
# Decides one PHASE of one effect. The phase is an input because the correct
# answer differs at each: what is legal before an act is not legal after it, and
# the gap between them is a named state rather than one of its neighbours.
#
# The pre-effect arm evaluates every refusal whose own inputs are present BEFORE
# reaching the head comparison, then answers could-not-observe if the target head
# was never read. A comparison against a value that was never read is not a
# refusal, and reporting it as one would send an operator to repair agreement
# between three values when only two of them exist.
# shellcheck disable=SC2016  # jq program: $REC and friends are jq variables, not shell ones
FM_SEMANTICS_EFFECT_TABLE='
  ($REC[0]) as $e
  | ($e.authority // {}) as $auth
  | (if $phase == "PRE_EFFECT" then "authority-state,cache,intent,target-head,head-agreement"
     elif $phase == "COMMIT_POINT" then "authority-state,commit-rendering"
     elif $phase == "POST_EFFECT" then "authority-state,outcome,post-effect-proof"
     else "phase" end) as $dims
  | if $phase == "PRE_EFFECT" then
      (if ($auth.state // "") != "granted" then
        ["REFUSE", "IDENT_AUTHORITY_BY_NAME", $dims,
         "authority state is \($auth.state // "<absent>") where granted is required; a name, a list or a directory grants nothing"]
      elif ($e.served_from_cache // false) then
        ["REFUSE", "SFI_STALE_FOR_EFFECT", $dims,
         "an input was served from a cache at an effect-proximal boundary; no stored verdict is served here at any age"]
      elif (($e.intent_recorded // false) | not) then
        ["REFUSE", "EFFECT_INTENT_UNRECORDABLE", $dims,
         "the intent record was not durably written before returning; acting first is reachable by exactly one mistake and is not recoverable"]
      elif (($e.observed_head // "") == "") then
        ["CNO", "EFFECT_TARGET_UNOBSERVED", $dims,
         "the effect target could not be observed, so the three-way head agreement has only two values and may not be asserted either way"]
      elif (($e.approved_head // "") != ($e.caller_head // " "))
           or (($e.approved_head // "") != ($e.observed_head // " ")) then
        ["REFUSE", "EFFECT_HEAD_DISAGREEMENT", $dims,
         "approved=\($e.approved_head // "-") caller=\($e.caller_head // "-") observed=\($e.observed_head // "-"); agreement of all three is the property and any two of them is one of its weaker neighbours"]
      else
        ["PASS", "-", $dims,
         "a granted authority, an uncached input, a durably recorded intent, and three agreeing heads"]
      end)
    elif $phase == "COMMIT_POINT" then
      (if ($e.rendered_as_committed // false) then
        ["REFUSE", "EFFECT_PRECOMMIT_CLAIMED_COMMITTED", $dims,
         "a state before the commit point was rendered as committed; the commit point is a state with its own identity, not one of its neighbours"]
      elif ($auth.state // "") == "spent" then
        ["REFUSE", "EFFECT_REPLAY", $dims,
         "the authority for this subject is already spent, so arriving at a commit point again is a replay"]
      elif ($auth.state // "") != "spending" then
        ["REFUSE", "EFFECT_INTENT_UNRECORDABLE", $dims,
         "authority state is \($auth.state // "<absent>") at the commit point where spending is required; the intent was never moved, so the act may or may not have happened with nothing recording it"]
      else
        ["PASS", "-", $dims,
         "the commit point is rendered as itself and the authority is spending, which is the honest name for the window in which the act may or may not have happened"]
      end)
    elif $phase == "POST_EFFECT" then
      (if ($auth.state // "") == "spent" then
        ["REFUSE", "EFFECT_REPLAY", $dims,
         "the authority was already spent before this act, so this is a second spend of a one-use permission"]
      elif (($e.act_reported // "") == "failed") or (($e.outcome_recorded // false) | not) then
        ["CNO", "EFFECT_INDETERMINATE", $dims,
         "the act reported \($e.act_reported // "nothing") and the outcome was \(if ($e.outcome_recorded // false) then "recorded" else "not recorded" end); a failed invocation does not prove NOT_APPLIED, so reconcile from an observation before any retry"]
      elif (($e.post_effect_proof.source // "") == "")
           or (($e.post_effect_proof.source // "") == ($e.actor // " ")) then
        ["CNO", "EFFECT_UNPROVEN", $dims,
         "no INDEPENDENT observation of the target establishes that the intended effect is now true; the report of the actor is not the proof, and its absence is unproven rather than success"]
      else
        ["PASS", "-", $dims,
         "the outcome is recorded and an independent observation of the target establishes the effect"]
      end)
    else
      ["CNO", "EFFECT_INDETERMINATE", $dims,
       "phase \($phase) is not one of PRE_EFFECT, COMMIT_POINT or POST_EFFECT"]
    end
  | @tsv
'

fm_semantics_validate_effect_commit() {  # <record-path> <phase>
  local record=${1:-} phase=${2:-}
  [ -n "$record" ] && [ -f "$record" ] || {
    fm_semantics_emit validate_effect_commit CNO EFFECT_INDETERMINATE 'input' \
      "no effect record was supplied at ${record:-<absent>}"
    return $?
  }
  fm_semantics_docs_readable reasons || {
    fm_semantics_emit validate_effect_commit CNO EFFECT_INDETERMINATE 'owner-documents' \
      "an owner document could not be read, so no dimension could be evaluated"
    return $?
  }
  fm_semantics_decide validate_effect_commit "$FM_SEMANTICS_EFFECT_TABLE" "$record" \
    --arg phase "$phase" --null-input
}

# --- validate_identity_mapping ------------------------------------------------
#
# Decides whether ONE resolution across ONE declared namespace edge produced the
# subject it claims. Zero declared owners and two declared owners are the SAME
# refusal, because in both cases nobody is answerable and each candidate owner
# can correctly believe the other checked.
#
# Ambiguity and substitution stay apart deliberately. A mismatch says the one
# candidate found is not about this work; ambiguity says several were found and
# none can be chosen. Labelling the second a mismatch sends the operator asking
# why a ruling was misaddressed when the truth is that one comment carried two
# markers.
# shellcheck disable=SC2016  # jq program: $REC and friends are jq variables, not shell ones
FM_SEMANTICS_IDENTITY_TABLE='
  ($REC[0]) as $m
  | (input) as $ID
  | ($ID.edges | map({key: .edge, value: .}) | from_entries) as $edges
  | ($m.edge // null) as $edge
  | ($m.subject.digest // "") as $want
  | "edge-owner,candidate-cardinality,namespace-rule,recompilation,resolved-subject,provenance" as $dims
  | if ($edge | type) != "string" or ($edges | has($edge) | not) then
      ["REFUSE", "IDENT_MULTI_OWNER", $dims,
       "edge \($edge // "<absent>") is not declared, so no owner is answerable for it; an undeclared edge and a two-owner edge are the same defect"]
    elif (($edges[$edge].owner // null) == null) then
      ["REFUSE", "IDENT_MULTI_OWNER", $dims,
       "edge \($edge) is declared UNOWNED: \($edges[$edge].consequence // "nobody is answerable for this resolution")"]
    elif (($m.candidates // 0) | tonumber) > 1 then
      ["REFUSE", "IDENT_AMBIGUOUS", $dims,
       "\($m.candidates) candidates match across \($edge) and none is uniquely choosable; this is ambiguity, not a mismatch, and the repairs differ"]
    elif (($m.candidates // 0) | tonumber) < 1 then
      ["CNO", "IDENT_UNRESOLVABLE", $dims,
       "no candidate resolved across \($edge), so the mapping may not be asserted in either direction"]
    elif (($m.target_rule_observed // false) | not) then
      ["CNO", "IDENT_RULE_UNOBSERVED", $dims,
       "the identity rule of the target namespace could not be determined, so a comparison would be a guess; never default the rule"]
    elif $want == "" then
      ["CNO", "IDENT_UNRESOLVABLE", $dims,
       "the subject carries no digest, so there is nothing to recompile against"]
    elif (($m.recompiled_digest // "") != $want) then
      ["REFUSE", "IDENT_MOVED", $dims,
       "recompiling from the world yields \($m.recompiled_digest // "<absent>") where the subject claims \($want); a moved head is a DIFFERENT subject, not a stale one"]
    elif (($m.resolved_subject // "") != $want) then
      ["REFUSE", "IDENT_NAMESPACE_SUBSTITUTION", $dims,
       "the object resolved across \($edge) names subject \($m.resolved_subject // "<absent>") and not \($want); a workspace cannot become a repository, a transport cannot become a subject, and an artifact location cannot become a governed subject"]
    elif (($m.provenance // "") == "") then
      ["CNO", "IDENT_UNPROVENANCED", $dims,
       "no provenance record exists for this mapping, so it cannot be re-checked later; the edge owner records provenance when it resolves"]
    else
      ["PASS", "-", $dims,
       "edge \($edge) has one owner (\($edges[$edge].owner)), one candidate, an observable target rule, a recompilation that agrees, and a provenance record"]
    end
  | @tsv
'

fm_semantics_validate_identity_mapping() {  # <record-path>
  local record=${1:-}
  [ -n "$record" ] && [ -f "$record" ] || {
    fm_semantics_emit validate_identity_mapping CNO IDENT_UNRESOLVABLE 'input' \
      "no mapping record was supplied at ${record:-<absent>}"
    return $?
  }
  fm_semantics_docs_readable identity reasons || {
    fm_semantics_emit validate_identity_mapping CNO IDENT_UNRESOLVABLE 'owner-documents' \
      "an owner document could not be read, so no dimension could be evaluated"
    return $?
  }
  fm_semantics_decide validate_identity_mapping "$FM_SEMANTICS_IDENTITY_TABLE" "$record" \
    --null-input "$(fm_semantics_doc identity)"
}

# Dispatch by validator name, so a caller holding a name from a law declaration
# reaches the validator without a second table mapping names to functions.
fm_semantics_run() {  # <validator> <record-path> [extra...]
  local validator=${1:-}
  shift || true
  fm_semantics_validator_is_known "$validator" || {
    printf 'fm-semantics: unknown validator: %s\n' "${validator:-<absent>}" >&2
    return "$FM_SEMANTICS_EXIT_USAGE"
  }
  case "$validator" in
    validate_state) fm_semantics_validate_state "$@" ;;
    validate_transition) fm_semantics_validate_transition "$@" ;;
    validate_effect_commit) fm_semantics_validate_effect_commit "$@" ;;
    validate_identity_mapping) fm_semantics_validate_identity_mapping "$@" ;;
  esac
}
