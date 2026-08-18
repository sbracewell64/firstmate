#!/usr/bin/env bash
# fm-slot-reservation.sh - the command surface for a worktree pool's single slot
# reservation: open one for a queued trunk repair, read its computed state,
# claim it, or release it.
#
# bin/fm-slot-reservation-lib.sh is the single owner of the record format, the
# admission predicate, the state vocabulary, and the honest bound on what a
# reservation does and does not do. Read that header before changing anything
# here; this file only turns those into commands.
#
# In one line, so it is not lost between the two: a reservation makes a queued
# trunk repair wait for the NEXT slot that frees rather than for a slot it
# happens to win. It creates no capacity, preempts nothing, and guarantees no
# time bound.
#
# Usage:
#   fm-slot-reservation.sh open <task-id> --project <dir> --verdict <file>
#                               [--trunk-ref <ref>] [--ttl <seconds>]
#       Reserve this pool's next free slot for <task-id>. --verdict is a
#       bin/fm-verify.sh record; only result=FAIL admits a reservation. The
#       trunk ref defaults to the project's resolved default branch, and its
#       HEAD is read here rather than supplied. Refuses while a reservation is
#       already held, naming the holder - one pool holds one reservation, and
#       choosing between several waiting requests is a scheduler this
#       deliberately is not.
#   fm-slot-reservation.sh status --project <dir> [--for <task-id>]
#       Print one record for the pool's reservation and exit by its state:
#       0 held, 1 absent or released, 2 unobservable. With --for, a `holder:`
#       line reports whether that task is the one the slot is held for.
#   fm-slot-reservation.sh claim <task-id> --project <dir>
#       Consume the reservation because <task-id> has just been handed the slot.
#       Exit 0 when it was consumed, 1 when there was nothing to consume or it
#       is held for another task, 2 when its state could not be observed.
#   fm-slot-reservation.sh release --project <dir> [--for <task-id>]
#       Remove the record. With --for, only when it is held for that task.
#       Releasing is always safe: it withholds a slot and nothing else, so this
#       can never discard work.
#
# The record it prints, one line, for every state:
#
#   reservation[1]{state,reason,task,project,trunk_ref,trunk_head,expires_in,verifier,evidence}:
#     held,,trunk-red-repair,/home/x/projects/p,refs/heads/main,a1b2c3d,6821,pr-checks,/tmp/fm-verify-pr-checks.log
#
# state and reason come from the library's closed vocabulary. expires_in is
# seconds remaining against the TTL, negative once past it, and empty when the
# record did not parse. An empty field is an absent value, never a zero.
#
# EXIT STATUS IS THREE-VALUED, LIKE THE ANSWER. 0 means observed and held, 1
# means observed and not held, 2 means the state could not be observed. A caller
# that reads only the status therefore cannot turn "I could not tell" into
# either of the other two, which is the whole point of the type
# (bin/fm-verify-lib.sh).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pool-lib.sh
. "$SCRIPT_DIR/fm-pool-lib.sh"
# shellcheck source=bin/fm-landed-lib.sh
. "$SCRIPT_DIR/fm-landed-lib.sh"
# shellcheck source=bin/fm-slot-reservation-lib.sh
. "$SCRIPT_DIR/fm-slot-reservation-lib.sh"

usage() {
  awk '/^# Usage:/ { on = 1 } on { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' \
    "${BASH_SOURCE[0]:-$0}"
}

die() {  # <message>
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# Refuse an option given without a value. `shift 2 || true` would be the shorter
# spelling and is a hang: the shift fails without consuming anything, so the
# option loop never advances.
need_value() {  # <option> <remaining-arg-count>
  [ "$2" -ge 2 ] || die "$1 needs a value"
}

now_epoch() {
  date +%s 2>/dev/null || printf ''
}

resolve_pool() {  # <dir>
  local dir=$1 real
  [ -n "$dir" ] || return 1
  real=$(cd "$dir" 2>/dev/null && pwd -P) || return 1
  printf '%s\n' "$real"
}

# A task id becomes part of no path here, but it does become a record field that
# other tooling joins on, so it is held to the same plain-slug shape task ids
# already have rather than accepting anything with a newline or an equals sign
# in it.
task_id_valid() {  # <id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

print_record() {  # <expires-in>
  local expires=$1
  printf 'reservation[1]{state,reason,task,project,trunk_ref,trunk_head,expires_in,verifier,evidence}:\n'
  printf '  %s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$FM_SLOT_RESERVATION_STATE" "$FM_SLOT_RESERVATION_REASON" \
    "$FM_SLOT_RESERVATION_TASK" "$FM_SLOT_RESERVATION_PROJECT" \
    "$FM_SLOT_RESERVATION_TRUNK_REF" "$FM_SLOT_RESERVATION_TRUNK_HEAD" \
    "$expires" "$FM_SLOT_RESERVATION_VERIFIER" "$FM_SLOT_RESERVATION_EVIDENCE"
}

expires_in() {  # <now>
  local now=$1
  [ -n "$FM_SLOT_RESERVATION_OPENED" ] && [ -n "$FM_SLOT_RESERVATION_TTL" ] || return 0
  case "$now" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$((FM_SLOT_RESERVATION_OPENED + FM_SLOT_RESERVATION_TTL - now))"
}

state_exit() {
  case "$FM_SLOT_RESERVATION_STATE" in
    held) return 0 ;;
    unobservable) return 2 ;;
    *) return 1 ;;
  esac
}

# The FAIL observation that admits a reservation, read from one bin/fm-verify.sh
# record. Sets VERDICT_VERIFIER and VERDICT_EVIDENCE.
#
# The record's own shape is the parse: a header line naming the fields, then one
# comma-separated row. Anything else is refused rather than pattern-matched into
# a result, because a verdict this cannot read is a verdict it has not seen.
VERDICT_VERIFIER=
VERDICT_EVIDENCE=
read_verdict() {  # <file>
  local file=$1 row result
  [ -f "$file" ] && [ -r "$file" ] \
    || die "--verdict $file is not a readable file, so no observation was read"
  row=$(grep -A1 '^verify\[1\]{verifier,result,reason,evidence_ref}:' "$file" 2>/dev/null | sed -n '2p')
  row=${row#"${row%%[![:space:]]*}"}
  [ -n "$row" ] \
    || die "--verdict $file carries no bin/fm-verify.sh record, so no observation was read"
  VERDICT_VERIFIER=$(printf '%s' "$row" | cut -d, -f1)
  result=$(printf '%s' "$row" | cut -d, -f2)
  VERDICT_EVIDENCE=$(printf '%s' "$row" | cut -d, -f4-)
  case "$result" in
    FAIL) return 0 ;;
    PASS)
      die "--verdict $file reports PASS: a trunk observed good needs no repair, so no slot is reserved"
      ;;
    NO_VERIFIER_RAN)
      die "--verdict $file reports NO_VERIFIER_RAN: the observation did not happen, and an observation that did not happen is not evidence a trunk is broken"
      ;;
    *)
      die "--verdict $file reports an unknown result '$result'; only FAIL admits a reservation"
      ;;
  esac
}

cmd_open() {  # <task-id> ...
  local task='' project='' verdict='' ref='' ttl=$FM_SLOT_RESERVATION_TTL_DEFAULT
  local pool name head now file tmp
  [ $# -gt 0 ] || { usage >&2; exit 2; }
  task=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) need_value --project $#; project=$2; shift 2 ;;
      --verdict) need_value --verdict $#; verdict=$2; shift 2 ;;
      --trunk-ref) need_value --trunk-ref $#; ref=$2; shift 2 ;;
      --ttl) need_value --ttl $#; ttl=$2; shift 2 ;;
      *) die "unknown option '$1' for open" ;;
    esac
  done
  task_id_valid "$task" || die "'$task' is not a usable task id"
  [ -n "$project" ] || die "open needs --project <dir>"
  [ -n "$verdict" ] || die "open needs --verdict <bin/fm-verify.sh record file>"
  fm_slot_reservation_positive_int "$ttl" || die "--ttl must be a positive whole number of seconds"
  pool=$(resolve_pool "$project") || die "cannot read project directory '$project'"

  # The trunk this reservation is about, resolved here rather than asserted by
  # the caller. Both non-zero statuses refuse: a project with no default branch
  # and a project whose branches could not be read are different facts, and
  # neither of them names a trunk to repair.
  if [ -z "$ref" ]; then
    name=$(fm_landed_default_branch_name "$pool")
    case $? in
      0) ref="refs/heads/$name" ;;
      1) die "$pool has no resolvable default branch, so there is no trunk to reserve a slot to repair" ;;
      *) die "$pool's default branch could not be read, so whether it needs repair could not be observed" ;;
    esac
  fi
  head=$(git --no-optional-locks -C "$pool" rev-parse --verify --quiet "$ref" 2>/dev/null) || head=
  [ -n "$head" ] || die "$ref could not be resolved in $pool, so the trunk head this would reserve against could not be observed"

  read_verdict "$verdict"

  now=$(now_epoch)
  fm_slot_reservation_positive_int "$now" || die "the current time could not be read, so a reservation could not be given an expiry"

  fm_slot_reservation_read "$pool" "$now"
  if [ "$FM_SLOT_RESERVATION_STATE" = held ]; then
    if [ "$FM_SLOT_RESERVATION_TASK" = "$task" ]; then
      printf 'fm-slot-reservation: %s already holds this pool'"'"'s next free slot (%s)\n' \
        "$task" "$FM_SLOT_RESERVATION_DETAIL" >&2
      print_record "$(expires_in "$now")"
      return 0
    fi
    {
      echo "error: this pool's next free slot is already reserved for $FM_SLOT_RESERVATION_TASK ($FM_SLOT_RESERVATION_DETAIL)."
      echo "       One pool holds one reservation. Deciding which of several waiting repairs goes first is a scheduler, and this is not one."
      echo "       Wait for $FM_SLOT_RESERVATION_TASK to take the slot, or release it explicitly:"
      echo "         bin/fm-slot-reservation.sh release --project $pool --for $FM_SLOT_RESERVATION_TASK"
    } >&2
    exit 1
  fi
  # Anything not held is replaceable, including a record that could not be read:
  # by the library's contract an unobservable record already withholds nothing,
  # so refusing to replace it would let one broken file block every later
  # reservation while protecting nothing.
  case "$FM_SLOT_RESERVATION_STATE" in
    released|unobservable)
      printf 'fm-slot-reservation: replacing the previous reservation (%s: %s)\n' \
        "$FM_SLOT_RESERVATION_STATE" "$FM_SLOT_RESERVATION_DETAIL" >&2
      ;;
  esac

  file=$(fm_slot_reservation_path "$pool") \
    || die "the pool's machine-private state directory could not be resolved or validated, so nothing was reserved"
  tmp="$file.$$.tmp"
  umask 077
  {
    printf '%s\n' "$FM_SLOT_RESERVATION_VERSION"
    printf 'task=%s\n' "$task"
    printf 'project=%s\n' "$pool"
    printf 'trunk_ref=%s\n' "$ref"
    printf 'trunk_head=%s\n' "$head"
    printf 'opened=%s\n' "$now"
    printf 'ttl=%s\n' "$ttl"
    printf 'verifier=%s\n' "$VERDICT_VERIFIER"
    printf 'evidence=%s\n' "$VERDICT_EVIDENCE"
  } > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$file" || { rm -f "$tmp"; die "could not install $file"; }

  fm_slot_reservation_read "$pool" "$now"
  print_record "$(expires_in "$now")"
  [ "$FM_SLOT_RESERVATION_STATE" = held ] \
    || die "the reservation was written but does not read back as held ($FM_SLOT_RESERVATION_STATE: $FM_SLOT_RESERVATION_DETAIL)"
  return 0
}

cmd_status() {
  local project='' want='' pool now
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) need_value --project $#; project=$2; shift 2 ;;
      --for) need_value --for $#; want=$2; shift 2 ;;
      *) die "unknown option '$1' for status" ;;
    esac
  done
  [ -n "$project" ] || die "status needs --project <dir>"
  pool=$(resolve_pool "$project") || die "cannot read project directory '$project'"
  now=$(now_epoch)
  fm_slot_reservation_read "$pool" "$now"
  print_record "$(expires_in "$now")"
  printf '  detail: %s\n' "$FM_SLOT_RESERVATION_DETAIL"
  if [ -n "$want" ]; then
    if [ "$FM_SLOT_RESERVATION_STATE" = held ] && [ "$FM_SLOT_RESERVATION_TASK" = "$want" ]; then
      printf '  holder: %s\n' "$want"
    else
      printf '  holder: not %s\n' "$want"
    fi
  fi
  state_exit
}

cmd_claim() {  # <task-id> --project <dir>
  local task='' project='' pool now
  [ $# -gt 0 ] || { usage >&2; exit 2; }
  task=$1
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) need_value --project $#; project=$2; shift 2 ;;
      *) die "unknown option '$1' for claim" ;;
    esac
  done
  task_id_valid "$task" || die "'$task' is not a usable task id"
  [ -n "$project" ] || die "claim needs --project <dir>"
  pool=$(resolve_pool "$project") || die "cannot read project directory '$project'"
  now=$(now_epoch)
  fm_slot_reservation_read "$pool" "$now"
  case "$FM_SLOT_RESERVATION_STATE" in
    held)
      if [ "$FM_SLOT_RESERVATION_TASK" != "$task" ]; then
        printf 'fm-slot-reservation: nothing claimed - this pool is reserved for %s, not %s\n' \
          "$FM_SLOT_RESERVATION_TASK" "$task" >&2
        return 1
      fi
      rm -f "$FM_SLOT_RESERVATION_PATH" \
        || die "the reservation for $task could not be removed, so it will keep withholding a slot until it expires"
      printf 'fm-slot-reservation: %s claimed this pool'"'"'s reserved slot\n' "$task" >&2
      return 0
      ;;
    unobservable)
      printf 'fm-slot-reservation: nothing claimed - the reservation state could not be observed (%s: %s)\n' \
        "$FM_SLOT_RESERVATION_REASON" "$FM_SLOT_RESERVATION_DETAIL" >&2
      return 2
      ;;
    absent)
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

cmd_release() {
  local project='' want='' pool now
  while [ $# -gt 0 ]; do
    case "$1" in
      --project) need_value --project $#; project=$2; shift 2 ;;
      --for) need_value --for $#; want=$2; shift 2 ;;
      *) die "unknown option '$1' for release" ;;
    esac
  done
  [ -n "$project" ] || die "release needs --project <dir>"
  pool=$(resolve_pool "$project") || die "cannot read project directory '$project'"
  now=$(now_epoch)
  fm_slot_reservation_read "$pool" "$now"
  if [ "$FM_SLOT_RESERVATION_STATE" = absent ]; then
    printf 'fm-slot-reservation: nothing to release - no slot is reserved in this pool\n' >&2
    return 1
  fi
  if [ -n "$want" ] && [ "$FM_SLOT_RESERVATION_TASK" != "$want" ]; then
    printf 'fm-slot-reservation: nothing released - this pool is reserved for %s, not %s\n' \
      "${FM_SLOT_RESERVATION_TASK:-an unreadable holder}" "$want" >&2
    return 1
  fi
  [ -n "$FM_SLOT_RESERVATION_PATH" ] \
    || die "the pool's machine-private state directory could not be resolved or validated, so nothing could be released"
  rm -f "$FM_SLOT_RESERVATION_PATH" || die "could not remove $FM_SLOT_RESERVATION_PATH"
  printf 'fm-slot-reservation: released (%s: %s)\n' \
    "$FM_SLOT_RESERVATION_STATE" "$FM_SLOT_RESERVATION_DETAIL" >&2
  return 0
}

case "${1:-}" in
  open) shift; cmd_open "$@" ;;
  status) shift; cmd_status "$@" ;;
  claim) shift; cmd_claim "$@" ;;
  release) shift; cmd_release "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
