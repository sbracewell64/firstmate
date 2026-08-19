#!/usr/bin/env bash
# Behavioral tests for the isolation-proof and test-run public interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-test-isolation-proof.sh"
RUNNER="$ROOT/bin/fm-test-run.sh"

# shellcheck source=bin/fm-test-isolation-lib.sh
. "$ROOT/bin/fm-test-isolation-lib.sh"

assert_present "$PROOF" "bin/fm-test-isolation-proof.sh is missing"
[ -x "$PROOF" ] || fail "bin/fm-test-isolation-proof.sh must be executable"

test_list_candidates_nonempty_and_stable() {
  local listed count sorted
  listed=$("$PROOF" --list)
  [ -n "$listed" ] || fail "--list printed nothing"
  count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$count" -ge 10 ] || fail "expected a bounded non-trivial candidate set, got $count"
  sorted=$(printf '%s\n' "$listed" | LC_ALL=C sort)
  [ "$listed" = "$sorted" ] || fail "--list must be sorted for a stable matrix"
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = "$count" ] \
    || fail "--list must not duplicate candidates"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) [ -f "$ROOT/$line" ] || fail "listed missing script: $line" ;;
      *) fail "non-test candidate path: $line" ;;
    esac
  done <<<"$listed"
  pass "candidate --list is non-empty, sorted, unique, and real"
}

test_candidates_exclude_serial_classes() {
  local listed
  listed=$("$PROOF" --list)
  for banned in \
    tests/fm-test-isolation-proof.test.sh \
    tests/fm-backend-tmux-smoke.test.sh \
    tests/fm-watcher-lock.test.sh \
    tests/fm-wake-queue.test.sh \
    tests/fm-backend-herdr-smoke.test.sh \
    tests/fm-afk-inject-e2e.test.sh \
    tests/fm-pi-primary-live-e2e.test.sh \
    tests/fm-pr-check-security.test.sh \
    tests/fm-backend-cmux-smoke.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$banned" \
      && fail "serial-class script must not be a parallel candidate: $banned"
  done
  pass "serial classes remain excluded from the parallel candidate set"
}

test_extra_hermetic_candidates_present() {
  local listed
  listed=$("$PROOF" --list)
  for want in \
    tests/fm-backend-herdr.test.sh \
    tests/fm-send-strict.test.sh \
    tests/fm-spawn-batch.test.sh \
    tests/fm-pr-merge.test.sh \
    tests/fm-review-diff.test.sh \
    tests/fm-x-mode.test.sh; do
    printf '%s\n' "$listed" | grep -Fxq "$want" \
      || fail "extra hermetic candidate missing: $want"
  done
  pass "audited fake-backend and stub-network extras are candidates"
}

test_list_exclusions_documents_reasons() {
  local out
  out=$("$PROOF" --list-exclusions)
  [ -n "$out" ] || fail "--list-exclusions printed nothing"
  printf '%s\n' "$out" | grep -Fq 'fm-watcher-lock.test.sh' \
    || fail "exclusions must document watcher-lock serial reason"
  printf '%s\n' "$out" | grep -Fq 'fm-backend-herdr-smoke.test.sh' \
    || fail "exclusions must document real-herdr serial reason"
  pass "exclusion list documents serial reasons"
}

test_family_map_labels_this_contract() {
  local fam
  fam=$("$RUNNER" --list --family pure-contract-unit)
  printf '%s\n' "$fam" | grep -Fq 'tests/fm-test-isolation-proof.test.sh' \
    || fail "fm-test-isolation-proof.test.sh must map to pure-contract-unit"
  pass "isolation-proof contract test is family-mapped"
}

test_parallel_shards_consume_the_proven_set() {
  local proven shards
  proven=$("$PROOF" --list | LC_ALL=C sort -u)
  shards=$(
    {
      "$RUNNER" --list --lane portable-parallel-1
      "$RUNNER" --list --lane portable-parallel-2
    } | LC_ALL=C sort -u
  )
  [ "$proven" = "$shards" ] \
    || fail "portable parallel shards must equal isolation-proof --list exactly"
  pass "parallel shards consume the proven-isolated set only"
}


# --- freshness: an isolation proof is only about the code it measured --------
#
# The archived proof recorded a path and a duration, so when its subjects were
# edited afterwards it kept reading as current and no consumer could tell. These
# cases pin the repair by driving each binding red on purpose and watching the
# verdict flip, because a freshness check that never refuses is the same dead
# control as the one it replaced.
#
# Every case runs against a disposable fixture repository rather than this
# checkout: the mutations below are the point of the test, and they must never
# touch a real subject.

# Echoes a minimal repository root holding one subject, one shared fixture it
# sources, and a workflow that invokes a portable parallel lane.
mk_freshness_fixture() {
  local root
  root=$(fm_test_tmproot fm-isolation-freshness)
  [ -n "$root" ] && [ -d "$root" ] || return 1
  mkdir -p "$root/tests" "$root/.github/workflows" "$root/docs" || return 1
  cat >"$root/tests/lib.sh" <<'FIXTURE'
#!/usr/bin/env bash
# Minimal stand-in for the shared test harness: the fixture identity a subject
# binds to.
fm_test_tmproot() { mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX"; }
FIXTURE
  cat >"$root/tests/mini.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
d=$(fm_test_tmproot mini)
[ -d "$d" ] || exit 1
rm -rf "$d"
echo "ok"
FIXTURE
  cat >"$root/.github/workflows/ci.yml" <<'FIXTURE'
jobs:
  tests-portable-parallel-1:
    steps:
      - name: Run portable parallel shard 1
        run: |
          set -eu
          bin/fm-test-run.sh --lane portable-parallel-1 \
            --json timing.json
FIXTURE
  printf '%s\n' "$root"
}

# Measures the fixture subject for real and records a proof over what it just
# ran. There is deliberately no path here that stamps a digest onto an existing
# record: re-proving means running the subject again.
remeasure_freshness_fixture() {
  local root=$1 rc dur rec cdig
  rm -rf "$root/w1"
  fm_isolation_run_subject "$root" "$root/w1" tests/mini.test.sh || return 1
  [ -f "$root/w1/out/exit" ] || return 1
  rc=$(cat "$root/w1/out/exit")
  dur=$(cat "$root/w1/out/duration_ms")
  [ "$rc" = "0" ] || return 1
  rec=$(fm_isolation_record_subject "$root" tests/mini.test.sh "$rc" "$dur" 1) || return 1
  printf '%s\n' "$rec" >"$root/records.tsv"
  cdig=$(fm_isolation_contract_digest) || return 1
  fm_isolation_lane_concurrency "$root" >"$root/lanes.txt" || return 1
  fm_isolation_write_proof "$root/docs/fm-test-isolation-proof.json" \
    2026-01-01T00:00:00Z 2026-01-01T00:00:30Z fixture-run 1 0 4 30000 \
    "$root/records.tsv" "$cdig" "$root/lanes.txt" 4
}

FRESHNESS_OUT=
FRESHNESS_RC=0
# Captured in a `|| rc=$?` list so a refusal cannot end the suite under errexit:
# a refusal is the observation these cases are built to make.
freshness_verdict() {
  local root=$1 cap=$2
  FRESHNESS_RC=0
  FRESHNESS_OUT=$(fm_isolation_check_freshness "$root" \
    "$root/docs/fm-test-isolation-proof.json" "$cap" 2>&1) || FRESHNESS_RC=$?
}

test_freshness_proves_then_refuses_moved_subject_bytes() {
  local root
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # Non-vacuity: an unmeasured proof would refuse everything, including this.
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 0 ] || fail "freshly measured proof must be PROVEN, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" "FM_ISOLATION_SUBJECT PROVEN path=tests/mini.test.sh" \
    "a measured subject lists as proven"

  # Watched red: one hunk appended to the subject.
  printf '\necho "a hunk this proof never saw"\n' >>"$root/tests/mini.test.sh"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 1 ] || fail "moved subject bytes must refuse with 1, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_SUBJECT STALE path=tests/mini.test.sh reason=subject-bytes-changed" \
    "the stale subject is named with why"
  assert_contains "$FRESHNESS_OUT" "FM_ISOLATION_FRESHNESS STALE" "the whole proof reads stale"

  # An honest re-measurement - running the moved subject again - restores it.
  remeasure_freshness_fixture "$root" || fail "could not re-measure the moved subject"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 0 ] || fail "re-measured subject must return to PROVEN, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  pass "subject bytes bind the proof, and re-measurement is what clears it"
}

test_freshness_refuses_a_fixture_that_moved_under_a_subject() {
  local root
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # The subject's own bytes are untouched here. Only the harness it loads moved.
  printf '\n# a change in the shared harness the subject runs under\n' >>"$root/tests/lib.sh"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 1 ] || fail "a moved fixture must refuse with 1, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_SUBJECT STALE path=tests/mini.test.sh reason=fixture-bytes-changed:tests/lib.sh" \
    "the moved fixture is named, not just the subject"
  pass "fixture identity binds the proof independently of the subject's bytes"
}

test_freshness_refuses_concurrency_above_the_proof() {
  local root
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # Watched red: the CI lane starts running the proven set wider than proven.
  sed 's|--lane portable-parallel-1|--lane portable-parallel-1 --jobs 16|' \
    "$root/.github/workflows/ci.yml" >"$root/.github/workflows/ci.yml.new"
  mv "$root/.github/workflows/ci.yml.new" "$root/.github/workflows/ci.yml"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 1 ] || fail "a lane above the proof must refuse with 1, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_DEPENDENCY STALE name=concurrency reason=exceeds-proof observed_max=16 proven=4" \
    "the refusal states both the observed and the proven concurrency"

  # Watched red: the runner's own cap raised above the proof. The lane is put
  # back first so the refusal below can only come from the cap.
  root=$(mk_freshness_fixture) || fail "could not rebuild the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the rebuilt fixture"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 0 ] || fail "the rebuilt fixture must start PROVEN, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  freshness_verdict "$root" 9
  [ "$FRESHNESS_RC" -eq 1 ] || fail "a runner cap above the proof must refuse with 1, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" "observed_max=9 proven=4" "the runner cap is observed too"
  pass "concurrency above the proof refuses from either place it is configured"
}

test_freshness_refuses_changed_isolation_semantics() {
  local root saved
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # Watched red: the sandbox stops clearing most ambient fleet overrides, so the
  # semantics the subject was measured under no longer hold.
  saved=$FM_ISOLATION_CLEARED_ENV
  FM_ISOLATION_CLEARED_ENV='FM_HOME'
  freshness_verdict "$root" 4
  FM_ISOLATION_CLEARED_ENV=$saved
  [ "$FRESHNESS_RC" -eq 1 ] || fail "changed isolation semantics must refuse with 1, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_DEPENDENCY STALE name=isolation-contract reason=contract-changed" \
    "the contract change is named as the reason"

  # Non-vacuity: restoring the contract restores the verdict, so the case is not
  # passing on some unrelated permanent difference.
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 0 ] || fail "restored semantics must return to PROVEN, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  pass "runner semantics and sandbox layout bind the proof"
}

test_freshness_reports_could_not_observe_instead_of_passing() {
  local root
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # No lane invocation anywhere: the concurrency the proven set runs at is
  # unknown, which is not the same as a concurrency of zero.
  printf 'jobs:\n  unrelated:\n    steps: []\n' >"$root/.github/workflows/ci.yml"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 3 ] || fail "an unobservable lane must return 3, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=concurrency reason=no-parallel-lane-invocation-found" \
    "an unreadable lane inventory is stated as such"
  assert_not_contains "$FRESHNESS_OUT" "FM_ISOLATION_FRESHNESS PROVEN" \
    "could-not-observe must never be narrowed into a pass"

  # An absent artifact is could-not-observe at the whole-proof level.
  rm -f "$root/docs/fm-test-isolation-proof.json"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 3 ] || fail "an absent proof must return 3, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" "name=proof-artifact" "the missing artifact is named"
  pass "unreadable inputs return could-not-observe rather than a pass"
}

test_proven_set_comes_from_the_proof_artifact() {
  local from_proof from_runner cap proven_concurrency
  from_proof=$("$PROOF" --list-proven | LC_ALL=C sort -u)
  [ -n "$from_proof" ] || fail "--list-proven printed nothing"
  from_runner=$("$RUNNER" --list --proven-isolated | LC_ALL=C sort -u)
  [ "$from_proof" = "$from_runner" ] \
    || fail "the runner's proven set must come from the proof artifact, not a second copy"

  # The runner's concurrency licence may not exceed the evidence behind it.
  cap=$("$RUNNER" --print-jobs-max)
  proven_concurrency=$(
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["concurrency"])' \
      "$ROOT/docs/fm-test-isolation-proof.json"
  )
  [ "$cap" -le "$proven_concurrency" ] \
    || fail "--jobs cap $cap exceeds the proven concurrency $proven_concurrency"
  pass "the artifact owns the proven set and bounds the runner's concurrency"
}

test_list_candidates_nonempty_and_stable
test_candidates_exclude_serial_classes
test_extra_hermetic_candidates_present
test_list_exclusions_documents_reasons
test_family_map_labels_this_contract
test_parallel_shards_consume_the_proven_set
test_freshness_proves_then_refuses_moved_subject_bytes
test_freshness_refuses_a_fixture_that_moved_under_a_subject
test_freshness_refuses_concurrency_above_the_proof
test_freshness_refuses_changed_isolation_semantics
test_freshness_reports_could_not_observe_instead_of_passing
test_proven_set_comes_from_the_proof_artifact
