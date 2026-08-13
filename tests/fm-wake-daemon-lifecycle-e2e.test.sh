#!/usr/bin/env bash
# tests/fm-wake-daemon-lifecycle-e2e.test.sh - the watcher + supervise-daemon
# lifecycle, end to end, over one shared state root and a shimmed tmux:
#
#   routine status -> self-handled, queued
#   terminal status written while the watcher is DOWN -> caught on restart (catch-up)
#   drain queued records -> exactly ONE captain-relevant digest is buffered
#   housekeeping catch-all scan -> NO duplicate digest
#   buffered digest flushes to the supervisor pane as exactly ONE submission
#   stale working-pane: transient (self + marker) -> persistent (escalates once,
#     clears its marker) -> resumed/busy (clears without escalating)
#
# This proves the operator-visible routing/queueing/dedupe behavior through real
# fm-watch.sh runs plus the daemon's own functions. The captain-relevant
# status-phrase matrix and the lock-primitive races stay as focused units
# (fm-daemon.test.sh, fm-watcher-lock.test.sh) - an e2e cannot deterministically
# cover a race, and the phrase list is a product contract worth a dedicated test.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

# Source the daemon's pure functions (its main loop is guarded out under sourcing).
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=/dev/null
  . "$DAEMON"
fi
# Housekeeping's wedge gate reads crew state, so every in-process call below must
# answer from this file's fake rather than from the real reader and whatever the
# fixture happens to have on disk. The guard makes forgetting that abort the run.
fm_guard_crew_state_reader

TMP_ROOT=$(fm_test_tmproot fm-wake-daemon-e2e)

# Run the daemon-managed watcher once: under the supervise-daemon (away mode) the
# watcher is one-shot - it exits with a single reason line on EVERY wake and the
# daemon does the triage. This e2e exercises exactly that path, so it runs with
# state/.afk present (which the daemon owns) to keep the watcher one-shot; the
# always-on standalone triage is covered by fm-watch-triage.test.sh. fakebin
# shadows tmux. Echoes nothing; the caller reads $out.
run_watcher_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  date '+%s' > "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

run_watcher_present_once() {
  local state=$1 fakebin=$2 out=$3
  mkdir -p "$state"
  rm -f "$state/.afk"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 50
}

# --- Phase 1: routine self-handled, queued; terminal caught after restart ---
test_routine_then_terminal_after_restart() {
  local dir state fakebin out drain_out status_file
  dir=$(make_supercase wd-lifecycle)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  status_file="$state/task-w1.status"

  # A routine status fires a signal; the watcher queues it and exits.
  printf 'working: building\n' > "$status_file"
  run_watcher_once "$state" "$fakebin" "$out" || fail "watcher did not exit for the routine signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not report the routine signal"

  # Drain it and route through the daemon: a routine status self-handles.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after routine signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "routine signal was not queued"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  [ ! -s "$state/.subsuper-escalations" ] || fail "routine status was escalated by the daemon"

  # The watcher is now DOWN (one-shot exit). A terminal status lands while it is
  # down; the next watcher run must catch it up (losslessness across restart).
  printf 'done: PR https://example.test/pr/900\n' >> "$status_file"
  : > "$out"
  run_watcher_once "$state" "$fakebin" "$out" || fail "restarted watcher did not exit for the terminal signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "terminal signal written while watcher down was not caught on restart"

  # Drain and route the terminal: exactly ONE digest is buffered.
  : > "$drain_out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after terminal signal failed"
  FM_STATE_OVERRIDE="$state" handle_wake "signal: $status_file" "$state"
  [ -s "$state/.subsuper-escalations" ] || fail "captain-relevant terminal status was not buffered"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "expected exactly one buffered digest after the terminal signal"

  # The catch-all heartbeat scan must NOT re-escalate the same status (no dup).
  FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    housekeeping "$state"
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" -eq 1 ] \
    || fail "catch-all scan duplicated the already-buffered digest"

  # With afk active, the buffered digest flushes to the supervisor pane as ONE
  # submission (one typed line + one Enter), then the buffer clears.
  local sent
  sent="$dir/sent.log"; : > "$sent"
  : > "$dir/pane.txt"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_PANE_ALIVE=1 FM_FAKE_TMUX_SENT="$sent" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_ESCALATE_BATCH_SECS=0 escalate_flush "$state" \
    || fail "escalate_flush failed for the buffered digest"
  [ "$(grep -c '\[ENTER\]' "$sent")" -eq 1 ] || fail "buffered digest was not submitted exactly once"
  [ ! -s "$state/.subsuper-escalations" ] || fail "buffer not cleared after a successful flush"
  pass "lifecycle: routine self-handles, terminal survives a watcher restart, buffers once, no dup, injects once"
}

# --- Phase 1b: typed PR-ready delivery transition ----------------------------
# The present-mode control proves the ordinary watcher surfaces the event for
# firstmate. The away-mode leg then replays the same typed event after a prior
# seen marker exists, exercises the canonical registration mutation, and lets a
# real watcher poll carry the result through to the merged wake and retirement.
test_typed_pr_ready_away_transition_reaches_merge_poll() {
  local dir state home fakebin status_file url out
  dir=$(make_supercase wd-pr-ready)
  state="$dir/state"
  home="$dir/home"
  fakebin="$dir/fakebin"
  status_file="$state/task-pr-e2e.status"
  url=https://github.com/o/r/pull/901
  mkdir -p "$home/config" "$home/data" "$dir/wt"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --json headRefOid '*) printf '0123456789abcdef0123456789abcdef01234567\n' ;;
  *' --json state,headRefOid '*) printf '%s\t0123456789abcdef0123456789abcdef01234567\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
  *' state,mergeable,headRefOid '*) printf '%s\tMERGEABLE\t0123456789abcdef0123456789abcdef01234567\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  fm_write_meta "$state/task-pr-e2e.meta" \
    "window=firstmate:fm-task-pr-e2e" \
    "endpoint_task_id=task-pr-e2e" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "fm-status-event.v1 verb=done phase=ready evidence=$url summary=checks green" > "$status_file"

  run_watcher_present_once "$state" "$fakebin" "$dir/present.out" \
    || fail "present-mode watcher did not surface the typed PR-ready event"
  grep -F "signal: $status_file" "$dir/present.out" >/dev/null \
    || fail "present-mode watcher did not report the typed PR-ready event"
  [ ! -e "$state/task-pr-e2e.check.sh" ] \
    || fail "present-mode watcher registered a PR without firstmate's handoff"

  # Simulate firstmate seeing the present-mode wake, then preserve its seen
  # marker while the away daemon takes ownership of the next signal.
  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" bash -c \
    '. "$1"; LOG="$4"; FM_ESCALATE_BATCH_SECS=999999 handle_wake "signal: $2" "$3"' \
    _ "$DAEMON" "$status_file" "$state" "$dir/daemon.log" >/dev/null 2>&1; then
    :
  fi
  [ -s "$state/.subsuper-escalations" ] \
    || fail "present-mode handoff did not produce an actionable digest"
  rm -f "$state/.subsuper-escalations"

  printf '%s\n' "fm-status-event.v1 verb=done phase=ready evidence=$url summary=checks green" >> "$status_file"
  run_watcher_once "$state" "$fakebin" "$dir/away.out" \
    || fail "away-mode watcher did not surface the replayed typed PR-ready event"
  grep -F "signal: $status_file" "$dir/away.out" >/dev/null \
    || fail "away-mode watcher did not report the replayed typed PR-ready event"

  if FM_HOME="$home" FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" bash -c \
    '. "$1"; LOG="$4"; FM_ESCALATE_BATCH_SECS=999999 handle_wake "signal: $2" "$3"' \
    _ "$DAEMON" "$status_file" "$state" "$dir/daemon.log" >/dev/null 2>&1; then
    :
  fi
  grep -qxF "pr=$url" "$state/task-pr-e2e.meta" \
    || fail "away-mode replay did not record the canonical PR"
  fm_pr_poll_artifacts_valid "$state" task-pr-e2e "$ROOT/bin/fm-pr-poll.sh" \
    || fail "away-mode replay did not publish an authenticated merge poll"

  rm -f "$state/.last-check"
  export FM_TEST_GH_STATE=MERGED
  run_watcher_once "$state" "$fakebin" "$dir/merged.out" \
    || fail "merge poll did not complete in away mode"
  unset FM_TEST_GH_STATE
  case "$(cat "$dir/merged.out")" in
    check:*task-pr-e2e.check.sh:*merged*) ;;
    *) fail "away-mode merge poll did not publish a terminal notification: $(cat "$dir/merged.out")" ;;
  esac
  [ ! -e "$state/task-pr-e2e.check.sh" ] \
    || fail "merged away-mode poll was not retired"
  grep -F $'\tcheck\t' "$state/.wake-queue" | grep -F 'task-pr-e2e.check.sh: merged' >/dev/null \
    || fail "merged away-mode poll did not leave its durable notification"
  pass "lifecycle: present mode surfaces typed PR-ready work, away mode registers it before dedupe, and the merged poll notifies and retires"
}

# --- Phase 2: stale working-pane transient -> persistent -> resumed ----------
test_stale_pane_transient_persistent_resume() {
  local dir state fakebin win key resumed_gen
  dir=$(make_supercase wd-stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  win="sess:fm-stale-w2"
  key=$(printf '%s' "stale-w2" | tr ':/.' '___')
  printf 'working: compiling\n' > "$state/stale-w2.status"

  # Transient: first stale observation self-handles and records a marker.
  stale_marker_record "$win" "$state"
  # classify_stale reaches crew_absorb_class for the settled-terminal absorb, so
  # the reader is stubbed here too: this case is about the transient self-handle,
  # and its verdict must come from the test rather than from the fixture on disk.
  case "$(FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    classify_stale "$win" "$state")" in
    self\|*) : ;;
    *) fail "transient stale did not self-handle" ;;
  esac
  [ -e "$state/.subsuper-stale-$key" ] || fail "transient stale did not record a persistence marker"

  # Persistent: the marker ages past the threshold and the pane is still idle, so
  # housekeeping escalates exactly once and clears the marker. That path runs
  # through the provably-working gate, so the verdict is stubbed to a non-working
  # one here: the escalation must follow the verdict this test names, not whatever
  # the real reader would make of the fixture at this phase.
  printf 'idle prompt $\n' > "$dir/pane.txt"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  : > "$state/.subsuper-escalations" 2>/dev/null || true
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · agent exited' \
    housekeeping "$state" 2>"$dir/housekeeping.err"
  [ ! -s "$dir/housekeeping.err" ] \
    || fail "missing task metadata leaked a raw read error: $(cat "$dir/housekeeping.err")"
  [ -s "$state/.subsuper-escalations" ] || fail "persistent stale did not escalate"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "stale marker not cleared after escalation"

  # Resumed: a fresh transient marker but the crew is provably working again ->
  # housekeeping clears the marker without escalating. The proof is the crew's
  # own semantic busy-state record (bin/fm-busy-lib.sh), not rendered pane text.
  stale_marker_record "$win" "$state"
  echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
  printf 'Working...\n' > "$dir/pane.txt"
  fm_write_meta "$state/stale-w2.meta" "window=$win" "worktree=$dir/wt" "kind=ship" "harness=pi"
  resumed_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" stale-w2)
  "$ROOT/bin/fm-busy-event.sh" apply "$state" stale-w2 busy --gen "$resumed_gen" \
    --source pi-ext --event agent-start
  : > "$state/.subsuper-escalations"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=240 \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · agent exited' \
    housekeeping "$state"
  [ ! -e "$state/.subsuper-stale-$key" ] || fail "resumed stale marker was not cleared"
  [ ! -s "$state/.subsuper-escalations" ] || fail "resumed (busy) stale was escalated"
  pass "lifecycle: stale pane transient self-handles, persistent escalates once and clears, resumed clears quietly"
}

test_routine_then_terminal_after_restart
test_typed_pr_ready_away_transition_reaches_merge_poll
test_stale_pane_transient_persistent_resume
