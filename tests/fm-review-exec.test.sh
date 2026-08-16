#!/usr/bin/env bash
# Tests for bin/fm-review-exec.sh, the substrate that launches and captures a
# reviewer and owns that review's execution evidence.
#
# The substrate replaces one whose defect was accepting a proxy: it ran a whole
# suite, grepped the output for `ok - <case>`, and printed
# `FM_RECURRENCE_ASSERTION_EXECUTED` on the strength of that line. So the
# majority of the cases here are negative controls, and each names the proxy it
# refuses:
#
#   label            a success literal in the reviewer's own captured stream
#   coincidence      an unrelated failure whose output contains that literal
#   task-terminal    a status event saying the review finished
#   liveness         a reviewer that is demonstrably alive right now
#   acknowledgement  a reviewer's own signed-looking claim that it reviewed
#   wrapper          a marker printed by something that wrapped the real work
#   forged record    a plausible record with no materialized reviewer behind it
#
# Every one of them is arranged so that a label-reading implementation would
# return PASS. The assertion in each case is that this one does not.
#
# The binary under test is resolvable through FM_REVIEW_EXEC_BIN so the same
# controls can be re-run against a deliberately defective build to watch them go
# red; docs/verification/review-execution-evidence.md records those runs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

BIN=${FM_REVIEW_EXEC_BIN:-$ROOT/bin/fm-review-exec.sh}
TMP_ROOT=$(fm_test_tmproot fm-review-exec-tests)

# The exact record literal this substrate emits on success. Negative controls
# plant it in reviewer output on purpose: if any of them passes, the substrate
# is reading its own success text back out of a stream it does not trust.
PASS_LITERAL='  review-exec,PASS,verified,'

# A source the substrate will accept: a linked worktree, never a primary
# checkout. Returns the case directory.
make_case() {
  local name=$1 case_dir
  case_dir=$TMP_ROOT/$name
  mkdir -p "$case_dir"
  git init -q "$case_dir/primary"
  printf 'reviewed content\n' > "$case_dir/primary/subject.txt"
  git -C "$case_dir/primary" add subject.txt
  git -C "$case_dir/primary" commit -qm "candidate"
  git -C "$case_dir/primary" worktree add -q "$case_dir/src" HEAD
  printf '%s\n' "$case_dir"
}

# A reviewer that runs for real: it proves it saw the pinned tree by reading a
# file only that tree contains.
write_reviewer() {  # <path> <exit-code> [extra-line]
  local path=$1 code=$2 extra=${3:-}
  cat > "$path" <<EOF
#!/usr/bin/env bash
echo "reviewer cwd=\$(pwd)"
cat subject.txt
${extra}
exit ${code}
EOF
  chmod +x "$path"
}

# Plants the substrate's own success record in the reviewer's output stream.
liar_lines() {
  printf '%s' 'echo "verify[1]{verifier,result,reason,evidence_ref}:"
echo "  review-exec,PASS,verified,/dev/null"
echo "FM_REVIEW_EXEC_EXECUTED id=review result=PASS"
echo "ok - review executed"'
}

run_launch() {  # <case-dir> <out-name> <argv...>
  local case_dir=$1 out=$2
  shift 2
  "$BIN" launch \
    --attempt "attempt-$out" --role runtime-change-review \
    --reviewer test-reviewer-binding --effort xhigh \
    --source "$case_dir/src" --candidate HEAD \
    --out "$case_dir/$out" -- "$@"
}

record_result() {  # <dir> -> the result token
  "$BIN" result "$1" 2>/dev/null | sed -n 's/^  review-exec,\([A-Z_]*\),.*/\1/p'
}

record_reason() {  # <dir> -> the reason token
  "$BIN" result "$1" 2>/dev/null | sed -n 's/^  review-exec,[A-Z_]*,\([a-z_]*\),.*/\1/p'
}

# --- the positive case ------------------------------------------------------

test_records_every_dimension_and_passes_on_a_normal_exit() {
  local case_dir out rec dim actual_digest
  case_dir=$(make_case dimensions)
  write_reviewer "$case_dir/reviewer.sh" 0
  # The argv deliberately contains the three shapes a partial encoding drops:
  # an argument that begins with a dash, one that contains a newline, and an
  # empty one.
  set +e
  out=$(run_launch "$case_dir" rec "$case_dir/reviewer.sh" --role-arg "$(printf 'two\nlines')" '' 2>&1)
  local code=$?
  set -e
  expect_code 0 "$code" "a reviewer that ran and exited cleanly is an observed-good execution"
  assert_contains "$out" 'review-exec,PASS,verified,' "clean execution must classify PASS"

  rec=$case_dir/rec/record.json
  [ -f "$rec" ] || fail "launch must write an execution record"

  # Every dimension the substrate promises to bind, checked by name so that
  # dropping one is a test failure rather than a quieter record.
  for dim in attempt_identity review_role reviewer_binding reviewer_effort \
    candidate_commit candidate_tree reviewer_checkout reviewer_checkout_commit \
    reviewer_checkout_tree launch_executable launch_argv launch_cwd started_at \
    ended_at terminal_state exit_status artifact_sha256; do
    [ "$(jq -r --arg d "$dim" '.dimensions[$d].observed' "$rec")" = true ] \
      || fail "dimension $dim must be recorded as observed"
    [ "$(jq -r --arg d "$dim" '.dimensions[$d].value | tostring' "$rec")" != '' ] \
      || fail "dimension $dim must carry a value"
  done

  # The candidate and the thing that was actually reviewed are separate
  # dimensions on purpose, and the record has to tie them together.
  [ "$(jq -r '.dimensions.candidate_commit.value' "$rec")" \
    = "$(git -C "$case_dir/src" rev-parse HEAD)" ] \
    || fail "candidate_commit must be the source's pinned candidate"
  [ "$(jq -r '.dimensions.reviewer_checkout_tree.value' "$rec")" \
    = "$(jq -r '.dimensions.candidate_tree.value' "$rec")" ] \
    || fail "the reviewer's materialized tree must equal the candidate tree"

  # The argv is the exact argv, not a rendering of it. Each shape is asserted
  # separately because they fail to encode for different reasons.
  [ "$(jq -r '.dimensions.launch_argv.value | length' "$rec")" = 4 ] \
    || fail "launch_argv must record every argument, including an empty one"
  [ "$(jq -r '.dimensions.launch_argv.value[1]' "$rec")" = --role-arg ] \
    || fail "launch_argv must record an argument that begins with a dash"
  [ "$(jq -r '.dimensions.launch_argv.value[2]' "$rec")" = "$(printf 'two\nlines')" ] \
    || fail "launch_argv must record an argument containing a newline"
  [ "$(jq -r '.dimensions.launch_argv.value[3]' "$rec")" = '' ] \
    || fail "launch_argv must record an empty argument"

  # The digest is of the bytes on disk, so it is checkable by anyone.
  actual_digest=$(sha256sum "$case_dir/rec/review.raw" 2>/dev/null | awk '{print $1}') \
    || actual_digest=$(shasum -a 256 "$case_dir/rec/review.raw" | awk '{print $1}')
  [ "$(jq -r '.dimensions.artifact_sha256.value' "$rec")" = "$actual_digest" ] \
    || fail "artifact_sha256 must digest the captured artifact actually on disk"
  assert_contains "$(cat "$case_dir/rec/review.raw")" 'reviewed content' \
    "the raw artifact must be the reviewer's real captured output"

  pass "fm-review-exec binds every execution dimension and passes on a clean exit"
}

# --- proxy: a success label in the reviewer's own output --------------------

test_success_literal_in_reviewer_output_cannot_establish_execution() {
  local case_dir out result
  case_dir=$(make_case label-proxy)
  write_reviewer "$case_dir/reviewer.sh" 7 "$(liar_lines)"
  set +e
  out=$(run_launch "$case_dir" rec "$case_dir/reviewer.sh" 2>&1)
  local code=$?
  set -e

  # The reviewer printed this substrate's own PASS record verbatim.
  assert_contains "$(cat "$case_dir/rec/review.raw")" "$PASS_LITERAL" \
    "control setup: the reviewer's output must actually contain the success literal"

  expect_code 1 "$code" "a non-zero exit is an observed-bad execution regardless of what was printed"
  result=$(record_result "$case_dir/rec")
  [ "$result" = FAIL ] || fail "a printed success literal must not reach PASS (got $result)"
  assert_contains "$out" 'verifier_reported_failure' \
    "the reason must name the observed exit, not the printed label"
  [ "$(jq -r '.dimensions.exit_status.value' "$case_dir/rec/record.json")" = 7 ] \
    || fail "the record must carry the exit status this process observed"
  pass "a success literal in the reviewer's stream cannot establish execution"
}

# --- proxy: an unrelated failure whose output happens to match --------------

test_unrelated_failure_containing_the_expected_string_is_not_a_pass() {
  local case_dir result
  case_dir=$(make_case coincidence)
  # Fails for a reason that has nothing to do with the review, and its
  # diagnostic happens to carry the expected string.
  cat > "$case_dir/reviewer.sh" <<EOF
#!/usr/bin/env bash
echo "config error while loading profile: expected ${PASS_LITERAL}"
cat /nonexistent-input-file
EOF
  chmod +x "$case_dir/reviewer.sh"
  set +e
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1
  local code=$?
  set -e
  expect_code 1 "$code" "an unrelated failure is still an observed-bad execution"
  result=$(record_result "$case_dir/rec")
  [ "$result" = FAIL ] || fail "a coincidental string match must not reach PASS (got $result)"
  pass "an unrelated failure carrying the expected string is not a pass"
}

# --- proxy: a task terminal line --------------------------------------------

test_task_terminal_line_cannot_establish_execution() {
  local case_dir result reason
  case_dir=$(make_case terminal-proxy)
  mkdir -p "$case_dir/rec"
  # Exactly the shape the retired substrate read as proof a review happened.
  printf 'fm-status-event.v1 verb=done key=review-execution phase=runtime-change-review evidence=%s summary=captured reviewer execution\n' \
    "$(git -C "$case_dir/src" rev-parse HEAD)" > "$case_dir/rec/task.status"
  result=$(record_result "$case_dir/rec")
  reason=$(record_reason "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a task terminal line must not establish execution (got $result)"
  [ "$reason" = empty_result_set ] \
    || fail "the absence of a record is the empty set, not a verdict (got $reason)"
  pass "a task terminal line cannot establish execution"
}

# --- proxy: liveness ---------------------------------------------------------

test_liveness_cannot_establish_execution() {
  local case_dir result launch_pid
  case_dir=$(make_case liveness-proxy)
  cat > "$case_dir/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
touch "$1"
sleep 30
EOF
  chmod +x "$case_dir/reviewer.sh"

  run_launch "$case_dir" rec "$case_dir/reviewer.sh" "$case_dir/alive" \
    >/dev/null 2>&1 &
  launch_pid=$!
  fm_test_reap "$launch_pid"
  fm_test_wait_file "$case_dir/alive" 10 "$launch_pid" \
    "control setup: the reviewer exited before it could be observed alive" \
    "control setup: the reviewer never started"

  # Liveness is observed-good here, and that is the entire point: the reviewer
  # is provably running right now.
  kill -0 "$launch_pid" 2>/dev/null || fail "control setup: the launch must still be alive"

  result=$(record_result "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a live reviewer has not executed; liveness must not reach PASS (got $result)"

  fm_test_kill_tree "$launch_pid"
  pass "a live reviewer process cannot establish execution"
}

# --- proxy: a reviewer's own acknowledgement --------------------------------

test_stale_acknowledgement_cannot_establish_execution() {
  local case_dir result head
  case_dir=$(make_case ack-proxy)
  mkdir -p "$case_dir/rec"
  head=$(git -C "$case_dir/src" rev-parse HEAD)
  # The reviewer's own claim, correctly bound to the real candidate, complete
  # and internally consistent. It is still only testimony.
  jq -n --arg h "$head" '{
      schema: "fm-review-ack.v1", assignment_received: true,
      review_assignment_id: "attempt-rec", review_role: "runtime-change-review",
      reviewer_binding: "test-reviewer-binding", review_target_commit: $h
    }' > "$case_dir/rec/review-ack.json"
  result=$(record_result "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a reviewer acknowledgement must not establish execution (got $result)"
  pass "a reviewer acknowledgement cannot establish execution"
}

# --- proxy: a wrapper marker -------------------------------------------------

test_wrapper_cannot_masquerade_as_the_reviewer() {
  local case_dir recorded
  case_dir=$(make_case wrapper-proxy)
  write_reviewer "$case_dir/real-reviewer.sh" 0
  # A wrapper that prints the marker and never runs the reviewer it names.
  cat > "$case_dir/wrapper.sh" <<EOF
#!/usr/bin/env bash
echo "FM_REVIEW_EXEC_EXECUTED reviewer=$case_dir/real-reviewer.sh result=PASS"
exit 0
EOF
  chmod +x "$case_dir/wrapper.sh"
  set +e
  run_launch "$case_dir" rec "$case_dir/wrapper.sh" >/dev/null 2>&1
  set -e

  # The wrapper did execute, so this is a pass about the WRAPPER. What the
  # record must not do is let it stand in for the reviewer it named.
  recorded=$(jq -r '.dimensions.launch_executable.value' "$case_dir/rec/record.json")
  [ "$recorded" = "$case_dir/wrapper.sh" ] \
    || fail "the record must name the executable that actually ran (got $recorded)"
  [ "$recorded" != "$case_dir/real-reviewer.sh" ] \
    || fail "a wrapper marker must not let a wrapper be recorded as the reviewer"
  pass "a wrapper marker cannot make a wrapper be recorded as the reviewer"
}

# --- proxy: a forged record --------------------------------------------------

test_forged_record_without_a_materialized_reviewer_is_could_not_observe() {
  local case_dir result reason digest
  case_dir=$(make_case forged-record)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the baseline launch must pass"
  [ "$(record_result "$case_dir/rec")" = PASS ] \
    || fail "control setup: the baseline record must classify PASS"

  # Remove only the materialized checkout. The record and the raw artifact are
  # untouched and the digest still matches, so every text-level check passes.
  rm -rf "$case_dir/rec/checkout"
  digest=$(jq -r '.dimensions.artifact_sha256.value' "$case_dir/rec/record.json")
  [ -n "$digest" ] || fail "control setup: the record must still carry its digest"

  result=$(record_result "$case_dir/rec")
  reason=$(record_reason "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a record with no materialized reviewer behind it must not pass (got $result)"
  [ "$reason" = verification_unreachable ] \
    || fail "the reason must name the unreachable checkout (got $reason)"
  pass "a record with no materialized reviewer behind it is could-not-observe"
}

# --- preserved semantics: isolation, restoration, immutability --------------

test_refuses_a_primary_checkout_as_its_source() {
  local case_dir out
  case_dir=$(make_case primary-refusal)
  set +e
  out=$("$BIN" launch --attempt a --role r --reviewer b --effort e \
    --source "$case_dir/primary" --candidate HEAD --out "$case_dir/rec" -- /bin/true 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "a primary checkout as source is could-not-observe"
  assert_contains "$out" 'refuses a primary checkout' \
    "the refusal must name the primary checkout"
  pass "fm-review-exec refuses a primary checkout as its review source"
}

test_reviewer_checkout_is_isolated_from_the_source() {
  local case_dir co
  case_dir=$(make_case isolation)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the launch must pass"
  co=$case_dir/rec/checkout

  [ ! -e "$co/.git/objects/info/alternates" ] \
    || fail "the reviewer checkout must not borrow the source's objects"
  # The property --no-local buys, checked directly: a clone that hardlinks the
  # source's objects passes every other assertion in this case.
  [ -z "$(find "$co/.git/objects" -type f -links +1 -print 2>/dev/null | head -n 1)" ] \
    || fail "the reviewer checkout must not share object storage with the source"
  [ "$(git -C "$co" rev-parse --git-common-dir)" = .git ] \
    || fail "the reviewer checkout must own its repository administration"
  [ "$(git -C "$co" rev-parse HEAD)" = "$(git -C "$case_dir/src" rev-parse HEAD)" ] \
    || fail "the reviewer checkout must be detached onto the pinned candidate"
  [ "$(git -C "$co" rev-parse --abbrev-ref HEAD)" = HEAD ] \
    || fail "the reviewer checkout must be detached, not on a branch"

  # A write inside the reviewer's checkout must not reach the source.
  printf 'reviewer scribble\n' > "$co/subject.txt"
  [ "$(cat "$case_dir/src/subject.txt")" = 'reviewed content' ] \
    || fail "a write in the reviewer checkout must not reach the source worktree"
  pass "the reviewer checkout is isolated from the source it was cloned from"
}

test_reviewer_moving_its_checkout_off_the_candidate_is_could_not_observe() {
  local case_dir result reason object
  case_dir=$(make_case restoration)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the launch must pass"
  [ "$(record_result "$case_dir/rec")" = PASS ] \
    || fail "control setup: the baseline record must classify PASS"

  # Simulate a reviewer that did not leave its pinned checkout where it found it.
  git -C "$case_dir/rec/checkout" commit -q --allow-empty -m "reviewer moved HEAD"

  result=$(record_result "$case_dir/rec")
  reason=$(record_reason "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a checkout moved off the pinned candidate must not still pass (got $result)"
  [ "$reason" = verification_unreachable ] \
    || fail "the reason must name the unverifiable checkout (got $reason)"

  git -C "$case_dir/rec/checkout" reset -q --hard HEAD~1
  printf 'dirty\n' > "$case_dir/rec/checkout/subject.txt"
  [ "$(record_result "$case_dir/rec")" = NO_VERIFIER_RAN ] \
    || fail "a dirty reviewer checkout must not still pass"
  git -C "$case_dir/rec/checkout" reset -q --hard

  git -C "$case_dir/rec/checkout" switch -q -c attached-review
  [ "$(record_result "$case_dir/rec")" = NO_VERIFIER_RAN ] \
    || fail "an attached reviewer checkout must not still pass"
  git -C "$case_dir/rec/checkout" checkout -q --detach

  jq '.dimensions.reviewer_checkout_commit.value = "0000000000000000000000000000000000000000"' \
    "$case_dir/rec/record.json" > "$case_dir/rec/record.tmp"
  mv "$case_dir/rec/record.tmp" "$case_dir/rec/record.json"
  [ "$(record_result "$case_dir/rec")" = NO_VERIFIER_RAN ] \
    || fail "checkout identity divergent from candidate identity must not pass"
  jq --arg head "$(git -C "$case_dir/rec/checkout" rev-parse HEAD)" \
    '.dimensions.reviewer_checkout_commit.value = $head' \
    "$case_dir/rec/record.json" > "$case_dir/rec/record.tmp"
  mv "$case_dir/rec/record.tmp" "$case_dir/rec/record.json"

  object=$(find "$case_dir/rec/checkout/.git/objects" -type f | head -n 1)
  ln "$object" "$object.shared"
  [ "$(record_result "$case_dir/rec")" = NO_VERIFIER_RAN ] \
    || fail "shared reviewer object storage must not still pass on reread"
  rm "$object.shared"
  pass "a reviewer checkout moved off the pinned candidate is could-not-observe"
}

test_refuses_to_overwrite_an_existing_record() {
  local case_dir out first
  case_dir=$(make_case immutability)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the first launch must pass"
  first=$(jq -r '.recorded_at' "$case_dir/rec/record.json")

  set +e
  out=$(run_launch "$case_dir" rec "$case_dir/reviewer.sh" 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "a second launch into an occupied record directory is refused"
  assert_contains "$out" 'a record is written once' "the refusal must name the immutability rule"
  [ "$(jq -r '.recorded_at' "$case_dir/rec/record.json")" = "$first" ] \
    || fail "the refused launch must leave the existing record untouched"
  pass "fm-review-exec refuses to overwrite an existing execution record"
}

# --- the three-valued boundary ----------------------------------------------

test_a_missing_dimension_outranks_a_clean_exit() {
  local case_dir result out
  case_dir=$(make_case missing-dimension)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the launch must pass"

  jq 'del(.dimensions.reviewer_effort)' "$case_dir/rec/record.json" > "$case_dir/rec/r.tmp"
  mv "$case_dir/rec/r.tmp" "$case_dir/rec/record.json"

  set +e
  out=$("$BIN" result "$case_dir/rec" 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "an unobserved dimension is could-not-observe"
  result=$(record_result "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "sixteen observed and one missing is not a pass (got $result)"
  assert_contains "$out" 'reviewer_effort' \
    "the unobserved dimension must be named rather than silently dropped"
  pass "one unobserved dimension outranks an otherwise clean execution"
}

test_a_tampered_artifact_breaks_the_digest_binding() {
  local case_dir result
  case_dir=$(make_case digest-binding)
  write_reviewer "$case_dir/reviewer.sh" 0
  run_launch "$case_dir" rec "$case_dir/reviewer.sh" >/dev/null 2>&1 \
    || fail "control setup: the launch must pass"
  printf 'appended after the fact\n' >> "$case_dir/rec/review.raw"
  result=$(record_result "$case_dir/rec")
  [ "$result" = NO_VERIFIER_RAN ] \
    || fail "a record must not outlive the bytes it attests to (got $result)"
  pass "a tampered raw artifact breaks the record's digest binding"
}

test_an_ambiguous_shell_status_is_could_not_observe() {
  local case_dir out
  case_dir=$(make_case signalled)
  cat > "$case_dir/reviewer.sh" <<'EOF'
#!/usr/bin/env bash
exit 143
EOF
  chmod +x "$case_dir/reviewer.sh"
  set +e
  out=$(run_launch "$case_dir" rec "$case_dir/reviewer.sh" 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "a shell status that cannot distinguish signal from exit is could-not-observe"
  assert_contains "$out" 'terminal state is ambiguous' \
    "the refusal must name the ambiguous terminal observation"
  [ ! -f "$case_dir/rec/record.json" ] || fail "an ambiguous terminal state must write no record"
  pass "an ambiguous shell terminal status is could-not-observe"
}

test_an_unresolvable_candidate_is_could_not_observe() {
  local case_dir out
  case_dir=$(make_case bad-candidate)
  set +e
  out=$("$BIN" launch --attempt a --role r --reviewer b --effort e \
    --source "$case_dir/src" --candidate deadbeefdeadbeefdeadbeefdeadbeefdeadbeef \
    --out "$case_dir/rec" -- /bin/true 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "a candidate that does not resolve is could-not-observe"
  assert_contains "$out" 'candidate does not resolve' "the refusal must name the candidate"
  [ ! -f "$case_dir/rec/record.json" ] || fail "a refused launch must write no record"
  pass "an unresolvable candidate is could-not-observe and writes no record"
}

test_an_unresolvable_reviewer_executable_is_could_not_observe() {
  local case_dir out recorded
  case_dir=$(make_case bad-executable)
  mkdir -p "$case_dir/src/bin"
  write_reviewer "$case_dir/src/bin/candidate-reviewer" 0
  git -C "$case_dir/src" add bin/candidate-reviewer
  git -C "$case_dir/src" commit -qm "add candidate reviewer"
  run_launch "$case_dir" relative ./bin/candidate-reviewer >/dev/null 2>&1 \
    || fail "a checkout-relative candidate executable must resolve"
  recorded=$(jq -r '.dimensions.launch_executable.value' "$case_dir/relative/record.json")
  [ "$recorded" = "$case_dir/relative/checkout/bin/candidate-reviewer" ] \
    || fail "a relative executable must resolve inside the reviewer checkout (got $recorded)"
  set +e
  out=$(run_launch "$case_dir" rec "$case_dir/no-such-reviewer" 2>&1)
  local code=$?
  set -e
  expect_code 2 "$code" "a reviewer that does not resolve is could-not-observe"
  assert_contains "$out" 'reviewer executable does not resolve' \
    "the refusal must name the unresolvable executable"
  [ ! -f "$case_dir/rec/record.json" ] || fail "a refused launch must write no record"
  pass "an unresolvable reviewer executable is could-not-observe and writes no record"
}

test_records_every_dimension_and_passes_on_a_normal_exit
test_success_literal_in_reviewer_output_cannot_establish_execution
test_unrelated_failure_containing_the_expected_string_is_not_a_pass
test_task_terminal_line_cannot_establish_execution
test_liveness_cannot_establish_execution
test_stale_acknowledgement_cannot_establish_execution
test_wrapper_cannot_masquerade_as_the_reviewer
test_forged_record_without_a_materialized_reviewer_is_could_not_observe
test_refuses_a_primary_checkout_as_its_source
test_reviewer_checkout_is_isolated_from_the_source
test_reviewer_moving_its_checkout_off_the_candidate_is_could_not_observe
test_refuses_to_overwrite_an_existing_record
test_a_missing_dimension_outranks_a_clean_exit
test_a_tampered_artifact_breaks_the_digest_binding
test_an_ambiguous_shell_status_is_could_not_observe
test_an_unresolvable_candidate_is_could_not_observe
test_an_unresolvable_reviewer_executable_is_could_not_observe
