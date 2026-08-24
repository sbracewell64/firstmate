#!/usr/bin/env bash
# tests/fm-classify.test.sh - the shared triage policy in bin/fm-classify-lib.sh,
# colocated with the library that owns it.
#
# Two properties live here because both were re-created by a fix for the other,
# and each is a whole-alarm property rather than a watcher or daemon detail:
#
#   1. A LIVE SHELL IS NOT A LIVE AGENT. A busy turn record is trusted for up to
#      FM_BUSY_MAX_BUSY_AGE_SECS (default 3600s) from a timestamp stamped when
#      the turn OPENED, so a worker killed mid-turn behind a surviving shell
#      keeps reading busy for up to an hour. Absorbing a wedge on that record
#      alone answers could-not-observe with silence, on exactly the lane the
#      alarm exists for, so the record must be corroborated by a reading that
#      RE-DERIVES per call.
#   2. The absorb-class vocabulary has one owner, and a consumer applying a
#      policy to "nothing absorbed this wake" must ask that owner rather than
#      naming a class. Naming `none` is how the fifth class, `unobserved`,
#      silently opted out of the watcher's dead-agent pause recovery and started
#      spending an extra wake per distinct pane hash on every declared-pause and
#      captain-held lane.
#
# The reader half of (1) - that bin/fm-crew-state.sh actually measures and
# reports agent liveness beside the turn signal - is owned by
# tests/fm-crew-state.test.sh. This file owns what the pair MEANS, and drives the
# real bin/fm-backend.sh probe so the value it feeds the policy is the value the
# reader would have recorded rather than one this test invented.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-classify-tests)

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if
# it died. A watcher that absorbed the wake is one that is still running.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# Signature a primed .seen-* marker must hold so the per-poll signal scan does
# not fire on a pre-existing status line (mirrors fm-watch.sh's stat_sig). The
# lane under test is a STALE-path classification, so its status line must already
# be seen or an unrelated signal wake would decide the run.
seen_sig() {
  if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
}

# The measured lane, one layer above where it was measured: a run left `failed`
# by an earlier session-limit kill, a busy turn record still inside its trust
# window, and a pane holding nothing but the shell the agent left behind.
test_dead_agent_behind_live_shell_escalates() {
  local dir state fakebin window probe verdict
  dir=$(make_case dead-agent-live-shell); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:fm-deadagent"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_STATE_OVERRIDE="$state"
  export FM_FAKE_CREW_STATE FM_FAKE_CREW_BUSY FM_FAKE_CREW_AGENT
  printf 'working: driving the gate\n' > "$state/a.status"

  # What the REAL probe says about each pane, so the policy below is fed the
  # reader's own vocabulary rather than a value this test chose. The probe is
  # backend-native and target-bound; nothing here searches process names across
  # the machine, which has twice matched the wrong process in this fleet.
  probe=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CURRENT_COMMAND=claude fm_backend_agent_state tmux "$window")
  [ "$probe" = alive ] || fail "the backend probe did not report a harness pane alive, got '$probe'"
  probe=$(PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh fm_backend_agent_state tmux "$window")
  [ "$probe" = dead ] || fail "the backend probe did not report a shell-only pane agent-free, got '$probe'"

  for verdict in failed aborted interrupted; do
    FM_FAKE_CREW_STATE="state: $verdict · source: run-step · killed mid-step by a session-limit wall"
    # The record is identical in every leg below. Only who is still there to be
    # taking that turn changes, which is the entire point.
    FM_FAKE_CREW_BUSY='busy claude-hook'

    # Control: the agent is established alive, so the busy record is corroborated
    # and the lane the alarm kept firing on is absorbed.
    FM_FAKE_CREW_AGENT=alive
    [ "$(crew_absorb_class a)" = working ] \
      || fail "a corroborated live turn after a $verdict run was not classed working"

    # The lane this case exists for: same busy record, agent established gone.
    # This is an OBSERVATION that the crew is not working, so it escalates on the
    # unchanged schedule rather than waiting out the record's trust window.
    for FM_FAKE_CREW_AGENT in dead missing; do
      [ "$(crew_absorb_class a)" = none ] \
        || fail "a busy record behind a '$FM_FAKE_CREW_AGENT' agent after a $verdict run was absorbed"
      ! crew_is_provably_working a \
        || fail "a busy record behind a '$FM_FAKE_CREW_AGENT' agent was called provably working"
    done

    # And the third value, which is where an hour-long trust window actually
    # belongs: liveness that could not be established is cannot-tell, never
    # working. It escalates and says so.
    for FM_FAKE_CREW_AGENT in ambiguous unreadable unverified ''; do
      [ "$(crew_absorb_class a)" = unobserved ] \
        || fail "an uncorroborated busy record ('${FM_FAKE_CREW_AGENT:-unmeasured}') after a $verdict run did not report itself unobserved"
      ! crew_is_provably_working a \
        || fail "an uncorroborated busy record ('${FM_FAKE_CREW_AGENT:-unmeasured}') was called provably working"
    done
  done

  # A verdict that DID observe the crew is untouched by either reading: this
  # corroboration widens no absorb, it only bounds one.
  FM_FAKE_CREW_BUSY='busy claude-hook'
  FM_FAKE_CREW_AGENT=alive
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  [ "$(crew_absorb_class a)" = none ] || fail "agent liveness talked a gate-parked run into absorbing"
  FM_FAKE_CREW_AGENT=dead
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "a dead agent overrode an actively-running run step"

  unset FM_FAKE_CREW_STATE FM_FAKE_CREW_BUSY FM_FAKE_CREW_AGENT FM_CREW_STATE_BIN FM_STATE_OVERRIDE
  pass "a dead agent behind a live shell escalates rather than being absorbed"
}

# The consumer side of the one-owner rule, end to end through the real watcher.
# The lane: a captain-held task whose run ended, whose agent is confidently dead,
# and whose turn evidence was never written - so crew_absorb_class reports
# `unobserved`. That must enter the bounded pause cadence exactly as `none` does,
# because the recovery is about a dead agent under a declared hold, not about
# which non-absorbing token the crew read produced.
test_unobserved_is_subject_to_dead_agent_pause_recovery() {
  local dir state fakebin window key capture statusf pid stale_wakes

  # The membership this rests on, asked of its owner: every class that must
  # surface is covered, and no class that absorbs is.
  for key in none unobserved; do
    crew_absorb_class_surfaces "$key" || fail "crew_absorb_class_surfaces did not cover the surfacing class '$key'"
  done
  for key in working paused settled; do
    ! crew_absorb_class_surfaces "$key" \
      || fail "crew_absorb_class_surfaces reported the absorbing class '$key' as surfacing"
  done

  dir=$(make_case unobserved-pause-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  window="test:fm-classifyheld"
  capture="$dir/pane.txt"; statusf="$state/classifyheld.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'idle bare shell after the agent exited\n' > "$capture"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/classifyheld.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  printf '%s' "$(seen_sig "$statusf")" > "$state/.seen-classifyheld_status"
  # Already stably stale on this hash, so the first poll reaches stale triage.
  printf '%s' "$(hash_text "idle bare shell after the agent exited")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # The crew read: a run that ended, and no turn signal measured for it at all.
  export FM_FAKE_CREW_STATE='state: failed · source: run-step · killed mid-step by a session-limit wall'
  export FM_STATE_OVERRIDE="$state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  [ "$(crew_absorb_class classifyheld "$state")" = unobserved ] \
    || fail "the fixture does not produce an unobserved class, so it proves nothing about it"

  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$dir/watch.out" &
  pid=$!
  fm_test_reap "$pid"
  if ! wait_live "$pid" 40; then
    fail "an unobserved crew under a captain hold with a dead agent surfaced instead of entering the pause cadence: $(cat "$dir/watch.out")"
  fi
  [ ! -s "$dir/watch.out" ] \
    || fail "the unobserved captain-held lane printed a wake reason: $(cat "$dir/watch.out")"
  [ -e "$state/.paused-$key" ] \
    || { reap "$pid"; fail "the unobserved captain-held lane did not record the bounded pause cadence marker"; }
  reap "$pid"
  stale_wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null || printf 0)
  [ "$stale_wakes" -eq 0 ] \
    || fail "the unobserved captain-held lane queued $stale_wakes stale wakes instead of absorbing on the pause cadence"

  unset FM_FAKE_CREW_STATE FM_CREW_STATE_BIN FM_STATE_OVERRIDE
  pass "the unobserved class is subject to dead-agent pause recovery"
}

# The other half of the one-owner rule: which semantic classes may be answered by
# a process-liveness reading is a single list, asked by both the watcher's stale
# DETECTION gate and crew_absorb_class. Restating it in either place is how the
# two modes would come to absorb the same crew at different layers.
test_liveness_open_membership_has_one_owner() {
  local class
  for class in $FM_CLASSIFY_LIVENESS_OPEN_CLASSES; do
    crew_semantic_class_leaves_liveness_open "$class" \
      || fail "the declared liveness-open class '$class' was not recognized by its own predicate"
  done
  for class in working paused definite '' not-a-class; do
    ! crew_semantic_class_leaves_liveness_open "$class" \
      || fail "'${class:-empty}' was treated as leaving the crew's own liveness open"
  done
  pass "one owner decides which semantic classes a liveness reading may answer for"
}

# Agent liveness is reduced to three answers, and an unknown reading defaults to
# the one that ESCALATES. A backend that grows a new state must never be able to
# widen an absorb by accident.
test_agent_liveness_verdict_is_fail_safe() {
  local word
  [ "$(crew_agent_liveness_verdict alive)" = alive ] || fail "a verified agent was not reported alive"
  for word in dead missing; do
    [ "$(crew_agent_liveness_verdict "$word")" = gone ] \
      || fail "'$word' was not reported as an established absence"
  done
  for word in ambiguous unreadable unverified unmeasured '' a-state-nobody-taught; do
    [ "$(crew_agent_liveness_verdict "$word")" = unestablished ] \
      || fail "'${word:-empty}' was narrowed to a verdict this reading cannot support"
  done
  pass "agent liveness keeps three values and defaults an untaught state to escalate"
}

# --- the decision disposition vocabulary -------------------------------------
#
# THE PROPERTY: the vocabulary is CLOSED, TOTAL and NON-VACUOUS. Every member is
# reachable from a real fixture, every input reaches exactly one member, and an
# input whose disposition cannot be established reaches CNO_DECISION_SUBJECT -
# a value in the set rather than an empty field. A declared vocabulary whose
# members no input can reach is a list that reads as a contract and enforces
# nothing, which is the failure class this fleet keeps hitting.
disposition_home() {  # <name> -> prints home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

record_disposition() {  # <home> <task> <key> <value>
  mkdir -p "$1/data/$2"
  # shellcheck disable=SC2016  # the backticks are the literal fence the fold reads, not a substitution
  printf '# decision\n\n```disposition\n%s\n```\n' "$4" > "$1/data/$2/decision-$3.md"
}

test_disposition_vocabulary_is_total_and_non_vacuous() {
  local home member got reached=0 checked=0 recordable=0 derived=0

  home=$(disposition_home dispo)

  # Every member reachable. Four are recorded-only by design (no structured fleet
  # fact establishes them and prose is not evidence), so they are driven through
  # the record; the rest are driven through the derivation as well, below.
  #
  # The DERIVED-ONLY members are driven the other way, and the direction is the
  # point: recorded, one of them would let a decision file declare that nobody
  # owes a live captain decision, and the consumers that skip those entries would
  # skip a real decision. So a record naming one must come back could-not-observe,
  # exactly as an unknown value does, and the member itself is reached through the
  # fold instead - tests/fm-commitment-register.test.sh's
  # freshness_expiry_is_not_a_reopen, which owns the fixtures that reach it.
  for member in $FM_DECISION_DISPOSITION_VOCABULARY; do
    record_disposition "$home" "rec$reached" k "$member"
    got=$(decision_disposition "rec$reached" k needs-decision "$home")
    if decision_disposition_is_derived_only "$member"; then
      [ "$got" = CNO_DECISION_SUBJECT ] \
        || fail "recorded disposition $member came back as $got; a derived-only member may never be declared by a record"
      derived=$((derived + 1))
    else
      [ "$got" = "$member" ] \
        || fail "recorded disposition $member came back as $got, so that member is unreachable"
      recordable=$((recordable + 1))
    fi
    reached=$((reached + 1))
  done
  [ "$reached" -eq 9 ] \
    || fail "the vocabulary has $reached members; every one must be driven, not counted"
  [ "$recordable" -eq 8 ] \
    || fail "$recordable members round-tripped through a record; the recorded path must stay non-vacuous"
  [ "$derived" -eq 1 ] \
    || fail "$derived members were refused as records; a refusal that refuses nothing proves nothing"

  # Derived, with no record at all. Absent metadata is the subject itself being
  # unobservable, which is could-not-observe rather than a captain decision.
  got=$(decision_disposition nometa k needs-decision "$home")
  [ "$got" = CNO_DECISION_SUBJECT ] \
    || fail "a decision whose task metadata is absent must be CNO_DECISION_SUBJECT, got $got"
  checked=$((checked + 1))

  # The postures below are spelled from bin/fm-autonomy-lib.sh, the owner both
  # this fold and bin/fm-spawn.sh consult, so these fixtures cannot drift into a
  # vocabulary the fleet does not write. They did once: this test used to write
  # `yolo=1` and `yolo=0`, values no producer emits, and stayed green for the
  # entire time the SELF_HANDLE branch was unreachable in production.
  # tests/fm-task-delivery.test.sh pins the two ends against the REAL producer;
  # this file pins what the fold does with each.
  printf 'worktree=%s\nyolo=%s\n' "$home" "$FM_AUTONOMY_STATE_CAPTAIN" > "$home/state/plain.meta"
  got=$(decision_disposition plain k needs-decision "$home")
  [ "$got" = CAPTAIN_REQUIRED_NONBLOCKING ] \
    || fail "an open needs-decision on a live task must be CAPTAIN_REQUIRED_NONBLOCKING, got $got"
  checked=$((checked + 1))
  got=$(decision_disposition plain k blocked "$home")
  [ "$got" = CAPTAIN_REQUIRED_AND_BLOCKING ] \
    || fail "a blocked decision on a live task must be CAPTAIN_REQUIRED_AND_BLOCKING, got $got"
  checked=$((checked + 1))

  printf 'worktree=%s\nyolo=%s\n' "$home" "$FM_AUTONOMY_STATE_SELF" > "$home/state/auto.meta"
  got=$(decision_disposition auto k needs-decision "$home")
  [ "$got" = SELF_HANDLE ] \
    || fail "standing routine authority makes the decision firstmate's own, got $got"
  checked=$((checked + 1))
  got=$(decision_disposition auto k blocked "$home")
  [ "$got" = SELF_HANDLE ] \
    || fail "standing routine authority is the task's, not the verb's, got $got"
  checked=$((checked + 1))

  # An ABSENT posture is a live producer state and a DIFFERENT fact from an
  # unreadable one: a scout records none by design, so nothing granted standing
  # authority and the captain holds the decision. Narrowing this into
  # could-not-observe would hide a decision the captain really does owe.
  printf 'worktree=%s\n' "$home" > "$home/state/noposture.meta"
  got=$(decision_disposition noposture k blocked "$home")
  [ "$got" = CAPTAIN_REQUIRED_AND_BLOCKING ] \
    || fail "a task recording no posture at all must stay the captain's, got $got"
  checked=$((checked + 1))

  # A verb the fold could not classify is could-not-observe, never narrowed into
  # either captain-required answer.
  got=$(decision_disposition plain k a-verb-nobody-taught "$home")
  [ "$got" = CNO_DECISION_SUBJECT ] \
    || fail "an untaught verb was narrowed to $got rather than could-not-observe"
  checked=$((checked + 1))

  # A recorded value that is NOT a vocabulary member is could-not-observe, not a
  # silent fall-through to the derivation: answering around an operator's own
  # unreadable record would hide that the record is broken.
  record_disposition "$home" plain garbage NOT_A_MEMBER
  got=$(decision_disposition plain garbage needs-decision "$home")
  [ "$got" = CNO_DECISION_SUBJECT ] \
    || fail "an unreadable recorded disposition must be could-not-observe, got $got"
  checked=$((checked + 1))

  # A decision record that EXISTS and cannot be read may carry a disposition
  # nobody here can see, so it is could-not-observe rather than an answer derived
  # around it. Skipped when the tests run as a user no permission bit constrains.
  record_disposition "$home" plain unreadable BROWSER_SOL
  chmod 000 "$home/data/plain/decision-unreadable.md"
  if [ ! -r "$home/data/plain/decision-unreadable.md" ]; then
    got=$(decision_disposition plain unreadable needs-decision "$home")
    [ "$got" = CNO_DECISION_SUBJECT ] \
      || fail "an unreadable decision record must be could-not-observe, got $got"
  fi
  chmod 644 "$home/data/plain/decision-unreadable.md"

  # Totality: every answer this function can give is a member.
  [ "$checked" -eq 8 ] || fail "expected 8 derivation cases, drove $checked"
  for got in \
    "$(decision_disposition '' k needs-decision "$home")" \
    "$(decision_disposition plain '' needs-decision "$home")" \
    "$(decision_disposition 'not a slug' k needs-decision "$home")" \
    "$(decision_disposition plain k needs-decision '')"; do
    decision_disposition_is_known "$got" \
      || fail "a malformed input produced '$got', which is outside the closed vocabulary"
  done
  pass "the decision disposition vocabulary is closed, total, and every member is reachable"
}

# --- the autonomy-state fold, and the control that was manufactured ----------
#
# THE REGRESSION. bin/fm-spawn.sh writes `yolo=on`; this fold used to test
# `yolo= 1`. SELF_HANDLE was reachable only from a hand-edited record, so every
# routine decision on a task carrying standing routine authority was rendered as
# owed by the captain - 48 of the fleet's 49 open decisions when it was found.
#
# The row set below is the executed negative control from that investigation,
# kept verbatim as the regression case. Its finding was that of {on, off, 1,
# true, yes} ONLY `1` reached SELF_HANDLE. The expectations here are what each
# must produce now: the producer's own two values partition into the two real
# answers, and each of the three spellings the producer never writes REFUSES to
# CNO_DECISION_SUBJECT rather than being narrowed into either.
#
# The refusal direction is the point. Silently reading an uninterpretable
# posture as "the captain's" would restate this defect with the failure hidden:
# the queue would look right and the record would still be unreadable.
test_autonomy_postures_partition_and_unknown_ones_refuse() {
  local home value expect got n=0
  home=$(disposition_home autonomy-fold)

  while IFS='|' read -r value expect; do
    [ -n "$value" ] || continue
    n=$((n + 1))
    printf 'worktree=%s\nyolo=%s\n' "$home" "$value" > "$home/state/ctl$n.meta"
    got=$(decision_disposition "ctl$n" k blocked "$home")
    [ "$got" = "$expect" ] \
      || fail "a task recorded yolo=$value resolved to $got, expected $expect"
  done <<'ROWS'
on|SELF_HANDLE
off|CAPTAIN_REQUIRED_AND_BLOCKING
1|CNO_DECISION_SUBJECT
true|CNO_DECISION_SUBJECT
yes|CNO_DECISION_SUBJECT
ROWS
  [ "$n" -eq 5 ] || fail "the preserved negative control has 5 rows; drove $n"

  # A truncated write leaves `yolo=` with no value. That is a BROKEN record, not
  # an absent field, so it refuses rather than inheriting the scout's answer.
  printf 'worktree=%s\nyolo=\n' "$home" > "$home/state/truncated.meta"
  got=$(decision_disposition truncated k blocked "$home")
  [ "$got" = CNO_DECISION_SUBJECT ] \
    || fail "a posture line with no value resolved to $got rather than could-not-observe"

  pass "the autonomy postures the producer writes partition, and every other spelling refuses"
}

# --- the recorded-only branches, driven through their real writer -------------
#
# BROWSER_SOL and EXTERNAL_DEPENDENCY are recorded, never derived: no structured
# fleet fact establishes them and the only other source is the note's prose,
# which is the wrong-subject failure .agents/skills/wrong-subject names. So the
# reachability question for them is about their WRITER, and the audit that found
# the `yolo=` defect asked whether they carry the same one. They do not, and
# this pins why: bin/fm-decision-hold.sh and this fold both consult
# decision_disposition_is_known, so writer and reader cannot spell the set
# differently - the same one-owner shape the autonomy posture now has.
#
# These two branches had no production instance when this was written, and that
# is a USE gap rather than a reachability defect. The difference is exactly what
# this test keeps visible: a branch nothing has reached YET still has a working
# source, and a branch nothing CAN reach does not.
test_recorded_only_dispositions_round_trip_through_their_writer() {
  local home hold got member n=0
  home=$(disposition_home recorded-only)
  hold="$ROOT/bin/fm-decision-hold.sh"
  [ -x "$hold" ] || fail "bin/fm-decision-hold.sh is not executable, so this control cannot run"

  mkdir -p "$home/data/soltask" "$home/state"
  printf 'worktree=%s\nyolo=%s\n' "$home" "$FM_AUTONOMY_STATE_SELF" > "$home/state/soltask.meta"
  printf '# decision\n\nprose that reassigns this decision, which is never evidence\n' \
    > "$home/data/soltask/decision-solkey.md"

  # Each is written by the real writer and read back by the real fold. The task
  # carries standing routine authority on purpose: a recorded disposition must
  # win over the derivation, or recording one would be a no-op on exactly the
  # tasks whose decisions get reassigned.
  for member in BROWSER_SOL EXTERNAL_DEPENDENCY; do
    n=$((n + 1))
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$hold" disposition soltask solkey "$member" >/dev/null 2>&1 \
      || fail "the writer refused $member, so that branch has no live source"
    got=$(decision_disposition soltask solkey blocked "$home")
    [ "$got" = "$member" ] \
      || fail "$member was written but the fold read back $got"
  done
  [ "$n" -eq 2 ] || fail "expected 2 recorded-only branches driven, drove $n"

  # The writer refuses a value outside the vocabulary rather than storing a
  # record the fold would later have to call could-not-observe.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$hold" disposition soltask solkey NOT_A_MEMBER >/dev/null 2>&1 \
    && fail "the writer accepted a value outside the closed vocabulary"
  got=$(decision_disposition soltask solkey blocked "$home")
  [ "$got" = EXTERNAL_DEPENDENCY ] \
    || fail "a refused write disturbed the record already there, now $got"

  # Cleared, the fold returns to deriving - and derives SELF_HANDLE, because
  # this task does carry standing routine authority.
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    "$hold" disposition soltask solkey --clear >/dev/null 2>&1 \
    || fail "the writer could not clear a recorded disposition"
  got=$(decision_disposition soltask solkey blocked "$home")
  [ "$got" = SELF_HANDLE ] \
    || fail "a cleared record did not fall back to the derivation, got $got"
  pass "the recorded-only dispositions round-trip through their real writer and clear back to the derivation"
}

test_unreadable_status_is_in_band_universe_cno() {
  local home got
  home=$(disposition_home unreadable-status)
  printf 'needs-decision [key=hidden]: must not disappear\n' > "$home/state/real.status"
  ln -s real.status "$home/state/linked.status"
  got=$(status_open_decisions "$home/state/linked.status")
  case "$got" in
    CNO_DECISION_UNIVERSE$'\t'CNO_DECISION_UNIVERSE$'\t'CNO_DECISION_SUBJECT$'\t'*) ;;
    *) fail "a status log that cannot be read safely disappeared instead of reporting CNO_DECISION_UNIVERSE: $got" ;;
  esac
  pass "an unobservable status log reports decision-universe CNO in band"
}

test_dead_agent_behind_live_shell_escalates
test_unobserved_is_subject_to_dead_agent_pause_recovery
test_liveness_open_membership_has_one_owner
test_agent_liveness_verdict_is_fail_safe
test_disposition_vocabulary_is_total_and_non_vacuous
test_autonomy_postures_partition_and_unknown_ones_refuse
test_recorded_only_dispositions_round_trip_through_their_writer
test_unreadable_status_is_in_band_universe_cno

echo "all fm-classify tests passed"
