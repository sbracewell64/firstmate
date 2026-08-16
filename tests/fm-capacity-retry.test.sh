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

# NEGATIVE CONTROL: the resume asks the ROUTE OWNER, and only for the candidates
# that FOLLOW the failed model in its own pool.
#
# This case replaces one that asserted the opposite - that a pool member sitting
# EARLIER than the failed model resumes the work as soon as it recovers. That
# behaviour is a SECOND FAILOVER SELECTOR: it answers "which model do I
# substitute to" by walking the whole eligible list, independently of
# `fm-route.sh next --after`, which is the fleet's canonical answer and is
# already on main. Two answers to one routing question diverge the moment either
# changes, and the eligibility-ordered one can reach a model the failed model's
# pool never names.
#
# The pool is vendor/large then alt/large, and the task failed on alt/large, the
# LAST member. `next --after alt/large` therefore names nobody, and the lawful
# outcome is to keep waiting rather than to resume backwards onto vendor/large.
# Against a build whose resume selects by eligibility alone, vendor/large IS
# selected and the task resumes, so this case goes red - which is the whole
# point of keeping it.
test_resume_does_not_select_a_model_before_the_failed_one() {
  local out meta
  make_dispatch_home earlier-resume
  write_brief "$HOME_DIR" earliertask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0 altq=0)" \
    earliertask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model alt/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "both spent candidates must first create a wait"
  # Only the EARLIER pool member recovers.
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=95 altq=0)" tick --id earliertask --force)
  meta="$HOME_DIR/state/earliertask.meta"
  assert_absent "$meta" "the resume reached backwards to a pool member BEFORE the model that failed, which means it selected a candidate the route owner never offered"
  assert_not_contains "$out" "vendor/large in route R-PAIR" "the resume named a candidate that does not follow the failed model in pool order"
  assert_present "$HOME_DIR/state/earliertask.capacity" "with no candidate after the failed model, the lawful outcome is to keep waiting, not to retire the wait"
  pass "a resume never selects a model before the failed one; with none after it, the wait continues"
}

test_recorded_effort_survives_policy_edit() {
  local out cfg meta
  make_dispatch_home inherited-effort
  cfg="$HOME_DIR/config/crew-dispatch.json"
  write_brief "$HOME_DIR" inheritedtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
    inheritedtask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the fixture did not defer the explicitly banded dispatch"
  assert_grep "effort=medium" "$HOME_DIR/state/inheritedtask.capacity" "the stated route effort was not persisted"
  jq '._floors["F-MED"].effort_floor = "low"' "$cfg" > "$cfg.tmp" && mv "$cfg.tmp" "$cfg"
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=95)" tick --id inheritedtask --force)
  meta="$HOME_DIR/state/inheritedtask.meta"
  assert_present "$meta" "the explicitly banded dispatch did not resume after capacity returned"
  assert_grep "effort=medium" "$meta" "the resumed dispatch changed its recorded effort after the policy edit"
  pass "recorded effort survives a policy edit across deferral and resume"
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
  # A record that could not be WRITTEN is could-not-observe, not exhaustion:
  # nothing here established that any pool was tried and found empty.
  assert_grep "terminal=blocked_by_evidence_integrity" "$HOME_DIR/state/refreshtask.attempt" "the attempt owner did not record the unobservable stop"
  assert_no_grep "terminal=budget_exhausted" "$HOME_DIR/state/refreshtask.attempt" "a record-write failure was recorded as an exhausted budget, which makes a broken recorder indistinguishable from a tried-and-empty pool"
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

# NEGATIVE CONTROL: ONE bound per WORK ITEM, not one per model.
#
# The ruling's failure here is arithmetic, not policy. Substituting to a
# floor-meeting pool member is correct failover and must resume, but if the
# retry bound travels with the MODEL then N pool members multiply into N budgets
# and the driver runs unbounded while every individual accounting still looks
# correct. That is the reason the driver never ended, and it is invisible to any
# check that only asks whether a bound exists.
#
# The SIGNATURE is what a substitution changes - it names the capacity picture
# the wait is now watching - so "a per-model budget" is exactly a build in which
# a changed signature resets the count. Every defer below therefore carries a
# DIFFERENT signature and names a different pool member, and the count must
# still climb 1, then 2, then refuse. Against a per-model bound the second defer
# reads deferrals=1 and the third is allowed, so this case goes red.
#
# Stagnation cannot be what stops it: a changed signature resets the stagnation
# counter every time, which leaves the total work-item bound as the only thing
# able to end this wait.
test_one_bound_per_work_item_across_substitutions() {
  local rec out rc
  rec=$(make_refusal_home item-bound); read_home_record "$rec"
  write_brief "$HOME_DIR" itemtask no-mistakes

  item_defer() {  # <model> <signature>
    FM_ATTEMPT_DEFER_BUDGET_DEFAULT=2 \
      run_retry "$HOME_DIR" "$(quota_record vendorq=0 altq=0)" defer itemtask \
      --route R-PAIR --floor F-MED --pool vendor/large,alt/large --reason spent \
      --signature "$2" --project "$PROJ_DIR" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --model "$1" --effort medium 2>&1
  }

  rc=0; out=$(item_defer vendor/large vendor=spent) || rc=$?
  expect_code 0 "$rc" "the first wait on this work item must be within bounds"
  assert_grep "deferrals=1" "$HOME_DIR/state/itemtask.attempt" "the first deferral was not counted against the work item"

  # The substitution. A different pool member, a different capacity picture, and
  # therefore a different signature - the exact transition a per-model budget
  # would treat as a fresh start.
  rc=0; out=$(item_defer alt/large alt=spent) || rc=$?
  expect_code 0 "$rc" "a substitution inside the pool must keep waiting, not stop"
  assert_grep "deferrals=2" "$HOME_DIR/state/itemtask.attempt" "the substitution reset the bound instead of spending from the budget it inherited, so each pool member carries its own budget and the driver is unbounded"
  assert_no_grep "deferrals=1" "$HOME_DIR/state/itemtask.attempt" "the work item's count did not advance across the substitution"

  # Third wait, second substitution: the inherited budget is now spent and the
  # driver must end regardless of how many pool members are still healthy.
  rc=0; out=$(item_defer vendor/large vendor=spent-again) || rc=$?
  expect_code 3 "$rc" "the work item's bound did not stop the driver after two substitutions"
  assert_grep "terminal=budget_exhausted" "$HOME_DIR/state/itemtask.attempt" "a spent bound is observed-bad and must be recorded as an exhausted budget"
  assert_contains "$out" "deferral budget of 2 is spent" "the stop did not name the work item's bound"
  unset -f item_defer
  pass "one retry bound is owned by the work item and consumed monotonically across substitutions"
}

# NEGATIVE CONTROL: the two stops are DIFFERENT terminal states.
#
# This is the load-bearing half of the ruling. Budget spent is observed-bad: the
# pool was tried and the bound was reached. Count unrecordable is
# could-not-observe, and the could-not-observe lands on the BOUND ITSELF - the
# wait stopped without anything ever establishing that a model was tried and
# found out of capacity.
#
# Report the second as the first and a broken recorder becomes indistinguishable
# from an exhausted pool: the fleet reads "we tried everything" when the truth is
# "we could not tell how many times we tried". One is a routing fact worth acting
# on, the other is a defect in the instrument, and they share no repair.
#
# Against a build that records both as exhaustion this case goes red on case B,
# and the closing assertion goes red on ANY build that gives them one name -
# including a future one that renames the pair rather than separating them.
test_the_two_capacity_stops_are_distinguishable() {
  local rec out rc stub spent_state unmeasured_state
  rec=$(make_refusal_home two-stops); read_home_record "$rec"
  write_brief "$HOME_DIR" spenttask no-mistakes
  write_brief "$HOME_DIR" blindtask no-mistakes

  # Case A - the bound was REACHED. One deferral allowed, so the second refuses.
  rc=0
  FM_ATTEMPT_DEFER_BUDGET_DEFAULT=1 \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer spenttask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the first wait must be within bounds"
  rc=0
  out=$(FM_ATTEMPT_DEFER_BUDGET_DEFAULT=1 \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer spenttask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=still-spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium) || rc=$?
  expect_code 3 "$rc" "a spent bound must stop the wait"

  # Case B - the bound was never MEASURABLE. The count write fails while the
  # owner can still record the stop, which is the only condition under which a
  # collapsing build and a distinguishing build differ in the durable record.
  stub="$TMP_ROOT/two-stops/defer-blind"
  cat > "$stub" <<SH
#!/bin/sh
case "\$1" in
  defer) printf 'simulated count write failure\n' >&2; exit 1 ;;
esac
exec "$ATTEMPT" "\$@"
SH
  chmod +x "$stub"
  rc=0
  out=$(FM_ATTEMPT_BIN="$stub" \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer blindtask \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium) || rc=$?
  expect_code 1 "$rc" "an unrecordable count must stop the wait"

  assert_grep "terminal=budget_exhausted" "$HOME_DIR/state/spenttask.attempt" "a reached bound must be recorded as observed-bad exhaustion"
  assert_grep "terminal=blocked_by_evidence_integrity" "$HOME_DIR/state/blindtask.attempt" "an unrecordable bound must be recorded as could-not-observe, not as exhaustion"
  assert_no_grep "terminal=budget_exhausted" "$HOME_DIR/state/blindtask.attempt" "the unmeasurable stop was recorded as an exhausted pool, so a broken recorder is indistinguishable from one that was tried and found empty"

  # The distinction has to be READABLE, not merely differently worded. A reader
  # that cannot separate the two facts from the durable record is the failure,
  # whatever the two states happen to be called.
  spent_state=$(sed -n 's/^terminal=\(..*\)$/\1/p' "$HOME_DIR/state/spenttask.attempt" | head -1)
  unmeasured_state=$(sed -n 's/^terminal=\(..*\)$/\1/p' "$HOME_DIR/state/blindtask.attempt" | head -1)
  [ -n "$spent_state" ] || fail "the spent bound recorded no terminal state at all"
  [ -n "$unmeasured_state" ] || fail "the unmeasurable bound recorded no terminal state at all"
  [ "$spent_state" != "$unmeasured_state" ] \
    || fail "both capacity stops recorded the same terminal state '$spent_state', so the durable record cannot tell an exhausted pool from a recorder that never measured the bound"

  # RECURRENCE GUARD. The distinction must not be able to decay by OMISSION. A
  # stop site added later that simply forgets to say what it observed is refused
  # outright rather than landing on whichever state the owner happens to prefer,
  # and any preference here is exhaustion - which is the collapse itself. This
  # is what makes the mechanism gone rather than the symptom corrected.
  rc=0
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ATTEMPT" stop-defer guardtask --reason "no observation named" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "stop-defer accepted a stop without naming what was observed, so a later caller can collapse the two terminal states by omission"
  assert_contains "$out" "different terminal states" "the refusal did not explain why naming the observation is required"
  ! [ -e "$HOME_DIR/state/guardtask.attempt" ] \
    || fail "a refused stop still wrote a terminal state to the durable record"
  pass "a spent bound and an unmeasurable bound are different terminal states in the durable record"
}

test_spent_deferral_bound_cannot_be_raised_in_place() {
  local rec out rc
  rec=$(make_refusal_home spent-override); read_home_record "$rec"
  write_brief "$HOME_DIR" spentoverride no-mistakes

  rc=0
  FM_ATTEMPT_DEFER_BUDGET_DEFAULT=1 \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer spentoverride \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the first deferral must spend the one allowed wait"
  rc=0
  out=$(FM_ATTEMPT_DEFER_BUDGET_DEFAULT=1 \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" defer spentoverride \
    --route R-SOLO --floor F-MED --pool vendor/large --reason spent \
    --signature vendor=still-spent --project "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --model vendor/large --effort medium) || rc=$?
  expect_code 3 "$rc" "the second deferral must exhaust the recorded bound"
  assert_contains "$out" "A higher --defer-budget must be chosen before the bound is spent" "the stop did not distinguish advance configuration from recovery"
  assert_contains "$out" "retire the durable attempt record through ordinary task teardown" "the stop did not name the recovery that actually clears spent state"
  assert_not_contains "$out" "release" "the stop advertised release even though it preserves the spent attempt record"

  rc=0
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ATTEMPT" defer spentoverride --defer-budget 5 --signature vendor=still-spent >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the recorded override must remain writable without reopening the work item"
  assert_grep "terminal=budget_exhausted" "$HOME_DIR/state/spentoverride.attempt" "the larger supplied budget cleared the terminal state"
  rc=0
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=95)" tick --id spentoverride --force) || rc=$?
  expect_code 0 "$rc" "the retry driver must handle a terminal wait without failing"
  assert_absent "$HOME_DIR/state/spentoverride.meta" "the retry driver resumed a wait whose bound was already spent"
  assert_grep "terminal=" "$HOME_DIR/state/spentoverride.capacity" "the driver did not preserve a terminal diagnostic record"
  pass "a spent deferral bound stays spent and names only executable recovery"
}

# The captain-facing half of the same rule. "Name which, in the durable record
# AND in whatever reaches me" - a record that distinguishes the two stops behind
# a startup line that reports them as one number still tells the fleet the pool
# was tried and found empty when the truth is that nothing measured the wait.
#
# The two lines are asserted to be SEPARATE and to name disjoint task sets, so a
# build that reverts to one combined count goes red on the missing line, and a
# build that emits both but files the unmeasured task under the exhausted line
# goes red on the disjointness assertion.
test_bootstrap_reports_the_two_capacity_stops_separately() {
  local home out deferred_line unmeasured_line
  home="$TMP_ROOT/bootstrap-stops/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf 'manual\n' > "$home/config/backlog-backend"
  printf 'task=spenttask\nterminal=deferral bound spent\n' > "$home/state/spenttask.capacity"
  printf 'attempt=1\nattempt_budget=2\nterminal=budget_exhausted\n' > "$home/state/spenttask.attempt"
  printf 'task=blindtask\nterminal=attempt count could not be recorded\n' > "$home/state/blindtask.capacity"
  printf 'attempt=1\nattempt_budget=2\nterminal=blocked_by_evidence_integrity\n' > "$home/state/blindtask.attempt"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PROJECTS_OVERRIDE="$home/projects" \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1 | grep -E '^CAPACITY_' || true)

  assert_contains "$out" "CAPACITY_DEFERRED: 1 task(s)" "the reached bound was not reported as a stopped wait"
  assert_contains "$out" "CAPACITY_UNMEASURED: 1 task(s)" "the unmeasurable bound was not reported separately, so a broken recorder is counted as an exhausted pool"
  # Disjoint sets, checked WITHIN each line rather than across the pair: neither
  # task may be filed under the other's diagnostic.
  deferred_line=$(printf '%s\n' "$out" | grep '^CAPACITY_DEFERRED:')
  unmeasured_line=$(printf '%s\n' "$out" | grep '^CAPACITY_UNMEASURED:')
  assert_contains "$deferred_line" "spenttask" "the exhausted-pool line did not name the task that reached its bound"
  assert_contains "$unmeasured_line" "blindtask" "the unmeasurable line did not name the task whose bound was never written"
  assert_not_contains "$deferred_line" "blindtask" "the task whose bound was never measurable was reported as an exhausted pool"
  assert_not_contains "$unmeasured_line" "spenttask" "the task that reached its bound was reported as unmeasurable"
  pass "session start reports a reached bound and an unmeasurable bound as separate diagnostics"
}

test_resumes_onto_an_expressive_recovered_pool_member
test_resume_does_not_select_a_model_before_the_failed_one
test_recorded_effort_survives_policy_edit
test_uncounted_deferral_fails_closed
test_one_bound_per_work_item_across_substitutions
test_the_two_capacity_stops_are_distinguishable
test_spent_deferral_bound_cannot_be_raised_in_place
test_bootstrap_reports_the_two_capacity_stops_separately
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
