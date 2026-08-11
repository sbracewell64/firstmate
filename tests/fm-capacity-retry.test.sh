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

test_inexpressive_and_unverified_substitutes_keep_waiting() {
  local variant rec out
  for variant in inexpressive unverified; do
    rec=$(make_refusal_home "band-$variant"); read_home_record "$rec"
    jq '._floors["F-MED"].effort_floor = "WAIVED - retry predicate owns the recorded band"' \
      "$HOME_DIR/config/crew-dispatch.json" > "$HOME_DIR/config/crew-dispatch.json.tmp"
    mv "$HOME_DIR/config/crew-dispatch.json.tmp" "$HOME_DIR/config/crew-dispatch.json"
    if [ "$variant" = unverified ]; then
      jq 'del(._models["weak/tiny"].effort_expressible)' "$HOME_DIR/config/crew-dispatch.json" \
        > "$HOME_DIR/config/crew-dispatch.json.tmp"
      mv "$HOME_DIR/config/crew-dispatch.json.tmp" "$HOME_DIR/config/crew-dispatch.json"
    fi
    write_brief "$HOME_DIR" "bandtask-$variant" no-mistakes
    out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 weakq=0)" \
      "bandtask-$variant" "$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-WEAK --model vendor/large --effort medium)
    assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
    out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0 weakq=95)" tick --id "bandtask-$variant" --force)
    assert_absent "$HOME_DIR/state/bandtask-$variant.meta" "a substitute without band evidence was dispatched"
    assert_present "$HOME_DIR/state/bandtask-$variant.capacity" "the refused substitution did not keep waiting"
  done
  pass "a substitute that cannot express the route effort band is refused and the task keeps waiting"
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
  [ "$(cat "$target")" = $'task=linkedtask\nsentinel=unchanged' ] || fail "a capacity command changed the symlink target"
  pass "a symlinked capacity record is refused without touching its target"
}

test_resumes_onto_an_expressive_recovered_pool_member
test_uncounted_deferral_fails_closed
test_inexpressive_and_unverified_substitutes_keep_waiting
test_non_capacity_refusal_keeps_a_counted_wait
test_moved_capacity_picture_resets_stagnation
test_record_refresh_failure_stops_durably
test_unsafe_recorded_id_stops_without_escaping_state
test_linked_capacity_record_is_refused_untouched
