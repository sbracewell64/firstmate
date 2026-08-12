#!/usr/bin/env bash
# Behavior tests for quota-aware routing and durable capacity retry
# (bin/fm-capacity-lib.sh, bin/fm-capacity-retry.sh, bin/fm-attempt.sh's
# deferral bounds, and the capacity gate at the bin/fm-spawn.sh chokepoint).
#
# The measured failure these close: overnight 2026-08-10/11 five lanes stalled
# repeatedly because the platform discovered a provider window was spent only
# AFTER dispatching into it, and recovery then waited for a human to say
# continue. Closing that needs two proofs, not one, and this file is written to
# carry both.
#
#   INSTANCE_FIXED - a task whose floor's candidates are all exhausted is not
#   dispatched into them, and a capacity-blocked task resumes by itself.
#
#   RECURRENCE_PATH_CLOSED - the MECHANISM is gone. There is no path by which a
#   dispatch proceeds without consulting availability, and no path by which
#   unavailability lowers a floor. A test that only re-checks the symptom does
#   not establish that, so two cases here are written to fail if the mechanism
#   is reintroduced rather than if today's bad state returns: every enforcing
#   dispatch must record WHAT capacity it was admitted against, including when
#   the answer was could-not-observe, and a pool holding an available model that
#   does not meet the floor must still defer.
#
# The five properties pinned:
#
#   1. RED BOTH WAYS. An exhausted floor pool defers with the pool and the retry
#      condition named, and the identical dispatch with capacity available runs
#      through the same code path untouched.
#   2. THE FLOOR IS NEVER LOWERED. An available model that does not meet the
#      floor is not a substitute, so the answer stays a deferral.
#   3. THREE VALUES, NEVER TWO. Unobservable quota is could_not_observe: the
#      candidate stays eligible and the uncertainty is recorded durably, so the
#      answer is neither "available" nor "unavailable".
#   4. IT SURVIVES A RESTART. The deferral is a file, and a fresh process with no
#      inherited state resumes the work once capacity returns, with no operator
#      message.
#   5. IT IS BOUNDED. A wait whose observed picture never moves stops rather
#      than polling forever, through the one owner of that arithmetic.
#
# Refusal cases stop before any endpoint exists, and a fake `tmux` that exits
# non-zero backstops them, so a case that wrongly proceeded would fail rather
# than quietly create a worker. Every quota reading is injected, so no case
# depends on this host's real provider windows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
RETRY="$ROOT/bin/fm-capacity-retry.sh"
ATTEMPT="$ROOT/bin/fm-attempt.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity-routing)

# A routed policy with the shape the live home uses, plus the declared quota
# binding this seam adds. Three providers on purpose: one whose windows are
# readable, one that is readable and healthy but whose model does not meet the
# floor, and one that declares no readable quota at all.
write_capacity_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_providers": {
    "vendor": { "quota_observable": true, "quota_axi_provider": "vendorq" },
    "alt":    { "quota_observable": true, "quota_axi_provider": "altq" },
    "weak":   { "quota_observable": true, "quota_axi_provider": "weakq" },
    "dark":   { "quota_observable": false }
  },
  "_floors": {
    "F-MED":  { "effort_floor": "medium", "context_ceiling": 140000, "tool_loop": "verified-agentic" },
    "F-ONLY": { "effort_floor": "medium", "context_ceiling": 140000, "tool_loop": "verified-agentic" }
  },
  "_models": {
    "vendor/large": { "smart_zone": 140000, "effort_expressible": ["low","medium","high"], "tool_loop": "verified-agentic" },
    "alt/large":    { "smart_zone": 140000, "effort_expressible": ["low","medium","high"], "tool_loop": "verified-agentic" },
    "weak/tiny":    { "smart_zone": 140000, "effort_expressible": ["low"], "tool_loop": "verified-agentic" },
    "dark/opaque":  { "smart_zone": 140000, "effort_expressible": ["low","medium","high"], "tool_loop": "verified-agentic" }
  },
  "rules": [
    { "when": "one candidate only", "route": "R-SOLO", "floor": "F-MED",
      "use": { "harness": "codex", "model": "vendor/large", "effort": "medium" },
      "pool": ["vendor/large"] },
    { "when": "a weaker sibling is in the pool", "route": "R-WEAK", "floor": "F-MED",
      "use": { "harness": "codex", "model": "vendor/large", "effort": "medium" },
      "pool": ["vendor/large", "weak/tiny"] },
    { "when": "a floor-meeting sibling is in the pool", "route": "R-PAIR", "floor": "F-MED",
      "use": { "harness": "codex", "model": "vendor/large", "effort": "medium" },
      "pool": ["vendor/large", "alt/large"] },
    { "when": "the provider publishes no quota", "route": "R-DARK", "floor": "F-MED",
      "use": { "harness": "codex", "model": "dark/opaque", "effort": "medium" },
      "pool": ["dark/opaque"] },
    { "when": "the only route naming its floor", "route": "R-ONLY", "floor": "F-ONLY",
      "use": { "harness": "codex", "model": "alt/large", "effort": "medium" },
      "pool": ["alt/large"] }
  ],
  "default": { "harness": "codex", "model": "vendor/large", "effort": "medium",
               "route": "R-SOLO", "floor": "F-MED" }
}
JSON
}

# The schema every other home uses: profiles only, no pool, so there is nothing
# to enforce and this activation must not reach it.
write_unrouted_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": { "F-GEN": "ordinary generalist work" },
  "rules": [ { "when": "anything", "use": { "harness": "codex", "model": "gpt-5", "effort": "medium" }, "floor": "F-GEN" } ],
  "default": { "harness": "codex", "model": "gpt-5", "effort": "medium", "floor": "F-GEN" }
}
JSON
}

# One quota-axi record, assembled from named per-provider percentages so a case
# reads as the condition it is testing rather than as a wall of JSON. A reset
# time is published for every provider, because the retry condition a deferral
# records comes from that number.
quota_record() {  # <provider>=<percent> ...
  local spec provider pct entries=
  for spec in "$@"; do
    provider=${spec%%=*}
    pct=${spec#*=}
    entries="$entries{\"provider\":\"$provider\",\"state\":{\"status\":\"fresh\"},\"windows\":[{\"id\":\"weekly\",\"resetsAt\":\"2026-08-15T23:00:00.5+00:00\"}],\"quotaSemantics\":{\"status\":\"known\",\"effectiveAvailability\":[{\"scope\":\"all_models\",\"status\":\"known\",\"effectivePercentRemaining\":$pct,\"limitingWindowIds\":[\"weekly\"]}]}},"
  done
  printf '{"schemaVersion":3,"providers":[%s]}\n' "${entries%,}"
}

# The epoch 2026-08-15T23:00:00Z, which is the retry condition every record
# above publishes. Computed rather than pasted, so a case asserts against the
# same conversion the code performs rather than against a constant.
RESET_EPOCH=$(printf '%s\n' '2026-08-15T23:00:00Z' | jq -R -r 'fromdateiso8601')

# A home whose fake tmux REFUSES, so any case that wrongly got past the gate
# fails loudly instead of leaving a worker behind.
make_refusal_home() {  # <name> [routed|unrouted]
  local name=$1 shape=${2:-routed} home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  case "$shape" in
    routed) write_capacity_config "$home" ;;
    unrouted) write_unrouted_config "$home" ;;
  esac
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

# A home whose fake tmux SUCCEEDS and which owns a real isolated worktree, for
# the cases that have to reach task metadata. Sets HOME_DIR, OK_BIN and OK_REPO.
make_dispatch_home() {  # <name> [routed|unrouted]
  local name=$1 shape=${2:-routed} rec
  rec=$(make_refusal_home "$name" "$shape"); read_home_record "$rec"
  OK_BIN="$TMP_ROOT/$name/okbin"
  mkdir -p "$OK_BIN"
  cat > "$OK_BIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$OK_BIN/tmux"
  fm_fake_treehouse "$OK_BIN"
  fm_fake_exit0 "$OK_BIN" codex
  OK_REPO="$TMP_ROOT/$name/repo"
  OK_WT="$TMP_ROOT/$name/wt"
  fm_git_worktree "$OK_REPO" "$OK_WT" "wt-$name"
  touch "$HOME_DIR/state/.last-watcher-beat"
}

read_home_record() {
  IFS='|' read -r HOME_DIR PROJ_DIR FAKEBIN <<EOF
$1
EOF
}

write_brief() {  # <home> <id> [<mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

# Every spawn in this file carries an injected quota reading, so no case depends
# on this host's real provider windows or on quota-axi being installed at all.
run_spawn() {  # <home> <fakebin> <quota-json> <args...>
  local home=$1 fakebin=$2 quota=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' PATH="$fakebin:$PATH" \
    FM_CAPACITY_QUOTA_JSON="$quota" \
    "$SPAWN" "$@" 2>&1
}

run_retry() {  # <home> <quota-json> <args...>
  local home=$1 quota=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CAPACITY_QUOTA_JSON="$quota" \
    "$RETRY" "$@" 2>&1
}

# --- 1. an exhausted floor pool defers, naming the pool and the retry condition

test_exhausted_floor_pool_defers_rather_than_dispatching() {
  local rec out
  rec=$(make_refusal_home exhausted-solo); read_home_record "$rec"
  write_brief "$HOME_DIR" solotask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0)" \
    solotask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a dispatch into an exhausted floor pool must be refused"
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the stable deferral token is missing"
  assert_contains "$out" "vendor/large" "the exhausted candidate is not named"
  assert_contains "$out" "0 percent remaining" "the observed capacity is not quoted"
  assert_contains "$out" "$RESET_EPOCH" "the retry condition - the earliest known recovery - is not named"
  assert_contains "$out" "do not lower the floor" "the refusal does not say what must not happen instead"
  # Nothing was created: the whole point is that the pool is never entered.
  assert_absent "$HOME_DIR/state/solotask.meta" "a deferred dispatch must leave no task metadata"
  assert_present "$HOME_DIR/state/solotask.capacity" "a deferral that is not recorded is work that never resumes"
  assert_grep "route=R-SOLO" "$HOME_DIR/state/solotask.capacity" "the deferral must record the route it is waiting on"
  assert_grep "pool=vendor/large" "$HOME_DIR/state/solotask.capacity" "the deferral must record the pool it stayed inside"
  assert_grep "retry_after=$RESET_EPOCH" "$HOME_DIR/state/solotask.capacity" "the deferral must record its retry condition"
  pass "an exhausted floor pool defers with the pool and the retry condition recorded, and dispatches nothing"
}

# --- 2. the same dispatch with capacity available is untouched ---------------

test_available_capacity_dispatches_and_records_what_it_was_admitted_against() {
  local out meta
  make_dispatch_home available-solo
  write_brief "$HOME_DIR" oktask no-mistakes
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=89)" \
      oktask "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-SOLO --model vendor/large --effort medium)
  meta="$HOME_DIR/state/oktask.meta"
  [ -f "$meta" ] || fail "a dispatch with capacity available must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  assert_not_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "available capacity must not defer"
  # RECURRENCE PROBE. The recorded verdict is what proves this dispatch consulted
  # availability at all. A dispatch that reached metadata with no capacity field
  # in an enforcing home is one that got past the gate.
  assert_grep "capacity_observed=available" "$meta" "meta must record the capacity this dispatch was admitted against"
  assert_grep "capacity_evidence=quota-axi vendorq" "$meta" "meta must record the evidence for that capacity, not just the verdict"
  assert_absent "$HOME_DIR/state/oktask.capacity" "a dispatch that ran must leave no capacity deferral behind"
  pass "capacity available dispatches unchanged and records the verdict and evidence it was admitted against"
}

# --- 3. unavailability never lowers the floor --------------------------------

test_an_available_model_below_the_floor_is_not_a_substitute() {
  local rec out
  rec=$(make_refusal_home floor-hold); read_home_record "$rec"
  write_brief "$HOME_DIR" floortask no-mistakes
  # weak/tiny is in the SAME pool and its provider is at 100 percent, so it is
  # available in every sense except the one that matters: it cannot express the
  # effort this route's floor requires.
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 weakq=100)" \
    floortask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-WEAK --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "an exhausted floor candidate must not be replaced by a below-floor one"
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the answer must be a deferral, not a substitution"
  # The precise failure this closes: weak/tiny must never appear as something to
  # fail over to. It may appear in the per-candidate disclosure below, so the
  # substitution sentence itself is what is asserted against.
  assert_not_contains "$out" "Fail over to the next eligible model inside this route pool, in pool order (weak/tiny" \
    "an available model that does not meet the floor was offered as a substitute"
  assert_absent "$HOME_DIR/state/floortask.meta" "no dispatch may happen when only a below-floor model is available"
  pass "an available model that does not meet the floor is never a substitute: the answer stays a deferral"
}

# --- 4. a floor-meeting sibling IS a substitution, and is not a wait ---------

test_a_floor_meeting_sibling_is_named_rather_than_deferred() {
  local rec out
  rec=$(make_refusal_home pool-sibling); read_home_record "$rec"
  write_brief "$HOME_DIR" pairtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=95)" \
    pairtask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "an exhausted primary must be refused so the caller re-dispatches on the sibling"
  assert_contains "$out" "FM_SPAWN_CAPACITY_EXHAUSTED" "a substitution and a deferral must not share one token"
  assert_contains "$out" "alt/large" "the floor-meeting substitute inside the pool is not named"
  # Work that can run now must not be held behind a wait that has already
  # cleared, so no deferral is recorded for this answer.
  assert_absent "$HOME_DIR/state/pairtask.capacity" "work with an eligible substitute must not be recorded as waiting for capacity"
  assert_absent "$HOME_DIR/state/pairtask.meta" "the refused dispatch must leave no task metadata"
  pass "an exhausted primary with a floor-meeting sibling names the substitute and records no wait"
}

test_a_registry_ineligible_sibling_does_not_prevent_deferral() {
  local rec out
  rec=$(make_refusal_home registry-ineligible-sibling); read_home_record "$rec"
  cat > "$HOME_DIR/config/models.json" <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "vendor": { "status": "active", "cost_posture": "subscription-flat" },
    "alt": { "status": "active", "cost_posture": "subscription-flat" }
  },
  "models": {
    "vendor/large": { "status": "approved-primary" },
    "alt/large": { "status": "blocked", "status_reason": "account entitlement is unavailable" }
  }
}
JSON
  write_brief "$HOME_DIR" blockedpairtask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0 altq=95)" \
    blockedpairtask "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-PAIR --model vendor/large --effort medium); rc=$?
  expect_code 1 "$rc" "a registry-ineligible sibling must not suppress the capacity deferral"
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the exhausted route must create a durable deferral"
  assert_not_contains "$out" "FM_SPAWN_CAPACITY_EXHAUSTED" "a registry-ineligible substitute must not be offered"
  assert_present "$HOME_DIR/state/blockedpairtask.capacity" "the automatic-resume deferral must be recorded"
  assert_absent "$HOME_DIR/state/blockedpairtask.meta" "the deferred dispatch must leave no task metadata"
  pass "a registry-ineligible sibling cannot suppress durable capacity deferral"
}

# --- 5. three values, never two ----------------------------------------------

test_unobservable_quota_is_could_not_observe_and_keeps_the_candidate_eligible() {
  local out meta
  make_dispatch_home dark-provider
  write_brief "$HOME_DIR" darktask no-mistakes
  # The provider declares no readable quota surface, so its window is neither
  # observed spent nor observed remaining.
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
      darktask "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-DARK --model dark/opaque --effort medium)
  meta="$HOME_DIR/state/darktask.meta"
  [ -f "$meta" ] || fail "an unmeasurable candidate must stay eligible"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "capacity_observed=could_not_observe" "$meta" "an unmeasurable candidate must be recorded as could-not-observe"
  assert_no_grep "capacity_observed=available" "$meta" "could-not-observe must never be recorded as available"
  assert_no_grep "capacity_observed=exhausted" "$meta" "could-not-observe must never be recorded as unavailable"
  assert_grep "quota_observable is false" "$meta" "the disclosure must say WHY it could not be observed"
  pass "unobservable quota is could-not-observe: the candidate stays eligible and the reason is recorded durably"
}

test_an_unreadable_quota_source_is_could_not_observe_rather_than_either_answer() {
  local out meta
  make_dispatch_home unreadable-source
  write_brief "$HOME_DIR" srctask no-mistakes
  # The source itself cannot be read. That is a state of knowledge, not evidence
  # of absence, so it must not become "out of capacity" and must not become
  # "capacity remains" either.
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" 'not json at all' \
      srctask "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --route R-SOLO --model vendor/large --effort medium)
  meta="$HOME_DIR/state/srctask.meta"
  [ -f "$meta" ] || fail "an unreadable quota source must not stop a lawful dispatch"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "capacity_observed=could_not_observe" "$meta" "an unreadable source must record the third value"
  assert_grep "source_unreadable" "$meta" "the recorded evidence must name which of the three ways observation failed"
  pass "an unreadable quota source is could-not-observe, becoming neither available nor unavailable"
}

# --- 6. it survives a restart and resumes with no operator message -----------

test_a_deferral_survives_a_restart_and_resumes_when_capacity_returns() {
  local out meta
  make_dispatch_home restart-resume
  write_brief "$HOME_DIR" resumetask no-mistakes
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
    resumetask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the work must be deferred before it can be resumed"
  assert_present "$HOME_DIR/state/resumetask.capacity" "the deferral must be durable"
  assert_absent "$HOME_DIR/state/resumetask.meta" "the deferred work must not have been dispatched"

  # THE RESTART. Nothing in memory carries over: this is a fresh process reading
  # only the file the deferral left behind, which is what a firstmate restart,
  # a closed terminal, a rebooted host and a replaced session all look like.
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=92)" tick --id resumetask --force)
  meta="$HOME_DIR/state/resumetask.meta"
  [ -f "$meta" ] || fail "capacity returned and the work did not resume"$'\n'"--- output ---"$'\n'"$out"
  assert_contains "$out" "resumed automatically" "the resume must say it happened without being asked"
  assert_grep "capacity_observed=available" "$meta" "the resumed dispatch must record the capacity it finally ran on"
  assert_grep "route=R-SOLO" "$meta" "the resumed dispatch must be the same dispatch, on the same route"
  assert_grep "capability_floor=F-MED" "$meta" "the resumed dispatch must run on the same floor it was deferred at"
  assert_grep "FM_CAPACITY_RESUMED" "$HOME_DIR/state/resumetask.status" "the automatic resume must be visible to supervision"
  assert_absent "$HOME_DIR/state/resumetask.capacity" "a resumed deferral must be retired"
  pass "a deferral survives a restart and resumes by itself when capacity returns, on the same route and floor"
}

test_a_deferral_is_not_resumed_while_capacity_is_still_spent() {
  local out
  make_dispatch_home still-spent
  write_brief "$HOME_DIR" waittask no-mistakes
  run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
    waittask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium >/dev/null
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=0)" tick --id waittask --force)
  assert_absent "$HOME_DIR/state/waittask.meta" "a tick must not dispatch into a pool that is still exhausted"
  assert_present "$HOME_DIR/state/waittask.capacity" "a wait that is still valid must be preserved"
  assert_not_contains "$out" "resumed automatically" "nothing resumed, so nothing may claim it did"
  pass "a tick while capacity is still spent keeps waiting instead of dispatching"
}

# --- 7. the wait is bounded ---------------------------------------------------

test_a_stagnating_deferral_stops_rather_than_polling_forever() {
  local rec out i
  rec=$(make_refusal_home stagnation); read_home_record "$rec"
  write_brief "$HOME_DIR" stagtask no-mistakes
  # Three identical observations, with the stagnation limit lowered so the case
  # is fast rather than long. The picture never moves, which is precisely the
  # wait that has stopped being a wait.
  for i in 1 2 3; do
    out=$(FM_ATTEMPT_DEFER_STAGNATION_DEFAULT=3 \
      run_spawn "$HOME_DIR" "$FAKEBIN" "$(quota_record vendorq=0)" \
        stagtask "$PROJ_DIR" --mode no-mistakes --yolo off \
        --reason-code NL_RULE_CLASSIFICATION --harness codex \
        --route R-SOLO --model vendor/large --effort medium)
  done
  assert_contains "$out" "has stopped waiting for capacity" "a stagnating wait must stop and say so"
  assert_contains "$out" "budget_exhausted" "the stop must use the unified terminal state, not a private one"
  assert_grep "terminal=budget_exhausted" "$HOME_DIR/state/stagtask.attempt" "the stop must be durable"
  assert_grep "failed: waiting for capacity stopped" "$HOME_DIR/state/stagtask.status" \
    "a stopped wait must be declared as a failure supervision can see"
  # A stopped wait is never ticked again, however often a sweep runs.
  out=$(run_retry "$HOME_DIR" "$(quota_record vendorq=95)" tick --id stagtask --force)
  assert_absent "$HOME_DIR/state/stagtask.meta" "a stopped wait must not silently resume later"
  pass "a wait whose observed picture never moves stops, durably, and is never ticked again"
}

test_the_deferral_bound_is_arithmetic_over_one_record_and_spends_no_attempt() {
  local home out
  home="$TMP_ROOT/bound/home"
  mkdir -p "$home/state" "$home/data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEMPT" defer boundtask --defer-budget 2 --signature "a=exhausted@1")
  assert_contains "$out" "deferrals=1 deferral_budget=2" "the first deferral is not counted"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEMPT" defer boundtask --signature "b=exhausted@2")
  assert_contains "$out" "deferrals=2" "the recorded budget must survive without being restated"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEMPT" defer boundtask --signature "c=exhausted@3" 2>&1); rc=$?
  expect_code 3 "$rc" "a spent deferral budget must refuse the next wait"
  assert_contains "$out" "stopped waiting for capacity" "the refusal must name what stopped"
  # A task the fleet had no capacity for did not fail, so no attempt was spent.
  assert_grep "attempt=0" "$home/state/boundtask.attempt" "waiting for capacity must never spend a retry attempt"
  pass "the deferral bound is arithmetic over the one attempt record, and spends no retry attempt"
}

test_an_attempt_write_preserves_the_deferral_count() {
  local home
  home="$TMP_ROOT/preserve/home"
  mkdir -p "$home/state" "$home/data"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEMPT" defer preservetask --signature "a=exhausted@1" >/dev/null
  # The attempt path rewrites this record. If it dropped the deferral count, one
  # relaunch would silently unbound every wait, which is the bound quietly
  # disappearing rather than being raised deliberately.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$ATTEMPT" open preservetask >/dev/null
  assert_grep "deferrals=1" "$home/state/preservetask.attempt" \
    "opening an attempt must not drop the deferral count that bounds the wait"
  pass "opening an attempt preserves the deferral count, so a relaunch cannot unbound a wait"
}

# --- 8. inert where nothing is configured ------------------------------------

test_a_home_with_no_routed_pool_is_untouched() {
  local out meta
  make_dispatch_home unrouted unrouted
  write_brief "$HOME_DIR" plaintask no-mistakes
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
      plaintask "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex --model gpt-5 --effort medium)
  meta="$HOME_DIR/state/plaintask.meta"
  [ -f "$meta" ] || fail "a home with no routed pool must dispatch exactly as before"$'\n'"--- output ---"$'\n'"$out"
  # An absent capacity field in a home with no routed pool means "nothing was
  # configured to check", which is a different fact from could-not-observe and
  # must not be written as one.
  assert_no_grep "capacity_observed=" "$meta" "a home with nothing to enforce must record no capacity verdict"
  assert_absent "$HOME_DIR/state/plaintask.capacity" "a home with nothing to enforce must record no wait"
  pass "a home with no routed pool is untouched: no capacity verdict, no wait, no change"
}

# --- 9. the resume is the same dispatch, or it does not happen ---------------

test_a_resumed_dispatch_carries_the_base_contract_it_was_deferred_with() {
  local out rec
  make_dispatch_home base-contract
  write_brief "$HOME_DIR" basetask no-mistakes
  # The base contract is part of WHICH dispatch this is, not decoration: a resume
  # that dropped it would resolve a different read base or contribution target
  # and become a different task wearing the same id.
  out=$(run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
    basetask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium \
    --contribution-target upstream/main)
  assert_contains "$out" "FM_SPAWN_CAPACITY_DEFERRED" "the work must be deferred before its record can be checked"
  rec="$HOME_DIR/state/basetask.capacity"
  assert_grep "contribution_target=upstream/main" "$rec" \
    "the deferral must carry the contribution target it was dispatched with"
  pass "a deferral carries the base contract of the dispatch it is holding"
}

test_a_deferral_whose_recorded_dispatch_no_longer_validates_is_not_resumed() {
  local out
  make_dispatch_home tampered
  write_brief "$HOME_DIR" tamperedtask no-mistakes
  run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=0)" \
    tamperedtask "$OK_REPO" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION --harness codex \
    --route R-SOLO --model vendor/large --effort medium >/dev/null
  # A record whose delivery mode is no longer one this fleet ships. Resuming it
  # would run the work under a posture nobody chose, so the resume stops instead.
  printf 'mode=whatever-mode\n' >> "$HOME_DIR/state/tamperedtask.capacity"
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" PATH="$OK_BIN:$PATH" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' \
    run_retry "$HOME_DIR" "$(quota_record vendorq=95)" tick --id tamperedtask --force); rc=$?
  expect_code 1 "$rc" "a deferral that cannot be turned back into its own dispatch must not resume"
  assert_contains "$out" "no longer validates" "the stop must say the recorded dispatch is what failed"
  assert_absent "$HOME_DIR/state/tamperedtask.meta" "a dispatch nobody can validate must not be launched"
  pass "a deferral whose recorded dispatch no longer validates is stopped rather than resumed on a guess"
}

# --- 10. no dispatch shape reaches a launch without consulting availability ---

# THE RECURRENCE PROBE. The gate lives at the one chokepoint, but "one
# chokepoint" is a claim about code shape, and code shape is what a later change
# alters. What survives such a change is the RECORD: every ship and scout
# dispatch in an enforcing home carries the capacity verdict it was admitted
# against. So this case drives the two remaining ways into that path - a scout
# rather than a ship, and a route derived from an explicit floor rather than
# named outright - and fails if either reaches a launch without one.
test_every_enforcing_dispatch_shape_records_its_capacity() {
  local out meta
  make_dispatch_home shapes
  write_brief "$HOME_DIR" scouttask
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record vendorq=89)" \
      scouttask "$OK_REPO" --scout --reason-code NL_RULE_CLASSIFICATION \
      --harness codex --route R-SOLO --model vendor/large --effort medium)
  meta="$HOME_DIR/state/scouttask.meta"
  [ -f "$meta" ] || fail "a scout dispatch must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "capacity_observed=available" "$meta" "a scout dispatch must record the capacity it was admitted against"

  # No --route at all: the claim is derived from a floor that names exactly one
  # route, which is the other supported way in and must be gated identically.
  write_brief "$HOME_DIR" floorderived no-mistakes
  out=$(FM_FAKE_PANE_PATH="$OK_WT" TMUX="fake,1,0" \
    run_spawn "$HOME_DIR" "$OK_BIN" "$(quota_record altq=77)" \
      floorderived "$OK_REPO" --mode no-mistakes --yolo off \
      --reason-code NL_RULE_CLASSIFICATION --harness codex \
      --capability-floor F-ONLY --model alt/large --effort medium)
  meta="$HOME_DIR/state/floorderived.meta"
  [ -f "$meta" ] || fail "a floor-derived route claim must reach task metadata"$'\n'"--- output ---"$'\n'"$out"
  assert_grep "route=R-ONLY" "$meta" "the floor must still derive the route it was checked against"
  assert_grep "capacity_observed=available" "$meta" "a floor-derived dispatch must record the capacity it was admitted against"
  pass "every enforcing dispatch shape records the capacity it was admitted against"
}

if [ "${FM_CAPACITY_ROUTING_HELPERS_ONLY:-0}" = 1 ]; then
  return 0
fi

test_exhausted_floor_pool_defers_rather_than_dispatching
test_available_capacity_dispatches_and_records_what_it_was_admitted_against
test_an_available_model_below_the_floor_is_not_a_substitute
test_a_floor_meeting_sibling_is_named_rather_than_deferred
test_a_registry_ineligible_sibling_does_not_prevent_deferral
test_unobservable_quota_is_could_not_observe_and_keeps_the_candidate_eligible
test_an_unreadable_quota_source_is_could_not_observe_rather_than_either_answer
test_a_deferral_survives_a_restart_and_resumes_when_capacity_returns
test_a_deferral_is_not_resumed_while_capacity_is_still_spent
test_a_stagnating_deferral_stops_rather_than_polling_forever
test_the_deferral_bound_is_arithmetic_over_one_record_and_spends_no_attempt
test_an_attempt_write_preserves_the_deferral_count
test_a_home_with_no_routed_pool_is_untouched
test_a_deferral_whose_recorded_dispatch_no_longer_validates_is_not_resumed
test_a_resumed_dispatch_carries_the_base_contract_it_was_deferred_with
test_every_enforcing_dispatch_shape_records_its_capacity
