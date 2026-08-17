#!/usr/bin/env bash
# fm-landing-authorization-lib.sh - the contract for a ruling-derived landing
# authorization: its identity, its state vocabulary, and the pure predicates that
# decide whether one may be minted and whether one may be spent.
#
# WHY THIS EXISTS, AND WHAT IT DELIBERATELY DOES NOT DO.
#
# The inbound control plane already establishes THAT a ruling answers a given
# request. bin/fm-outbound-artifact.sh joins a Browser Sol comment to the durable
# correlation record that asked for it, refuses an unrelated one, refuses a body
# whose request marker or verdict line is ambiguous, and invalidates a record
# whose identity has moved. That mechanism owns correlation, and this one does
# not repeat any part of it - a second joiner would be the second control plane
# both halves exist to avoid. This file starts from a correlation record that is
# already `ruled` and treats establishing that state as somebody else's proven
# work.
#
# What nothing owned is the step after. A ruling that approves a landing is an
# AUTHORITY, and an authority has properties a correlation record does not: it is
# bound to one exact head, it is exhausted by being used, and using it is an
# irreversible act against the outside world. Correlation is a fact about two
# documents, so re-deriving it is free; landing is an event, so re-deriving it is
# impossible. That asymmetry is the whole reason this file exists.
#
# THE FOURTH STATE, which is the hazard this file is shaped around.
#
# A spend has three answers a later reader may reach - it was spent, it was not
# spent, or that could not be observed - and one state a careless implementation
# reaches instead: the act happened and nothing recorded it. That fourth state is
# indistinguishable from "not spent" to every later reader, so the next attempt
# lands a second time. It is reached by exactly one mistake, writing the durable
# record after the act rather than before, which is why the spend sequence writes
# INTENT first and OUTCOME second and reports the gap between them as
# could-not-observe rather than as either neighbour.
#
# A failed act sits in that same gap. A merge command that exits non-zero has not
# said the merge did not happen; it has said it reported a failure, and for an
# irreversible act those are different claims. Reading the exit status as "no
# effect" is the same substitution as reading an unreadable file as an absent
# one, so a failed act leaves the authorization indeterminate and reconcilable
# rather than silently returning it to the pool. The cost is that an ordinary
# transient failure needs an explicit reconciliation instead of a blind retry,
# and that cost is accepted: a retry that lands twice is not recoverable and a
# reconciliation that took a minute is.
#
# WHY THE HEAD IS OBSERVED AND NOT ACCEPTED.
#
# The actor spending an authorization is the party the head condition is checked
# against, so a spend that compares only the head that actor passed in has
# anchored the condition to something the checked party sets in the same act.
# The caller states its intended head and that must agree, but the binding is
# carried by an independent observation of the pull request's current head at the
# moment of use. Agreement of all three - what the ruling approved, what the
# caller intends, and what the forge currently reports - is the property; any two
# of them is one of its weaker neighbours.
#
# WHAT THIS FILE DOES NOT ESTABLISH, stated so no reader credits it with more.
#
# It does not re-derive the correlation record's own identity digest, and it does
# not re-read the ruling comment. That record is the outbound owner's artifact
# and its internal integrity is that owner's to prove; this file consumes it,
# requires it to be filed under its own request id, and refuses anything it
# cannot read as the schema it expects. A correlation record that is internally
# consistent but forged is out of scope here and in scope there. A ruling edited
# on the forge after correlation is likewise not detected here.

if [ -n "${FM_LANDING_AUTH_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_LANDING_AUTH_LIB_SOURCED=1

# --- contract constants ------------------------------------------------------

FM_AUTH_SCHEMA='fm-landing-authorization.v1'

# The correlation record schema this consumes. Owned by
# bin/fm-outbound-artifact-lib.sh as FM_OUTBOUND_RECORD_SCHEMA; named here as the
# version this reader accepts, so an unannounced schema change is refused as
# could-not-observe rather than parsed on a guess.
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_CORRELATION_SCHEMA='fm-outbound-artifact.v1'

# The only correlation state a landing authorization may be minted from.
# `emitted` has no ruling yet; `superseded` and `closed` are past; `resumed` has
# already moved the work on. Named positively, as one state rather than a list of
# excluded ones, so a state added to that vocabulary later is refused here rather
# than silently admitted.
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_CORRELATION_MINTABLE_STATE='ruled'

FM_AUTH_ID_PREFIX='fm-auth-'
FM_AUTH_ID_HEX_WIDTH=32

# Authorization lifecycle.
#
#   granted   minted, unspent, and fresh as far as the last check could observe
#   spending  a spend began and its outcome is not recorded - the honest name for
#             the window in which the act may or may not have happened
#   spent     the act completed and this authority is exhausted
#   void      permanently inapplicable: the head moved, or the request it rests
#             on was superseded
# shellcheck disable=SC2034  # contract constant consumed by sourcing callers
FM_AUTH_STATES='granted
spending
spent
void'

# What a caller reads. `indeterminate` is deliberately a status a reader can
# reach and act on, not an error: it is the third value, and collapsing it into
# either neighbour is the defect this file exists to prevent.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_AUTH_STATUS_GRANTED='granted'
FM_AUTH_STATUS_SPENT='spent'
FM_AUTH_STATUS_INDETERMINATE='indeterminate'
FM_AUTH_STATUS_VOID='void'
FM_AUTH_STATUS_UNREADABLE='unreadable'
FM_AUTH_STATUS_ABSENT='absent'
}

# Stable refusal tokens. Callers and tests match these rather than prose, so the
# wording can improve without breaking a consumer.
#
# The two families are kept apart on purpose, the same distinction the inbound
# identity vocabulary already draws: a REFUSAL says a verdict was reached and it
# is no, and an UNOBSERVED says no verdict was reached at all. Both stop the act,
# so collapsing them is not unsafe - it is unreportable, and an operator told
# only "it did not work" repairs the wrong thing.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
# refusals: a verdict was reached and it is no
FM_AUTH_TOKEN_NOT_RULED=FM_AUTH_REQUEST_NOT_RULED
FM_AUTH_TOKEN_MISPLACED=FM_AUTH_CORRELATION_MISPLACED
FM_AUTH_TOKEN_ABSENT=FM_AUTH_CORRELATION_ABSENT
FM_AUTH_TOKEN_DECLINED=FM_AUTH_VERDICT_DECLINED
FM_AUTH_TOKEN_STALE_HEAD=FM_AUTH_STALE_HEAD
FM_AUTH_TOKEN_HEAD_MISMATCH=FM_AUTH_HEAD_MISMATCH
FM_AUTH_TOKEN_SUPERSEDED=FM_AUTH_REQUEST_SUPERSEDED
FM_AUTH_TOKEN_EXHAUSTED=FM_AUTH_ALREADY_SPENT
FM_AUTH_TOKEN_VOID=FM_AUTH_VOID
# Kept apart from VOID: an authorization that never existed and one that existed
# and was retired are different facts, and an operator chasing the first looks
# for a mint that did not happen while the second looks for what moved.
FM_AUTH_TOKEN_NONE=FM_AUTH_NO_AUTHORIZATION
FM_AUTH_TOKEN_IN_FLIGHT=FM_AUTH_SPEND_IN_FLIGHT
FM_AUTH_TOKEN_NO_ACT=FM_AUTH_NO_ACT
FM_AUTH_TOKEN_BAD_HEAD=FM_AUTH_HEAD_MALFORMED
FM_AUTH_TOKEN_NO_PR=FM_AUTH_GRANT_HAS_NO_PULL_REQUEST

# could-not-observe: no verdict was reached
FM_AUTH_TOKEN_UNREADABLE=FM_AUTH_CORRELATION_UNREADABLE
FM_AUTH_TOKEN_RECORD_UNREADABLE=FM_AUTH_RECORD_UNREADABLE
FM_AUTH_TOKEN_VERDICT_UNRECOGNIZED=FM_AUTH_VERDICT_UNRECOGNIZED
FM_AUTH_TOKEN_HEAD_UNOBSERVED=FM_AUTH_HEAD_UNOBSERVED
FM_AUTH_TOKEN_INDETERMINATE=FM_AUTH_SPEND_INDETERMINATE
FM_AUTH_TOKEN_ENUM_UNOBSERVED=FM_AUTH_ENUMERATION_UNOBSERVED
FM_AUTH_TOKEN_WRITE_UNOBSERVED=FM_AUTH_INTENT_UNRECORDABLE
}

# The verdicts that authorize a landing, and the ones that decline it.
#
# A verdict outside BOTH lists is UNRECOGNIZED and refuses. The asymmetry is the
# point: the failure that matters is an unknown word being read as approval, so
# the approving set is closed and everything else stops. Compared
# case-insensitively because the ruling corpus writes both `accepted` and
# `APPROVE`.
FM_AUTH_VERDICTS_AUTHORIZING='accept
accepted
approve
approved'

FM_AUTH_VERDICTS_DECLINING='decline
declined
deny
denied
reject
rejected'

# --- digest ------------------------------------------------------------------

fm_auth_digest() {  # reads stdin, prints a lowercase hex digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# --- identity ----------------------------------------------------------------
#
# Every field that changes WHAT IS AUTHORIZED is in the identity, one per line in
# a fixed order, so the canonical form is stable across shells and its digest is
# a durable id.
#
# head is the load-bearing member. A moved head produces a different identity, a
# different id, and therefore a different authorization, so "an authorization is
# bound to one exact head" falls out of the identity rather than being enforced
# beside it. Minting the same ruling twice reproduces the same id, which is what
# makes a duplicate mint converge on one authorization instead of two.
#
# An absent optional field is the literal "-" rather than empty, so "no pull
# request" and "pull request omitted" cannot collide into one identity.

fm_auth_identity_canonical() {  # <request> <comment> <verdict> <item> <project> <repo> <pr> <head>
  printf 'schema=%s\nrequest=%s\ncomment=%s\nverdict=%s\nitem=%s\nproject=%s\nrepo=%s\npr=%s\nhead=%s\n' \
    "$FM_AUTH_SCHEMA" "$1" "$2" "$3" "$4" "${5:--}" "${6:--}" "${7:--}" "$8"
}

fm_auth_id() {  # <same arguments as fm_auth_identity_canonical> -> id
  local sum
  sum=$(fm_auth_identity_canonical "$@" | fm_auth_digest) || return 1
  [ -n "$sum" ] || return 1
  printf '%s%s\n' "$FM_AUTH_ID_PREFIX" "${sum:0:$FM_AUTH_ID_HEX_WIDTH}"
}

fm_auth_id_valid() {  # <candidate>
  printf '%s' "${1:-}" \
    | grep -Eq "^${FM_AUTH_ID_PREFIX}[0-9a-f]{${FM_AUTH_ID_HEX_WIDTH}}\$"
}

# --- verdict classification --------------------------------------------------
#
# Prints authorizing | declining | unrecognized. Three values, because "not on
# the approving list" covers both a ruling that said no and a ruling whose word
# nobody has taught this mechanism, and those are different repairs: one is a
# decision to respect, the other is a vocabulary gap to close.

fm_auth_verdict_class() {  # <verdict>
  local lower token
  lower=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  lower=${lower#"${lower%%[![:space:]]*}"}
  lower=${lower%"${lower##*[![:space:]]}"}
  [ -n "$lower" ] || { printf 'unrecognized\n'; return 0; }
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "$lower" = "$token" ] || continue
    printf 'authorizing\n'
    return 0
  done <<< "$FM_AUTH_VERDICTS_AUTHORIZING"
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    [ "$lower" = "$token" ] || continue
    printf 'declining\n'
    return 0
  done <<< "$FM_AUTH_VERDICTS_DECLINING"
  printf 'unrecognized\n'
}

# --- head shape --------------------------------------------------------------
#
# A SHAPE PREFILTER ONLY, and named that way so nothing credits it with more.
# The load-bearing head check is equality against an independently observed head
# at the moment of the act; this only rejects a value that cannot be a head at
# all, such as a branch name or a forge error body captured from stdout.
#
# Both widths are accepted because the object format belongs to the target
# repository, which this mechanism never clones. That makes the prefilter weaker
# than the outbound owner's resolvable-object rule, and it is sound here only
# because the equality carries the property and this only screens the inputs.

fm_auth_head_shape_valid() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

# --- pull request locator ----------------------------------------------------
#
# The correlation record stores a pull request as its URL, which is a LOCATION.
# This does not pretend otherwise: parsing it yields the coordinates needed to
# ASK the forge what the head currently is, and the answer is then required to
# equal the head the ruling approved. The location never substitutes for the
# identity; it only addresses the question.
#
# The parse is strict so a near-miss string cannot resolve to some other
# repository's pull request. A URL carrying a trailing path, query, or fragment
# is refused rather than trimmed: a URL this parser had to repair is not a URL
# this parser understood.
#
# Prints "<owner>/<repo> <number>" and returns 1 when the input is not one.

fm_auth_pr_locator() {  # <pr-url>
  local url=${1:-} rest owner repo number
  case $url in
    https://github.com/*/pull/*) rest=${url#https://github.com/} ;;
    *) return 1 ;;
  esac
  owner=${rest%%/*}
  rest=${rest#*/}
  repo=${rest%%/*}
  rest=${rest#*/}
  case $rest in
    pull/*) number=${rest#pull/} ;;
    *) return 1 ;;
  esac
  case $number in
    ''|*[!0-9]*) return 1 ;;
  esac
  case $owner in ''|*/*|*\?*|*\#*) return 1 ;; esac
  case $repo in ''|*/*|*\?*|*\#*) return 1 ;; esac
  printf '%s/%s %s\n' "$owner" "$repo" "$number"
}

# --- spend admissibility -----------------------------------------------------
#
# The pure half of the spend decision: what the record's own state permits,
# before any freshness is re-observed. Prints one token.
#
#   proceed        granted, and freshness has still to be checked
#   exhausted      already spent - the caller returns the recorded outcome and
#                  performs no act, which is what makes a duplicate wake converge
#   indeterminate  a spend began and no outcome was recorded
#   void           permanently inapplicable
#   unreadable     the state is not one this contract knows

fm_auth_spend_admissibility() {  # <state>
  case ${1:-} in
    granted) printf 'proceed\n' ;;
    spent) printf 'exhausted\n' ;;
    spending) printf 'indeterminate\n' ;;
    void) printf 'void\n' ;;
    *) printf 'unreadable\n' ;;
  esac
}

# --- reported status ---------------------------------------------------------
#
# The record state a caller sees. `spending` is reported as `indeterminate`
# because that is what it means to a reader: the durable record cannot say
# whether the act happened. Naming it after the internal transition would invite
# a reader to treat it as "in progress" and wait for something to finish it.

fm_auth_reported_status() {  # <state>
  case ${1:-} in
    granted) printf '%s\n' "$FM_AUTH_STATUS_GRANTED" ;;
    spent) printf '%s\n' "$FM_AUTH_STATUS_SPENT" ;;
    spending) printf '%s\n' "$FM_AUTH_STATUS_INDETERMINATE" ;;
    void) printf '%s\n' "$FM_AUTH_STATUS_VOID" ;;
    *) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE" ;;
  esac
}

# --- record construction -----------------------------------------------------

fm_auth_record_new() {  # <id> <request> <comment> <verdict> <item> <project> <repo> <pr> <head> <now>
  jq -n \
    --arg schema "$FM_AUTH_SCHEMA" \
    --arg id "$1" --arg request "$2" --arg comment "$3" --arg verdict "$4" \
    --arg item "$5" --arg project "$6" --arg repo "$7" --arg pr "$8" \
    --arg head "$9" --arg now "${10}" \
    '{schema:$schema,
      authorization_id:$id,
      request_id:$request,
      ruling:{comment_id:$comment,verdict:$verdict},
      grant:{item:$item,project:$project,repo:$repo,
             pr:(if $pr == "" or $pr == "-" then null else $pr end),
             head:$head},
      uses:1,
      state:"granted",
      minted:$now,
      updated:$now,
      spend:null,
      void_reason:null,
      history:[]}'
}

# fail-closed-predicates: enforced
