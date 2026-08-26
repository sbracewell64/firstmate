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
# THE AUTHORITY NAMES THE ACT. A mint declares a typed effect plan and the plan
# is part of the authorization identity; a spend CONSTRUCTS the act from that
# plan and performs it. A caller never supplies the command, the executable, the
# venue, the ref, or the mode. bin/fm-landing-authorization-lib.sh's header is
# the single owner of that contract, including the two effect kinds and every
# field each one carries.
#
# USAGE
#   fm-landing-authorization.sh mint <request-id> --effect pr-merge
#                                    --method squash|merge|rebase [--delete-branch]
#                                    [--assert-repo <owner/name>] [--assert-pr <n>]
#                                    [--assert-head <sha>]
#   fm-landing-authorization.sh mint <request-id> --effect local-fast-forward
#                                    --project <path> --target-branch <name>
#                                    [--assert-head <sha>]
#       Mint (or return) the authorization the ruled request grants for exactly
#       that act. Idempotent on the authorization identity: the same ruling, the
#       same head, and the same plan always reproduce the same id, so a duplicate
#       wake converges on one authority. Every `--assert-*` value is a redundant
#       assertion: it must equal the value this owner derived, and it can only
#       agree or refuse - it never chooses.
#
#   fm-landing-authorization.sh spend <auth-id> --head <sha> [--receipt <path>]
#                                     [--assert-act -- <command> [args...]]
#       Perform this authority's own act at most once. Refuses unless the head the
#       ruling approved, the head the caller states, and the head the forge
#       currently reports are all the same value, and unless the effect plan still
#       re-observes as the act it names. `--assert-act` states the act the caller
#       believes it is authorizing; a difference from the authority-derived act
#       refuses before any mutation. `--receipt` names a file this owner writes
#       immediately before the act, so a caller can tell an act that ran from an
#       authority that was already spent.
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

# Four-valued, and the caller must keep the four apart:
#   0 and RECORD set   readable
#   3                  no such file - genuinely absent
#   4                  present and unreadable, or not this schema
#   5                  readable as a record, but its effect plan does not
#                      determine an act - AUTH_PLAN_DEFECT names why
#
# The plan is parsed here rather than at the act, so no path in this file can
# reach a mutation holding a record whose plan was never validated.
AUTH_RECORD=
AUTH_RAW=
AUTH_PLAN_DEFECT=
AUTH_PLAN_RC=0
auth_read() {  # <auth-id>
  local expected=$1 path raw schema stored request comment verdict item project repo pr head computed
  local plan plan_rc stored_effect computed_effect
  AUTH_PLAN_DEFECT=
  AUTH_PLAN_RC=0
  AUTH_RAW=
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
  # Everything above is the record's SHAPE, and it passed. AUTH_RAW is published
  # from here on so a caller that reaches the plan defect below can still read
  # what the record claims - see ruling_unspent, the one caller that needs it.
  AUTH_RAW=$raw

  # The effect plan is deliberately NOT part of the shape check above. A record
  # carrying none is not malformed; it is a record from before the effect plan
  # existed, and calling that unreadable would hide the one repair that fixes it.
  # It is validated and re-digested here instead, so a record whose plan no longer
  # determines an act is reported as that rather than as a generic identity
  # mismatch: the two are different repairs.
  plan=$(printf '%s' "$raw" | jq -c '.effect') || return 4
  # Parsed OUTSIDE a command substitution on purpose: the parse records the defect
  # in a global, and a subshell would discard it, leaving a refusal that names
  # nothing to repair.
  fm_auth_plan_parse "$plan"; plan_rc=$?
  if [ "$plan_rc" -ne 0 ]; then
    AUTH_PLAN_DEFECT=$FM_AUTH_PLAN_DEFECT
    AUTH_PLAN_RC=$plan_rc
    return 5
  fi
  computed_effect=$(fm_auth_plan_canonical_digest) || return 4
  stored_effect=$(printf '%s' "$raw" | jq -r '.effect.digest')
  [ "$stored_effect" = "$computed_effect" ] || return 4

  computed=$(fm_auth_id "$request" "$comment" "$verdict" "$item" "$project" "$repo" "$pr" "$head" "$computed_effect") \
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
    unobserved "$FM_AUTH_TOKEN_ABSENT" \
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
  # fm-retrieval-audit: not-a-collection - this reads one pull request named by repository and number.
  # fm-retrieval-audit: conservative-negative - a failed head read returns could-not-observe to the caller, which stops the authorized action and preserves the unspent authorization.
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
  if printf '%s\n' "$pid" > "$dir/owner-pid" \
    && printf '%s\n' "$identity" > "$dir/owner-identity" \
    && printf '%s\n' "$group" > "$dir/owner-group"; then
    :
  else
    rm -f "$dir/owner-pid" "$dir/owner-identity" "$dir/owner-group"
    rmdir "$dir" 2>/dev/null
    return 1
  fi
  CLAIM=$dir
  trap claim_release EXIT
  trap 'claim_terminate INT' INT
  trap 'claim_terminate TERM' TERM
  return 0
}

claim_terminate() {  # <signal>
  local signal=$1 group=${BASHPID:-$$}
  trap - EXIT INT TERM
  kill -s "$signal" -- "-$group" 2>/dev/null || exit 4
  exit 4
}

claim_release() {
  [ -n "$CLAIM" ] || return 0
  rm -f "$CLAIM/owner-pid" "$CLAIM/owner-identity" "$CLAIM/owner-group"
  rmdir "$CLAIM" 2>/dev/null || true
  CLAIM=
}

claim_group_state() {  # <process-group>
  local rc
  perl -e '
    my $marker = "FM_AUTH_GROUP_PROBE";
    my $group = shift;
    exit 0 if kill 0, -$group;
    exit 3 if $!{ESRCH};
    exit 5 if $!{EPERM};
    exit 4;' "$1"
  rc=$?
  case $rc in
    0|5) printf 'live\n' ;;
    3) printf 'gone\n' ;;
    *) printf 'unobserved\n' ;;
  esac
}

claim_owner_state() {  # <auth-id>
  local dir pid identity group current current_group proc_root
  dir=$(auth_claim_path "$1") || { printf 'unobserved\n'; return; }
  if pid=$(cat "$dir/owner-pid" 2>/dev/null) \
    && identity=$(cat "$dir/owner-identity" 2>/dev/null) \
    && group=$(cat "$dir/owner-group" 2>/dev/null); then
    :
  else
    printf 'unobserved\n'
    return
  fi
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
  claim_group_state "$group"
}

CLAIM_OWNER_STATE=
claim_reclaim_gone() {  # <auth-id>
  local dir
  CLAIM_OWNER_STATE=$(claim_owner_state "$1")
  [ "$CLAIM_OWNER_STATE" = gone ] || return 1
  dir=$(auth_claim_path "$1") || return 1
  rm -f "$dir/owner-pid" "$dir/owner-identity" "$dir/owner-group" || return 1
  rmdir "$dir" 2>/dev/null || return 1
  claim_acquire "$1"
}

# --- the executable an effect kind is performed by ----------------------------
#
# Resolved ONCE, here, at the owning boundary, and pinned into the plan as an
# absolute path plus a content digest. The name comes from the contract, never
# from a caller, and the containing directory is resolved so a later symlink
# change cannot move the pinned path. The digest is what carries identity: a
# different file at the same path refuses at effect time rather than running.
EXEC_PATH=
EXEC_DIGEST=
resolve_executable() {  # <name>
  local name=$1 found dir base digest
  EXEC_PATH=
  EXEC_DIGEST=
  found=$(command -v "$name" 2>/dev/null) || return 1
  case $found in
    /*) ;;
    *) return 1 ;;
  esac
  base=${found##*/}
  dir=${found%/*}
  [ -n "$dir" ] || dir=/
  dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  case $dir in
    */) found="$dir$base" ;;
    *) found="$dir/$base" ;;
  esac
  [ -f "$found" ] && [ -x "$found" ] || return 1
  digest=$(fm_auth_digest < "$found") || return 1
  fm_auth_plan_digest_valid "$digest" || return 1
  EXEC_PATH=$found
  EXEC_DIGEST=$digest
  return 0
}

# A caller-supplied value is admitted only as a redundant assertion. It is
# compared to the value this owner derived and can only agree or refuse.
assert_equal() {  # <asserted-or-empty> <derived> <what>
  [ -n "${1:-}" ] || return 0
  fm_auth_credential_bearing "$1" \
    && refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
      "the asserted $3 carries credential-bearing input, which is refused before it can reach a landing act"
  [ "$1" = "$2" ] || refuse "$FM_AUTH_TOKEN_ACT_MISMATCH" \
    "the caller asserts $3 '$1'; this authority derives '$2', and an assertion may only agree"
  return 0
}

# --- mint --------------------------------------------------------------------

# The plan a mint declares, built from what the ruling establishes plus the
# closed, mutation-significant choices the chokepoint makes at mint time. Nothing
# here is re-openable at spend: the plan is digested into the authorization
# identity, so a different plan is a different authority.
MINT_EFFECT=
mint_plan() {  # <kind> <repo> <pr-number> <head> <method> <delete-branch> <project> <target-branch>
  local kind=$1 repo=$2 number=$3 head=$4 method=$5 delete=$6 project=$7 branch=$8
  local exec_name identity plan digest rc=0
  MINT_EFFECT=
  exec_name=$(fm_auth_effect_executable_name "$kind") \
    || unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" \
      "'$kind' is not an effect this authority contract performs"
  resolve_executable "$exec_name" \
    || unobserved "$FM_AUTH_TOKEN_EXEC_UNOBSERVED" \
      "'$exec_name' could not be resolved to one exact executable, so the act this authority would permit could not be pinned"

  case $kind in
    pr-merge)
      plan=$(jq -n --arg kind "$kind" --arg repo "$repo" --arg pr "$number" \
        --arg head "$head" --arg method "$method" --arg delete "$delete" \
        --arg name "$exec_name" --arg path "$EXEC_PATH" --arg digest "$EXEC_DIGEST" \
        '{kind:$kind,venue:"github",repo:$repo,pr:$pr,head:$head,method:$method,
          delete_branch:($delete == "yes"),force:false,
          executable_name:$name,executable_path:$path,executable_digest:$digest}') \
        || die "the effect plan could not be constructed" 4
      ;;
    local-fast-forward)
      identity=$(cd "$project" 2>/dev/null && pwd -P) \
        || unobserved "$FM_AUTH_TOKEN_TARGET_UNOBSERVED" \
          "the project at '$project' could not be resolved to one exact directory, so the act this authority would permit could not be pinned"
      plan=$(jq -n --arg kind "$kind" --arg project "$project" --arg identity "$identity" \
        --arg ref "refs/heads/$branch" --arg head "$head" \
        --arg name "$exec_name" --arg path "$EXEC_PATH" --arg digest "$EXEC_DIGEST" \
        '{kind:$kind,venue:"local",project:$project,project_identity:$identity,
          target_ref:$ref,head:$head,mode:"ff-only",force:false,
          executable_name:$name,executable_path:$path,executable_digest:$digest}') \
        || die "the effect plan could not be constructed" 4
      ;;
    *)
      unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" \
        "'$kind' is not an effect this authority contract performs" ;;
  esac

  fm_auth_plan_parse "$plan"; rc=$?
  case $rc in
    0) ;;
    3) refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
         "this landing plan carries credential-bearing input: $FM_AUTH_PLAN_DEFECT" ;;
    2) unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" "$FM_AUTH_PLAN_DEFECT" ;;
    *) unobserved "$FM_AUTH_TOKEN_PLAN_INCOMPLETE" "$FM_AUTH_PLAN_DEFECT" ;;
  esac
  digest=$(fm_auth_plan_canonical_digest) \
    || die "the effect plan's identity could not be computed" 4
  MINT_EFFECT=$(printf '%s' "$plan" | jq -c --arg d "$digest" '. + {digest:$d}') \
    || die "the effect plan could not be recorded" 4
  MINT_EFFECT_DIGEST=$digest
}

MINT_EFFECT_DIGEST=

# ONE RULING AUTHORIZES ONE LANDING, and this is where that is larger than
# one-use. The exactly-once guarantee lives on a RECORD, and the effect plan is
# part of a record's identity, so a second plan for the same ruling and head is a
# second record with its own single use. That is right for identity and would be
# wrong for authority, so an approval whose landing already happened - or may
# have happened - grants nothing further and spends nothing further.
#
# Asked at BOTH the mint and the act, because a sibling minted before the first
# landing would pass a mint-only check and still be granted afterwards.
#
# It reads other authorization records, which resets the parsed-plan globals, so
# every caller runs it before building its own act.
ruling_unspent() {  # <request-id> <head> <this-id>
  local rid=$1 head=$2 self=$3 f other state rc record
  [ -d "$AUTH_DIR" ] || return 0
  if [ ! -r "$AUTH_DIR" ] || [ ! -x "$AUTH_DIR" ]; then
    unobserved "$FM_AUTH_TOKEN_ENUM_UNOBSERVED" \
      "the authorization store could not be enumerated, so whether this ruling already landed could not be observed"
  fi
  for f in "$AUTH_DIR"/*.json; do
    [ -e "$f" ] || continue
    other=${f##*/}
    other=${other%.json}
    [ "$other" != "$self" ] || continue
    auth_read "$other"; rc=$?
    case $rc in
      0) record=$AUTH_RECORD ;;
      # A record whose SHAPE is intact and whose effect plan is not is a record
      # from before this contract, and this file's own refusals make it
      # unspendable, so it can never itself perform a landing. What it can still
      # answer is the only question asked here - whether this ruling was landed
      # under it - and reading that from the record's own claim is the safe
      # direction: it can produce a refusal and never a landing. Treating every
      # such record as could-not-observe instead would stop every governed
      # landing in a home that holds one, which is a repair to demand of an
      # operator, not a state to wedge them in.
      #
      # The claim is not identity-verified, and it does not need to be: a store
      # an attacker can edit is a store they can delete from, which this guard
      # never claimed to survive. What it survives is ordinary duplication.
      5) record=$AUTH_RAW ;;
      *)
        unobserved "$FM_AUTH_TOKEN_ENUM_UNOBSERVED" \
          "authorization $other could not be read, so whether this ruling already landed could not be observed; repair or retire that record before landing anything in this home" ;;
    esac
    [ "$(printf '%s' "$record" | jq -r '.request_id')" = "$rid" ] || continue
    [ "$(printf '%s' "$record" | jq -r '.grant.head')" = "$head" ] || continue
    state=$(printf '%s' "$record" | jq -r '.state')
    case $state in
      spent|spending)
        refuse "$FM_AUTH_TOKEN_RULING_EXHAUSTED" \
          "the ruling on $rid at $head has already been landed under $other ($(fm_auth_reported_status "$state")); one approval grants one landing" ;;
    esac
  done
  return 0
}

cmd_mint() {  # <request-id> --effect <kind> [...]
  local rid=$1; shift
  local kind='' method='' delete=no project='' branch=''
  local assert_repo='' assert_pr='' assert_head='' assert_project=''
  local state comment verdict class item project_name repo pr head id rec now existing rc
  local locator owner_repo number declared
  [ -n "$rid" ] || die "mint needs a request id" 2

  while [ $# -gt 0 ]; do
    case $1 in
      --effect) kind=${2:-}; shift 2 || die "--effect needs a value" 2 ;;
      --method) method=${2:-}; shift 2 || die "--method needs a value" 2 ;;
      --delete-branch) delete=yes; shift ;;
      --project) project=${2:-}; shift 2 || die "--project needs a value" 2 ;;
      --target-branch) branch=${2:-}; shift 2 || die "--target-branch needs a value" 2 ;;
      --assert-repo) assert_repo=${2:-}; shift 2 || die "--assert-repo needs a value" 2 ;;
      --assert-pr) assert_pr=${2:-}; shift 2 || die "--assert-pr needs a value" 2 ;;
      --assert-head) assert_head=${2:-}; shift 2 || die "--assert-head needs a value" 2 ;;
      --assert-project) assert_project=${2:-}; shift 2 || die "--assert-project needs a value" 2 ;;
      *) die "unexpected argument '$1'" 2 ;;
    esac
  done
  [ -n "$kind" ] \
    || die "mint needs --effect naming the act this authority permits; an authority with no effect plan authorizes no act" 2

  # Credential-bearing mechanism input is refused HERE, before any of it is used
  # to resolve a directory, quoted into a refusal, or written to a record. A
  # value that had to be handled carefully to be safe was never a landing
  # mechanism field this owner should be holding.
  for declared in "$kind" "$method" "$project" "$branch" \
    "$assert_repo" "$assert_pr" "$assert_head" "$assert_project"; do
    [ -n "$declared" ] || continue
    if fm_auth_credential_bearing "$declared"; then
      refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
        "a landing effect plan was declared with credential-bearing input, which is refused before it can reach a landing act"
    fi
  done

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
  project_name=$(printf '%s' "$CORRELATION" | jq -r '.identity.project // ""')
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
  locator=$(fm_auth_pr_locator "$pr") \
    || refuse "$FM_AUTH_TOKEN_NO_PR" \
      "request $rid names no pull request to land, so its head could not be observed at use"
  owner_repo=${locator%% *}
  number=${locator##* }

  # THE PLAN'S VENUE, TARGET, AND HEAD COME FROM THE RULING, NOT FROM THE CALLER.
  # Only the choices a ruling cannot express - which merge method, which local
  # project directory and branch - are declared here, each against a closed
  # vocabulary, and every caller-supplied value is checked as a redundant
  # assertion rather than used as the source.
  assert_equal "$assert_head" "$head" "landing head"
  case $kind in
    pr-merge)
      assert_equal "$assert_repo" "$owner_repo" "landing repository"
      assert_equal "$assert_pr" "$number" "pull request number"
      [ -z "$project" ] && [ -z "$branch" ] \
        || die "--project and --target-branch describe a local fast-forward, not a pull-request merge" 2
      [ -n "$method" ] \
        || die "a pr-merge effect plan needs --method squash|merge|rebase; the merge method changes what lands" 2
      fm_auth_plan_member_of "$method" "$FM_AUTH_MERGE_METHODS" \
        || die "--method must be one of: $(printf '%s' "$FM_AUTH_MERGE_METHODS" | tr '\n' ' ')" 2
      ;;
    local-fast-forward)
      [ -z "$method" ] \
        || die "--method describes a pull-request merge, not a local fast-forward" 2
      [ -n "$project" ] \
        || die "a local-fast-forward effect plan needs --project naming the checkout it lands in" 2
      [ -n "$branch" ] \
        || die "a local-fast-forward effect plan needs --target-branch naming the ref it advances" 2
      assert_equal "$assert_project" "$project" "landing project"
      ;;
    *)
      unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" \
        "'$kind' is not an effect this authority contract performs" ;;
  esac
  mint_plan "$kind" "$owner_repo" "$number" "$head" "$method" "$delete" "$project" "$branch"

  id=$(fm_auth_id "$rid" "$comment" "$verdict" "$item" "$project_name" "$repo" "$pr" "$head" "$MINT_EFFECT_DIGEST") \
    || die "the authorization identity could not be computed" 4

  claim_acquire "$id" \
    || refuse "$FM_AUTH_TOKEN_IN_FLIGHT" \
      "another operation on $id holds the claim"

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
    5) plan_defect_stop "$id" ;;
  esac

  # Only reached when this exact plan has no record yet, which is the one moment
  # a second authority against an already-landed approval could be created.
  ruling_unspent "$rid" "$head" "$id"

  now=$(now_iso)
  rec=$(fm_auth_record_new "$id" "$rid" "$comment" "$verdict" "$item" "$project_name" \
    "$repo" "$pr" "$head" "$now" "$MINT_EFFECT") \
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

# A record whose plan does not determine an act, reported as the defect it is.
# Unknown, malformed, unsupported, and credential-bearing are kept apart because
# they are different repairs: one closes a vocabulary gap, one repairs a record,
# and one is a security refusal.
plan_defect_stop() {  # <auth-id>
  local id=$1
  case $AUTH_PLAN_RC in
    3) refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
         "authorization $id carries credential-bearing input: $AUTH_PLAN_DEFECT" ;;
    2) unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" \
         "authorization $id does not determine an act: $AUTH_PLAN_DEFECT" ;;
    *) unobserved "$FM_AUTH_TOKEN_PLAN_INCOMPLETE" \
         "authorization $id does not determine an act: $AUTH_PLAN_DEFECT" ;;
  esac
}

# --- the plan, re-read at effect time ----------------------------------------
#
# Everything in the plan that can move between mint and use is read again here,
# as late as the sequence allows and always before the intent record. What could
# not be read stops the act as could-not-observe; what was read and disagrees is
# a refusal. Neither silently retargets the act at whatever is there now.
plan_reobserve() {  # <auth-id>
  local id=$1 digest branch identity present ancestor
  if [ ! -f "$FM_AUTH_PLAN_EXEC_PATH" ] || [ ! -x "$FM_AUTH_PLAN_EXEC_PATH" ]; then
    refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
      "authorization $id performs its act with $FM_AUTH_PLAN_EXEC_PATH, which is no longer an executable file"
  fi
  digest=$(fm_auth_digest < "$FM_AUTH_PLAN_EXEC_PATH") \
    || unobserved "$FM_AUTH_TOKEN_EXEC_UNOBSERVED" \
      "the executable $FM_AUTH_PLAN_EXEC_PATH could not be read, so whether it is the one this authority pinned could not be observed"
  [ "$digest" = "$FM_AUTH_PLAN_EXEC_DIGEST" ] \
    || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
      "the file at $FM_AUTH_PLAN_EXEC_PATH is not the executable authorization $id pinned; it now digests to $digest"

  case $FM_AUTH_PLAN_KIND in
    local-fast-forward)
      identity=$(cd "$FM_AUTH_PLAN_PROJECT" 2>/dev/null && pwd -P) \
        || unobserved "$FM_AUTH_TOKEN_TARGET_UNOBSERVED" \
          "the project at $FM_AUTH_PLAN_PROJECT could not be resolved, so the target of authorization $id could not be observed"
      [ "$identity" = "$FM_AUTH_PLAN_PROJECT_IDENTITY" ] \
        || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
          "$FM_AUTH_PLAN_PROJECT now resolves to $identity, not the $FM_AUTH_PLAN_PROJECT_IDENTITY authorization $id was bound to"
      branch=$("$FM_AUTH_PLAN_EXEC_PATH" -C "$FM_AUTH_PLAN_PROJECT" symbolic-ref --quiet --short HEAD 2>/dev/null) \
        || unobserved "$FM_AUTH_TOKEN_TARGET_UNOBSERVED" \
          "which branch $FM_AUTH_PLAN_PROJECT has checked out could not be observed, so the ref this act advances could not be confirmed"
      [ "refs/heads/$branch" = "$FM_AUTH_PLAN_TARGET_REF" ] \
        || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
          "authorization $id advances $FM_AUTH_PLAN_TARGET_REF, but $FM_AUTH_PLAN_PROJECT has refs/heads/$branch checked out"
      present=$("$FM_AUTH_PLAN_EXEC_PATH" -C "$FM_AUTH_PLAN_PROJECT" rev-parse --verify --quiet "$FM_AUTH_PLAN_HEAD^{commit}" 2>/dev/null) \
        || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
          "the commit $FM_AUTH_PLAN_HEAD authorization $id lands is not present in $FM_AUTH_PLAN_PROJECT"
      [ "$present" = "$FM_AUTH_PLAN_HEAD" ] \
        || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
          "$FM_AUTH_PLAN_HEAD resolves to $present in $FM_AUTH_PLAN_PROJECT, so it is not the object this authority names"
      ancestor=0
      "$FM_AUTH_PLAN_EXEC_PATH" -C "$FM_AUTH_PLAN_PROJECT" merge-base --is-ancestor \
        "$FM_AUTH_PLAN_TARGET_REF" "$FM_AUTH_PLAN_HEAD" 2>/dev/null || ancestor=$?
      [ "$ancestor" -eq 0 ] \
        || refuse "$FM_AUTH_TOKEN_PLAN_STALE" \
          "$FM_AUTH_PLAN_TARGET_REF is no longer an ancestor of $FM_AUTH_PLAN_HEAD in $FM_AUTH_PLAN_PROJECT, so the act authorization $id names is not a fast-forward"
      ;;
  esac
}

# The caller's asserted act, admitted only as a redundant assertion. It is
# compared element by element against the act this owner derived; a difference
# refuses before the intent record, so a substituted executable, venue, ref, or
# mode performs nothing at all.
assert_act() {  # <auth-id> <asserted...>
  local id=$1; shift
  local i=0 asserted derived
  for asserted in "$@"; do
    if fm_auth_credential_bearing "$asserted"; then
      refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
        "the act asserted for $id carries credential-bearing input at element $i, which is refused before it can reach a landing act"
    fi
    i=$((i + 1))
  done
  if [ "$#" -ne "${#FM_AUTH_ACT[@]}" ]; then
    refuse "$FM_AUTH_TOKEN_ACT_MISMATCH" \
      "the caller asserts an act of $# argument(s); authorization $id derives one of ${#FM_AUTH_ACT[@]} from its effect plan"
  fi
  i=0
  for asserted in "$@"; do
    derived=${FM_AUTH_ACT[$i]}
    if [ "$asserted" != "$derived" ]; then
      # The executable is named by its pinned path, and the caller is allowed to
      # have named it by the name this plan recorded - that name is the
      # authority's own value, not an ambient resolution of it.
      if [ "$i" -eq 0 ] && [ "$asserted" = "$FM_AUTH_PLAN_EXEC_NAME" ]; then
        i=$((i + 1))
        continue
      fi
      refuse "$FM_AUTH_TOKEN_ACT_MISMATCH" \
        "the caller asserts '$asserted' at element $i; authorization $id derives '$derived' from its effect plan, and an assertion may only agree"
    fi
    i=$((i + 1))
  done
}

cmd_spend() {  # <auth-id> --head <sha> [--receipt <path>] [--assert-act -- <command>...]
  local id=$1; shift
  local want_head='' receipt='' asserted=0
  local rec state admit outcome_state recorded
  local rid corr_state corr_comment pr locator owner number observed
  local grant_head act_digest now rc plan
  local -a assertion=()

  while [ $# -gt 0 ]; do
    case $1 in
      --head) want_head=${2:-}; shift 2 || die "--head needs a value" 2 ;;
      --receipt) receipt=${2:-}; shift 2 || die "--receipt needs a value" 2 ;;
      --assert-act)
        shift
        [ "${1:-}" = -- ] \
          || die "--assert-act must be followed by -- and the act the caller expects" 2
        shift
        asserted=1
        assertion=("$@")
        break ;;
      # The withdrawn form. A caller-supplied command is no longer the act: the
      # authority builds its own from its effect plan. Reinterpreting the old
      # argv as an assertion silently would let a stale caller believe it still
      # chooses the act, so this refuses and names the replacement.
      --)
        die "spend no longer performs a caller-supplied command; the authority performs the act its own effect plan names, and the act you expected is stated as '--assert-act -- <command>...'" 2 ;;
      *) die "unexpected argument '$1'" 2 ;;
    esac
  done
  [ -n "$id" ] || die "spend needs an authorization id" 2
  [ -n "$want_head" ] || die "spend needs --head, the head the caller intends to land" 2
  [ "$asserted" -eq 0 ] || [ "${#assertion[@]}" -gt 0 ] \
    || refuse "$FM_AUTH_TOKEN_NO_ACT" \
      "--assert-act was given no act to assert, so there is nothing to compare against this authority"

  if ! claim_acquire "$id"; then
    auth_read "$id"; rc=$?
    if [ "$rc" -eq 0 ] \
      && [ "$(printf '%s' "$AUTH_RECORD" | jq -r '.state // ""')" = spending ]; then
      unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
        "a spend of $id began and recorded no outcome, so whether the act happened is unknown; reconcile it from an observation before any further attempt"
    fi
    refuse "$FM_AUTH_TOKEN_IN_FLIGHT" \
      "another spend of $id holds the claim; one authority is spent by one caller"
  fi

  auth_read "$id"; rc=$?
  case $rc in
    3) refuse "$FM_AUTH_TOKEN_NONE" "no authorization $id exists" ;;
    4) unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
         "authorization $id could not be read, so whether it is spent is unknown" ;;
    5) plan_defect_stop "$id" ;;
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

  # ONE APPROVAL, ONE LANDING. The effect plan is part of the identity, so a
  # different plan is a different authorization id - correct for identity, and
  # wrong for authority if it let one approval be landed twice. This is the same
  # question the mint asks, asked again at the act, because an authority minted
  # before the sibling landed would otherwise still be granted.
  #
  # It reads other records, which resets the parsed-plan globals, so it runs
  # BEFORE this authority's own act is built below.
  ruling_unspent "$rid" "$grant_head" "$id"

  # THE ACT IS BUILT HERE, from this authority's own plan, and from the record
  # this spend already read rather than from anything a caller offered.
  plan=$(printf '%s' "$rec" | jq -c '.effect') \
    || unobserved "$FM_AUTH_TOKEN_PLAN_INCOMPLETE" \
      "the effect plan of $id could not be re-read before the act"
  fm_auth_plan_parse "$plan"; rc=$?
  case $rc in
    0) ;;
    3) refuse "$FM_AUTH_TOKEN_CREDENTIAL" \
         "authorization $id carries credential-bearing input: $FM_AUTH_PLAN_DEFECT" ;;
    2) unobserved "$FM_AUTH_TOKEN_PLAN_UNSUPPORTED" "$FM_AUTH_PLAN_DEFECT" ;;
    *) unobserved "$FM_AUTH_TOKEN_PLAN_INCOMPLETE" "$FM_AUTH_PLAN_DEFECT" ;;
  esac
  [ "${#FM_AUTH_ACT[@]}" -gt 0 ] \
    || unobserved "$FM_AUTH_TOKEN_PLAN_INCOMPLETE" \
      "the effect plan of $id determined no act to perform"

  # The plan must still describe the grant it was minted against. A record whose
  # plan and grant disagree names two different landings, and neither of them is
  # the one this authority is.
  [ "$FM_AUTH_PLAN_HEAD" = "$grant_head" ] \
    || refuse "$FM_AUTH_TOKEN_PLAN_FOREIGN" \
      "authorization $id approves $grant_head and its effect plan lands $FM_AUTH_PLAN_HEAD"

  # A pull-request plan addresses the same pull request the grant does, or it is
  # a plan for somebody else's landing carried under this approval.
  if [ "$FM_AUTH_PLAN_KIND" = pr-merge ]; then
    { [ "$FM_AUTH_PLAN_REPO" = "$owner" ] && [ "$FM_AUTH_PLAN_PR" = "$number" ]; } \
      || refuse "$FM_AUTH_TOKEN_PLAN_FOREIGN" \
        "authorization $id is granted for $owner#$number and its effect plan merges $FM_AUTH_PLAN_REPO#$FM_AUTH_PLAN_PR"
  fi

  # The caller's assertion is checked before the intent record, so a substituted
  # executable, venue, ref, or mode performs nothing and leaves the authority
  # unspent.
  if [ "$asserted" -eq 1 ]; then
    assert_act "$id" "${assertion[@]}"
  fi

  # Everything the plan pinned that could have moved, read again at the last
  # moment before the act.
  plan_reobserve "$id"

  # The receipt is proven writable BEFORE the intent record, so a caller whose
  # receipt path is unusable learns that from an authority that is still granted
  # rather than from one that is indeterminate.
  if [ -n "$receipt" ]; then
    : > "$receipt" 2>/dev/null \
      || unobserved "$FM_AUTH_TOKEN_RECEIPT_UNOBSERVED" \
        "the act receipt at $receipt could not be created, so whether the act ran could not have been observed"
    [ ! -s "$receipt" ] \
      || unobserved "$FM_AUTH_TOKEN_RECEIPT_UNOBSERVED" \
        "the act receipt at $receipt could not be emptied before the act, so a stale receipt could be read as this act"
  fi

  # INTENT BEFORE ACT. Everything after this point may crash, and the durable
  # record must already say a spend began, because the alternative is a landing
  # nothing remembers. The digest recorded is of the act this AUTHORITY derived,
  # which is the only act that can run.
  now=$(now_iso)
  act_digest=$(printf '%s\n' "${FM_AUTH_ACT[@]}" | fm_auth_digest) || act_digest=
  rec=$(printf '%s' "$rec" | jq --arg n "$now" --arg d "$act_digest" --arg h "$observed" \
    '.state = "spending"
     | .spend = {started:$n, act_digest:$d, observed_head:$h, outcome:null, finished:null, evidence:null}
     | .updated = $n
     | .history += [{at:$n, event:"spend-began", detail:$d}]')
  auth_write "$id" "$rec" \
    || unobserved "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the spend of $id could not be recorded before the act, so no act was performed"

  # Written immediately before the act and never after it: a receipt written
  # afterwards could not tell an act that never ran from one that ran and could
  # not report. A receipt that cannot be written stops the act rather than
  # performing a landing whose outcome nothing could have recorded.
  if [ -n "$receipt" ]; then
    printf 'entered\n' > "$receipt" 2>/dev/null \
      || unobserved "$FM_AUTH_TOKEN_RECEIPT_UNOBSERVED" \
        "the act receipt at $receipt could not be written, so no act was performed under $id; reconcile it as not-applied"
  fi

  "${FM_AUTH_ACT[@]}"
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
    3) printf '%s\n' "$FM_AUTH_STATUS_ABSENT"; exit 4 ;;
    # A record whose effect plan does not determine an act cannot say what it
    # would authorize, so it is unreadable AS AN AUTHORITY. The defect is named
    # on stderr so the repair is not left to guesswork.
    4) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE"; exit 4 ;;
    5) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE"
       plan_defect_stop "$id" ;;
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
    if ! claim_reclaim_gone "$id"; then
      if [ "$CLAIM_OWNER_STATE" = live ]; then
        unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
          "the spender process group for $id still exists"
      fi
      unobserved "$FM_AUTH_TOKEN_INDETERMINATE" \
        "the spender process group for $id could not be observed as gone"
    fi
  fi

  auth_read "$id"; rc=$?
  case $rc in
    3) refuse "$FM_AUTH_TOKEN_NONE" "no authorization $id exists" ;;
    4) unobserved "$FM_AUTH_TOKEN_RECORD_UNREADABLE" "authorization $id could not be read" ;;
    5) plan_defect_stop "$id" ;;
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
if [ "$CMD" = mint ] || [ "$CMD" = spend ] || [ "$CMD" = reconcile ]; then
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
  mint) [ $# -gt 0 ] || die "mint needs a request id" 2
        cmd_mint "$@" ;;
  spend) [ $# -gt 0 ] || die "spend needs an authorization id" 2
         cmd_spend "$@" ;;
  status) cmd_status "${1:-}" ;;
  reconcile) [ $# -gt 0 ] || die "reconcile needs an authorization id" 2
             cmd_reconcile "$@" ;;
  list) cmd_list ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
