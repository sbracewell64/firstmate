#!/usr/bin/env bash
# fm-slot-reservation-lib.sh - the single owner of the POOL SLOT RESERVATION
# record: its format, what may open one, and how its state is computed on read.
#
# Source it AFTER bin/fm-pool-lib.sh and bin/fm-landed-lib.sh, which own the
# record's location and the trunk's candidate ref set respectively; it defines
# and runs nothing on its own:
#   # shellcheck source=bin/fm-slot-reservation-lib.sh
#   . "$SCRIPT_DIR/fm-slot-reservation-lib.sh"
#
# bin/fm-slot-reservation.sh is the command surface, and
# bin/fm-worktree-guard.sh is the only consumer that acts on the state. Nothing
# else may parse this record.
#
# WHAT THIS IS FOR, AND THE HONEST BOUND ON IT
#
# On 2026-08-16 firstmate's trunk was red. The repair could not start because
# every pool slot held live work, and it stayed queued for hours behind
# unrelated dispatches while every lane cutting a worktree cut it from a broken
# trunk.
#
# THIS WOULD NOT HAVE FIXED THAT DAY. The fleet was genuinely full and the
# repair would still have waited. What a reservation does is bound the WORST
# CASE - the repair waits for the next slot rather than for a slot it happens to
# win - not remove the wait. It creates no capacity, guarantees no time bound,
# and promises no immediate start. Anything that describes it as preventing
# trunk-red starvation is describing a different feature.
#
# IT NEVER PREEMPTS. A reservation is only ever consulted about slots the pool
# guard has ALREADY proven empty, so no running lane is stopped, evicted, or
# reclaimed to satisfy one, and no slot holding unlanded work is touched. That
# is structural, not a policy: the reservation is read after the emptiness test,
# never in place of it, so there is no path through this file that hands out a
# slot the guard would otherwise have refused. A reservation that preempts is a
# different and more dangerous feature, and it stays off the table until lineage
# and salvage can prove preemption safe.
#
# IT RESERVES ONE SLOT, NOT THE POOL, AND IT DECIDES NO ORDER. At most one
# reservation exists per pool. A second one is refused while the first is held,
# rather than queued behind it: deciding which of several waiting requests goes
# first is a scheduler, and nobody has asked for one. The withheld slot is a
# single slot, so a pool with two empty slots still hands the second to ordinary
# work.
#
# WHAT COUNTS AS A TRUNK REPAIR
#
# A reservation that any task can claim by calling itself urgent is worthless,
# so the predicate is established from state this file resolves itself, never
# from what the requesting task says about itself. Opening one requires all of:
#
#   1. A PROJECT whose default branch this can resolve. The trunk ref is
#      resolved through bin/fm-landed-lib.sh, which already separates "there is
#      no such branch" from "the branch could not be read"; neither may open a
#      reservation, because a trunk nobody can name is not a trunk anybody can
#      repair.
#   2. A TRUNK HEAD this reads for itself. The caller supplies the ref, never
#      the commit: `open` resolves the tip and records it. There is therefore no
#      head for a caller to assert, and the recorded head is the exact commit
#      the reservation is about.
#   3. A FAIL OBSERVATION from bin/fm-verify.sh, supplied as that script's own
#      record. PASS is refused because a trunk observed good needs no repair,
#      and NO_VERIFIER_RAN is refused because an observation that did not happen
#      is not evidence of anything. The verifier name and evidence reference are
#      copied into the reservation, so which observation admitted it is readable
#      afterwards rather than inferred.
#
#   The third condition is corroboration, not proof, and saying so is part of
#   the contract: firstmate declares no trunk-checks verifier today
#   (bin/fm-verify.sh --list), so what this can require is that an observation
#   RAN and returned FAIL, not that this specific check proved this specific
#   trunk red. Declaring a trunk-checks verifier is the way to tighten it, and
#   until then the recorded verifier name is what a reader judges. What keeps
#   that proportionate is the bound above: a reservation grants no capacity and
#   cannot preempt, so the worst an unjustified one does is withhold one empty
#   slot, visibly, for at most its TTL.
#
# HOW STRONG THAT ADMISSION WAS IS TYPED, NOT LEFT TO PROSE. The paragraph above
# is a disclosure no consumer can read, so the strength of the evidence that
# admitted a reservation is a field with a closed vocabulary
# (FM_SLOT_RESERVATION_TIERS):
#
#   caller-asserted  the FAIL observation arrived as a record the caller handed
#                    over. Every admission today is this one, because no
#                    trunk-checks verifier is declared for `open` to run itself.
#   verified         the FAIL observation was produced by a declared
#                    trunk-checks verifier this resolved for itself.
#
# Declaring such a verifier UPGRADES an admission into the second tier; it never
# changes what the first one means, so a record already carrying
# caller-asserted keeps saying exactly what it said when it was written. A
# record whose evidence_tier is missing or outside that vocabulary is
# unreadable_record like any other malformed field, never quietly defaulted to
# either tier: guessing which strength a record meant is the one thing a typed
# tier exists to stop.
#
# THE RECORD. One file per pool, written atomically, keyed and located by
# bin/fm-pool-lib.sh:
#
#   fm-slot-reservation.v1     exact first line; anything else is unreadable
#   task=<id>                  the ONE task this slot is held for
#   project=<pool-real-path>   the pool, re-checked against the key on read
#   trunk_ref=<ref>            the ref whose tip was observed failing, kept for
#                              provenance: it says which ref `open` read, not
#                              which refs the release condition watches
#   trunk_head=<sha>           that tip, resolved by `open`, never supplied
#   opened=<epoch>             when the reservation was opened
#   ttl=<seconds>              how long it may withhold a slot at the outside
#   verifier=<name>            which bin/fm-verify.sh verifier observed FAIL
#   evidence_tier=<tier>       how strong that observation was, from the closed
#                              vocabulary above
#   evidence=<ref>             that observation's evidence reference
#
# STATE IS COMPUTED, NEVER STORED. Every state below is derived from the record
# plus the world at the moment of reading, in the same discipline as the
# commitment and qualification registers: a stored state is a claim that was
# true once and is asserted forever. Nothing in this file writes a state.
#
#   absent           no record. The ordinary case, and an observation in its own
#                    right - it is not the same fact as a record that could not
#                    be read, and the two never share a branch.
#   held             the record is readable, its TTL has not run out, and the
#                    trunk's candidate refs were enumerated COMPLETELY with none
#                    of them advanced past the recorded head. This is the only
#                    state that withholds a slot.
#   released         the reservation is over and withholds nothing. Its reason
#                    says which end it reached:
#                      landed_or_superseded  some candidate ref carrying the
#                                            trunk's name has a tip that differs
#                                            from the recorded head AND has that
#                                            head as an ancestor, so the trunk
#                                            advanced past the commit this
#                                            reservation was opened against: the
#                                            repair landed, or something else
#                                            ended the situation.
#                      expired               the TTL ran out. This is the
#                                            unconditional backstop for the
#                                            abandoned case, and it needs no
#                                            other condition to hold: a repair
#                                            that was dropped leaves a trunk
#                                            that never moves, so without a
#                                            clock the record would withhold a
#                                            slot until someone noticed it.
#   unobservable     the reservation's state could not be determined. NEVER
#                    narrowed into either of the other two. Its reason says what
#                    could not be observed:
#                      unreadable_record     the file exists and does not parse:
#                                            wrong version line, missing field,
#                                            malformed number, or a project that
#                                            does not match the pool it is keyed
#                                            under.
#                      trunk_unresolvable    the trunk's candidate refs could
#                                            not be enumerated at all, or none
#                                            of them could be read, or the list
#                                            was INCOMPLETE and no advance was
#                                            proven within it - so whether the
#                                            trunk moved is unknown.
#
# WHY THE TRUNK IS A CANDIDATE SET AND NOT ONE REF. bin/fm-landed-lib.sh owns
# that set, and owns it because refs/heads/<name> is the landing target only
# while something keeps fast-forwarding it. On a fetch-upstream/push-fork fleet
# the repair lands on the push target or on origin/<name> while the pool
# project's local branch sits exactly where it was, so a release condition
# watching that one ref never fires and the reservation withholds an empty slot
# until its TTL runs out instead. The advance is tested by ANCESTRY rather than
# by content containment: the recorded head is the trunk commit the reservation
# was opened against, and a trunk that advanced keeps it as an ancestor even
# when the repair itself landed squashed.
#
# INCOMPLETENESS KILLS THE NEGATIVE, NOT THE POSITIVE. A proven advance stands
# whatever went unread, so it releases on the first candidate that shows one.
# But "no candidate advanced" is a negative claim over the whole universe of
# candidates, and a list that could not be fully enumerated is not that
# universe, so an incomplete list with no advance found is could-not-observe
# rather than held. That is the same reasoning bin/fm-worktree-guard.sh already
# applies to an incomplete candidate list.
#
# WHAT A CONSUMER MUST DO WITH unobservable, AND WHY. It must not withhold a
# slot, and it must say so out loud. Withholding on a record nobody can read is
# exactly how a reservation becomes an invisible permanent hold, which is the
# failure this whole design is built to avoid; and silently ignoring it hides a
# broken record. So the slot goes to ordinary work, the reason is printed, and
# the TTL still runs underneath - which is why `expired` is checked BEFORE the
# trunk read. A clock is always readable, so a record past its TTL is released
# even when nothing else about it can be observed.
#
# RELEASE IS THEREFORE THREE THINGS, ALL STATED: the holder claims it, the trunk
# advances past the commit it names on any of its candidate refs, or its TTL
# runs out. No reservation survives all three.
set -u

# The default TTL, in seconds. Two hours, chosen against the failure it bounds
# rather than against how long a repair takes: expiry does not cancel a repair,
# it only stops withholding a slot for one, and re-opening is a single command
# that a still-red trunk plainly justifies. A TTL long enough to cover every
# repair would be long enough for an abandoned reservation to survive into a day
# nobody remembers opening it, which is the state this bound exists to prevent.
# shellcheck disable=SC2034 # Contract constant consumed by sourcing callers.
FM_SLOT_RESERVATION_TTL_DEFAULT=7200

FM_SLOT_RESERVATION_VERSION=fm-slot-reservation.v1

# The closed evidence-tier vocabulary described in the header. A later declared
# trunk-checks verifier admits into FM_SLOT_RESERVATION_TIER_VERIFIED; nothing
# may redefine what FM_SLOT_RESERVATION_TIER_CALLER_ASSERTED means, because
# records already written carry it.
# shellcheck disable=SC2034 # Contract constants consumed by sourcing callers.
FM_SLOT_RESERVATION_TIER_CALLER_ASSERTED=caller-asserted
# shellcheck disable=SC2034 # Contract constants consumed by sourcing callers.
FM_SLOT_RESERVATION_TIER_VERIFIED=verified

# Whether <value> is one of the tiers above. There is no default: a record that
# does not name its tier has not said how strong its admission was, and
# inventing an answer is exactly what the field exists to prevent.
fm_slot_reservation_tier_valid() {  # <value>
  case "${1:-}" in
    "$FM_SLOT_RESERVATION_TIER_CALLER_ASSERTED"|"$FM_SLOT_RESERVATION_TIER_VERIFIED") return 0 ;;
  esac
  return 1
}

# Results, set by fm_slot_reservation_read:
#   FM_SLOT_RESERVATION_STATE   absent | held | released | unobservable
#   FM_SLOT_RESERVATION_REASON  '' | landed_or_superseded | expired
#                               | unreadable_record | trunk_unresolvable
#   FM_SLOT_RESERVATION_DETAIL  one short human phrase, always set
#   FM_SLOT_RESERVATION_TASK    the holder, when the record parsed
#   FM_SLOT_RESERVATION_PATH    the record's path, when it could be resolved
# plus FM_SLOT_RESERVATION_{PROJECT,TRUNK_REF,TRUNK_HEAD,OPENED,TTL,VERIFIER,
#                           EVIDENCE_TIER,EVIDENCE}.
# shellcheck disable=SC2034 # Out-variables consumed by sourcing callers.
fm_slot_reservation_reset() {
  FM_SLOT_RESERVATION_STATE=absent
  FM_SLOT_RESERVATION_REASON=
  FM_SLOT_RESERVATION_DETAIL=
  FM_SLOT_RESERVATION_TASK=
  FM_SLOT_RESERVATION_PATH=
  FM_SLOT_RESERVATION_PROJECT=
  FM_SLOT_RESERVATION_TRUNK_REF=
  FM_SLOT_RESERVATION_TRUNK_HEAD=
  FM_SLOT_RESERVATION_OPENED=
  FM_SLOT_RESERVATION_TTL=
  FM_SLOT_RESERVATION_VERIFIER=
  FM_SLOT_RESERVATION_EVIDENCE_TIER=
  FM_SLOT_RESERVATION_EVIDENCE=
}

fm_slot_reservation_path() {  # <pool-real>
  fm_pool_state_path "$1" reservation .state
}

# The value of one key=value field, non-zero when there is not exactly one such
# line to read.
#
# A repeated key is refused rather than resolved: two assignments of the same
# field are two claims, and picking one silently is choosing which to believe.
#
# The status is read from grep itself, never from a count of its output. `grep -c`
# on a file it cannot read prints 0 and fails, so `count=$(grep -c ...) || count=0`
# would make an unreadable file indistinguishable from a file that simply has no
# such key. Both outcomes do reach the same conservative verdict in the caller -
# a required field this could not produce is unreadable_record, which is
# could-not-observe - but they reach it because the caller decided that, not
# because this function threw the difference away.
fm_slot_reservation_field() {  # <file> <key>
  local file=$1 key=$2 matches status
  matches=$(grep "^${key}=" "$file" 2>/dev/null)
  status=$?
  [ "$status" -eq 0 ] || return 1
  case "$matches" in
    *$'\n'*) return 1 ;;
  esac
  printf '%s\n' "${matches#*=}"
}

fm_slot_reservation_positive_int() {  # <value>
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# Whether <value> is the shape git prints for a FULL resolved object name: 40
# hex characters under SHA-1, 64 under SHA-256.
#
# A full name rather than any abbreviation, because the recorded head is
# compared for exact equality against `git rev-parse` output. An abbreviation
# would parse as usable and then never equal any tip, so a hand-edited short
# head would read as a trunk advance that did not happen and silently drop the
# reservation. A head this cannot use is unreadable_record, which withholds
# nothing and says why.
fm_slot_reservation_sha_shape() {  # <value>
  local value=${1:-}
  case "${#value}" in
    40|64) ;;
    *) return 1 ;;
  esac
  case "$value" in
    *[!0-9a-f]*) return 1 ;;
  esac
  return 0
}

# shellcheck disable=SC2034 # Out-variables consumed by sourcing callers.
fm_slot_reservation_unobservable() {  # <reason> <detail>
  FM_SLOT_RESERVATION_STATE=unobservable
  FM_SLOT_RESERVATION_REASON=$1
  FM_SLOT_RESERVATION_DETAIL=$2
  return 0
}

# Read and classify the reservation for <pool-real>, at <now> epoch seconds.
# Always returns 0: the answer is the state, and every outcome including "this
# could not be observed" is an answer rather than a failure to produce one.
# shellcheck disable=SC2034 # Out-variables consumed by sourcing callers.
fm_slot_reservation_read() {  # <pool-real> <now-epoch>
  local pool=$1 now=$2 file task project ref head opened ttl verifier evidence
  local version age tier
  local name refs status candidate tip incomplete=0 observed=0
  fm_slot_reservation_reset
  if ! file=$(fm_slot_reservation_path "$pool"); then
    fm_slot_reservation_unobservable unreadable_record \
      "the pool's machine-private state directory could not be resolved or validated"
    return 0
  fi
  FM_SLOT_RESERVATION_PATH=$file
  if [ ! -e "$file" ]; then
    FM_SLOT_RESERVATION_DETAIL="no slot is reserved in this pool"
    return 0
  fi
  if [ -L "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file is not a readable regular file"
    return 0
  fi
  version=$(head -1 "$file" 2>/dev/null) || version=
  if [ "$version" != "$FM_SLOT_RESERVATION_VERSION" ]; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file does not start with $FM_SLOT_RESERVATION_VERSION"
    return 0
  fi
  task=$(fm_slot_reservation_field "$file" task) || task=
  project=$(fm_slot_reservation_field "$file" project) || project=
  ref=$(fm_slot_reservation_field "$file" trunk_ref) || ref=
  head=$(fm_slot_reservation_field "$file" trunk_head) || head=
  opened=$(fm_slot_reservation_field "$file" opened) || opened=
  ttl=$(fm_slot_reservation_field "$file" ttl) || ttl=
  verifier=$(fm_slot_reservation_field "$file" verifier) || verifier=
  tier=$(fm_slot_reservation_field "$file" evidence_tier) || tier=
  evidence=$(fm_slot_reservation_field "$file" evidence) || evidence=
  if [ -z "$task" ] || [ -z "$project" ] || [ -z "$ref" ]; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file does not carry exactly one readable task, project and trunk_ref"
    return 0
  fi
  if ! fm_slot_reservation_sha_shape "$head"; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file records no usable trunk_head"
    return 0
  fi
  if ! fm_slot_reservation_tier_valid "$tier"; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file records no evidence_tier in the closed vocabulary ($FM_SLOT_RESERVATION_TIER_CALLER_ASSERTED, $FM_SLOT_RESERVATION_TIER_VERIFIED)"
    return 0
  fi
  if ! fm_slot_reservation_positive_int "$opened" || ! fm_slot_reservation_positive_int "$ttl"; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file records no usable opened/ttl pair"
    return 0
  fi
  # The record is keyed by pool, so a project field naming a different pool
  # means the two disagree about what this file is for. That is a record whose
  # subject cannot be established, not a reservation for either pool.
  if [ "$project" != "$pool" ]; then
    fm_slot_reservation_unobservable unreadable_record \
      "$file is keyed to $pool but records project=$project"
    return 0
  fi
  FM_SLOT_RESERVATION_TASK=$task
  FM_SLOT_RESERVATION_PROJECT=$project
  FM_SLOT_RESERVATION_TRUNK_REF=$ref
  FM_SLOT_RESERVATION_TRUNK_HEAD=$head
  FM_SLOT_RESERVATION_OPENED=$opened
  FM_SLOT_RESERVATION_TTL=$ttl
  FM_SLOT_RESERVATION_VERIFIER=$verifier
  FM_SLOT_RESERVATION_EVIDENCE_TIER=$tier
  FM_SLOT_RESERVATION_EVIDENCE=$evidence
  # The clock first, deliberately. It is the one condition that is readable
  # whatever else is broken, so a record past its TTL releases even when the
  # trunk cannot be read at all - which is what stops an unobservable record
  # from being held open by its own unreadability.
  if ! fm_slot_reservation_positive_int "$now"; then
    fm_slot_reservation_unobservable unreadable_record \
      "the current time could not be read, so the reservation's age is unknown"
    return 0
  fi
  age=$((now - opened))
  if [ "$age" -ge "$ttl" ]; then
    FM_SLOT_RESERVATION_STATE=released
    FM_SLOT_RESERVATION_REASON=expired
    FM_SLOT_RESERVATION_DETAIL="opened ${age}s ago, past its ${ttl}s limit"
    return 0
  fi
  # The trunk is the candidate set bin/fm-landed-lib.sh owns, not the single ref
  # the record names for provenance. See the header: refs/heads/<name> is the
  # landing target only while something keeps fast-forwarding it.
  #
  # Both non-zero statuses refuse together: "no such branch" and "the branches
  # could not be read" are different facts, and neither of them enumerates a
  # universe this could take a negative over.
  if ! name=$(fm_landed_default_branch_name "$pool"); then
    fm_slot_reservation_unobservable trunk_unresolvable \
      "$pool names no readable default branch, so whether the trunk moved past $head is unknown"
    return 0
  fi
  refs=$(fm_landed_candidate_refs "$pool" "$name")
  status=$?
  # 0 complete with candidates, 1 a PROVEN empty universe, 2 INCOMPLETE and the
  # printed list is short. Only the third can still carry candidates worth
  # reading, and reading them can still prove an advance.
  [ "$status" -ne 2 ] || incomplete=1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    tip=$(git --no-optional-locks -C "$pool" rev-parse --verify --quiet "$candidate" 2>/dev/null) || tip=
    if [ -z "$tip" ]; then
      incomplete=1
      continue
    fi
    observed=$((observed + 1))
    [ "$tip" != "$head" ] || continue
    git --no-optional-locks -C "$pool" merge-base --is-ancestor "$head" "$tip" 2>/dev/null
    status=$?
    case "$status" in
      0)
        FM_SLOT_RESERVATION_STATE=released
        FM_SLOT_RESERVATION_REASON=landed_or_superseded
        FM_SLOT_RESERVATION_DETAIL="$candidate has advanced from $head to $tip"
        return 0
        ;;
      1) : ;;
      *) incomplete=1 ;;
    esac
  done <<EOF
$refs
EOF
  # A positive stands on its own, so the loop above returns the moment one ref
  # proves an advance. Everything from here is the NEGATIVE, and a negative is
  # only as good as the universe it was taken over.
  if [ "$observed" -eq 0 ]; then
    fm_slot_reservation_unobservable trunk_unresolvable \
      "no ref carrying $name could be read in $pool, so whether the trunk moved past $head is unknown"
    return 0
  fi
  if [ "$incomplete" -ne 0 ]; then
    fm_slot_reservation_unobservable trunk_unresolvable \
      "$pool's refs carrying $name could not be read in full, so an advance past $head cannot be ruled out"
    return 0
  fi
  FM_SLOT_RESERVATION_STATE=held
  FM_SLOT_RESERVATION_DETAIL="held for $task against $name at $head"
  return 0
}
