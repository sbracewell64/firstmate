#!/usr/bin/env bash
# Behavior tests for the POOL SLOT RESERVATION: bin/fm-slot-reservation.sh and
# bin/fm-slot-reservation-lib.sh, plus the way bin/fm-worktree-guard.sh applies
# one inside the existing pool allocation path.
#
# WHAT THESE CASES DO AND DO NOT CLAIM
#
# bin/fm-slot-reservation-lib.sh's header owns what a reservation is for and the
# honest bound on it. The consequence for this suite: a reservation creates no
# capacity and guarantees no time bound, so nothing here asserts that a repair
# starts, or starts within any time. Every assertion is about which dispatch the
# next EMPTY slot goes to.
#
# EVERY CASE IS WATCHED RED. Each named property is first asserted green against
# the shipped code, then re-asserted against a disposable copy of bin/ carrying
# one defect planted in the exact production bytes that property depends on, and
# it must go red there. A plant whose target bytes are not found, or are found
# more than once, fails the case outright: a defect build that did not apply
# proves nothing, and would leave an ordinary green run masquerading as a
# watched red.
#
# The suite closes on POSITIVE EXECUTED COUNTS - properties asserted green and
# defect builds observed red - because "no failures" is equally satisfied by a
# suite that asserted nothing.
#
# The properties, and the defect each is watched against:
#   (1) the holder is handed the reserved slot       requester match removed
#   (2) another dispatch is refused it               reservation never consulted
#   (3) no running lane is preempted for one         an occupied slot handed out
#   (4) an expired reservation releases              the TTL comparison disabled
#   (5) a superseded one releases                    the head comparison disabled
#   (6) unreadable is not the same as absent         the could-not-observe branch
#                                                    collapsed into silence
#   (7) NON-VACUITY CONTROL: with no reservation a   the absent branch made a
#       normal dispatch still gets a free slot       refusal
#   (8) one pool holds one reservation               the held-holder check removed
#   (9) only a FAIL observation admits one           every verdict accepted
#  (10) one slot is withheld, not the pool           the second empty slot hidden
#  (11) the holder taking the slot consumes it       the claim call removed
#  (12) END TO END: a full pool starts nothing, and  the requesting task's
#       the next slot to free goes to the queued      identity discarded
#       repair rather than to whoever asked first
#  (13) a pool state namespace this user does           the namespace ownership
#       not control reads could-not-observe             and mode check inverted
#  (14) an option with no value refuses, never loops   the arity check dropped
#
# Every plant below passes the production bytes it replaces as single-quoted
# literals, which is the point of the quoting: those bytes must reach `plant`
# unexpanded, so they can be matched against the file byte for byte.
# shellcheck disable=SC2016
set -u

FM_TEST_IDENTITY_CONTRACT=1
# shellcheck source=tests/worktree-pool-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/worktree-pool-helpers.sh"
# fm-timeout-lib.sh owns bounded execution, which case (14) needs: a hang is
# only observable against a deadline, and every bounded call in this repo agrees
# on 124 through that owner rather than re-deriving the mechanism here.
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-reservation)
trap fm_test_cleanup EXIT
fm_git_identity

command -v python3 >/dev/null 2>&1 \
  || fail "slot reservation: python3 is required to plant the defect builds these cases are watched against"

SHIPPED_BIN="$ROOT/bin"

# Every reservation in this suite is keyed under a namespace this suite owns, so
# no case can see or disturb the machine's real pool state. empty_pool narrows
# it further, to one namespace per case.
FM_POOL_NAMESPACE_DIR="$TMP_ROOT/pool-ns"
mkdir -p "$FM_POOL_NAMESPACE_DIR"
chmod 700 "$FM_POOL_NAMESPACE_DIR"
export FM_POOL_NAMESPACE_DIR

# The FAIL observation that admits a reservation, in bin/fm-verify.sh's own
# record shape.
VERDICT_FAIL="$TMP_ROOT/verdict-fail"
cat > "$VERDICT_FAIL" <<'V'
verify[1]{verifier,result,reason,evidence_ref}:
  pr-checks,FAIL,verifier_reported_failure,/tmp/fm-verify-pr-checks.trunk.log
V
VERDICT_PASS="$TMP_ROOT/verdict-pass"
cat > "$VERDICT_PASS" <<'V'
verify[1]{verifier,result,reason,evidence_ref}:
  pr-checks,PASS,verified,/tmp/fm-verify-pr-checks.trunk.log
V
VERDICT_NONE="$TMP_ROOT/verdict-none"
cat > "$VERDICT_NONE" <<'V'
verify[1]{verifier,result,reason,evidence_ref}:
  pr-checks,NO_VERIFIER_RAN,empty_result_set,/tmp/fm-verify-pr-checks.trunk.log
V

PROPS_GREEN=0
DEFECT_BUILDS_RED=0


# --- the defect-build apparatus ---------------------------------------------

# A disposable copy of bin/ to plant a defect in. The scripts resolve their
# siblings from their own location, so a copy is a complete, self-consistent
# build rather than a file spliced into the shipped one.
bin_copy() {  # <label>
  local label=$1
  # A second `local`, deliberately: bash expands every right-hand side of one
  # `local` before assigning any of them, so a dir= sharing this statement would
  # be built from an empty label.
  local dir="$TMP_ROOT/bin-$label"
  rm -rf "$dir"
  cp -R "$SHIPPED_BIN" "$dir" || return 1
  printf '%s\n' "$dir"
}

# Replace the exact bytes <old> with <new> in <file>, requiring EXACTLY ONE
# occurrence. Zero means the code moved and the defect describes nothing; more
# than one means the plant is ambiguous about what it changed. Either way the
# caller must treat a non-zero status as a failed case, never as a plant that
# quietly did nothing.
plant() {  # <file> <old> <new>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.stderr.write("plant: %d occurrences of the target bytes in %s, need exactly 1\n"
                     % (s.count(old), path))
    sys.exit(3)
open(path, 'w').write(s.replace(old, new, 1))
PY
}

# Assert <prop> green against the shipped build, then red against a build
# carrying one planted defect. Counts both, so the suite closes on what it
# actually executed.
watch_red() {  # <prop-fn> <label> <file> <old> <new>
  local prop=$1 label=$2 file=$3 old=$4 new=$5 root
  "$prop" "$SHIPPED_BIN" "green-$label" \
    || fail "$label: the property is not green against the shipped build"
  PROPS_GREEN=$((PROPS_GREEN + 1))
  root=$(bin_copy "$label") || fail "$label: could not build a disposable copy of bin/"
  plant "$root/$file" "$old" "$new" \
    || fail "$label: the defect build did not apply to $file, so nothing was proved"
  if "$prop" "$root" "red-$label"; then
    fail "$label: the property stayed green with a defect planted in $file, so it does not measure what it names"
  fi
  DEFECT_BUILDS_RED=$((DEFECT_BUILDS_RED + 1))
}

# --- running the pieces under test ------------------------------------------

GUARD_OUT=''
GUARD_ERR=''
GUARD_RC=0

# Run <bin-root>'s pool guard over a canned pool. stdout is the chosen slot and
# is kept apart from stderr, which carries every refusal and reservation note.
guard() {  # <bin-root> <mode> <proj> <json> [extra args...]
  local root=$1 mode=$2 proj=$3 json=$4 fakebin base
  shift 4
  base=$(dirname "$proj")
  fakebin=$(fm_fakebin "$base")
  install_fake_treehouse "$fakebin" "$json"
  GUARD_OUT=$(PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$base/state" \
    "$root/fm-worktree-guard.sh" "$mode" "$proj" "$@" 2>"$base/guard.err")
  GUARD_RC=$?
  GUARD_ERR=$(cat "$base/guard.err" 2>/dev/null)
}

reserve() {  # <bin-root> <task> <proj> [ttl] [verdict]
  local root=$1 task=$2 proj=$3 ttl=${4:-7200} verdict=${5:-$VERDICT_FAIL}
  "$root/fm-slot-reservation.sh" open "$task" --project "$proj" \
    --verdict "$verdict" --ttl "$ttl" >/dev/null 2>&1
}

# The computed state word for this pool's reservation, read through the command
# surface rather than by opening the record.
res_state() {  # <bin-root> <proj>
  "$1/fm-slot-reservation.sh" status --project "$2" 2>/dev/null \
    | sed -n '2p' | cut -d, -f1 | tr -d '[:space:]'
}

# Give this case a pool-state namespace of its own. Per-case isolation is what
# lets a case reason about "the reservation record" as a single file: a shared
# namespace accumulates the released and expired records earlier cases
# deliberately left behind, and a case reading one of those is reading another
# case's evidence.
#
# It is a separate call, and NOT folded into empty_pool below, because
# empty_pool is invoked through command substitution to capture the project
# path. An export inside a substituted function dies with the subshell that ran
# it, so folding this in would silently leave every case on the shared namespace
# while reading as though it had its own.
isolate_pool_namespace() {  # <label>
  FM_POOL_NAMESPACE_DIR="$TMP_ROOT/pool-ns-$1"
  mkdir -p "$FM_POOL_NAMESPACE_DIR"
  chmod 700 "$FM_POOL_NAMESPACE_DIR"
  export FM_POOL_NAMESPACE_DIR
}

# One pool whose slots are all empty and enterable by name.
empty_pool() {  # <label> <slot-count>
  make_pool "$1" "$2"
}

pool_json() {  # <proj> <slot-count>
  local proj=$1 count=$2 i args=()
  for i in $(seq 1 "$count"); do
    args+=("$i" available "$(slot_path "$proj" "$i")")
  done
  slot_json "${args[@]}"
}

# --- (1) the holder is handed the reserved slot ------------------------------

prop_holder_gets_reserved_slot() {  # <bin-root> <label>
  local root=$1 label=$2 proj json
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for trunk-repair
  [ "$GUARD_RC" -eq 0 ] || { echo "$label: the holder was refused (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  [ "$GUARD_OUT" = "$(printf '1\t%s' "$(slot_path "$proj" 1)")" ] \
    || { echo "$label: the holder was not handed the empty slot (got '$GUARD_OUT')" >&2; return 1; }
  return 0
}

test_a_queued_trunk_repair_is_handed_the_next_free_slot() {
  watch_red prop_holder_gets_reserved_slot holder-match fm-worktree-guard.sh \
    '  if [ "$requester" = "$FM_SLOT_RESERVATION_TASK" ]; then' \
    '  if [ "$requester" = "a-task-id-no-reservation-can-name" ]; then'
  pass "(1) the pool's next free slot goes to the task the reservation names"
}

# --- (2) another dispatch is refused the reserved slot -----------------------

prop_other_dispatch_is_refused() {  # <bin-root> <label>
  local root=$1 label=$2 proj json
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -ne 0 ] || { echo "$label: unrelated work was handed the reserved slot ('$GUARD_OUT')" >&2; return 1; }
  [ -z "$GUARD_OUT" ] || { echo "$label: a slot was printed with the spawn refused ('$GUARD_OUT')" >&2; return 1; }
  case "$GUARD_ERR" in
    *"reserved for trunk-repair"*) ;;
    *) echo "$label: the refusal does not name the holder: $GUARD_ERR" >&2; return 1 ;;
  esac
  return 0
}

test_an_unrelated_dispatch_does_not_take_the_reserved_slot() {
  watch_red prop_other_dispatch_is_refused reservation-consulted fm-worktree-guard.sh \
    '    reservation_apply "$mode" "$proj_real" "$requester" "$chosen" "$chosen_second" || return 1' \
    '    RESERVATION_GRANT=$chosen'
  pass "(2) a dispatch that is not the reservation's holder is refused the slot it holds"
}

# --- (3) no running lane is preempted to satisfy a reservation ---------------

prop_no_preemption() {  # <bin-root> <label>
  local root=$1 label=$2 proj json slot head_before branch_before head_after branch_after
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  slot=$(slot_path "$proj" 1)
  give_unlanded_branch "$slot" fm/live-lane 2
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  head_before=$(git -C "$slot" rev-parse HEAD)
  branch_before=$(git -C "$slot" symbolic-ref --short HEAD)
  guard "$root" select "$proj" "$json" --for trunk-repair
  head_after=$(git -C "$slot" rev-parse HEAD)
  branch_after=$(git -C "$slot" symbolic-ref --short HEAD 2>/dev/null || printf 'detached')
  [ "$head_before" = "$head_after" ] && [ "$branch_before" = "$branch_after" ] \
    || { echo "$label: the occupied slot moved from $branch_before/$head_before to $branch_after/$head_after" >&2; return 1; }
  [ -z "$(git -C "$slot" status --porcelain)" ] \
    || { echo "$label: the occupied slot was dirtied" >&2; return 1; }
  [ "$GUARD_RC" -ne 0 ] \
    || { echo "$label: the reservation was satisfied out of a slot holding live work ('$GUARD_OUT')" >&2; return 1; }
  [ -z "$GUARD_OUT" ] \
    || { echo "$label: a slot holding live work was handed to the reservation ('$GUARD_OUT')" >&2; return 1; }
  return 0
}

test_a_reservation_never_preempts_a_running_lane() {
  watch_red prop_no_preemption empty-slot-required fm-worktree-guard.sh \
    '  if [ -n "$chosen" ]; then
    reservation_apply' \
    '  if [ -z "$chosen" ]; then
    chosen=$(printf '"'"'%s\t%s'"'"' "$name" "$wt")
  fi
  if [ -n "$chosen" ]; then
    reservation_apply'
  pass "(3) a slot holding live work is never handed to a reservation, and is left untouched"
}

# --- (4) an expired reservation releases -------------------------------------

prop_expired_reservation_releases() {  # <bin-root> <label>
  local root=$1 label=$2 proj json state
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" 1 || { echo "$label: could not open the reservation" >&2; return 1; }
  sleep 2
  state=$(res_state "$root" "$proj")
  [ "$state" = released ] || { echo "$label: an expired reservation reads '$state'" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] \
    || { echo "$label: an expired reservation still withheld the slot (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  [ -n "$GUARD_OUT" ] || { echo "$label: no slot was handed out after expiry" >&2; return 1; }
  return 0
}

test_an_expired_reservation_stops_withholding_a_slot() {
  watch_red prop_expired_reservation_releases ttl-bound fm-slot-reservation-lib.sh \
    '  if [ "$age" -ge "$ttl" ]; then' \
    '  if [ "$age" -ge "$ttl" ] && [ 1 = 0 ]; then'
  pass "(4) a reservation past its stated limit releases and holds no slot"
}

# --- (5) a landed or superseded reservation releases -------------------------

prop_superseded_reservation_releases() {  # <bin-root> <label>
  local root=$1 label=$2 proj json state
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  # The trunk moves past the commit the reservation names: the repair landed, or
  # something else ended the situation. Either way it is a different trunk now.
  git -C "$proj" commit -q --allow-empty -m "trunk moves on"
  state=$(res_state "$root" "$proj")
  [ "$state" = released ] || { echo "$label: a superseded reservation reads '$state'" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] \
    || { echo "$label: a superseded reservation still withheld the slot (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  case "$GUARD_ERR" in
    *"no longer held"*) ;;
    *) echo "$label: the release was not reported: $GUARD_ERR" >&2; return 1 ;;
  esac
  return 0
}

test_a_reservation_whose_trunk_moved_on_releases() {
  watch_red prop_superseded_reservation_releases trunk-head-bound fm-slot-reservation-lib.sh \
    '  if [ "$current" != "$head" ]; then' \
    '  if [ "$current" != "$current" ]; then'
  pass "(5) a reservation whose trunk moved past the commit it names releases and holds no slot"
}

# --- (6) unreadable is not the same fact as absent ---------------------------

prop_unreadable_is_not_absent() {  # <bin-root> <label>
  local root=$1 label=$2 proj json record candidate absent_err
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  # First the absent case, which must be silent about any reservation.
  guard "$root" select "$proj" "$json" --for unrelated-work
  absent_err=$GUARD_ERR
  case "$absent_err" in
    *reservation*) echo "$label: an absent reservation was reported: $absent_err" >&2; return 1 ;;
  esac
  # Now a record that exists and does not parse. This is could-not-observe, and
  # it must reach a different branch with its own output.
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  record=''
  for candidate in "$FM_POOL_NAMESPACE_DIR"/reservation-*.state; do
    [ -f "$candidate" ] || continue
    record=$candidate
  done
  [ -n "$record" ] || { echo "$label: no reservation record was written" >&2; return 1; }
  printf 'not-a-reservation-record\n' > "$record"
  [ "$(res_state "$root" "$proj")" = unobservable ] \
    || { echo "$label: a corrupt record does not read unobservable" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] \
    || { echo "$label: an unreadable record withheld a slot (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  case "$GUARD_ERR" in
    *"could not be observed"*) ;;
    *) echo "$label: an unreadable reservation produced the same silence as an absent one: '$GUARD_ERR'" >&2; return 1 ;;
  esac
  return 0
}

test_an_unreadable_reservation_is_not_reported_as_no_reservation() {
  watch_red prop_unreadable_is_not_absent could-not-observe-branch fm-worktree-guard.sh \
    '    unobservable)
      printf '"'"'worktree guard: this pool'"'"'"'"'"'"'"'"'s slot reservation could not be observed (%s: %s). No slot is withheld. This is a reservation that could not be read, which is not the same fact as no reservation.\n'"'"' \
        "$FM_SLOT_RESERVATION_REASON" "$FM_SLOT_RESERVATION_DETAIL" >&2
      return 0
      ;;' \
    '    unobservable)
      return 0
      ;;'
  pass "(6) a reservation that could not be read is reported as that, never as no reservation"
}

# --- (7) NON-VACUITY CONTROL -------------------------------------------------

prop_normal_dispatch_still_gets_a_slot() {  # <bin-root> <label>
  local root=$1 label=$2 proj json
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 2)
  json=$(pool_json "$proj" 2)
  [ "$(res_state "$root" "$proj")" = absent ] \
    || { echo "$label: the control pool already carries a reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for ordinary-task
  [ "$GUARD_RC" -eq 0 ] || { echo "$label: an ordinary dispatch was refused (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  [ "$GUARD_OUT" = "$(printf '1\t%s' "$(slot_path "$proj" 1)")" ] \
    || { echo "$label: an ordinary dispatch was not handed the first empty slot (got '$GUARD_OUT')" >&2; return 1; }
  return 0
}

test_control_a_normal_dispatch_still_gets_a_free_slot() {
  watch_red prop_normal_dispatch_still_gets_a_slot absent-branch fm-worktree-guard.sh \
    '  case "$FM_SLOT_RESERVATION_STATE" in
    absent)
      return 0
      ;;' \
    '  case "$FM_SLOT_RESERVATION_STATE" in
    absent)
      RESERVATION_GRANT=
      return 1
      ;;'
  pass "(7) control: with no reservation in the pool, an ordinary dispatch still gets a free slot"
}

# --- (8) one pool holds one reservation, and no queue forms ------------------

prop_second_reservation_is_refused() {  # <bin-root> <label>
  local root=$1 label=$2 proj out rc
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the first reservation" >&2; return 1; }
  out=$("$root/fm-slot-reservation.sh" open second-repair --project "$proj" \
    --verdict "$VERDICT_FAIL" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "$label: a second reservation was accepted: $out" >&2; return 1; }
  case "$out" in
    *"already reserved for trunk-repair"*) ;;
    *) echo "$label: the refusal does not name the existing holder: $out" >&2; return 1 ;;
  esac
  [ "$("$root/fm-slot-reservation.sh" status --project "$proj" 2>/dev/null | sed -n '2p' | cut -d, -f3)" = trunk-repair ] \
    || { echo "$label: the first reservation did not survive the second request" >&2; return 1; }
  return 0
}

test_a_pool_holds_one_reservation_and_forms_no_queue() {
  watch_red prop_second_reservation_is_refused single-holder fm-slot-reservation.sh \
    '  if [ "$FM_SLOT_RESERVATION_STATE" = held ]; then' \
    '  if [ "$FM_SLOT_RESERVATION_STATE" = held ] && [ 1 = 0 ]; then'
  pass "(8) a pool holds one reservation: a second request is refused, not queued behind the first"
}

# --- (9) only a FAIL observation admits a reservation ------------------------

prop_only_a_fail_observation_admits() {  # <bin-root> <label>
  local root=$1 label=$2 proj out rc
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  out=$("$root/fm-slot-reservation.sh" open trunk-repair --project "$proj" \
    --verdict "$VERDICT_PASS" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "$label: a PASS observation opened a reservation: $out" >&2; return 1; }
  [ "$(res_state "$root" "$proj")" = absent ] \
    || { echo "$label: a PASS observation left a reservation behind" >&2; return 1; }
  out=$("$root/fm-slot-reservation.sh" open trunk-repair --project "$proj" \
    --verdict "$VERDICT_NONE" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "$label: NO_VERIFIER_RAN opened a reservation: $out" >&2; return 1; }
  [ "$(res_state "$root" "$proj")" = absent ] \
    || { echo "$label: an observation that did not happen left a reservation behind" >&2; return 1; }
  # And the admitted case records the observation it was admitted by, so which
  # evidence opened it is readable rather than inferred.
  reserve "$root" trunk-repair "$proj" || { echo "$label: a FAIL observation did not open a reservation" >&2; return 1; }
  case "$("$root/fm-slot-reservation.sh" status --project "$proj" 2>/dev/null | sed -n '2p')" in
    *pr-checks*) ;;
    *) echo "$label: the admitting observation was not recorded" >&2; return 1 ;;
  esac
  return 0
}

test_only_an_observed_failure_admits_a_reservation() {
  watch_red prop_only_a_fail_observation_admits fail-only-admission fm-slot-reservation.sh \
    '    FAIL) return 0 ;;' \
    '    FAIL|PASS|NO_VERIFIER_RAN) return 0 ;;'
  pass "(9) only a FAIL observation admits a reservation, and the record names which one did"
}

# --- (10) one slot is withheld, not the pool ---------------------------------

prop_one_slot_is_withheld() {  # <bin-root> <label>
  local root=$1 label=$2 proj json
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 2)
  json=$(pool_json "$proj" 2)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] \
    || { echo "$label: ordinary work was refused though a second empty slot existed (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  [ "$GUARD_OUT" = "$(printf '2\t%s' "$(slot_path "$proj" 2)")" ] \
    || { echo "$label: ordinary work did not get the second empty slot (got '$GUARD_OUT')" >&2; return 1; }
  [ "$(res_state "$root" "$proj")" = held ] \
    || { echo "$label: the reservation did not survive an unrelated dispatch" >&2; return 1; }
  return 0
}

test_a_reservation_withholds_one_slot_not_the_pool() {
  watch_red prop_one_slot_is_withheld one-slot-only fm-worktree-guard.sh \
    '  if [ -n "$second" ]; then
    RESERVATION_GRANT=$second' \
    '  if [ -n "$second" ] && [ 1 = 0 ]; then
    RESERVATION_GRANT=$second'
  pass "(10) a reservation withholds one slot, so a second empty slot still goes to ordinary work"
}

# --- (11) the holder taking the slot consumes the reservation ----------------

prop_claim_consumes_the_reservation() {  # <bin-root> <label>
  local root=$1 label=$2 proj json
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 2)
  json=$(pool_json "$proj" 2)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for trunk-repair
  [ "$GUARD_RC" -eq 0 ] || { echo "$label: the holder was refused (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  [ "$(res_state "$root" "$proj")" = absent ] \
    || { echo "$label: the reservation survived its holder taking the slot" >&2; return 1; }
  # And with it gone the pool is ordinary again: the next dispatch takes the
  # first empty slot with nothing withheld.
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] || { echo "$label: the pool stayed withheld after the reservation was consumed" >&2; return 1; }
  [ "$GUARD_OUT" = "$(printf '1\t%s' "$(slot_path "$proj" 1)")" ] \
    || { echo "$label: the freed pool did not allocate normally (got '$GUARD_OUT')" >&2; return 1; }
  return 0
}

test_the_holder_taking_the_slot_consumes_the_reservation() {
  watch_red prop_claim_consumes_the_reservation claim-on-handover fm-worktree-guard.sh \
    '"$FM_GUARD_DIR/fm-slot-reservation.sh" claim "$requester" --project "$pool" >/dev/null 2>&1' \
    'true "$FM_GUARD_DIR" "$requester" "$pool" >/dev/null 2>&1'
  pass "(11) the reservation is consumed when its holder is handed the slot, and the pool allocates normally after"
}

# --- (12) end to end: the next slot to free goes to the reservation ----------

# The acceptance sequence, in the order the incident ran in: a full pool, a
# queued repair that cannot start, one slot freeing later, and an unrelated
# dispatch reaching the pool before the repair does.
prop_next_slot_to_free_goes_to_the_repair() {  # <bin-root> <label>
  local root=$1 label=$2 proj json slot1 slot2
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 2)
  slot1=$(slot_path "$proj" 1)
  slot2=$(slot_path "$proj" 2)
  give_unlanded_branch "$slot1" fm/lane-one 1
  give_unlanded_branch "$slot2" fm/lane-two 1
  json=$(pool_json "$proj" 2)

  # The pool is full: nothing can start, repair or otherwise.
  guard "$root" select "$proj" "$json" --for trunk-repair
  [ "$GUARD_RC" -ne 0 ] || { echo "$label: a full pool handed out a slot ('$GUARD_OUT')" >&2; return 1; }
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for trunk-repair
  [ "$GUARD_RC" -ne 0 ] \
    || { echo "$label: a reservation created capacity a full pool did not have ('$GUARD_OUT')" >&2; return 1; }

  # One lane finishes and its slot goes back to the pool, parked where an
  # allocation would find it.
  git -C "$slot2" checkout -q --detach main
  git -C "$slot2" branch -q -D fm/lane-two

  # Unrelated work reaches the pool first, as it did on the day.
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -ne 0 ] \
    || { echo "$label: the freed slot went to unrelated work ('$GUARD_OUT')" >&2; return 1; }

  # The repair takes the slot that freed, and the pool is ordinary again.
  guard "$root" select "$proj" "$json" --for trunk-repair
  [ "$GUARD_RC" -eq 0 ] || { echo "$label: the repair was refused the slot reserved for it: $GUARD_ERR" >&2; return 1; }
  [ "$GUARD_OUT" = "$(printf '2\t%s' "$slot2")" ] \
    || { echo "$label: the repair did not get the slot that freed (got '$GUARD_OUT')" >&2; return 1; }
  [ "$(res_state "$root" "$proj")" = absent ] \
    || { echo "$label: the reservation outlived the handover" >&2; return 1; }
  return 0
}

test_end_to_end_the_next_slot_to_free_goes_to_the_queued_repair() {
  watch_red prop_next_slot_to_free_goes_to_the_repair requester-identity fm-worktree-guard.sh \
    '        requester=$2' \
    '        requester='
  pass "(12) end to end: a full pool starts nothing, and the next slot to free goes to the queued repair rather than to the dispatch that asked first"
}

# --- (13) the pool's state namespace is validated, not assumed ---------------

# bin/fm-pool-lib.sh owns where a pool's machine-private state lives, and
# re-validates that directory on every resolution because it is a fixed path in
# a shared world-writable place: its existence proves nothing about who made it.
# A namespace that fails that check must reach could-not-observe, never the
# absent branch, because "the reservation is not there" and "I was not allowed
# to look where it would be" are different facts.
prop_unusable_namespace_is_could_not_observe() {  # <bin-root> <label>
  local root=$1 label=$2 proj json out rc
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  json=$(pool_json "$proj" 1)
  reserve "$root" trunk-repair "$proj" || { echo "$label: could not open the reservation" >&2; return 1; }
  # The namespace stops being one this user demonstrably controls.
  chmod 755 "$FM_POOL_NAMESPACE_DIR"
  [ "$(res_state "$root" "$proj")" = unobservable ] \
    || { echo "$label: an unusable namespace does not read unobservable" >&2; return 1; }
  out=$("$root/fm-slot-reservation.sh" open other-repair --project "$proj" \
    --verdict "$VERDICT_FAIL" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { echo "$label: a reservation was opened through an unusable namespace: $out" >&2; return 1; }
  guard "$root" select "$proj" "$json" --for unrelated-work
  [ "$GUARD_RC" -eq 0 ] \
    || { echo "$label: an unusable namespace withheld a slot (rc=$GUARD_RC): $GUARD_ERR" >&2; return 1; }
  case "$GUARD_ERR" in
    *"could not be observed"*) ;;
    *) echo "$label: an unusable namespace was silent, like an absent reservation: '$GUARD_ERR'" >&2; return 1 ;;
  esac
  chmod 700 "$FM_POOL_NAMESPACE_DIR"
  return 0
}

test_a_pool_state_namespace_this_user_does_not_control_is_could_not_observe() {
  watch_red prop_unusable_namespace_is_could_not_observe namespace-validated fm-pool-lib.sh \
    '  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]' \
    '  [ "$owner" = "$expected_uid" ] || [ "$mode" != 700 ]'
  pass "(13) a pool state namespace this user does not demonstrably control reads could-not-observe, never as no reservation"
}

# --- (14) an option given with no value refuses, and does not loop -----------

# Measured on this branch before it landed: `--for` or `--project` as the last
# argument hung both commands. `shift 2` fails without consuming anything when
# fewer than two arguments remain, so `shift 2 || true` leaves the option loop
# on the same argument forever. A spawn that hangs inside slot selection holds
# the pool lock while it does, so this is a pool-wide wedge rather than one
# stuck command, and it is pinned under a hard bound rather than by inspection.
prop_valueless_option_refuses() {  # <bin-root> <label>
  local root=$1 label=$2 proj rc
  isolate_pool_namespace "$label"
  proj=$(empty_pool "$label" 1)
  local -a invocations=(
    "$root/fm-worktree-guard.sh check $proj --for"
    "$root/fm-slot-reservation.sh status --project"
    "$root/fm-slot-reservation.sh open a-task --project"
    "$root/fm-slot-reservation.sh release --project $proj --for"
  )
  local invocation
  for invocation in "${invocations[@]}"; do
    # shellcheck disable=SC2086 # each entry is a fixed argv this suite built.
    fm_run_timed 10 $invocation >/dev/null 2>&1
    rc=$?
    [ "$rc" -ne 124 ] || { echo "$label: '$invocation' did not finish within its bound" >&2; return 1; }
    [ "$rc" -ne 0 ] || { echo "$label: '$invocation' accepted an option with no value" >&2; return 1; }
  done
  return 0
}

test_an_option_with_no_value_refuses_instead_of_looping() {
  watch_red prop_valueless_option_refuses valueless-option fm-slot-reservation.sh \
    '      --project) need_value --project $#; project=$2; shift 2 ;;
      --for) need_value --for $#; want=$2; shift 2 ;;
      *) die "unknown option '"'"'$1'"'"' for status" ;;' \
    '      --project) project=${2:-}; shift 2 || true ;;
      --for) need_value --for $#; want=$2; shift 2 ;;
      *) die "unknown option '"'"'$1'"'"' for status" ;;'
  pass "(14) an option given with no value refuses within a bound instead of looping on it forever"
}

# --- run ---------------------------------------------------------------------

test_a_queued_trunk_repair_is_handed_the_next_free_slot
test_an_unrelated_dispatch_does_not_take_the_reserved_slot
test_a_reservation_never_preempts_a_running_lane
test_an_expired_reservation_stops_withholding_a_slot
test_a_reservation_whose_trunk_moved_on_releases
test_an_unreadable_reservation_is_not_reported_as_no_reservation
test_control_a_normal_dispatch_still_gets_a_free_slot
test_a_pool_holds_one_reservation_and_forms_no_queue
test_only_an_observed_failure_admits_a_reservation
test_a_reservation_withholds_one_slot_not_the_pool
test_the_holder_taking_the_slot_consumes_the_reservation
test_end_to_end_the_next_slot_to_free_goes_to_the_queued_repair
test_a_pool_state_namespace_this_user_does_not_control_is_could_not_observe
test_an_option_with_no_value_refuses_instead_of_looping

fm_test_contract "$0" || exit 1

# Positive executed counts, because "no failures" is also what a suite that ran
# nothing reports. Each property was asserted green against the shipped build
# and red against its own defect build, so these two numbers must match the
# number of properties and must both be non-zero.
[ "$PROPS_GREEN" -gt 0 ] || fail "no property was asserted green"
[ "$DEFECT_BUILDS_RED" -eq "$PROPS_GREEN" ] \
  || fail "watched-red accounting mismatch: $PROPS_GREEN green, $DEFECT_BUILDS_RED red"
printf 'FM_SLOT_RESERVATION_COUNTS properties_green=%s defect_builds_red=%s\n' \
  "$PROPS_GREEN" "$DEFECT_BUILDS_RED"

printf '\nall fm-slot-reservation tests passed\n'
