# shellcheck shell=bash
# fm-landing-seam-lib.sh - the single owner of ONE question, asked at the two
# real landing chokepoints: is THIS landing candidate governed by a Browser Sol
# ruling, and if so which durable request grants the authority the landing must
# consume?
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-landing-seam-lib.sh
#   . "$SCRIPT_DIR/fm-landing-seam-lib.sh"
#
# It needs bin/fm-outbound-artifact-lib.sh for the gate register and
# bin/fm-landing-authorization-lib.sh for the head prefilter and the
# authorization id shape; source both before this one.
#
# WHY THIS EXISTS.
#
# bin/fm-landing-authorization.sh was a complete, correct control that nothing
# ever invoked. Every property it establishes - one exact head, one use, an
# intent record written before the act, a spend that stays indeterminate rather
# than returning to the pool - was real in its own test and reachable from no
# production landing. A control the mutation path can route around is not a
# control; it is a description of one. This file is the wiring, and it is
# deliberately the ONLY wiring, so bin/fm-pr-merge.sh and bin/fm-merge-local.sh
# cannot drift into two different answers about whether a landing was governed.
#
# WHAT IT DOES NOT OWN, stated so nothing credits it with more.
#
# It does not decide whether a ruling approves. bin/fm-landing-authorization.sh
# owns minting, the closed approving-verdict set, the exactly-once spend, and the
# head re-observation; this file selects the request to hand it and refuses to
# guess when the selection is not unique. It does not correlate a ruling to a
# request either - bin/fm-outbound-artifact.sh owns that, and this reads its
# records read-only, exactly as the authorization layer does.
#
# It establishes nothing about whether a head is green, mergeable, or unblocked
# by review. Those remain the calling gate's own guards, and this composes with
# them rather than replacing them: a candidate must pass every pre-existing
# refusal AND consume an authorization when one governs it.
#
# APPLICABILITY IS AN OBSERVATION, NOT A SILENCE.
#
# A landing that no ruling governs must proceed, and must SAY that it proceeded
# ungoverned. The failure mode this replaces is a home that looks authorised
# because nothing spoke. So `not-applicable` is a reported verdict with its own
# token and its own reason, carried to the operator on every ungoverned landing,
# and it is reached only after the record store was successfully enumerated.
# An enumeration that could not be completed is could-not-observe and stops the
# landing, because the record it could not read is exactly the one that might
# have governed it.
#
# WHY GOVERNANCE IS KEYED ON THE ITEM AND THE AUTHORITY ON THE HEAD.
#
# These are two different questions and collapsing them is how a governed
# landing escapes. "Is this work under Sol review?" is a fact about the ITEM and
# survives a rebase. "Does an approval cover what is about to land?" is a fact
# about the exact HEAD and does not. So a live request for the item makes the
# candidate governed, and only a request bound to the candidate's exact head can
# grant. An item governed at head A landing head B therefore REFUSES; it does not
# fall through to not-applicable, which would make moving the head the cheapest
# way to shed the ruling.
#
# The record's project field is deliberately not compared. The item already
# identifies the work, and the two surfaces name projects differently - the
# correlation record carries a registry name while a merge gate holds a clone
# path - so comparing them would refuse correct landings on a naming mismatch
# while adding nothing the item does not already establish.

if [ -n "${FM_LANDING_SEAM_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_LANDING_SEAM_LIB_SOURCED=1

# --- contract constants ------------------------------------------------------

# The sol-control gates that do NOT govern a landing, named as the exclusion
# rather than by listing the ones that do.
#
# The direction is the point. Governance is derived as "every sol-control gate
# except these", so a gate added to the outbound vocabulary later governs a
# landing until somebody decides otherwise, rather than silently permitting one
# until somebody remembers to add it here. The cost of a wrong inclusion is a
# refused landing an operator reconciles; the cost of a wrong exclusion is the
# defect this whole file exists to close.
#
# ARCHITECTURE_RULING_REQUIRED is excluded because its subject is a design
# question, not this head's fitness to land. Work whose LANDING must wait on Sol
# is emitted under one of the review gates, which are bound to an exact head for
# exactly that reason.
FM_LANDING_SEAM_NONGOVERNING_GATES='ARCHITECTURE_RULING_REQUIRED'

# The correlation-record states in which a gate is still in force. Named
# positively, so a state added to the outbound vocabulary later is not live here
# until it is stated to be.
#
#   emitting  a request is being posted; the gate is in force and unanswered
#   emitted   the request is posted and unanswered
#   ruled     a ruling arrived; whether it approves is the authorization's call
#   resumed   the ruling was applied and the item resumed - the landing it
#             authorised has still not happened, so the authority is still live
#
# `closed` and `superseded` are past. A superseded record's successor is found by
# this same scan when it is live, and a closed record carries its own
# disposition, so neither needs to keep governing to stay accounted for.
FM_LANDING_SEAM_LIVE_STATES='emitting
emitted
ruled
resumed'

# Stable tokens. Callers and tests match these rather than prose.
#
# The families are kept apart exactly as the authorization layer keeps them
# apart: a REFUSAL says a verdict was reached and it is no, an UNOBSERVED says no
# verdict was reached. Both stop the landing, and an operator told only "it did
# not work" repairs the wrong thing.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
# reported observations - neither is a refusal
FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE=FM_LANDING_NOT_APPLICABLE
FM_LANDING_SEAM_TOKEN_GOVERNED=FM_LANDING_GOVERNED
# refusals: a verdict was reached and it is no
FM_LANDING_SEAM_TOKEN_HEAD_UNAPPROVED=FM_LANDING_HEAD_NOT_APPROVED
FM_LANDING_SEAM_TOKEN_MINT_REFUSED=FM_LANDING_AUTHORIZATION_REFUSED
FM_LANDING_SEAM_TOKEN_SPEND_REFUSED=FM_LANDING_SPEND_REFUSED
# could-not-observe: no verdict was reached
FM_LANDING_SEAM_TOKEN_NO_ACT=FM_LANDING_ACT_NOT_PERFORMED
FM_LANDING_SEAM_TOKEN_AMBIGUOUS=FM_LANDING_AMBIGUOUS_AUTHORITY
FM_LANDING_SEAM_TOKEN_STORE_UNREADABLE=FM_LANDING_RECORD_STORE_UNREADABLE
FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE=FM_LANDING_RECORD_UNREADABLE
FM_LANDING_SEAM_TOKEN_VENUE_UNCONFIGURED=FM_LANDING_VENUE_UNCONFIGURED
FM_LANDING_SEAM_TOKEN_CANDIDATE_UNBOUND=FM_LANDING_CANDIDATE_UNBOUND
FM_LANDING_SEAM_TOKEN_MINT_UNOBSERVED=FM_LANDING_AUTHORIZATION_UNOBSERVED
FM_LANDING_SEAM_TOKEN_SPEND_UNOBSERVED=FM_LANDING_SPEND_UNOBSERVED
FM_LANDING_SEAM_TOKEN_RECEIPT_UNOBSERVED=FM_LANDING_ACT_RECEIPT_UNOBSERVED
}

# --- gate and state vocabulary -----------------------------------------------
#
# The channel comes from bin/fm-outbound-artifact-lib.sh, which owns the gate
# register, so a gate renamed there is renamed here by construction.

fm_landing_seam_gate_governs() {  # <gate>
  local gate=${1:-}
  [ -n "$gate" ] || return 1
  [ "$(fm_outbound_gate_channel "$gate")" = sol-control ] || return 1
  if printf '%s\n' "$FM_LANDING_SEAM_NONGOVERNING_GATES" | grep -qxF "$gate"; then
    return 1
  fi
  return 0
}

fm_landing_seam_state_live() {  # <state>
  printf '%s\n' "$FM_LANDING_SEAM_LIVE_STATES" | grep -qxF "${1:-}"
}

# --- candidate shape ---------------------------------------------------------
#
# A candidate this file cannot bind is refused before any record is read. The
# head must be an exact head by the authorization layer's own prefilter, because
# a candidate whose head is a branch name or a captured error body would compare
# equal to no record and reach not-applicable - a bypass wearing the shape of a
# clean answer.

fm_landing_seam_candidate_valid() {  # <item> <head>
  [ -n "${1:-}" ] || return 1
  fm_auth_head_shape_valid "${2:-}"
}

# --- the venue ---------------------------------------------------------------

fm_landing_seam_venue_configured() {  # <config-dir>
  local file=${1:-}/sol-control.json raw repo issue
  [ -f "$file" ] || return 1
  raw=$(cat "$file" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 1
  repo=$(printf '%s' "$raw" | jq -r '.repo // ""' 2>/dev/null) || return 1
  issue=$(printf '%s' "$raw" | jq -r 'if .issue == null then "" else (.issue|tostring) end' 2>/dev/null) || return 1
  [ -n "$repo" ] && [ -n "$issue" ]
}

# --- resolution --------------------------------------------------------------
#
# Sets, always, all four:
#   FM_LANDING_SEAM_VERDICT   governed | not-applicable | refused | unobserved
#   FM_LANDING_SEAM_TOKEN     one stable token from the block above
#   FM_LANDING_SEAM_REASON    one line naming what was observed
#   FM_LANDING_SEAM_REQUEST   the granting request id, only when governed
#
# Returns 0 for governed and not-applicable, 3 for refused, 4 for unobserved, so
# a caller that reads only the status still stops safely on both stopping values.

FM_LANDING_SEAM_VERDICT=
FM_LANDING_SEAM_TOKEN=
FM_LANDING_SEAM_REASON=
FM_LANDING_SEAM_REQUEST=

# shellcheck disable=SC2034  # the four outputs are read by the sourcing merge gates
fm_landing_seam_set() {  # <verdict> <token> <reason> [<request>]
  FM_LANDING_SEAM_VERDICT=$1
  FM_LANDING_SEAM_TOKEN=$2
  FM_LANDING_SEAM_REASON=$3
  FM_LANDING_SEAM_REQUEST=${4:-}
  case $1 in
    governed|not-applicable) return 0 ;;
    refused) return 3 ;;
    *) return 4 ;;
  esac
}

# The pull request argument is the candidate's own, or "-" when the caller has
# none of its own. "-" does NOT relax the binding: it means the caller cannot
# contribute that half of it, and the authorization layer still re-observes the
# ruling's own pull request head at the moment of use. A local fast-forward is
# governed by a ruling on a published head precisely because that is the only
# head an outside reviewer could ever have seen.
fm_landing_seam_resolve() {  # <record-dir> <config-dir> <item> <head> <pr-or-dash>
  local dir=$1 config=$2 item=$3 head=$4 pr=$5
  local f rid raw stored gate state rec_head rec_pr
  local live=0 granting=0 granting_id='' others=''

  if ! fm_landing_seam_candidate_valid "$item" "$head"; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_CANDIDATE_UNBOUND" \
      "the landing candidate names item '$item' at head '$head', which is not a work item at an exact head, so whether a ruling governs it could not be asked"
    return $?
  fi

  if [ ! -d "$dir" ]; then
    # A store that does not exist has never held a correlation record, which is a
    # genuine emptiness rather than an unreadable one.
    if fm_landing_seam_venue_configured "$config"; then
      fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
        "no Browser Sol request has ever been recorded in this home, so no ruling governs $item at $head"
      return $?
    fi
    fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
      "no Browser Sol control venue is configured in this home and no request has ever been recorded, so no ruling governs $item at $head"
    return $?
  fi
  if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_STORE_UNREADABLE" \
      "the Browser Sol correlation store at $dir could not be enumerated, so this is not an absence of rulings"
    return $?
  fi

  for f in "$dir"/*.json; do
    [ -e "$f" ] || continue
    rid=${f##*/}
    rid=${rid%.json}
    if ! raw=$(cat "$f" 2>/dev/null); then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record $f could not be read, and an unreadable record is exactly the one that might govern $item"
      return $?
    fi
    if ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record $f is not readable JSON, and an unreadable record is exactly the one that might govern $item"
      return $?
    fi
    if [ "$(printf '%s' "$raw" | jq -r '.schema // ""')" != "$FM_OUTBOUND_RECORD_SCHEMA" ]; then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record $f does not declare schema $FM_OUTBOUND_RECORD_SCHEMA, so what it governs could not be read"
      return $?
    fi
    # LOCATION IS NOT IDENTITY, held here for the same reason the authorization
    # layer holds it: a record adopted from its filename can be moved into place.
    stored=$(printf '%s' "$raw" | jq -r '.request_id // ""')
    if [ "$stored" != "$rid" ]; then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE" \
        "correlation record filed as $rid names request '$stored', so what it governs could not be read"
      return $?
    fi

    [ "$(printf '%s' "$raw" | jq -r '.identity.item // ""')" = "$item" ] || continue
    gate=$(printf '%s' "$raw" | jq -r '.identity.gate // ""')
    fm_landing_seam_gate_governs "$gate" || continue
    state=$(printf '%s' "$raw" | jq -r '.state // ""')
    fm_landing_seam_state_live "$state" || continue

    live=$((live + 1))
    rec_head=$(printf '%s' "$raw" | jq -r '.identity.head // ""')
    if [ "$rec_head" != "$head" ]; then
      others="$others $rid($gate/$state at ${rec_head:--})"
      continue
    fi
    rec_pr=$(printf '%s' "$raw" | jq -r '.identity.pr // "-"')
    if [ "$pr" != '-' ] && [ "$rec_pr" != "$pr" ]; then
      others="$others $rid($gate/$state on ${rec_pr:--})"
      continue
    fi
    granting=$((granting + 1))
    granting_id=$rid
  done

  if [ "$live" -eq 0 ]; then
    if fm_landing_seam_venue_configured "$config"; then
      fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
        "no live Browser Sol review request governs $item, so this landing is not ruling-governed"
      return $?
    fi
    fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
      "no Browser Sol control venue is configured in this home and no live review request governs $item, so this landing is not ruling-governed"
    return $?
  fi

  # Governed, and the venue is missing. This is NOT the unconfigured-home case
  # above: this home holds live Sol requests and no venue to resolve them
  # against, which is a contradiction in its own configuration rather than an
  # answer about this candidate.
  if ! fm_landing_seam_venue_configured "$config"; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_VENUE_UNCONFIGURED" \
      "$live live Browser Sol request(s) govern $item while no control venue is configured in this home, so whether their rulings apply could not be observed"
    return $?
  fi

  if [ "$granting" -eq 0 ]; then
    fm_landing_seam_set refused "$FM_LANDING_SEAM_TOKEN_HEAD_UNAPPROVED" \
      "$live live Browser Sol request(s) govern $item and none is bound to the head being landed ($head):$others"
    return $?
  fi
  if [ "$granting" -gt 1 ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_AMBIGUOUS" \
      "$granting live Browser Sol requests claim to govern $item at $head, so which authority this landing would consume could not be determined"
    return $?
  fi

  fm_landing_seam_set governed "$FM_LANDING_SEAM_TOKEN_GOVERNED" \
    "Browser Sol request $granting_id governs $item at $head" "$granting_id"
  return $?
}

# --- authority ---------------------------------------------------------------
#
# Mint is idempotent on the authorization identity, so calling it here grants at
# most one authority per ruling per head however many times a landing is
# attempted. Every reason a ruling may not grant one - a request that is not
# ruled, a declining verdict, a verdict this fleet cannot classify, a request
# naming no pull request whose head could be re-observed - is decided by
# bin/fm-landing-authorization.sh and relayed verbatim, because a second copy of
# that decision here is the second control plane both halves exist to avoid.
#
# THE EFFECT PLAN PASSES THROUGH, IT IS NOT BUILT HERE. The trailing arguments
# are the chokepoint's declaration of the act it is asking to have authorized,
# and this file forwards them verbatim. bin/fm-landing-authorization.sh validates
# every one of them, derives the venue, target, and head from the ruling rather
# than from the declaration, and refuses a plan it cannot close. A second copy of
# that validation here would be the second control plane both halves exist to
# avoid, and a plan assembled here would make this file an act builder, which it
# is deliberately not.

FM_LANDING_SEAM_AUTH_ID=

fm_landing_seam_mint() {  # <auth-script> <request-id> [<effect-plan-arg>...]
  local auth=$1 rid=$2; shift 2
  local out id rc=0
  FM_LANDING_SEAM_AUTH_ID=
  out=$("$auth" mint "$rid" "$@" 2>&1) || rc=$?
  if [ "$rc" -eq 3 ]; then
    fm_landing_seam_set refused "$FM_LANDING_SEAM_TOKEN_MINT_REFUSED" \
      "the ruling on $rid grants no landing authorization: $out"
    return $?
  fi
  if [ "$rc" -ne 0 ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_MINT_UNOBSERVED" \
      "whether the ruling on $rid grants a landing authorization could not be observed: $out"
    return $?
  fi
  id=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}')
  if ! fm_auth_id_valid "$id"; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_MINT_UNOBSERVED" \
      "minting the authorization for $rid returned no authorization id: $out"
    return $?
  fi
  # shellcheck disable=SC2034  # read by the sourcing merge gates
  FM_LANDING_SEAM_AUTH_ID=$id
  return 0
}

# --- the act -----------------------------------------------------------------
#
# THE ACT RUNS INSIDE THE SPEND, not after a check that one would be permitted.
# A gate that asks "may I land?" and then lands is two operations with a window
# between them; this is one, and the durable intent record is written before the
# act is reached. That is the property that makes the wiring real rather than
# advisory.
#
# THE COMMAND PASSED HERE IS AN ASSERTION, NOT THE ACT. The authority builds the
# act from its own effect plan; what a chokepoint passes is the act it believes
# it is authorizing, and the authority refuses before any mutation when the two
# differ. This file used to hand `spend` the command to run, wrapped in a
# `bash -c` prologue of its own - which made the SEAM the chooser of the
# executable and of the argv, the exact freedom the effect plan closes. Both are
# gone: the wrapper because the receipt is the authority's to write, and the
# chooser because there is no longer one here.
#
# WHY A RECEIPT AND NOT AN EXIT STATUS. `spend` exits 0 on two different
# outcomes: the act ran and the authority is now spent, or the authority was
# ALREADY spent and no act was performed. Reading only the exit status turns the
# second into a silent success - a merge gate reporting success while merging
# nothing - which is precisely the double-land this mechanism exists to make
# impossible. So the authority writes the receipt immediately before the act, and
# the landing is a success only when that receipt says the act was reached.
#
# Returns 0 when the act ran and the authority is spent, 3 when the spend was
# refused, and 4 for every could-not-observe, including an act that exited
# non-zero - which is NOT evidence that it had no effect.

fm_landing_seam_spend() {  # <auth-script> <auth-id> <head> <receipt> <asserted-command...>
  local auth=$1 id=$2 head=$3 receipt=$4; shift 4
  local rc=0

  if ! : > "$receipt" 2>/dev/null; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECEIPT_UNOBSERVED" \
      "the landing act receipt at $receipt could not be created, so whether the act ran could not have been observed"
    return $?
  fi
  if [ -s "$receipt" ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_RECEIPT_UNOBSERVED" \
      "the landing act receipt at $receipt could not be emptied before the act, so a stale receipt could be read as this act"
    return $?
  fi

  "$auth" spend "$id" --head "$head" --receipt "$receipt" --assert-act -- "$@" || rc=$?

  if [ "$rc" -eq 0 ] && [ -s "$receipt" ]; then
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    # The one outcome an exit status cannot express: the authority was spent
    # already, so `spend` succeeded at doing nothing.
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_NO_ACT" \
      "the landing authority $id was already spent, so no landing act was performed and this landing did not happen"
    return $?
  fi
  if [ "$rc" -eq 3 ]; then
    fm_landing_seam_set refused "$FM_LANDING_SEAM_TOKEN_SPEND_REFUSED" \
      "the landing authority $id refused to authorize this act"
    return $?
  fi
  fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_SPEND_UNOBSERVED" \
    "the act under landing authority $id exited $rc, which does not establish that it had no effect; reconcile it from an observation with bin/fm-landing-authorization.sh reconcile $id"
  return $?
}

# fail-closed-predicates: enforced
