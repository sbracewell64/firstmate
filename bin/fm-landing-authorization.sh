#!/usr/bin/env bash
# fm-landing-authorization.sh - mint a one-use landing authorization from a ruled
# Browser Sol request, and spend it exactly once against the exact head it names.
#
# WHAT THIS IS FOR. A ruling that approves a landing is an authority, not just a
# record. It permits ONE irreversible act, against ONE head. Nothing in this
# fleet held that authority as a countable, exhaustible thing before: a ruling
# was read, an agent remembered it, and the merge happened. A remembered
# authority cannot be spent twice safely, cannot survive a restart, and cannot
# refuse a head that moved after it was granted. This makes it durable, bound,
# and exactly-once.
#
# WHAT IT IS NOT. It is not the inbound correlation path. Establishing that a
# ruling answers a given request, refusing an unrelated one, refusing an
# ambiguous body, and invalidating a moved request are owned and proven by
# bin/fm-outbound-artifact.sh. This starts from a correlation record already in
# `ruled` and adds only the authority on top. See
# bin/fm-landing-authorization-lib.sh's header for the full boundary and for the
# fourth-state hazard the spend sequence is shaped around.
#
# USAGE
#   fm-landing-authorization.sh mint <request-id>
#       Mint (or return) the authorization the ruled request grants. Idempotent
#       on the authorization identity: the same ruling for the same head always
#       reproduces the same id, so a duplicate wake converges on one authority.
#
#   fm-landing-authorization.sh spend <auth-id> --head <sha> -- <command> [args...]
#       Perform <command> at most once under this authority. Refuses unless the
#       head the ruling approved, the head the caller states, and the head the
#       forge currently reports are all the same value.
#
#   fm-landing-authorization.sh status <auth-id>
#       Print one token: granted | spent | indeterminate | void | unreadable |
#       absent. `indeterminate` is a real answer rather than a failure, and it
#       still exits 4 so that exit 0 from this command means strictly "a
#       determinate answer" to a caller that reads only the status.
#
#   fm-landing-authorization.sh reconcile <auth-id> --observed applied|not-applied
#                                          --evidence <ref>
#       Resolve an indeterminate spend from an OBSERVATION of whether the act
#       happened. Requires the evidence pointer; it never guesses.
#
#   fm-landing-authorization.sh list
#       Enumerate authorizations. A partial enumeration reports could-not-observe
#       rather than a short list.
#
# EXIT CODES
#   0  the operation completed, or the authority was already spent and the
#      recorded outcome is reprinted
#   2  usage error
#   3  refused - a verdict was reached and it is no
#   4  could-not-observe - no verdict was reached, including an indeterminate
#      spend. Never read as either neighbour.
#
# Judge this command by the token it prints, not by the exit status alone: 3 and
# 4 are different results and the token names which.
#
# ENVIRONMENT
#   FM_HOME                operational home (default: repo root)
#   FM_LANDING_AUTH_DIR    authorization store (default: $FM_HOME/data/landing-authorizations)
#   FM_OUTBOUND_DIR        correlation records (default: $FM_HOME/data/outbound-artifacts)
#                          Owned by bin/fm-outbound-artifact.sh; read-only here.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
AUTH_DIR="${FM_LANDING_AUTH_DIR:-$DATA/landing-authorizations}"
CORRELATION_DIR="${FM_OUTBOUND_DIR:-$DATA/outbound-artifacts}"

# shellcheck source=bin/fm-landing-authorization-lib.sh
. "$SCRIPT_DIR/fm-landing-authorization-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CLAIM=

usage() { sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

die() {  # <message> [<code>]
  printf '%s\n' "$1" >&2
  exit "${2:-4}"
}

refuse() {  # <token> <message>
  printf '%s: %s\n' "$1" "$2" >&2
  exit 3
}

unobserved() {  # <token> <message>
  printf '%s: %s\n' "$1" "$2" >&2
  exit 4
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- store -------------------------------------------------------------------

auth_path() {
  fm_auth_id_valid "${1:-}" || return 1
  printf '%s/%s.json\n' "$AUTH_DIR" "$1"
}

auth_claim_path() {
  fm_auth_id_valid "${1:-}" || return 1
  printf '%s/.%s.claim\n' "$AUTH_DIR" "$1"
}

# Atomic by rename, so a reader never sees a half-written record and a crash
# leaves either the previous record or the new one - never a torn one. The spend
# sequence depends on this: an intent record that could be half-written would put
# the fourth state back.
auth_write() {  # <auth-id> <json>
  local path tmp
  path=$(auth_path "$1") || return 1
  mkdir -p "$AUTH_DIR" || return 1
  tmp="$path.tmp.$$"
  printf '%s\n' "$2" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Three-valued, and the caller must keep the three apart:
#   0 and RECORD set   readable
#   3                  no such file - genuinely absent
#   4                  present and unreadable, or not this schema
AUTH_RECORD=
auth_read() {  # <auth-id>
  local expected=$1 path raw schema stored request comment verdict item project repo pr head computed
  path=$(auth_path "$expected") || return 4
  if [ ! -e "$path" ]; then
    AUTH_RECORD=
    return 3
  fi
  raw=$(cat "$path" 2>/dev/null) || return 4
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 4
  schema=$(printf '%s' "$raw" | jq -r '.schema // ""')
  [ "$schema" = "$FM_AUTH_SCHEMA" ] || return 4
  printf '%s' "$raw" | jq -e '
    (.authorization_id | type == "string" and length > 0) and
    (.request_id | type == "string" and length > 0) and
    (.ruling | type == "object") and
    (.ruling.comment_id | type == "string" and length > 0) and
    (.ruling.verdict | type == "string" and length > 0) and
    (.grant | type == "object") and
    (.grant.item | type == "string" and length > 0) and
    (.grant.project | type == "string") and
    (.grant.repo | type == "string") and
    ((.grant.pr == null) or (.grant.pr | type == "string" and length > 0)) and
    (.grant.head | type == "string") and
    (.uses == 1) and
    (.state == "granted" or .state == "spending" or .state == "spent" or .state == "void") and
    (.minted | type == "string" and length > 0) and
    (.updated | type == "string" and length > 0) and
    (.history | type == "array") and
    (if .state == "granted" then .spend == null and .void_reason == null
     elif .state == "void" then .spend == null and (.void_reason | type == "string" and length > 0)
     elif .state == "spending" then
       (.void_reason == null) and (.spend | type == "object") and
       (.spend.started | type == "string" and length > 0) and
       (.spend.act_digest | type == "string") and
       (.spend.observed_head | type == "string") and
       (.spend.outcome == null or .spend.outcome == "failed") and
       ((.spend.finished == null) or (.spend.finished | type == "string" and length > 0)) and
       (.spend.evidence == null)
     else
       (.void_reason == null) and (.spend | type == "object") and
       (.spend.started | type == "string" and length > 0) and
       (.spend.act_digest | type == "string") and
       (.spend.observed_head | type == "string") and
       (.spend.outcome == "applied") and
       (.spend.finished | type == "string" and length > 0) and
       ((.spend.evidence == null) or (.spend.evidence | type == "string" and length > 0))
     end)' >/dev/null 2>&1 || return 4
  stored=$(printf '%s' "$raw" | jq -r '.authorization_id')
  [ "$stored" = "$expected" ] || return 4
  request=$(printf '%s' "$raw" | jq -r '.request_id')
  comment=$(printf '%s' "$raw" | jq -r '.ruling.comment_id')
  verdict=$(printf '%s' "$raw" | jq -r '.ruling.verdict')
  item=$(printf '%s' "$raw" | jq -r '.grant.item')
  project=$(printf '%s' "$raw" | jq -r '.grant.project')
  repo=$(printf '%s' "$raw" | jq -r '.grant.repo')
  pr=$(printf '%s' "$raw" | jq -r '.grant.pr // "-"')
  head=$(printf '%s' "$raw" | jq -r '.grant.head')
  fm_auth_head_shape_valid "$head" || return 4
  computed=$(fm_auth_id "$request" "$comment" "$verdict" "$item" "$project" "$repo" "$pr" "$head") \
    || return 4
  [ "$computed" = "$expected" ] || return 4
  AUTH_RECORD=$raw
  return 0
}

# --- the correlation record, consumed read-only ------------------------------
#
# LOCATION IS NOT IDENTITY, enforced here rather than assumed. A record is
# addressed by filename and must also SAY it is that request; a file whose
# `.request_id` disagrees with where it sits is refused rather than adopted,
# because adopting the filename when the content says otherwise is exactly the
# substitution that lets a mis-filed or copied record authorize the wrong work.
CORRELATION=
correlation_read() {  # <request-id>
  local rid=$1 path raw schema stored
  path="$CORRELATION_DIR/$rid.json"
  if [ ! -e "$path" ]; then
    refuse "$FM_AUTH_TOKEN_ABSENT" \
      "no correlation record for $rid, so no request asked for this ruling"
  fi
  raw=$(cat "$path" 2>/dev/null) \
    || unobserved "$FM_AUTH_TOKEN_UNREADABLE" "correlation record $rid could not be read"
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 \
    || unobserved "$FM_AUTH_TOKEN_UNREADABLE" "correlation record $rid is not readable JSON"
  schema=$(printf '%s' "$raw" | jq -r '.schema // ""')
  [ "$schema" = "$FM_AUTH_CORRELATION_SCHEMA" ] \
    || unobserved "$FM_AUTH_TOKEN_UNREADABLE" \
      "correlation record $rid declares schema '$schema', not $FM_AUTH_CORRELATION_SCHEMA"
  stored=$(printf '%s' "$raw" | jq -r '.request_id // ""')
  [ "$stored" = "$rid" ] \
    || refuse "$FM_AUTH_TOKEN_MISPLACED" \
      "correlation record filed as $rid names request '$stored'"
  CORRELATION=$raw
}

# --- the observed head -------------------------------------------------------
#
# The independent half of the head binding. Asked of the forge at the moment of
# use, so the condition is not anchored to a value the spending actor supplies.
#
# THE STDOUT TRAP. `gh api` prints its error body to stdout, so a failed call
# whose exit status is ignored yields a JSON error document that a naive reader
# carries forward as a head. Both guards are applied: the exit status is checked,
# AND the result must pass the head shape prefilter before it is compared. An
# unobservable head is could-not-observe and stops the spend; it is never
# resolved by falling back to the head the caller offered, which would delete the
# whole point of observing it.
observe_head() {  # <owner/repo> <number> -> prints sha, or returns 1
  local out
  out=$(gh api "repos/$1/pulls/$2" --jq '.head.sha' 2>/dev/null) || return 1
  fm_auth_head_shape_valid "$out" || return 1
  printf '%s\n' "$out"
}

# --- claim -------------------------------------------------------------------
#
# Serializes concurrent live spends of one authority. mkdir is the atomic
# primitive: it succeeds for exactly one caller.
#
# A claim left behind by a killed process does NOT silently expire, and that is
# deliberate. The durable record is already `spending` in that case, so the
# authority is indeterminate on its own terms; a claim that timed itself out
# would let the next caller past the one guard that is telling the truth.
# `reconcile` clears both together, which is the only path that has an
# observation to justify it.
claim_acquire() {  # <auth-id>
  local dir pid identity group
  dir=$(auth_claim_path "$1") || return 1
  pid=${BASHPID:-$$}
  group=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
  [ "$group" = "$pid" ] || return 1
  identity=$(fm_pid_identity "$pid") || return 1
  mkdir -p "$AUTH_DIR" || return 1
  mkdir "$dir" 2>/dev/null || return 1
  printf '%s\n' "$pid" > "$dir/owner-pid" \
    && printf '%s\n' "$identity" > "$dir/owner-identity" \
    && printf '%s\n' "$group" > "$dir/owner-group" \
    || { rm -f "$dir/owner-pid" "$dir/owner-identity" "$dir/owner-group"; rmdir "$dir" 2>/dev/null; return 1; }
  CLAIM=$dir
  trap claim_release EXIT INT TERM
  return 0
}

claim_release() {
  [ -n "$CLAIM" ] || return 0
  rm -f "$CLAIM/owner-pid" "$CLAIM/owner-identity" "$CLAIM/owner-group"
  rmdir "$CLAIM" 2>/dev/null || true
  CLAIM=
}

claim_owner_state() {  # <auth-id>
  local dir pid identity group current current_group proc_root groups self_group snapshot_state
  dir=$(auth_claim_path "$1") || { printf 'unobserved\n'; return; }
  pid=$(cat "$dir/owner-pid" 2>/dev/null) \
    && identity=$(cat "$dir/owner-identity" 2>/dev/null) \
    && group=$(cat "$dir/owner-group" 2>/dev/null) \
    || { printf 'unobserved\n'; return; }
  case $pid in ''|*[!0-9]*) printf 'unobserved\n'; return ;; esac
  [ "$group" = "$pid" ] || { printf 'unobserved\n'; return; }
  [ -n "$identity" ] || { printf 'unobserved\n'; return; }
  if current=$(fm_pid_identity "$pid" 2>/dev/null); then
    if [ "$current" = "$identity" ]; then
      current_group=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]') \
        || { printf 'unobserved\n'; return; }
      if [ "$current_group" = "$group" ]; then printf 'live\n'; else printf 'unobserved\n'; fi
      return
    fi
  else
    proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
    if [ -d "$proc_root" ] && [ -e "$proc_root/$pid" ]; then
      printf 'unobserved\n'
      return
    fi
  fi
  groups=$(LC_ALL=C ps -e -o pgid= 2>/dev/null) \
    || { printf 'unobserved\n'; return; }
  self_group=$(ps -o pgid= -p "${BASHPID:-$$}" 2>/dev/null | tr -d '[:space:]') \
    || { printf 'unobserved\n'; return; }
  case $self_group in ''|*[!0-9]*) printf 'unobserved\n'; return ;; esac
  printf '%s\n' "$groups" | awk -v wanted="$group" -v self="$self_group" '
    BEGIN { valid=1 }
    NF != 1 || $1 !~ /^[0-9]+$/ { valid=0; next }
    { seen=1 }
    $1 == self { self_seen=1 }
    $1 == wanted { wanted_seen=1 }
    END {
      if (!seen || !valid || !self_seen) exit 2
      if (wanted_seen) exit 0
      exit 1
    }'
  snapshot_state=$?
  case $snapshot_state in
    0) printf 'live\n' ;;
    1) printf 'gone\n' ;;
    *) printf 'unobserved\n' ;;
  esac
}

claim_reclaim_gone() {  # <auth-id>
  local dir
  [ "$(claim_owner_state "$1")" = gone ] || return 1
  dir=$(auth_claim_path "$1") || return 1
  rm -f "$dir/owner-pid" "$dir/owner-identity" "$dir/owner-group" || return 1
  rmdir "$dir" 2>/dev/null || return 1
  claim_acquire "$1"
}

# --- mint --------------------------------------------------------------------

cmd_mint() {  # <request-id>
  local rid=$1 state comment verdict class item project repo pr head id rec now existing rc
  [ -n "$rid" ] || die "mint needs a request id" 2

  correlation_read "$rid"

  state=$(printf '%s' "$CORRELATION" | jq -r '.state // ""')
  [ "$state" = "$FM_AUTH_CORRELATION_MINTABLE_STATE" ] \
    || refuse "$FM_AUTH_TOKEN_NOT_RULED" \
      "request $rid is $state; only a $FM_AUTH_CORRELATION_MINTABLE_STATE request grants a landing authorization"

  comment=$(printf '%s' "$CORRELATION" | jq -r '.ruling.comment_id // ""')
  verdict=$(printf '%s' "$CORRELATION" | jq -r '.ruling.verdict // ""')
  [ -n "$comment" ] && [ -n "$verdict" ] \
    || unobserved "$FM_AUTH_TOKEN_UNREADABLE" \
      "request $rid is ruled but carries no readable ruling comment and verdict"

  # An unknown word is never read as approval. Declined and unrecognized are kept
  # apart because respecting a refusal and closing a vocabulary gap are different
  # repairs.
  class=$(fm_auth_verdict_class "$verdict")
  case $class in
    authorizing) ;;
    declining)
      refuse "$FM_AUTH_TOKEN_DECLINED" \
        "the ruling on $rid returned '$verdict', which does not authorize a landing" ;;
    *)
      unobserved "$FM_AUTH_TOKEN_VERDICT_UNRECOGNIZED" \
        "the ruling on $rid returned '$verdict', which this mechanism cannot classify as approving or declining" ;;
  esac

  item=$(printf '%s' "$CORRELATION" | jq -r '.identity.item // ""')
  project=$(printf '%s' "$CORRELATION" | jq -r '.identity.project // ""')
  repo=$(printf '%s' "$CORRELATION" | jq -r '.identity.repo // ""')
  pr=$(printf '%s' "$CORRELATION" | jq -r '.identity.pr // "-"')
  head=$(printf '%s' "$CORRELATION" | jq -r '.identity.head // ""')

  [ -n "$item" ] \
    || unobserved "$FM_AUTH_TOKEN_UNREADABLE" "request $rid names no work item"
  fm_auth_head_shape_valid "$head" \
    || refuse "$FM_AUTH_TOKEN_BAD_HEAD" \
      "request $rid names head '$head', which cannot be an exact head"

  # A landing is performed against a pull request, so an authorization with no
  # pull request to observe could never have its head re-checked at the moment of
  # use. Refusing at mint keeps that from surfacing as a surprise at spend.
  fm_auth_pr_locator "$pr" >/dev/null \
    || refuse "$FM_AUTH_TOKEN_NO_PR" \
      "request $rid names no pull request to land, so its head could not be observed at use"

  id=$(fm_auth_id "$rid" "$comment" "$verdict" "$item" "$project" "$repo" "$pr" "$head") \
    || die "the authorization identity could not be computed" 4

  # Idempotent on identity. The same ruling for the same head reproduces the same
  # id, so a second mint returns the first authorization rather than granting a
  # second one against the same approval.
  auth_read "$id"; rc=$?
  case $rc in
    0)
      existing=$(printf '%s' "$AUTH_RECORD" | jq -r '.state')
      printf '%s %s (already minted, %s)\n' "$id" "$item" \
        "$(fm_auth_reported_status "$existing")"
      return 0 ;;
    4)
      unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
        "an authorization already exists at $id and could not be read" ;;
  esac

  now=$(now_iso)
  rec=$(fm_auth_record_new "$id" "$rid" "$comment" "$verdict" "$item" "$project" \
    "$repo" "$pr" "$head" "$now") \
    || die "the authorization record could not be constructed" 4
  auth_write "$id" "$rec" \
    || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the authorization for $rid could not be recorded, so none was granted"
  printf '%s %s at %s\n' "$id" "$item" "$head"
}

# --- spend -------------------------------------------------------------------

# Permanently retire an authorization that can never apply again, recording why.
# A head that moved and a request that was superseded are both past the point
# where re-checking could help, so leaving them `granted` would mean re-deciding
# the same refusal on every later attempt.
auth_void() {  # <auth-id> <record> <reason>
  local rec
  rec=$(printf '%s' "$2" | jq --arg r "$3" --arg n "$(now_iso)" \
    '.state = "void" | .void_reason = $r | .updated = $n
     | .history += [{at:$n, event:"void", detail:$r}]')
  auth_write "$1" "$rec" || return 1
}

cmd_spend() {  # <auth-id> --head <sha> -- <command>...
  local id=$1; shift
  local want_head=''
  local rec state admit outcome_state recorded
  local rid corr_state corr_comment pr locator owner number observed
  local grant_head act_digest now rc

  while [ $# -gt 0 ]; do
    case $1 in
      --head) want_head=${2:-}; shift 2 || die "--head needs a value" 2 ;;
      --) shift; break ;;
      *) die "unexpected argument '$1' before --" 2 ;;
    esac
  done
  [ -n "$id" ] || die "spend needs an authorization id" 2
  [ -n "$want_head" ] || die "spend needs --head, the head the caller intends to land" 2
  [ $# -gt 0 ] || refuse "$FM_AUTH_TOKEN_NO_ACT" \
    "spend was given no command to perform, so there is nothing to authorize"

  auth_read "$id"; rc=$?
  case $rc in
    3) refuse "$FM_AUTH_TOKEN_NONE" "no authorization $id exists" ;;
    4) unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
         "authorization $id could not be read, so whether it is spent is unknown" ;;
  esac
  rec=$AUTH_RECORD
  state=$(printf '%s' "$rec" | jq -r '.state // ""')

  # The exactly-once decision, made from the durable record BEFORE anything else,
  # so a duplicate wake and a restarted process reach it by the same path.
  admit=$(fm_auth_spend_admissibility "$state")
  case $admit in
    proceed) ;;
    exhausted)
      recorded=$(printf '%s' "$rec" | jq -r '.spend.outcome // "applied"')
      printf '%s: %s was already spent (%s); no act performed\n' \
        "$FM_AUTH_TOKEN_EXHAUSTED" "$id" "$recorded"
      return 0 ;;
    indeterminate)
      unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
        "a spend of $id began and recorded no outcome, so whether the act happened is unknown; reconcile it from an observation before any further attempt" ;;
    void)
      refuse "$FM_AUTH_TOKEN_VOID" \
        "authorization $id is void: $(printf '%s' "$rec" | jq -r '.void_reason // "no reason recorded"')" ;;
    *)
      unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
        "authorization $id is in state '$state', which this contract does not know" ;;
  esac

  claim_acquire "$id" \
    || refuse "$FM_AUTH_TOKEN_IN_FLIGHT" \
      "another spend of $id holds the claim; one authority is spent by one caller"

  grant_head=$(printf '%s' "$rec" | jq -r '.grant.head')

  # 1 of 3: the head the caller states must be the head the ruling approved.
  [ "$want_head" = "$grant_head" ] \
    || refuse "$FM_AUTH_TOKEN_HEAD_MISMATCH" \
      "authorization $id approves $grant_head; the caller asked to land $want_head"

  # The request must still be the one that granted this. A superseded or closed
  # correlation record means the approval no longer describes live work.
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  correlation_read "$rid"
  corr_state=$(printf '%s' "$CORRELATION" | jq -r '.state // ""')
  corr_comment=$(printf '%s' "$CORRELATION" | jq -r '.ruling.comment_id // ""')
  case $corr_state in
    ruled|resumed) ;;
    *)
      auth_void "$id" "$rec" "request $rid is $corr_state" \
        || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
          "authorization $id is inapplicable and that could not be recorded"
      refuse "$FM_AUTH_TOKEN_SUPERSEDED" \
        "request $rid is $corr_state, so its landing authorization no longer applies" ;;
  esac
  [ "$corr_comment" = "$(printf '%s' "$rec" | jq -r '.ruling.comment_id')" ] \
    || {
      auth_void "$id" "$rec" "request $rid now carries a different ruling" \
        || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
          "authorization $id is inapplicable and that could not be recorded"
      refuse "$FM_AUTH_TOKEN_SUPERSEDED" \
        "request $rid now carries a different ruling than the one that granted $id"
    }

  # 2 of 3: the forge's current head, observed independently of the caller.
  pr=$(printf '%s' "$rec" | jq -r '.grant.pr // ""')
  locator=$(fm_auth_pr_locator "$pr") \
    || unobserved "$FM_AUTH_TOKEN_HEAD_UNOBSERVED" \
      "authorization $id names pull request '$pr', which could not be resolved to a location to observe"
  owner=${locator%% *}
  number=${locator##* }
  observed=$(observe_head "$owner" "$number") \
    || unobserved "$FM_AUTH_TOKEN_HEAD_UNOBSERVED" \
      "the current head of $owner#$number could not be observed, so it cannot be shown to be the approved one"

  # 3 of 3: all three agree, or the authority does not apply.
  if [ "$observed" != "$grant_head" ]; then
    auth_void "$id" "$rec" "head moved from $grant_head to $observed" \
      || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
        "authorization $id is inapplicable and that could not be recorded"
    refuse "$FM_AUTH_TOKEN_STALE_HEAD" \
      "authorization $id approves $grant_head but $owner#$number is now at $observed"
  fi

  # INTENT BEFORE ACT. Everything after this point may crash, and the durable
  # record must already say a spend began, because the alternative is a landing
  # nothing remembers.
  now=$(now_iso)
  act_digest=$(printf '%s\n' "$@" | fm_auth_digest) || act_digest=
  rec=$(printf '%s' "$rec" | jq --arg n "$now" --arg d "$act_digest" --arg h "$observed" \
    '.state = "spending"
     | .spend = {started:$n, act_digest:$d, observed_head:$h, outcome:null, finished:null, evidence:null}
     | .updated = $n
     | .history += [{at:$n, event:"spend-began", detail:$d}]')
  auth_write "$id" "$rec" \
    || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the spend of $id could not be recorded before the act, so no act was performed"

  "$@"
  rc=$?

  # A non-zero act is NOT "nothing happened". It is could-not-observe about an
  # irreversible operation, so the authority stays indeterminate and reconcilable
  # rather than returning to the pool for a blind retry.
  now=$(now_iso)
  if [ "$rc" -eq 0 ]; then
    outcome_state=spent
    rec=$(printf '%s' "$rec" | jq --arg n "$now" \
      '.state = "spent" | .spend.outcome = "applied" | .spend.finished = $n
       | .updated = $n | .history += [{at:$n, event:"spent", detail:"applied"}]')
  else
    outcome_state=spending
    rec=$(printf '%s' "$rec" | jq --arg n "$now" --arg c "$rc" \
      '.state = "spending" | .spend.outcome = "failed" | .spend.finished = $n
       | .updated = $n
       | .history += [{at:$n, event:"act-failed", detail:("exit " + $c)}]')
  fi
  auth_write "$id" "$rec" \
    || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the act ran and its outcome could not be recorded for $id"
  claim_release

  if [ "$outcome_state" = spent ]; then
    printf 'spent: %s landed %s at %s\n' "$id" \
      "$(printf '%s' "$rec" | jq -r '.grant.item')" "$grant_head"
    return 0
  fi
  unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
    "the act under $id exited $rc, which does not establish that it had no effect; reconcile it from an observation"
}

# --- status ------------------------------------------------------------------

# The token on stdout is the answer, and the exit code is a second, coarser copy
# of it that fails closed. Exit 0 from `status` therefore means strictly "a
# determinate answer": `indeterminate` exits 4 alongside `unreadable`, because a
# caller that reads only the exit status must not learn "fine" from a record that
# cannot say whether the act happened. The two are still distinguished by the
# printed token, which is where the repair is named.
cmd_status() {  # <auth-id>
  local id=$1 rc reported
  [ -n "$id" ] || die "status needs an authorization id" 2
  auth_read "$id"; rc=$?
  case $rc in
    3) printf '%s\n' "$FM_AUTH_STATUS_ABSENT"; exit 3 ;;
    4) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE"; exit 4 ;;
  esac
  reported=$(fm_auth_reported_status "$(printf '%s' "$AUTH_RECORD" | jq -r '.state // ""')")
  printf '%s\n' "$reported"
  case $reported in
    "$FM_AUTH_STATUS_INDETERMINATE"|"$FM_AUTH_STATUS_UNREADABLE") exit 4 ;;
  esac
}

# --- reconcile ---------------------------------------------------------------

cmd_reconcile() {  # <auth-id> --observed applied|not-applied --evidence <ref>
  local id=$1; shift
  local observed='' evidence=''
  local rec state rc now
  while [ $# -gt 0 ]; do
    case $1 in
      --observed) observed=${2:-}; shift 2 || die "--observed needs a value" 2 ;;
      --evidence) evidence=${2:-}; shift 2 || die "--evidence needs a value" 2 ;;
      *) die "unexpected argument '$1'" 2 ;;
    esac
  done
  [ -n "$id" ] || die "reconcile needs an authorization id" 2
  case $observed in
    applied|not-applied) ;;
    *) die "reconcile needs --observed applied|not-applied" 2 ;;
  esac
  # The evidence pointer is required, because a reconciliation with no evidence
  # is a guess promoted to a fact - the same move this whole mechanism refuses
  # everywhere else.
  [ -n "$evidence" ] || die "reconcile needs --evidence naming what was observed" 2

  if ! claim_acquire "$id"; then
    claim_reclaim_gone "$id" \
      || unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
        "the spender claim for $id is live or could not be observed as gone"
  fi

  auth_read "$id"; rc=$?
  case $rc in
    3) refuse "$FM_AUTH_TOKEN_NONE" "no authorization $id exists" ;;
    4) unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" "authorization $id could not be read" ;;
  esac
  rec=$AUTH_RECORD
  state=$(printf '%s' "$rec" | jq -r '.state // ""')
  [ "$state" = spending ] \
    || refuse "$FM_AUTH_TOKEN_VOID" \
      "authorization $id is $state; only an indeterminate spend needs reconciling"

  now=$(now_iso)
  if [ "$observed" = applied ]; then
    rec=$(printf '%s' "$rec" | jq --arg n "$now" --arg e "$evidence" \
      '.state = "spent" | .spend.outcome = "applied" | .spend.finished = $n
       | .spend.evidence = $e | .updated = $n
       | .history += [{at:$n, event:"reconciled", detail:("applied: " + $e)}]')
  else
    rec=$(printf '%s' "$rec" | jq --arg n "$now" --arg e "$evidence" \
      '.state = "granted" | .spend = null | .updated = $n
       | .history += [{at:$n, event:"reconciled", detail:("not-applied: " + $e)}]')
  fi
  auth_write "$id" "$rec" \
    || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the reconciliation of $id could not be recorded"
  claim_release
  printf 'reconciled: %s is now %s\n' "$id" \
    "$(fm_auth_reported_status "$(printf '%s' "$rec" | jq -r '.state')")"
}

# --- list --------------------------------------------------------------------
#
# A partial enumeration is could-not-observe, never a short list. An absent store
# is genuinely empty and says so with a count rather than with silence, because
# silence is what an unreadable store would also look like.
cmd_list() {
  local f id state count=0 failed=0
  if [ ! -d "$AUTH_DIR" ]; then
    printf 'count=0\n'
    return 0
  fi
  if [ ! -r "$AUTH_DIR" ] || [ ! -x "$AUTH_DIR" ]; then
    unobserved "$FM_AUTH_TOKEN_ENUM_UNOBSERVED" \
      "the authorization store could not be enumerated, so this is not an empty list"
  fi
  for f in "$AUTH_DIR"/*.json; do
    [ -e "$f" ] || continue
    id=$(basename "$f" .json)
    if auth_read "$id"; then
      state=$(fm_auth_reported_status "$(printf '%s' "$AUTH_RECORD" | jq -r '.state // ""')")
    else
      state=$FM_AUTH_STATUS_UNREADABLE
      failed=1
    fi
    printf '%s\t%s\n' "$id" "$state"
    count=$((count + 1))
  done
  printf 'count=%s\n' "$count"
  [ "$failed" -eq 0 ] || unobserved "$FM_AUTH_TOKEN_ENUM_UNOBSERVED" \
    "at least one authorization could not be read, so this listing is incomplete"
}

# --- entry -------------------------------------------------------------------

command -v jq >/dev/null 2>&1 || die "jq is required" 4

[ $# -gt 0 ] || { usage; exit 2; }
CMD=$1; shift
if [ "$CMD" = spend ] || [ "$CMD" = reconcile ]; then
  if [ "${FM_AUTH_OWNED_GROUP:-}" != "${BASHPID:-$$}" ]; then
    command -v perl >/dev/null 2>&1 || die "perl is required for process-group ownership" 4
    exec perl -e '
      defined(my $pid = fork) or exit 125;
      if ($pid == 0) {
        setpgrp(0, 0) or exit 125;
        $ENV{FM_AUTH_OWNED_GROUP} = $$;
        exec @ARGV;
        exit 125;
      }
      waitpid($pid, 0) == $pid or exit 125;
      my $status = $?;
      exit(128 + ($status & 127)) if $status & 127;
      exit($status >> 8);' "$0" "$CMD" "$@"
  fi
  [ "${FM_AUTH_OWNED_GROUP:-}" = "${BASHPID:-$$}" ] \
    || die "authorization command does not own its process group" 4
  unset FM_AUTH_OWNED_GROUP
fi
case $CMD in
  mint) cmd_mint "${1:-}" ;;
  spend) [ $# -gt 0 ] || die "spend needs an authorization id" 2
         cmd_spend "$@" ;;
  status) cmd_status "${1:-}" ;;
  reconcile) [ $# -gt 0 ] || die "reconcile needs an authorization id" 2
             cmd_reconcile "$@" ;;
  list) cmd_list ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
