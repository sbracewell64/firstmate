#!/usr/bin/env bash
# Deterministic controls for the SSSF planning-transition consumer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-sssf-planning-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-sssf-planning-awareness)
REPO='sbracewell64/inkwell-agent-sandboxes-and-software-factory'
REF='planning/future-sssf'
SNAPSHOT_SOURCE='1111111111111111111111111111111111111111'
AWARE_SOURCE='2222222222222222222222222222222222222222'
ACTIVE_SOURCE='3333333333333333333333333333333333333333'
FEED_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'

snapshot_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0001","kind":"snapshot","source_commit":"1111111111111111111111111111111111111111","states":{"FUT-001":"SEQUENCED","FUT-002":"PRESERVE","FUT-003":"ACTIVE"},"authoritative_refs":["docs/development/FUTURE_CANDIDATES.md","docs/development/ROADMAP.md"],"actionability":"baseline"}'
}

awareness_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-004","from":"EXPLORE","to":"PRESERVE","source_commit":"2222222222222222222222222222222222222222","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"actionability":"awareness"}'
}

active_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-001","from":"SEQUENCED","to":"ACTIVE","source_commit":"3333333333333333333333333333333333333333","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md","docs/increments/FP-009_EXAMPLE.md"],"actionability":"engineering","increment_id":"FP-009"}'
}

make_home() {
  local name=$1 home state fakebin
  home="$TMP_ROOT/$name"
  state="$home/state"
  fakebin="$home/fakebin"
  mkdir -p "$state" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *" repos/"*) ;;
esac
# Resolve configured source ref to the immutable feed commit.
case "$args" in
  *"commits/$FM_TEST_SOURCE_REF"*"--jq .sha"*)
    printf '%s\n' "$FM_TEST_FEED_COMMIT"
    exit 0
    ;;
esac
# Verify an exact source commit. Tests can make one source unobservable.
case "$args" in
  *"commits/"*"--jq .sha"*)
    target=${args#*commits/}
    target=${target%% *}
    if [ -n "${FM_TEST_FAIL_SOURCE_COMMIT:-}" ] && [ "$target" = "$FM_TEST_FAIL_SOURCE_COMMIT" ]; then
      exit 1
    fi
    printf '%s\n' "$target"
    exit 0
    ;;
esac
# Raw feed read: no --jq field request.
case "$args" in
  *"contents/$FM_TEST_SOURCE_PATH"*"Accept: application/vnd.github.raw+json"*)
    cat "$FM_TEST_FEED_FILE"
    exit 0
    ;;
esac
# Exact authoritative-ref observation.
case "$args" in
  *"contents/"*"--jq .type"*)
    if [ "${FM_TEST_FAIL_REF:-0}" = 1 ]; then exit 1; fi
    printf 'file\n'
    exit 0
    ;;
esac
printf 'unexpected fake gh invocation: %s\n' "$args" >&2
exit 2
SH
  chmod +x "$fakebin/gh"
  printf 'schema=fm-sssf-planning-source.v1\nrepository=%s\nref=%s\npath=%s\n' \
    "$REPO" "$REF" 'docs/development/PLANNING_EVENTS.jsonl' > "$state/sssf-planning.source"
  chmod 0600 "$state/sssf-planning.source"
  printf '%s\n' "$home"
}

run_check() { # <home> [extra env assignments...]
  local home=$1
  shift
  FM_STATE_OVERRIDE="$home/state" \
  FM_TEST_SOURCE_REF="$REF" \
  FM_TEST_SOURCE_PATH='docs/development/PLANNING_EVENTS.jsonl' \
  FM_TEST_FEED_COMMIT="$FEED_COMMIT" \
  FM_TEST_FEED_FILE="$home/feed.jsonl" \
  PATH="$home/fakebin:$PATH" \
  "$@" "$CHECK" check
}

write_snapshot() { snapshot_line > "$1/feed.jsonl"; printf '\n' >> "$1/feed.jsonl"; }
append_awareness() { awareness_line >> "$1/feed.jsonl"; printf '\n' >> "$1/feed.jsonl"; }
append_active() { active_line >> "$1/feed.jsonl"; printf '\n' >> "$1/feed.jsonl"; }

cursor_event() {
  python3 - "$1/state/sssf-planning.cursor.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8'))['last_event_id'])
PY
}

pending_exists() { [ -e "$1/state/sssf-planning.pending.json" ]; }


test_bootstrap_is_silent_and_non_actionable() {
  local home out
  home=$(make_home bootstrap)
  write_snapshot "$home"
  out=$(run_check "$home") || fail "bootstrap check failed"
  [ -z "$out" ] || fail "bootstrap snapshot surfaced as actionable: $out"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "bootstrap cursor did not advance to snapshot"
  pending_exists "$home" && fail "bootstrap snapshot created pending work"
  pass "bootstrap snapshot establishes the cursor silently and cannot create work"
}


test_awareness_event_replays_until_ack_then_advances() {
  local home out shown acked
  home=$(make_home awareness)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "awareness bootstrap failed"
  append_awareness "$home"
  out=$(run_check "$home") || fail "awareness check failed"
  assert_contains "$out" "SSSF_PLANNING_EVENT pending plan-20260818-0002 awareness FUT-004 PRESERVE" "awareness event did not surface typed"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "cursor advanced before awareness acknowledgement"
  pending_exists "$home" || fail "awareness event was not captured durably"
  out=$(run_check "$home") || fail "pending awareness replay failed"
  assert_contains "$out" "plan-20260818-0002 awareness" "pending awareness was not re-announced"
  shown=$(FM_STATE_OVERRIDE="$home/state" "$CHECK" show plan-20260818-0002) || fail "show failed"
  assert_contains "$shown" '"actionability":"awareness"' "show did not return the pending event"
  acked=$(FM_STATE_OVERRIDE="$home/state" "$CHECK" ack plan-20260818-0002 awareness) || fail "awareness acknowledgement failed"
  assert_contains "$acked" "acknowledged: plan-20260818-0002 as awareness" "awareness acknowledgement text missing"
  [ "$(cursor_event "$home")" = plan-20260818-0002 ] || fail "cursor did not advance after acknowledgement"
  pending_exists "$home" && fail "pending awareness survived acknowledgement"
  out=$(run_check "$home") || fail "post-ack awareness check failed"
  [ -z "$out" ] || fail "acknowledged awareness resurfaced: $out"
  pass "awareness event is durable/replayed until ack, then advances exactly once"
}


test_active_requires_intake_ack_and_is_not_direct_execution() {
  local home out status
  home=$(make_home active)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "active bootstrap failed"
  append_active "$home"
  out=$(run_check "$home") || fail "active event check failed"
  assert_contains "$out" "engineering FUT-001 ACTIVE $ACTIVE_SOURCE FP-009" "ACTIVE event did not surface as engineering intake eligibility"
  status=0
  FM_STATE_OVERRIDE="$home/state" "$CHECK" ack plan-20260818-0002 awareness >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "engineering event accepted an awareness acknowledgement"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "failed ACTIVE acknowledgement advanced cursor"
  FM_STATE_OVERRIDE="$home/state" "$CHECK" ack plan-20260818-0002 intake >/dev/null \
    || fail "ACTIVE intake acknowledgement failed"
  [ "$(cursor_event "$home")" = plan-20260818-0002 ] || fail "ACTIVE intake acknowledgement did not advance cursor"
  pass "ACTIVE is mechanically distinct and requires intake acknowledgement, never an awareness/direct-execution shortcut"
}


test_non_active_engineering_is_rejected_without_cursor_advance() {
  local home out bad
  home=$(make_home nonactive-engineering)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "nonactive bootstrap failed"
  bad=$(awareness_line | sed 's/"actionability":"awareness"/"actionability":"engineering"/')
  printf '%s\n' "$bad" >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "invalid event check should surface through stdout, not command failure"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "non-ACTIVE engineering event was not rejected"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "invalid non-ACTIVE event advanced cursor"
  pending_exists "$home" && fail "invalid non-ACTIVE event became pending"
  pass "non-ACTIVE planning state can never be reinterpreted as engineering authority"
}


test_prefix_rewrite_breaks_continuity_without_reset() {
  local home out mutated
  home=$(make_home rewrite)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "rewrite bootstrap failed"
  mutated=$(snapshot_line | sed 's/"FUT-002":"PRESERVE"/"FUT-002":"CANDIDATE"/')
  printf '%s\n' "$mutated" > "$home/feed.jsonl"
  out=$(run_check "$home") || fail "continuity check should surface through stdout"
  assert_contains "$out" "SSSF_PLANNING_CONTINUITY_BROKEN" "prefix rewrite was not refused"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "continuity failure reset/advanced cursor"
  pass "changed historical feed prefix fails closed and never silently rebases"
}


test_malformed_and_stale_events_never_become_pending() {
  local home out stale
  home=$(make_home malformed)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "malformed bootstrap failed"
  printf '{bad}\n' >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "malformed check should surface through stdout"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "malformed event was not rejected"
  pending_exists "$home" && fail "malformed event became pending"

  home=$(make_home stale)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "stale bootstrap failed"
  stale='{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-001","from":"DECIDED","to":"SUPERSEDED","source_commit":"2222222222222222222222222222222222222222","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"actionability":"awareness"}'
  printf '%s\n' "$stale" >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "stale check should surface through stdout"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "stale from-state event was not rejected"
  pending_exists "$home" && fail "stale event became pending"
  pass "malformed and stale events are non-pass and cannot become pending effects"
}


test_unobservable_source_refuses_event_without_cursor_advance() {
  local home out
  home=$(make_home source-gap)
  write_snapshot "$home"
  run_check "$home" >/dev/null || fail "source-gap bootstrap failed"
  append_awareness "$home"
  out=$(run_check "$home" env FM_TEST_FAIL_SOURCE_COMMIT="$AWARE_SOURCE") || fail "source gap should surface through stdout"
  assert_contains "$out" "SSSF_PLANNING_COULD_NOT_OBSERVE" "missing source provenance was not CNO"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "source gap advanced cursor"
  pending_exists "$home" && fail "unobservable source became pending"
  pass "unobservable authoritative source stays distinct from a valid event and advances nothing"
}


test_install_binds_exact_check_bytes_and_tamper_is_rejected() {
  local home state status
  home=$(make_home trust)
  state="$home/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" "$CHECK" install --repo "$REPO" --ref "$REF" >/dev/null \
    || fail "planning check install failed"
  [ -f "$state/sssf-planning.check.sh" ] || fail "installed check is absent"
  [ -f "$state/sssf-planning.check-trust" ] || fail "check trust record is absent"
  status=0
  FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" sssf-planning' _ "$ROOT" "$state" || status=$?
  expect_code 0 "$status" "registered planning check trust"
  printf '\n# tamper\n' >> "$state/sssf-planning.check.sh"
  status=0
  FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" sssf-planning' _ "$ROOT" "$state" || status=$?
  [ "$status" -ne 0 ] || fail "tampered registered planning check still validated"
  pass "planning check uses the existing hash-bound custom-check trust mechanism"
}


test_bootstrap_is_silent_and_non_actionable
test_awareness_event_replays_until_ack_then_advances
test_active_requires_intake_ack_and_is_not_direct_execution
test_non_active_engineering_is_rejected_without_cursor_advance
test_prefix_rewrite_breaks_continuity_without_reset
test_malformed_and_stale_events_never_become_pending
test_unobservable_source_refuses_event_without_cursor_advance
test_install_binds_exact_check_bytes_and_tamper_is_rejected
