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
FM_OUTBOUND_TOKEN_MISMATCH=FM_OUTBOUND_RULING_IDENTITY_MISMATCH
FM_OUTBOUND_TOKEN_DETECT_ONLY=FM_OUTBOUND_CHANNEL_DETECT_ONLY
FM_OUTBOUND_TOKEN_IN_FLIGHT=FM_OUTBOUND_EMIT_IN_FLIGHT
FM_OUTBOUND_TOKEN_SATISFIED=FM_OUTBOUND_SATISFIED
FM_OUTBOUND_TOKEN_IDENTITY=FM_OUTBOUND_IDENTITY_REFUSED
}

# --- digest ------------------------------------------------------------------

fm_outbound_digest() {  # reads stdin, prints 12 lowercase hex
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print substr($1,1,12)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print substr($1,1,12)}'
  else
    return 1
  fi
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
  printf 'fm-ob-%s\n' "$sum"
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

# The full predicate: exact width for this repository, and resolvable there when
# the repository is present.
fm_outbound_head_valid() {  # <candidate> <clone-dir>
  local candidate=$1 dir=$2 width
  width=$(fm_outbound_object_width "$dir")
  [ -n "$width" ] || return 1
  fm_outbound_is_sha "$candidate" "$width" || return 1
  # Resolvability beats shape wherever it can be observed.
  git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$candidate^{object}" \
    >/dev/null 2>&1
}

fm_outbound_binding_missing() {  # <gate> <project> <repo> <item> <head> [<clone-dir>]
  local gate=$1 project=$2 repo=$3 item=$4 head=$5 missing=0
  if [ -z "$gate" ] || ! fm_outbound_gate_valid "$gate"; then
    printf 'gate\n'; missing=1
  fi
  [ -n "$project" ] || { printf 'project\n'; missing=1; }
  [ -n "$repo" ] || { printf 'repo\n'; missing=1; }
  [ -n "$item" ] || { printf 'item\n'; missing=1; }
  # <clone-dir> is optional so existing callers keep working; without it the
  # width is undeterminable and the head is refused rather than assumed.
  fm_outbound_head_valid "$head" "${6:-}" || { printf 'head\n'; missing=1; }
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
    *never\ submitted*|*"no pull request"*|*"released for handoff"*)
      printf 'CONTRIBUTION_SUBMISSION_REQUIRED\n' ;;
    *exact_head_browser_review_required*|*"exact head browser review"*)
      printf 'EXACT_HEAD_BROWSER_REVIEW_REQUIRED\n' ;;
    *independent_browser_review_required*|*"independent browser review"*|*"independent review"*|*"independent acceptance"*|*"independently adjudicate"*)
      printf 'INDEPENDENT_BROWSER_REVIEW_REQUIRED\n' ;;
    *architecture_ruling_required*|*"architecture ruling"*)
      printf 'ARCHITECTURE_RULING_REQUIRED\n' ;;
    *awaiting_browser_sol*|*"awaiting browser sol"*|*"awaiting a browser sol"*)
      printf 'AWAITING_BROWSER_SOL\n' ;;
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

fm_outbound_record_new() {  # <id> <gate> <channel> <project> <repo> <item> <pr> <head> <venue> <now>
  jq -n \
    --arg schema "$FM_OUTBOUND_RECORD_SCHEMA" \
    --arg request_id "$1" --arg gate "$2" --arg channel "$3" \
    --arg project "$4" --arg repo "$5" --arg item "$6" \
    --arg pr "$7" --arg head "$8" --arg venue "$9" --arg now "${10}" \
    '{schema:$schema,
      request_id:$request_id,
      channel:$channel,
      identity:{gate:$gate,project:$project,repo:$repo,item:$item,
                pr:(if $pr == "" or $pr == "-" then null else $pr end),
                head:$head},
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

# fail-closed-predicates: enforced
