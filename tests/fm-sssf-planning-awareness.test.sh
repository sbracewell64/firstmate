#!/usr/bin/env bash
# Behavior tests for bin/fm-sssf-planning-awareness.sh - FirstMate's consumer
# side of the SSSF planning-transition bridge (increment FM-FP-001, ADR-0005).
#
# The invariant every case here serves:
#
#   FirstMate consumes typed planning transitions. It never derives execution
#   authority from planning prose. Only ACTIVE is engineering-intake eligible,
#   and even ACTIVE is not execution authority - the adapter surfaces a typed
#   wake and creates NO task.
#
# Two disciplines apply throughout, because a green here is worth only what it
# excludes:
#
#   WATCHED RED. Every refusal case is paired with the same fixture in its
#   honest form, asserted to be ACCEPTED. A guard that refuses everything and a
#   guard that works are indistinguishable from the refusal alone.
#
#   NON-VACUITY. Every silence assertion is preceded, in the same fixture, by a
#   proof that this exact invocation DOES speak when it has something to say.
#   Empty output is otherwise satisfied by an adapter that never ran.
#
# The third value is a first-class case, not an afterthought: an unreachable
# feed must be reported as could-not-observe. It must never be silence (which
# reads as "nothing new") and never a continuity failure (which is a defect
# claim about a feed nothing read). bin/fm-verify-lib.sh owns that type.
#
# Integration is asserted against the CURRENT watcher surface rather than
# against an assumption about it: the check is dispatched exactly the way
# bin/fm-watch.sh dispatches a registered custom check, through
# fm_custom_check_snapshot_prepare on a real fm-check-register.sh registration.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"

FM_TEST_IDENTITY_CONTRACT=1

ADAPTER="$ROOT/bin/fm-sssf-planning-awareness.sh"
TMP=$(fm_test_tmproot fm-sssf-planning)
FAKEBIN=$(fm_fakebin "$TMP")

command -v jq >/dev/null 2>&1 || { printf 'skip - jq unavailable\n'; exit 0; }

SRC=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

# --- fixtures ---------------------------------------------------------------

# A fake gh that answers the three request shapes the adapter makes, and can be
# steered into each distinct remote failure the adapter must tell apart.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -u
request=
for a in "$@"; do
  case "$a" in repos/*) request=$a; break ;; esac
done
[ -n "$request" ] || { printf 'fake gh: no repos/ request in: %s\n' "$*" >&2; exit 1; }
case "$request" in
  repos/*/commits/*)
    [ "${FM_TEST_COMMIT_UNREACHABLE:-0}" = 1 ] && exit 1
    printf '%s\n' "${request##*/}"
    ;;
  *'/contents/'*'PLANNING_EVENTS.jsonl?ref='*)
    [ "${FM_TEST_FEED_UNREACHABLE:-0}" = 1 ] && exit 1
    cat "$FM_TEST_FEED"
    ;;
  *'/contents/'*'?ref='*)
    [ "${FM_TEST_COMMIT_UNREACHABLE:-0}" = 1 ] && exit 1
    path=${request#*/contents/}
    path=${path%%\?ref=*}
    [ "$path" = "${FM_TEST_MISSING_REF:-}" ] && exit 1
    printf 'blobsha\n'
    ;;
  *)
    printf 'fake gh: unexpected request: %s\n' "$request" >&2
    exit 1
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh"

# A fresh private state directory per case, so no case can pass on another's
# leftovers and no case can be poisoned by them.
new_state() {
  local dir
  dir=$(mktemp -d "$TMP/state.XXXXXX") || fail "cannot create fixture state"
  chmod 700 "$dir"
  printf '%s\n' "$dir"
}

# A private copy of the adapter, so a case that mutates it cannot reach the
# repo. The registrar and its libraries are linked from the real tree on
# purpose: the trust boundary under test is theirs, not a reimplementation.
adapter_sandbox() {
  local dir
  dir=$(mktemp -d "$TMP/bin.XXXXXX") || fail "cannot create adapter sandbox"
  cp "$ADAPTER" "$dir/fm-sssf-planning-awareness.sh" || fail "cannot copy adapter"
  chmod 700 "$dir/fm-sssf-planning-awareness.sh"
  ln -s "$ROOT/bin/fm-check-register.sh" "$dir/fm-check-register.sh"
  ln -s "$ROOT/bin/fm-pr-lib.sh" "$dir/fm-pr-lib.sh"
  ln -s "$ROOT/bin/fm-check-lib.sh" "$dir/fm-check-lib.sh"
  printf '%s\n' "$dir/fm-sssf-planning-awareness.sh"
}

# Every adapter invocation goes through here and is logged, so the suite can
# report what it actually executed. A count of assertions that never ran is the
# same shape of defect this adapter exists to refuse.
RUN_LOG="$TMP/adapter-runs.log"
: > "$RUN_LOG"

adapter_exec() { # <binary> <state> <args...>
  local bin=$1 state=$2
  shift 2
  printf '%s %s\n' "${bin##*/}" "$*" >> "$RUN_LOG"
  PATH="$FAKEBIN:$PATH" \
  FM_STATE_OVERRIDE="$state" \
  FM_TEST_FEED="$FEED" \
  FM_TEST_MISSING_REF="${MISSING_REF:-}" \
  FM_TEST_FEED_UNREACHABLE="${FEED_UNREACHABLE:-0}" \
  FM_TEST_COMMIT_UNREACHABLE="${COMMIT_UNREACHABLE:-0}" \
  FM_SSSF_PLANNING_ENABLE="${ENABLE:-0}" \
  FM_SSSF_PLANNING_REPO='fixture/sssf' \
  FM_SSSF_PLANNING_REF='fixture-ref' \
  "$bin" "$@"
}

run_adapter() { # <state> <args...>
  adapter_exec "$ADAPTER" "$@"
}

bootstrap_event() { # <event-id> <sequence>
  printf '{"actionability":"awareness","authoritative_refs":["docs/development/FUTURE_CANDIDATES.md"],"event_id":"%s","increments":["FP-001","FM-FP-001"],"kind":"bootstrap","schema":"sssf-planning-event/v1","sequence":%s,"source_commit":"%s","states":{"FUT-003":"ACTIVE"}}' \
    "$1" "$2" "$SRC"
}

transition_event() { # <event-id> <sequence> <item> <from> <to> <actionability> [extra-json]
  local extra=${7:-}
  printf '{"actionability":"%s","authoritative_refs":["docs/increments/FP-001_FIRSTMATE_PLANNING_FEED.md"],"event_id":"%s","from":"%s","item_id":"%s","kind":"transition","schema":"sssf-planning-event/v1","sequence":%s,"source_commit":"%s","to":"%s"%s}' \
    "$6" "$1" "$4" "$3" "$2" "$SRC" "$5" "$extra"
}

active_event() { # <event-id> <sequence>
  transition_event "$1" "$2" FUT-003 SEQUENCED ACTIVE engineering ',"increments":["FM-FP-001"]'
}

write_feed() { FEED="$TMP/feed.$RANDOM.jsonl"; printf '%s\n' "$@" > "$FEED"; }

# Every file the adapter is allowed to own inside a home's state directory.
# Anything else appearing there is the adapter reaching outside its lane.
assert_no_task_state() { # <state> <label>
  local state=$1 label=$2 stray
  stray=$(find "$state" -maxdepth 1 -type f \
    ! -name 'sssf-planning.cursor' ! -name 'sssf-planning.pending' \
    ! -name 'sssf-planning.check.sh' ! -name 'sssf-planning.check-trust' \
    ! -name 'unrelated.keep' -print | LC_ALL=C sort)
  [ -z "$stray" ] || fail "$label: adapter created state it does not own:"$'\n'"$stray"
}

cursor_fingerprint() { # <state>
  if [ -e "$1/sssf-planning.cursor" ]; then cat "$1/sssf-planning.cursor"; else printf 'ABSENT\n'; fi
}

# --- the matrix -------------------------------------------------------------

test_silence_is_observed_and_not_an_absent_observation() {
  local state out before
  state=$(new_state)
  write_feed "$(bootstrap_event plan-20260818-0001 1)"

  # NON-VACUITY: this exact invocation speaks when it has something to say.
  out=$(run_adapter "$state" check) || fail "check exited nonzero"
  assert_contains "$out" 'sssf-planning pending event_id=plan-20260818-0001' \
    "silence non-vacuity: a new event must produce a wake line"
  run_adapter "$state" acknowledge plan-20260818-0001 >/dev/null || fail "acknowledge failed"

  # Only now is empty output meaningful.
  out=$(run_adapter "$state" check) || fail "unchanged-feed check exited nonzero"
  [ -z "$out" ] || fail "unchanged feed produced a wake: $out"

  # WATCHED RED for the silence itself: an unreachable feed must break the
  # silence rather than be absorbed into it. This is the three-valued rule -
  # "I could not look" must never render as "I looked and there was nothing".
  before=$(cursor_fingerprint "$state")
  out=$(FEED_UNREACHABLE=1 run_adapter "$state" check) || fail "unreachable-feed check exited nonzero"
  [ -n "$out" ] || fail "an unreachable feed was reported as silence"
  assert_contains "$out" 'could-not-observe reason=source-unreachable' \
    "an unreachable feed must be could-not-observe"
  assert_not_contains "$out" 'continuity failure' \
    "an unreachable feed must not be claimed as a defect in the feed"
  [ "$(cursor_fingerprint "$state")" = "$before" ] || fail "could-not-observe advanced the cursor"
  assert_absent "$state/sssf-planning.pending" "could-not-observe created a pending generation"
  assert_no_task_state "$state" "silence and could-not-observe"
  pass "no new event is silence, and an unreadable feed is could-not-observe rather than silence"
}

test_bootstrap_synchronizes_and_creates_no_task() {
  local state out
  state=$(new_state)
  write_feed "$(bootstrap_event plan-20260818-0001 1)"
  out=$(run_adapter "$state" check) || fail "bootstrap check exited nonzero"
  assert_contains "$out" 'kind=bootstrap' "bootstrap must surface as a bootstrap"
  assert_contains "$out" 'actionability=awareness' "bootstrap must be awareness only"
  assert_not_contains "$out" 'to=' "a bootstrap snapshot carries no transition edge"
  assert_present "$state/sssf-planning.pending" "bootstrap generation was not durable"
  assert_absent "$state/sssf-planning.cursor" "cursor advanced before acknowledgement"
  assert_no_task_state "$state" "bootstrap"
  # inspect returns the exact bytes, so handling reads the event and not a summary.
  [ "$(run_adapter "$state" inspect)" = "$(bootstrap_event plan-20260818-0001 1)" ] \
    || fail "inspect did not return the exact pending event"
  pass "bootstrap synchronizes the cursor, stays awareness-only, and creates no task"
}

test_every_non_active_state_is_awareness_only() {
  local state out target origin seq=1 id
  for target in PRESERVE CANDIDATE DECIDED SEQUENCED PROVEN DEFERRED REJECTED SUPERSEDED EXPLORE; do
    # A transition needs a distinct origin; a no-op edge is its own refusal case.
    if [ "$target" = SEQUENCED ]; then origin=DECIDED; else origin=SEQUENCED; fi
    state=$(new_state)
    seq=$((seq + 1))
    id=$(printf 'plan-20260818-%04d' "$seq")
    write_feed "$(transition_event "$id" "$seq" FUT-003 "$origin" "$target" awareness)"
    out=$(run_adapter "$state" check) || fail "$target check exited nonzero"
    assert_contains "$out" "to=$target" "$target must surface as itself"
    assert_contains "$out" 'actionability=awareness' "$target must be awareness only"
    assert_no_task_state "$state" "$target"

    # WATCHED RED: engineering actionability cannot be smuggled onto a
    # non-ACTIVE state. Only ACTIVE may carry it.
    state=$(new_state)
    write_feed "$(transition_event "$id" "$seq" FUT-003 "$origin" "$target" engineering)"
    out=$(run_adapter "$state" check) || fail "$target smuggle check exited nonzero"
    assert_contains "$out" 'invalid-event' "$target with engineering actionability must be refused"
    assert_absent "$state/sssf-planning.pending" "$target smuggle created a pending generation"
    assert_absent "$state/sssf-planning.cursor" "$target smuggle advanced the cursor"
  done
  pass "every non-ACTIVE planning state is awareness-only and cannot carry engineering actionability"
}

test_active_is_intake_eligible_but_creates_no_task() {
  local state out
  state=$(new_state)
  write_feed "$(active_event plan-20260818-0100 1)"
  out=$(run_adapter "$state" check) || fail "ACTIVE check exited nonzero"
  assert_contains "$out" 'to=ACTIVE' "ACTIVE must surface as ACTIVE"
  assert_contains "$out" 'actionability=engineering' "ACTIVE must surface engineering eligibility"
  assert_present "$state/sssf-planning.pending" "ACTIVE generation was not durable"
  # The whole point of the boundary: eligibility is all that was produced.
  assert_no_task_state "$state" "ACTIVE"
  assert_contains "$(run_adapter "$state" inspect)" '"increments":["FM-FP-001"]' \
    "ACTIVE must name the increment that ordinary admission will fetch and judge"

  # WATCHED RED: an ACTIVE claim that names nothing to activate is refused.
  state=$(new_state)
  write_feed "$(transition_event plan-20260818-0100 1 FUT-003 SEQUENCED ACTIVE engineering)"
  out=$(run_adapter "$state" check) || fail "unbound ACTIVE check exited nonzero"
  assert_contains "$out" 'invalid-event' "ACTIVE with no increment binding must be refused"
  assert_absent "$state/sssf-planning.pending" "unbound ACTIVE created a pending generation"
  pass "ACTIVE is engineering-intake eligibility only, names its increment, and creates no task"
}

test_malformed_events_cannot_activate_work() {
  local state out case_json label
  # Each of these is the honest ACTIVE event with exactly one thing wrong, so a
  # refusal is attributable to that one thing.
  while IFS='|' read -r label case_json; do
    [ -n "$label" ] || continue
    state=$(new_state)
    write_feed "$case_json"
    out=$(run_adapter "$state" check) || fail "$label check exited nonzero"
    assert_contains "$out" 'invalid-event' "$label must be refused as a malformed event"
    assert_absent "$state/sssf-planning.pending" "$label created a pending generation"
    assert_absent "$state/sssf-planning.cursor" "$label advanced the cursor"
    assert_no_task_state "$state" "$label"
  done <<EOF
not JSON at all|{ this is not json
wrong schema id|$(active_event plan-20260818-0100 1 | jq -c '.schema="sssf-planning-event/v2"')
unknown target state|$(active_event plan-20260818-0100 1 | jq -c '.to="LAUNCH"|.actionability="awareness"|del(.increments)')
unknown origin state|$(active_event plan-20260818-0100 1 | jq -c '.from="MAYBE"|.to="DECIDED"|.actionability="awareness"|del(.increments)')
no-op transition edge|$(active_event plan-20260818-0100 1 | jq -c '.from="ACTIVE"')
abbreviated source commit|$(active_event plan-20260818-0100 1 | jq -c '.source_commit="aaaaaaa"')
traversing authoritative ref|$(active_event plan-20260818-0100 1 | jq -c '.authoritative_refs=["docs/../../etc/passwd"]')
ungoverned authoritative ref|$(active_event plan-20260818-0100 1 | jq -c '.authoritative_refs=["etc/passwd"]')
empty authoritative refs|$(active_event plan-20260818-0100 1 | jq -c '.authoritative_refs=[]')
malformed item identity|$(active_event plan-20260818-0100 1 | jq -c '.item_id="ROADMAP"')
malformed event identity|$(active_event plan-20260818-0100 1 | jq -c '.event_id="plan-1"')
missing declared sequence|$(active_event plan-20260818-0100 1 | jq -c 'del(.sequence)')
fractional sequence|$(active_event plan-20260818-0100 1 | jq -c '.sequence=1.5')
bootstrap carrying an edge|$(bootstrap_event plan-20260818-0001 1 | jq -c '.to="ACTIVE"')
bootstrap with no snapshot|$(bootstrap_event plan-20260818-0001 1 | jq -c 'del(.states)')
bootstrap with unknown state|$(bootstrap_event plan-20260818-0001 1 | jq -c '.states={"FUT-003":"LAUNCH"}')
unknown event kind|$(active_event plan-20260818-0100 1 | jq -c '.kind="announcement"')
EOF

  # WATCHED RED partner: the same fixture, honest, is ACCEPTED. Without this the
  # whole block is satisfied by an adapter that refuses everything.
  state=$(new_state)
  write_feed "$(active_event plan-20260818-0100 1)"
  out=$(run_adapter "$state" check) || fail "honest-control check exited nonzero"
  assert_contains "$out" 'sssf-planning pending' "the honest control event must be accepted"
  pass "every malformed event shape is refused without activating work, and the honest control is accepted"
}

test_stale_or_missing_authority_cannot_activate_work() {
  local state out
  # Missing ref at a commit that IS reachable: the ref is genuinely absent.
  state=$(new_state)
  write_feed "$(active_event plan-20260818-0100 1)"
  out=$(MISSING_REF='docs/increments/FP-001_FIRSTMATE_PLANNING_FEED.md' run_adapter "$state" check) \
    || fail "missing-authority check exited nonzero"
  assert_contains "$out" 'stale-or-missing-authority event_id=plan-20260818-0100' \
    "a missing authoritative reference must be named as such"
  assert_absent "$state/sssf-planning.pending" "missing authority created a pending generation"
  assert_absent "$state/sssf-planning.cursor" "missing authority advanced the cursor"

  # The wrong-subject control: when the source commit itself cannot be read, the
  # ref was never examined. Reporting that as missing authority would credit a
  # verdict to a subject nothing observed.
  state=$(new_state)
  write_feed "$(active_event plan-20260818-0100 1)"
  out=$(COMMIT_UNREACHABLE=1 run_adapter "$state" check) || fail "unreachable-commit check exited nonzero"
  assert_contains "$out" 'could-not-observe reason=authority-unreadable' \
    "an unreachable source commit must be could-not-observe"
  assert_not_contains "$out" 'stale-or-missing-authority' \
    "an unreachable source commit must not be claimed as missing authority"
  assert_absent "$state/sssf-planning.cursor" "could-not-observe advanced the cursor"

  # WATCHED RED partner: with every named reference present, the same event is
  # accepted, so the refusals above are attributable to the reference state.
  state=$(new_state)
  write_feed "$(active_event plan-20260818-0100 1)"
  out=$(run_adapter "$state" check) || fail "present-authority check exited nonzero"
  assert_contains "$out" 'sssf-planning pending' "an event with present references must be accepted"
  pass "absent authority refuses, an unreadable source commit is could-not-observe, and present authority is accepted"
}

test_continuity_mismatch_refuses_and_never_advances_the_cursor() {
  local state out before after size
  state=$(new_state)
  write_feed "$(bootstrap_event plan-20260818-0001 1)" "$(active_event plan-20260818-0100 2)"
  run_adapter "$state" check >/dev/null || fail "seed check exited nonzero"
  run_adapter "$state" acknowledge plan-20260818-0001 >/dev/null || fail "seed acknowledge failed"
  before=$(cursor_fingerprint "$state")
  [ "$before" != "ABSENT" ] || fail "seed did not establish a cursor"

  # Prefix MUTATION: the consumed prefix no longer hashes to what was consumed.
  printf 'X' | dd of="$FEED" bs=1 seek=0 conv=notrunc 2>/dev/null
  out=$(run_adapter "$state" check) || fail "prefix-mutation check exited nonzero"
  assert_contains "$out" 'continuity failure=prefix-changed' \
    "prefix mutation must be a typed continuity failure"
  assert_not_contains "$out" 'could-not-observe' \
    "prefix mutation is observed-bad, not could-not-observe"
  [ "$(cursor_fingerprint "$state")" = "$before" ] || fail "prefix mutation advanced the cursor"
  assert_absent "$state/sssf-planning.pending" "prefix mutation created a pending generation"

  # TRUNCATION: the feed is now shorter than what was already consumed.
  : > "$FEED"
  out=$(run_adapter "$state" check) || fail "truncation check exited nonzero"
  assert_contains "$out" 'continuity failure=truncated' \
    "truncation must be a typed continuity failure"
  [ "$(cursor_fingerprint "$state")" = "$before" ] || fail "truncation advanced the cursor"
  assert_absent "$state/sssf-planning.pending" "truncation created a pending generation"

  # A partially appended record is not a record.
  size=$(printf '%s' "$(bootstrap_event plan-20260818-0001 1)" | wc -c | tr -d ' ')
  { printf '%s\n' "$(bootstrap_event plan-20260818-0001 1)"; printf '%s' '{"partial":'; } > "$FEED"
  out=$(run_adapter "$state" check) || fail "incomplete-record check exited nonzero"
  assert_contains "$out" 'continuity failure=incomplete-record' \
    "an unterminated record must be a typed continuity failure"
  [ "$(cursor_fingerprint "$state")" = "$before" ] || fail "an incomplete record advanced the cursor"
  [ "$size" -gt 0 ] || fail "fixture sizing failed"

  # WATCHED RED partner: restore honest append-only growth and the cursor DOES
  # advance, so "never advances" above is a property and not a dead adapter.
  write_feed "$(bootstrap_event plan-20260818-0001 1)" "$(active_event plan-20260818-0100 2)"
  out=$(run_adapter "$state" check) || fail "restored-feed check exited nonzero"
  assert_contains "$out" 'event_id=plan-20260818-0100' "honest growth must surface the next event"
  run_adapter "$state" acknowledge plan-20260818-0100 >/dev/null || fail "restored acknowledge failed"
  after=$(cursor_fingerprint "$state")
  [ "$after" != "$before" ] || fail "honest growth did not advance the cursor"
  pass "truncation and prefix mutation are typed continuity failures that never advance the cursor"
}

test_acknowledgement_is_durable_and_ordered() {
  local state out expected_offset
  state=$(new_state)
  # Three events present at once. Delivery must be oldest-unseen first, not
  # newest, or a promotion could be skipped entirely.
  write_feed "$(bootstrap_event plan-20260818-0001 1)" \
             "$(transition_event plan-20260818-0002 2 FUT-003 CANDIDATE DECIDED awareness)" \
             "$(active_event plan-20260818-0003 3)"

  out=$(run_adapter "$state" check) || fail "first check exited nonzero"
  assert_contains "$out" 'event_id=plan-20260818-0001' "delivery must start at the oldest unseen event"

  # WATCHED RED: acknowledging an identity other than the pending one is
  # refused and changes nothing.
  run_adapter "$state" acknowledge plan-20260818-0003 >/dev/null 2>&1 \
    && fail "acknowledging a non-pending identity was accepted"
  assert_absent "$state/sssf-planning.cursor" "a refused acknowledgement advanced the cursor"
  assert_present "$state/sssf-planning.pending" "a refused acknowledgement retired the pending generation"

  run_adapter "$state" acknowledge plan-20260818-0001 >/dev/null || fail "acknowledge 1 failed"
  assert_absent "$state/sssf-planning.pending" "acknowledgement did not retire the pending generation"
  expected_offset=$(( $(printf '%s\n' "$(bootstrap_event plan-20260818-0001 1)" | wc -c | tr -d ' ') ))
  assert_grep "offset=$expected_offset" "$state/sssf-planning.cursor" \
    "the cursor must advance by exactly the consumed record"
  assert_grep 'last_sequence=1' "$state/sssf-planning.cursor" "the cursor must record the consumed sequence"

  out=$(run_adapter "$state" check) || fail "second check exited nonzero"
  assert_contains "$out" 'event_id=plan-20260818-0002' "the next event must be the next in order, not the newest"
  run_adapter "$state" acknowledge plan-20260818-0002 >/dev/null || fail "acknowledge 2 failed"

  out=$(run_adapter "$state" check) || fail "third check exited nonzero"
  assert_contains "$out" 'event_id=plan-20260818-0003' "ordered delivery must reach the third event"
  run_adapter "$state" acknowledge plan-20260818-0003 >/dev/null || fail "acknowledge 3 failed"

  # Durability: the record survives, and a fresh process resumes from it.
  assert_grep 'last_sequence=3' "$state/sssf-planning.cursor" "the cursor must be durable across invocations"
  out=$(run_adapter "$state" check) || fail "drained check exited nonzero"
  [ -z "$out" ] || fail "a fully drained feed produced a wake: $out"
  assert_no_task_state "$state" "ordered acknowledgement"
  pass "acknowledgement is durable, ordered oldest-first, and refuses a mismatched identity"
}

test_duplicate_events_do_not_duplicate_effects() {
  local state out first second
  state=$(new_state)
  write_feed "$(bootstrap_event plan-20260818-0001 1)"

  # A repeated wake for the SAME pending generation is one generation, not two.
  first=$(run_adapter "$state" check) || fail "first check exited nonzero"
  second=$(run_adapter "$state" check) || fail "repeat check exited nonzero"
  [ "$first" = "$second" ] || fail "a repeated poll changed the pending answer"
  [ "$(find "$state" -maxdepth 1 -name 'sssf-planning.pending' | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "a repeated poll created a second pending generation"
  assert_absent "$state/sssf-planning.cursor" "a repeated poll advanced the cursor"
  run_adapter "$state" acknowledge plan-20260818-0001 >/dev/null || fail "acknowledge failed"

  # A replayed identity that clears the sequence gate is still a replay.
  write_feed "$(bootstrap_event plan-20260818-0001 1)" "$(bootstrap_event plan-20260818-0001 2)"
  out=$(run_adapter "$state" check) || fail "replayed-identity check exited nonzero"
  assert_contains "$out" 'continuity failure=duplicate-event event_id=plan-20260818-0001' \
    "a replayed event identity must be refused as a duplicate"
  assert_absent "$state/sssf-planning.pending" "a replayed identity created a pending generation"

  # A record whose declared sequence does not advance means the feed was
  # rewritten rather than appended to, whatever its bytes say.
  write_feed "$(bootstrap_event plan-20260818-0001 1)" \
             "$(transition_event plan-20260818-0009 1 FUT-003 CANDIDATE DECIDED awareness)"
  out=$(run_adapter "$state" check) || fail "out-of-order check exited nonzero"
  assert_contains "$out" 'continuity failure=out-of-order' \
    "a non-advancing declared sequence must be refused"
  assert_absent "$state/sssf-planning.pending" "an out-of-order record created a pending generation"

  # WATCHED RED partner: a genuinely new identity at an advancing sequence IS
  # accepted, so the duplicate guard is not simply refusing everything.
  write_feed "$(bootstrap_event plan-20260818-0001 1)" \
             "$(transition_event plan-20260818-0009 2 FUT-003 CANDIDATE DECIDED awareness)"
  out=$(run_adapter "$state" check) || fail "fresh-event check exited nonzero"
  assert_contains "$out" 'event_id=plan-20260818-0009' "a genuinely new event must be accepted"
  pass "a repeated poll, a replayed identity, and a non-advancing sequence all produce no duplicate effect"
}

test_registered_check_trust_boundary_holds() {
  local state adapter_copy out
  state=$(new_state)
  adapter_copy=$(adapter_sandbox)
  write_feed "$(bootstrap_event plan-20260818-0001 1)"

  # WATCHED RED for the enablement gate itself: arming is refused by default,
  # which is what keeps this increment from live-enabling the production feed.
  adapter_exec "$adapter_copy" "$state" install >/dev/null 2>&1 \
    && fail "install armed the planning check without explicit enablement"
  assert_absent "$state/sssf-planning.check.sh" "a refused install left a check behind"

  ENABLE=1 adapter_exec "$adapter_copy" "$state" install >/dev/null \
    || fail "deliberate install failed"
  # NON-VACUITY: the registration the watcher reads is genuinely in place.
  fm_custom_check_registered "$state" sssf-planning \
    || fail "the installed check was not registered for the watcher"

  # This is the watcher's own dispatch path, not an imitation of it.
  fm_pr_poll_snapshot_capture "$state" sssf-planning "$ROOT/bin/fm-pr-poll.sh" 2>/dev/null \
    && fail "the planning check was claimed by the PR poll path"
  fm_custom_check_snapshot_prepare "$state" sssf-planning \
    || fail "the watcher could not prepare a trusted snapshot of the planning check"
  out=$(PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$state" FM_TEST_FEED="$FEED" \
    FM_TEST_MISSING_REF='' FM_TEST_FEED_UNREACHABLE=0 FM_TEST_COMMIT_UNREACHABLE=0 \
    FM_SSSF_PLANNING_REPO='fixture/sssf' FM_SSSF_PLANNING_REF='fixture-ref' \
    bash "$FM_CUSTOM_CHECK_SNAPSHOT")
  fm_custom_check_snapshot_cleanup
  assert_contains "$out" 'sssf-planning pending event_id=plan-20260818-0001' \
    "the watcher's own dispatch of the registered check must produce the typed wake"
  rm -f "$state/sssf-planning.pending"

  # WATCHED RED: mutating the CHECK breaks the watcher's content binding.
  printf '\n# tampered\n' >> "$state/sssf-planning.check.sh"
  fm_custom_check_registered "$state" sssf-planning \
    && fail "a mutated check kept its registration"
  fm_custom_check_snapshot_prepare "$state" sssf-planning \
    && { fm_custom_check_snapshot_cleanup; fail "the watcher prepared a snapshot of a mutated check"; }
  fm_custom_check_snapshot_cleanup

  # WATCHED RED: mutating the ADAPTER cannot inherit the check's authorization.
  # The registration binds the check file; the check file binds the adapter.
  adapter_exec "$adapter_copy" "$state" retire >/dev/null || fail "retire before reinstall failed"
  ENABLE=1 adapter_exec "$adapter_copy" "$state" install >/dev/null || fail "reinstall failed"
  printf '\n# adapter tampered\n' >> "$adapter_copy"
  fm_custom_check_registered "$state" sssf-planning \
    || fail "mutating the adapter should not disturb the check registration"
  out=$(PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$state" FM_TEST_FEED="$FEED" \
    bash "$state/sssf-planning.check.sh")
  assert_contains "$out" 'security failure=adapter-drift' \
    "a mutated adapter must be refused by the still-registered check"
  assert_absent "$state/sssf-planning.pending" "a drifted adapter still produced a pending generation"
  pass "arming is gated, the watcher's content binding holds, and a mutated adapter inherits no authorization"
}

test_retirement_restores_pre_bridge_behavior() {
  local state adapter_copy leftovers
  state=$(new_state)
  adapter_copy=$(adapter_sandbox)
  write_feed "$(bootstrap_event plan-20260818-0001 1)"
  printf 'keep me\n' > "$state/unrelated.keep"

  ENABLE=1 adapter_exec "$adapter_copy" "$state" install >/dev/null || fail "install failed"
  run_adapter "$state" check >/dev/null || fail "check failed"
  run_adapter "$state" acknowledge plan-20260818-0001 >/dev/null || fail "acknowledge failed"
  run_adapter "$state" check >/dev/null || fail "post-acknowledge check failed"
  # A staging file left by a process killed mid-write is exactly the residue
  # retirement must not leave orphaned.
  printf 'orphan\n' > "$state/.sssf-planning-cursor.orphan"

  # NON-VACUITY: everything retirement must remove is present first.
  assert_present "$state/sssf-planning.check.sh" "fixture did not install a check"
  assert_present "$state/sssf-planning.check-trust" "fixture did not register the check"
  assert_present "$state/sssf-planning.cursor" "fixture did not establish a cursor"
  fm_custom_check_registered "$state" sssf-planning || fail "fixture check was not registered"

  adapter_exec "$adapter_copy" "$state" retire >/dev/null || fail "retire failed"

  assert_absent "$state/sssf-planning.check.sh" "retirement left the check behind"
  assert_absent "$state/sssf-planning.check-trust" "retirement left the registration behind"
  assert_absent "$state/sssf-planning.cursor" "retirement left the cursor behind"
  assert_absent "$state/sssf-planning.pending" "retirement left a pending generation behind"
  leftovers=$(find "$state" -maxdepth 1 -name '.sssf-planning-*' -print)
  [ -z "$leftovers" ] || fail "retirement left staging residue:"$'\n'"$leftovers"
  fm_custom_check_registered "$state" sssf-planning \
    && fail "a retired check is still registered for the watcher"

  # WATCHED RED: retirement is scoped. It removes this bridge, not the home.
  assert_present "$state/unrelated.keep" "retirement removed unrelated state"
  assert_present "$adapter_copy" "retirement removed the adapter itself"
  # And the bridge is genuinely reversible: arming again works from clean.
  ENABLE=1 adapter_exec "$adapter_copy" "$state" install >/dev/null \
    || fail "the bridge could not be re-armed after retirement"
  pass "retirement removes the check, cursor, and staging residue, leaves unrelated state, and is reversible"
}

test_watcher_lifecycle_remains_single_owner() {
  local state out started elapsed
  state=$(new_state)
  write_feed "$(bootstrap_event plan-20260818-0001 1)" "$(active_event plan-20260818-0100 2)"

  # Capturing through a command substitution is itself the no-daemon proof: the
  # substitution does not return until every writer to that pipe has closed it,
  # so a forked child inheriting stdout would hang this line rather than pass
  # it. Deliberately not pgrep, whose pattern would match this test script's own
  # argv and report a process that is the test itself.
  started=$(date +%s)
  out=$(run_adapter "$state" check) || fail "check exited nonzero"
  assert_contains "$out" 'sssf-planning pending' "check must have done real work"
  # One line, because the watcher turns check output into exactly one durable
  # wake record and a second line would corrupt that record's shape.
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "check emitted more than one wake line:"$'\n'"$out"

  # The failure path has its own emitter, so the same one-line guarantee is
  # asserted there rather than inferred from the pending path. It needs a state
  # with no pending generation: a published generation is answered before the
  # feed is ever read, which would make this assertion vacuous.
  state=$(new_state)
  out=$(FEED_UNREACHABLE=1 run_adapter "$state" check) || fail "failure-path check exited nonzero"
  [ -n "$out" ] || fail "the failure path produced no wake line at all"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ] \
    || fail "the failure path emitted more than one wake line:"$'\n'"$out"

  # And it is bounded: the watcher kills a check at FM_CHECK_TIMEOUT (30s by
  # default), so a poll that needed longer would be killed rather than reported.
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 30 ] || fail "the check took ${elapsed}s, at or past the watcher's per-check bound"

  # No watcher lifecycle state is written by the adapter: the existing watcher
  # remains the single owner of when this check runs.
  assert_absent "$state/.watch.lock" "the adapter wrote watcher lock state"
  assert_absent "$state/.wake-queue" "the adapter wrote the wake queue directly"
  assert_absent "$state/.last-watcher-beat" "the adapter wrote watcher liveness state"
  assert_absent "$state/.last-check" "the adapter drove the watcher's own check cadence"
  assert_no_task_state "$state" "watcher lifecycle"
  pass "the check is a bounded single-line poll that starts no process and owns no watcher lifecycle state"
}

test_silence_is_observed_and_not_an_absent_observation
test_bootstrap_synchronizes_and_creates_no_task
test_every_non_active_state_is_awareness_only
test_active_is_intake_eligible_but_creates_no_task
test_malformed_events_cannot_activate_work
test_stale_or_missing_authority_cannot_activate_work
test_continuity_mismatch_refuses_and_never_advances_the_cursor
test_acknowledgement_is_durable_and_ordered
test_duplicate_events_do_not_duplicate_effects
test_registered_check_trust_boundary_holds
test_retirement_restores_pre_bridge_behavior
test_watcher_lifecycle_remains_single_owner

fm_test_contract "$0" || exit 1

# Positive executed counts. "No failures" is satisfied by a suite that ran
# nothing, so the suite reports what it actually drove rather than what it
# failed to catch.
RUNS=$(wc -l < "$RUN_LOG" | tr -d ' ')
CHECKS=$(grep -c ' check$' "$RUN_LOG" || true)
PROPERTIES=$(compgen -A function | grep -c '^test_')
[ "$RUNS" -gt 0 ] && [ "$CHECKS" -gt 0 ] && [ "$PROPERTIES" -gt 0 ] \
  || fail "the suite reported success without executing anything"
printf 'all fm-sssf-planning-awareness tests passed: properties=%s adapter-invocations=%s feed-polls=%s\n' \
  "$PROPERTIES" "$RUNS" "$CHECKS"
