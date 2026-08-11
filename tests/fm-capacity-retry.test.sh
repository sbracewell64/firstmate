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

test_resumes_onto_an_expressive_recovered_pool_member
test_uncounted_deferral_fails_closed
test_inexpressive_and_unverified_substitutes_keep_waiting
test_non_capacity_refusal_keeps_a_counted_wait
