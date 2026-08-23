# shellcheck shell=bash
# fm-outbound-artifact-lib.sh - single owner of the OUTBOUND transport invariant's
# three contracts: which durable states imply an outstanding outbound artifact,
# what identity an artifact binds to, and what one correlation record contains.
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-outbound-artifact-lib.sh
#   . "$SCRIPT_DIR/fm-outbound-artifact-lib.sh"
#
# bin/fm-outbound-artifact.sh is its only command and owns transport, cadence,
# retry, checkpointing, and the invariant verdict. This file performs no network
# I/O and takes no lock, so each predicate is testable on its own.
#
# THE ASYMMETRY THIS EXISTS TO CLOSE
#
# The control plane had one direction. An INBOUND detector wakes firstmate when
# Browser Sol replies to a control issue that already exists. Nothing owned the
# OUTBOUND direction - that work reaching a gate actually emits the artifact the
# gate is waiting on. The gap is measured, not theoretical, and it has been
# observed on two different surfaces:
#
#   Four SSSF pull requests sat in "released for handoff pending independent
#   acceptance" for days having never been submitted for review. Browser Sol did
#   not fail to process them; nothing ever asked.
#
#   Three items - fleet-attention-advisory-signal, and the two engraphis rows -
#   held finished work on a real branch with NO pull request ever opened on any
#   remote. Nobody rejected that work; nobody was ever shown it.
#
# One shape, two surfaces: an item in a state that IMPLIES an outstanding
# outbound artifact, where no applicable durable artifact exists. An
# outbound-blind control plane is indistinguishable, from the inside, from a
# working one. Both are quiet, and the quiet is the defect.
#
# THE INVARIANT
#
#   An item may not remain in a state that implies an outstanding outbound
#   artifact while no applicable durable artifact exists.
#
# When that condition holds it is a CONTROL-TRANSPORT DEFECT, not an external
# wait. The distinction is the whole point: an external wait is legitimate and
# costs nothing to hold, so an item misfiled as one waits forever and reads as
# patience. Nothing may reclassify an artifact-less waiting item as not-waiting
# to make the invariant pass - the item goes red, and the redness is the product.
#
# WHY THE INVARIANT IS STATED OVER ARTIFACTS AND NOT OVER SOL REQUESTS
#
# It was authorised over Browser Sol requests, then widened on evidence, and the
# choice is recorded here rather than left implicit. Building the Sol-only form
# and adding the pull-request form later would have produced two mechanisms with
# two identity rules and two dedupe stories - the second control plane the
# authorisation explicitly forbids. The general form costs one channel field.
#
# THE SCOPE BOUNDARY THAT CAME WITH THE WIDENING. Channels differ in whether this
# mechanism may CREATE the missing artifact:
#
#   sol-control    emit. Posting a request comment asks a question. Asking is
#                  reversible, carries no delivery authority, and is exactly the
#                  transport that was missing.
#   pull-request   DETECT ONLY. Opening a pull request is a delivery action owned
#                  by the task's selected delivery path (AGENTS.md section 7),
#                  and an outward-facing one on an upstream contribution. The
#                  invariant was authorised; new delivery authority was not. So
#                  this channel surfaces the defect and refuses to close it
#                  itself, and firstmate relaunches through the proper path.
#
# That boundary is deliberate and load-bearing. A future channel that wants to
# emit must justify it the way sol-control does here, not inherit permission by
# being listed.
#
# THREE VALUES, HERE TOO
#
# Recognition is three-valued like every other observation in this fleet
# (bin/fm-verify-lib.sh owns the type). A record is `waiting`, `clear`, or
# `unreadable`, and `unreadable` never collapses into `clear`. A durable row this
# parser cannot read is a row whose gate state is unknown, and an unknown gate
# state is exactly the condition under which the original defect hid.
#
# WHY RECOGNITION HAS TWO TIERS
#
# A recognizer that only reads a typed marker is vacuous on the day it lands:
# every item already waiting predates the marker, so the invariant would report a
# clean fleet while the seven items it was built for stayed invisible. That is a
# failure this fleet has already paid for once - a probe that read a field which
# did not exist, failed unconditionally, and measured nothing.
#
# So recognition reads durable state that already exists:
#
#   TIER 1, typed. `hold-kind: outbound` on the backlog row, with the gate type
#   and binding in data/<item>/outbound-gate.json. This is the canonical form.
#
#   TIER 2, prose. `hold-kind: external` whose hold reason matches the closed
#   token set below. This catches the population that predates the typed marker.
#   It is deliberately NOT a permanent second path: a tier-2 match whose gate type
#   cannot be typed from the prose is reported as an incomplete binding, which is
#   a defect requiring reconciliation, never a pass.
#
# The pull-request channel additionally has a recognizer that reads NO prose at
# all - bin/fm-outbound-artifact.sh's branch sweep - because "a branch carries
# unlanded work and no pull request is bound to its head" is fully observable
# from refs and the forge. That one would have caught all three never-submitted
# items on day one, with no annotation from anybody.
#
# Both prose tiers fail toward `waiting`. A row that looks like it might be at a
# gate and cannot be typed is a defect to surface, because the cost of a false
# waiting is one reconciliation and the cost of a false clear is seven items.

if [ -n "${FM_OUTBOUND_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_OUTBOUND_LIB_SOURCED=1

# --- contract constants ------------------------------------------------------

# The sol-control channel's wire protocol name, as the control issues already use
# it. It is the protocol, not this record's schema: the two version separately.
FM_OUTBOUND_PROTOCOL='fm-sol-control/v1'
export FM_OUTBOUND_RULING_MARKER='FM-SOL-RULING'

# The correlation record's own schema. ONE record serves both directions: the
# outbound emitter creates it and the inbound ruling path joins onto it. That is
# what keeps a ruling attributable to the request that asked for it, and what
# stops this from becoming a second control plane beside the inbound poll.
FM_OUTBOUND_RECORD_SCHEMA='fm-outbound-artifact.v1'

# The marker embedded in every emitted request body. It is how a crashed emit
# recognises its own already-posted request instead of posting a second one, so
# it is a durability mechanism and not decoration. Derived from the protocol name
# rather than repeating it, so the wire never disagrees with the constant.
FM_OUTBOUND_BODY_MARKER="$FM_OUTBOUND_PROTOCOL request:"

# The closed gate vocabulary, and the channel each gate's artifact lives on.
# A state outside this set implies no outbound artifact; a state inside it MUST
# have one. Two fields per line: <gate> <channel>.
FM_OUTBOUND_GATES='AWAITING_BROWSER_SOL sol-control
INDEPENDENT_BROWSER_REVIEW_REQUIRED sol-control
ARCHITECTURE_RULING_REQUIRED sol-control
EXACT_HEAD_BROWSER_REVIEW_REQUIRED sol-control
CONTRIBUTION_SUBMISSION_REQUIRED pull-request'

# Which channels this mechanism may create an artifact on. See the scope boundary
# above: absence from this list is a decision, not an omission.
FM_OUTBOUND_EMIT_CHANNELS='sol-control'

# Record lifecycle. Stored, unlike the commitment register's computed state,
# because these are transport facts about the outside world that cannot be
# recomputed from local files - whether a comment was posted is not derivable.
# Applicability is deliberately NOT stored: it is computed on every read from the
# observed head, so a stale record can never assert its own freshness.
FM_OUTBOUND_RECORD_STATES='emitting
emitted
ruled
resumed
closed
superseded'

# Stable classification and refusal tokens. Callers and tests match these rather
# than prose, so wording can improve without breaking a consumer.
#
# EVERY TOKEN HERE MUST HAVE AN EMIT SITE. This block reads as the closed
# vocabulary of answers the mechanism can give, so a token nothing emits
# documents a classification that cannot occur - and two of them did, while the
# conditions they name were detected at live sites and reported under a
# neighbouring token instead. The dead-predicate control scans function
# definitions, so it cannot see this: an unemitted constant is outside its
# universe by construction. When a token has no emitter, decide whether the
# condition is reachable and label it, rather than deleting the better name.
# The rule is enforced, not merely stated: tests/fm-outbound-artifact.test.sh's
# `token vocabulary` case reads these declarations and refuses any token this
# module never expands.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_OUTBOUND_TOKEN_NO_ARTIFACT=FM_OUTBOUND_NO_ARTIFACT
FM_OUTBOUND_TOKEN_STALE_HEAD=FM_OUTBOUND_STALE_HEAD
FM_OUTBOUND_TOKEN_INCOMPLETE=FM_OUTBOUND_INCOMPLETE_BINDING
FM_OUTBOUND_TOKEN_UNCONFIGURED=FM_OUTBOUND_TRANSPORT_UNCONFIGURED
FM_OUTBOUND_TOKEN_UNREADABLE=FM_OUTBOUND_RECORD_UNREADABLE
FM_OUTBOUND_TOKEN_MISSING_CORRELATION=FM_OUTBOUND_CORRELATION_RECORD_MISSING
FM_OUTBOUND_TOKEN_BACKLOG_UNREADABLE=FM_OUTBOUND_BACKLOG_ROW_UNREADABLE
FM_OUTBOUND_TOKEN_HEAD_UNOBSERVED=FM_OUTBOUND_HEAD_UNOBSERVED
FM_OUTBOUND_TOKEN_ARTIFACT_UNOBSERVED=FM_OUTBOUND_ARTIFACT_UNOBSERVED
FM_OUTBOUND_TOKEN_CLONE_UNREADABLE=FM_OUTBOUND_CLONE_UNREADABLE
FM_OUTBOUND_TOKEN_VENUE_UNRESOLVED=FM_OUTBOUND_VENUE_UNRESOLVED
FM_OUTBOUND_TOKEN_REGISTRY_UNREADABLE=FM_OUTBOUND_PROJECT_REGISTRY_UNREADABLE
FM_OUTBOUND_TOKEN_LANDING_UNOBSERVED=FM_OUTBOUND_LANDING_TARGET_UNOBSERVED
FM_OUTBOUND_TOKEN_POSTURE_UNOBSERVED=FM_OUTBOUND_PROJECT_POSTURE_UNOBSERVED
FM_OUTBOUND_TOKEN_REFS_UNOBSERVED=FM_OUTBOUND_REFS_UNOBSERVED
FM_OUTBOUND_TOKEN_REF_UNOBSERVED=FM_OUTBOUND_REF_UNOBSERVED
FM_OUTBOUND_TOKEN_AMBIGUOUS=FM_OUTBOUND_AMBIGUOUS_CANDIDATES
FM_OUTBOUND_TOKEN_MISMATCH=FM_OUTBOUND_RULING_IDENTITY_MISMATCH
FM_OUTBOUND_TOKEN_DETECT_ONLY=FM_OUTBOUND_CHANNEL_DETECT_ONLY
FM_OUTBOUND_TOKEN_IN_FLIGHT=FM_OUTBOUND_EMIT_IN_FLIGHT
FM_OUTBOUND_TOKEN_SATISFIED=FM_OUTBOUND_SATISFIED
FM_OUTBOUND_TOKEN_IDENTITY=FM_OUTBOUND_IDENTITY_REFUSED
FM_OUTBOUND_TOKEN_WORK_STATE_UNOBSERVED=FM_OUTBOUND_WORK_STATE_UNOBSERVED
FM_OUTBOUND_TOKEN_WORK_LIFECYCLE_CONFLICT=FM_OUTBOUND_WORK_LIFECYCLE_CONFLICT
FM_OUTBOUND_TOKEN_ARCHIVE_UNREADABLE=FM_OUTBOUND_DONE_ARCHIVE_UNREADABLE
FM_OUTBOUND_TOKEN_SENDER_INVALID=FM_OUTBOUND_SENDER_INVALID
}

# The closed sender enum. A `from:` value is compared WHOLE against this list,
# never by prefix and never by substring: a live incident showed that prefix
# discovery lets a body address someone else and still wake this fleet. A
# malformed, duplicated, unknown, or prefix-matching sender is INVALID, and an
# invalid sender wakes nothing at all rather than waking the wrong work.
FM_OUTBOUND_SENDERS='firstmate
browser-sol'

# Which sender a given direction is allowed to have. Canonical writers hardcode
# their own role, so an inbound ruling claiming to come from firstmate is not a
# self-message to be honoured - it is a body that failed to be what it claims.
# shellcheck disable=SC2034  # contract constant consumed by the sourcing command
FM_OUTBOUND_INBOUND_SENDER='browser-sol'

# Is this body's sender exactly the role we require? Returns 0 only when the
# body carries EXACTLY ONE `from:` line whose entire trimmed value equals the
# expected role, and that role is itself in the closed enum.
#
# Counting first, then comparing, is the whole point. Reading "the from line"
# by first match is what makes a second, attacker-chosen `from:` free: the
# reader takes the honest one and the body still carries the other. Two sender
# lines is not a body with a sender, it is a body whose sender is ambiguous,
# and ambiguous identity is could-not-observe rather than a value to pick from.
fm_outbound_sender_valid() {  # <body> <expected-role>
  local body=$1 expected=$2 count value
  [ -n "$expected" ] || return 1
  printf '%s\n' "$FM_OUTBOUND_SENDERS" | grep -qxF -- "$expected" || return 1
  count=$(printf '%s\n' "$body" | grep -c '^from:' || true)
  case $count in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -eq 1 ] || return 1
  value=$(printf '%s\n' "$body" | sed -n 's/^from://p' | tr -d '\r')
  # Trim surrounding whitespace WITHOUT globbing the value itself.
  value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  # Whole-value equality. Never a prefix test, never a substring test: the
  # malformed `from: browser-sol-recipient: firstmate` from the live incident
  # has `browser-sol` as a PREFIX and must still be refused.
  [ "$value" = "$expected" ]
}

# --- digest ------------------------------------------------------------------

FM_OUTBOUND_REQUEST_ID_PREFIX='fm-ob-'
FM_OUTBOUND_REQUEST_ID_HEX_WIDTH=12
FM_OUTBOUND_REQUEST_ID_PATTERN="${FM_OUTBOUND_REQUEST_ID_PREFIX}[0-9a-f]\\{${FM_OUTBOUND_REQUEST_ID_HEX_WIDTH}\\}"
export FM_OUTBOUND_REQUEST_ID_PATTERN

# ONE hashing owner for this module, at full width. The request id truncates it
# and the material block does not, so a change of hash here moves both together
# rather than leaving two functions to drift into two different digests of the
# same bytes.
fm_outbound_sha256() {  # reads stdin, prints the full lowercase hex sha256
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

fm_outbound_digest() {  # reads stdin, prints a lowercase hex request digest
  local full
  full=$(fm_outbound_sha256) || return 1
  case $full in
    "") return 1 ;;
  esac
  printf '%s\n' "$(printf '%s' "$full" \
    | cut -c "1-$FM_OUTBOUND_REQUEST_ID_HEX_WIDTH")"
}

# --- gate vocabulary ---------------------------------------------------------

fm_outbound_gate_valid() {  # <gate>
  printf '%s\n' "$FM_OUTBOUND_GATES" | awk '{print $1}' | grep -qxF "$1"
}

fm_outbound_gate_channel() {  # <gate> -> channel, empty when unknown
  printf '%s\n' "$FM_OUTBOUND_GATES" | awk -v g="$1" '$1 == g {print $2; exit}'
}

fm_outbound_channel_can_emit() {  # <channel>
  printf '%s\n' "$FM_OUTBOUND_EMIT_CHANNELS" | grep -qxF "$1"
}

fm_outbound_record_state_valid() {  # <state>
  printf '%s\n' "$FM_OUTBOUND_RECORD_STATES" | grep -qxF "$1"
}

# --- identity ----------------------------------------------------------------
#
# The idempotency identity. Every field the contract names is here, in a fixed
# order, one per line, so the canonical form is stable across shells and jq
# versions and a digest of it is a durable artifact id.
#
# head is the load-bearing member: it is what makes an artifact EXACT-HEAD bound,
# so a moved head produces a different identity, a different id, and therefore a
# different artifact. "Fresh request when the reviewed head changes" falls out of
# the identity rather than being enforced beside it, which is why there is no
# separate head-change rule anywhere in this mechanism.
#
# An absent optional field is the literal "-" rather than empty, so "no pull
# request" and "pull request field omitted" cannot collide into one identity.

fm_outbound_identity_canonical() {  # <gate> <project> <repo> <item> <pr> <head>
  printf 'gate=%s\nproject=%s\nrepo=%s\nitem=%s\npr=%s\nhead=%s\n' \
    "$1" "${2:--}" "${3:--}" "$4" "${5:--}" "${6:--}"
}

fm_outbound_request_id() {  # <gate> <project> <repo> <item> <pr> <head> -> id
  local sum
  sum=$(fm_outbound_identity_canonical "$@" | fm_outbound_digest) || return 1
  [ -n "$sum" ] || return 1
  printf '%s%s\n' "$FM_OUTBOUND_REQUEST_ID_PREFIX" "$sum"
}

# --- binding completeness ----------------------------------------------------
#
# FAIL CLOSED, stated as code. The mechanism owns WHETHER and WHEN an artifact
# exists; it must never paper over a missing field by emitting a vague request. A
# vague request is worse than none, because it looks like the invariant holds
# while asking a question that cannot be answered against a known head.
#
# Prints the missing field names, one per line, and returns 1 when any is
# missing. An empty result with return 0 is the only complete binding.

# What an exact head may look like, owned once. A branch name, a phrase, and a
# forge error body are all refused by the same rule, and the head cascade applies
# it at the point of OBSERVATION as well as here at the point of use: `gh api`
# prints its error JSON to stdout, so an unvalidated read captures a 404 body and
# carries it forward as an identity. Observed doing exactly that against a live
# backlog, where it surfaced as `head {"message":"Not Found",...}`.
# WIDTH IS NOT A CONSTANT. An object id's width comes from the TARGET
# REPOSITORY's object format - 40 for sha1, 64 for sha256 - and accepting either
# universally is not a stricter rule, it is a different hole. This fleet writes
# 64-character sha256 CONTENT digests routinely (manifest digests, patch digests,
# check-trust hashes), so a universal 64 lets a content digest be read as a head
# in a sha1 repository: the same substitution as an abbreviation, arriving from
# the other side. Verified 2026-08-16: all five clones this fleet holds report
# sha1 via `git rev-parse --show-object-format`.
#
# Shape is only the cheap PRE-FILTER. Where the value can be resolved against the
# repository, resolvability is the stronger evidence and is preferred, because a
# well-formed hex string of exactly the right width is still not proof that the
# object exists.
#
# An UNDETERMINABLE object format is could-not-observe and refuses. It is never
# resolved by falling back to a default width, because guessing the width is
# guessing the identity rule.
fm_outbound_object_width() {  # <clone-dir> -> 40|64, or empty when undeterminable
  local dir=$1 fmt
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  fmt=$(git --no-optional-locks -C "$dir" rev-parse --show-object-format 2>/dev/null) || return 0
  case $fmt in
    sha1) printf '40\n' ;;
    sha256) printf '64\n' ;;
    *) printf '' ;;
  esac
}

# <candidate> [<width>]. With no width the shape cannot be judged at all, so the
# answer is no rather than a guessed default.
fm_outbound_is_sha() {  # <candidate> [<width>]
  local candidate=$1 width=${2:-}
  case $width in
    40|64) ;;
    *) return 1 ;;
  esac
  printf '%s' "$candidate" | grep -Eq "^[0-9a-f]{$width}\$"
}

# The full predicate: exact width for this repository, and resolvable there
# unless the forge authoritatively observed the exact pull-request head.
fm_outbound_head_valid() {  # <candidate> <clone-dir> [<observation-source>]
  local candidate=$1 dir=$2 source=${3:-} width
  width=$(fm_outbound_object_width "$dir")
  [ -n "$width" ] || return 1
  fm_outbound_is_sha "$candidate" "$width" || return 1
  [ "$source" = forge ] && return 0
  # Resolvability beats shape wherever it can be observed.
  git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$candidate^{object}" \
    >/dev/null 2>&1
}

fm_outbound_binding_missing() {  # <gate> <project> <repo> <item> <head> [<clone-dir>] [<head-source>]
  local gate=$1 project=$2 repo=$3 item=$4 head=$5 missing=0
  if [ -z "$gate" ] || ! fm_outbound_gate_valid "$gate"; then
    printf 'gate\n'; missing=1
  fi
  [ -n "$project" ] || { printf 'project\n'; missing=1; }
  [ -n "$repo" ] || { printf 'repo\n'; missing=1; }
  [ -n "$item" ] || { printf 'item\n'; missing=1; }
  # <clone-dir> is optional so existing callers keep working; without it the
  # width is undeterminable and the head is refused rather than assumed.
  fm_outbound_head_valid "$head" "${6:-}" "${7:-}" || { printf 'head\n'; missing=1; }
  [ "$missing" -eq 0 ]
}

# --- identity verdict vocabulary ---------------------------------------------
#
# Captain ruling 2026-08-16: retrieval by identity is THREE-valued, and the two
# refusals are not interchangeable.
#
#   VALID_MATCH        the content proves it is the requested object -> consume
#   IDENTITY_MISMATCH  the content names something else -> refuse
#   COULD_NOT_OBSERVE  identity missing, unreadable, malformed, unsupported
#                      schema -> refuse
#
# Both refuse, so a two-valued check is not UNSAFE - it is UNREPORTABLE, which is
# how this collapse survives review. A caller told only "could not read it" will
# go looking for a corrupt file or a permissions problem; the actual condition
# may be a record that is perfectly readable and belongs to a different request,
# which is a correlation defect and a completely different repair. Keeping the
# two apart is the difference between an operator fixing the right thing and an
# operator fixing nothing.
#
# A missing identity is COULD_NOT_OBSERVE and never an implicit match, because
# adopting the filename when the content is silent is precisely the substitution
# the ruling forbids.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_OUTBOUND_IDENTITY_VALID='VALID_MATCH'
FM_OUTBOUND_IDENTITY_MISMATCH='IDENTITY_MISMATCH'
FM_OUTBOUND_IDENTITY_CNO='COULD_NOT_OBSERVE'
}

# --- the prose recognizer ----------------------------------------------------
#
# Tier 2's closed token set. Every token names a way this fleet has actually
# written an outstanding outbound artifact into a durable hold.
#
# This list is a MIGRATION surface, not an extension point. A new gate should
# arrive as a typed tier-1 marker; adding prose here to avoid typing an item is
# how the typed path stays permanently empty.
FM_OUTBOUND_PROSE_TOKENS='browser sol
browser-sol
awaiting_browser_sol
independent_browser_review_required
architecture_ruling_required
exact_head_browser_review_required
sol-fm-
never submitted
no pull request
pending independent acceptance
released for handoff'

# Prose that names a specific gate maps to it. Everything else that matched a
# prose token is a real wait whose TYPE is unknown - reported as waiting with an
# empty gate, which fm_outbound_binding_missing then refuses. Untyped is a
# defect, never a pass and never a skip.
fm_outbound_gate_from_prose() {  # <text> -> gate or empty
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case $lower in
    *exact_head_browser_review_required*|*"exact head browser review"*)
      printf 'EXACT_HEAD_BROWSER_REVIEW_REQUIRED\n' ;;
    *never\ submitted*|*"no pull request"*)
      printf 'CONTRIBUTION_SUBMISSION_REQUIRED\n' ;;
    *architecture_ruling_required*|*"architecture ruling"*)
      printf 'ARCHITECTURE_RULING_REQUIRED\n' ;;
    *awaiting_browser_sol*|*"awaiting browser sol"*|*"awaiting a browser sol"*)
      printf 'AWAITING_BROWSER_SOL\n' ;;
    *independent_browser_review_required*|*"independent browser review"*|*"independent review"*|*"independent acceptance"*|*"independently adjudicate"*)
      printf 'INDEPENDENT_BROWSER_REVIEW_REQUIRED\n' ;;
    *"released for handoff"*)
      printf 'CONTRIBUTION_SUBMISSION_REQUIRED\n' ;;
    *) printf '' ;;
  esac
}

fm_outbound_prose_matches() {  # <text>
  local lower token
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    case $lower in *"$token"*) return 0 ;; esac
  done <<< "$FM_OUTBOUND_PROSE_TOKENS"
  return 1
}

# Classify ONE backlog record. Prints three tab-separated fields:
#   <verdict>\t<gate>\t<tier>
# verdict is waiting | clear | unreadable, exactly the three values.
#
# A `done` row is clear regardless of its hold prose: a landed item is not
# waiting on anything and its hold text is history. That is the one narrowing
# permitted here, and it is safe because it reads the row's own state field
# rather than inferring completion from silence.
# The text a prose tier reads. It includes the row's RAW line, not just its
# parsed hold_reason, and that is load-bearing rather than belt-and-braces: the
# backlog parser captures a hold with `[^,)]*`, so it stops at the first comma.
# Measured on the live backlog, "RECLASSIFIED ...: VALID UNFINISHED WORK, never
# submitted" parses to a hold_reason ending at "WORK" - the two words that name
# the defect are cut off. Reading hold_reason alone made this recognizer blind to
# exactly the three never-submitted items it was widened to catch.
#
# The truncation is the backlog parser's contract and is not changed here; one
# owner keeps it, and this reader compensates by reading the untruncated line.
fm_outbound_haystack() {  # <record-json>
  printf '%s' "$1" | jq -r '[.hold_reason, .title, .body_excerpt, .raw]
    | map(select(. != null)) | join(" ")' 2>/dev/null || true
}

fm_outbound_classify_record() {  # <record-json> [<declared-gate>]
  local rec=$1 declared_gate=${2:-} structured state hold_kind hay gate
  if ! printf '%s' "$rec" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'unreadable\t\tnone\n'
    return 0
  fi
  structured=$(printf '%s' "$rec" | jq -r '.structured // false')
  if [ "$structured" != "true" ]; then
    # A free-form line in a backlog section carries no typed state at all. It is
    # could-not-observe, not clear: the recognizer genuinely cannot say.
    printf 'unreadable\t\tnone\n'
    return 0
  fi
  state=$(printf '%s' "$rec" | jq -r '.state // ""')
  if [ "$state" = "done" ]; then
    printf 'clear\t\tnone\n'
    return 0
  fi
  hold_kind=$(printf '%s' "$rec" | jq -r '.hold_kind // ""')
  hay=$(fm_outbound_haystack "$rec")

  if [ "$hold_kind" = "outbound" ]; then
    gate=
    if fm_outbound_gate_valid "$declared_gate"; then
      gate=$declared_gate
    fi
    printf 'waiting\t%s\ttyped\n' "$gate"
    return 0
  fi
  if [ "$hold_kind" = "external" ] && fm_outbound_prose_matches "$hay"; then
    gate=$(fm_outbound_gate_from_prose "$hay")
    printf 'waiting\t%s\tprose\n' "$gate"
    return 0
  fi
  printf 'clear\t\tnone\n'
}

# --- applicability -----------------------------------------------------------
#
# A stored artifact is applicable to an item only when the identity it was bound
# to still describes that item. Exact-head applicability is the case that
# matters: a request asking about head A says nothing about head B, so a moved
# head does not make the old artifact stale-but-usable, it makes it INAPPLICABLE
# and leaves the item with no applicable artifact - the invariant's violated
# condition, reached without any special-case rule for head moves.
#
# Prints applicable | inapplicable | unobservable.
fm_outbound_applicability() {  # <stored-head> <observed-head> <record-state>
  case $3 in
    superseded|closed) printf 'inapplicable\n'; return 0 ;;
  esac
  if [ -z "$2" ]; then
    # The head could not be read. Never applicable-by-default: an unobservable
    # head is exactly when a silent pass would hide a moved one.
    printf 'unobservable\n'
    return 0
  fi
  if [ "$1" = "$2" ]; then printf 'applicable\n'; else printf 'inapplicable\n'; fi
}

# --- record construction -----------------------------------------------------

fm_outbound_record_new() {  # <id> <gate> <channel> <project> <repo> <item> <pr> <head> <venue> <now> [<head-source>]
  jq -n \
    --arg schema "$FM_OUTBOUND_RECORD_SCHEMA" \
    --arg request_id "$1" --arg gate "$2" --arg channel "$3" \
    --arg project "$4" --arg repo "$5" --arg item "$6" \
    --arg pr "$7" --arg head "$8" --arg venue "$9" --arg now "${10}" \
    --arg head_source "${11:-}" \
    '{schema:$schema,
      request_id:$request_id,
      channel:$channel,
      identity:{gate:$gate,project:$project,repo:$repo,item:$item,
                pr:(if $pr == "" or $pr == "-" then null else $pr end),
                head:$head,head_source:$head_source},
      venue:$venue,
      state:"emitting",
      comment_id:null,
      attempts:0,
      created:$now,
      updated:$now,
      ruling:null,
      resumed:null,
      disposition:null,
      superseded_by:null}'
}

# The deterministic request body. Every binding field appears verbatim, and the
# marker line carries the artifact id so a crashed emit can find its own work.
#
# A caller-supplied rationale is included as a clearly attributed block BELOW the
# binding. It is never allowed to replace or reword a binding field: the
# mechanism owns the exact-head binding, and a model may only add context to it.
fm_outbound_request_body() {  # <record-json> [<rationale-file>]
  local rec=$1 rationale=${2:-}
  printf '%s %s\n\n' "$FM_OUTBOUND_BODY_MARKER" \
    "$(printf '%s' "$rec" | jq -r '.request_id')"
  printf '%s\n' "$(printf '%s' "$rec" | jq -r '
    "from: firstmate",
    "gate: " + .identity.gate,
    "project: " + .identity.project,
    "repo: " + .identity.repo,
    "item: " + .identity.item,
    "pull-request: " + (.identity.pr // "-"),
    "exact-head: " + .identity.head,
    "requested: " + .created')"
  printf '\nThis request is bound to the exact head above.\n'
  printf 'A ruling on any other head is not applicable to it and will not be applied.\n'
  if [ -n "$rationale" ] && [ -r "$rationale" ]; then
    printf '\n--- context supplied by firstmate (not part of the binding) ---\n\n'
    cat "$rationale"
    printf '\n'
  fi
}

# --- the material universe: content-addressed multipart publication ----------
#
# WHY THIS LIVES INSIDE THE OUTBOUND RECORD RATHER THAN BESIDE IT
#
# A control request sometimes has to carry MATERIAL - the exact bytes a reviewer
# must read - and not only a question about a head. The bytes do not fit in one
# comment, so the request becomes several, and the moment a request is several
# comments three facts nobody owned have to be owned: which parts exist, whether
# what comes back reconstructs the exact bytes that went out, and whether the
# thing being published still describes the subject that was prepared.
#
# One such publication has already been completed BY HAND on this control plane.
# It worked, which is precisely the problem: it is a positive transport fixture
# with no code behind it, so nothing can repeat it, resume it after an
# interruption, or refuse it when it goes wrong.
#
# It is filed HERE, and not next to here, for the same reason the pull-request
# channel was folded into this invariant rather than built alongside it. A
# second publisher brings a second identity rule, a second dedupe story and a
# second answer to "is this correlation finished" - the second control plane the
# original authorisation forbids. So a multipart publication is ONE outbound
# record carrying an OPTIONAL material block, joined to the same request
# identity, written under the same lock, into the same record directory, over
# the same forge seam.
#
# THE RECORD SCHEMA IS DELIBERATELY NOT BUMPED. `material` is optional and
# carries its own schema, so the two version separately - the rule the record
# schema constant above already states. Bumping the record to v2 would make
# every historical record invalid on read, and this fleet's historical records
# include the malformed and adverse ones it is required to preserve. An additive
# optional block leaves every one of them exactly as readable as it was.
#
# THREE DIGESTS, BECAUSE COLLAPSING ANY TWO LOSES A DISTINCT REFUSAL
#
#   manifest identity  digests the ENTRY TABLE - path, class, content digest,
#                      size, bound authority - and nothing else. It answers
#                      "is this the same declared universe".
#   subject digest     digests the PAYLOAD BYTE STREAM that entry table resolves
#                      to. It answers "do the bytes that came back equal the
#                      bytes that went out", which a table alone cannot: a table
#                      can be entirely right about files that were never sent.
#   part digest        digests ONE wire chunk. It answers "WHICH part is wrong"
#                      when a reconstruction fails, and a reconstruction that can
#                      only say "something changed" is not actionable.
#
# EXACT VERSUS DERIVATIVE IS A CLASSIFICATION, NOT A QUALITY JUDGEMENT. An EXACT
# entry publishes its bytes verbatim and stands on them. A DERIVATIVE entry
# publishes NO bytes at all: it declares its own content digest and names the
# already-published authority it derives from, and it grants no independent
# authority. The distinction is load-bearing because the failure it prevents has
# been observed on this control plane - a derived disposition read as though it
# were an independent ruling. Both classes are counted in the universe; only one
# is transmitted.

FM_OUTBOUND_MATERIAL_SCHEMA='fm-outbound-material.v1'
FM_OUTBOUND_MATERIAL_MANIFEST_SCHEMA='fm-outbound-material-manifest.v1'
# shellcheck disable=SC2034  # contract constant consumed by the sourcing command
FM_OUTBOUND_MATERIAL_PAYLOAD_SCHEMA='fm-outbound-material-payload/v1'

# The part marker, derived from the protocol name exactly as the request marker
# is, so the wire can never disagree with the constant. It is a DIFFERENT marker
# from the request's: a part is not a request, and a reader that cannot tell them
# apart would adopt a part as the artifact that satisfies the gate.
FM_OUTBOUND_MATERIAL_BODY_MARKER="$FM_OUTBOUND_PROTOCOL material-part:"

# The wire fence. Five dashes, chosen so it cannot occur inside what it fences:
# the chunk between them is base64, whose alphabet has no '-' at all. That is a
# property of the encoding rather than an inspection of the payload, which is
# what makes exact extraction decidable instead of merely likely.
FM_OUTBOUND_MATERIAL_FENCE_BEGIN='-----FM-MATERIAL-PART-BEGIN-----'
FM_OUTBOUND_MATERIAL_FENCE_END='-----FM-MATERIAL-PART-END-----'

# The closed classification vocabulary for one entry in the universe.
FM_OUTBOUND_MATERIAL_CLASSES='EXACT
DERIVATIVE_OF_PUBLISHED_AUTHORITY'

# Publication lifecycle, and the two orthogonal axes beside it. All three are
# COMPUTED from the record's own evidence rather than stored, for the reason the
# commitment register states: a stored state is a second claim that can disagree
# with the facts it summarises, and this one summarises facts - published parts,
# verified parts, staleness, closure - that are already durable.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_OUTBOUND_PUBLICATION_STATES='PREPARED
PARTIAL
COMPLETE_VERIFIED
STALE
TERMINAL'
FM_OUTBOUND_NEXT_REQUEST_STATES='NOT_ELIGIBLE
ELIGIBLE
EMITTED'
FM_OUTBOUND_DISPOSITION_STATES='OPEN
PUBLISHED'
}

# The declared vocabularies above are ENFORCED rather than documented. Each fold
# below computes a value and this predicate refuses one outside its axis's closed
# set, so a fold that grows a sixth publication state cannot ship it as prose: a
# vocabulary nothing checks is a comment wearing a constant's clothes, and this
# module has already written down that an unemitted constant documents a
# classification that cannot occur.
fm_outbound_material_lifecycle_valid() {  # <vocabulary> <value>
  printf '%s\n' "$1" | grep -qxF "$2"
}

# Material refusal and could-not-observe tokens, under the same rule as the
# vocabulary above: every token here must have an emit site, and the test that
# reads these declarations refuses one this module never expands.
# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
{
FM_OUTBOUND_TOKEN_MATERIAL_ABSENT=FM_OUTBOUND_MATERIAL_ABSENT
FM_OUTBOUND_TOKEN_MANIFEST_UNREADABLE=FM_OUTBOUND_MATERIAL_MANIFEST_UNREADABLE
FM_OUTBOUND_TOKEN_UNIVERSE_INCOMPLETE=FM_OUTBOUND_MATERIAL_UNIVERSE_INCOMPLETE
FM_OUTBOUND_TOKEN_UNIVERSE_UNCERTAIN=FM_OUTBOUND_MATERIAL_UNIVERSE_UNCERTAIN
FM_OUTBOUND_TOKEN_VENUE_INVALID=FM_OUTBOUND_MATERIAL_VENUE_INVALID
FM_OUTBOUND_TOKEN_VENUE_MISMATCH=FM_OUTBOUND_MATERIAL_VENUE_MISMATCH
FM_OUTBOUND_TOKEN_PART_BOUND=FM_OUTBOUND_MATERIAL_PART_BOUND_EXCEEDED
FM_OUTBOUND_TOKEN_PART_MISSING=FM_OUTBOUND_MATERIAL_PART_MISSING
FM_OUTBOUND_TOKEN_PART_UNREADABLE=FM_OUTBOUND_MATERIAL_PART_UNREADABLE
FM_OUTBOUND_TOKEN_IDENTITY_COLLISION=FM_OUTBOUND_MATERIAL_IDENTITY_COLLISION
FM_OUTBOUND_TOKEN_GENERATION_MISMATCH=FM_OUTBOUND_MATERIAL_GENERATION_MISMATCH
FM_OUTBOUND_TOKEN_RECONSTRUCTION=FM_OUTBOUND_MATERIAL_RECONSTRUCTION_MISMATCH
FM_OUTBOUND_TOKEN_COLLECTION_TRUNCATED=FM_OUTBOUND_MATERIAL_COLLECTION_TRUNCATED
FM_OUTBOUND_TOKEN_SUBJECT_MOVED=FM_OUTBOUND_MATERIAL_SUBJECT_MOVED
FM_OUTBOUND_TOKEN_ALREADY_COMPLETE=FM_OUTBOUND_MATERIAL_ALREADY_COMPLETE
FM_OUTBOUND_TOKEN_NOT_STALE=FM_OUTBOUND_MATERIAL_NOT_STALE
FM_OUTBOUND_TOKEN_PAYLOAD_UNREADABLE=FM_OUTBOUND_MATERIAL_PAYLOAD_UNREADABLE
FM_OUTBOUND_TOKEN_MATERIAL_COMPLETE=FM_OUTBOUND_MATERIAL_COMPLETE_VERIFIED
}

# --- venue identity ----------------------------------------------------------
#
# THE VENUE IS BOUND INTO THE RECORD, AND THE RECORD IS THE AUTHORITY.
#
# The single-comment path resolves its venue from config/sol-control.json on
# every read, which is correct for it: one fleet, one control issue, and a
# request that is re-derived from live state each time. Material publication
# cannot work that way. A generation is published to ONE issue over many calls
# and many minutes, and re-reading a process-global default between those calls
# means an edit to the config silently retargets a half-published generation -
# parts on one issue, the rest on another, and a completion that reconstructs
# from neither. So the venue is captured once at preparation and every later
# call addresses THAT venue. The configured default seeds it; it never overrides
# it.
fm_outbound_venue_valid() {  # <repository> <issue>
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' || return 1
  # A positive integer, so "0", "007" and "9x" are all refused. An issue number
  # is an identity, and a leading zero makes two spellings of one identity.
  printf '%s' "$2" | grep -Eq '^[1-9][0-9]*$'
}

fm_outbound_venue_canonical() {  # <repository> <issue>
  printf '%s#%s\n' "$1" "$2"
}

fm_outbound_venue_split() {  # <repo#issue> -> repository<TAB>issue
  local venue=$1 repo issue
  case $venue in *'#'*) ;; *) return 1 ;; esac
  repo=${venue%#*}
  issue=${venue##*#}
  fm_outbound_venue_valid "$repo" "$issue" || return 1
  printf '%s\t%s\n' "$repo" "$issue"
}

# --- the declared universe ---------------------------------------------------

fm_outbound_material_class_valid() {  # <classification>
  printf '%s\n' "$FM_OUTBOUND_MATERIAL_CLASSES" | grep -qxF "$1"
}

# COMPLETE-UNIVERSE ACCOUNTING, AS ONE FOLD AND THREE VALUES.
#
# The question is not "did every entry publish" but "is the set of entries the
# whole set there was". Those are different, and only the second can refuse a
# publication that is internally consistent about a universe someone silently
# trimmed. So the manifest declares how many artifacts the universe REQUIRES,
# independently of how many it lists, and this fold compares them.
#
# Prints one tab-separated row:
#   <required> <classified> <exact> <derivative> <omitted> <duplicates> <verdict>
# verdict is complete | incomplete | uncertain, and uncertain is a real answer:
# a manifest that cannot be parsed, that declares no required total, that
# carries an entry outside the closed class vocabulary, or that declares an
# EMPTY universe is not a clean universe - it is one nobody measured. A
# publication is allowed to proceed on `complete` alone.
fm_outbound_material_accounting() {  # <manifest-json>
  local out
  out=$(printf '%s' "$1" | jq -r --argjson classes "$(printf '%s\n' "$FM_OUTBOUND_MATERIAL_CLASSES" | jq -Rn '[inputs | select(length > 0)]')" '
    def uncertain: [-1,-1,-1,-1,-1,-1,"uncertain"];
    if type != "object" then uncertain
    elif (.required_total | type) != "number" or (.entries | type) != "array" then uncertain
    else
      (.required_total) as $req
      | (.entries) as $e
      | ($e | length) as $n
      | ([$e[] | select(.classification == "EXACT")] | length) as $x
      | ([$e[] | select(.classification == "DERIVATIVE_OF_PUBLISHED_AUTHORITY")] | length) as $d
      | ($n - ($e | map(.path) | unique | length)) as $dup
      | ($req - $n) as $om
      | [$req, $n, $x, $d, $om, $dup,
         (if ($req < 1)
             or ($e | any((.classification // "") as $c | ($classes | index($c)) == null))
             or ($e | any(.path == null or .digest == null))
             # A DERIVATIVE entry that names no published authority claims to
             # derive from something and declines to say what. What it grants
             # cannot be established from it, so the universe it belongs to
             # cannot be counted - uncertain, not merely short.
             or ($e | any(.classification == "DERIVATIVE_OF_PUBLISHED_AUTHORITY"
                          and ((.authority // "") == "")))
             or (($x + $d) != $n)
          then "uncertain"
          elif ($dup != 0) or ($om != 0) then "incomplete"
          else "complete" end)]
    end | @tsv' 2>/dev/null) || out=
  if [ -z "$out" ]; then
    printf -- '-1\t-1\t-1\t-1\t-1\t-1\tuncertain\n'
    return 0
  fi
  printf '%s\n' "$out"
}

# The canonical entry table. Deterministic across shells and jq versions:
# entries in path order, a fixed field order, and an absent optional field as
# the literal "-" so "no bound authority" and "authority field omitted" cannot
# collide into one digest - the same rule the request identity already uses.
fm_outbound_material_canonical() {  # <manifest-json>
  printf '%s' "$1" | jq -r \
    --arg schema "$FM_OUTBOUND_MATERIAL_MANIFEST_SCHEMA" '
    "manifest-schema=" + $schema,
    "subject=" + (.subject // "-"),
    "required-total=" + ((.required_total // 0) | tostring),
    (.entries | sort_by(.path)[]
      | "entry=" + .path
        + " class=" + .classification
        + " digest=" + .digest
        + " bytes=" + ((.bytes // 0) | tostring)
        + " authority=" + (.authority // "-"))'
}

# --- part identity -----------------------------------------------------------
#
# The identity is bound to the POSITION and not to the content, which is the
# opposite of every other digest here and is the deliberate choice that makes a
# collision detectable at all. Content-bound identities cannot collide by
# construction, so two comments carrying different bytes for one part would be
# two unrelated parts and the wrong-bytes case would have no name. Position-bound
# identities let exactly that be observed: same identity, different part digest,
# refused as a collision.
fm_outbound_part_identity_canonical() {  # <request-id> <generation> <subject-digest> <index> <total>
  printf 'request=%s\ngeneration=%s\nsubject=%s\nindex=%s\ntotal=%s\n' \
    "$1" "$2" "$3" "$4" "$5"
}

fm_outbound_part_identity() {  # <request-id> <generation> <subject-digest> <index> <total>
  fm_outbound_part_identity_canonical "$@" | fm_outbound_sha256
}

# A bounded positive count, stated here rather than at the call site so the
# bound is part of the contract and not of one command's argument parsing.
fm_outbound_material_total_valid() {  # <total> <max>
  case $1 in ''|*[!0-9]*) return 1 ;; esac
  case $2 in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -ge 1 ] || return 1
  [ "$1" -le "$2" ]
}

# --- the wire ----------------------------------------------------------------

# One part's exact body. Every binding field the verifier compares appears
# verbatim and on its own line, so verification is whole-line equality rather
# than a parse: the same discipline artifact_body_matches_identity already uses
# for a request.
fm_outbound_material_part_body() {  # <record-json> <index> <identity> <chunk-digest> <chunk-file>
  local rec=$1 index=$2 identity=$3 chunk_digest=$4 chunk=$5
  local rid gen subject manifest venue total
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  manifest=$(printf '%s' "$rec" | jq -r '.material.generation.manifest_identity')
  venue=$(printf '%s' "$rec" | jq -r \
    '.material.venue.repository + "#" + (.material.venue.issue | tostring)')
  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  printf '%s %s\n\n' "$FM_OUTBOUND_MATERIAL_BODY_MARKER" "$identity"
  printf 'from: firstmate\n'
  printf 'protocol: %s\n' "$FM_OUTBOUND_PROTOCOL"
  printf 'request: %s\n' "$rid"
  printf 'generation: %s\n' "$gen"
  printf 'subject: %s\n' "$subject"
  printf 'manifest: %s\n' "$manifest"
  printf 'venue: %s\n' "$venue"
  printf 'part: %s/%s\n' "$index" "$total"
  printf 'part-digest: %s\n' "$chunk_digest"
  printf '\nThis part carries material bytes and rules on nothing.\n'
  printf 'It is one member of a generation that is complete only when every part reconstructs the exact subject digest above.\n'
  printf '\n%s\n' "$FM_OUTBOUND_MATERIAL_FENCE_BEGIN"
  cat "$chunk"
  printf '%s\n' "$FM_OUTBOUND_MATERIAL_FENCE_END"
}

# THE VENUE IS ITS OWN QUESTION, asked separately and answered under its own
# name. Folding it into the generation check would report "wrong generation" for
# a part that names this generation perfectly and was addressed to a different
# issue, and the repair for those two is nothing alike: one regenerates a
# publication, the other retargets it. This module's own header already records
# that two tokens were lost exactly this way - the condition detected at a live
# site and reported under a neighbouring token - so the split is written into the
# predicates rather than left to the caller's discipline.
fm_outbound_material_part_venue_binds() {  # <body> <record-json>
  local venue
  venue=$(printf '%s' "$2" | jq -r \
    '.material.venue.repository + "#" + (.material.venue.issue | tostring)')
  printf '%s\n' "$1" | grep -Fqx "venue: $venue"
}

# Does this body bind to exactly this part of exactly this generation? Whole-line
# equality on every axis, so a body that agrees about the request and disagrees
# about the generation is refused rather than adopted.
fm_outbound_material_part_binds() {  # <body> <record-json> <index> <identity>
  local body=$1 rec=$2 index=$3 identity=$4
  local rid gen subject manifest total
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  manifest=$(printf '%s' "$rec" | jq -r '.material.generation.manifest_identity')
  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  printf '%s\n' "$body" | grep -Fqx "$FM_OUTBOUND_MATERIAL_BODY_MARKER $identity" \
    && printf '%s\n' "$body" | grep -Fqx "request: $rid" \
    && printf '%s\n' "$body" | grep -Fqx "generation: $gen" \
    && printf '%s\n' "$body" | grep -Fqx "subject: $subject" \
    && printf '%s\n' "$body" | grep -Fqx "manifest: $manifest" \
    && printf '%s\n' "$body" | grep -Fqx "part: $index/$total"
}

# The part digest the body CLAIMS, or empty. Exactly one such line or none:
# two claims is an ambiguous body, and an ambiguous body is could-not-observe
# rather than a value to read by position.
fm_outbound_material_part_claimed_digest() {  # <body>
  local lines count
  lines=$(printf '%s\n' "$1" | sed -n 's/^part-digest: //p')
  count=$(printf '%s\n' "$lines" | grep -c . || true)
  case $count in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$lines"
}

# The fenced chunk, byte for byte. Exactly one complete fenced block or a
# refusal: zero is an unreadable part and two is an ambiguous one, and neither
# is a chunk to hash.
fm_outbound_material_part_chunk() {  # <body>
  local body=$1 opens closes
  # `--` is load-bearing: both fences begin with a dash, so without it grep
  # reads the pattern as an option bundle and the chunk is never found. The test
  # library carries the same guard on assert_grep for the same reason.
  opens=$(printf '%s\n' "$body" | grep -cFx -- "$FM_OUTBOUND_MATERIAL_FENCE_BEGIN" || true)
  closes=$(printf '%s\n' "$body" | grep -cFx -- "$FM_OUTBOUND_MATERIAL_FENCE_END" || true)
  case $opens in ''|*[!0-9]*) opens=0 ;; esac
  case $closes in ''|*[!0-9]*) closes=0 ;; esac
  [ "$opens" -eq 1 ] && [ "$closes" -eq 1 ] || return 1
  printf '%s\n' "$body" | awk \
    -v b="$FM_OUTBOUND_MATERIAL_FENCE_BEGIN" \
    -v e="$FM_OUTBOUND_MATERIAL_FENCE_END" '
    $0 == e { inside = 0; next }
    inside { print }
    $0 == b { inside = 1 }'
}

# --- computed lifecycle ------------------------------------------------------
#
# THREE AXES, FOLDED SEPARATELY, BECAUSE THEY ANSWER THREE QUESTIONS.
#
# publication_state  is the material published and proven?
# next_request_state has the transition this publication gates been taken?
# disposition_state  is the correlation itself finished?
#
# A publication can be COMPLETE_VERIFIED with its correlation still OPEN, and
# that is the ordinary shape rather than an anomaly: proving the bytes arrived
# is not the same as recording what came of them. Folding the three into one
# state would make the finished-looking case indistinguishable from the finished
# one, which is the exact conflation the terminal-disposition control refuses.

fm_outbound_material_publication_state() {  # <record-json>
  local rec=$1 state published total
  printf '%s' "$rec" | jq -e '.material.schema? != null' >/dev/null 2>&1 || return 1
  state=$(printf '%s' "$rec" | jq -r '.state // ""')
  case $state in
    closed|superseded) printf 'TERMINAL\n'; return 0 ;;
  esac
  if printf '%s' "$rec" | jq -e '.material.stale != null' >/dev/null 2>&1; then
    printf 'STALE\n'; return 0
  fi
  if printf '%s' "$rec" | jq -e '.material.completed != null' >/dev/null 2>&1; then
    printf 'COMPLETE_VERIFIED\n'; return 0
  fi
  published=$(printf '%s' "$rec" | jq -r '.material.parts.published | length')
  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  case $published in ''|*[!0-9]*) return 1 ;; esac
  case $total in ''|*[!0-9]*) return 1 ;; esac
  if [ "$published" -eq 0 ]; then printf 'PREPARED\n'; else printf 'PARTIAL\n'; fi
}

fm_outbound_material_next_request_state() {  # <record-json>
  local rec=$1
  printf '%s' "$rec" | jq -e '.material.schema? != null' >/dev/null 2>&1 || return 1
  if printf '%s' "$rec" | jq -e '.material.next_request != null' >/dev/null 2>&1; then
    printf 'EMITTED\n'; return 0
  fi
  if [ "$(fm_outbound_material_publication_state "$rec")" = COMPLETE_VERIFIED ]; then
    printf 'ELIGIBLE\n'; return 0
  fi
  printf 'NOT_ELIGIBLE\n'
}

fm_outbound_material_disposition_state() {  # <record-json>
  local rec=$1
  printf '%s' "$rec" | jq -e '.material.schema? != null' >/dev/null 2>&1 || return 1
  if printf '%s' "$rec" | jq -e '.disposition != null' >/dev/null 2>&1; then
    printf 'PUBLISHED\n'
  else
    printf 'OPEN\n'
  fi
}

# --- record construction -----------------------------------------------------

fm_outbound_material_new() {  # <repo> <issue> <rid> <generation> <manifest-identity> <subject-digest> <total> <identities-json> <accounting-json> <now>
  jq -n \
    --arg schema "$FM_OUTBOUND_MATERIAL_SCHEMA" \
    --arg protocol "$FM_OUTBOUND_PROTOCOL" \
    --arg repository "$1" --argjson issue "$2" --arg request_id "$3" \
    --argjson generation "$4" --arg manifest "$5" --arg subject "$6" \
    --argjson total "$7" --argjson identities "$8" --argjson accounting "$9" \
    --arg now "${10}" \
    '{schema:$schema,
      venue:{repository:$repository,issue:$issue,protocol:$protocol,request_id:$request_id},
      generation:{artifact_generation:$generation,manifest_identity:$manifest,
                  subject_digest:$subject},
      parts:{total:$total,identities:$identities,published:{},verified:{}},
      accounting:$accounting,
      stale:null,
      completed:null,
      next_request:null,
      prepared:$now,
      history:[]}'
}

# The successor request body, emitted exactly once by the completion transition.
# It is a REQUEST like any other on this channel - it carries the request marker
# and the same binding lines - so the inbound ruling path joins onto it with no
# second correlation rule. What it adds is the proof the reviewer needs to find
# the material: the venue, the generation, and the exact digests that generation
# reconstructed to.
fm_outbound_material_next_request_body() {  # <record-json>
  local rec=$1 rid gen subject manifest venue total
  rid=$(printf '%s' "$rec" | jq -r '.request_id')
  gen=$(printf '%s' "$rec" | jq -r '.material.generation.artifact_generation')
  subject=$(printf '%s' "$rec" | jq -r '.material.generation.subject_digest')
  manifest=$(printf '%s' "$rec" | jq -r '.material.generation.manifest_identity')
  venue=$(printf '%s' "$rec" | jq -r \
    '.material.venue.repository + "#" + (.material.venue.issue | tostring)')
  total=$(printf '%s' "$rec" | jq -r '.material.parts.total')
  printf '%s %s\n\n' "$FM_OUTBOUND_BODY_MARKER" "$rid"
  printf '%s\n' "$(printf '%s' "$rec" | jq -r '
    "from: firstmate",
    "gate: " + .identity.gate,
    "project: " + .identity.project,
    "repo: " + .identity.repo,
    "item: " + .identity.item,
    "pull-request: " + (.identity.pr // "-"),
    "exact-head: " + .identity.head,
    "requested: " + .created')"
  printf 'material-venue: %s\n' "$venue"
  printf 'material-generation: %s\n' "$gen"
  printf 'material-manifest: %s\n' "$manifest"
  printf 'material-subject: %s\n' "$subject"
  printf 'material-parts: %s\n' "$total"
  printf '\nThis request is bound to the exact head above.\n'
  printf 'The material generation above was reobserved at that venue and reconstructed to the exact subject digest named here.\n'
  printf 'A ruling on any other head is not applicable to it and will not be applied.\n'
}

# fail-closed-predicates: enforced
