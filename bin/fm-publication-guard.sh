#!/usr/bin/env bash
# fm-publication-guard.sh - the one chokepoint every remote-changing candidate
# publication this fleet performs must pass, and the one-use authority it spends.
#
# WHAT THIS IS FOR. A candidate reaches the outside world when it is PUSHED. Every
# reviewer, every CI run, every bot and every later ruling is reacting to a head
# that publication already made real, so a permission asked for at the merge is
# asked after the irreversible half already happened. This asks it before, binds
# the answer to one exact head on one exact ref moving from one exact tip, and
# exhausts it by using it.
#
# WHAT IT IS NOT. It is not a second authorization owner: the identity, the
# lifecycle, the state vocabulary and the record shape all come from
# bin/fm-landing-authorization-lib.sh, which landing already spends through. It is
# not a second decision procedure either: bin/fm-publication-seam-lib.sh compiles
# the verdict and this spends it. And it is not a push - it never learns how, and
# the act it wraps is supplied by the caller.
#
# THE SCOPE, said plainly so nothing credits it with more. This governs the
# publications FIRSTMATE ITSELF performs. A human typing `git push`, a provider
# web UI, and no-mistakes' own PushStep each reach the remote without passing
# here; server-side protection is the separate defence for those, and this is
# deliberately not claimed to replace it. What it does close is every path this
# repository owns, plus the external verdict a pre-push integration can consume:
# `prepare` prints the closed typed answer such an integration needs, so the
# semantic decision has one compiler rather than one per caller.
#
# THE TWO EFFECT CLASSES, and why the distinction is the guard's and not the
# caller's. A remote-changing candidate act is one of exactly two things:
#
#   CUSTODY_REPLICATION  durable backup of one exact committed candidate to its
#                        OWN unprotected feature ref, refs/heads/fm/<work-id> on
#                        the work's own venue. It grants NOTHING: no pull request,
#                        no review request, no CI implication, no acceptance, no
#                        landing authorization, no publication-qualified state. It
#                        demands things publication never asks - a clean worktree
#                        including untracked files, the candidate actually checked
#                        out at that exact head and tree, an unprotected ref
#                        derived from the work rather than chosen by the caller,
#                        no force in any form, and a remote ref that is absent or
#                        already equal - and it is not subject to the review it
#                        does not claim, so a candidate under a publication hold
#                        may still be backed up.
#   PUBLICATION_EFFECT   anything that makes the candidate enter the review, CI,
#                        publication or landing lifecycle. Every obligation this
#                        guard already compiled belongs here, unchanged.
#
# `--effect` names the class a caller wants and never settles it. The guard
# verifies the request against observation and REFUSES one the evidence does not
# support rather than quietly reclassifying it, so a caller cannot discover the
# class by trying, and custody is strictly weaker in what it grants while being
# strictly stricter in what it demands. Omitting it means PUBLICATION_EFFECT: the
# stricter class is the default, and every existing caller keeps its obligations.
#
# USAGE
#   fm-publication-guard.sh prepare --repo <dir> --remote <name|url>
#                                   --venue <host/owner/repo> --ref <refs/...>
#                                   --head <sha> --expected-tip <sha|->
#                                   [--tree <sha>] [--item <work-id>]
#                                   [--effect custody|publication] [--dry-run]
#       Compile the eligibility verdict for one exact candidate effect and, when
#       it is permitted, mint the one-use authority that effect must spend.
#
#       --dry-run compiles and prints the SAME verdict and writes nothing. Use it
#       for any probe. A probe that mints is not a probe: `prepare` is only
#       side-effect-free on the paths where it refuses, so a probe written to
#       expect a refusal quietly becomes a mint on the day the refusal stops
#       firing - which is exactly the day nobody wanted a live authority lying
#       around. The identity is deterministic, so a dry run prints the id that
#       WOULD be granted and a later real prepare reproduces it.
#       --expected-tip is required and has no default: a caller that does not
#       know which tip it planned against has not planned against one, and
#       defaulting it to whatever is there now would delete the only check that
#       notices the remote moving.
#
#   fm-publication-guard.sh consume <auth-id> --repo <dir> --remote <name|url>
#                                   -- <command> [args...]
#       Perform <command> at most once under this authority. Everything is
#       re-observed and re-compiled first, because permission granted at
#       commission time is not permission now: a newer hold, a superseding
#       ruling, a bumped policy generation or a remote that moved each make the
#       planned effect address a world that no longer exists.
#
#   fm-publication-guard.sh reconcile <auth-id> --observed applied|not-applied
#                                     --evidence <ref>
#       Resolve an authority consumed without a confirmed effect, from an
#       OBSERVATION of the remote. `not-applied` retires it permanently rather
#       than returning it to the pool; recovery mints a fresh one.
#
#   fm-publication-guard.sh publish --repo <dir> --remote <name|url>
#                                   --venue <host/owner/repo> --ref <refs/...>
#                                   --head <sha> --expected-tip <sha|->
#                                   [--item <work-id>]
#                                   [--effect custody|publication]
#                                   -- <command> [args...]
#       prepare and consume composed into the one operation a caller actually
#       wants: decide, and if permitted perform <command> inside the authority.
#       This is the entry point for a caller that cannot source shell libraries.
#
#   fm-publication-guard.sh retire <auth-id> --reason <text>
#       Retire a still-GRANTED authority that should never be spent - one minted
#       by a probe, or superseded before it was used. It transitions `granted` to
#       `void` and nothing else: the record is preserved whole and gains a
#       timestamped entry saying who retired it and why.
#
#       It refuses a `spent` record and one whose effect is unobserved, because
#       neither is an unused authority: the first records an act that happened,
#       and the second records one that may have. Retiring either would replace
#       evidence with a tidier state, which is the one thing this store exists
#       not to do. An already-retired record is reported and left exactly as it
#       is, so repeating the command cannot accumulate history.
#
#   fm-publication-guard.sh project --repo <dir> --remote <name|url>
#                                   --venue <host/owner/repo> --ref <refs/...>
#                                   --head <sha> [--item <work-id>]
#       READ-ONLY. What state this candidate is actually in, derived from the
#       durable owners that already hold the evidence, plus the one actionable
#       answer that state supports: may the slot holding it be reclaimed?
#
#       The states are explicit and monotonic and NONE IMPLIES THE NEXT:
#       local-only, custody-replicated, review-published, publication-qualified,
#       landing-authorized, landed. Remote custody is not review publication;
#       review publication is not acceptance; acceptance is not landing
#       authority; landing authority is not a completed landing. Each limb is
#       reported with its own three-valued answer so no reader has to infer one
#       from another, and the exit status answers reclaimability: 0 yes, 3 no,
#       4 could not be observed. A slot may be reclaimed only when ls-remote
#       resolves the custody ref to the EXACT candidate head - never because a
#       branch of that name exists.
#
#   fm-publication-guard.sh status <auth-id>
#   fm-publication-guard.sh list
#
# RESULT VOCABULARY, closed. Judge this command by the word it prints, never by
# the exit status alone.
#   ALLOW_EXACT <id> class=<c>    permitted, and this authority is the permission
#                                 for exactly the class named
#   NO_EFFECT_ALREADY_EQUAL       the remote already equals the head. A typed
#                                 NO-EFFECT result: nothing moves and no
#                                 authority is consumed
#   NOT_APPLICABLE                no policy and no ruling govern this candidate;
#                                 it proceeds, and it is REPORTED as ungoverned
#   REFUSE <token>                a verdict was reached and it is no
#   CNO <token>                   no verdict was reached. Never read as either
#                                 neighbour
#
# EXIT CODES
#   0  ALLOW_EXACT, NO_EFFECT_ALREADY_EQUAL, NOT_APPLICABLE, or a completed
#      consume whose effect was confirmed on the remote
#   2  usage error
#   3  REFUSE
#   4  CNO
#
# ENVIRONMENT
#   FM_HOME                operational home (default: repo root)
#   FM_LANDING_AUTH_DIR    authorization store (default: $FM_HOME/data/landing-authorizations)
#   FM_OUTBOUND_DIR        correlation records (default: $FM_HOME/data/outbound-artifacts)
#   FM_CONFIG_OVERRIDE     config dir holding publication-identity.json and sol-control.json
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
AUTH_DIR="${FM_LANDING_AUTH_DIR:-$DATA/landing-authorizations}"
OUTBOUND_DIR="${FM_OUTBOUND_DIR:-$DATA/outbound-artifacts}"

# shellcheck source=bin/fm-outbound-artifact-lib.sh
. "$SCRIPT_DIR/fm-outbound-artifact-lib.sh"
# shellcheck source=bin/fm-landing-authorization-lib.sh
. "$SCRIPT_DIR/fm-landing-authorization-lib.sh"
# shellcheck source=bin/fm-landing-seam-lib.sh
. "$SCRIPT_DIR/fm-landing-seam-lib.sh"
# shellcheck source=bin/fm-publication-seam-lib.sh
. "$SCRIPT_DIR/fm-publication-seam-lib.sh"

usage() { sed -n '2,/^set -u$/p' "$0" | sed -e '$d' -e 's/^# \{0,1\}//'; }

die() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }
refuse() { printf 'REFUSE %s: %s\n' "$1" "$2" >&2; exit 3; }
cno() { printf 'CNO %s: %s\n' "$1" "$2" >&2; exit 4; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- the remote tip, OBSERVED -------------------------------------------------
#
# The tip is read here rather than accepted from the caller, for the reason the
# landing authority re-observes a pull request's head: the party whose plan is
# being checked must not also be the source of the value it is checked against.
#
# An absent ref is the literal "-" and is a real answer - the first publication
# of a branch. A remote that could not be reached is not: it is could-not-observe,
# and it stops the publication rather than being read as an absent ref, because
# those two produce opposite decisions.

OBSERVED_TIP=
observe_tip() {  # <repo> <remote> <ref>
  local repo=$1 remote=$2 ref=$3 url out rc=0
  OBSERVED_TIP=
  url=$(git --no-optional-locks -C "$repo" remote get-url --push "$remote" 2>/dev/null) || url=$remote
  out=$(git --no-optional-locks -C "$repo" ls-remote "$url" "$ref" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  if [ -z "$out" ]; then
    OBSERVED_TIP='-'
    return 0
  fi
  OBSERVED_TIP=$(printf '%s\n' "$out" | awk 'NF {print $1; exit}')
  fm_auth_head_shape_valid "$OBSERVED_TIP"
}

# --- record access ------------------------------------------------------------
#
# Three-valued, and the three are kept apart: readable, genuinely absent, and
# present-but-unreadable. Only the second is an absence.

AUTH_RECORD=
AUTH_EFFECT=
auth_read() {  # <auth-id> -> 0 readable | 3 absent | 4 unreadable
  local id=$1 path raw effect
  path=$(fm_auth_store_path "$AUTH_DIR" "$id") || return 4
  if [ ! -e "$path" ]; then AUTH_RECORD=; return 3; fi
  raw=$(cat "$path" 2>/dev/null) || return 4
  printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 4
  [ "$(printf '%s' "$raw" | jq -r '.schema // ""')" = "$FM_AUTH_SCHEMA" ] || return 4
  # Two different unreadabilities, and both stop here. An effect this contract
  # has never heard of means the record was written by something that does not
  # share this vocabulary; a known effect that is not publication means the
  # caller addressed a landing authority with the publication guard. Neither is
  # a record this command may act on.
  effect=$(printf '%s' "$raw" | jq -r '.effect // ""')
  fm_auth_effect_valid "$effect" || return 4
  case $effect in publication|custody) ;; *) return 4 ;; esac
  AUTH_EFFECT=$effect
  # LOCATION IS NOT IDENTITY: a record adopted from its filename can be moved
  # into place, so the record must name itself.
  [ "$(printf '%s' "$raw" | jq -r '.authorization_id // ""')" = "$id" ] || return 4
  AUTH_RECORD=$raw
  return 0
}

# Named for what it reads rather than shortened to `rec`: that spelling is a
# common local variable across this repository, and a function sharing it makes
# every one of those files ambiguous to the dead-predicate control.
auth_field() { printf '%s' "$AUTH_RECORD" | jq -r "$1" 2>/dev/null; }

# The effect's class name, which is what a caller reads. The record stores the
# short effect; the closed result vocabulary names the class.
effect_class() {  # <effect>
  case ${1:-} in
    custody) printf '%s' "$FM_PUB_SEAM_CLASS_CUSTODY" ;;
    *) printf '%s' "$FM_PUB_SEAM_CLASS_PUBLICATION" ;;
  esac
}

# --- shared resolution --------------------------------------------------------

# The class selects the fold, and nothing else does. A caller that asked for
# custody is answered by custody's obligations; one that asked for publication -
# which is the default, and the stricter class - is answered by publication's.
resolve_or_exit() {  # <effect> <repo> <item> <venue> <ref> <head> <tree> <expected> <observed>
  local effect=$1 rc=0
  shift
  if [ "$effect" = custody ]; then
    fm_pub_seam_resolve_custody "$CONFIG" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" || rc=$?
  else
    fm_pub_seam_resolve "$OUTBOUND_DIR" "$AUTH_DIR" "$CONFIG" "$1" \
      "$2" "$3" "$4" "$5" "$6" "$7" "$8" || rc=$?
  fi
  case $rc in
    0) return 0 ;;
    3) refuse "$FM_PUB_SEAM_TOKEN" "$FM_PUB_SEAM_REASON" ;;
    *) cno "$FM_PUB_SEAM_TOKEN" "$FM_PUB_SEAM_REASON" ;;
  esac
}

# --- prepare ------------------------------------------------------------------

cmd_prepare() {
  local repo='' remote='' venue='' ref='' head='' tree='' item='-' expected='' dry=0
  local effect=publication
  local subject epoch=1 id path state f raw now record

  while [ $# -gt 0 ]; do
    case $1 in
      --dry-run) dry=1; shift ;;
      --effect) effect=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --remote) remote=${2:-}; shift 2 ;;
      --venue) venue=${2:-}; shift 2 ;;
      --ref) ref=${2:-}; shift 2 ;;
      --head) head=${2:-}; shift 2 ;;
      --tree) tree=${2:-}; shift 2 ;;
      --item) item=${2:-}; shift 2 ;;
      --expected-tip) expected=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$remote" ] && [ -n "$venue" ] && [ -n "$ref" ] \
    && [ -n "$head" ] && [ -n "$expected" ] \
    || die "prepare requires --repo, --remote, --venue, --ref, --head and --expected-tip"
  case $effect in
    publication|custody) ;;
    *) die "unknown effect class: $effect (custody or publication)" ;;
  esac

  if [ -z "$tree" ]; then
    tree=$(git --no-optional-locks -C "$repo" rev-parse "$head^{tree}" 2>/dev/null) || tree=''
    [ -n "$tree" ] || cno "$FM_PUB_SEAM_TOKEN_CANDIDATE_UNBOUND" \
      "the tree of $head could not be read from $repo, so what this publication would carry could not be observed"
  fi

  observe_tip "$repo" "$remote" "$ref" || cno "$FM_PUB_SEAM_TOKEN_TIP_UNOBSERVED" \
    "the current tip of $ref on $remote could not be observed, which is not the same as that ref being absent"

  resolve_or_exit "$effect" "$repo" "$item" "$venue" "$ref" "$head" "$tree" "$expected" "$OBSERVED_TIP"

  case $FM_PUB_SEAM_VERDICT in
    no-effect)
      printf 'NO_EFFECT_ALREADY_EQUAL %s\n' "$FM_PUB_SEAM_REASON"
      return 0
      ;;
    not-applicable)
      printf 'NOT_APPLICABLE %s\n' "$FM_PUB_SEAM_REASON"
      return 0
      ;;
  esac

  item=$FM_PUB_SEAM_ITEM
  subject=$(fm_auth_effect_subject_digest "$effect" "$venue" "$ref" "$item" "$head" "$tree" \
    "$OBSERVED_TIP" "$FM_PUB_SEAM_GENERATION") \
    || cno "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" "the subject of this $effect could not be digested"

  # WHAT HAS ALREADY HAPPENED TO THIS EXACT SUBJECT. A live authority converges;
  # a consumed one whose effect was never confirmed must be reconciled before
  # anything else may be granted; a spent one is a replay. Only a subject whose
  # every prior authority was retired earns a new epoch.
  if [ -d "$AUTH_DIR" ]; then
    if [ ! -r "$AUTH_DIR" ] || [ ! -x "$AUTH_DIR" ]; then
      cno "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
        "the authorization store at $AUTH_DIR could not be enumerated, so what has already been authorized for this subject could not be observed"
    fi
    for f in "$AUTH_DIR"/*.json; do
      [ -e "$f" ] || continue
      if ! raw=$(cat "$f" 2>/dev/null) || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        cno "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
          "authorization record $f could not be read, and an unreadable one is exactly the one that might already authorize this subject"
      fi
      [ "$(printf '%s' "$raw" | jq -r '.subject // ""')" = "$subject" ] || continue
      [ "$(printf '%s' "$raw" | jq -r '.effect // ""')" = "$effect" ] || continue
      state=$(printf '%s' "$raw" | jq -r '.state // ""')
      case $state in
        granted)
          printf 'ALLOW_EXACT %s generation=%s item=%s\n' \
            "$(printf '%s' "$raw" | jq -r '.authorization_id')" "$FM_PUB_SEAM_GENERATION" "$item"
          return 0
          ;;
        spending)
          cno FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT \
            "authority $(printf '%s' "$raw" | jq -r '.authorization_id') for this exact subject was consumed and its effect was never confirmed; reconcile it from an observation of the remote before anything else is authorized"
          ;;
        spent)
          refuse FM_PUB_REPLAY \
            "authority $(printf '%s' "$raw" | jq -r '.authorization_id') already published this exact subject, so this is a replay of a publication that has happened"
          ;;
        void)
          epoch=$(( epoch + 1 ))
          ;;
        *)
          cno "$FM_PUB_SEAM_TOKEN_AUTH_STORE_UNREADABLE" \
            "authorization record $f is in state '$state', which this contract does not know, so what has already been authorized for this subject could not be observed"
          ;;
      esac
    done
  fi

  id=$(fm_auth_effect_id "$effect" "$venue" "$ref" "$item" "$head" "$tree" \
    "$OBSERVED_TIP" "$FM_PUB_SEAM_GENERATION" "$epoch") \
    || cno "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" "the authorization identity could not be digested"

  if [ "$dry" -eq 1 ]; then
    printf 'ALLOW_EXACT %s class=%s generation=%s item=%s\n' \
      "$id" "$(effect_class "$effect")" "$FM_PUB_SEAM_GENERATION" "$item"
    printf 'fm-publication-guard: dry run, no authority was recorded\n' >&2
    return 0
  fi

  now=$(now_iso)
  record=$(fm_auth_effect_record_new "$effect" "$id" "$FM_PUB_SEAM_REQUEST" "$venue" "$ref" \
    "$item" "$head" "$tree" "$OBSERVED_TIP" "$FM_PUB_SEAM_GENERATION" "$epoch" "$subject" "$now") \
    || cno "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" "the authorization record could not be constructed"
  fm_auth_store_write "$AUTH_DIR" "$id" "$record" \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the authorization record for $id could not be written, so an authority that was granted could not have been recorded"

  path=$(fm_auth_store_path "$AUTH_DIR" "$id")
  printf 'ALLOW_EXACT %s class=%s generation=%s item=%s\n' \
    "$id" "$(effect_class "$effect")" "$FM_PUB_SEAM_GENERATION" "$item"
  printf 'fm-publication-guard: authority recorded at %s\n' "$path" >&2
  return 0
}

# --- consume ------------------------------------------------------------------
#
# THE ACT RUNS INSIDE THE CONSUME, and everything is re-observed before it. A
# guard that asks "may I publish?" and then publishes is two operations with a
# window between them, and this fleet has already ruled what belongs in that
# window: a newer hold, a REVISE, a quarantine, a supersession, a bumped policy
# generation, or the remote simply moving. Commission-time permission is never
# irrevocable, so the compile is redone here and the authority is only usable if
# the world it named is still the world in front of us.
#
# THE PESSIMISTIC RECORD IS WRITTEN FIRST. `consumed-without-confirmed-effect` is
# durable BEFORE the command runs, not after it fails, because a record written
# afterwards cannot distinguish an act that never ran from one that ran and could
# not report - and that gap is exactly how an authority gets spent twice.
#
# THE EFFECT IS CONFIRMED ON THE REMOTE, not from the command's exit status. A
# push that exits zero has said it reported success; the remote saying it now
# holds this head is a different claim, and only the second one is evidence that
# the publication happened.

cmd_consume() {
  local id=${1:-}; shift || true
  local repo='' remote='' now rc=0
  local venue ref item head tree tip generation epoch fresh_id state record effect

  [ -n "$id" ] || die "consume requires an authorization id"
  while [ $# -gt 0 ]; do
    case $1 in
      --repo) repo=${2:-}; shift 2 ;;
      --remote) remote=${2:-}; shift 2 ;;
      --) shift; break ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$remote" ] || die "consume requires --repo and --remote"
  [ $# -gt 0 ] || die "consume requires a command after --"

  # THE COMMAND IS PART OF WHAT IS BEING AUTHORIZED. Every check below reasons
  # about the subject, and a plan exactly right about its head and its tip still
  # destroys history if the push carries a force. This is the first point at
  # which the act itself is visible, so it is asked here and for both classes.
  if fm_pub_seam_command_forces "$@"; then
    refuse "$FM_PUB_SEAM_TOKEN_FORCE" \
      "the act under this authority carries a forcing argument, and no authority this guard grants covers overwriting or removing what a remote already holds"
  fi

  auth_read "$id" || case $? in
    3) refuse FM_PUB_NO_AUTHORIZATION "no publication authority $id has been granted, so there is nothing to publish under" ;;
    *) cno "$FM_AUTH_TOKEN_RECORD_UNREADABLE" "the publication authority $id could not be read as this contract's record, so whether it permits anything could not be observed" ;;
  esac

  state=$(auth_field '.state // ""')
  case $(fm_auth_spend_admissibility "$state") in
    proceed) ;;
    exhausted)
      refuse FM_PUB_REPLAY \
        "publication authority $id is already spent, so presenting it again is a replay of a publication that has happened"
      ;;
    indeterminate)
      cno FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT \
        "publication authority $id was consumed and its effect was never confirmed; reconcile it from an observation of the remote rather than presenting it again"
      ;;
    void)
      refuse "$FM_AUTH_TOKEN_VOID" \
        "publication authority $id was retired ($(auth_field '.void_reason // "no reason recorded"')) and is never resurrected; a later effect needs a fresh authority"
      ;;
    *)
      cno "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
        "publication authority $id is in state '$state', which this contract does not know"
      ;;
  esac

  effect=$AUTH_EFFECT
  venue=$(auth_field '.grant.venue // ""')
  ref=$(auth_field '.grant.ref // ""')
  item=$(auth_field '.grant.item // ""')
  head=$(auth_field '.grant.head // ""')
  tree=$(auth_field '.grant.tree // ""')
  tip=$(auth_field 'if .grant.tip == null then "-" else .grant.tip end')
  generation=$(auth_field '.grant.generation // ""')
  epoch=$(auth_field '.epoch // 1')

  observe_tip "$repo" "$remote" "$ref" || cno "$FM_PUB_SEAM_TOKEN_TIP_UNOBSERVED" \
    "the current tip of $ref on $remote could not be observed, which is not the same as that ref being absent"

  resolve_or_exit "$effect" "$repo" "$item" "$venue" "$ref" "$head" "$tree" "$tip" "$OBSERVED_TIP"
  case $FM_PUB_SEAM_VERDICT in
    no-effect)
      printf 'NO_EFFECT_ALREADY_EQUAL %s\n' "$FM_PUB_SEAM_REASON"
      return 0
      ;;
    not-applicable)
      cno FM_PUB_GOVERNANCE_WITHDRAWN \
        "publication authority $id was granted for governed work and $item on $venue is no longer governed, so what this authority now permits could not be established"
      ;;
  esac

  if [ "$FM_PUB_SEAM_GENERATION" != "$generation" ]; then
    refuse "$FM_PUB_SEAM_TOKEN_GENERATION" \
      "publication authority $id rests on generation $generation and the current ruling and policy generation is $FM_PUB_SEAM_GENERATION, so the permission it carries addresses a world that has since changed"
  fi

  fresh_id=$(fm_auth_effect_id "$effect" "$venue" "$ref" "$item" "$head" "$tree" \
    "$OBSERVED_TIP" "$FM_PUB_SEAM_GENERATION" "$epoch") \
    || cno "$FM_PUB_SEAM_TOKEN_POLICY_UNREADABLE" "the authorization identity could not be recomputed"
  if [ "$fresh_id" != "$id" ]; then
    refuse "$FM_PUB_SEAM_TOKEN_REMOTE_MOVED" \
      "publication authority $id no longer names the effect in front of it (recomputes to $fresh_id), so the subject it authorized is not the subject about to be published"
  fi

  now=$(now_iso)
  record=$(printf '%s' "$AUTH_RECORD" | jq \
    --arg now "$now" --arg pid "$$" \
    '.state="spending" | .updated=$now
     | .spend={intent:$now,by:$pid,outcome:"consumed-without-confirmed-effect",evidence:null}
     | .history += [{at:$now,event:"intent-recorded"}]') \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the intent record for $id could not be constructed, so the act was not attempted"
  fm_auth_store_write "$AUTH_DIR" "$id" "$record" \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" \
      "the intent record for $id could not be written, so a publication whose outcome could not have been recorded was not attempted"
  # The outcome is written ON TOP of the intent, not on top of the record as it
  # was before the intent. Building it from the earlier copy would drop the
  # intent's own timestamp, its spender, and its history entry - the evidence
  # that says WHEN this authority was committed to an act, which is the whole
  # point of writing it first.
  AUTH_RECORD=$record

  "$@" || rc=$?

  if ! observe_tip "$repo" "$remote" "$ref"; then
    cno FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT \
      "the publication under $id ran (exit $rc) and the resulting tip of $ref could not be observed, which does not establish that it had no effect; reconcile it with reconcile $id"
  fi
  if [ "$OBSERVED_TIP" != "$head" ]; then
    cno FM_PUB_CONSUMED_WITHOUT_CONFIRMED_EFFECT \
      "the publication under $id ran (exit $rc) and $ref on $remote is at $OBSERVED_TIP rather than $head, so its effect is not confirmed; reconcile it with reconcile $id"
  fi

  now=$(now_iso)
  record=$(printf '%s' "$AUTH_RECORD" | jq \
    --arg now "$now" --arg tip "$OBSERVED_TIP" \
    '.state="spent" | .updated=$now
     | .spend.outcome="applied" | .spend.evidence=("remote tip observed at " + $tip)
     | .history += [{at:$now,event:"effect-confirmed"}]') \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the outcome record for $id could not be constructed although the remote confirms the effect"
  fm_auth_store_write "$AUTH_DIR" "$id" "$record" \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the outcome record for $id could not be written although the remote confirms the effect"

  printf 'APPLIED %s %s %s now at %s\n' "$(effect_class "$effect")" "$id" "$ref" "$OBSERVED_TIP"
  return 0
}

# --- publish ------------------------------------------------------------------
#
# The composed operation, and the only one most callers need. It is a thin front
# for bin/fm-publication-seam-lib.sh's wiring rather than a second copy of it, so
# a caller reaching the guard as a COMMAND and a caller sourcing the library
# cannot drift into two different answers about whether a publication was
# governed - which is the whole reason that wiring is a single owner.

cmd_publish() {
  local repo='' remote='' venue='' ref='' head='' expected='' item='-' rc=0
  local effect=publication

  while [ $# -gt 0 ]; do
    case $1 in
      --effect) effect=${2:-}; shift 2 ;;
      --repo) repo=${2:-}; shift 2 ;;
      --remote) remote=${2:-}; shift 2 ;;
      --venue) venue=${2:-}; shift 2 ;;
      --ref) ref=${2:-}; shift 2 ;;
      --head) head=${2:-}; shift 2 ;;
      --expected-tip) expected=${2:-}; shift 2 ;;
      --item) item=${2:-}; shift 2 ;;
      --) shift; break ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$remote" ] && [ -n "$venue" ] && [ -n "$ref" ] \
    && [ -n "$head" ] && [ -n "$expected" ] \
    || die "publish requires --repo, --remote, --venue, --ref, --head and --expected-tip"
  [ $# -gt 0 ] || die "publish requires a command after --"
  case $effect in
    publication|custody) ;;
    *) die "unknown effect class: $effect (custody or publication)" ;;
  esac

  fm_pub_seam_publish "$0" "$repo" "$remote" "$venue" "$ref" "$head" "$expected" "$item" \
    "$effect" "$@" \
    || rc=$?
  [ -z "$FM_PUB_SEAM_OUTPUT" ] || printf '%s\n' "$FM_PUB_SEAM_OUTPUT" >&2
  case $rc in
    0)
      case $FM_PUB_SEAM_VERDICT in
        no-effect) printf 'NO_EFFECT_ALREADY_EQUAL %s\n' "$FM_PUB_SEAM_REASON" ;;
        not-applicable) printf 'NOT_APPLICABLE %s\n' "$FM_PUB_SEAM_REASON" ;;
        *) printf 'APPLIED %s\n' "$FM_PUB_SEAM_REASON" ;;
      esac
      return 0
      ;;
    3) refuse "$FM_PUB_SEAM_TOKEN" "$FM_PUB_SEAM_REASON" ;;
    *) cno "$FM_PUB_SEAM_TOKEN" "$FM_PUB_SEAM_REASON" ;;
  esac
}

# --- project ------------------------------------------------------------------
#
# WHAT STATE THIS CANDIDATE IS ACTUALLY IN, derived from the durable owners that
# already hold the evidence. It reads; it never writes, mints, or moves anything.
#
# The states are explicit and monotonic, and NONE OF THEM IMPLIES THE NEXT. That
# is the entire reason this exists rather than a boolean "is it pushed":
#
#   local-only            no remote copy this command could observe
#   custody-replicated    the candidate's own feature ref on the venue resolves
#                         to EXACTLY this head. A remote copy of a commit, and
#                         nothing else: no review, no CI, no acceptance
#   review-published      a live governing request carries this exact head, so
#                         the candidate has been submitted for review. Being
#                         submitted is not being accepted
#   publication-qualified the publication fold currently answers allow-exact for
#                         this candidate. Being permitted to publish is not
#                         having published, and is not landing authority
#   landing-authorized    a landing authority for this work stands unspent.
#                         Authority to land is not a landing
#   landed                a landing authority for this work is spent
#
# Each limb is reported on its own with its own three-valued answer, so a reader
# can see custody-replicated yes beside review-published no and not have to infer
# either from the other. The headline STATE is the highest limb OBSERVED, and a
# limb that could not be observed is reported as such rather than folded into no.
#
# THE EXIT STATUS ANSWERS THE ACTIONABLE QUESTION, which is reclaimability: may
# the worktree slot holding this candidate be released? Yes only when the remote
# ref resolves to the exact candidate head - verified by ls-remote, never by the
# branch merely existing, because a branch at some other head is evidence that
# this candidate is NOT backed up rather than that it is.
#
#   0  reclaimable
#   3  not reclaimable
#   4  could not be observed - which is not reclaimable either, and is a
#      different repair from a ref standing at the wrong head

PROJECT_STATE=local-only
project_limb() {  # <name> <verdict> <evidence>
  printf '%-22s %-18s %s\n' "$1" "$2" "$3"
  [ "$2" = yes ] || return 0
  PROJECT_STATE=$1
}

# The landing authorities standing for this work, which is a different store
# question from the publication ones: landing binds an item and a pull request,
# not a ref and a tip.
LANDING_STATES=
scan_landing() {  # <item> -> 0 read | 4 unreadable
  local item=$1 f raw
  LANDING_STATES=
  [ -d "$AUTH_DIR" ] || return 0
  { [ -r "$AUTH_DIR" ] && [ -x "$AUTH_DIR" ]; } || return 4
  for f in "$AUTH_DIR"/*.json; do
    [ -e "$f" ] || continue
    raw=$(cat "$f" 2>/dev/null) || return 4
    printf '%s' "$raw" | jq -e . >/dev/null 2>&1 || return 4
    [ "$(printf '%s' "$raw" | jq -r '.effect // ""')" = landing ] || continue
    [ "$(printf '%s' "$raw" | jq -r '.grant.item // ""')" = "$item" ] || continue
    LANDING_STATES="$LANDING_STATES $(printf '%s' "$raw" | jq -r '.state // "?"')"
  done
  return 0
}

cmd_project() {
  local repo='' remote='' venue='' ref='' head='' item='-' tree=''
  local permitted custody=no custody_note reclaim=3
  local review=no review_note qualified=no qualified_note
  local authorized=no authorized_note landed=no landed_note rc=0

  while [ $# -gt 0 ]; do
    case $1 in
      --repo) repo=${2:-}; shift 2 ;;
      --remote) remote=${2:-}; shift 2 ;;
      --venue) venue=${2:-}; shift 2 ;;
      --ref) ref=${2:-}; shift 2 ;;
      --head) head=${2:-}; shift 2 ;;
      --item) item=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$repo" ] && [ -n "$remote" ] && [ -n "$venue" ] && [ -n "$ref" ] && [ -n "$head" ] \
    || die "project requires --repo, --remote, --venue, --ref and --head"

  # The work identity, taken from the policy when it declares one, because every
  # limb below is keyed on the work rather than on the ref.
  fm_pub_seam_policy_read "$CONFIG"
  if [ "$FM_PUB_SEAM_POLICY_STATE" = present ] && fm_pub_seam_policy_venue_governed "$venue"; then
    permitted=$(fm_pub_seam_policy_work "$venue" "$ref" item)
    [ -z "$permitted" ] || item=$permitted
  fi
  [ "$item" != '-' ] || cno "$FM_PUB_SEAM_TOKEN_CANDIDATE_UNBOUND" \
    "no work identity was given and none is declared for $ref on $venue, so what this candidate is could not be established"
  tree=$(git --no-optional-locks -C "$repo" rev-parse "$head^{tree}" 2>/dev/null) || tree=''

  # --- custody, and with it reclaimability ---
  permitted=$(fm_pub_seam_custody_ref "$item")
  if ! observe_tip "$repo" "$remote" "$ref"; then
    custody=could-not-observe
    custody_note="the tip of $ref on $remote could not be observed, which is not the same as it being absent"
    reclaim=4
  elif [ "$ref" != "$permitted" ]; then
    custody_note="$ref is not this work's own custody ref ($permitted), so no custody replication is claimed for it"
  elif [ "$OBSERVED_TIP" = "$head" ]; then
    custody=yes
    custody_note="$venue has $ref at exactly $head"
    reclaim=0
  elif [ "$OBSERVED_TIP" = '-' ]; then
    custody_note="$venue has no $ref, so this candidate exists only here"
  else
    custody_note="$venue has $ref at $OBSERVED_TIP rather than $head, so this candidate is not the one backed up there"
  fi

  # --- review, from the correlation store ---
  if fm_pub_seam_scan_records "$OUTBOUND_DIR" "$item" "$head"; then
    if [ "$FM_PUB_SEAM_GRANTING" -gt 0 ]; then
      review=yes
      review_note="$FM_PUB_SEAM_GRANTING live request(s) carry this exact head with an approving ruling"
    elif [ "$FM_PUB_SEAM_LIVE" -gt 0 ]; then
      review=yes
      review_note="$FM_PUB_SEAM_LIVE live request(s) hold this work:$FM_PUB_SEAM_HOLDS"
    else
      review_note="no live request carries this work, so it has not been submitted for review"
    fi
  else
    review=could-not-observe
    review_note=$FM_PUB_SEAM_REASON
  fi

  # --- publication eligibility, from the publication fold itself ---
  #
  # Compiled against the tip that is actually there, so this answers "would this
  # be permitted", not "is the caller's plan still current". Those are different
  # questions and only the first one belongs in a projection.
  if [ -z "$tree" ] || [ "$custody" = could-not-observe ]; then
    qualified=could-not-observe
    qualified_note="the candidate's tree or the remote tip could not be read, so its publication eligibility could not be compiled"
  else
    rc=0
    fm_pub_seam_resolve "$OUTBOUND_DIR" "$AUTH_DIR" "$CONFIG" "$repo" \
      "$item" "$venue" "$ref" "$head" "$tree" "$OBSERVED_TIP" "$OBSERVED_TIP" || rc=$?
    case $rc in
      0)
        if [ "$FM_PUB_SEAM_VERDICT" = allow-exact ]; then
          qualified=yes
          qualified_note=$FM_PUB_SEAM_REASON
        else
          qualified_note="$FM_PUB_SEAM_TOKEN: $FM_PUB_SEAM_REASON"
        fi
        ;;
      3) qualified_note="$FM_PUB_SEAM_TOKEN: $FM_PUB_SEAM_REASON" ;;
      *) qualified=could-not-observe; qualified_note="$FM_PUB_SEAM_TOKEN: $FM_PUB_SEAM_REASON" ;;
    esac
  fi

  # --- landing authority ---
  if scan_landing "$item"; then
    case $LANDING_STATES in
      *spent*) landed=yes; landed_note="a landing authority for $item is spent" ;;
    esac
    case $LANDING_STATES in
      *granted*|*spending*) authorized=yes; authorized_note="a landing authority for $item stands unspent" ;;
    esac
    [ "$authorized" = yes ] || authorized_note="no unspent landing authority stands for $item"
    [ "$landed" = yes ] || landed_note="no landing authority for $item records a completed landing"
  else
    authorized=could-not-observe
    landed=could-not-observe
    authorized_note="the authorization store at $AUTH_DIR could not be read"
    landed_note=$authorized_note
  fi

  # Printed lowest first so PROJECT_STATE ends on the highest limb observed.
  project_limb custody-replicated "$custody" "$custody_note"
  project_limb review-published "$review" "$review_note"
  project_limb publication-qualified "$qualified" "$qualified_note"
  project_limb landing-authorized "$authorized" "$authorized_note"
  project_limb landed "$landed" "$landed_note"
  printf '%-22s %-18s %s\n' reclaimable \
    "$(case $reclaim in 0) printf yes ;; 3) printf no ;; *) printf could-not-observe ;; esac)" \
    "$custody_note"
  printf 'STATE %s item=%s\n' "$PROJECT_STATE" "$item"
  return "$reclaim"
}

# --- reconcile ----------------------------------------------------------------
#
# THE ONE PLACE THIS DIVERGES FROM LANDING, deliberately. A landing authority
# reconciled to "the act did not happen" returns to `granted`, because the merge
# it authorises is still the merge it authorised. A publication authority does
# not: it is retired, and a later effect needs a fresh one.
#
# The reason is that a publication's subject includes the tip it was standing on,
# so the world it named has to be re-observed to know whether it still exists -
# and re-observing it is exactly what minting a fresh authority does. Returning
# this one to the pool would let an authority compiled before an interruption
# authorise an effect after it, which is the resurrection this must not permit.

cmd_reconcile() {
  local id=${1:-}; shift || true
  local observed='' evidence='' now record state
  [ -n "$id" ] || die "reconcile requires an authorization id"
  while [ $# -gt 0 ]; do
    case $1 in
      --observed) observed=${2:-}; shift 2 ;;
      --evidence) evidence=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  case $observed in applied|not-applied) ;; *) die "reconcile requires --observed applied|not-applied" ;; esac
  [ -n "$evidence" ] || die "reconcile requires --evidence naming what was observed"

  auth_read "$id" || case $? in
    3) refuse FM_PUB_NO_AUTHORIZATION "no publication authority $id exists to reconcile" ;;
    *) cno "$FM_AUTH_TOKEN_RECORD_UNREADABLE" "publication authority $id could not be read" ;;
  esac
  state=$(auth_field '.state // ""')
  [ "$state" = spending ] || refuse FM_PUB_NOT_INDETERMINATE \
    "publication authority $id is '$state' rather than consumed-without-confirmed-effect, so there is nothing to reconcile"

  now=$(now_iso)
  if [ "$observed" = applied ]; then
    record=$(printf '%s' "$AUTH_RECORD" | jq --arg now "$now" --arg ev "$evidence" \
      '.state="spent" | .updated=$now | .spend.outcome="applied" | .spend.evidence=$ev
       | .history += [{at:$now,event:"reconciled-applied"}]')
  else
    record=$(printf '%s' "$AUTH_RECORD" | jq --arg now "$now" --arg ev "$evidence" \
      '.state="void" | .updated=$now | .spend.outcome="not-applied" | .spend.evidence=$ev
       | .void_reason="consumed without a confirmed effect and observed not applied; a later effect needs a fresh authority"
       | .history += [{at:$now,event:"reconciled-not-applied"}]')
  fi
  [ -n "$record" ] || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the reconciliation record for $id could not be constructed"
  fm_auth_store_write "$AUTH_DIR" "$id" "$record" \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the reconciliation record for $id could not be written"
  printf 'RECONCILED %s is now %s\n' "$id" "$(printf '%s' "$record" | jq -r '.state')"
  return 0
}

# --- retire -------------------------------------------------------------------
#
# WHY THIS IS NARROW, and why it is not a delete.
#
# An authority that should never have existed is still evidence that it did. The
# store's whole value is that a later reader can say what was authorized, when,
# and what became of it, so the repair for a mistaken grant is a recorded
# retirement rather than a removal - and certainly not a hand edit, which leaves
# no trace that anything was ever different.
#
# `granted` is the ONLY state this touches. The two it refuses are refused for
# the same reason it exists: a `spent` record says an act happened, and an
# unobserved one says an act may have, and replacing either with `void` would
# turn evidence into a tidier claim than the evidence supports. The second is
# reconcile's to settle from an observation, never this command's to assume.

cmd_retire() {
  local id=${1:-}; shift || true
  local reason='' now record state
  [ -n "$id" ] || die "retire requires an authorization id"
  while [ $# -gt 0 ]; do
    case $1 in
      --reason) reason=${2:-}; shift 2 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [ -n "$reason" ] || die "retire requires --reason naming why this authority must never be spent"

  auth_read "$id" || case $? in
    3) refuse FM_PUB_NO_AUTHORIZATION "no publication authority $id exists to retire" ;;
    *) cno "$FM_AUTH_TOKEN_RECORD_UNREADABLE" "publication authority $id could not be read, so what retiring it would discard could not be established" ;;
  esac

  state=$(auth_field '.state // ""')
  case $state in
    granted) ;;
    void)
      # Idempotent, and deliberately WITHOUT a second history entry: repeating
      # the command must not make the record look like it was retired twice.
      printf 'RETIRED %s was already retired (%s)\n' "$id" "$(auth_field '.void_reason // "no reason recorded"')"
      return 0
      ;;
    spent)
      refuse FM_PUB_NOT_RETIRABLE \
        "publication authority $id is spent, so it records an act that happened; retiring it would replace that evidence with a tidier state than the evidence supports"
      ;;
    spending)
      refuse FM_PUB_NOT_RETIRABLE \
        "publication authority $id was consumed and its effect is unobserved, so whether an act happened is not settled; reconcile it from an observation of the remote rather than retiring it"
      ;;
    *)
      cno "$FM_AUTH_TOKEN_RECORD_UNREADABLE" \
        "publication authority $id is in state '$state', which this contract does not know"
      ;;
  esac

  now=$(now_iso)
  # The record is AMENDED, never rebuilt: every field it already carries survives
  # verbatim, and the retirement is added beside them.
  record=$(printf '%s' "$AUTH_RECORD" | jq --arg now "$now" --arg reason "$reason" \
    '.state="void" | .updated=$now | .void_reason=$reason
     | .history += [{at:$now,event:"retired",reason:$reason}]') \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the retirement record for $id could not be constructed"
  [ -n "$record" ] || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the retirement record for $id could not be constructed"
  fm_auth_store_write "$AUTH_DIR" "$id" "$record" \
    || cno "$FM_AUTH_TOKEN_WRITE_UNOBSERVED" "the retirement record for $id could not be written, so it is still spendable"
  printf 'RETIRED %s is now void (%s)\n' "$id" "$reason"
  return 0
}

# --- status and list ----------------------------------------------------------

cmd_status() {
  local id=${1:-} state
  [ -n "$id" ] || die "status requires an authorization id"
  auth_read "$id" || case $? in
    3) printf '%s\n' "$FM_AUTH_STATUS_ABSENT"; exit 4 ;;
    *) printf '%s\n' "$FM_AUTH_STATUS_UNREADABLE"; exit 4 ;;
  esac
  state=$(fm_auth_reported_status "$(auth_field '.state // ""')")
  printf '%s\n' "$state"
  [ "$state" = "$FM_AUTH_STATUS_INDETERMINATE" ] && exit 4
  return 0
}

# A partial enumeration reports could-not-observe rather than a short list: a
# listing that silently omitted the record it could not read is the same claim as
# an empty violations log.
cmd_list() {
  local f raw partial=0
  [ -d "$AUTH_DIR" ] || { printf 'no publication authorities recorded\n'; return 0; }
  for f in "$AUTH_DIR"/*.json; do
    [ -e "$f" ] || continue
    if ! raw=$(cat "$f" 2>/dev/null) || ! printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
      printf '%s\tunreadable\n' "${f##*/}"
      partial=1
      continue
    fi
    [ "$(printf '%s' "$raw" | jq -r '.effect // ""')" = publication ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(printf '%s' "$raw" | jq -r '.authorization_id')" \
      "$(printf '%s' "$raw" | jq -r '.state')" \
      "$(printf '%s' "$raw" | jq -r '.grant.venue')" \
      "$(printf '%s' "$raw" | jq -r '.grant.ref')" \
      "$(printf '%s' "$raw" | jq -r '.grant.head')"
  done
  [ "$partial" -eq 0 ] || cno "$FM_AUTH_TOKEN_ENUM_UNOBSERVED" \
    "the publication authority listing is incomplete, so it is not a short list of what exists"
  return 0
}

# --- dispatch -----------------------------------------------------------------

[ $# -gt 0 ] || { usage; exit 2; }
case $1 in
  -h|--help) usage; exit 0 ;;
  prepare) shift; cmd_prepare "$@" ;;
  consume) shift; cmd_consume "$@" ;;
  publish) shift; cmd_publish "$@" ;;
  project) shift; cmd_project "$@" ;;
  reconcile) shift; cmd_reconcile "$@" ;;
  retire) shift; cmd_retire "$@" ;;
  status) shift; cmd_status "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) die "unknown command: $1" ;;
esac

# fail-closed-predicates: enforced
