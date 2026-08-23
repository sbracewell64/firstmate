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
superseded
quarantined'

# The states in which a record is FINISHED. A finished record is preserved and
# stays readable - it is evidence - but it can never be applicable, never be
# adopted by a fresh emit, and never sustain a wait. `quarantined` is the one
# reached by ruling rather than by completion: a request that was malformed at
# birth, retired through this owner instead of hand-edited into validity.
FM_OUTBOUND_TERMINAL_STATES='closed
superseded
quarantined'

fm_outbound_state_terminal() {  # <state>
  printf '%s\n' "$FM_OUTBOUND_TERMINAL_STATES" | grep -qxF "$1"
}

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
# The read SUCCEEDED and cannot name one governed subject - distinct from
# VENUE_UNRESOLVED, which is about where the question is asked rather than what
# it is about, and from INCOMPLETE_BINDING, which is a positive contradiction.
FM_OUTBOUND_TOKEN_SUBJECT_UNRESOLVED=FM_OUTBOUND_SUBJECT_UNRESOLVED
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

# --- inbound ruling wire form ------------------------------------------------
#
# TWO WIRE FORMS REACH THIS FLEET, and only one of them was readable.
#
# The legacy form is the one this module wrote first: an `FM-SOL-RULING <id>`
# marker plus the request's own binding lines echoed back verbatim. The governed
# Browser Sol form declares itself instead - `protocol: fm-sol-control/v1`,
# `kind: ruling` - and names what it is answering in its opening fields.
#
# A real ruling was lost to that gap. Comment 5383943043 carried a HOLD for
# fm-ob-25c701e04893 in the typed form; the reader looked for a marker that was
# not there and returned FM_OUTBOUND_RULING_IDENTITY_MISMATCH - a claim that the
# ruling was about other work, when the truth was that this end could not read
# the form it came in.
#
# THEN READING IT BODY-WIDE BROKE THE OTHER DIRECTION, and that is the failure
# this parser is shaped around. A control issue is a CONVERSATION: rulings quote
# earlier rulings, requests carry fenced examples of the wire format, and
# operators paste protocol snippets while discussing them. Scanning a whole body
# for `protocol:` or `in_reply_to:` therefore finds fields that were never the
# body's own - a full poll reported dozens of ambiguous candidates from
# legitimate rulings quoting their predecessors, and read two compatibility
# REQUESTS as rulings because their fenced examples contained the legacy marker.
#
# So a ruling's identity is read from its ENVELOPE and nowhere else.
#
#   The envelope is the leading run of the body: unindented `key: value` lines
#   and blank lines, starting at the first non-blank line, ending at the first
#   line that is neither - a bare `key:` opening a block (`exact_subject:`), a
#   content section (`observed:`, `ruling:`, `stale_state_protection:`), an
#   indented line, a list item, or prose.
#
#   Fenced regions are removed before any of that, because a fenced block is by
#   definition an EXAMPLE of the protocol rather than an instance of it.
#
# Everything after the envelope is discussion. It is never a field, never a
# form declaration, and never an ambiguity - which is what lets a ruling quote
# its predecessor without becoming unreadable.
#
# ACCEPTING THE FORM IS NOT ACCEPTING THE VERDICT. Everything here answers "which
# request does this body speak about, and does its envelope say so once". What
# the ruling DECIDED stays a string this module records verbatim; whether that
# word authorizes anything is bin/fm-landing-authorization-lib.sh's closed list,
# where a word outside it - HOLD included - is unrecognized and stops the act.

# The typed form's kind, alongside the protocol constant it shares with the
# request wire form.
FM_OUTBOUND_RULING_KIND='ruling'

# The envelope of a body: the canonical top-level region, fences removed.
#
# POSITION IS THE RULE, not search. A line qualifies only where an envelope can
# still be running, so the first line that is not an unindented `key: value`,
# not a canonical marker line, and not blank ends it for good.
fm_outbound_ruling_envelope() {  # <body> -> the envelope's lines
  # The id pattern is rebuilt here as an ERE. FM_OUTBOUND_REQUEST_ID_PATTERN is a
  # BASIC regex - it spells its repeat `\{12\}` - and awk reads EXTENDED, where
  # that is a literal brace and matches nothing. Passing it through unchanged
  # silently stopped every legacy marker from being an envelope line.
  printf '%s\n' "$1" | awk -v marker="$FM_OUTBOUND_RULING_MARKER" \
    -v idpat="${FM_OUTBOUND_REQUEST_ID_PREFIX}[0-9a-f]{${FM_OUTBOUND_REQUEST_ID_HEX_WIDTH}}" '
    BEGIN { fence = 0; ended = 0; seen = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      # A fenced region is an EXAMPLE of the protocol, never an instance of it.
      if (line ~ /^[[:space:]]*(```|~~~)/) { fence = 1 - fence; next }
      if (fence) next
      if (ended) next
      if (line ~ /^[[:space:]]*$/) { next }          # blanks never end an envelope
      # The canonical legacy marker is an envelope line, so a body carrying both
      # forms is visible as one envelope holding two declarations.
      if (line ~ ("^" marker " " idpat "$")) { print line; seen = 1; next }
      # An unindented key with a NON-EMPTY value. A bare `key:` opens a block and
      # is where the envelope stops.
      if (line ~ /^[A-Za-z_][A-Za-z0-9_.-]*:[[:space:]]+[^[:space:]]/) { print line; seen = 1; next }
      ended = 1
    }' 2>/dev/null || true
}

# Read ONE field from an envelope.
#
# Prints the trimmed value and returns 0 only when exactly one envelope line IS
# that field. Returns 1 when absent and 2 when duplicated, because those are
# different repairs: one envelope forgot to say, the other said twice and cannot
# be resolved by taking either.
#
# The key is restricted to lowercase and underscore so it can never carry a
# regex metacharacter into the patterns below. Every caller passes a literal
# from this module; the guard is here so that stays true.
fm_outbound_envelope_field() {  # <envelope> <key> -> value; 0 unique · 1 absent · 2 duplicated
  local envelope=$1 key=$2 count value
  case $key in
    ''|*[!a-z_]*) return 2 ;;
  esac
  count=$(printf '%s\n' "$envelope" | grep -c "^$key:" || true)
  case $count in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -ne 0 ] || return 1
  [ "$count" -eq 1 ] || return 2
  value=$(printf '%s\n' "$envelope" | sed -n "s/^$key://p" | tr -d '\r')
  value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  printf '%s\n' "$value"
}

# Which wire form does this envelope declare, if either?
#
# Prints legacy | typed | both | none.
#
# The typed form must BEGIN with its preamble: the envelope's first two lines
# are exactly the protocol and the ruling kind. The legacy form must begin with
# its canonical marker line. Neither is discovered by search, so a quoted
# example cannot promote a comment into a ruling.
#
# `both` is a real answer rather than a preference order: an envelope declaring
# itself typed while also carrying a canonical legacy marker has two
# declarations and no stated precedence, and choosing one would be choosing for
# the sender.
fm_outbound_ruling_form() {  # <body> -> legacy|typed|both|none
  local body=$1 envelope first second legacy typed_present=0
  envelope=$(fm_outbound_ruling_envelope "$body")
  [ -n "$envelope" ] || { printf 'none\n'; return 0; }
  first=$(printf '%s\n' "$envelope" | sed -n '1p')
  second=$(printf '%s\n' "$envelope" | sed -n '2p')
  legacy=$(printf '%s\n' "$envelope" | grep -c "^$FM_OUTBOUND_RULING_MARKER " || true)
  case $legacy in ''|*[!0-9]*) legacy=0 ;; esac
  if printf '%s\n' "$envelope" | grep -qxF "protocol: $FM_OUTBOUND_PROTOCOL" \
     && printf '%s\n' "$envelope" | grep -qxF "kind: $FM_OUTBOUND_RULING_KIND"; then
    typed_present=1
  fi

  # TWO DECLARATIONS IN ONE ENVELOPE, in either combination. The sender stated no
  # precedence between them, so picking one would be picking for the sender.
  if [ "$legacy" -gt 1 ]; then printf 'both\n'; return 0; fi
  if [ "$typed_present" -eq 1 ] && [ "$legacy" -gt 0 ]; then printf 'both\n'; return 0; fi

  # A FORM MUST BEGIN ITS ENVELOPE. A preamble or marker further down is a field
  # the sender happened to include, not a declaration of what this body is, and
  # promoting it is how quoted examples became rulings.
  if [ "$first" = "protocol: $FM_OUTBOUND_PROTOCOL" ] \
     && [ "$second" = "kind: $FM_OUTBOUND_RULING_KIND" ]; then
    printf 'typed\n'; return 0
  fi
  case $first in
    "$FM_OUTBOUND_RULING_MARKER "*) printf 'legacy\n'; return 0 ;;
  esac
  printf 'none\n'
}

# The request id a TYPED envelope says it answers.
#
# FOUR ANSWERS, and the fourth is the one that matters. `in_reply_to` may name a
# request this mechanism does not correlate at all: measured on the live control
# issue, 37 of 43 typed rulings answer a foreign identity - a bare comment id, or
# an `FM-SOL-...` name - because this issue carries far more conversation than
# this fleet's own correlation records.
#
# That is NOT AMBIGUITY. Reporting it as such is what turned one poll into dozens
# of FM_OUTBOUND_AMBIGUOUS_CANDIDATES and drove the whole sweep to a failure
# status, over rulings that were never addressed to a request in this store. A
# ruling for someone else is simply not ours, and the honest handling is the same
# as for a comment carrying no request at all: pass over it in silence.
#
# Ambiguity is kept for the one case that genuinely cannot be resolved - the same
# field stated twice in one envelope - because there the body IS addressing us
# and we still cannot tell what it said.
#
#   0 a well-formed request id in this store's scheme
#   1 absent
#   2 stated more than once in the envelope: ambiguous
#   3 stated once, but naming an identity this mechanism does not correlate
fm_outbound_typed_ruling_request() {  # <body> -> request id
  local body=$1 value rc
  value=$(fm_outbound_envelope_field "$(fm_outbound_ruling_envelope "$body")" in_reply_to); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$value" | grep -q "^$FM_OUTBOUND_REQUEST_ID_PATTERN\$" || return 3
  printf '%s\n' "$value"
}

# The request id a LEGACY envelope declares, from its canonical first line.
fm_outbound_legacy_ruling_request() {  # <body> -> request id; 0 unique · 1 absent · 2 unusable
  local body=$1 envelope lines value
  envelope=$(fm_outbound_ruling_envelope "$body")
  lines=$(printf '%s\n' "$envelope" | grep -c "^$FM_OUTBOUND_RULING_MARKER " || true)
  case $lines in ''|*[!0-9]*) lines=0 ;; esac
  [ "$lines" -ne 0 ] || return 1
  [ "$lines" -eq 1 ] || return 2
  value=$(printf '%s\n' "$envelope" \
    | sed -n "s/^$FM_OUTBOUND_RULING_MARKER \($FM_OUTBOUND_REQUEST_ID_PATTERN\)\$/\1/p")
  [ -n "$value" ] || return 2
  printf '%s\n' "$value"
}

# --- digest ------------------------------------------------------------------

FM_OUTBOUND_REQUEST_ID_PREFIX='fm-ob-'
FM_OUTBOUND_REQUEST_ID_HEX_WIDTH=12
FM_OUTBOUND_REQUEST_ID_PATTERN="${FM_OUTBOUND_REQUEST_ID_PREFIX}[0-9a-f]\\{${FM_OUTBOUND_REQUEST_ID_HEX_WIDTH}\\}"
export FM_OUTBOUND_REQUEST_ID_PATTERN

fm_outbound_digest() {  # reads stdin, prints a lowercase hex request digest
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk -v width="$FM_OUTBOUND_REQUEST_ID_HEX_WIDTH" '{print substr($1,1,width)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk -v width="$FM_OUTBOUND_REQUEST_ID_HEX_WIDTH" '{print substr($1,1,width)}'
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

# <gate> <project> <repo> <item> <pr> <head> [<tree>] [<policy>]
#
# TREE AND POLICY ARE APPENDED ONLY WHEN SUPPLIED, and that is a compatibility
# decision rather than an oversight. Every stored record's id is a digest of this
# text, and record_identity_verdict recomputes it to check the record against its
# own filename - so adding an unconditional field would change every existing
# id at once and turn the whole store adverse in a single release. A request that
# carries no governed tree or policy generation therefore keeps exactly the
# canonical form it has always had, and one that carries them gets a distinct
# identity. Which is also the behaviour the ruling asks for: a request bound to a
# different policy generation is a different question and must not be answerable
# by its predecessor.
#
# An absent OPTIONAL field inside the fixed prefix stays the literal "-", so "no
# pull request" and "pull request omitted" still cannot collide.
fm_outbound_identity_canonical() {
  printf 'gate=%s\nproject=%s\nrepo=%s\nitem=%s\npr=%s\nhead=%s\n' \
    "$1" "${2:--}" "${3:--}" "$4" "${5:--}" "${6:--}"
  [ -z "${7:-}" ] || printf 'tree=%s\n' "$7"
  [ -z "${8:-}" ] || printf 'policy=%s\n' "$8"
}

fm_outbound_request_id() {  # <gate> <project> <repo> <item> <pr> <head> -> id
  local sum
  sum=$(fm_outbound_identity_canonical "$@" | fm_outbound_digest) || return 1
  [ -n "$sum" ] || return 1
  printf '%s%s\n' "$FM_OUTBOUND_REQUEST_ID_PREFIX" "$sum"
}

# --- the governed decision subject -------------------------------------------
#
# THE SUBJECT IS NOT THE VENUE, and conflating them produced three malformed
# requests in a row. fm-ob-6267e1c729b9, fm-ob-26660534cd52 and
# fm-ob-7804557b2dfe each persisted `repo: sbracewell64/firstmate-sol-control`
# - the CONTROL issue's own repository - while binding a head that exists only
# in the governed repository the work actually lives in. Browser Sol ruled all
# three non-actionable for the same reason: a repository/head tuple that cannot
# identify one real subject is not a request, whatever else it carries.
#
# So a request now compiles its subject from ONE validated declaration, and the
# control repository and issue stay what they always were - the transport venue
# the question is asked at, recorded as venue metadata and nothing else.
#
# WHY THE SUBJECT REPOSITORY IS DECLARED RATHER THAN DERIVED. A clone's remotes
# look like an authority and are not one here: this fleet's own checkout carries
# `upstream` at the maintainer's repository and `origin` at the captain's fork,
# and the governed subject for its candidates is the FORK. Reading a remote by
# preference would therefore name the wrong repository confidently - the exact
# failure mode the ruling forbids - and a separate work item already owns that
# resolver's fork posture. A missing declaration is could-not-observe and
# refuses; it is never repaired from prose, path, config venue, or a reply.
#
# Prints the missing subject fields, one per line, and returns 1 when any is
# missing - the same shape as fm_outbound_binding_missing, so callers refuse the
# same way for both.
fm_outbound_clone_repos() {  # <clone-dir> -> distinct owner/name remotes, one per line
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  git --no-optional-locks -C "$1" remote -v 2>/dev/null \
    | awk '{ print $2 }' \
    | sed -e 's#\.git$##' -e 's#^git@[^:]*:##' -e 's#^[a-z+]*://[^/]*/##' \
    | grep -E '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$' \
    | sort -u
}

fm_outbound_subject_missing() {  # <repo> <venue-repo> <clone-dir> <tree> <head> [<declared>]
  local repo=$1 venue=$2 dir=$3 tree=$4 head=$5 declared=${6:-} missing=0 width
  # THE RULE THAT ALWAYS APPLIES: the venue is never the subject. This is the
  # ruled defect itself, and it is refused however the subject was arrived at.
  if [ -n "$venue" ] && [ "$repo" = "$venue" ]; then
    printf 'subject-repo-is-transport-venue\n'; missing=1
  fi
  if [ -z "$repo" ]; then
    printf 'subject-repo\n'; missing=1
  fi
  if [ -z "$declared" ] && [ "$missing" -eq 0 ] && [ -n "$dir" ] && [ -d "$dir" ]; then
    # A DERIVED subject is an OBSERVATION only while the clone names exactly one
    # repository. A clone that names two - a fork and the upstream it was forked
    # from - cannot say which one the review governs, and picking whichever the
    # venue rule happens to prefer would emit a governed request against a
    # repository nobody chose. That is an inference from the config venue, which
    # is precisely what a governed subject may not be built from, so it refuses.
    if [ "$(fm_outbound_clone_repos "$dir" | wc -l)" -gt 1 ]; then
      printf 'subject-repo-ambiguous\n'; missing=1
    fi
  fi
  # THE NAME-SHAPE AND KNOWN-TO-THE-CLONE RULES APPLY TO A DECLARED SUBJECT,
  # because a declaration is a claim about a named GitHub repository and can be
  # checked as one. Applying them to a derived subject would refuse every
  # project whose clone speaks in local paths rather than forge names, which is
  # a fleet-wide outage rather than a repair; the ambiguity rule above is what
  # keeps a derived subject honest.
  if [ -n "$declared" ] && [ "$missing" -eq 0 ]; then
    if ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
      printf 'subject-repo-malformed\n'; missing=1
    elif [ -n "$dir" ] && [ -d "$dir" ]; then
      # REFERENTIAL INTEGRITY WITHOUT THE NETWORK. The candidate is
      # intentionally unpublished and its remote branch is expected absent, so
      # remote resolution would refuse a subject that is perfectly valid. What
      # the clone CAN answer is whether it knows this repository at all, which
      # is what separates a real subject from a plausible-looking name.
      if ! git --no-optional-locks -C "$dir" remote -v 2>/dev/null \
         | sed -e 's#\.git[[:space:]]*(.*)$##' -e 's#[[:space:]]*(.*)$##' \
         | grep -qE "[:/]$(printf '%s' "$repo" | sed 's#[/.]#[/.]#g')\$"; then
        printf 'subject-repo-unknown-to-clone\n'; missing=1
      fi
    fi
  fi
  # A declared tree must be the tree of the declared head, or the subject
  # contradicts itself.
  if [ -n "$tree" ]; then
    width=$(fm_outbound_object_width "$dir")
    if [ -z "$width" ] || ! fm_outbound_is_sha "$tree" "$width"; then
      printf 'subject-tree-malformed\n'; missing=1
    elif [ -n "$head" ] && [ -d "$dir" ]; then
      if ! git --no-optional-locks -C "$dir" rev-parse --verify --quiet "$head^{tree}" 2>/dev/null \
         | grep -qxF "$tree"; then
        printf 'subject-tree-not-of-head\n'; missing=1
      fi
    fi
  fi
  [ "$missing" -eq 0 ]
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

# --- record subject ----------------------------------------------------------
#
# WHICH WORK ITEM IS THIS RECORD ABOUT, when the record's own bytes settle it?
#
# This exists because "is this record valid" and "is this record even about the
# work in front of me" are different questions, and answering the first in order
# to reach the second is what let ONE preserved adverse record stop EVERY new
# request in the fleet. A record filed for another item can be as broken as it
# likes without saying anything at all about the item being requested now, so a
# decision scoped to one item must be able to set that record aside WITHOUT
# certifying it - which is exactly what this predicate does and all it does.
#
# It is deliberately the WEAKEST reading in this module, and it grants nothing.
# It never certifies a record, never substitutes for a caller's own identity
# verdict, and a subject it prints belongs to a record that remains unvalidated
# in every other respect. Its ONLY licensed use is to skip a decision that
# provably does not concern this record. Reading it as "this record is fine"
# would rebuild, one level down, the collapse the identity vocabulary above
# exists to prevent.
#
# TWO VALUES HERE, BY CONSTRUCTION. It answers "the subject is exactly this" or
# "could not observe", and there is no third answer, because the caller that
# could not observe a subject must behave exactly as if the record were its own.
# Fail-closed lives in that asymmetry: an unobservable subject keeps the record
# in scope, so nothing is ever skipped on a guess.
#
# COUNT, THEN COMPARE - the same rule fm_outbound_sender_valid applies to
# `from:`, here for the same reason. jq resolves a duplicated object key to
# whichever copy was written LAST, so a record carrying two subjects reads as a
# record about one of them, chosen by write order. A record with two subjects is
# not a record about the last one; it is a record whose subject is AMBIGUOUS,
# and an ambiguous subject is could-not-observe rather than a value to pick
# from. The same count refuses a file holding more than one top-level document,
# where the paths collide and neither document owns the answer.
#
# The schema is counted the same way and required to match, because the meaning
# of `.identity.item` is defined by this record schema and nothing else. A field
# at that path in a document of some other shape is a string this module has no
# grounds to read as a work item.
#
# Prints the item and returns 0 only when every one of those holds. Returns 1 -
# could-not-observe - for unparsable JSON, more than one top-level document, an
# unknown or duplicated schema, and a missing, empty, non-string, or duplicated
# item.
fm_outbound_record_subject() {  # <record-json> -> item, or non-zero
  local raw=$1 item
  # --stream emits one [path,value] event per OCCURRENCE, so a duplicated key
  # arrives as two events rather than collapsing into the last one. That is the
  # whole reason the check is built on it rather than on an ordinary read.
  item=$(printf '%s' "$raw" | jq -rn --stream --arg s "$FM_OUTBOUND_RECORD_SCHEMA" '
    [inputs | select(length == 2)] as $events
    | [$events[] | select(.[0] == ["schema"]) | .[1]] as $schemas
    | [$events[] | select(.[0] == ["identity","item"]) | .[1]] as $items
    | if ($schemas | length) == 1 and $schemas[0] == $s
         and ($items | length) == 1
         and ($items[0] | type) == "string" and $items[0] != ""
      then $items[0] else empty end' 2>/dev/null) || return 1
  [ -n "$item" ] || return 1
  printf '%s\n' "$item"
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
    # A TYPED DECLARATION WINS OVER PROSE WHEREVER IT EXISTS, not only where the
    # row's hold-kind has already been migrated to `outbound`.
    #
    # Prose is a MIGRATION surface and it goes stale: a hold sentence is written
    # once and rarely rewritten, while the gate an item is actually at moves as
    # the work moves. Reading the stale sentence in preference to a current
    # declaration reproduced a PREDECESSOR's identity - measured on
    # candidate-publication-effect-guard, whose declaration had moved to
    # EXACT_HEAD_BROWSER_REVIEW_REQUIRED while its hold sentence still said
    # "Awaiting Browser Sol". The recomputed identity was the closed
    # AWAITING_BROWSER_SOL request, so a fresh gate silently adopted a finished
    # one instead of asking its own question.
    #
    # The TIER still says prose, because prose is what recognised the row as
    # waiting at all. Only the gate comes from the declaration, and only when
    # that declaration is valid; an absent or invalid one leaves the prose gate
    # exactly as it was.
    gate=
    if fm_outbound_gate_valid "$declared_gate"; then
      gate=$declared_gate
    else
      gate=$(fm_outbound_gate_from_prose "$hay")
    fi
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
  # Every FINISHED state is inapplicable, quarantined included: a request
  # retired as malformed answers nothing, which is the whole point of retiring
  # it rather than hand-editing it.
  if fm_outbound_state_terminal "$3"; then printf 'inapplicable\n'; return 0; fi
  if [ -z "$2" ]; then
    # The head could not be read. Never applicable-by-default: an unobservable
    # head is exactly when a silent pass would hide a moved one.
    printf 'unobservable\n'
    return 0
  fi
  if [ "$1" = "$2" ]; then printf 'applicable\n'; else printf 'inapplicable\n'; fi
}

# --- record construction -----------------------------------------------------

# <id> <gate> <channel> <project> <repo> <item> <pr> <head> <venue> <now>
#   [<head-source>] [<tree>] [<policy>]
#
# `repo` is the GOVERNED SUBJECT repository - what the request is about - while
# `venue` stays the transport location it is asked at. They were the same value
# for three malformed requests, which is what the ruling calls a repository/head
# tuple that cannot identify one real subject.
fm_outbound_record_new() {
  jq -n \
    --arg schema "$FM_OUTBOUND_RECORD_SCHEMA" \
    --arg request_id "$1" --arg gate "$2" --arg channel "$3" \
    --arg project "$4" --arg repo "$5" --arg item "$6" \
    --arg pr "$7" --arg head "$8" --arg venue "$9" --arg now "${10}" \
    --arg head_source "${11:-}" \
    --arg tree "${12:-}" --arg policy "${13:-}" \
    '{schema:$schema,
      request_id:$request_id,
      channel:$channel,
      identity:{gate:$gate,project:$project,repo:$repo,item:$item,
                pr:(if $pr == "" or $pr == "-" then null else $pr end),
                head:$head,head_source:$head_source,
                tree:(if $tree == "" then null else $tree end),
                policy:(if $policy == "" then null else $policy end)},
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
