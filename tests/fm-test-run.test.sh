#!/usr/bin/env bash
# Contract tests for bin/fm-test-run.sh - the single owner of behavior suite
# selection, portable lane composition, proven-isolated --jobs, timing markers,
# JSON artifacts, coverage guard, and aggregate exit status.
#
# These tests intentionally exercise the runner with fixtures, --list, and
# focused scheduler checks, not the complete Firstmate suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$ROOT/bin/fm-test-run.sh"

assert_present "$RUNNER" "bin/fm-test-run.sh is missing"
[ -x "$RUNNER" ] || fail "bin/fm-test-run.sh must be executable"

test_list_all_exact_suite_coverage() {
  local listed expected missing extra f
  listed=$("$RUNNER" --list --all | LC_ALL=C sort)
  expected=$(
    for f in "$ROOT"/tests/*.test.sh; do
      [ -f "$f" ] || continue
      printf 'tests/%s\n' "$(basename "$f")"
    done | LC_ALL=C sort
  )
  [ -n "$listed" ] || fail "--list --all printed nothing"
  missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  extra=$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") || true)
  [ -z "$missing" ] || fail "--list --all missing scripts: $missing"
  [ -z "$extra" ] || fail "--list --all unexpected scripts: $extra"
  # No duplicates.
  [ "$(printf '%s\n' "$listed" | uniq | wc -l | tr -d ' ')" = \
    "$(printf '%s\n' "$listed" | wc -l | tr -d ' ')" ] \
    || fail "--list --all must not duplicate scripts"
  pass "exact suite coverage: --all lists every tests/*.test.sh once"
}

test_family_selection() {
  local listed line
  listed=$("$RUNNER" --list --family pure-contract-unit)
  [ -n "$listed" ] || fail "--family pure-contract-unit selected nothing"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-test-run.test.sh' \
    || fail "pure-contract-unit must include fm-test-run.test.sh"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      tests/*.test.sh) ;;
      *) fail "family selection produced non-test path: $line" ;;
    esac
  done <<<"$listed"
  # Family mode must not equal the complete suite for a narrow family.
  local all_count fam_count
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] \
    || fail "pure-contract-unit must be a proper subset of --all"
  pass "family selection returns a proper subset of the suite"
}

test_single_script_selection() {
  local listed
  listed=$("$RUNNER" --list tests/fm-lint.test.sh)
  [ "$listed" = "tests/fm-lint.test.sh" ] \
    || fail "single-script list expected tests/fm-lint.test.sh, got: $listed"
  pass "single-script selection lists exactly that path"
}

test_changed_file_selection_is_conservative() {
  local listed all_count fam_count listed_count
  # A path-mapped pure unit should not expand to --all.
  listed=$("$RUNNER" --list --family pure-contract-unit)
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  fam_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
  [ "$fam_count" -lt "$all_count" ] || fail "changed-informed pure family still full suite"
  # Directly exercise --changed: empty or partial selection is ok; must not
  # exceed the suite and must never silently become --all by accident.
  listed=$("$RUNNER" --list --changed --base HEAD 2>/dev/null || true)
  if [ -n "$listed" ]; then
    listed_count=$(printf '%s\n' "$listed" | wc -l | tr -d ' ')
    [ "$listed_count" -le "$all_count" ] || fail "changed selection larger than suite"
  fi
  # A single test path selects only that script (same contract as a
  # tests/*.test.sh change entry in the map).
  listed=$("$RUNNER" --list tests/fm-brief.test.sh)
  [ "$listed" = "tests/fm-brief.test.sh" ] \
    || fail "test-file-only change contract should select one script"
  pass "changed-file selection stays conservative (never silent full suite)"
}

init_changed_fixture_repo() {
  local repo=$1 script
  mkdir -p "$repo/bin" "$repo/tests"
  cp "$RUNNER" "$repo/bin/fm-test-run.sh"
  chmod +x "$repo/bin/fm-test-run.sh"
  for script in \
    fm-brief.test.sh \
    fm-ask-user-authority.test.sh \
    fm-cd-pretool-check.test.sh \
    fm-daemon.test.sh \
    fm-backend-herdr-smoke.test.sh \
    fm-secondmate-safety.test.sh \
    fm-session-start.test.sh \
    fm-afk-pi-herdr-return-e2e.test.sh \
    fm-backend.test.sh \
    fm-pr-merge.test.sh \
    fm-pi-watch-extension.test.sh \
    fm-afk-return.test.sh \
    fm-bearings-snapshot.test.sh \
    fm-backend-cmux.test.sh \
    fm-backend-zellij.test.sh \
    fm-backend-orca.test.sh; do
    printf '#!/usr/bin/env bash\n# tests/lib.sh\n' >"$repo/tests/$script"
    chmod +x "$repo/tests/$script"
  done
  : >"$repo/tests/lib.sh"
  : >"$repo/tests/fm-backend-herdr-eventwait.test.py"
  : >"$repo/bin/fm-supervisor-target-lib.sh"
  : >"$repo/bin/unmapped-source.sh"
  printf '# .claude/settings.json\n# .pi/extensions/fm-primary-turnend-guard.ts\n' \
    >>"$repo/tests/fm-cd-pretool-check.test.sh"
  printf '# .pi/extensions/fm-primary-pi-watch.ts\n' >>"$repo/tests/fm-pi-watch-extension.test.sh"
  mkdir -p "$repo/.agents/skills/example" "$repo/.claude" "$repo/.pi/extensions" "$repo/src"
  : >"$repo/.agents/skills/example/SKILL.md"
  : >"$repo/.claude/settings.json"
  : >"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  : >"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  : >"$repo/src/unmapped.ts"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm baseline
}

test_changed_dependency_selection_and_unmapped_failure() {
  local tmp repo listed rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-changed.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"

  printf '\n' >>"$repo/tests/lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-pr-merge.test.sh" "shared helper selects pr-forge dependents"
  assert_contains "$listed" "tests/fm-secondmate-safety.test.sh" "shared helper selects secondmate dependents"
  assert_contains "$listed" "tests/fm-bearings-snapshot.test.sh" "shared helper selects snapshot dependents"
  git -C "$repo" add tests/lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm helper-change

  printf '\n' >>"$repo/tests/fm-backend-herdr-eventwait.test.py"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-backend-herdr-smoke.test.sh" "eventwait test selects Herdr coverage"
  assert_contains "$listed" "tests/fm-backend.test.sh" "eventwait test selects backend coverage"
  git -C "$repo" add tests/fm-backend-herdr-eventwait.test.py
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm eventwait-change

  printf '\n' >>"$repo/bin/fm-supervisor-target-lib.sh"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-daemon.test.sh" "supervisor target selects daemon coverage"
  assert_contains "$listed" "tests/fm-afk-return.test.sh" "supervisor target selects afk coverage"
  git -C "$repo" add bin/fm-supervisor-target-lib.sh
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm supervisor-change

  printf '\n' >>"$repo/.agents/skills/example/SKILL.md"
  printf '\n' >>"$repo/.claude/settings.json"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-pi-watch.ts"
  printf '\n' >>"$repo/.pi/extensions/fm-primary-turnend-guard.ts"
  listed=$(cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD)
  assert_contains "$listed" "tests/fm-ask-user-authority.test.sh" "skill source selects pure contract coverage"
  assert_contains "$listed" "tests/fm-cd-pretool-check.test.sh" "Claude and Pi source selects hook coverage"
  assert_contains "$listed" "tests/fm-pi-watch-extension.test.sh" "Pi source selects watcher coverage"
  git -C "$repo" add .agents .claude .pi
  git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit -qm non-bin-source-change

  printf '\n' >>"$repo/src/unmapped.ts"
  set +e
  (cd "$repo" && bin/fm-test-run.sh --list --changed --base HEAD) >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "unmapped changed source must fail with exit 2, got $rc"
  grep -Fq 'no changed-test mapping for source path: src/unmapped.ts' "$tmp/err" \
    || fail "unmapped changed source failure is not actionable: $(cat "$tmp/err")"
  rm -rf "$tmp"
  pass "changed selection covers dependents and fails closed for unmapped source"
}

test_empty_selection_emits_summary() {
  local tmp repo out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-empty.XXXXXX")
  repo="$tmp/repo"
  init_changed_fixture_repo "$repo"
  printf 'documentation only\n' >"$repo/README.md"
  out=$(cd "$repo" && bin/fm-test-run.sh --changed --base HEAD --json "$tmp/artifacts/timing.json" 2>"$tmp/err") \
    || fail "empty valid changed selection must pass"
  [ "$out" = "FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0" ] \
    || fail "empty selection summary is missing or non-deterministic: $out"
  json="$tmp/artifacts/timing.json"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["summary"] == {"duration_ms": 0, "failed": 0, "skipped_gate": 0, "total": 0}
assert doc["scripts"] == []
assert doc["families"] == []
' "$json" || { rm -rf "$tmp"; fail "empty selection JSON summary is wrong"; }
  rm -rf "$tmp"
  pass "empty changed selection emits deterministic text and JSON summaries"
}

test_timing_markers_and_json() {
  local tmp fixture out json begin_n end_n summary
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-timing.XXXXXX")
  fixture="$tmp/ok.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$fixture" <<'SH'
#!/usr/bin/env bash
echo "ok - fixture"
exit 0
SH
  chmod +x "$fixture"
  "$RUNNER" --json "$json" "$fixture" >"$out" 2>"$tmp/err.txt" \
    || { rm -rf "$tmp"; fail "runner should pass on a green fixture"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$out" || true)
  [ "$begin_n" -eq 1 ] || fail "expected one FM_TEST_BEGIN, got $begin_n"
  [ "$end_n" -eq 1 ] || fail "expected one FM_TEST_END, got $end_n"
  grep -Eq '^FM_TEST_BEGIN .+ family=unclassified expected_gate_skip=none$' "$out" \
    || fail "BEGIN line missing family/expected_gate_skip: $(grep '^FM_TEST_BEGIN' "$out")"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=false$' "$out" \
    || fail "END line missing exit/duration/gate_skip: $(grep '^FM_TEST_END' "$out")"
  summary=$(grep '^FM_TEST_SUMMARY ' "$out" || true)
  assert_contains "$summary" "total=1" "summary total"
  assert_contains "$summary" "failed=0" "summary failed"
  assert_contains "$summary" "skipped_gate=0" "summary skipped_gate"
  grep -q '^FM_TEST_SLOWEST rank=1 ' "$out" \
    || fail "expected FM_TEST_SLOWEST rank=1"
  [ -f "$json" ] || fail "JSON timing artifact was not written"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$json" \
    || fail "JSON timing artifact is not valid JSON"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert "scripts" in doc and len(doc["scripts"]) == 1, doc
assert doc["scripts"][0]["exit"] == 0
assert doc["scripts"][0]["gate_skip"] is False
assert doc["summary"]["total"] == 1
assert doc["summary"]["failed"] == 0
assert "duration_ms" in doc["scripts"][0]
assert "family" in doc["scripts"][0]
' "$json" || { rm -rf "$tmp"; fail "JSON timing artifact missing required fields"; }
  rm -rf "$tmp"
  pass "timing markers and JSON artifact are valid"
}

test_aggregate_exit_behavior() {
  local tmp pass_f fail_f rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-agg.XXXXXX")
  pass_f="$tmp/pass.test.sh"
  fail_f="$tmp/fail.test.sh"
  cat >"$pass_f" <<'SH'
#!/usr/bin/env bash
echo "ok - pass"
exit 0
SH
  cat >"$fail_f" <<'SH'
#!/usr/bin/env bash
echo "not ok - fail"
exit 1
SH
  chmod +x "$pass_f" "$fail_f"
  set +e
  "$RUNNER" "$pass_f" "$fail_f" >"$tmp/out.txt" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "aggregate exit must be non-zero when any script fails"
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out.txt" \
    || fail "summary should report total=2 failed=1: $(grep FM_TEST_SUMMARY "$tmp/out.txt")"
  # All-green stays 0.
  set +e
  "$RUNNER" "$pass_f" >"$tmp/out2.txt" 2>"$tmp/err2.txt"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { rm -rf "$tmp"; fail "aggregate exit must be 0 when every script passes"; }
  rm -rf "$tmp"
  pass "aggregate exit reflects any script failure"
}

test_gate_skip_accounting() {
  local tmp skip_f out json
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  json="$tmp/timing.json"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  "$RUNNER" --json "$json" "$skip_f" >"$out" 2>"$tmp/err.txt" \
    || fail "gate-skip fixture must exit 0 from the runner"
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$out" \
    || fail "END must mark gate_skip=true: $(grep '^FM_TEST_END' "$out")"
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$out" \
    || fail "summary must count skipped_gate=1: $(grep FM_TEST_SUMMARY "$out")"
  python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["scripts"][0]["gate_skip"] is True
assert doc["summary"]["skipped_gate"] == 1
assert doc["summary"]["failed"] == 0
' "$json" || { rm -rf "$tmp"; fail "JSON gate_skip accounting is wrong"; }
  rm -rf "$tmp"
  pass "gate-skip accounting is honest and non-failing"
}

test_fail_on_gate_skip_token() {
  local tmp skip_f out rc
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-fail-skip.XXXXXX")
  skip_f="$tmp/skip.test.sh"
  out="$tmp/out.txt"
  cat >"$skip_f" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found"
exit 0
SH
  chmod +x "$skip_f"
  set +e
  "$RUNNER" --fail-on-gate-skip 'herdr not found' "$skip_f" >"$out" 2>"$tmp/err.txt"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fail-on-gate-skip must make herdr-not-found a hard failure"
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$out" \
    || fail "summary must report failed=1 under fail-on-gate-skip: $(grep FM_TEST_SUMMARY "$out")"
  grep -q 'required gate skip token' "$tmp/err.txt" \
    || fail "runner must log the required gate skip token"
  rm -rf "$tmp"
  pass "fail-on-gate-skip converts herdr-not-found into a hard failure"
}

test_exclude_family() {
  local listed
  listed=$("$RUNNER" --list --all --exclude-family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "exclude-family real-herdr-gated left a real-herdr script"
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-lint.test.sh' \
    || fail "exclude-family must retain pure-contract-unit scripts"
  # Explicit family mode still works; exclude of a different family is a no-op.
  listed=$("$RUNNER" --list --family real-herdr-gated)
  printf '%s\n' "$listed" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "family real-herdr-gated must list smoke test"
  pass "exclude-family drops the named primary family after selection"
}

test_portable_shard_union_and_coverage_guard() {
  local s1 s2 proven serial herdr all_count union_count overlap out first
  s1=$("$RUNNER" --list --lane portable-parallel-1)
  s2=$("$RUNNER" --list --lane portable-parallel-2)
  proven=$("$RUNNER" --list --proven-isolated)
  serial=$("$RUNNER" --list --lane portable-serial)
  herdr=$("$RUNNER" --list --family real-herdr-gated)
  [ -n "$s1" ] && [ -n "$s2" ] || fail "portable parallel shards must be non-empty"
  # Shards disjoint.
  overlap=$(comm -12 <(printf '%s\n' "$s1" | LC_ALL=C sort) <(printf '%s\n' "$s2" | LC_ALL=C sort) || true)
  [ -z "$overlap" ] || fail "portable parallel shards overlap: $overlap"
  # Union of shards equals proven-isolated.
  [ "$(printf '%s\n' "$s1" "$s2" | LC_ALL=C sort -u)" = \
    "$(printf '%s\n' "$proven" | LC_ALL=C sort -u)" ] \
    || fail "shard union must equal proven-isolated set"
  # No herdr in portable lanes.
  printf '%s\n' "$s1" "$s2" "$serial" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    && fail "portable lanes must not include real-herdr-gated smoke"
  printf '%s\n' "$herdr" | grep -Fq 'tests/fm-backend-herdr-smoke.test.sh' \
    || fail "herdr family must include smoke"
  out=$("$RUNNER" --check-coverage)
  assert_contains "$out" "FM_TEST_COVERAGE ok" "coverage guard success marker"
  all_count=$("$RUNNER" --list --all | wc -l | tr -d ' ')
  union_count=$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$union_count" = "$all_count" ] \
    || fail "union of lanes ($union_count) must equal --all ($all_count)"
  # No duplicates across the four partitions.
  [ "$(printf '%s\n' "$s1" "$s2" "$serial" "$herdr" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" = "0" ] \
    || fail "lanes must not duplicate scripts"
  # LPT order: first script of shard 1 is the longest proven script.
  first=$(printf '%s\n' "$s1" | head -n 1)
  [ "$first" = "tests/fm-x-mode.test.sh" ] \
    || fail "shard 1 must start with the longest proven script, got $first"
  pass "portable shard union, disjointness, and coverage guard hold"
}

test_portable_serial_shards_partition_the_serial_lane() {
  local lanes count serial shard listed union dups shard_lane total cap
  lanes=$("$RUNNER" --list-lanes)
  count=$(printf '%s\n' "$lanes" | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  [ "$count" -ge 2 ] || fail "expected at least two portable serial shard lanes, got $count"
  printf '%s\n' "$lanes" | grep -q "^portable-serial-1of${count}\$" \
    || fail "shard lane names must carry the shard count ${count}: $lanes"

  serial=$("$RUNNER" --list --lane portable-serial | LC_ALL=C sort)
  union=""
  shard=1
  while [ "$shard" -le "$count" ]; do
    shard_lane="portable-serial-${shard}of${count}"
    listed=$("$RUNNER" --list --lane "$shard_lane")
    [ -n "$listed" ] || fail "$shard_lane selected no tests"
    union=$(printf '%s\n%s' "$union" "$listed")
    shard=$((shard + 1))
  done
  union=$(printf '%s\n' "$union" | grep -v '^$' || true)

  dups=$(printf '%s\n' "$union" | LC_ALL=C sort | uniq -d || true)
  [ -z "$dups" ] || fail "portable serial shards run the same script twice: $dups"
  [ "$(printf '%s\n' "$union" | LC_ALL=C sort)" = "$serial" ] \
    || fail "portable serial shards must exactly cover the portable serial lane"

  # Every shard carries a real share of the lane, so no degenerate partition
  # leaves one runner doing nearly all of the work the split exists to spread.
  total=$(printf '%s\n' "$serial" | wc -l | tr -d ' ')
  cap=$((total * 6 / 10))
  shard=1
  while [ "$shard" -le "$count" ]; do
    listed=$("$RUNNER" --list --lane "portable-serial-${shard}of${count}" | wc -l | tr -d ' ')
    [ "$listed" -ge 2 ] \
      || fail "portable-serial-${shard}of${count} holds only $listed script(s)"
    [ "$listed" -le "$cap" ] \
      || fail "portable-serial-${shard}of${count} holds $listed of $total scripts"
    shard=$((shard + 1))
  done

  # Assignment is deterministic across invocations.
  [ "$("$RUNNER" --list --lane "portable-serial-1of${count}")" = \
    "$("$RUNNER" --list --lane "portable-serial-1of${count}")" ] \
    || fail "portable serial shard membership must be deterministic"
  pass "portable serial shards are a deterministic disjoint cover of the serial lane"
}

test_portable_serial_shard_lane_refusals() {
  local tmp count rc other
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-shard-lane.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  other=$((count + 1))

  # A lane built for a different shard count must refuse rather than run a
  # partial suite: this is what keeps a CI matrix from silently dropping tests.
  set +e
  "$RUNNER" --list --lane "portable-serial-1of${other}" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "mismatched shard count must refuse (exit 2), got $rc"
  [ ! -s "$tmp/out" ] || fail "mismatched shard count must not list tests"
  grep -Fq "configured for $count" "$tmp/err" \
    || fail "mismatch refusal must name the configured count: $(cat "$tmp/err")"

  set +e
  "$RUNNER" --list --lane "portable-serial-$((count + 1))of${count}" >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "out-of-range shard index must refuse (exit 2), got $rc"
  grep -Fq "outside 1..$count" "$tmp/err2" \
    || fail "range refusal message missing: $(cat "$tmp/err2")"

  set +e
  "$RUNNER" --list --lane portable-serial-1 >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "shard lane without a count must refuse (exit 2), got $rc"
  rm -rf "$tmp"
  pass "portable serial shard lanes refuse mismatched, out-of-range, and countless names"
}

test_jobs_requires_proven_isolated() {
  local tmp rc shard_lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs.XXXXXX")
  set +e
  "$RUNNER" --jobs 2 --lane portable-serial >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with portable-serial must refuse (exit 2), got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err" \
    || fail "--jobs refusal message missing: $(cat "$tmp/err")"
  set +e
  "$RUNNER" --jobs 2 tests/fm-watcher-lock.test.sh >"$tmp/out2" 2>"$tmp/err2"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs on watcher-lock must refuse, got $rc"
  # Sharding across runners never relaxes the serial rule inside one shard.
  shard_lane=$("$RUNNER" --list-lanes | grep -m1 '^portable-serial-[0-9]*of[0-9]*$')
  set +e
  "$RUNNER" --jobs 2 --lane "$shard_lane" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "--jobs with a portable serial shard must refuse, got $rc"
  grep -Fq 'not in the proven-isolated set' "$tmp/err3" \
    || fail "shard --jobs refusal message missing: $(cat "$tmp/err3")"
  rm -rf "$tmp"
  pass "--jobs refuses non-proven / stateful selections"
}

test_jobs_parallel_scheduler_and_failure_propagation() {
  local tmp repo runner evidence fake_bin a b c d rc begin_n end_n
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-jobs-sched.XXXXXX")
  repo="$tmp/repo"
  runner="$repo/bin/fm-test-run.sh"
  evidence="$tmp/evidence"
  fake_bin="$tmp/fake-bin"
  a=tests/fm-brief.test.sh
  b=tests/fm-composer-lib.test.sh
  c=tests/fm-lint.test.sh
  d=tests/fm-supervision-instructions.test.sh
  mkdir -p "$repo/bin" "$repo/tests" "$evidence" "$fake_bin"
  cp "$RUNNER" "$runner"
  cat >"$fake_bin/stat" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "-c" ] && [ "$2" = "%a" ]; then
  printf '700\n'
  exit 0
fi
if [ "$1" = "-f" ] && [ "$2" = "%Lp" ]; then
  printf '  File: "%s"\n    ID: fake Namelen: 255 Type: ext2/ext3\n700\n' "$3"
  exit 0
fi
exit 1
SH
  # The slow fixture blocks on the replacement fixture's own signal rather than
  # a wall-clock sleep, so a loaded machine cannot let it finish first and turn
  # a correct scheduler into a failure. The bounded deadline is only there so a
  # scheduler that really does wait for the oldest worker still reports instead
  # of hanging.
  cat >"$repo/$a" <<'SH'
#!/usr/bin/env bash
if [ -n "${SCHED_WAIT_FOR_REPLACEMENT:-}" ]; then
  waited=0
  while [ ! -e "$SCHED_EVIDENCE/replacement-started" ] && [ "$waited" -lt 600 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
fi
touch "$SCHED_EVIDENCE/slow-done"
echo "ok - slow fixture"
SH
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "ok - fast fixture"
SH
  cat >"$repo/$c" <<'SH'
#!/usr/bin/env bash
# Read the evidence before releasing the slow fixture, so the release can never
# race ahead of the check it is being used to make.
if [ -e "$SCHED_EVIDENCE/slow-done" ]; then
  touch "$SCHED_EVIDENCE/replacement-started"
  echo "not ok - scheduler waited for oldest worker"
  exit 1
fi
touch "$SCHED_EVIDENCE/replacement-started"
echo "ok - replacement fixture started before slow fixture finished"
SH
  chmod +x "$runner" "$repo/$a" "$repo/$b" "$repo/$c" "$fake_bin/stat"
  set +e
  PATH="$fake_bin:$PATH" SCHED_EVIDENCE="$evidence" SCHED_WAIT_FOR_REPLACEMENT=1 \
    "$runner" --jobs 2 --json "$tmp/timing.json" \
    "$a" "$b" "$c" >"$tmp/out" 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || { cat "$tmp/out" "$tmp/err"; rm -rf "$tmp"; fail "jobs=2 must refill the first completed slot"; }
  begin_n=$(grep -c '^FM_TEST_BEGIN ' "$tmp/out" || true)
  end_n=$(grep -c '^FM_TEST_END ' "$tmp/out" || true)
  [ "$begin_n" -eq 3 ] || fail "expected 3 BEGIN markers, got $begin_n"
  [ "$end_n" -eq 3 ] || fail "expected 3 END markers, got $end_n"
  grep -q 'FM_TEST_SUMMARY total=3 failed=0' "$tmp/out" \
    || fail "summary missing for jobs run: $(grep FM_TEST_SUMMARY "$tmp/out")"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==0
assert "jobs=2" in doc["selection"]
' "$tmp/timing.json" || { rm -rf "$tmp"; fail "jobs JSON artifact wrong"; }

  # Non-proven path is refused before any worker starts (no race masking).
  cat >"$tmp/fail.test.sh" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate fail"
exit 1
SH
  chmod +x "$tmp/fail.test.sh"
  set +e
  "$runner" --jobs 2 "$a" "$tmp/fail.test.sh" >"$tmp/out3" 2>"$tmp/err3"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "jobs with non-proven fail fixture must refuse before run, got $rc"

  # Parallel failure propagation stays inside the private runner fixture.
  cat >"$repo/$b" <<'SH'
#!/usr/bin/env bash
echo "not ok - deliberate proven-set fail"
exit 1
SH
  chmod +x "$repo/$b"
  set +e
  SCHED_EVIDENCE="$evidence" "$runner" --jobs 2 "$a" "$b" >"$tmp/out4" 2>"$tmp/err4"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "jobs aggregate must be non-zero when a proven worker fails"; }
  grep -q 'FM_TEST_SUMMARY total=2 failed=1' "$tmp/out4" \
    || { rm -rf "$tmp"; fail "jobs failure summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out4")"; }

  cat >"$repo/$d" <<'SH'
#!/usr/bin/env bash
echo "skip: herdr not found" >&2
exit 0
SH
  chmod +x "$repo/$d"
  set +e
  "$runner" --jobs 2 --fail-on-gate-skip 'herdr not found' "$d" >"$tmp/out5" 2>"$tmp/err5"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || { rm -rf "$tmp"; fail "parallel stderr gate skip must hard-fail"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=1' "$tmp/out5" \
    || { rm -rf "$tmp"; fail "parallel stderr hard-fail summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out5")"; }

  "$runner" --jobs 2 "$d" >"$tmp/out6" 2>"$tmp/err6" \
    || { rm -rf "$tmp"; fail "ordinary parallel stderr gate skip must remain successful"; }
  grep -Eq '^FM_TEST_END .+ exit=0 duration_ms=[0-9]+ gate_skip=true$' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr gate skip was not recorded"; }
  grep -q 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=1' "$tmp/out6" \
    || { rm -rf "$tmp"; fail "parallel stderr skip summary wrong: $(grep FM_TEST_SUMMARY "$tmp/out6")"; }

  rm -rf "$tmp"
  pass "jobs scheduler runs proven scripts; failure propagates; non-proven refused"
}

test_aggregate_json() {
  local tmp a b
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-aggjson.XXXXXX")
  cat >"$tmp/a.json" <<'JSON'
{
  "run_id": "a",
  "selection": "lane=portable-parallel-1",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:01:00Z",
  "summary": {"total": 1, "failed": 0, "skipped_gate": 0, "duration_ms": 1000},
  "scripts": [{"path": "tests/a.test.sh", "family": "pure-contract-unit", "duration_ms": 1000, "exit": 0, "gate_skip": false}]
}
JSON
  cat >"$tmp/b.json" <<'JSON'
{
  "run_id": "b",
  "selection": "lane=portable-serial",
  "started_at": "2026-07-22T00:00:00Z",
  "finished_at": "2026-07-22T00:02:00Z",
  "summary": {"total": 2, "failed": 1, "skipped_gate": 0, "duration_ms": 2000},
  "scripts": [
    {"path": "tests/b.test.sh", "family": "afk", "duration_ms": 1500, "exit": 1, "gate_skip": false},
    {"path": "tests/c.test.sh", "family": "afk", "duration_ms": 500, "exit": 0, "gate_skip": false}
  ]
}
JSON
  out=$("$RUNNER" --aggregate-json "$tmp/out.json" "$tmp/a.json" "$tmp/b.json")
  assert_contains "$out" "FM_TEST_AGGREGATE lanes=2 total=3 failed=1" "aggregate summary line"
  python3 -c '
import json,sys
doc=json.load(open(sys.argv[1]))
assert doc["kind"]=="aggregate"
assert doc["summary"]["lanes"]==2
assert doc["summary"]["total"]==3
assert doc["summary"]["failed"]==1
assert doc["summary"]["critical_path_duration_ms"]==2000
assert len(doc["scripts"])==3
' "$tmp/out.json" || { rm -rf "$tmp"; fail "aggregate JSON shape wrong"; }
  rm -rf "$tmp"
  pass "aggregate-json merges lane timing artifacts"
}

# Write one fixture timing artifact per serial shard, spreading a requested wall
# evenly across whatever scripts that shard currently holds.
#
# Durations are constructed from the requested wall, never read from the runner's
# weight hints: the hints are an implementation detail that changes whenever the
# suite is remeasured, and a fixture built from them would silently re-derive the
# very numbers under test.
#   $1 dir  $2 wall in ms for every shard  $3 optional script to omit
#   $4 optional shard index given $5 instead of $2
fm_write_serial_fixture() {
  local dir=$1 wall=$2 drop=${3:-} heavy=${4:-0} heavy_wall=${5:-0} count k target
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  mkdir -p "$dir"
  k=1
  while [ "$k" -le "$count" ]; do
    "$RUNNER" --list --lane "portable-serial-${k}of${count}" >"$dir/members.$k"
    target=$wall
    [ "$k" = "$heavy" ] && target=$heavy_wall
    python3 - "$dir/shard-$k.json" "$k" "$count" "$target" "$drop" "$dir/members.$k" <<'PY'
import json, sys

out, k, count, target, drop, members = sys.argv[1:7]
k, count, target = int(k), int(count), int(target)

paths = [l.strip() for l in open(members, encoding="utf-8") if l.strip() and l.strip() != drop]
if not paths:
    raise SystemExit("shard %d fixture would be empty" % k)

# Spread the requested wall evenly, giving the first script the remainder so the
# shard total is exactly the wall this fixture claims to represent.
each, rest = divmod(target, len(paths))
rows = []
for i, p in enumerate(paths):
    rows.append({
        "path": p,
        "duration_ms": each + (rest if i == 0 else 0),
        "exit": 0,
        "family": "fixture",
        "gate_skip": False,
        "expected_gate_skip": "none",
    })
json.dump({
    "selection": "lane=portable-serial-%dof%d" % (k, count),
    "run_id": "fixture",
    "scripts": rows,
    "summary": {
        "total": len(rows), "failed": 0, "skipped_gate": 0,
        "duration_ms": sum(r["duration_ms"] for r in rows),
    },
}, open(out, "w", encoding="utf-8"))
PY
    k=$((k + 1))
  done
}

# Read the control's own declared bounds off its published output rather than out
# of the script that defines them, so these tests keep working when the budget is
# re-derived and fail only if the control's behavior actually changes.
#   echoes: <shards> <budget_ms> <allowed_ms> <headroom_ms>
fm_serial_budget_bounds() {
  local tmp line shards budget allowed headroom
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-bounds.XXXXXX")
  fm_write_serial_fixture "$tmp/probe" 1000
  line=$("$RUNNER" --check-budget "$tmp/probe"/shard-*.json 2>/dev/null) \
    || { rm -rf "$tmp"; fail "the budget control must publish its bounds on a trivial lane"; }
  rm -rf "$tmp"
  shards=$(printf '%s\n' "$line" | sed -n 's/.*shards=\([0-9]*\).*/\1/p')
  budget=$(printf '%s\n' "$line" | sed -n 's/.*budget_ms=\([0-9]*\).*/\1/p')
  allowed=$(printf '%s\n' "$line" | sed -n 's/.*allowed_ms=\([0-9]*\).*/\1/p')
  headroom=$(printf '%s\n' "$line" | sed -n 's/.*headroom_ms=\([0-9]*\).*/\1/p')
  [ -n "$shards" ] && [ -n "$budget" ] && [ -n "$allowed" ] && [ -n "$headroom" ] \
    || fail "FM_TEST_BUDGET must publish shards, budget_ms, allowed_ms and headroom_ms: $line"
  printf '%s %s %s %s\n' "$shards" "$budget" "$allowed" "$headroom"
}

# The recurrence control for serial-lane budget drift. The property that matters
# is three-valued: a lane inside its bound passes, a lane that actually grew
# fails, and a run whose artifacts are missing or unreadable is could-not-observe
# rather than either. Ordinary runner jitter must stay on the passing side, or
# the control gets ignored and stops protecting anything.
test_serial_budget_control_verdicts() {
  local tmp rc out bounds shards budget allowed
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget.XXXXXX")
  bounds=$(fm_serial_budget_bounds)
  shards=$(printf '%s' "$bounds" | cut -d' ' -f1)
  budget=$(printf '%s' "$bounds" | cut -d' ' -f2)
  allowed=$(printf '%s' "$bounds" | cut -d' ' -f3)

  # Exactly at the declared budget.
  fm_write_serial_fixture "$tmp/ok" $((budget / shards))
  set +e
  out=$("$RUNNER" --check-budget "$tmp/ok"/shard-*.json 2>"$tmp/ok.err")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a lane at its declared budget must pass, got $rc: $(cat "$tmp/ok.err")"
  assert_contains "$out" "FM_TEST_BUDGET verdict=ok" "a passing lane must report verdict=ok"

  # Jitter control: just inside the allowance is a slow runner, not a defect,
  # and reporting it as one is how a control gets ignored.
  fm_write_serial_fixture "$tmp/jitter" $(((allowed - allowed / 50) / shards))
  set +e
  out=$("$RUNNER" --check-budget "$tmp/jitter"/shard-*.json 2>&1)
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "a lane inside its drift allowance must not fail, got $rc: $out"

  # Just past the allowance is the signal this exists for. The two fixtures
  # differ by about 4% of the lane, so the boundary is where it is claimed to be
  # rather than somewhere convenient.
  fm_write_serial_fixture "$tmp/grown" $(((allowed + allowed / 50) / shards + 1))
  set +e
  out=$("$RUNNER" --check-budget "$tmp/grown"/shard-*.json 2>"$tmp/grown.err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a lane past its drift allowance must fail (exit 1), got $rc"
  assert_contains "$out" "verdict=drifted" "a grown lane must report verdict=drifted"
  assert_grep 'lane grew to' "$tmp/grown.err" "the failure must name lane growth"
  [ "$allowed" -gt "$budget" ] || fail "the allowance must sit above the declared budget"

  rm -rf "$tmp"
  pass "serial budget control passes at budget, absorbs jitter, and fails just past its allowance"
}

# The incident shape: the lane total stayed unremarkable while one shard carried
# the imbalance to the edge of its hang tripwire and cancelled whole runs. A
# control that only watched the lane total would have called that healthy.
test_serial_budget_control_catches_a_single_shard_near_the_tripwire() {
  local tmp rc out bounds shards budget allowed headroom rest lane
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget-shard.XXXXXX")
  bounds=$(fm_serial_budget_bounds)
  shards=$(printf '%s' "$bounds" | cut -d' ' -f1)
  budget=$(printf '%s' "$bounds" | cut -d' ' -f2)
  allowed=$(printf '%s' "$bounds" | cut -d' ' -f3)
  headroom=$(printf '%s' "$bounds" | cut -d' ' -f4)
  [ "$shards" -ge 2 ] || fail "this test needs at least two shards to skew one"

  # One shard just past the headroom bound; the rest carry the remaining budget
  # so the LANE total stays inside its allowance. Only the shard rule can fail
  # this, which is the point: the original incident looked healthy in aggregate.
  rest=$(((budget - headroom) / (shards - 1)))
  [ "$rest" -gt 0 ] || fail "the declared budget leaves no room to build this fixture"
  fm_write_serial_fixture "$tmp/skew" "$rest" '' 2 $((headroom + headroom / 20))

  set +e
  out=$("$RUNNER" --check-budget "$tmp/skew"/shard-*.json 2>"$tmp/skew.err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "a shard past its headroom bound must fail (exit 1), got $rc: $out"
  assert_grep 'hang tripwire' "$tmp/skew.err" "the failure must name the tripwire it approached"
  assert_contains "$out" "worst_shard=2" "the verdict must name which shard carried the load"
  assert_contains "$out" "verdict=drifted" "an over-headroom shard must report verdict=drifted"

  # Prove the lane rule stayed silent, so this really is the shard rule firing.
  assert_no_grep 'lane grew to' "$tmp/skew.err" "the lane bound must not be what failed here"
  lane=$(printf '%s\n' "$out" | sed -n 's/.*lane_ms=\([0-9]*\).*/\1/p')
  [ "$lane" -le "$allowed" ] || fail "fixture lane total $lane must stay inside the allowance $allowed"

  rm -rf "$tmp"
  pass "serial budget control fails one shard near its tripwire while the lane looks healthy"
}

# Could-not-observe is the third value and is never a pass. A shard cancelled at
# its timeout uploads no timing artifact, which is exactly this state, so a
# control that read a missing artifact as success would go quiet during the very
# failure it exists to catch.
test_serial_budget_control_reports_could_not_observe() {
  local tmp rc out count
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget-unobserved.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')

  fm_write_serial_fixture "$tmp/gap" 1000
  rm -f "$tmp/gap/shard-2.json"
  set +e
  out=$("$RUNNER" --check-budget "$tmp/gap"/shard-*.json 2>"$tmp/gap.err")
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a missing shard artifact must be could-not-observe (exit 3), got $rc"
  [ "$rc" -ne 0 ] || fail "could-not-observe must never be reported as a pass"
  assert_contains "$out" "verdict=could-not-observe" "a missing shard must report could-not-observe"
  assert_grep 'shard(s) 2' "$tmp/gap.err" "the reason must name the unobserved shard"

  # An unreadable artifact is the same third value, not a failure of the lane.
  fm_write_serial_fixture "$tmp/bad" 1000
  printf 'not json at all\n' >"$tmp/bad/shard-1.json"
  set +e
  out=$("$RUNNER" --check-budget "$tmp/bad"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an unreadable artifact must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "an unreadable artifact must report could-not-observe"

  # Artifacts from a run built for a different shard count say nothing about
  # this head's lane, so they are unobserved rather than compared anyway.
  fm_write_serial_fixture "$tmp/stale" 1000
  python3 - "$tmp/stale/shard-1.json" "$count" <<'PY'
import json, sys
p, count = sys.argv[1], int(sys.argv[2])
doc = json.load(open(p, encoding="utf-8"))
doc["selection"] = "lane=portable-serial-1of%d" % (count + 1)
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/stale"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a foreign shard count must be could-not-observe (exit 3), got $rc"

  fm_write_serial_fixture "$tmp/out-of-range" 1000
  cp "$tmp/out-of-range/shard-1.json" "$tmp/out-of-range/shard-0.json"
  python3 - "$tmp/out-of-range/shard-0.json" "$count" <<'PY'
import json, sys
p, count = sys.argv[1], int(sys.argv[2])
doc = json.load(open(p, encoding="utf-8"))
doc["selection"] = "lane=portable-serial-0of%d" % count
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/out-of-range"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an out-of-range shard index must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "an out-of-range shard index must report could-not-observe"
  assert_not_contains "$out" "verdict=drifted" "an out-of-range shard index must not report drifted"

  fm_write_serial_fixture "$tmp/unconvertible" 1000
  python3 - "$tmp/unconvertible/shard-1.json" "$count" <<'PY'
import json, sys
p, count = sys.argv[1], int(sys.argv[2])
doc = json.load(open(p, encoding="utf-8"))
doc["selection"] = "lane=portable-serial-%sof%d" % ("9" * 5000, count)
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/unconvertible"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "unconvertible numeric shard metadata must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "unconvertible numeric shard metadata must report could-not-observe"
  assert_not_contains "$out" "verdict=drifted" "unconvertible numeric shard metadata must not report drifted"

  # A malformed negative timing can shrink the total enough to manufacture an
  # apparently healthy lane, so it is unreadable evidence rather than a pass.
  fm_write_serial_fixture "$tmp/negative" 1000
  python3 - "$tmp/negative/shard-1.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding="utf-8"))
doc["scripts"][0]["duration_ms"] = -1
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/negative"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a negative duration must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "a negative duration must report could-not-observe"

  fm_write_serial_fixture "$tmp/boolean" 1000
  python3 - "$tmp/boolean/shard-1.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding="utf-8"))
doc["scripts"][0]["duration_ms"] = True
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/boolean"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a boolean duration must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "a boolean duration must report could-not-observe"

  # Valid JSON can still be structurally invalid. It must reach the same third
  # value instead of crashing into CI's lane-drift branch.
  fm_write_serial_fixture "$tmp/invalid-path" 1000
  python3 - "$tmp/invalid-path/shard-1.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding="utf-8"))
doc["scripts"][0]["path"] = None
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/invalid-path"/shard-*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "an invalid script path must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "an invalid script path must report could-not-observe"

  # A malformed extra artifact must not disappear as though it belonged to a
  # different lane and let an otherwise complete artifact set pass.
  fm_write_serial_fixture "$tmp/invalid-selection" 1000
  cp "$tmp/invalid-selection/shard-1.json" "$tmp/invalid-selection/malformed.json"
  python3 - "$tmp/invalid-selection/malformed.json" <<'PY'
import json, sys
p = sys.argv[1]
doc = json.load(open(p, encoding="utf-8"))
doc["selection"] = {"lane": "portable-serial-1of8"}
json.dump(doc, open(p, "w", encoding="utf-8"))
PY
  set +e
  out=$("$RUNNER" --check-budget "$tmp/invalid-selection"/*.json 2>/dev/null)
  rc=$?
  set -e
  [ "$rc" -eq 3 ] || fail "a structurally invalid selection must be could-not-observe (exit 3), got $rc"
  assert_contains "$out" "verdict=could-not-observe" "a structurally invalid selection must report could-not-observe"
  assert_not_contains "$out" "verdict=drifted" "a structurally invalid selection must not report drifted"

  rm -rf "$tmp"
  pass "serial budget control reports could-not-observe instead of passing on absent or invalid evidence"
}

# The partition half. A run that quietly executed fewer scripts than the lane
# declares is a coverage defect, and it would otherwise look like a lane that
# comfortably beat its budget.
test_serial_budget_control_checks_the_partition_it_measured() {
  local tmp rc out dropped count
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget-partition.XXXXXX")
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  dropped=$("$RUNNER" --list --lane "portable-serial-1of${count}" | head -1)
  [ -n "$dropped" ] || fail "could not pick a script to omit"

  fm_write_serial_fixture "$tmp/partial" 1000 "$dropped"
  set +e
  out=$("$RUNNER" --check-budget "$tmp/partial"/shard-*.json 2>"$tmp/partial.err")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "an unrun declared script must fail (exit 1), got $rc"
  assert_contains "$out" "verdict=drifted" "a broken partition must not report ok"
  assert_grep "$dropped" "$tmp/partial.err" "the failure must name the script no shard ran"

  rm -rf "$tmp"
  pass "serial budget control refuses a run that skipped part of the declared lane"
}

# The workflow's hang tripwire cannot be read from inside its own job, so it is
# passed in and checked. Silent disagreement would leave the derived bounds
# describing a timeout that is no longer set.
fm_check_ci_serial_timeout_link() {
  python3 - "$1" "${2:-check}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
action = sys.argv[2]
lines = path.read_text(encoding="utf-8").splitlines(keepends=True)


def job_block(name):
    pattern = re.compile(r"^(\s*)" + re.escape(name) + r"\s*:\s*(?:#.*)?(?:\r?\n)?$")
    matches = [(i, match) for i, line in enumerate(lines) if (match := pattern.match(line))]
    if len(matches) != 1:
        raise SystemExit("job %s: expected 1 match, saw %d" % (name, len(matches)))
    start, match = matches[0]
    indent = match.group(1)
    sibling = re.compile(r"^" + re.escape(indent) + r"[^\s#][^:]*\s*:")
    end = next((i for i in range(start + 1, len(lines)) if sibling.match(lines[i])), len(lines))
    return start + 1, end


def field(job, key):
    start, end = job_block(job)
    pattern = re.compile(
        r"^(\s*" + re.escape(key) + r"\s*:\s*)([^#\r\n]*?)(\s*(?:#.*)?(?:\r?\n)?)$"
    )
    matches = [(i, match) for i in range(start, end) if (match := pattern.match(lines[i]))]
    if len(matches) != 1:
        raise SystemExit("%s.%s: expected 1 match, saw %d" % (job, key, len(matches)))
    index, match = matches[0]
    value = match.group(2).strip()
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise SystemExit("%s.%s must be a positive integer" % (job, key))
    return index, match, int(value)


_, _, timeout = field("tests-portable-serial", "timeout-minutes")
copied_index, copied_match, copied_timeout = field(
    "tests-timing-aggregate", "FM_SERIAL_TIMEOUT_MINUTES"
)
if action == "diverge":
    lines[copied_index] = "%s%d%s" % (
        copied_match.group(1), timeout + 1, copied_match.group(3)
    )
    path.write_text("".join(lines), encoding="utf-8")
elif action != "check":
    raise SystemExit("unknown action: %s" % action)
elif timeout != copied_timeout:
    raise SystemExit(
        "tests-portable-serial timeout-minutes %r disagrees with "
        "FM_SERIAL_TIMEOUT_MINUTES %r" % (timeout, copied_timeout)
    )
else:
    print(timeout)
PY
}

test_serial_budget_control_refuses_a_foreign_timeout_literal() {
  local tmp rc declared fixture
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run-budget-timeout.XXXXXX")
  fm_write_serial_fixture "$tmp/ok" 1000

  fixture="$tmp/ci.yml"
  cp "$ROOT/.github/workflows/ci.yml" "$fixture"
  fm_check_ci_serial_timeout_link "$fixture" diverge \
    || fail "the workflow timeout link fixture must be made divergent"
  set +e
  fm_check_ci_serial_timeout_link "$fixture" >/dev/null 2>"$tmp/link.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the workflow timeout link check must refuse divergent values"
  assert_grep 'disagrees with FM_SERIAL_TIMEOUT_MINUTES' "$tmp/link.err" \
    "the workflow timeout link refusal must name both linked values"

  declared=$(fm_check_ci_serial_timeout_link "$ROOT/.github/workflows/ci.yml") \
    || fail "tests-portable-serial must pass its actual timeout to the budget check"

  set +e
  FM_SERIAL_TIMEOUT_MINUTES=$((declared + 5)) \
    "$RUNNER" --check-budget "$tmp/ok"/shard-*.json >/dev/null 2>"$tmp/err"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail "a disagreeing timeout literal must refuse (exit 2), got $rc"
  assert_grep 'reconcile both' "$tmp/err" "the refusal must ask for both to be reconciled"

  # The workflow's own value must agree, so CI does not carry a latent refusal.
  set +e
  FM_SERIAL_TIMEOUT_MINUTES=$declared \
    "$RUNNER" --check-budget "$tmp/ok"/shard-*.json >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "the timeout ci.yml declares must be the one the bounds assume, got $rc"

  rm -rf "$tmp"
  pass "serial budget control refuses a timeout literal that disagrees with its bounds"
}

# The shard count only protects the lane if the CI matrix actually runs every
# shard the runner composes. These are two files and they drift silently.
test_ci_matrix_runs_every_composed_serial_shard() {
  local count matrix
  count=$("$RUNNER" --list-lanes | grep -c '^portable-serial-[0-9]*of[0-9]*$')
  matrix=$(grep -E '^ *shard: \[' "$ROOT/.github/workflows/ci.yml" | head -1 | grep -o '[0-9]\+' | wc -l | tr -d ' ')
  [ "$matrix" = "$count" ] \
    || fail "ci.yml runs $matrix serial shards but the runner composes $count"
  pass "the CI serial matrix runs exactly the shards the runner composes"
}

test_list_all_exact_suite_coverage
test_family_selection
test_single_script_selection
test_changed_file_selection_is_conservative
test_changed_dependency_selection_and_unmapped_failure
test_empty_selection_emits_summary
test_timing_markers_and_json
test_aggregate_exit_behavior
test_gate_skip_accounting
test_fail_on_gate_skip_token
test_exclude_family
test_portable_shard_union_and_coverage_guard
test_portable_serial_shards_partition_the_serial_lane
test_portable_serial_shard_lane_refusals
test_jobs_requires_proven_isolated
test_jobs_parallel_scheduler_and_failure_propagation
test_aggregate_json
test_serial_budget_control_verdicts
test_serial_budget_control_catches_a_single_shard_near_the_tripwire
test_serial_budget_control_reports_could_not_observe
test_serial_budget_control_checks_the_partition_it_measured
test_serial_budget_control_refuses_a_foreign_timeout_literal
test_ci_matrix_runs_every_composed_serial_shard
