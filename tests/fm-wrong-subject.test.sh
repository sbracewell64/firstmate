#!/usr/bin/env bash
# Behavioral regressions for bin/fm-wrong-subject.sh, the renderer and form
# validator for wrong-subject findings.
#
# Every case drives the real script through its command line and reads its
# stdout and exit status. Nothing here reads the script's source, because a test
# that asserts implementation bytes would establish that the file says something
# rather than that the tool does something - which is the failure class this
# tool is named after.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WS="$ROOT/bin/fm-wrong-subject.sh"
TMP_ROOT=$(fm_test_tmproot fm-wrong-subject)

# One complete, valid finding, used as the positive control every refusal case
# is driven away from. Keeping it in one place means a refusal case differs from
# a passing one in exactly the field it is about.
render_valid() {
  "$WS" finding \
    --check 'bin/example.sh landing guard' \
    --axis stand-in \
    --examined 'the commit is not reachable from a remote this worktree can see' \
    --credited 'the work is not safely recoverable' \
    --credited-as fail \
    --gap 'the pipeline pushed to a remote this worktree has no ref for'
}

test_valid_finding_renders_both_claims_and_the_derived_line() {
  local out
  out=$(render_valid 2>&1) || fail "a complete finding was refused"

  assert_contains "$out" 'wrong-subject finding (axis: stand-in)' \
    "rendered block does not open with the assertable class-and-axis header"
  assert_contains "$out" 'examined:    the commit is not reachable' \
    "rendered block does not state the claim the check establishes"
  assert_contains "$out" 'credited:    the work is not safely recoverable' \
    "rendered block does not state the claim the verdict is credited with"
  assert_contains "$out" 'gap:         the pipeline pushed to a remote' \
    "rendered block does not state the condition where the two claims come apart"
  pass "a rendered finding carries both claims and the gap between them"
}

test_derived_line_resolves_the_credited_claim_to_could_not_observe() {
  local as_fail as_pass

  as_fail=$(render_valid 2>&1) || fail "a complete finding was refused"
  assert_contains "$as_fail" 'therefore:   the credited claim is could-not-observe, not fail' \
    "a credited failure did not resolve to could-not-observe"
  assert_not_contains "$as_fail" 'observed-good' \
    "the derived line converted a credited failure into its opposite"

  # The same law in the other direction. A review that only hunts false greens
  # misses half the class, so both readings must reach could-not-observe and
  # neither may flip to the opposite verdict.
  as_pass=$("$WS" finding \
    --check 'bin/example.sh broken-symlink control' \
    --axis manufacture \
    --examined 'the synthetic link the control created for itself is well formed' \
    --credited 'the real subject path is well formed' \
    --credited-as pass \
    --gap 'materialize crashed before any control ran against the real path' 2>&1) ||
    fail "a complete finding was refused"
  assert_contains "$as_pass" 'therefore:   the credited claim is could-not-observe, not pass' \
    "a credited pass did not resolve to could-not-observe"
  assert_not_contains "$as_pass" 'not fail' \
    "the derived line converted a credited pass into its opposite"

  pass "a finding resolves the credited claim to could-not-observe in both directions"
}

test_refusals_that_protect_the_finding_form() {
  local out rc

  # Each of these is a way a finding can be written in the shape of the class
  # while establishing nothing the class is for.
  out=$("$WS" finding --check c --axis instance --examined A --credited B \
    --credited-as pass 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a finding with no gap condition was rendered"
  assert_contains "$out" '--gap' "refusal does not name the missing field"

  out=$("$WS" finding --check c --axis instance --examined A --credited A \
    --credited-as pass --gap G 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a finding whose two claims are identical was rendered"
  assert_contains "$out" 'the gap between them is the finding' \
    "refusal does not say why identical claims are not a finding"

  out=$("$WS" finding --check c --axis lineage --examined A --credited B \
    --credited-as pass --gap G 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "an axis outside the closed set was accepted"

  out=$("$WS" finding --check c --axis instance --examined A --credited B \
    --credited-as maybe --gap G 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a credited reading outside pass|fail was accepted"

  # A value carrying a newline would produce a block its own parser cannot read.
  out=$("$WS" finding --check c --axis instance --examined "$(printf 'A\nB')" \
    --credited B --credited-as pass --gap G 2>&1) && rc=0 || rc=$?
  expect_code 2 "$rc" "a multi-line field value was accepted into the block"
  assert_contains "$out" 'one physical line per field' \
    "newline refusal does not state the form rule it protects"

  pass "the form refuses every way a finding can omit its reason"
}

test_every_axis_is_renderable_and_documented() {
  local axes axis out
  axes=$("$WS" axes 2>&1) || fail "axes listing failed"

  # The listing and the accepted set are checked against each other, so an axis
  # a reviewer can read about is one they can actually use, and vice versa.
  for axis in instance moment extent stand-in manufacture property; do
    assert_contains "$axes" "$axis" "axes listing omits '$axis'"
    out=$("$WS" finding --check c --axis "$axis" --examined A --credited B \
      --credited-as pass --gap G 2>&1) ||
      fail "documented axis '$axis' was refused by the renderer"
    assert_contains "$out" "(axis: $axis)" "rendered header lost axis '$axis'"
  done

  assert_contains "$axes" 'What would have to be true of the real subject for this to go red?' \
    "axes listing does not carry the diagnostic question a reviewer asks"
  pass "every documented axis renders and every rendered axis is documented"
}

test_check_reports_form_complete_only_for_a_well_formed_block() {
  local file out rc
  file="$TMP_ROOT/valid.txt"
  render_valid >"$file" || fail "a complete finding was refused"

  out=$("$WS" check "$file" 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a well-formed block was not reported complete"
  assert_contains "$out" 'FORM_COMPLETE' "check did not report a complete form"
  assert_not_contains "$out" 'PASS' \
    "check reported a verdict token that credits it with more than form"

  pass "check reports FORM_COMPLETE for a well-formed block"
}

test_check_refuses_a_block_whose_derived_line_was_edited() {
  local file out rc
  file="$TMP_ROOT/softened.txt"
  render_valid | sed 's/could-not-observe, not fail/observed-good/' >"$file"

  out=$("$WS" check "$file" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a block whose derived line was rewritten passed the form check"
  assert_contains "$out" 'bad=therefore' "check did not name the rewritten derived line"

  # Same block with the field simply removed, to separate "edited" from "absent".
  file="$TMP_ROOT/no-therefore.txt"
  render_valid | grep -v '^  therefore:' >"$file"
  out=$("$WS" check "$file" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a block with no derived line passed the form check"
  assert_contains "$out" 'missing=therefore' "check did not name the absent derived line"

  pass "check refuses a derived line that was softened or dropped"
}

test_check_refuses_duplicate_singleton_fields() {
  local file out rc
  file="$TMP_ROOT/duplicate-examined.txt"
  render_valid | sed '/^  examined:/a\  examined:    a second claim silently replacing the first' >"$file"

  out=$("$WS" check "$file" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a block with two examined claims passed the form check"
  assert_contains "$out" 'duplicate=examined' \
    "check did not name the duplicate singleton field"

  pass "check refuses an ambiguous duplicate singleton field"
}

test_check_is_three_valued_with_distinct_exit_codes() {
  local complete incomplete unreadable directory permission_denied out rc
  complete="$TMP_ROOT/three-complete.txt"
  incomplete="$TMP_ROOT/three-incomplete.txt"
  unreadable="$TMP_ROOT/three-prose.txt"
  directory="$TMP_ROOT/three-directory"
  permission_denied="$TMP_ROOT/three-permission-denied.txt"
  render_valid >"$complete"
  render_valid | grep -v '^  gap:' >"$incomplete"
  printf 'a report with no finding block in it at all\n' >"$unreadable"
  mkdir "$directory"
  render_valid >"$permission_denied"
  chmod 000 "$permission_denied"

  "$WS" check "$complete" >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 0 "$rc" "FORM_COMPLETE did not exit 0"

  "$WS" check "$incomplete" >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 1 "$rc" "FORM_INCOMPLETE did not exit 1"

  out=$("$WS" check "$directory" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a directory passed as input did not report could-not-observe"
  assert_contains "$out" 'FORM_UNREADABLE' "a directory was not reported unreadable"

  out=$("$WS" check "$permission_denied" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "an unreadable present file did not report could-not-observe"
  assert_contains "$out" 'FORM_UNREADABLE' "an unreadable present file was not reported unreadable"

  # An input holding no block is could-not-observe, never a clean file: a run
  # that examined nothing has established nothing. This is the case an exit
  # status of 0 would silently turn into a pass.
  out=$("$WS" check "$unreadable" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "an input with no finding block did not report could-not-observe"
  assert_contains "$out" 'FORM_UNREADABLE' "an input with no block was not reported unreadable"
  assert_contains "$out" 'reason=no-finding-block' "unreadable result does not say which could-not-observe it is"

  out=$("$WS" check "$TMP_ROOT/does-not-exist.txt" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "an absent input did not report could-not-observe"
  assert_contains "$out" 'reason=not-readable' "an absent input was not distinguished from an empty one"

  : >"$TMP_ROOT/three-empty.txt"
  "$WS" check "$TMP_ROOT/three-empty.txt" >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 3 "$rc" "an empty input was read as a clean one"

  pass "check separates complete, incomplete, and could-not-observe on distinct exit codes"
}

test_check_validates_findings_embedded_in_a_report() {
  local file out rc
  file="$TMP_ROOT/report.md"
  {
    printf '# Scout report\n\nLeading prose.\n\n'
    render_valid
    printf '\nProse between the two findings.\n\n'
    render_valid | sed 's/could-not-observe, not fail/observed-good/'
    printf '\nClosing prose.\n'
  } >"$file"

  out=$("$WS" check "$file" 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a report carrying one bad finding was accepted"
  assert_contains "$out" 'FORM_COMPLETE block=1' "the sound embedded finding was not recognized"
  assert_contains "$out" 'FORM_INCOMPLETE block=2' "the malformed embedded finding was not caught"
  # The line number is what makes the result actionable inside a long report.
  assert_contains "$out" 'line=5' "check did not report where the first block starts"

  pass "check finds and grades findings embedded in surrounding prose"
}

test_check_reads_stdin() {
  local directory out rc
  directory="$TMP_ROOT/stdin-directory"
  mkdir "$directory"

  out=$(render_valid | "$WS" check - 2>&1) && rc=0 || rc=$?
  expect_code 0 "$rc" "a well-formed block on stdin was not accepted"
  assert_contains "$out" 'FORM_COMPLETE' "stdin input was not graded"

  out=$("$WS" check - <"$directory" 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "a directory on stdin did not report could-not-observe"
  assert_contains "$out" 'FORM_UNREADABLE' "a directory on stdin was not reported unreadable"

  out=$("$WS" check - <&- 2>&1) && rc=0 || rc=$?
  expect_code 3 "$rc" "an unreadable stdin stream did not report could-not-observe"
  assert_contains "$out" 'FORM_UNREADABLE' "an unreadable stdin stream was not reported unreadable"

  out=$(printf 'wrong-subject finding (axis: instance)\n' | "$WS" check - 2>&1) && rc=0 || rc=$?
  expect_code 1 "$rc" "a malformed readable stdin stream did not report incomplete"
  assert_contains "$out" 'FORM_INCOMPLETE' "a malformed readable stdin stream was not reported incomplete"

  pass "check preserves three-valued results for stdin"
}

test_help_states_the_limit_of_a_complete_form() {
  local out
  out=$("$WS" --help 2>&1) || fail "--help failed"

  # The tool's own wrong-subject hazard: a form result credited as a truth
  # result. The limit has to be discoverable at the tool's own seam.
  assert_contains "$out" 'FORM_COMPLETE IS A STATEMENT ABOUT FORM AND ABOUT NOTHING ELSE.' \
    "--help does not state what a complete form establishes"
  assert_contains "$out" 'does not establish that the examined claim is true' \
    "--help does not name what a complete form leaves unestablished"
  assert_contains "$out" 'nothing here tries to decide it' \
    "--help does not state that class membership is not decided mechanically"
  assert_contains "$out" 'Every field except repeatable `evidence` is a singleton' \
    "--help does not state how duplicate fields affect form completeness"
  pass "--help states what a complete form does and does not establish"
}

test_unknown_commands_are_refused() {
  local rc
  "$WS" detect >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown command was not refused"
  "$WS" axes extra >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "axes accepted a stray argument"
  "$WS" check >/dev/null 2>&1 && rc=0 || rc=$?
  expect_code 2 "$rc" "check accepted no input path"
  pass "unknown commands and stray arguments are refused"
}

test_valid_finding_renders_both_claims_and_the_derived_line
test_derived_line_resolves_the_credited_claim_to_could_not_observe
test_refusals_that_protect_the_finding_form
test_every_axis_is_renderable_and_documented
test_check_reports_form_complete_only_for_a_well_formed_block
test_check_refuses_a_block_whose_derived_line_was_edited
test_check_refuses_duplicate_singleton_fields
test_check_is_three_valued_with_distinct_exit_codes
test_check_validates_findings_embedded_in_a_report
test_check_reads_stdin
test_help_states_the_limit_of_a_complete_form
test_unknown_commands_are_refused
