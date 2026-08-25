#!/usr/bin/env bash
# Behavioral tests for the isolation-proof and test-run public interfaces.
#
# This script owns everything that asks whether the CANONICAL isolation proof is
# current, including bin/fm-test-run.sh --check-coverage and the real seam that
# the production runner consumes the proof the harness just wrote.
#
# It owns them because it is deliberately excluded from the candidate set
# (bin/fm-test-isolation-proof.sh, exclusion_reason), so it is never executed as
# a proof subject and requiring a current proof here closes no loop. The same
# cases inside tests/fm-test-run.test.sh - which IS a subject - made
# re-measurement impossible; docs/architecture.md states the law under
# EVIDENCE_GENERATION_WELL_FOUNDEDNESS and docs/fm-test-isolation-proof.md keeps
# the incident.
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

  # A truncated document is could-not-observe, and this is the shape a write
  # interrupted partway used to leave behind. It must never read as a proof with
  # fewer subjects, because that would silently narrow the proven set.
  head -c 40 "$root/docs/fm-test-isolation-proof.json" >"$root/truncated.json" \
    || fail "could not build the truncated artifact"
  mv "$root/truncated.json" "$root/docs/fm-test-isolation-proof.json"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 3 ] || fail "a truncated proof must return 3, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" "name=proof-artifact" "the malformed artifact is named"
  assert_not_contains "$FRESHNESS_OUT" "FM_ISOLATION_FRESHNESS PROVEN" \
    "a malformed proof must never be narrowed into a pass"

  # Restore a genuine proof, so the next leg is about the lane inventory only.
  remeasure_freshness_fixture "$root" || fail "could not restore the fixture proof"

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
  pass "malformed, truncated, and absent inputs return could-not-observe, never a pass"
}

test_freshness_refuses_an_unparseable_lane_jobs_value() {
  local root
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  # Watched red: the lane carries a --jobs token whose value is not a literal
  # integer, so the concurrency the proven set runs at was not observed. Only
  # the absence of a --jobs token may read as the runner's default of 1.
  # shellcheck disable=SC2016 # The literal unexpanded $FM_JOBS is the unparseable value under test.
  sed 's|--lane portable-parallel-1|--lane portable-parallel-1 --jobs "$FM_JOBS"|' \
    "$root/.github/workflows/ci.yml" >"$root/.github/workflows/ci.yml.new"
  mv "$root/.github/workflows/ci.yml.new" "$root/.github/workflows/ci.yml"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 3 ] || fail "an unparseable --jobs value must return 3, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=concurrency" \
    "an unreadable lane concurrency is stated as such"
  assert_not_contains "$FRESHNESS_OUT" "FM_ISOLATION_FRESHNESS PROVEN" \
    "could-not-observe must never be narrowed into a pass"

  # Non-vacuity: the same lane with a literal --jobs value is observed rather
  # than refused, so the refusal above can only be about parseability.
  # shellcheck disable=SC2016 # Matches the literal $FM_JOBS written above.
  sed 's|--jobs "$FM_JOBS"|--jobs 2|' \
    "$root/.github/workflows/ci.yml" >"$root/.github/workflows/ci.yml.new"
  mv "$root/.github/workflows/ci.yml.new" "$root/.github/workflows/ci.yml"
  freshness_verdict "$root" 4
  [ "$FRESHNESS_RC" -eq 0 ] || fail "a literal --jobs 2 must be observed as PROVEN, got rc=$FRESHNESS_RC"$'\n'"$FRESHNESS_OUT"
  assert_contains "$FRESHNESS_OUT" \
    "FM_ISOLATION_DEPENDENCY OBSERVED name=lane-concurrency lane=portable-parallel-1 jobs=2" \
    "a literal jobs value is observed with its lane"
  pass "an unreadable lane --jobs value is could-not-observe, never one"
}

# Echoes a minimal proof artifact holding exactly one recorded subject with the
# given exit code. Only the reader's schema checks matter here, so the digests
# are placeholders: fm_isolation_proven_paths never verifies bytes, it only
# reports what the artifact recorded.
mk_proof_artifact_with_exit() {
  local exit_code=$1 out
  out=$(fm_test_tmproot fm-isolation-proven-paths)/proof.json
  cat >"$out" <<FIXTURE
{
  "kind": "isolation-proof",
  "schema_version": 2,
  "concurrency": 4,
  "isolation_contract": {"digest": "sha256:fixture"},
  "scripts": [
    {"path": "tests/mini.test.sh", "digest": "sha256:fixture", "exit": $exit_code, "fixtures": []}
  ]
}
FIXTURE
  printf '%s\n' "$out"
}

test_proven_paths_refuse_a_proof_with_no_passing_subject() {
  local artifact out rc

  # Watched red: every recorded subject failed, so there is no proven set to
  # hand out. An empty set here would let --proven-isolated select nothing and
  # read as a successful run of nothing.
  artifact=$(mk_proof_artifact_with_exit 1)
  rc=0
  out=$(fm_isolation_proven_paths "$artifact") || rc=$?
  [ "$rc" -eq 3 ] || fail "a proof with no passing subject must return 3, got rc=$rc"
  [ -z "$out" ] || fail "a refused proven set must print nothing, got: $out"

  # Non-vacuity: the same artifact with exit 0 lists that subject, so the
  # refusal above can only be about the exit code.
  artifact=$(mk_proof_artifact_with_exit 0)
  rc=0
  out=$(fm_isolation_proven_paths "$artifact") || rc=$?
  [ "$rc" -eq 0 ] || fail "a proof with a passing subject must return 0, got rc=$rc"
  [ "$out" = "tests/mini.test.sh" ] || fail "the passing subject must be listed, got: $out"
  pass "a proof in which nothing passed is could-not-observe, never an empty set"
}

test_reader_refuses_a_non_integer_concurrency() {
  local artifact out rc

  # Watched red: a proof without an integer concurrency cannot be compared
  # against the observed lane concurrency, so the reader must return
  # could-not-observe instead of letting "None" reach the -le comparison and be
  # misreported as a definite STALE finding.
  artifact=$(mk_proof_artifact_with_exit 0)
  python3 - "$artifact" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
del doc["concurrency"]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(doc, fh)
PY
  rc=0
  out=$(fm_isolation_proof_read "$artifact") || rc=$?
  [ "$rc" -eq 3 ] || fail "a proof without concurrency must return 3, got rc=$rc"

  rc=0
  out=$(fm_isolation_check_freshness "$(dirname "$artifact")" "$artifact" 4 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "freshness over a proof without concurrency must return 3, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "FM_ISOLATION_DEPENDENCY COULD-NOT-OBSERVE name=proof-artifact" \
    "an unreadable proof is could-not-observe, not a definite finding"
  assert_not_contains "$out" "FM_ISOLATION_DEPENDENCY STALE" \
    "an unreadable input must never be narrowed into a definite STALE"
  pass "a non-integer concurrency is could-not-observe, never a definite finding"
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


# --- the coverage guard as the isolation proof's refusing consumer ----------
#
# The proof document had no mandatory consumer at all: fourteen of its
# twenty-four subjects had been edited since it was taken, and nothing in the
# repository could notice. These are the end-to-end version of that repair - the
# guard CI actually runs, refusing on a subject that moved.
#
# They run against a disposable copy of this repository, because the mutation is
# the point of the case and must never land on a real subject.
#
# WHY THEY LIVE HERE. Each one needs a baseline in which the installed proof is
# CURRENT, so each one requires the canonical artifact to be fresh. This script
# is deliberately excluded from the candidate set (bin/fm-test-isolation-proof.sh,
# exclusion_reason), so its passing is not a precondition of generating that
# artifact and requiring the artifact to be fresh closes no loop. They used to
# live in tests/fm-test-run.test.sh, which IS a subject: editing that file made
# the proof stale, the stale proof failed these cases, and the failing subject
# then kept the run from producing a proof that would clear it.
# docs/architecture.md states the law under EVIDENCE_GENERATION_WELL_FOUNDEDNESS.
#
# Each guard invocation below is captured in a `|| rc=$?` list rather than a bare
# assignment followed by `rc=$?`. An earlier case in this suite leaves errexit
# on, and a bare assignment would end the whole suite silently on exactly the
# refusal these cases exist to observe.

# Echoes a disposable copy of everything the coverage guard reads.
mk_guard_repo() {
  local repo
  repo=$(fm_test_tmproot fm-coverage-guard)
  [ -n "$repo" ] && [ -d "$repo" ] || return 1
  mkdir -p "$repo/docs" "$repo/.github/workflows" || return 1
  cp -R "$ROOT/bin" "$repo/bin" || return 1
  cp -R "$ROOT/tests" "$repo/tests" || return 1
  cp "$ROOT/docs/fm-test-isolation-proof.json" "$repo/docs/" || return 1
  cp "$ROOT/.github/workflows/ci.yml" "$repo/.github/workflows/" || return 1
  printf '%s\n' "$repo"
}

test_coverage_guard_refuses_a_proven_subject_that_moved() {
  local repo subject out rc

  repo=$(mk_guard_repo) || fail "could not build a disposable guard repository"
  [ -n "$repo" ] && [ -d "$repo" ] || fail "guard repository path is empty"
  subject=$("$repo/bin/fm-test-isolation-proof.sh" --list-proven | head -n 1)
  [ -n "$subject" ] || fail "the proof named no proven subject to mutate"
  [ -f "$repo/$subject" ] || fail "proven subject missing from the copy: $subject"

  # Non-vacuity: the untouched copy passes, so a later refusal is about the
  # mutation and not about the copy being broken.
  rc=0
  out=$("$repo/bin/fm-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "an untouched copy must pass the coverage guard, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "FM_TEST_COVERAGE ok" "the untouched copy reports the guard marker"
  assert_contains "$out" "FM_ISOLATION_FRESHNESS PROVEN" \
    "the guard reports the freshness verdict it consulted"

  # Watched red: one hunk appended to a proven subject.
  printf '\n# a hunk recorded in no proof\n' >>"$repo/$subject"
  rc=0
  out=$("$repo/bin/fm-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a moved proven subject must refuse with 1, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "FM_ISOLATION_SUBJECT STALE path=$subject reason=subject-bytes-changed" \
    "the refusal names the subject that moved"
  assert_contains "$out" "re-measure" "the refusal states how to clear it"
  assert_not_contains "$out" "FM_TEST_COVERAGE ok" "a stale proof must not report the guard as ok"

  pass "the coverage guard refuses a proven subject whose bytes moved"
}

test_coverage_guard_refuses_a_lane_wider_than_the_proof() {
  local repo out rc workflow

  repo=$(mk_guard_repo) || fail "could not build a disposable guard repository"
  [ -n "$repo" ] && [ -d "$repo" ] || fail "guard repository path is empty"
  workflow="$repo/.github/workflows/ci.yml"

  # Watched red: a parallel lane starts running the proven set wider than it was
  # ever measured at.
  sed 's|--lane portable-parallel-1|--lane portable-parallel-1 --jobs 16|' \
    "$workflow" >"$workflow.new" || fail "could not rewrite the fixture workflow"
  mv "$workflow.new" "$workflow"
  rc=0
  out=$("$repo/bin/fm-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a lane above the proof must refuse with 1, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "name=concurrency reason=exceeds-proof" \
    "the refusal names the concurrency dependency"
  assert_contains "$out" "observed_max=16" "the refusal states the concurrency it observed"
  pass "the coverage guard refuses a CI lane wider than the proof"
}

test_coverage_guard_reports_an_unreadable_proof_as_could_not_observe() {
  local repo out rc

  repo=$(mk_guard_repo) || fail "could not build a disposable guard repository"
  [ -n "$repo" ] && [ -d "$repo" ] || fail "guard repository path is empty"

  # An absent artifact leaves the proven set unknown. The failure that matters
  # is the one this replaced: an unreadable proof used to collapse to an empty
  # proven set, and the guard then reported a true shard-partition mismatch
  # about the wrong subject while the real fault went unnamed.
  rm -f "$repo/docs/fm-test-isolation-proof.json"
  rc=0
  out=$("$repo/bin/fm-test-run.sh" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 3 ] || fail "an unreadable proof must return 3, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "COULD NOT BE OBSERVED" "the guard states it could not observe the set"
  assert_not_contains "$out" "portable shards must equal the proven-isolated set" \
    "an unreadable proof must not be reported as a shard-partition mismatch"
  pass "an unreadable proof is could-not-observe, not an empty proven set"
}

test_canonical_coverage_seam_consumes_the_installed_proof() {
  local out rc

  # THE REAL SEAM, against this repository rather than a copy: the production
  # runner reads the canonical artifact that bin/fm-test-isolation-proof.sh
  # writes, and reports the freshness verdict it consulted.
  #
  # This is the assertion that keeps the repaired ordering honest end to end. It
  # is red exactly while the committed proof does not describe the committed
  # code, which is the state a re-measurement exists to clear - and it blocks no
  # re-measurement, because nothing here is a proof subject.
  rc=0
  out=$("$RUNNER" --check-coverage 2>&1) || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "the canonical coverage seam must accept the committed proof, got rc=$rc"$'\n'"$out"$'\n'"re-measure: bin/fm-test-isolation-proof.sh --jobs 4 --json docs/fm-test-isolation-proof.json"
  assert_contains "$out" "FM_ISOLATION_FRESHNESS PROVEN" \
    "the seam states the freshness verdict it consulted"
  assert_contains "$out" "FM_TEST_COVERAGE ok" "the seam reports the guard marker"
  pass "the production runner consumes the canonical proof and finds it current"
}


# --- what a run has to observe before it may replace the evidence -----------
#
# fm_isolation_artifact_refusal is the one owner of that question, and
# bin/fm-test-isolation-proof.sh asks it before writing anything. The incident
# it exists to prevent: a run that measured 23 of 24 subjects good replaced a
# genuine 24-subject proof with a 23-subject one, and the smaller artifact then
# became the acceptance evidence the same subject was measured against.

mk_refusal_inputs() {
  local root
  root=$(fm_test_tmproot fm-isolation-refusal)
  [ -n "$root" ] && [ -d "$root" ] || return 1
  printf 'tests/a.test.sh\ntests/b.test.sh\n' >"$root/candidates.txt" || return 1
  printf 'tests/a.test.sh\tda\t0\t10\t1\t\t\n' >"$root/records.tsv" || return 1
  printf 'tests/b.test.sh\tdb\t0\t20\t2\t\t\n' >>"$root/records.tsv" || return 1
  printf '%s\n' "$root"
}

test_a_complete_passing_run_may_replace_the_evidence() {
  local root reason rc
  root=$(mk_refusal_inputs) || fail "could not build the refusal fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "refusal fixture root is empty"

  # Non-vacuity: the whole candidate universe observed good is publishable, so a
  # later refusal is about what changed and not about the fixture being broken.
  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.tsv" "$root/candidates.txt" 0 0) || rc=$?
  [ "$rc" -eq 0 ] || fail "a complete passing run must be publishable, got rc=$rc reason=$reason"
  [ -z "$reason" ] || fail "a publishable run must state no refusal, got: $reason"
  pass "a run that observed every candidate good may replace the evidence"
}

test_a_run_that_did_not_observe_every_candidate_may_not() {
  local root reason rc

  # Watched red, one binding at a time. Each case below is the same fixture with
  # exactly one thing wrong, so the reason names the thing that is wrong.
  root=$(mk_refusal_inputs) || fail "could not build the refusal fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "refusal fixture root is empty"

  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.tsv" "$root/candidates.txt" 1 1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a failed subject must withhold the artifact, got rc=$rc"
  [ "$reason" = "subject-not-observed-good" ] || fail "unexpected reason: $reason"

  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.tsv" "$root/candidates.txt" 0 1) || rc=$?
  [ "$rc" -eq 1 ] || fail "a broken isolation check must withhold the artifact, got rc=$rc"
  [ "$reason" = "isolation-check-failed" ] || fail "unexpected reason: $reason"

  # The 23-of-24 shape: the run reported no failure, but a subject is missing
  # from the records. A proof written from these would assert a smaller universe
  # than the one the run was asked about.
  grep -v '^tests/b\.test\.sh' "$root/records.tsv" >"$root/records.short" \
    || fail "could not build the short record set"
  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.short" "$root/candidates.txt" 0 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "records short of the candidate universe must withhold, got rc=$rc"
  [ "$reason" = "records-are-not-the-candidate-universe" ] || fail "unexpected reason: $reason"

  # A record present but not passing, with the failure counter disagreeing. The
  # records themselves settle it; a miscounted run does not get published.
  printf 'tests/a.test.sh\tda\t0\t10\t1\t\t\ntests/b.test.sh\t\t-1\t0\t2\t\t\n' \
    >"$root/records.unmeasured"
  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.unmeasured" "$root/candidates.txt" 0 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "an unmeasured subject must withhold the artifact, got rc=$rc"
  [ "$reason" = "records-hold-a-non-passing-subject" ] || fail "unexpected reason: $reason"

  # Could-not-observe inputs are refusals too, never a silent pass.
  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/no-such-records" "$root/candidates.txt" 0 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "unreadable records must withhold the artifact, got rc=$rc"
  [ "$reason" = "records-unreadable" ] || fail "unexpected reason: $reason"

  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.tsv" "$root/no-such-candidates" 0 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "an unreadable candidate universe must withhold, got rc=$rc"
  [ "$reason" = "candidate-universe-unreadable" ] || fail "unexpected reason: $reason"

  : >"$root/candidates.empty"
  rc=0
  reason=$(fm_isolation_artifact_refusal "$root/records.tsv" "$root/candidates.empty" 0 0) || rc=$?
  [ "$rc" -eq 1 ] || fail "an empty candidate universe must withhold, got rc=$rc"
  [ "$reason" = "candidate-universe-empty" ] || fail "unexpected reason: $reason"

  pass "a run short of the whole candidate universe never replaces the evidence"
}

test_a_failed_write_leaves_the_previous_artifact_intact() {
  local root before after rc residue
  root=$(mk_freshness_fixture) || fail "could not build the freshness fixture"
  [ -n "$root" ] && [ -d "$root" ] || fail "freshness fixture root is empty"
  remeasure_freshness_fixture "$root" || fail "could not measure the fixture subject"

  before=$(fm_isolation_digest_file "$root/docs/fm-test-isolation-proof.json") \
    || fail "could not digest the genuine artifact"

  # The destination is replaced whole, so a write that does not complete leaves
  # the previous genuine artifact exactly as it was rather than a truncated
  # document that every consumer would read as could-not-observe.
  rc=0
  fm_isolation_write_proof "$root/docs/fm-test-isolation-proof.json" \
    2026-01-01T00:00:00Z 2026-01-01T00:00:30Z broken-run 1 0 4 30000 \
    "$root/no-such-records.tsv" deadbeef "$root/lanes.txt" 4 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "a write with no record set must fail rather than publish"

  after=$(fm_isolation_digest_file "$root/docs/fm-test-isolation-proof.json") \
    || fail "the previous artifact is no longer readable after a failed write"
  [ "$before" = "$after" ] \
    || fail "a failed write replaced the previous genuine artifact"

  residue=$(find "$root/docs" -maxdepth 1 -name 'fm-test-isolation-proof.json.tmp.*' | head -n 1)
  [ -z "$residue" ] || fail "a failed write left a partial document behind: $residue"

  # Non-vacuity: the same writer with the same real record set DOES replace the
  # destination, so the byte-identity above is about the failed write and not
  # about a writer that never writes. The run id is what is driven apart here,
  # because a re-measurement of this tiny subject can legitimately record the
  # same duration twice and produce identical bytes.
  local cdig
  cdig=$(fm_isolation_contract_digest) || fail "could not digest the isolation contract"
  fm_isolation_write_proof "$root/docs/fm-test-isolation-proof.json" \
    2026-01-01T00:00:00Z 2026-01-01T00:00:30Z after-failed-write 1 0 4 30000 \
    "$root/records.tsv" "$cdig" "$root/lanes.txt" 4 \
    || fail "the writer could not publish a real record set after the failed one"
  after=$(fm_isolation_digest_file "$root/docs/fm-test-isolation-proof.json") \
    || fail "could not digest the re-written artifact"
  [ "$before" != "$after" ] || fail "the writer never replaced the artifact at all"
  pass "a write that does not complete leaves the last genuine artifact intact"
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
test_freshness_refuses_an_unparseable_lane_jobs_value
test_proven_paths_refuse_a_proof_with_no_passing_subject
test_reader_refuses_a_non_integer_concurrency
test_proven_set_comes_from_the_proof_artifact
test_coverage_guard_refuses_a_proven_subject_that_moved
test_coverage_guard_refuses_a_lane_wider_than_the_proof
test_coverage_guard_reports_an_unreadable_proof_as_could_not_observe
test_canonical_coverage_seam_consumes_the_installed_proof
test_a_complete_passing_run_may_replace_the_evidence
test_a_run_that_did_not_observe_every_candidate_may_not
test_a_failed_write_leaves_the_previous_artifact_intact
