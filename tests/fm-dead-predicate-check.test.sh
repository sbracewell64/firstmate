#!/usr/bin/env bash
# Behavior tests for bin/fm-dead-predicate-check.sh - the class control that
# refuses a fail-closed predicate nothing consults.
#
# WHY THIS SUITE MATTERS MORE THAN MOST. The subject is a control whose entire
# value is its ability to fail. Two guards shipped in one module family, each
# written correct and never called, and three separate review findings were
# needed to notice. A checker for that class which itself passes vacuously would
# be the same defect a level up, so every case here drives it to a verdict from
# fixture state rather than asserting it stays quiet.
#
# The checker reads source, which is why it is a bin/ command and not a test:
# tests in this repo must exercise behavior through an executable interface and
# never assert implementation bytes. This suite honours that - it builds fixture
# trees and asserts the command's VERDICT, never its source.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dead-predicate-check-tests)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

CHECK="$ROOT/bin/fm-dead-predicate-check.sh"
MARKER='# fail-closed-predicates: enforced'

# <name> <lib-body> [consumer-body] -> prints fixture root
fixture() {
  local dir="$TMP_ROOT/$1" lib=$2 consumer=${3:-}
  mkdir -p "$dir/bin"
  printf '# shellcheck shell=bash\n%s\n%s\n' "$MARKER" "$lib" > "$dir/bin/sample-lib.sh"
  [ -z "$consumer" ] || printf '%s\n' "$consumer" > "$dir/bin/consumer.sh"
  printf '%s\n' "$dir"
}

run_check() { FM_ROOT_OVERRIDE="$1" "$CHECK" "${@:2}"; }

test_dead_function_is_refused() {
  local dir out rc
  dir=$(fixture dead 'live_one() { return 0; }
dead_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a dead function did not refuse, exit $rc: $out"
  printf '%s' "$out" | grep -q 'dead_one' || fail "the dead function was not named: $out"
  printf '%s' "$out" | grep -q 'DEAD.*live_one' \
    && fail "a consulted function was reported dead: $out"
  pass "a function nothing consults is refused, and named"
}

test_consulted_function_passes() {
  local dir out rc
  dir=$(fixture live 'live_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a consulted function was refused, exit $rc: $out"
  pass "a function with a call site passes"
}

test_call_site_inside_its_own_file_counts() {
  local dir out rc
  # A helper used only by its own library is consulted. Counting only external
  # callers would flood the report and get the control switched off.
  dir=$(fixture internal 'helper() { return 0; }
caller() { helper; }' 'caller')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an internally consulted helper was refused, exit $rc: $out"
  pass "a call site inside the defining file counts as consulted"
}

test_blanket_exemption_cannot_silence() {
  local dir out rc
  # The requirement that makes this control worth having: no file-level escape.
  dir=$(fixture blanket '# unused-by-design: blanket line, must exempt nothing
live_one() { return 0; }
dead_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a blanket exemption silenced the control, exit $rc: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' \
    || fail "the dead function was not still named: $out"
  pass "a file-level blanket mark exempts nothing"
}

test_adjacent_mark_keeps_one_and_still_reports_it() {
  local dir out rc
  dir=$(fixture marked 'live_one() { return 0; }
# unused-by-design: reserved for the inbound adapter that has not landed
dead_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an adjacent mark did not keep the function, exit $rc: $out"
  printf '%s' "$out" | grep -q 'marked.*dead_one' \
    || fail "a marked function was hidden rather than reported: $out"
  printf '%s' "$out" | grep -q 'inbound adapter' \
    || fail "the stated reason was not surfaced: $out"
  pass "an adjacent per-function mark keeps one function and still reports it"
}

test_mark_must_be_adjacent_to_the_definition() {
  local dir out rc
  # A mark two lines up belongs to something else. Accepting it would make the
  # mark drift silently as the file is edited.
  dir=$(fixture distant 'live_one() { return 0; }
# unused-by-design: this mark is not adjacent

dead_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a non-adjacent mark was honoured, exit $rc: $out"
  pass "a mark that is not immediately above the definition does not apply"
}

test_no_enrolled_file_is_could_not_observe() {
  local dir out rc
  # The vacuity guard. A checker that found nothing to check has established
  # nothing, and reporting that as a pass is the defect this control exists for.
  dir="$TMP_ROOT/unenrolled"
  mkdir -p "$dir/bin"
  printf '# shellcheck shell=bash\ndead_one() { return 0; }\n' > "$dir/bin/sample-lib.sh"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "an unenrolled tree did not report could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'COULD-NOT-OBSERVE' \
    || fail "the vacuity guard did not name itself: $out"
  pass "zero enrolled files is could-not-observe, never a pass"
}

test_outbound_library_stays_enrolled() {
  # Pins the enrolment itself. Removing the marker is the quiet way to silence
  # every finding in this module, so the enrolment is a contract, not a setting.
  grep -qF "$MARKER" "$ROOT/bin/fm-outbound-artifact-lib.sh" \
    || fail "bin/fm-outbound-artifact-lib.sh is no longer enrolled in the dead-predicate control"
  pass "the outbound library is enrolled, and cannot be quietly un-enrolled"
}

test_repository_is_clean_under_the_control() {
  local out rc
  out=$("$CHECK" 2>&1); rc=$?
  [ "$rc" -ne 4 ] || fail "the real repository run found nothing to check: $out"
  [ "$rc" -eq 0 ] || fail "the real repository has an unconsulted guard: $out"
  pass "every enrolled file in this repository has its guards consulted"
}

test_dead_function_is_refused
test_consulted_function_passes
test_call_site_inside_its_own_file_counts
test_blanket_exemption_cannot_silence
test_adjacent_mark_keeps_one_and_still_reports_it
test_mark_must_be_adjacent_to_the_definition
test_no_enrolled_file_is_could_not_observe
test_outbound_library_stays_enrolled
test_repository_is_clean_under_the_control

printf '\nall fm-dead-predicate-check tests passed\n'
