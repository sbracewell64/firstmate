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
  # Preserve the generated stub's positional parameter for its own runtime.
  # shellcheck disable=SC2016
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

test_non_capacity_refusal_consults_route_owner_for_substitute() {
  local out
  make_dispatch_home secondary-refusal
  cat > "$OK_BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *vendor/large*) exit 1 ;;
esac
exit 0
SH
  chmod +x "$OK_BIN/tmux"
  write_brief "$HOME_DIR" blockedtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0 altq=0)" \
    blockedtask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=95 altq=95)" tick --id blockedtask --force)
  assert_present "$HOME_DIR/state/blockedtask.meta" "a lawful substitute was skipped after a non-capacity refusal"
  assert_grep "model=alt/large" "$HOME_DIR/state/blockedtask.meta" "the route owner's substitute was not used"
  assert_contains "$out" "alt/large in route R-PAIR" "the automatic substitute resume was not disclosed"
  assert_absent "$HOME_DIR/state/blockedtask.capacity" "the resumed wait record was not retired"
  pass "a non-capacity refusal consults the route owner and resumes on its substitute"
}

test_non_capacity_refusal_without_substitute_keeps_waiting() {
  local rec out
  rec=$(make_refusal_home secondary-refusal-wait); read_home_record "$rec"
  write_brief "$HOME_DIR" blockedwaittask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=0)" \
    blockedwaittask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=0)" tick --id blockedwaittask --force)
  assert_present "$HOME_DIR/state/blockedwaittask.capacity" "a refusal with no lawful substitute ended the capacity wait"
  assert_no_grep "terminal=" "$HOME_DIR/state/blockedwaittask.capacity" "a secondary refusal marked the capacity wait terminal"
  pass "a non-capacity refusal with no lawful substitute keeps waiting"
}

test_moved_capacity_picture_resets_stagnation() {
  local rec out
  rec=$(make_refusal_home moved-picture); read_home_record "$rec"
  write_brief "$HOME_DIR" movingtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=0)" \
      movingtask "$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-PAIR --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not enter a capacity wait"
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=95)" tick --id movingtask --force)
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

test_provider_reset_precedes_blind_backoff() {
  local rec now reset due checked
  rec=$(make_refusal_home provider-reset); read_home_record "$rec"
  write_brief "$HOME_DIR" resettask no-mistakes
  now=$(date -u +%s)
  reset=$((now + 120))
  FM_CAPACITY_RECHECK_BASE=3600 run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer resettask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --retry-after "$reset" --signature vendor=spent --project "$PROJ_DIR" \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --model vendor/large --effort medium >/dev/null
  due=$(FM_CAPACITY_RECHECK_BASE=3600 run_retry "$HOME_DIR" "$(quota_record vendorq=0)" list \
    | sed -n 's/.*next_check=\([0-9]*\).*/\1/p')
  [ "$due" = "$reset" ] || fail "a future provider reset lost to blind backoff: got $due, want $reset"
  checked=$((reset + 1))
  sed -i.bak "s/^last_checked=.*/last_checked=$checked/" "$HOME_DIR/state/resettask.capacity"
  rm -f "$HOME_DIR/state/resettask.capacity.bak"
  due=$(FM_CAPACITY_RECHECK_BASE=3600 run_retry "$HOME_DIR" "$(quota_record vendorq=0)" list \
    | sed -n 's/.*next_check=\([0-9]*\).*/\1/p')
  [ "$due" -gt "$checked" ] || fail "a consumed provider reset did not enter blind backoff: got $due after $checked"
  [ "$due" != "$reset" ] || fail "a consumed provider reset remained permanently due"
  pass "an unconsumed provider reset wins once and then yields to blind backoff"
}

test_release_serializes_with_active_retry() {
  local rec stub entered gate tick_out release_out tick_pid release_pid
  rec=$(make_refusal_home release-race); read_home_record "$rec"
  write_brief "$HOME_DIR" releasetask no-mistakes
  run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer releasetask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium >/dev/null
  stub="$TMP_ROOT/release-race/attempt"
  entered="$TMP_ROOT/release-race/entered"
  gate="$TMP_ROOT/release-race/gate"
  # Preserve the generated stub's variables for its own runtime.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nif [ "$1" = show ]; then : > "$FM_TEST_ENTERED"; while [ ! -e "$FM_TEST_GATE" ]; do sleep 0.01; done; fi\nexec "$FM_TEST_REAL_ATTEMPT" "$@"\n' > "$stub"
  chmod +x "$stub"
  tick_out="$TMP_ROOT/release-race/tick.out"
  release_out="$TMP_ROOT/release-race/release.out"
  FM_ATTEMPT_BIN="$stub" FM_TEST_ENTERED="$entered" FM_TEST_GATE="$gate" \
    FM_TEST_REAL_ATTEMPT="$ATTEMPT" run_retry "$HOME_DIR" "$(quota_record vendorq=0)" \
    tick --id releasetask --force >"$tick_out" 2>&1 &
  tick_pid=$!
  fm_test_reap "$tick_pid"
  while [ ! -e "$entered" ]; do sleep 0.01; done
  run_retry "$HOME_DIR" "$(quota_record vendorq=0)" release releasetask >"$release_out" 2>&1 &
  release_pid=$!
  fm_test_reap "$release_pid"
  sleep 0.1
  kill -0 "$release_pid" 2>/dev/null || fail "release returned while retry still owned the task"
  : > "$gate"
  wait "$tick_pid" || fail "the active retry failed: $(cat "$tick_out")"
  wait "$release_pid" || fail "the serialized release failed: $(cat "$release_out")"
  assert_absent "$HOME_DIR/state/releasetask.capacity" "release did not retire the wait after retry reconciliation"
  pass "release serializes with active automatic retry ownership"
}

test_release_serializes_with_spawn_deferral() {
  local rec entered gate holder_out release_out holder_pid release_pid
  rec=$(make_refusal_home release-spawn-race); read_home_record "$rec"
  write_brief "$HOME_DIR" spawnreleasetask no-mistakes
  entered="$TMP_ROOT/release-spawn-race/entered"
  gate="$TMP_ROOT/release-spawn-race/gate"
  holder_out="$TMP_ROOT/release-spawn-race/holder.out"
  release_out="$TMP_ROOT/release-spawn-race/release.out"
  (
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$HOME_DIR/state/.spawn-spawnreleasetask.lock"
    : > "$entered"
    while [ ! -e "$gate" ]; do sleep 0.01; done
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer spawnreleasetask \
      --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
      --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium
    fm_lock_release "$HOME_DIR/state/.spawn-spawnreleasetask.lock"
  ) >"$holder_out" 2>&1 &
  holder_pid=$!
  fm_test_reap "$holder_pid"
  while [ ! -e "$entered" ]; do sleep 0.01; done
  run_retry "$HOME_DIR" "$(quota_record vendorq=0)" release spawnreleasetask >"$release_out" 2>&1 &
  release_pid=$!
  fm_test_reap "$release_pid"
  sleep 0.1
  kill -0 "$release_pid" 2>/dev/null || fail "release returned while spawn still owned the task"
  : > "$gate"
  wait "$holder_pid" || fail "the spawn deferral fixture failed: $(cat "$holder_out")"
  wait "$release_pid" || fail "release failed after the spawn deferral: $(cat "$release_out")"
  assert_absent "$HOME_DIR/state/spawnreleasetask.capacity" "spawn recreated the capacity wait after release returned"
  pass "release serializes with an active spawn deferral"
}

test_concurrent_ticks_claim_one_retry_owner() {
  local rec stub log out1 out2 pid1 pid2
  rec=$(make_refusal_home concurrent-tick); read_home_record "$rec"
  write_brief "$HOME_DIR" claimtask no-mistakes
  run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer claimtask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium >/dev/null
  stub="$TMP_ROOT/concurrent-tick/attempt"
  log="$TMP_ROOT/concurrent-tick/show.log"
  # Preserve the generated stub's variables for its own runtime.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nif [ "$1" = show ]; then printf "show\\n" >> "$FM_TEST_SHOW_LOG"; sleep 1; fi\nexec "$FM_TEST_REAL_ATTEMPT" "$@"\n' > "$stub"
  chmod +x "$stub"
  out1="$TMP_ROOT/concurrent-tick/tick-one.out"
  out2="$TMP_ROOT/concurrent-tick/tick-two.out"
  FM_ATTEMPT_BIN="$stub" FM_TEST_SHOW_LOG="$log" FM_TEST_REAL_ATTEMPT="$ATTEMPT" \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" tick --id claimtask --force >"$out1" 2>&1 &
  pid1=$!
  fm_test_reap "$pid1"
  while [ ! -f "$log" ]; do sleep 0.01; done
  FM_ATTEMPT_BIN="$stub" FM_TEST_SHOW_LOG="$log" FM_TEST_REAL_ATTEMPT="$ATTEMPT" \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" tick --id claimtask --force >"$out2" 2>&1 &
  pid2=$!
  fm_test_reap "$pid2"
  wait "$pid1" || fail "the claimed retry owner failed: $(cat "$out1")"
  wait "$pid2" || fail "the concurrent retry tick failed: $(cat "$out2")"
  [ "$(wc -l < "$log" | tr -d ' ')" = 1 ] \
    || fail "concurrent ticks both entered the claimed retry reconciliation"
  pass "concurrent ticks give one process exclusive retry ownership"
}

test_resumes_onto_an_expressive_recovered_pool_member
test_uncounted_deferral_fails_closed
test_same_band_substitution_is_required
test_unrecordable_bound_leaves_no_active_wait
test_non_capacity_refusal_consults_route_owner_for_substitute
test_non_capacity_refusal_without_substitute_keeps_waiting
test_moved_capacity_picture_resets_stagnation
test_record_refresh_failure_stops_durably
test_unsafe_recorded_id_stops_without_escaping_state
test_linked_capacity_record_is_refused_untouched
test_provider_reset_precedes_blind_backoff
test_concurrent_ticks_claim_one_retry_owner
test_release_serializes_with_active_retry
test_release_serializes_with_spawn_deferral
