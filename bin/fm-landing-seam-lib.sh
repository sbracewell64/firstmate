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
# APPLICABILITY IS ALSO POSITIVE AND CLOSED.
#
# Reporting the answer is not the same as reaching it honestly. This file's first
# form reported `not-applicable` faithfully and DERIVED it from an absence: no
# live correlation record for this item meant no ruling governed it. An obligation
# that is real but not represented by one exact local record therefore disappeared
# into the same clean-looking answer as work that was never under review.
#
# So `not-applicable` now requires POSITIVE proof that the effect is outside the
# governed landing domain, and the domain is DECLARED rather than inferred - see
# the governed-landing-domain section below. Inside the domain, a landing with no
# live correlation is `FM_LANDING_APPLICABLE_MISSING` and REFUSES. The missing
# record is what stops the landing rather than what permits it, which is the whole
# inversion this increment makes.
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
FM_LANDING_SEAM_TOKEN_APPLICABLE_MISSING=FM_LANDING_APPLICABLE_MISSING
FM_LANDING_SEAM_TOKEN_MINT_REFUSED=FM_LANDING_AUTHORIZATION_REFUSED
FM_LANDING_SEAM_TOKEN_SPEND_REFUSED=FM_LANDING_SPEND_REFUSED
# could-not-observe: no verdict was reached
FM_LANDING_SEAM_TOKEN_NO_ACT=FM_LANDING_ACT_NOT_PERFORMED
FM_LANDING_SEAM_TOKEN_AMBIGUOUS=FM_LANDING_AMBIGUOUS_AUTHORITY
FM_LANDING_SEAM_TOKEN_STORE_UNREADABLE=FM_LANDING_RECORD_STORE_UNREADABLE
FM_LANDING_SEAM_TOKEN_RECORD_UNREADABLE=FM_LANDING_RECORD_UNREADABLE
FM_LANDING_SEAM_TOKEN_VENUE_UNCONFIGURED=FM_LANDING_VENUE_UNCONFIGURED
FM_LANDING_SEAM_TOKEN_CANDIDATE_UNBOUND=FM_LANDING_CANDIDATE_UNBOUND
FM_LANDING_SEAM_TOKEN_DOMAIN_UNDECLARED=FM_LANDING_DOMAIN_UNDECLARED
FM_LANDING_SEAM_TOKEN_DOMAIN_UNREADABLE=FM_LANDING_DOMAIN_UNREADABLE
FM_LANDING_SEAM_TOKEN_VENUE_INVALID=FM_LANDING_VENUE_INVALID
FM_LANDING_SEAM_TOKEN_CANDIDATE_REPO_UNOBSERVED=FM_LANDING_CANDIDATE_REPOSITORY_UNOBSERVED
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

FM_LANDING_SEAM_VENUE_STATE=

fm_landing_seam_venue_read() {  # <config-dir>
  local file=${1:-}/sol-control.json raw repo issue
  FM_LANDING_SEAM_VENUE_STATE=invalid
  if [ ! -e "$file" ]; then
    FM_LANDING_SEAM_VENUE_STATE=absent
    return 0
  fi
  [ -f "$file" ] && [ -r "$file" ] || return 0
  raw=$(cat "$file" 2>/dev/null) || return 0
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 0
  repo=$(printf '%s' "$raw" | jq -r '.repo // ""' 2>/dev/null) || return 0
  issue=$(printf '%s' "$raw" | jq -r 'if .issue == null then "" else (.issue|tostring) end' 2>/dev/null) || return 0
  [ -n "$repo" ] && [ -n "$issue" ] || return 0
  FM_LANDING_SEAM_VENUE_STATE=valid
  return 0
}

# --- the governed landing domain ---------------------------------------------
#
# WHY A DECLARED DOMAIN, AND WHY IT IS THE THING THAT MAKES NOT-APPLICABLE REAL.
#
# The seam's first form asked one question - is there a live correlation record
# for this item at this head? - and read NO for "no ruling governs this". That
# reads an ABSENCE as a positive answer, and it is the same shape as the defect
# this file was written to close: a landing obligation that is real but not
# represented by one exact local record disappears into `not-applicable`, and the
# home looks authorised because nothing spoke. A record that was never written, a
# store that was never populated, and a review that was promised and never
# emitted are all indistinguishable from work no ruling was ever going to govern.
#
# So applicability is decided from a DECLARATION instead. `landing_domain.repos`
# in config/sol-control.json names the repositories whose landings this home has
# placed under Browser Sol control. Inside that domain a landing needs a live
# granting correlation and REFUSES without one, which is the whole point: the
# missing record becomes the refusal rather than the permission. Outside it, the
# landing is not-applicable on POSITIVE grounds - the operator said which
# repositories are governed and this is not one of them - and lands through the
# ordinary gates.
#
# The four states are kept apart because they need four different repairs.
#
#   listed      the declaration names repositories; membership decides
#   empty       the declaration names none, so nothing in this home is governed.
#               This is a complete positive answer on its own and needs no
#               repository identity: an empty set contains nothing.
#   undeclared  a venue is configured and the domain was never stated. This is
#               NOT an empty domain. A home that configured Sol control and never
#               said what it governs cannot answer this question, so it is
#               could-not-observe and the landing stops with both repairs named.
#   unreadable  the declaration is present and malformed, which is a defect in
#               the declaration rather than an answer about this candidate.
#
# Repositories are compared as the venue's own `owner/name` path, lowercased,
# because forge paths are case-insensitive and a case difference that read as a
# different repository would be a bypass. The host is deliberately not part of
# the comparison: an ssh host alias and the forge's own name address the same
# repository, and requiring them to agree would let renaming a remote shed the
# domain. Two same-path repositories on different hosts therefore both match,
# which over-includes rather than under-includes - a refusal an operator
# reconciles rather than a landing nobody authorised.

FM_LANDING_SEAM_DOMAIN_STATE=
FM_LANDING_SEAM_DOMAIN_REPOS=

fm_landing_seam_domain_read() {  # <config-dir>
  local file=${1:-}/sol-control.json raw declared repos
  FM_LANDING_SEAM_DOMAIN_STATE=unreadable
  FM_LANDING_SEAM_DOMAIN_REPOS=
  raw=$(cat "$file" 2>/dev/null) || return 0
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 0
  declared=$(printf '%s' "$raw" | jq -r 'if has("landing_domain") then "yes" else "no" end' 2>/dev/null) || return 0
  if [ "$declared" != yes ]; then
    FM_LANDING_SEAM_DOMAIN_STATE=undeclared
    return 0
  fi
  # An explicit null is a malformed declaration rather than a way to say none:
  # "none" has its own spelling, `{"repos": []}`, and accepting two spellings for
  # a decision this consequential is how one of them stops being read.
  repos=$(printf '%s' "$raw" | jq -r '
      .landing_domain as $d
      | if ($d | type) != "object" then error("shape")
        elif ($d | has("repos") | not) then error("shape")
        elif ($d.repos | type) != "array" then error("shape")
        elif ([$d.repos[] | select(type != "string")] | length) > 0 then error("shape")
        elif ([$d.repos[] | select(test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not)] | length) > 0 then error("shape")
        else ($d.repos[] | ascii_downcase)
        end' 2>/dev/null) || return 0
  if [ -z "$repos" ]; then
    FM_LANDING_SEAM_DOMAIN_STATE=empty
    return 0
  fi
  FM_LANDING_SEAM_DOMAIN_STATE=listed
  FM_LANDING_SEAM_DOMAIN_REPOS=$repos
  return 0
}

fm_landing_seam_domain_contains() {  # <repo-path>
  local repo
  repo=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  [ -n "$repo" ] && [ "$repo" != - ] || return 1
  printf '%s\n' "$FM_LANDING_SEAM_DOMAIN_REPOS" | grep -qxF "$repo"
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
#
# The repository argument is the candidate's own landing repository as an
# `owner/name` path, or "-" when the caller could not establish one. "-" is a
# could-not-observe about the candidate, never a claim that it has no repository:
# it can still reach not-applicable through an empty declared domain, because an
# empty domain contains nothing whatever the candidate turns out to be, but it
# can never be shown to be outside a NON-empty one.
fm_landing_seam_resolve() {  # <record-dir> <config-dir> <item> <head> <pr-or-dash> <repo-or-dash>
  local dir=$1 config=$2 item=$3 head=$4 pr=$5 repo=$6
  local f rid raw stored gate state rec_head rec_pr
  local live=0 granting=0 granting_id='' others=''
  local venue_state store=present

  if ! fm_landing_seam_candidate_valid "$item" "$head"; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_CANDIDATE_UNBOUND" \
      "the landing candidate names item '$item' at head '$head', which is not a work item at an exact head, so whether a ruling governs it could not be asked"
    return $?
  fi

  fm_landing_seam_venue_read "$config"
  venue_state=$FM_LANDING_SEAM_VENUE_STATE

  if [ ! -d "$dir" ]; then
    # A store that does not exist has never held a correlation record, which is a
    # genuine emptiness rather than an unreadable one. It leaves the live count at
    # zero and the declared domain decides, exactly as an enumerated empty store
    # does: whether a missing record permits or refuses is the domain's question,
    # not the store's.
    store=absent
  elif [ ! -r "$dir" ] || [ ! -x "$dir" ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_STORE_UNREADABLE" \
      "the Browser Sol correlation store at $dir could not be enumerated, so this is not an absence of rulings"
    return $?
  fi

  for f in "$dir"/*.json; do
    # An absent store is enumerated as empty rather than by blanking the path,
    # because a blank path would glob the filesystem root.
    [ "$store" = present ] || break
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

  if [ "$live" -gt 0 ]; then
    # An exact live correlation is a stronger statement about this item than any
    # repository-level declaration, so it decides on its own and the domain is
    # never consulted. That direction matters: a live request must govern its item
    # whether or not somebody remembered to list its repository.
    #
    # Governed, and the venue is missing. This home holds live Sol requests and no
    # venue to resolve them against, which is a contradiction in its own
    # configuration rather than an answer about this candidate.
    if [ "$venue_state" = absent ]; then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_VENUE_UNCONFIGURED" \
        "$live live Browser Sol request(s) govern $item while no control venue is configured in this home, so whether their rulings apply could not be observed"
      return $?
    fi
    if [ "$venue_state" = invalid ]; then
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_VENUE_INVALID" \
        "config/sol-control.json is present but unreadable, malformed, or missing repo or issue, so the Browser Sol control venue could not be observed"
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
  fi

  # No live correlation names this item. Whether that is permission or a refusal
  # is decided by the DECLARED domain and never by the absence itself.

  # A home with no control venue has placed nothing under Browser Sol control, so
  # there is no governed landing domain for a candidate to be inside. That is the
  # shipped default and the complete answer for every home that never opted in.
  if [ "$venue_state" = absent ]; then
    fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
      "no Browser Sol control venue is configured in this home, so no landing is inside a governed domain and no ruling governs $item at $head"
    return $?
  fi

  if [ "$venue_state" = invalid ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_VENUE_INVALID" \
      "config/sol-control.json is present but unreadable, malformed, or missing repo or issue, so the Browser Sol control venue and its landing domain could not be observed"
    return $?
  fi

  fm_landing_seam_domain_read "$config"
  case "$FM_LANDING_SEAM_DOMAIN_STATE" in
    undeclared)
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_DOMAIN_UNDECLARED" \
        "this home configures a Browser Sol control venue and declares no landing_domain in config/sol-control.json, so whether $item at $head is inside the governed landing domain could not be observed; name the governed repositories as {\"landing_domain\": {\"repos\": [\"owner/name\"]}}, or declare that none are governed with {\"landing_domain\": {\"repos\": []}}"
      return $?
      ;;
    unreadable)
      fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_DOMAIN_UNREADABLE" \
        "the landing_domain declared in config/sol-control.json is not an object carrying a repos array of owner/name paths, so whether $item at $head is inside the governed landing domain could not be observed"
      return $?
      ;;
    empty)
      fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
        "this home declares an empty Browser Sol landing domain, so $item at $head is outside it and no ruling governs this landing"
      return $?
      ;;
  esac

  if [ "$repo" = - ] || [ -z "$repo" ]; then
    fm_landing_seam_set unobserved "$FM_LANDING_SEAM_TOKEN_CANDIDATE_REPO_UNOBSERVED" \
      "this home declares a Browser Sol landing domain and the repository this landing would write could not be established, so whether $item at $head is inside that domain could not be observed"
    return $?
  fi

  if ! fm_landing_seam_domain_contains "$repo"; then
    fm_landing_seam_set not-applicable "$FM_LANDING_SEAM_TOKEN_NOT_APPLICABLE" \
      "$repo is not in this home's declared Browser Sol landing domain ($(printf '%s' "$FM_LANDING_SEAM_DOMAIN_REPOS" | tr '\n' ' ')), so $item at $head is outside it and no ruling governs this landing"
    return $?
  fi

  # THE REPAIR. The candidate is inside the declared governed domain and no live
  # Browser Sol request covers it. The missing record is the refusal, because a
  # governed landing whose authority was never recorded is exactly the landing
  # that must not happen on the strength of nothing having been written down.
  fm_landing_seam_set refused "$FM_LANDING_SEAM_TOKEN_APPLICABLE_MISSING" \
    "$repo is inside this home's declared Browser Sol landing domain and no live review request covers $item at $head, so the authority this landing must consume does not exist"
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

FM_LANDING_SEAM_AUTH_ID=

fm_landing_seam_mint() {  # <auth-script> <request-id>
  local auth=$1 rid=$2 out id rc=0
  FM_LANDING_SEAM_AUTH_ID=
  out=$("$auth" mint "$rid" 2>&1) || rc=$?
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
# command is reached. That is the property that makes the wiring real rather than
# advisory.
#
# WHY A RECEIPT AND NOT AN EXIT STATUS. `spend` exits 0 on two different
# outcomes: the act ran and the authority is now spent, or the authority was
# ALREADY spent and no act was performed. Reading only the exit status turns the
# second into a silent success - a merge gate reporting success while merging
# nothing - which is precisely the double-land this mechanism exists to make
# impossible. So the act is wrapped in a one-line prologue that records having
# been entered, and the landing is a success only when that receipt says the act
# was reached. The receipt is written BEFORE the command for the same reason the
# intent record is: a receipt written afterwards cannot distinguish an act that
# never ran from one that ran and could not report.
#
# The wrapper's own failure to write the receipt exits 125 rather than running
# the act, so a landing whose outcome could not have been recorded does not
# happen at all.
#
# Returns 0 when the act ran and the authority is spent, 3 when the spend was
# refused, and 4 for every could-not-observe, including an act that exited
# non-zero - which is NOT evidence that it had no effect.

fm_landing_seam_spend() {  # <auth-script> <auth-id> <head> <receipt> <command...>
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

  # shellcheck disable=SC2016  # the wrapper's own positional parameters, deliberately unexpanded here
  "$auth" spend "$id" --head "$head" -- \
    bash -c 'printf "entered\n" > "$1" || exit 125; shift; exec "$@"' \
    fm-landing-act "$receipt" "$@" || rc=$?

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
