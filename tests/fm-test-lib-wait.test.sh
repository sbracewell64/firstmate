#!/usr/bin/env bash
# Behavior of the shared bounded waits in tests/lib.sh and tests/wake-helpers.sh,
# and of the third test result they report a spent bound through.
#
# Every suite that blocks a real worker at a fixture barrier polls for its
# marker, and the bound those polls carry is what decides whether a slow runner
# reports a hang. This pins the wait's contract: wall-clock bound, a distinct
# verdict for a dead producer, and no false "exited" when the producer writes
# its marker and exits in the same breath.
#
# It also pins what a bound that runs out actually reports. A spent bound is a
# fact about the machine, so it belongs in neither the pass nor the fail
# channel; tests/lib.sh's env_could_not_observe owns that third line and
# bin/fm-test-run.sh counts it in its own bucket.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-test-lib-wait)
mkdir -p "$TMP_ROOT"

# Run one fm_test_wait_file call in its own shell so its fail() aborts only that
# shell. Echoes the call's exit status; its output is captured by the caller.
run_wait() { # <marker> <seconds> <pid|-> <out-file>
  bash -c '
    . "$1"
    fm_test_wait_file "$2" "$3" "$4" "producer exited" "wait timed out"
    printf "returned\n"
  ' _ "$LIB" "$1" "$2" "$3" > "$4" 2>&1
}

test_returns_as_soon_as_the_marker_appears() {
  local marker="$TMP_ROOT/appears.marker" out="$TMP_ROOT/appears.out" producer status
  ( sleep 0.3; : > "$marker" ) &
  producer=$!
  fm_test_reap "$producer"
  run_wait "$marker" 30 "$producer" "$out"
  status=$?
  wait "$producer" 2>/dev/null || true
  expect_code 0 "$status" "wait aborted while its producer was still working"
  assert_grep returned "$out" "wait did not return after the marker appeared"
  pass "the wait returns once its marker appears"
}

# Time out one wait whose marker never appears; echo the seconds it spent.
time_out_wait() { # <label> <seconds>
  local label=$1 seconds=$2 marker="$TMP_ROOT/never-$1.marker" out="$TMP_ROOT/never-$1.out"
  local producer status started elapsed
  ( sleep 60 ) &
  producer=$!
  fm_test_reap "$producer"
  started=$SECONDS
  run_wait "$marker" "$seconds" "$producer" "$out"
  status=$?
  elapsed=$((SECONDS - started))
  kill "$producer" 2>/dev/null || true
  expect_code 1 "$status" "a wait whose marker never appears must fail ($label)"
  assert_grep "wait timed out" "$out" "timeout did not report its own message ($label)"
  printf '%s\n' "$elapsed"
}

test_bound_is_wall_clock_seconds_not_iterations() {
  local short_elapsed long_elapsed
  short_elapsed=$(time_out_wait short 1) || exit 1
  long_elapsed=$(time_out_wait long 5) || exit 1
  # Two independent failure modes, and a poll count catches neither. A count
  # spends whatever its polls happen to cost on the day - too little on a loaded
  # runner, which is what reports a slow worker as a hang - and it spends the
  # same amount whatever bound the caller asked for.
  [ "$short_elapsed" -ge 1 ] || fail "wait gave up after ${short_elapsed}s of a 1s bound"
  [ "$long_elapsed" -ge 5 ] || fail "wait gave up after ${long_elapsed}s of a 5s bound"
  [ "$((long_elapsed - short_elapsed))" -ge 2 ] \
    || fail "a 5s bound outlasted a 1s bound by only $((long_elapsed - short_elapsed))s, so the bound is not the seconds asked for"
  pass "the bound is wall-clock seconds, spent in full and scaled to the caller's request"
}

test_dead_producer_is_reported_apart_from_a_timeout() {
  local marker="$TMP_ROOT/dead.marker" out="$TMP_ROOT/dead.out" producer status started elapsed
  ( sleep 0.2; exit 3 ) &
  producer=$!
  fm_test_reap "$producer"
  started=$SECONDS
  run_wait "$marker" 60 "$producer" "$out"
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "a wait whose producer died must fail"
  assert_grep "producer exited" "$out" "dead producer was not reported as an exit"
  assert_no_grep "wait timed out" "$out" "dead producer was reported as a timeout"
  [ "$elapsed" -le 30 ] || fail "dead producer was not noticed until the bound expired"
  pass "a producer that dies without its marker is reported apart from a timeout"
}

# --- the third test result --------------------------------------------------
#
# Both helpers below are exercised in their own shell, the same way run_wait
# does, because the property under test is that the case CONTINUES: a helper
# that exited the suite would otherwise take the assertion with it. The sentinel
# printed after the call is what proves it returned.
run_snippet() {  # <out-file> <library> <body>
  local out=$1
  bash -c '
    set -u
    . "$1"
    eval "$2"
    printf "continued\n"
  ' _ "$2" "$3" >"$out" 2>&1
}

test_could_not_observe_is_neither_a_pass_nor_a_failure() {
  local out="$TMP_ROOT/cno.out" status line
  run_snippet "$out" "$LIB" \
    'env_could_not_observe "watcher exit" "budget=80 polls elapsed=31s loadavg=88.4"'
  status=$?
  expect_code 0 "$status" "env_could_not_observe must not exit the suite"
  assert_grep continued "$out" "env_could_not_observe ended the case instead of returning"

  line=$(grep '^cno - ' "$out" || true)
  [ -n "$line" ] || fail "no typed could-not-observe line was emitted: $(cat "$out")"
  # The whole reason for a third channel: every consumer that knows only ok and
  # not ok stays correct, because this line is neither.
  assert_no_grep "ok - watcher exit" "$out" \
    "the typed result must not be reported through the pass/fail channel"
  grep -Eq '^(not )?ok ' "$out" \
    && fail "the typed result matched a TAP ok/not-ok consumer: $line"
  assert_contains "$line" "TEST_ENVIRONMENT_RESOURCE_TIMEOUT" "default typed class"
  assert_contains "$line" "budget=80 polls elapsed=31s loadavg=88.4" \
    "the evidence a later attribution needs must survive"

  run_snippet "$TMP_ROOT/cno2.out" "$LIB" \
    'env_could_not_observe "the register" "no reachable copy" COULD_NOT_OBSERVE'
  assert_grep "cno - the register: COULD_NOT_OBSERVE no reachable copy" "$TMP_ROOT/cno2.out" \
    "a caller-named class must reach the line"
  pass "the typed environment result is neither a pass nor a product failure, and returns"
}

# The snippet bodies below stay single-quoted on purpose: every expansion in
# them belongs to the child shell that sources the helper, not to this one.
# shellcheck disable=SC2016
test_wait_for_exit_classifies_a_spent_envelope_apart_from_an_exit() {
  local helpers="$ROOT/tests/wake-helpers.sh" out="$TMP_ROOT/wfe.out" status

  # Observed: the subject really exits, and with the status it chose. That still
  # has to be a plain exit, not an environment result.
  run_snippet "$out" "$helpers" '
    ( exit 7 ) & pid=$!
    wait_for_exit "$pid" 60
    printf "status=%s class=%s\n" "$?" "${WAIT_FOR_EXIT_CLASS:-unset}"
    wait_for_exit_expired "should not fire" && printf "WRONGLY_EXPIRED\n"
  '
  status=$?
  expect_code 0 "$status" "wait_for_exit on a subject that exits"
  assert_grep "status=7 class=exited" "$out" "an observed exit must report its own status"
  assert_no_grep "WRONGLY_EXPIRED" "$out" "an observed exit was classified as an expiry"
  assert_no_grep "cno - " "$out" "an observed exit emitted a could-not-observe line"

  # Could not observe: the subject outlives a deliberately tiny envelope. The
  # expiry must not reach the caller through the same numeric channel a real
  # exit status uses, and the case must still be standing afterwards.
  run_snippet "$TMP_ROOT/wfe2.out" "$helpers" '
    ( sleep 30 ) & pid=$!
    fm_test_reap "$pid"
    wait_for_exit "$pid" 3
    printf "class=%s\n" "${WAIT_FOR_EXIT_CLASS:-unset}"
    wait_for_exit_expired "watcher exit" || printf "NOT_REPORTED\n"
  '
  status=$?
  expect_code 0 "$status" "a spent envelope must not exit the suite"
  assert_grep "class=resource_timeout" "$TMP_ROOT/wfe2.out" \
    "a spent envelope must be classified, not returned as a status"
  assert_no_grep "NOT_REPORTED" "$TMP_ROOT/wfe2.out" \
    "wait_for_exit_expired did not report the spent envelope"
  assert_grep continued "$TMP_ROOT/wfe2.out" "a spent envelope ended the case"
  assert_grep "TEST_ENVIRONMENT_RESOURCE_TIMEOUT" "$TMP_ROOT/wfe2.out" \
    "the expiry was not reported as the typed environment result"
  # Captured before the kill, which is what used to destroy it.
  assert_grep "budget=3" "$TMP_ROOT/wfe2.out" "the configured budget was not preserved"
  assert_grep "elapsed=" "$TMP_ROOT/wfe2.out" "the elapsed wall time was not preserved"
  assert_grep "loadavg=" "$TMP_ROOT/wfe2.out" "no load reading was preserved"
  pass "wait_for_exit reports a spent envelope as the typed environment result, not as an exit status"
}

test_returns_as_soon_as_the_marker_appears
test_bound_is_wall_clock_seconds_not_iterations
test_dead_producer_is_reported_apart_from_a_timeout
test_could_not_observe_is_neither_a_pass_nor_a_failure
test_wait_for_exit_classifies_a_spent_envelope_apart_from_an_exit

echo "ALL TESTS PASSED"
