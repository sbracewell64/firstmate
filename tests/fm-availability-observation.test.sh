#!/usr/bin/env bash
# Behavior tests for three-valued availability observation
# (bin/fm-availability-lib.sh, bin/fm-model-verify.sh, bin/fm-route-lib.sh).
#
# THE DEFECT THESE PIN. Two facts used to collapse into one recorded state:
# "the probe could not run" and "the probe ran and established the candidate is
# unavailable". The measured consequence was a routed model that is entitled and
# live recorded as unreachable, a single-candidate pool correctly refused, and a
# refusal carrying an EMPTY reason - a failure that cannot say why is a failure
# nobody can repair.
#
# The properties worth having, and what each is red for:
#
#   1. THE MAP IS TOTAL AND THREE-VALUED. Every probe shape reaches exactly one
#      of AVAILABLE / UNAVAILABLE / UNOBSERVABLE, and a shape nobody wired up
#      reaches the third rather than a convenient one of the first two.
#   2. THE THREE LAND IN DIFFERENT RECORDS. A positive observation holds
#      nothing; a negative one records a hold through the SUPPORTED writer in
#      its closed vocabulary; a could-not-observe records a TOOLING_GAP and no
#      hold, because a broken reader is not a provider fact.
#   3. ROUTING STAYS FAIL-CLOSED. UNOBSERVABLE is never silently eligible, and a
#      single-candidate pool blocked by one fails closed with an explicit reason
#      naming the reader to repair - not with a hold nobody can release.
#   4. NO REASON IS EVER EMPTY. Both the reported line and the recorded evidence
#      carry text even when the reader itself printed nothing.
#   5. THE RECURRENCE PROBE IS RED-CAPABLE. The last case reintroduces the
#      permitting mechanism in a controlled copy and REQUIRES the probe to fail
#      against it, so a probe that could never go red fails loudly instead of
#      passing forever.
#
# Every probe here runs against a fake harness on PATH, so no case issues a live
# request or spends a token on a metered provider.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VERIFY="$ROOT/bin/fm-model-verify.sh"
ROUTE="$ROOT/bin/fm-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-availability-observation)

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A fake reader whose response shape is chosen by FAKE_PI_MODE, so each of the
# four measured probe shapes plus a structural failure and a silent one can be
# produced deterministically and for free.
write_fake_reader() {  # <bindir>
  cat > "$1/pi" <<'SH'
#!/usr/bin/env bash
case "${FAKE_PI_MODE:-ok}" in
  ok)       echo ok; exit 0 ;;
  refused)  echo "model is not supported when using a Pro account"; exit 1 ;;
  unknown)  echo "model not found for provider vendor"; exit 1 ;;
  client)   echo "Unknown provider vendr"; exit 1 ;;
  weird)    echo "the reader died in a way nobody classified"; exit 1 ;;
  silent)   exit 1 ;;
  hang)     sleep 10; echo ok; exit 0 ;;
esac
SH
  chmod +x "$1/pi"
}

# A home with one routed pool. Its size is the point in several cases: a
# single-candidate required-capability pool is where a could-not-observe stops a
# route outright, which is the exact shape the measured incident took.
make_home() {  # <name> [second-pool-member]
  local name=$1 second=${2:-} home bindir pool models
  home="$TMP_ROOT/$name/home"
  bindir="$TMP_ROOT/$name/bin"
  mkdir -p "$home/config" "$home/state" "$home/data" "$bindir"
  write_fake_reader "$bindir"
  pool='["vendor/only"]'
  models='"vendor/only": { "smart_zone": 140000, "effort_expressible": ["low"], "tool_loop": "verified-agentic" }'
  if [ -n "$second" ]; then
    pool='["vendor/only", "vendor/spare"]'
    models="$models,"'"vendor/spare": { "smart_zone": 140000, "effort_expressible": ["low"], "tool_loop": "verified-agentic" }'
  fi
  cat > "$home/config/crew-dispatch.json" <<JSON
{
  "_floors": { "F-ONE": { "effort_floor": "low", "context_ceiling": 100000, "tool_loop": "verified-agentic" } },
  "_models": { $models },
  "rules": [ { "when": "the only rule", "route": "R-ONE", "floor": "F-ONE",
               "use": { "harness": "pi", "model": "vendor/only", "effort": "low" },
               "pool": $pool } ]
}
JSON
  cat > "$home/config/models.json" <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": { "vendor": { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" } },
  "models": {
    "vendor/only":  { "provider": "vendor", "model_id": "only",  "harness": "pi",
                      "cost_class": "subscription-flat", "status": "approved-primary" },
    "vendor/spare": { "provider": "vendor", "model_id": "spare", "harness": "pi",
                      "cost_class": "subscription-flat", "status": "approved-fallback" }
  }
}
JSON
  printf '%s\n' "$home|$bindir"
}

read_home() {  # <record>
  HOME_DIR=${1%%|*}
  BIN_DIR=${1##*|}
}

# One sweep against the fake reader. PATH is reduced to the fake reader plus the
# system directories, so nothing here can reach a real harness by accident.
run_sweep() {  # <home> <bindir> <mode> [extra args...]
  local home=$1 bindir=$2 mode=$3
  shift 3
  env -u FM_ROOT_OVERRIDE PATH="$bindir:/usr/bin:/bin:/usr/local/bin" \
      FM_HOME="$home" FAKE_PI_MODE="$mode" "$VERIFY" --all "$@" 2>&1
}

run_route() {  # <home> <args...>
  local home=$1
  shift
  env -u FM_ROOT_OVERRIDE FM_HOME="$home" "$ROUTE" "$@" 2>&1
}

observation_of() {  # <home> <model>
  jq -r --arg m "$2" '.models[$m].observation // "ABSENT"' \
    "$1/state/model-observation.json" 2>/dev/null || printf 'UNREADABLE\n'
}

# ---------------------------------------------------------------------------
# 1. The map is total and three-valued
# ---------------------------------------------------------------------------

test_every_probe_shape_maps_to_exactly_one_of_three_observations() {
  local out
  out=$(bash -c '
    . "'"$ROOT"'/bin/fm-availability-lib.sh"
    for s in ok entitlement-refused unknown-model client-error timeout unprobeable; do
      printf "%s=%s\n" "$s" "$(fm_availability_from_shape "$s" 2>/dev/null)"
    done
    # A shape no arm names must reach the third value by the DEFAULT arm rather
    # than a convenient one of the other two. This is the case that decides
    # whether the map is total or merely long.
    printf "novel=%s\n" "$(fm_availability_from_shape a-shape-nobody-wired-up 2>/dev/null)"
    printf "empty=%s\n" "$(fm_availability_from_shape "" 2>/dev/null)"
  ')
  assert_contains "$out" "ok=AVAILABLE" "a successful probe must establish AVAILABLE"
  assert_contains "$out" "entitlement-refused=UNAVAILABLE" "a server-side refusal positively establishes unavailability"
  assert_contains "$out" "unknown-model=UNAVAILABLE" "an unrecognised model identity positively establishes unavailability"
  # The one the model-onboarding skill is explicit about: the request never left
  # the machine, so it is a configuration error HERE and never a provider fact.
  assert_contains "$out" "client-error=UNOBSERVABLE" \
    "a client-side failure must never be recorded as a provider outage"
  assert_contains "$out" "timeout=UNOBSERVABLE" "a probe that never returned established nothing"
  assert_contains "$out" "unprobeable=UNOBSERVABLE" "a reader that could not run established nothing"
  assert_contains "$out" "novel=UNOBSERVABLE" "an unmapped shape must default to could-not-observe"
  assert_contains "$out" "empty=UNOBSERVABLE" "an empty shape must default to could-not-observe"
  assert_not_contains "$out" "novel=AVAILABLE" "an unmapped shape must never read as available"
  assert_not_contains "$out" "novel=UNAVAILABLE" "an unmapped shape must never read as a provider fact"
  pass "every probe shape maps to exactly one of three observations, and an unmapped one defaults to could-not-observe"
}

test_the_observation_type_is_the_fleets_one_three_valued_type() {
  local out rc
  out=$(bash -c '
    . "'"$ROOT"'/bin/fm-verify-lib.sh"
    . "'"$ROOT"'/bin/fm-availability-lib.sh"
    for v in AVAILABLE UNAVAILABLE UNOBSERVABLE; do
      r=$(fm_availability_to_verify_result "$v")
      printf "%s->%s->%s\n" "$v" "$r" "$(fm_availability_from_verify_result "$r")"
    done
    fm_availability_to_verify_result NOT_A_VALUE >/dev/null 2>&1 || printf "refused-unknown-value\n"
  ')
  assert_contains "$out" "AVAILABLE->PASS->AVAILABLE" "AVAILABLE must round-trip through the fleet observation type"
  assert_contains "$out" "UNAVAILABLE->FAIL->UNAVAILABLE" "UNAVAILABLE must round-trip through the fleet observation type"
  assert_contains "$out" "UNOBSERVABLE->NO_VERIFIER_RAN->UNOBSERVABLE" \
    "could-not-observe must round-trip onto the fleet's own could-not-observe value"
  assert_contains "$out" "refused-unknown-value" "a value outside the type must be refused rather than guessed"

  # And the consumer rule is the SAME code, not a copy of it: a two-branch read,
  # and a read that routes could-not-observe into the pass or fail handler, are
  # both refused by bin/fm-verify-lib.sh's own exhaustiveness check.
  out=$(bash -c '
    . "'"$ROOT"'/bin/fm-verify-lib.sh"
    . "'"$ROOT"'/bin/fm-availability-lib.sh"
    yes_() { echo handled-available; }; no_() { echo handled-unavailable; }
    gap_() { echo handled-unobservable; }
    fm_availability_case UNOBSERVABLE reader detail yes_ no_ gap_
    fm_availability_case UNOBSERVABLE reader detail yes_ no_ 2>&1
    fm_availability_case UNOBSERVABLE reader detail yes_ no_ yes_ 2>&1
  '); rc=$?
  assert_contains "$out" "handled-unobservable" "an exhaustive consumer must reach the could-not-observe handler"
  assert_contains "$out" "consumer must handle all three" "a two-branch consumer must be refused"
  assert_contains "$out" "not coercible" "a consumer that folds could-not-observe into another handler must be refused"
  pass "the availability observation is the fleet's one three-valued type, consumed through its one exhaustiveness rule"
}

# ---------------------------------------------------------------------------
# 2. The three observations land in different records
# ---------------------------------------------------------------------------

test_a_positive_probe_records_available_and_holds_nothing() {
  local rec out
  rec=$(make_home available); read_home "$rec"
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" ok)
  [ -z "$out" ] || fail "a healthy sweep must print nothing, printed: $out"
  [ "$(observation_of "$HOME_DIR" vendor/only)" = AVAILABLE ] \
    || fail "a successful probe must record AVAILABLE"
  # A positive observation is not an admission and not a release. It only fails
  # to exclude, so a stale positive can never override a fresh negative.
  assert_absent "$HOME_DIR/state/model-health.json" \
    "a successful probe must record no hold at all - the hold record is negative-only"
  out=$(run_route "$HOME_DIR" eligible --route R-ONE)
  assert_contains "$out" "vendor/only" "an available candidate must stay eligible"
  pass "a positive probe records AVAILABLE and holds nothing"
}

test_a_server_refusal_records_unavailable_through_the_supported_writer() {
  local rec out state
  rec=$(make_home refused); read_home "$rec"
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" refused)
  assert_contains "$out" "REFUSED by the provider" "a server-side refusal must be reported as a provider fact"
  assert_not_contains "$out" "TOOLING_GAP" "a probe that ran and answered is not a broken reader"
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNAVAILABLE ] \
    || fail "a server-side refusal must record UNAVAILABLE"
  # The hold has to be in the CLOSED vocabulary the routing policy's own
  # failover conditions set, because a state nobody defined is a hold nobody can
  # report on - which is precisely what the foreign-schema writer produced.
  assert_present "$HOME_DIR/state/model-health.json" "an established unavailability must record a hold"
  state=$(jq -r '.models["vendor/only"].state' "$HOME_DIR/state/model-health.json")
  [ "$state" = auth_failure ] || fail "expected the closed-vocabulary state auth_failure, recorded '$state'"
  [ "$(jq -r '.schema' "$HOME_DIR/state/model-health.json")" = fm-model-health.v1 ] \
    || fail "the hold must be written in the supported writer's own schema"
  [ "$(jq -r '.models["vendor/only"].evidence' "$HOME_DIR/state/model-health.json")" != "" ] \
    || fail "a hold must carry the observed reason"
  out=$(run_route "$HOME_DIR" check --route R-ONE --model vendor/only --effort low)
  assert_contains "$out" "FM_SPAWN_ROUTE_MODEL_HELD" "an established unavailability must refuse as a hold"
  pass "a server refusal records UNAVAILABLE and a closed-vocabulary hold through the supported writer"
}

test_a_broken_reader_records_a_tooling_gap_and_never_a_hold() {
  local rec out gap
  rec=$(make_home gap); read_home "$rec"
  # The reader is not on PATH at all: the probe could not execute.
  out=$(env -u FM_ROOT_OVERRIDE PATH="/usr/bin:/bin:/usr/local/bin" FM_HOME="$HOME_DIR" \
        "$VERIFY" --all 2>&1)
  assert_contains "$out" "TOOLING_GAP" "a reader that could not run must be reported as repairable work"
  assert_contains "$out" "not a provider fact" "the report must say plainly that this is not a fact about the model"
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNOBSERVABLE ] \
    || fail "a reader that could not run must record UNOBSERVABLE"
  # And no hold, because a hold sends an operator to release it and releasing
  # changes nothing while the reader is still broken.
  assert_absent "$HOME_DIR/state/model-health.json" \
    "a could-not-observe must never be recorded as an availability hold"
  # The evidence has to be enough to REPAIR the reader without rediscovering it.
  gap=$(jq -c '.models["vendor/only"].tooling_gap' "$HOME_DIR/state/model-observation.json")
  assert_contains "$gap" '"reason_code":"TOOLING_GAP"' "the gap must carry the closed-vocabulary reason code"
  assert_contains "$gap" '"candidate":"vendor/only"' "the gap must name the candidate"
  assert_contains "$gap" '"requested_observation":"entitlement-and-liveness"' \
    "the gap must name the observation that was requested"
  assert_contains "$gap" '"failure_class":"unprobeable"' "the gap must name the failure class"
  assert_contains "$gap" '"affected_routes":["R-ONE"]' "the gap must name the routing decisions it is blocking"
  assert_contains "$gap" 'fm-model-verify.sh' "the gap must name the reader that failed"
  [ "$(printf '%s' "$gap" | jq -r '.failure_evidence | length > 0')" = true ] \
    || fail "the gap must carry failure evidence"
  [ "$(printf '%s' "$gap" | jq -r '.at | length > 0')" = true ] || fail "the gap must carry a timestamp"
  pass "a broken reader records a repairable TOOLING_GAP and never an availability hold"
}

test_a_structurally_failed_reader_is_not_narrowed_into_unavailable() {
  local rec out
  rec=$(make_home unclassified); read_home "$rec"
  # A non-zero exit whose output matches no known provider response. The
  # tempting narrowing is "it failed, so the model is unavailable" - which
  # fabricates a provider fact out of a reader that told us nothing.
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" weird)
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNOBSERVABLE ] \
    || fail "an unclassified reader failure must not be narrowed into UNAVAILABLE"
  assert_absent "$HOME_DIR/state/model-health.json" "an unclassified failure must record no hold"
  assert_contains "$out" "TOOLING_GAP" "an unclassified failure must be reported as repairable work"

  # The same for a client-side failure, which the model-onboarding skill calls a
  # configuration error on this machine rather than a provider fact.
  rec=$(make_home clienterr); read_home "$rec"
  run_sweep "$HOME_DIR" "$BIN_DIR" client >/dev/null
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNOBSERVABLE ] \
    || fail "a local configuration error must never be recorded as a provider outage"
  assert_absent "$HOME_DIR/state/model-health.json" "a local configuration error must record no hold"
  pass "a structurally failed or client-side reader failure is could-not-observe, never a fabricated provider fact"
}

test_a_sweep_timeout_records_every_unfinished_probe() {
  local rec out gap
  rec=$(make_home sweep-timeout); read_home "$rec"
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" hang --timeout 1)
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNOBSERVABLE ] \
    || fail "a probe killed by the sweep ceiling disappeared instead of recording UNOBSERVABLE"
  assert_contains "$out" "TOOLING_GAP" "a sweep timeout must report the broken observation path"
  assert_contains "$out" "sweep exceeded its 1s total ceiling" \
    "a sweep timeout must identify the ceiling that stopped the probe"
  gap=$(jq -c '.models["vendor/only"].tooling_gap' "$HOME_DIR/state/model-observation.json")
  assert_contains "$gap" '"failure_class":"timeout"' "the tooling gap must classify the sweep timeout"
  assert_contains "$gap" '"candidate":"vendor/only"' "the tooling gap must retain the unfinished candidate"
  pass "a sweep timeout records every unfinished probe as an UNOBSERVABLE tooling gap"
}

# ---------------------------------------------------------------------------
# 3. Routing stays fail-closed
# ---------------------------------------------------------------------------

test_unobservable_is_never_eligible_and_the_refusal_names_the_reader() {
  local rec out rc
  rec=$(make_home noteligible spare); read_home "$rec"
  # Only the first pool member is broken, so a substitute exists and the
  # exclusion cannot be confused with an exhausted pool.
  env -u FM_ROOT_OVERRIDE PATH="/usr/bin:/bin:/usr/local/bin" FM_HOME="$HOME_DIR" \
      "$VERIFY" --model vendor/only >/dev/null 2>&1
  out=$(run_route "$HOME_DIR" eligible --route R-ONE); rc=$?
  expect_code 0 "$rc" "a pool with one eligible member must still answer"
  assert_not_contains "$out" "vendor/only" "an UNOBSERVABLE candidate must never be silently eligible"
  assert_contains "$out" "vendor/spare" "the unobserved candidate must not remove the rest of the pool"

  out=$(run_route "$HOME_DIR" check --route R-ONE --model vendor/only --effort low); rc=$?
  expect_code 1 "$rc" "a dispatch to an UNOBSERVABLE candidate must be refused"
  assert_contains "$out" "FM_SPAWN_ROUTE_MODEL_UNOBSERVED" "the stable refusal token is missing"
  assert_contains "$out" "fm-model-verify.sh" "the refusal must name the reader that failed"
  assert_contains "$out" "unprobeable" "the refusal must name the failure class"
  assert_contains "$out" "TOOLING_GAP" "the refusal must point at the repair work"
  # The distinction is the whole point: reporting this as a hold sends an
  # operator to release something that was never what excluded the candidate.
  assert_not_contains "$out" "FM_SPAWN_ROUTE_MODEL_HELD" \
    "a could-not-observe must not be reported as an availability hold"
  assert_contains "$out" "no hold is what is excluding this candidate" \
    "the refusal must say explicitly that releasing a hold will not help"
  assert_contains "$out" "in pool order (vendor/spare)" "the refusal must name the substitute inside the pool"
  pass "an UNOBSERVABLE candidate is never eligible and the refusal names the reader rather than a hold"
}

test_a_single_candidate_pool_fails_closed_with_an_explicit_reason() {
  local rec out rc
  rec=$(make_home terminal); read_home "$rec"
  env -u FM_ROOT_OVERRIDE PATH="/usr/bin:/bin:/usr/local/bin" FM_HOME="$HOME_DIR" \
      "$VERIFY" --model vendor/only >/dev/null 2>&1
  out=$(run_route "$HOME_DIR" eligible --route R-ONE); rc=$?
  # This IS the measured incident, and blocking is the CORRECT behaviour. What
  # was wrong was the reason, not the refusal, so the assertions are about what
  # the stop says rather than about whether it stops.
  expect_code 3 "$rc" "a single-candidate pool whose only candidate is unobservable must stop"
  assert_contains "$out" "FM_ROUTE_NO_CANDIDATE" "the terminal stop token is missing"
  assert_contains "$out" "UNOBSERVABLE" "the terminal report must name the observation"
  assert_contains "$out" "fm-model-verify.sh" "the terminal report must name the reader to repair"
  assert_contains "$out" "do not lower the floor" "the terminal report must forbid degrading the floor"
  assert_not_contains "$out" "held " "an unobserved candidate must not be reported as held"

  out=$(run_route "$HOME_DIR" check --route R-ONE --model vendor/only --effort low); rc=$?
  expect_code 1 "$rc" "the single-candidate refusal must also refuse the direct dispatch"
  assert_contains "$out" "repair observability rather than making uncertainty permissive" \
    "the refusal must state the permanent fix rather than inviting a workaround"
  pass "a single-candidate pool blocked by a broken reader fails closed with an explicit, repairable reason"
}

test_an_unreadable_observation_record_refuses_and_names_the_right_file() {
  local rec out rc
  rec=$(make_home unreadable); read_home "$rec"
  run_sweep "$HOME_DIR" "$BIN_DIR" ok >/dev/null
  printf '{"models":{"vendor/only"' > "$HOME_DIR/state/model-observation.json"
  out=$(run_route "$HOME_DIR" eligible --route R-ONE); rc=$?
  expect_code 2 "$rc" "an unreadable observation record must refuse rather than read as an empty one"
  assert_contains "$out" "FM_ROUTE_OBSERVATION_UNREADABLE" "the stable token for this input is missing"
  assert_contains "$out" "model-observation.json" "the refusal must name the file that could not be read"
  # The three inputs fail independently and are repaired differently, so a
  # refusal that points at a file which parses perfectly costs the diagnosis.
  assert_contains "$out" "neither the routing config nor the availability record" \
    "the refusal must rule out the two inputs that did parse"
  pass "an unreadable observation record refuses and names itself rather than the inputs that parsed"
}

test_a_foreign_hold_entry_is_reported_with_its_repair_rather_than_reinterpreted() {
  local rec out rc
  rec=$(make_home foreign); read_home "$rec"
  # Exactly the shape the unsupported second writer produced: a probe-observation
  # schema merged into the negative-only hold register, where an entry's mere
  # presence is the hold. The measured absurdity is preserved here - the entry
  # says the model is "available" while excluding it.
  cat > "$HOME_DIR/state/model-health.json" <<'JSON'
{"models":{"vendor/only":{"shape":"ok","state":"available","detail":"ok"}},"providers":{}}
JSON
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" ok)
  assert_contains "$out" "not an availability state this fleet defines" \
    "a foreign hold entry must be reported rather than absorbed"
  assert_contains "$out" "availability release vendor/only" \
    "the report must name the supported command that repairs it"
  # Detect-only: reinterpreting it here would re-admit a candidate nothing
  # cleared, so it keeps excluding and the repair stays an explicit decision.
  out=$(run_route "$HOME_DIR" eligible --route R-ONE); rc=$?
  expect_code 3 "$rc" "a foreign entry must keep failing closed until it is released"
  assert_contains "$out" "FM_ROUTE_NO_CANDIDATE" "the foreign entry must still exclude the candidate"
  out=$(run_route "$HOME_DIR" availability release vendor/only)
  assert_contains "$out" "released model vendor/only" "the supported writer must be able to clear it"
  out=$(run_route "$HOME_DIR" eligible --route R-ONE)
  assert_contains "$out" "vendor/only" "releasing the foreign entry must restore the candidate"
  pass "a foreign hold entry is reported with its supported repair and never silently reinterpreted"
}

# ---------------------------------------------------------------------------
# 4. No reason is ever empty
# ---------------------------------------------------------------------------

test_a_failure_that_cannot_say_why_is_itself_refused() {
  local rec out detail
  rec=$(make_home silent); read_home "$rec"
  # A reader that exits non-zero and prints NOTHING. The record format used to
  # print absent numeric fields as consecutive tabs, and because tab is an IFS
  # whitespace character bash's `read` collapsed the run into one delimiter, so
  # the detail landed in the wrong variable and the reported reason was empty.
  out=$(run_sweep "$HOME_DIR" "$BIN_DIR" silent)
  assert_contains "$out" "TOOLING_GAP" "a silent reader failure must still be reported"
  # A reader that printed nothing must SAY that, rather than leave the reason
  # blank and let the reader of the report guess what happened.
  assert_contains "$out" "the reader exited without producing any output" \
    "a reader that produced no output must still state why there is no reason"
  detail=$(jq -r '.models["vendor/only"].tooling_gap.failure_evidence' \
    "$HOME_DIR/state/model-observation.json")
  case "$detail" in
    ''|null) fail "the recorded gap evidence is empty, so nobody could repair the reader" ;;
    *'without producing any output'*) : ;;
    *) fail "the recorded gap evidence does not describe the silent reader: $detail" ;;
  esac

  # And the arity, which is where the collapse actually fired: a result whose
  # numeric fields are BOTH absent used to be written as three consecutive tabs,
  # and `read` folded them into one delimiter, so the reason arrived in the rc
  # field and the reason field arrived empty. Two assertions pin that: rc must
  # still be a number or a dash rather than prose, and the reason must still
  # reach the evidence field.
  rec=$(make_home arity); read_home "$rec"
  out=$(env -u FM_ROOT_OVERRIDE PATH="/usr/bin:/bin:/usr/local/bin" FM_HOME="$HOME_DIR" \
        "$VERIFY" --all 2>&1)
  printf '%s\n' "$out" | grep -qE 'rc=(-|[0-9]+),' \
    || fail "the rc field carries prose rather than a number or a dash, so the record's fields have shifted: $out"
  detail=$(jq -r '.models["vendor/only"].tooling_gap.failure_evidence' \
    "$HOME_DIR/state/model-observation.json")
  case "$detail" in
    *'is not installed on this machine'*) : ;;
    *) fail "a result with no rc and no latency lost its reason on the way to the record: got '$detail'" ;;
  esac
  pass "a failure that cannot say why is refused: every could-not-observe carries a reason and recorded evidence"
}

# ---------------------------------------------------------------------------
# 5. The recurrence probe is red-capable
# ---------------------------------------------------------------------------

# The two probes, each written once so the same assertion can be run against the
# real code and against a deliberately collapsed copy of it.
#
# PRODUCER: a reader that cannot execute must record could-not-observe, never
# one of the two values that assert a fact about the model.
recurrence_probe_producer() {  # <bindir-under-test> <home>
  env -u FM_ROOT_OVERRIDE PATH="/usr/bin:/bin:/usr/local/bin" FM_HOME="$2" \
      "$1/fm-model-verify.sh" --all >/dev/null 2>&1
  [ "$(observation_of "$2" vendor/only)" = UNOBSERVABLE ]
}

# CONSUMER: a candidate whose observation failed must not be eligible.
recurrence_probe_consumer() {  # <bindir-under-test> <home>
  local out
  out=$(env -u FM_ROOT_OVERRIDE FM_HOME="$2" "$1/fm-route.sh" eligible --route R-ONE 2>&1)
  ! printf '%s\n' "$out" | grep -q '^vendor/only$'
}

# A copy of bin/ with one collapsing override APPENDED to the availability
# library. Appending a redefinition overrides the earlier one without matching
# any source text, so a refactor cannot make the mutation silently miss - and if
# the mutation ever fails to change behaviour the caller below fails loudly
# rather than reporting a probe that can never go red.
make_collapsed_bin() {  # <name> <override-body>
  local dir="$TMP_ROOT/$1-bin"
  rm -rf "$dir"
  cp -R "$ROOT/bin" "$dir"
  printf '\n%s\n' "$2" >> "$dir/fm-availability-lib.sh"
  printf '%s\n' "$dir"
}

# shellcheck disable=SC2016 # The override bodies are shell SOURCE appended to a
# copied library, so their $-names must reach that file unexpanded.
test_the_recurrence_probe_turns_red_when_the_permitting_mechanism_returns() {
  local rec real mutant

  # First: both probes must PASS against the shipped code. A probe that is red
  # everywhere proves nothing about the mechanism.
  rec=$(make_home recurrence-real); read_home "$rec"
  recurrence_probe_producer "$ROOT/bin" "$HOME_DIR" \
    || fail "the producer probe must pass against the shipped reader"
  recurrence_probe_consumer "$ROOT/bin" "$HOME_DIR" \
    || fail "the consumer probe must pass against the shipped router"

  # Collapse A, the PRODUCER: the reader maps a could-not-observe onto a
  # positive fact - the exact narrowing that turned a broken claude probe into a
  # recorded state, and the one an over-eager fix would reintroduce.
  mutant=$(make_collapsed_bin producer 'fm_availability_from_shape() { printf "%s\n" "$FM_AVAIL_AVAILABLE"; }')
  rec=$(make_home recurrence-producer); read_home "$rec"
  if recurrence_probe_producer "$mutant" "$HOME_DIR"; then
    fail "the producer probe stayed green while the reader recorded a broken probe as AVAILABLE, so it is not red-capable"
  fi
  [ "$(observation_of "$HOME_DIR" vendor/only)" = AVAILABLE ] \
    || fail "the controlled collapse did not take effect, so this control proved nothing"

  # Collapse A again, the other direction: narrowing a could-not-observe onto a
  # fabricated provider fact is equally wrong and equally must go red.
  mutant=$(make_collapsed_bin producer-neg 'fm_availability_from_shape() { printf "%s\n" "$FM_AVAIL_UNAVAILABLE"; }
fm_availability_hold_state() { printf "model_unavailable\n"; }')
  rec=$(make_home recurrence-producer-neg); read_home "$rec"
  if recurrence_probe_producer "$mutant" "$HOME_DIR"; then
    fail "the producer probe stayed green while a could-not-observe was recorded as UNAVAILABLE, so it is not red-capable"
  fi
  [ "$(observation_of "$HOME_DIR" vendor/only)" = UNAVAILABLE ] \
    || fail "the controlled collapse did not take effect, so this control proved nothing"

  # Collapse B, the CONSUMER: routing stops excluding on a failed observation,
  # which is the "make uncertainty permissive" fix the commission forbids.
  real=$(make_collapsed_bin consumer 'fm_availability_unobserved_active() { printf "%s\n" "{\"models\":{}}"; }')
  rec=$(make_home recurrence-consumer); read_home "$rec"
  recurrence_probe_producer "$ROOT/bin" "$HOME_DIR" \
    || fail "the fixture must record a failed observation before the consumer collapse is meaningful"
  if recurrence_probe_consumer "$real" "$HOME_DIR"; then
    fail "the consumer probe stayed green while routing treated an UNOBSERVABLE candidate as eligible, so it is not red-capable"
  fi
  pass "the recurrence probe turns red when either half of the permitting mechanism is reintroduced"
}

test_every_probe_shape_maps_to_exactly_one_of_three_observations
test_the_observation_type_is_the_fleets_one_three_valued_type
test_a_positive_probe_records_available_and_holds_nothing
test_a_server_refusal_records_unavailable_through_the_supported_writer
test_a_broken_reader_records_a_tooling_gap_and_never_a_hold
test_a_structurally_failed_reader_is_not_narrowed_into_unavailable
test_a_sweep_timeout_records_every_unfinished_probe
test_unobservable_is_never_eligible_and_the_refusal_names_the_reader
test_a_single_candidate_pool_fails_closed_with_an_explicit_reason
test_an_unreadable_observation_record_refuses_and_names_the_right_file
test_a_foreign_hold_entry_is_reported_with_its_repair_rather_than_reinterpreted
test_a_failure_that_cannot_say_why_is_itself_refused
test_the_recurrence_probe_turns_red_when_the_permitting_mechanism_returns
