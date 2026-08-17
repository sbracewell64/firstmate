#!/usr/bin/env bash
# Behavior tests for the ROLE QUALIFICATION register - bin/fm-qualification-lib.sh,
# bin/fm-qualification.sh, qualifications/schema.json and the shipped contracts.
#
# The guarantee under test is a vocabulary, not a feature. Missing qualification
# used to be the same value as incapability, and that single collapse is what
# turned "nobody has qualified a candidate yet" into a captain floor-exception
# request. So these cases pin the five values apart and pin every conversion
# between them:
#
#   1. FIVE VALUES, NEVER FEWER. QUALIFIED, FAILED, QUALIFICATION_REQUIRED,
#      QUALIFICATION_STALE and COULD_NOT_OBSERVE each reach a reader as itself,
#      with its own exit status. Missing is never FAILED, stale is never FAILED,
#      and could-not-observe is never either one and never a pass.
#   2. FRESHNESS IS DECLARED. A change to a dependency a record NAMES invalidates
#      it; a change to any other byte in the repository does not. Both directions
#      are asserted, because a register that went stale on every commit would be
#      one nobody could rely on.
#   3. A STATE IS NEVER STORED. A record carrying a hand-written state, a synonym
#      for a result, or an estimated measurement is INADMISSIBLE, and an
#      inadmissible record is could-not-observe rather than a pass.
#   4. THE AXES STAY APART. A maker never reviews its own candidate; design
#      challenge and exact-change review are separate capabilities that must each
#      be held; and a contract that names a vendor is refused, because a contract
#      that names who does the job cannot be re-run against the next candidate.
#
# Every check that can be vacuous runs a negative control FIRST and must be
# observed red there, so a pass on the real register is evidence the check fires.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUAL="$ROOT/bin/fm-qualification.sh"
TMP_ROOT=$(fm_test_tmproot fm-qualification)

command -v jq >/dev/null 2>&1 || fail "fm-qualification: jq is required"

if command -v sha256sum >/dev/null 2>&1; then
  QUAL_ACTIVATION_ID=$(printf '%s\0%s\0%s\0%s' job-maker alpha/one pi high | sha256sum | awk '{print "qualify-" substr($1,1,40)}')
else
  QUAL_ACTIVATION_ID=$(printf '%s\0%s\0%s\0%s' job-maker alpha/one pi high | shasum -a 256 | awk '{print "qualify-" substr($1,1,40)}')
fi

# --- fixture -----------------------------------------------------------------
#
# A self-contained register in temp dirs, so no case reads or writes the shipped
# one except the two that deliberately assert against it.

HOME_DIR="$TMP_ROOT/home"
CDIR="$TMP_ROOT/contracts"
RDIR="$TMP_ROOT/records"
NO_OVERLAY="$TMP_ROOT/absent-overlay"
DEP_FILE="$HOME_DIR/data/fixture/MANIFEST.json"
UNRELATED="$HOME_DIR/data/fixture/UNRELATED.txt"

FAKEBIN="$TMP_ROOT/fakebin"

mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data/fixture" "$CDIR" "$RDIR" "$FAKEBIN"
# A faithful tasks-axi, on PATH for every invocation. Without it these cases would
# reach the REAL binary and whatever backlog its config resolved to, which is both
# a hazard and the vacuity that hid total non-function for five review rounds.
fm_fake_tasks_axi "$FAKEBIN" "$TMP_ROOT/tasks-axi.log"
printf 'some-work queued\n' >> "$TMP_ROOT/tasks-axi.store"
printf '{"package":"job-fixture","version":"1.0.0"}\n' > "$DEP_FILE"
printf 'this byte is not a declared dependency of anything\n' > "$UNRELATED"

dep_digest() { sha256sum "$DEP_FILE" | awk '{print $1}'; }

qual() {
  FM_HOME="$HOME_DIR" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_QUALIFICATION_CONTRACT_DIR="$CDIR" \
  FM_QUALIFICATION_RECORD_DIR="$RDIR" \
  FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
  PATH="$FAKEBIN:$PATH" \
    "$QUAL" "$@"
}

# write_contract <id> <role> <risk> <axis> <adjudication-required> [adjudicator]
write_contract() {
  local id=$1 role=$2 risk=$3 axis=$4 adj=$5 adjc=${6:-job-adjudicator}
  local adj_block='{"required": false, "why_not": "the oracle grades the candidate from outside it"}'
  local required_dependencies='["file_digest", "contract_version"]'
  [ "$id" != job-adjudicator ] || required_dependencies='["contract_version"]'
  [ "$adj" != yes ] || adj_block=$(printf '{"required": true, "adjudicator_contract": "%s", "independence_dimensions": ["binding"]}' "$adjc")
  cat > "$CDIR/$id.json" <<JSON
{
  "qualification_schema_version": 1,
  "id": "$id",
  "role": "$role",
  "risk_class": "$risk",
  "contract_version": "1.0.0",
  "axis": "$axis",
  "purpose": "A synthetic contract used only to pin the register vocabulary.",
  "grants": "Eligibility on a route whose floor declares this contract.",
  "does_not_grant": ["anything outside this exact contract"],
  "executable_predicate": {
    "kind": "fixture_oracle",
    "fixture": "job-fixture",
    "fixture_version": "1.0.0",
    "manifest_digest": "0000000000000000000000000000000000000000000000000000000000000000",
    "root": "home:data/fixture",
    "integrity": "verify-integrity.sh",
    "setup": "setup.sh job",
    "verify": "verify.sh job",
    "controls": "run-controls.sh"
  },
  "adjudication": $adj_block,
  "required_freshness_dependencies": $required_dependencies
}
JSON
}

# write_record <id> <jq-filter-applied-to-the-base>
write_record() {
  local id=$1 filter=${2:-.}
  jq --arg id "$id" --arg digest "$(dep_digest)" \
    '.id = $id | (.freshness_dependencies[] | select(.kind == "file_digest")).digest = $digest | '"$filter" \
    > "$RDIR/$id.json" <<'JSON'
{
  "qualification_schema_version": 1,
  "id": "placeholder",
  "contract": "job-maker",
  "contract_version": "1.0.0",
  "role": "JOB_MAKER",
  "risk_class": "job-risk-v1",
  "binding": {
    "provider": "alpha",
    "model": "alpha/one",
    "harness": "pi",
    "harness_version": "9.9.9",
    "native_effort": "high"
  },
  "fixture": { "identity": "job-fixture", "version": "1.0.0",
               "manifest_digest": "0000000000000000000000000000000000000000000000000000000000000000" },
  "result": "QUALIFIED",
  "result_evidence": "the deterministic oracle graded the corrected candidate and returned its pass",
  "measured_context": 120000,
  "observed_at": "2026-08-13",
  "adjudication": {
    "adjudicator_binding": "beta/two",
    "adjudicator_harness": "pi",
    "adjudicator_result": "QUALIFIED",
    "evidence": "the assignment-distinct evaluator graded the retained package"
  },
  "freshness_dependencies": [
    { "kind": "file_digest", "path": "home:data/fixture/MANIFEST.json", "digest": "placeholder" },
    { "kind": "contract_version", "version": "1.0.0" }
  ],
  "known_limitations": ["synthetic fixture material; it measures this contract and nothing wider"]
}
JSON
}

reset_register() {
  rm -f "$RDIR"/*.json "$CDIR"/*.json
  write_contract job-maker JOB_MAKER job-risk-v1 maker_qualification yes
  write_contract job-adjudicator JOB_ADJUDICATOR job-evidence-v1 exact_change_review no
  write_record job-adjudicator-record \
    '.contract = "job-adjudicator" | .role = "JOB_ADJUDICATOR" | .risk_class = "job-evidence-v1"
     | .binding.provider = "beta" | .binding.model = "beta/two"
     | .adjudication.adjudicator_binding = "zeta/nine"
     | .freshness_dependencies |= map(select(.kind != "file_digest"))'
  printf '{"package":"job-fixture","version":"1.0.0"}\n' > "$DEP_FILE"
}

state_of() {  # <contract> <model> [harness] [effort]
  qual state --contract "$1" --model "$2" \
    "${3:+--harness}" ${3:+"$3"} "${4:+--effort}" ${4:+"$4"} --json 2>/dev/null | jq -r '.state'
}

state_rc() {  # <contract> <model>
  local rc=0
  qual state --contract "$1" --model "$2" --json >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# --- the five values ---------------------------------------------------------

test_a_qualified_record_with_unchanged_dependencies_is_qualified() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] \
    || fail "a record whose declared dependencies are all unchanged did not read QUALIFIED"
  expect_code 0 "$(state_rc job-maker alpha/one)" "QUALIFIED exit status"
  pass "a qualified record with unchanged dependencies is QUALIFIED"
}

test_no_record_is_qualification_required_and_never_failed() {
  reset_register
  # Negative control: with a record present the same call is not REQUIRED, so the
  # assertion below is about absence rather than about the call always saying so.
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" != QUALIFICATION_REQUIRED ] \
    || fail "the control case already read QUALIFICATION_REQUIRED, so this case proves nothing"
  rm -f "$RDIR/alpha-one-job.json"
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = QUALIFICATION_REQUIRED ] \
    || fail "a binding with no record read $st instead of QUALIFICATION_REQUIRED"
  [ "$st" != FAILED ] || fail "missing evidence was reported as a failure"
  expect_code 3 "$(state_rc job-maker alpha/one)" "QUALIFICATION_REQUIRED exit status"
  local out
  out=$(qual state --contract job-maker --model alpha/one --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.excluded_by')" = null ] \
    || fail "missing evidence recorded an exclusion against the binding"
  pass "no record is QUALIFICATION_REQUIRED and never FAILED"
}

test_a_failed_record_reads_failed_and_preserves_its_evidence() {
  reset_register
  write_record alpha-one-job '.result = "FAILED" | .result_evidence = "the oracle rejected six required predicates"'
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = FAILED ] || fail "a recorded rejection read $st instead of FAILED"
  expect_code 1 "$(state_rc job-maker alpha/one)" "FAILED exit status"
  assert_contains "$(qual state --contract job-maker --model alpha/one 2>&1)" \
    "rejected six required predicates" "the exclusion evidence was not carried to the reader"
  assert_present "$RDIR/alpha-one-job.json" "the FAILED record was removed"
  pass "a failed record reads FAILED and preserves its evidence"
}

test_a_changed_declared_dependency_makes_a_pass_stale_and_never_failed() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] || fail "control: the record did not start QUALIFIED"
  printf '{"package":"job-fixture","version":"1.0.1"}\n' > "$DEP_FILE"
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = QUALIFICATION_STALE ] \
    || fail "a changed declared dependency read $st instead of QUALIFICATION_STALE"
  [ "$st" != FAILED ] || fail "stale evidence was reported as a failure"
  expect_code 3 "$(state_rc job-maker alpha/one)" "QUALIFICATION_STALE exit status"
  pass "a changed declared dependency makes a pass stale and never failed"
}

test_an_unrelated_byte_change_does_not_invalidate_a_record() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] || fail "control: the record did not start QUALIFIED"
  # Two unrelated changes: a file nothing declares, and a brand new file. Neither
  # is a declared dependency, so neither may change the answer.
  printf 'edited\n' >> "$UNRELATED"
  printf 'new\n' > "$HOME_DIR/data/fixture/ANOTHER.txt"
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] \
    || fail "an unrelated byte change invalidated a record whose declared dependencies were untouched"
  pass "an unrelated byte change does not invalidate a record"
}

test_an_unobservable_dependency_is_could_not_observe_and_not_a_pass() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] || fail "control: the record did not start QUALIFIED"
  rm -f "$DEP_FILE"
  local st out
  st=$(state_of job-maker alpha/one)
  [ "$st" = COULD_NOT_OBSERVE ] \
    || fail "an absent declared dependency read $st instead of COULD_NOT_OBSERVE"
  expect_code 4 "$(state_rc job-maker alpha/one)" "COULD_NOT_OBSERVE exit status"
  out=$(qual state --contract job-maker --model alpha/one --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.excluded_by')" = null ] \
    || fail "an unobservable dependency recorded an exclusion against the binding"
  assert_contains "$(qual state --contract job-maker --model alpha/one 2>&1)" \
    "an absent file is not an unchanged one" "the could-not-observe was not explained"
  pass "an unobservable dependency is could-not-observe and not a pass"
}

test_a_failed_record_reopens_only_on_a_material_change() {
  reset_register
  write_record alpha-one-job '.result = "FAILED" | .result_evidence = "the oracle rejected this candidate"'
  [ "$(state_of job-maker alpha/one)" = FAILED ] || fail "control: the record did not start FAILED"
  printf '{"package":"job-fixture","version":"2.0.0"}\n' > "$DEP_FILE"
  local st out
  st=$(state_of job-maker alpha/one)
  [ "$st" = QUALIFICATION_REQUIRED ] \
    || fail "a FAILED record whose declared dependency changed read $st; re-qualification on an evidenced material change is lawful"
  out=$(qual state --contract job-maker --model alpha/one --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.excluded_by')" = prior-failed-superseded-by-material-change ] \
    || fail "the superseded exclusion was not carried on the record"
  assert_present "$RDIR/alpha-one-job.json" "the prior FAILED record was removed rather than retained"
  pass "a failed record reopens only on a material change"
}

test_a_predicate_pass_without_adjudication_is_qualification_required() {
  reset_register
  write_record alpha-one-job '.adjudication.adjudicator_binding = null | .adjudication.adjudicator_result = "COULD_NOT_OBSERVE"'
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = QUALIFICATION_REQUIRED ] \
    || fail "a predicate pass with no assignment-distinct adjudication read $st instead of QUALIFICATION_REQUIRED"
  assert_contains "$(qual state --contract job-maker --model alpha/one 2>&1)" \
    "never certifies itself" "the reader was not told why the pass did not stand"
  pass "a predicate pass without adjudication is QUALIFICATION_REQUIRED"
}

test_an_unqualified_adjudicator_pass_is_not_consumed() {
  reset_register
  write_record alpha-one-job '.adjudication.adjudicator_binding = "fabricated/reviewer"'
  [ "$(state_of job-maker alpha/one)" = QUALIFICATION_REQUIRED ] \
    || fail "a fabricated adjudicator identity certified a maker"
  pass "an adjudicator pass must cross the qualification guard"
}

# --- the record key ----------------------------------------------------------

test_a_different_harness_or_effort_is_a_near_miss_not_a_match() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one pi high)" = QUALIFIED ] \
    || fail "control: the exact tuple did not read QUALIFIED"
  local st out
  st=$(state_of job-maker alpha/one pi low)
  [ "$st" = QUALIFICATION_REQUIRED ] \
    || fail "a different native effort read $st; a band nobody observed is not a stale observation of one they did"
  st=$(state_of job-maker alpha/one claude high)
  [ "$st" = QUALIFICATION_REQUIRED ] || fail "a different harness read $st instead of QUALIFICATION_REQUIRED"
  out=$(qual state --contract job-maker --model alpha/one --harness claude --effort high --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '[.near_miss[].record] | join(",")')" = alpha-one-job ] \
    || fail "the near-miss record was not reported, so 'no record' is indistinguishable from 'a record for another tuple'"
  pass "a different harness or effort is a near miss not a match"
}

test_a_different_harness_version_is_a_distinct_observation() {
  reset_register
  write_record alpha-one-job
  write_record alpha-one-new-version '.binding.harness_version = "10.0.0"'
  [ "$(qual state --contract job-maker --model alpha/one --harness pi --harness-version 9.9.9 --effort high --json 2>/dev/null | jq -r '.record')" = alpha-one-job ] \
    || fail "the exact harness-version tuple did not select its own observation"
  [ "$(qual state --contract job-maker --model alpha/one --harness pi --harness-version 10.0.0 --effort high --json 2>/dev/null | jq -r '.record')" = alpha-one-new-version ] \
    || fail "records differing only in harness version collapsed into one observation"
  pass "a different harness version is a distinct observation"
}

test_two_records_for_one_tuple_are_could_not_observe() {
  reset_register
  write_record alpha-one-job
  write_record alpha-one-job-again
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = COULD_NOT_OBSERVE ] \
    || fail "two records claiming one tuple read $st; which observation applies cannot be settled by filename order"
  assert_contains "$(qual state --contract job-maker --model alpha/one 2>&1)" \
    "supersession graph" "the duplicate was not named"
  pass "two records for one tuple are could-not-observe"
}

test_a_declared_supersession_selects_the_retained_successor() {
  reset_register
  write_record alpha-one-old '.result = "FAILED" | .result_evidence = "the earlier observation failed"'
  write_record alpha-one-new '.supersedes = "alpha-one-old"'
  local out
  out=$(qual state --contract job-maker --model alpha/one --harness pi --harness-version 9.9.9 --effort high --json 2>/dev/null)
  [ "$(printf '%s' "$out" | jq -r '.record')" = alpha-one-new ] \
    || fail "the declared successor did not supersede the retained earlier evidence"
  [ "$(printf '%s' "$out" | jq -r '.state')" = QUALIFIED ] \
    || fail "a valid supersession chain did not expose its current observation"
  assert_present "$RDIR/alpha-one-old.json" "the superseded adverse evidence was removed"
  pass "a declared supersession selects the retained successor"
}

test_an_absent_contract_is_could_not_observe_and_never_a_pass() {
  reset_register
  write_record alpha-one-job
  [ "$(state_of job-maker alpha/one)" = QUALIFIED ] || fail "control: the record did not start QUALIFIED"
  local st
  st=$(state_of no-such-contract alpha/one)
  [ "$st" = COULD_NOT_OBSERVE ] \
    || fail "a route requirement naming an absent contract read $st; a requirement nobody can read has not been met"
  assert_contains "$(qual state --contract no-such-contract --model alpha/one 2>&1)" \
    "FM_QUALIFICATION_CONTRACT_UNKNOWN" "the refusal token was not printed"
  pass "an absent contract is could-not-observe and never a pass"
}

test_an_inadmissible_record_is_could_not_observe_and_never_used() {
  reset_register
  write_record alpha-one-job '.state = "QUALIFIED"'
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = COULD_NOT_OBSERVE ] \
    || fail "a record carrying a hand-written state read $st; an inadmissible record must never be used"
  assert_contains "$(qual state --contract job-maker --model alpha/one 2>&1)" \
    "FM_QUALIFICATION_RECORD_INADMISSIBLE" "the refusal token was not printed"
  pass "an inadmissible record is could-not-observe and never used"
}

# --- admissibility, driven red first ----------------------------------------

test_record_admissibility_refuses_stored_state_synonyms_and_estimates() {
  reset_register
  local case out rc
  # Every mutation must be observed red. The clean control at the end is what
  # proves the validator is not simply refusing everything.
  for case in 'stored-state:.state = "QUALIFIED"' \
              'synonym:.result = "inconclusive"' \
              'estimate:.measured_context = "about 200k"' \
              'no-limitations:.known_limitations = []' \
              'no-dependencies:.freshness_dependencies = []' \
              'score:.score = 7'; do
    write_record probe "${case#*:}"
    rc=0
    out=$(qual validate "$RDIR/probe.json" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "the ${case%%:*} mutation was admitted"
    assert_contains "$out" "inadmissible" "the ${case%%:*} mutation was not reported inadmissible"
    rm -f "$RDIR/probe.json"
  done
  write_record probe
  qual validate "$RDIR/probe.json" >/dev/null 2>&1 \
    || fail "the clean control record was refused, so the mutations above prove nothing"
  rm -f "$RDIR/probe.json"
  pass "record admissibility refuses stored state, synonyms and estimates"
}

test_an_uncovered_dependency_requires_a_time_bound() {
  reset_register
  write_record probe \
    '.freshness_dependencies += [{"kind":"harness_semantics","harness":"pi","version":"9.9.9"}]'
  local rc=0 out
  out=$(qual validate "$RDIR/probe.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an uncovered dependency was admitted with no time bound"
  assert_contains "$out" "bounded in time instead" "the reason was not named"
  write_record probe \
    '.freshness_dependencies += [{"kind":"harness_semantics","harness":"pi","version":"9.9.9"},
                                 {"kind":"time_bound","until":"2099-01-01","justification":"derived from the declared evidence-review cadence"}]'
  qual validate "$RDIR/probe.json" >/dev/null 2>&1 \
    || fail "an uncovered dependency WITH a time bound was refused"
  rm -f "$RDIR/probe.json"
  pass "an uncovered dependency requires a time bound"
}

test_an_expired_time_bound_makes_a_pass_stale() {
  reset_register
  write_record alpha-one-job \
    '.freshness_dependencies += [{"kind":"time_bound","until":"2026-01-01","justification":"deliberately in the past"}]'
  local st
  st=$(state_of job-maker alpha/one)
  [ "$st" = QUALIFICATION_STALE ] \
    || fail "a record past its declared time bound read $st instead of QUALIFICATION_STALE"
  pass "an expired time bound makes a pass stale"
}

test_a_contract_that_names_a_configured_binding_is_inadmissible() {
  reset_register
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "_models": { "alpha/one": { "smart_zone": 140000 } },
  "rules": [ { "when": "anything", "route": "R-X", "floor": "F-X",
               "use": { "harness": "pi", "model": "alpha/one" },
               "pool": ["alpha/one"] } ]
}
JSON
  local rc=0 out
  qual validate "$CDIR/job-maker.json" >/dev/null 2>&1 \
    || fail "control: the vendor-neutral contract was refused before any mutation"
  jq '.purpose = "measure whether alpha/one can do the job"' "$CDIR/job-maker.json" > "$CDIR/probe.json"
  jq '.id = "probe"' "$CDIR/probe.json" > "$CDIR/probe.tmp" && mv "$CDIR/probe.tmp" "$CDIR/probe.json"
  out=$(qual validate "$CDIR/probe.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a contract naming a configured binding was admitted"
  assert_contains "$out" "names a job, never who does it" "the vendor-neutrality reason was not named"
  rm -f "$CDIR/probe.json" "$HOME_DIR/config/crew-dispatch.json"
  pass "a contract that names a configured binding is inadmissible"
}

test_contract_admissibility_refuses_a_missing_predicate_field_and_an_unknown_axis() {
  reset_register
  local case rc out
  for case in 'unknown-axis:.axis = "reads_minds"' \
              'missing-digest:del(.executable_predicate.manifest_digest)' \
              'empty-digest:.executable_predicate.manifest_digest = ""' \
              'vendor-key:.model = "alpha/one"' \
              'no-adjudicator:.adjudication = {"required": true}'; do
    jq "${case#*:} | .id = \"probe\"" "$CDIR/job-maker.json" > "$CDIR/probe.json"
    rc=0
    out=$(qual validate "$CDIR/probe.json" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "the ${case%%:*} contract mutation was admitted"
    assert_contains "$out" "inadmissible" "the ${case%%:*} mutation was not reported inadmissible"
    rm -f "$CDIR/probe.json"
  done
  jq '.id = "probe"' "$CDIR/job-maker.json" > "$CDIR/probe.json"
  qual validate "$CDIR/probe.json" >/dev/null 2>&1 \
    || fail "the clean control contract was refused, so the mutations above prove nothing"
  rm -f "$CDIR/probe.json"
  pass "contract admissibility refuses a missing predicate field and an unknown axis"
}

# --- the axes stay apart -----------------------------------------------------

test_a_maker_may_never_review_its_own_candidate() {
  reset_register
  write_contract job-reviewer JOB_REVIEWER job-risk-v1 exact_change_review no
  write_record beta-two-reviewer \
    '.contract = "job-reviewer" | .role = "JOB_REVIEWER" | .binding.provider = "beta"
     | .binding.model = "beta/two" | .adjudication.adjudicator_binding = "alpha/one"'
  # Qualified as a reviewer, and still refused on its own work.
  qual reviewer --maker alpha/one --reviewer beta/two --contract job-reviewer >/dev/null 2>&1 \
    || fail "control: a qualified independent reviewer was refused"
  local rc=0 out
  out=$(qual reviewer --maker beta/two --reviewer beta/two --contract job-reviewer 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a binding was allowed to review its own candidate"
  assert_contains "$out" "FM_QUALIFICATION_SELF_REVIEW_REFUSED" "the self-review refusal token was not printed"
  assert_contains "$out" "may not review it" "the refusal did not say what was refused"
  pass "a maker may never review its own candidate"
}

test_a_record_naming_itself_as_its_own_adjudicator_is_inadmissible() {
  reset_register
  write_record probe '.adjudication.adjudicator_binding = "alpha/one"'
  local rc=0 out
  out=$(qual validate "$RDIR/probe.json" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a record naming its own binding as adjudicator was admitted"
  assert_contains "$out" "reviews its own mutation" "the reason was not named"
  rm -f "$RDIR/probe.json"
  pass "a record naming itself as its own adjudicator is inadmissible"
}

test_design_challenge_and_change_review_are_separate_capabilities() {
  reset_register
  write_contract job-design JOB_DESIGNER job-risk-v1 design_challenge no
  write_contract job-change JOB_CHANGE_REVIEWER job-risk-v1 exact_change_review no
  write_record gamma-design \
    '.contract = "job-design" | .role = "JOB_DESIGNER" | .binding.provider = "gamma"
     | .binding.model = "gamma/three" | .adjudication.adjudicator_binding = "alpha/one"'
  # Holding the design contract does NOT grant the change-review one.
  qual reviewer --maker alpha/one --reviewer gamma/three --contract job-design >/dev/null 2>&1 \
    || fail "control: the binding qualified for the design contract was refused for it"
  local rc=0 out
  out=$(qual reviewer --maker alpha/one --reviewer gamma/three --contract job-change 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a design-challenge qualification granted exact-change review"
  assert_contains "$out" "job-change" "the refusal did not name the contract that is missing"
  # One reviewer may perform BOTH, but only by holding both.
  write_record gamma-change \
    '.contract = "job-change" | .role = "JOB_CHANGE_REVIEWER" | .binding.provider = "gamma"
     | .binding.model = "gamma/three" | .adjudication.adjudicator_binding = "alpha/one"'
  qual reviewer --maker alpha/one --reviewer gamma/three --contract job-design --contract job-change >/dev/null 2>&1 \
    || fail "a reviewer holding BOTH contracts was refused both jobs on one assignment"
  pass "design challenge and change review are separate capabilities"
}

test_an_unqualified_reviewer_is_refused_without_being_recorded_as_failed() {
  reset_register
  write_contract job-reviewer JOB_REVIEWER job-risk-v1 exact_change_review no
  local rc=0 out
  out=$(qual reviewer --maker alpha/one --reviewer delta/four --contract job-reviewer 2>&1) || rc=$?
  expect_code 3 "$rc" "an unqualified reviewer is an engineering state, not a refusal"
  assert_contains "$out" "QUALIFICATION_REQUIRED" "the state was not named"
  assert_not_contains "$out" "FAILED" "a reviewer with no record was reported as failed"
  pass "an unqualified reviewer is refused without being recorded as failed"
}

# --- the shipped register ----------------------------------------------------

test_the_shipped_register_is_admissible() {
  local rc=0 out
  out=$(FM_HOME="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$QUAL" validate 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the shipped qualification register is inadmissible:"$'\n'"$out"
  assert_contains "$out" "admissible" "the shipped register produced no admissibility verdict"
  pass "the shipped register is admissible"
}

test_the_shipped_sol_high_record_is_the_first_real_record_and_is_not_a_pass() {
  local st out
  out=$(FM_HOME="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
        "$QUAL" state --contract runtime-risk-maker --model openai-codex/gpt-5.6-sol --json 2>/dev/null)
  st=$(printf '%s' "$out" | jq -r '.state')
  # The recorded result short-circuits before any freshness observation, so this
  # assertion does not rot when the record's declared time bound expires.
  [ "$(printf '%s' "$out" | jq -r '.recorded_result')" = QUALIFICATION_REQUIRED ] \
    || fail "the shipped record no longer records the adjudicated QUALIFICATION_REQUIRED result"
  [ "$st" = QUALIFICATION_REQUIRED ] \
    || fail "the shipped record reads $st; the adjudicated result was missing evidence, not a pass and not a failure"
  [ "$st" != QUALIFIED ] || fail "the first real record reads as a pass"
  [ "$st" != FAILED ] || fail "the first real record reads as a failure against the binding"
  [ "$(printf '%s' "$out" | jq -r '.record')" = sol-high-runtime-risk-v1 ] \
    || fail "the shipped record was not the one consulted"
  pass "the shipped Sol High record is the first real record and is not a pass"
}

test_every_shipped_contract_declares_exactly_one_of_the_nine_axes() {
  local axes bad
  axes=$(FM_HOME="$ROOT" "$QUAL" contracts --json 2>/dev/null | jq -r '.[].axis')
  [ -n "$axes" ] || fail "the shipped contract register listed nothing"
  bad=$(printf '%s\n' "$axes" | grep -vxF -e maker_qualification -e design_challenge \
        -e exact_change_review -e assignment_independence -e provider_account_pool_identity \
        -e availability -e cost -e entitlement -e attempt_custody_accounting || true)
  [ -z "$bad" ] || fail "a shipped contract declares an axis outside the nine: $bad"
  pass "every shipped contract declares exactly one of the nine axes"
}

test_a_qualified_pass_may_not_be_asserted_past_the_register() {
  reset_register
  mkdir -p "$HOME_DIR/state/qualification"
  cat > "$HOME_DIR/state/qualification/$QUAL_ACTIVATION_ID.activation" <<ACT
schema=fm-qualification-activation.v1
activation=$QUAL_ACTIVATION_ID
contract=job-maker
model=alpha/one
harness=pi
native_effort=high
route=R-X
attempt_budget=2
ACT
  # The workflow's own backlog item, which activation creates in production. It is
  # the single fact that owns this workflow's liveness, so resolve cannot close a
  # workflow the backlog owner never knew about.
  printf '%s queued\n' "$QUAL_ACTIVATION_ID" >> "$TMP_ROOT/tasks-axi.store"
  local rc=0 out
  out=$(qual resolve "$QUAL_ACTIVATION_ID" --result QUALIFIED 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a pass was accepted with no record in the register to support it"
  assert_contains "$out" "never what a caller asserts" "the refusal did not say why the word was not enough"
  # With the record present the same call is accepted, which is what proves the
  # refusal above was about the evidence and not about the command.
  write_record alpha-one-job
  qual resolve "$QUAL_ACTIVATION_ID" --result QUALIFIED >/dev/null 2>&1 \
    || fail "a pass the register independently computes was still refused"
  pass "a qualified pass may not be asserted past the register"
}

test_a_qualified_record_with_unchanged_dependencies_is_qualified
test_no_record_is_qualification_required_and_never_failed
test_a_failed_record_reads_failed_and_preserves_its_evidence
test_a_changed_declared_dependency_makes_a_pass_stale_and_never_failed
test_an_unrelated_byte_change_does_not_invalidate_a_record
test_an_unobservable_dependency_is_could_not_observe_and_not_a_pass
test_a_failed_record_reopens_only_on_a_material_change
test_a_predicate_pass_without_adjudication_is_qualification_required
test_an_unqualified_adjudicator_pass_is_not_consumed
test_a_different_harness_or_effort_is_a_near_miss_not_a_match
test_a_different_harness_version_is_a_distinct_observation
test_two_records_for_one_tuple_are_could_not_observe
test_a_declared_supersession_selects_the_retained_successor
test_an_absent_contract_is_could_not_observe_and_never_a_pass
test_an_inadmissible_record_is_could_not_observe_and_never_used
test_record_admissibility_refuses_stored_state_synonyms_and_estimates
test_an_uncovered_dependency_requires_a_time_bound
test_an_expired_time_bound_makes_a_pass_stale
test_a_contract_that_names_a_configured_binding_is_inadmissible
test_contract_admissibility_refuses_a_missing_predicate_field_and_an_unknown_axis
test_a_maker_may_never_review_its_own_candidate
test_a_record_naming_itself_as_its_own_adjudicator_is_inadmissible
test_design_challenge_and_change_review_are_separate_capabilities
test_an_unqualified_reviewer_is_refused_without_being_recorded_as_failed
test_the_shipped_register_is_admissible
test_the_shipped_sol_high_record_is_the_first_real_record_and_is_not_a_pass
test_every_shipped_contract_declares_exactly_one_of_the_nine_axes
test_a_qualified_pass_may_not_be_asserted_past_the_register
