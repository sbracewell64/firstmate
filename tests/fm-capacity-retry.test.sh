#!/usr/bin/env bash
# fm-capacity-retry.test.sh - focused automatic capacity resume regressions.
set -u

FM_CAPACITY_ROUTING_HELPERS_ONLY=1
# shellcheck source=tests/fm-capacity-routing.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-capacity-routing.test.sh"

test_resumes_onto_an_expressive_recovered_pool_member() {
  local out meta
  make_dispatch_home substitute-resume
  write_brief "$HOME_DIR" subtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0 altq=0)" \
    subtask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "both spent candidates must first create a wait"
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id subtask --force)
  meta="$HOME_DIR/state/subtask.meta"
  assert_present "$meta" "the recovered substitute did not resume the task"
  assert_grep "model=alt/large" "$meta" "the resumed metadata did not name the recovered substitute"
  assert_contains "$out" "alt/large in route R-PAIR" "the resume output did not name the selected candidate and route"
  assert_contains "$out" "recorded effort band medium" "the resume output did not name the expressible band"
  pass "resumes onto a recovered pool member that can express the route effort band"
}

test_uncounted_deferral_fails_closed() {
  local rec out rc stub
  rec=$(make_refusal_home uncounted); read_home_record "$rec"
  write_brief "$HOME_DIR" counttask no-mistakes
  stub="$TMP_ROOT/uncounted/fail-attempt"
  printf '#!/bin/sh\nprintf "simulated count write failure\\n" >&2\nexit 1\n' > "$stub"
  chmod +x "$stub"
  rc=0
  out=$(FM_ATTEMPT_BIN="$stub" run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer counttask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium 2>&1) || rc=$?
  expect_code 1 "$rc" "an unrecordable count must stop the deferral"
  assert_grep "terminal=attempt count could not be recorded" "$HOME_DIR/state/counttask.capacity" "the deferral was left live"
  assert_contains "$out" "attempt count could not be recorded" "the stop did not name the failed count"
  assert_contains "$out" "$HOME_DIR/state/counttask.attempt" "the stop did not name the unwritable attempt record"
  assert_grep "failed: waiting for capacity ended because the attempt count could not be recorded" "$HOME_DIR/state/counttask.status" "supervision was not given the specific terminal reason"
  pass "a deferral whose attempt count cannot be recorded stops and names the reason"
}

# NEGATIVE CONTROL: same-band substitution.
#
# The three variants share ONE DISPATCH-CAPABLE fixture deliberately. The
# earlier version of this control used the refusal fixture, whose backend always
# exits 1, so "no task metadata" was produced by the backend refusing rather
# than by the band check - the case stayed green with the band rule deleted and
# therefore proved nothing at all.
#
# `expressive` is the guard against exactly that failure: it proves this fixture
# CAN resume onto a substitute, so the two negative variants mean what they
# claim. Remove band expressibility from eligibility and `expressive` still
# passes while both negatives go red, which is what makes this control able to
# fail.
test_same_band_substitution_is_required() {
  local variant out meta cfg
  for variant in expressive inexpressive unverified; do
    make_dispatch_home "band-$variant"
    cfg="$HOME_DIR/config/crew-dispatch.json"
    # The floor's own effort_floor is waived so this exercises BAND PRESERVATION
    # rather than floor conformance. With a stated effort_floor the weaker model
    # is already refused for failing the floor, which is a different check
    # passing for a different reason.
    jq '._floors["F-MED"].effort_floor = "WAIVED - substitution must preserve the running band"' \
      "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
    case "$variant" in
      expressive)
        jq '._models["weak/tiny"].effort_expressible = ["low","medium"]' "$cfg" > "$cfg.tmp" \
          && mv "$cfg.tmp" "$cfg" ;;
      unverified)
        jq 'del(._models["weak/tiny"].effort_expressible)' "$cfg" > "$cfg.tmp" \
          && mv "$cfg.tmp" "$cfg" ;;
    esac
    write_brief "$HOME_DIR" "bandtask-$variant" no-mistakes
    out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0 weakq=0)" \
      "bandtask-$variant" "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-WEAK --model vendor/large --effort medium)
    assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
    out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
      FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
      run_retry "$HOME_DIR" "$(quota_record vendorq=0 weakq=95)" tick --id "bandtask-$variant" --force)
    meta="$HOME_DIR/state/bandtask-$variant.meta"
    if [ "$variant" = expressive ]; then
      assert_present "$meta" "a substitute that CAN express the running band was not resumed onto, so the negative variants below prove nothing"
      assert_grep "model=weak/tiny" "$meta" "the resume did not name the expressible substitute"
    else
      assert_absent "$meta" "a substitute that cannot be shown to express the running band was dispatched, silently changing reasoning depth"
      assert_present "$HOME_DIR/state/bandtask-$variant.capacity" "the refused substitution did not keep waiting"
    fi
  done
  pass "substitution requires the same running effort band, proven against a fixture that can dispatch"
}

# NEGATIVE CONTROL: unrecordable bound.
#
# The record is made UNWRITABLE before the stop is attempted, which is the only
# condition under which the two implementations differ. A stop that can only
# APPEND loses its terminal mark silently on such a record and leaves something
# that still reads as an active wait, so every later tick resumes it - forever,
# because nothing ever becomes recordable. A stop that replaces the record
# atomically, or removes it when even that fails, leaves nothing an active tick
# can pick up.
#
# Revert the durable stop to the plain `>> ... || true` append and this goes
# red: the record survives with no terminal marker at all.
test_unrecordable_bound_leaves_no_active_wait() {
  local rec out rc stub capacity
  rec=$(make_refusal_home unrecordable); read_home_record "$rec"
  write_brief "$HOME_DIR" boundtask no-mistakes
  # A real wait first, so the record under test is one the driver actually made.
  run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer boundtask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium >/dev/null 2>&1
  capacity="$HOME_DIR/state/boundtask.capacity"
  assert_present "$capacity" "the fixture did not create a deferral record to stop"
  chmod 444 "$capacity"
  stub="$TMP_ROOT/unrecordable/fail-attempt"
  printf '#!/bin/sh\ncase "$1" in show) exit 1 ;; esac\nprintf "simulated count write failure\\n" >&2\nexit 1\n' > "$stub"
  chmod +x "$stub"
  rc=0
  out=$(FM_ATTEMPT_BIN="$stub" run_retry "$HOME_DIR" "$(quota_record vendorq=0)" \
    tick --id boundtask --force 2>&1) || rc=$?
  # Terminal, or gone. Never still readable as an active wait.
  if [ -f "$capacity" ]; then
    assert_grep "terminal=" "$capacity" "an unrecordable bound left a record that still reads as an active capacity wait, so every later tick will retry it"
  fi
  assert_contains "$out" "attempt count could not be recorded" "the stop did not name the unrecordable count"
  chmod 644 "$capacity" 2>/dev/null || true
  pass "an unrecordable bound leaves no record that still reads as an active wait"
}

test_non_capacity_refusal_keeps_a_counted_wait() {
  local rec out
  rec=$(make_refusal_home secondary-refusal); read_home_record "$rec"
  write_brief "$HOME_DIR" blockedtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=0)" \
    blockedtask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id blockedtask --force)
  assert_present "$HOME_DIR/state/blockedtask.capacity" "a secondary refusal ended the capacity wait"
  assert_no_grep "terminal=" "$HOME_DIR/state/blockedtask.capacity" "a secondary refusal marked the capacity wait terminal"
  assert_grep "deferrals=2" "$HOME_DIR/state/blockedtask.attempt" "the secondary refusal did not advance the durable bound"
  assert_grep "blocked: waiting for capacity remains active" "$HOME_DIR/state/blockedtask.status" "the secondary refusal was not disclosed"
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id blockedtask --force)
  [ "$(grep -c '^blocked: waiting for capacity remains active' "$HOME_DIR/state/blockedtask.status")" -eq 1 ] \
    || fail "the unchanged secondary refusal was declared more than once"
  pass "a non-capacity substitute refusal leaves the capacity wait active and counted"
}

test_moved_capacity_picture_resets_stagnation() {
  local rec out
  rec=$(make_refusal_home moved-picture); read_home_record "$rec"
  write_brief "$HOME_DIR" movingtask no-mistakes
  out=$(FM_ATTEMPT_DEFER_STAGNATION_DEFAULT=2 \
    run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=0)" \
      movingtask "$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  out=$(FM_ATTEMPT_DEFER_STAGNATION_DEFAULT=2 \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id movingtask --force)
  assert_no_grep "terminal=" "$HOME_DIR/state/movingtask.attempt" "a changed capacity picture was counted as stagnant"
  assert_grep "defer_stagnant=1" "$HOME_DIR/state/movingtask.attempt" "a changed capacity picture did not reset stagnation"
  assert_grep "alt/large=available" "$HOME_DIR/state/movingtask.capacity" "the current capacity signature was not persisted"
  pass "a moved capacity picture advances the wait without accumulating stagnation"
}

test_record_refresh_failure_stops_durably() {
  local rec out rc stub
  rec=$(make_refusal_home record-refresh); read_home_record "$rec"
  write_brief "$HOME_DIR" refreshtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=0)" \
    refreshtask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  stub="$TMP_ROOT/record-refresh/fail-commit"
  printf '#!/bin/sh\nexit 1\n' > "$stub"
  chmod +x "$stub"
  rc=0
  out=$(FM_CAPACITY_RECORD_COMMIT_BIN="$stub" \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id refreshtask --force) || rc=$?
  expect_code 1 "$rc" "a failed deferral-record refresh must stop the wait"
  assert_grep "terminal=budget_exhausted" "$HOME_DIR/state/refreshtask.attempt" "the attempt owner did not record the unified stop"
  assert_contains "$out" "deferral record could not be written" "the stop did not distinguish the failed record refresh"
  assert_contains "$out" "$HOME_DIR/state/refreshtask.capacity" "the stop did not name the failed deferral record path"
  assert_grep "failed: waiting for capacity ended because the deferral record could not be written" "$HOME_DIR/state/refreshtask.status" "supervision did not receive the record-write stop"
  pass "a retry that cannot refresh its deferral record stops and names the failed record"
}

test_unsafe_recorded_id_stops_without_escaping_state() {
  local rec outside out rc
  rec=$(make_refusal_home unsafe-record); read_home_record "$rec"
  rec="$HOME_DIR/state/unsafe.capacity"
  outside="$HOME_DIR/outside.capacity"
  printf 'sentinel\n' > "$outside"
  {
    printf 'schema=fm-capacity-deferral.v1\n'
    printf 'task=../outside\n'
    printf 'last_checked=0\n'
    printf 'retry_after=0\n'
  } > "$rec"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0)" tick 2>&1) || rc=$?
  expect_code 1 "$rc" "an unsafe recorded task id must stop the wait"
  assert_grep "terminal=unsafe recorded task id rejected: ../outside" "$rec" "the trusted record was not marked terminal"
  assert_contains "$out" "rejected unsafe task id ../outside" "the stop did not name the rejected id"
  [ "$(cat "$outside")" = sentinel ] || fail "the unsafe recorded id modified a file outside state"
  assert_absent "$HOME_DIR/outside.status" "the unsafe recorded id created a status path outside state"
  assert_absent "$HOME_DIR/outside.attempt" "the unsafe recorded id reached the attempt owner outside state"
  assert_absent "$HOME_DIR/outside.meta" "the unsafe recorded id reached a metadata path outside state"
  pass "an unsafe recorded task id stops without writing outside the state directory"
}

test_linked_capacity_record_is_refused_untouched() {
  local rec target out rc
  rec=$(make_refusal_home linked-record); read_home_record "$rec"
  target="$HOME_DIR/outside-record"
  printf 'task=linkedtask\nsentinel=unchanged\n' > "$target"
  ln -s "$target" "$HOME_DIR/state/linkedtask.capacity"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0)" tick 2>&1) || rc=$?
  expect_code 1 "$rc" "tick must refuse a symlinked capacity record"
  assert_contains "$out" "$HOME_DIR/state/linkedtask.capacity" "tick did not name the rejected capacity path"
  assert_contains "$out" "not an ordinary private single-link record" "tick did not name the record trust failure"
  [ "$(cat "$target")" = $'task=linkedtask\nsentinel=unchanged' ] || fail "tick wrote through the capacity symlink"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0)" list 2>&1) || rc=$?
  expect_code 1 "$rc" "list must refuse a symlinked capacity record"
  assert_contains "$out" "not an ordinary private single-link record" "list bypassed the record trust guard"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0)" release linkedtask 2>&1) || rc=$?
  expect_code 1 "$rc" "release must refuse a symlinked capacity record"
  assert_contains "$out" "not an ordinary private single-link record" "release bypassed the record trust guard"
  assert_present "$HOME_DIR/state/linkedtask.capacity" "release removed the suspect capacity link"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer linkedtask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium 2>&1) || rc=$?
  expect_code 1 "$rc" "defer must refuse an existing symlinked capacity record"
  assert_contains "$out" "not an ordinary private single-link record" "defer bypassed the record accessor"
  [ -L "$HOME_DIR/state/linkedtask.capacity" ] || fail "defer replaced the suspect capacity link"
  [ "$(cat "$target")" = $'task=linkedtask\nsentinel=unchanged' ] || fail "a capacity command changed the symlink target"
  pass "a symlinked capacity record is refused without touching its target"
}

test_resumes_onto_an_expressive_recovered_pool_member
test_uncounted_deferral_fails_closed
test_same_band_substitution_is_required
test_unrecordable_bound_leaves_no_active_wait
test_non_capacity_refusal_keeps_a_counted_wait
test_moved_capacity_picture_resets_stagnation
test_record_refresh_failure_stops_durably
test_unsafe_recorded_id_stops_without_escaping_state
test_linked_capacity_record_is_refused_untouched
