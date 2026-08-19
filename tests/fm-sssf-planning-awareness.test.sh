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
ACTIVE_SOURCE='3333333333333333333333333333333333333333'
FEED_COMMIT='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
FUTURE_BLOB='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
ROADMAP_BLOB='cccccccccccccccccccccccccccccccccccccccc'
INCREMENT_BLOB='dddddddddddddddddddddddddddddddddddddddd'

snapshot_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0001","kind":"snapshot","source_commit":"1111111111111111111111111111111111111111","states":{"FUT-001":"SEQUENCED","FUT-002":"PRESERVE","FUT-003":"ACTIVE"},"authoritative_refs":["docs/development/FUTURE_CANDIDATES.md","docs/development/ROADMAP.md"],"authoritative_blobs":{"docs/development/FUTURE_CANDIDATES.md":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","docs/development/ROADMAP.md":"cccccccccccccccccccccccccccccccccccccccc"},"actionability":"baseline"}'
}
awareness_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-004","from":"EXPLORE","to":"PRESERVE","source_commit":"2222222222222222222222222222222222222222","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"authoritative_blobs":{"docs/development/FUTURE_CANDIDATES.md":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"actionability":"awareness"}'
}
active_line() {
  printf '%s' '{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-001","from":"SEQUENCED","to":"ACTIVE","source_commit":"3333333333333333333333333333333333333333","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md","docs/increments/FP-009_EXAMPLE.md"],"authoritative_blobs":{"docs/development/FUTURE_CANDIDATES.md":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","docs/increments/FP-009_EXAMPLE.md":"dddddddddddddddddddddddddddddddddddddddd"},"actionability":"engineering","increment_id":"FP-009"}'
}

make_home() {
  local name=$1 home state fakebin
  home="$TMP_ROOT/$name"; state="$home/state"; fakebin="$home/fakebin"
  mkdir -p "$state" "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -u
args="$*"
case "$args" in
  *"commits/$FM_TEST_SOURCE_REF"*"--jq .sha"*) printf '%s\n' "$FM_TEST_FEED_COMMIT"; exit 0 ;;
esac
case "$args" in
  *"commits/"*"--jq .sha"*)
    target=${args#*commits/}; target=${target%% *}
    [ "${FM_TEST_FAIL_SOURCE_COMMIT:-}" != "$target" ] || exit 1
    printf '%s\n' "$target"; exit 0
    ;;
esac
case "$args" in
  *"Accept: application/vnd.github.raw+json"*"contents/$FM_TEST_SOURCE_PATH"*) cat "$FM_TEST_FEED_FILE"; exit 0 ;;
esac
case "$args" in
  *"contents/docs/development/FUTURE_CANDIDATES.md"*"--jq .type"*)
    [ "${FM_TEST_FAIL_REF:-0}" != 1 ] || exit 1
    oid=${FM_TEST_FUTURE_BLOB}; [ "${FM_TEST_BAD_BLOB:-0}" != 1 ] || oid=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    printf 'file\t%s\n' "$oid"; exit 0
    ;;
  *"contents/docs/development/ROADMAP.md"*"--jq .type"*) printf 'file\t%s\n' "$FM_TEST_ROADMAP_BLOB"; exit 0 ;;
  *"contents/docs/increments/FP-009_EXAMPLE.md"*"--jq .type"*) printf 'file\t%s\n' "$FM_TEST_INCREMENT_BLOB"; exit 0 ;;
esac
printf 'unexpected fake gh invocation: %s\n' "$args" >&2
exit 2
SH
  chmod +x "$fakebin/gh"
  printf 'schema=fm-sssf-planning-source.v1\nrepository=%s\nref=%s\npath=%s\n' "$REPO" "$REF" 'docs/development/PLANNING_EVENTS.jsonl' > "$state/sssf-planning.source"
  chmod 0600 "$state/sssf-planning.source"
  printf '%s\n' "$home"
}

run_check() { # <home> [env command prefix...]
  local home=$1; shift
  FM_STATE_OVERRIDE="$home/state" FM_TEST_SOURCE_REF="$REF" \
    FM_TEST_SOURCE_PATH='docs/development/PLANNING_EVENTS.jsonl' \
    FM_TEST_FEED_COMMIT="$FEED_COMMIT" FM_TEST_FEED_FILE="$home/feed.jsonl" \
    FM_TEST_FUTURE_BLOB="$FUTURE_BLOB" FM_TEST_ROADMAP_BLOB="$ROADMAP_BLOB" \
    FM_TEST_INCREMENT_BLOB="$INCREMENT_BLOB" PATH="$home/fakebin:$PATH" \
    "$@" bash "$CHECK" check
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
  home=$(make_home bootstrap); write_snapshot "$home"
  out=$(run_check "$home") || fail "bootstrap check failed"
  [ -z "$out" ] || fail "bootstrap surfaced as actionable: $out"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "bootstrap cursor did not advance"
  pending_exists "$home" && fail "bootstrap created pending work"
  pass "bootstrap snapshot establishes the cursor silently and cannot create work"
}


test_awareness_replays_until_ack_then_advances() {
  local home out shown
  home=$(make_home awareness); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"; append_awareness "$home"
  out=$(run_check "$home") || fail "awareness check failed"
  assert_contains "$out" "SSSF_PLANNING_EVENT pending plan-20260818-0002 awareness FUT-004 PRESERVE" "awareness event did not surface typed"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "cursor advanced before ack"
  out=$(run_check "$home") || fail "pending replay failed"
  assert_contains "$out" "plan-20260818-0002 awareness" "pending event was not replayed"
  shown=$(FM_STATE_OVERRIDE="$home/state" bash "$CHECK" show plan-20260818-0002) || fail "show failed"
  assert_contains "$shown" '"actionability":"awareness"' "show did not expose pending event"
  FM_STATE_OVERRIDE="$home/state" bash "$CHECK" ack plan-20260818-0002 awareness >/dev/null || fail "awareness ack failed"
  [ "$(cursor_event "$home")" = plan-20260818-0002 ] || fail "cursor did not advance after ack"
  pending_exists "$home" && fail "pending survived ack"
  [ -z "$(run_check "$home")" ] || fail "acknowledged awareness resurfaced"
  pass "awareness event is replayable until acknowledgement and advances exactly once"
}


test_active_requires_intake_ack() {
  local home out rc=0
  home=$(make_home active); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"; append_active "$home"
  out=$(run_check "$home") || fail "ACTIVE check failed"
  assert_contains "$out" "engineering FUT-001 ACTIVE $ACTIVE_SOURCE FP-009" "ACTIVE did not surface as intake eligibility"
  FM_STATE_OVERRIDE="$home/state" bash "$CHECK" ack plan-20260818-0002 awareness >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "engineering event accepted awareness ack"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "failed ack advanced cursor"
  FM_STATE_OVERRIDE="$home/state" bash "$CHECK" ack plan-20260818-0002 intake >/dev/null || fail "intake ack failed"
  [ "$(cursor_event "$home")" = plan-20260818-0002 ] || fail "intake ack did not advance cursor"
  pass "ACTIVE is intake eligibility only and requires the distinct intake acknowledgement"
}


test_non_active_engineering_is_rejected() {
  local home out bad
  home=$(make_home nonactive); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"
  bad=$(awareness_line | sed 's/"actionability":"awareness"/"actionability":"engineering"/')
  printf '%s\n' "$bad" >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "invalid event should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "non-ACTIVE engineering was not rejected"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "invalid event advanced cursor"
  pending_exists "$home" && fail "invalid event became pending"
  pass "non-ACTIVE state can never be reinterpreted as engineering authority"
}


test_prefix_rewrite_breaks_continuity() {
  local home out mutated
  home=$(make_home rewrite); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"
  mutated=$(snapshot_line | sed 's/"FUT-002":"PRESERVE"/"FUT-002":"CANDIDATE"/')
  printf '%s\n' "$mutated" > "$home/feed.jsonl"
  out=$(run_check "$home") || fail "continuity failure should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_CONTINUITY_BROKEN" "historical rewrite was not refused"
  [ "$(cursor_event "$home")" = plan-20260818-0001 ] || fail "continuity failure reset cursor"
  pass "historical prefix rewrite fails closed without silent rebase"
}


test_source_commit_and_blob_must_reobserve_exactly() {
  local home out
  home=$(make_home source-gap); write_snapshot "$home"
  out=$(run_check "$home" env FM_TEST_BAD_BLOB=1) || fail "blob mismatch should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_COULD_NOT_OBSERVE" "blob mismatch was not CNO"
  [ ! -e "$home/state/sssf-planning.cursor.json" ] || fail "blob mismatch established bootstrap cursor"

  home=$(make_home commit-gap); write_snapshot "$home"
  out=$(run_check "$home" env FM_TEST_FAIL_SOURCE_COMMIT="$SNAPSHOT_SOURCE") || fail "commit gap should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_COULD_NOT_OBSERVE" "source commit gap was not CNO"
  [ ! -e "$home/state/sssf-planning.cursor.json" ] || fail "source commit gap established cursor"
  pass "consumer independently re-observes exact source commit and Git blob identities"
}


test_malformed_and_stale_events_never_become_pending() {
  local home out stale
  home=$(make_home malformed); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"
  printf '{bad}\n' >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "malformed event should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "malformed event was not rejected"
  pending_exists "$home" && fail "malformed event became pending"

  home=$(make_home stale); write_snapshot "$home"; run_check "$home" >/dev/null || fail "bootstrap failed"
  stale='{"schema":"sssf-planning-event/v1","event_id":"plan-20260818-0002","kind":"transition","item_id":"FUT-001","from":"DECIDED","to":"SUPERSEDED","source_commit":"2222222222222222222222222222222222222222","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"authoritative_blobs":{"docs/development/FUTURE_CANDIDATES.md":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"actionability":"awareness"}'
  printf '%s\n' "$stale" >> "$home/feed.jsonl"
  out=$(run_check "$home") || fail "stale event should surface through typed output"
  assert_contains "$out" "SSSF_PLANNING_EVENT_INVALID" "stale event was not rejected"
  pending_exists "$home" && fail "stale event became pending"
  pass "malformed and stale events advance nothing and create no pending effect"
}


test_install_uses_existing_hash_bound_trust() {
  local home state rc=0
  home=$(make_home trust); state="$home/state"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$state" bash "$CHECK" install --repo "$REPO" --ref "$REF" >/dev/null || fail "install failed"
  [ -f "$state/sssf-planning.check.sh" ] || fail "installed check absent"
  [ -f "$state/sssf-planning.check-trust" ] || fail "trust record absent"
  FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" sssf-planning' _ "$ROOT" "$state" || rc=$?
  expect_code 0 "$rc" "registered planning check trust"
  printf '\n# tamper\n' >> "$state/sssf-planning.check.sh"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-check-lib.sh"; fm_custom_check_registered "$2" sssf-planning' _ "$ROOT" "$state" || rc=$?
  [ "$rc" -ne 0 ] || fail "tampered registered check still validated"
  pass "planning check reuses the existing hash-bound custom-check trust mechanism"
}

test_bootstrap_is_silent_and_non_actionable
test_awareness_replays_until_ack_then_advances
test_active_requires_intake_ack
test_non_active_engineering_is_rejected
test_prefix_rewrite_breaks_continuity
test_source_commit_and_blob_must_reobserve_exactly
test_malformed_and_stale_events_never_become_pending
test_install_uses_existing_hash_bound_trust
