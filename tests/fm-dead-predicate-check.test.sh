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
  [ -z "$consumer" ] || printf '%s\n%s\n' "$MARKER" "$consumer" > "$dir/bin/consumer.sh"
  printf '%s\n' "$dir"
}

# A consumer that is NOT enrolled. The property is repo-wide, so a call from here
# is still a call; scoping the scan to enrolled files made the verdict depend on
# configuration rather than on the code.
add_plain_consumer() {  # <dir> <body>
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$1/bin/plain-consumer.sh"
}

# A consumer this control cannot parse. Its presence must be REPORTED, must not
# turn the control red on its own, and must turn an otherwise-dead predicate into
# could-not-observe rather than dead.
add_unparseable_consumer() {  # <dir> [<payload>]
  # The payload matters: completeness is PROPERTY-SCOPED, so an unparseable file
  # blocks a predicate only if it could possibly call it. A generic payload
  # leaves every predicate's universe complete.
  printf '#!/usr/bin/env bash\ncat <<EOF\n%s\nEOF\n' "${2:-payload}" > "$1/bin/unparseable.sh"
}

run_check() { FM_ROOT_OVERRIDE="$1" "$CHECK" "${@:2}"; }

test_unparsed_file_that_never_mentions_it_leaves_the_universe_complete() {
  local dir out rc
  # Property-scoped completeness. The candidate universe for a predicate is its
  # POSSIBLE CALLERS, so a file that never references the name cannot hold a call
  # to it and must not block a DEAD verdict for it. A global rule made 215
  # unparsed files block every predicate, including ones none of them mentions.
  dir=$(fixture universe-complete 'live_one() { return 0; }
dead_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  printf '#!/usr/bin/env bash\ncat <<EOF\nnothing relevant here\nEOF\n' > "$dir/bin/unparseable.sh"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "universe: DEAD was not issuable despite a complete caller universe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'DEAD .*dead_one' \
    || fail "universe: dead_one was not reported: $out"
  pass "an unparsed file that never mentions a predicate does not block its DEAD verdict"
}

test_unparsed_file_that_mentions_it_makes_the_universe_incomplete() {
  local dir out rc
  dir=$(fixture universe-incomplete 'live_one() { return 0; }
dead_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  printf '#!/usr/bin/env bash\ncat <<EOF\nmaybe dead_one appears here\nEOF\n' > "$dir/bin/unparseable.sh"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "universe: a possible caller did not yield could-not-observe, exit $rc: $out"
  printf '%s' "$out" | grep -q 'CNO .*dead_one' \
    || fail "universe: not reported as could-not-observe: $out"
  printf '%s' "$out" | grep -q 'DEAD .*dead_one' \
    && fail "universe: reported DEAD while a possible caller was unreadable: $out"
  pass "an unparsed file that mentions a predicate makes its universe incomplete, so could-not-observe"
}

test_loose_exclusion_never_confirms_a_call() {
  local dir out rc
  # The asymmetry that makes loose matching sound. A mention inside an unparsed
  # file may EXCLUDE that file from a predicate's universe - costing at worst a
  # could-not-observe - but must never be read as evidence that a call exists.
  # If it were, this predicate would report ALIVE and the control would be
  # confirming a call from a substring, which is discovery mistaken for identity.
  dir=$(fixture loose-never-confirms 'live_one() { return 0; }
dead_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  printf '#!/usr/bin/env bash\ncat <<EOF\ndead_one\nEOF\n' > "$dir/bin/unparseable.sh"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "asymmetry: expected could-not-observe, got $rc: $out"
  printf '%s' "$out" | grep -q 'alive=2' \
    && fail "asymmetry: a mention in an unparsed file was counted as a call: $out"
  pass "a mention in an unparsed file excludes but never confirms, so it can only yield could-not-observe"
}

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

test_mentions_are_not_call_sites() {
  local dir out rc
  dir=$(fixture mentions 'dead_one() { return 0; }' '# dead_one is documented here
printf "%s\\n" "dead_one"')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "quoted fixture text counted as a call, exit $rc: $out"
  pass "quoted fixture text is not a call site"
}

test_quoted_command_shape_is_not_a_call_site() {
  local dir out rc
  dir=$(fixture quoted-shape 'dead_one() { return 0; }' "printf '%s\\n' '; dead_one'")
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "quoted command-shaped text counted as a call, exit $rc: $out"
  pass "quoted command-shaped text is not a call site"
}

test_heredoc_payload_is_not_a_call_site() {
  local dir out rc
  dir=$(fixture heredoc 'dead_one() { return 0; }' 'cat <<EOF
; dead_one
EOF')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "a heredoc was interpreted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'UNCHECKED.*consumer.sh.*cat <<EOF' \
    || fail "the heredoc refusal did not name its file and construct: $out"
  pass "heredocs are reported unchecked"
}

test_punctuated_heredoc_does_not_hide_later_functions() {
  local dir out rc
  dir=$(fixture punctuated-heredoc 'live_one() { return 0; }
cat <<END-MARK
payload
END-MARK
dead_one() { return 0; }' 'live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "a punctuated heredoc was interpreted, exit $rc: $out"
  pass "punctuated heredocs are reported unchecked"
}

test_escaped_heredoc_payload_is_not_code() {
  local dir out rc
  dir=$(fixture escaped-heredoc 'dead_one() { return 0; }' 'cat <<\EOF
; dead_one
EOF')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "an escaped heredoc was interpreted, exit $rc: $out"
  pass "escaped heredocs are reported unchecked"
}

test_multiple_heredocs_are_reported_unchecked() {
  local dir out rc
  dir=$(fixture multiple-heredocs 'dead_one() { return 0; }' 'cat <<A <<B
A
; dead_one
B')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "multiple heredocs were interpreted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'UNCHECKED.*cat <<A <<B' \
    || fail "the multiple-heredoc refusal was not actionable: $out"
  pass "multiple heredocs are reported unchecked"
}

test_function_keyword_definition_is_scanned() {
  local dir out rc
  dir=$(fixture function-keyword 'function dead_one { return 0; }')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "a function-keyword definition was interpreted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'UNCHECKED.*function dead_one' \
    || fail "the alternate definition was not named: $out"
  pass "function-keyword definitions are reported unchecked"
}

test_quoted_awk_function_is_not_shell_syntax() {
  local dir out rc
  dir=$(fixture quoted-awk-function 'live_one() { return 0; }
live_one
awk '\''
  function helper(value) { return value }
  BEGIN { print helper("ok") }
'\''')
  out=$(FM_ROOT_OVERRIDE="$dir" "$CHECK" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "a quoted awk function was interpreted as shell syntax, exit $rc: $out"
  pass "quoted awk functions are excluded before shell construct classification"
}

test_explicit_indirect_call_counts() {
  local dir out rc
  # shellcheck disable=SC2016 # The generated fixture expands callback at runtime.
  dir=$(fixture indirect 'live_one() { return 0; }' 'callback=live_one
# indirect-call: live_one callback dispatch
"$callback"')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an explicitly identified indirect call was refused, exit $rc: $out"
  pass "an explicit indirect call site counts as consulted"
}

test_call_in_quoted_substitution_counts() {
  local dir out rc
  # shellcheck disable=SC2016 # The generated fixture runs the substitution at runtime.
  dir=$(fixture quoted-substitution 'live_one() { return 0; }' 'value="$(live_one)"')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a call inside a quoted command substitution was refused, exit $rc: $out"
  pass "executable substitutions inside quotes count without exposing quoted text"
}

test_multiline_double_quoted_command_shape_is_not_a_call() {
  local dir out rc
  dir=$(fixture multiline-double-quote 'dead_one() { return 0; }' 'message="first line
dead_one
last line"')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "multiline double-quoted data counted as a call, exit $rc: $out"
  pass "multiline double-quoted data does not establish call identity"
}

test_same_line_double_quoted_command_shape_is_not_a_call() {
  local dir out rc
  dir=$(fixture same-line-double-quote 'dead_one() { return 0; }' 'message="prefix; dead_one"')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "same-line double-quoted data counted as a call, exit $rc: $out"
  pass "same-line double-quoted data does not establish call identity"
}

test_unterminated_double_quote_is_unchecked() {
  local dir out rc
  dir=$(fixture unterminated-double-quote 'maybe_used() { return 0; }')
  add_plain_consumer "$dir" 'message="maybe_used'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "unterminated double quote was treated as parseable, exit $rc: $out"
  printf '%s' "$out" | grep -q 'plain-consumer.sh.*unterminated quoted string' \
    || fail "unterminated double quote was not named: $out"
  pass "unterminated double quotes are named unchecked"
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

test_repository_has_no_dead_predicates_under_the_control() {
  # This asserts the SAME outcome the CI invariants job asserts by running the
  # same command with no arguments over the real repository. Accepting exit 4
  # here as well as 0 would have made the test pass while CI went red, and would
  # have let the repository drift into a state where no predicate resolves at
  # all - which is what the control's own header says must never read as clean.
  local consumer="$ROOT/bin/fm-landing-authorization.sh" out rc
  out=$("$CHECK" --json 2>&1); rc=$?
  [ "$rc" -ne 3 ] \
    || fail "the real repository has an unconsulted guard: $out"
  [ "$rc" -ne 4 ] \
    || fail "the real repository has an unresolved predicate; that is not a pass: $out"
  [ "$rc" -eq 0 ] \
    || fail "the real repository produced an unexpected verdict, exit $rc: $out"
  printf '%s' "$out" | jq -e --arg consumer "$consumer" '
    .schema == "fm-dead-predicate-check.v1"
    and (.alive > 0)
    and ((.dead | length) == 0)
    and ((.could_not_observe | length) == 0)
    and (.unchecked_consumers
      | map(startswith($consumer + ":"))
      | any
      | not)
  ' >/dev/null \
    || fail "the repository verdict did not prove the landing-authorization consumer readable: $out"
  pass "the real repository passes the CI control with the landing-authorization consumer readable"
}

test_control_is_wired_into_the_automatic_check_path() {
  # The control exists to catch a guard nothing consults. A control that itself
  # depends on somebody choosing to run it is that same defect one level up, so
  # its presence on the automatic path is pinned rather than assumed.
  local workflow="$ROOT/.github/workflows/ci.yml"
  [ -r "$workflow" ] || fail "the CI workflow is unreadable, so its wiring cannot be checked"
  grep -qE '^[[:space:]]*run:[[:space:]]*bin/fm-dead-predicate-check\.sh[[:space:]]*$' "$workflow" \
    || fail "bin/fm-dead-predicate-check.sh is not run by the CI workflow; nothing invokes the control automatically"
  pass "the control runs on the automatic repo-wide check path, not only by hand"
}

test_call_from_unenrolled_consumer_counts() {
  local dir out rc
  dir=$(fixture unenrolled-caller 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "unenrolled consumer: a real call was not counted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'DEAD' \
    && fail "unenrolled consumer: a called predicate was reported dead: $out"
  pass "a call from a non-enrolled consumer counts, so the verdict follows the code not the configuration"
}

test_unsupported_call_form_in_unenrolled_consumer_is_unchecked() {
  local dir out rc
  dir=$(fixture unenrolled-unsupported 'maybe_used() { return 0; }')
  add_plain_consumer "$dir" 'echo maybe_used'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "unenrolled unsupported call form did not fail closed, exit $rc: $out"
  printf '%s' "$out" | grep -q 'plain-consumer.sh.*unsupported call-site form for maybe_used' \
    || fail "unenrolled unsupported call form was not named: $out"
  pass "unsupported call forms are validated across unenrolled consumers"
}

test_unsupported_call_form_alone_is_not_red() {
  local dir out rc
  dir=$(fixture unsupported-not-red 'live_one() { return 0; }' 'live_one')
  add_plain_consumer "$dir" 'echo live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "unsupported consumer alone made the control red, exit $rc: $out"
  printf '%s' "$out" | grep -q 'plain-consumer.sh.*unsupported call-site form for live_one' \
    || fail "unsupported consumer was not accumulated and named: $out"
  pass "unsupported consumers alone do not make resolved predicates red"
}

test_single_quoted_substitution_is_not_a_call() {
  local dir out rc
  # Falsification seven. Text inside single quotes is DATA; a command
  # substitution written there is never executed and is not evidence of a call.
  dir=$(fixture single-quoted-sub "live_one() { return 0; }
dead_one() { return 0; }
helper() { printf '%s' '\$(dead_one)'; }")
  add_plain_consumer "$dir" 'live_one
helper'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "single-quoted substitution: dead_one was not reported, exit $rc: $out"
  printf '%s' "$out" | grep -q 'DEAD .*dead_one' \
    || fail "single-quoted substitution: quoted data counted as a call: $out"
  pass "a command substitution inside single quotes is data, not a call site"
}

test_quoted_prose_describing_a_call_is_not_a_call() {
  local dir out rc
  # Contributed by the reviewer of this control, who wrote the previous case into
  # a message inside double quotes and watched their own shell execute it. Text
  # that DESCRIBES a call, in a context that never runs it, must not count - and
  # that is evidently easy to get wrong even while concentrating on it.
  dir=$(fixture quoted-prose "live_one() { return 0; }
dead_one() { return 0; }
note() { printf '%s' 'call dead_one to do the thing'; }")
  add_plain_consumer "$dir" 'live_one
note'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "quoted prose: dead_one was not reported, exit $rc: $out"
  pass "prose naming a function inside quotes is not a call site"
}

test_unchecked_consumers_are_named_but_not_red() {
  local dir out rc
  dir=$(fixture unchecked-not-red 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  add_unparseable_consumer "$dir"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] \
    || fail "unchecked consumers: control went non-zero with every predicate alive, exit $rc: $out"
  printf '%s' "$out" | grep -q 'UNCHECKED' \
    || fail "unchecked consumers: the gap was not reported: $out"
  printf '%s' "$out" | grep -q 'unparseable.sh' \
    || fail "unchecked consumers: the file was not named: $out"
  pass "unchecked consumers are named and counted, and do not make the control red on their own"
}

test_unresolvable_predicate_is_could_not_observe_not_dead() {
  local dir out rc
  # The load-bearing distinction. With an unchecked consumer outstanding, a
  # predicate with no visible call site MIGHT be called in the file nobody could
  # read. Reporting DEAD there would licence deleting live code.
  dir=$(fixture cno-not-dead 'live_one() { return 0; }
maybe_used() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  # It must MENTION the predicate, or its universe is complete and DEAD is the
  # correct answer. This case previously passed under a global completeness rule
  # that Browser Sol superseded.
  add_unparseable_consumer "$dir" 'maybe_used'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "cno: expected could-not-observe exit 4, got $rc: $out"
  printf '%s' "$out" | grep -q 'CNO .*maybe_used' \
    || fail "cno: predicate not reported as could-not-observe: $out"
  printf '%s' "$out" | grep -q 'DEAD .*maybe_used' \
    && fail "cno: an unobservable predicate was reported DEAD: $out"
  pass "an unobservable predicate is could-not-observe, never dead and never clean"
}

test_unrelated_unchecked_consumer_does_not_hide_dead_predicate() {
  local dir out rc
  dir=$(fixture property-scoped-cno 'live_one() { return 0; }
dead_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one'
  add_unparseable_consumer "$dir"
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "unrelated unchecked consumer hid a dead predicate, exit $rc: $out"
  printf '%s' "$out" | grep -q 'DEAD .*dead_one' \
    || fail "dead predicate was not reported under property-scoped observation: $out"
  pass "unchecked consumers affect only predicates they loosely reference"
}

test_backtick_substitution_is_unchecked() {
  local dir out rc
  dir=$(fixture backtick-substitution 'maybe_used() { return 0; }')
  # shellcheck disable=SC2016 # The literal backticks are the fixture under test.
  add_plain_consumer "$dir" 'value=`maybe_used`'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "backtick substitution produced a definitive verdict, exit $rc: $out"
  printf '%s' "$out" | grep -q 'plain-consumer.sh.*legacy backtick substitution' \
    || fail "backtick substitution was not named unchecked: $out"
  printf '%s' "$out" | grep -q 'CNO .*maybe_used' \
    || fail "backtick candidate did not make its predicate could-not-observe: $out"
  pass "legacy backtick substitutions fail closed as unchecked candidates"
}

test_dead_function_is_refused
test_consulted_function_passes
test_unparsed_file_that_never_mentions_it_leaves_the_universe_complete
test_unparsed_file_that_mentions_it_makes_the_universe_incomplete
test_loose_exclusion_never_confirms_a_call
test_call_from_unenrolled_consumer_counts
test_unsupported_call_form_in_unenrolled_consumer_is_unchecked
test_unsupported_call_form_alone_is_not_red
test_single_quoted_substitution_is_not_a_call
test_quoted_prose_describing_a_call_is_not_a_call
test_unchecked_consumers_are_named_but_not_red
test_unresolvable_predicate_is_could_not_observe_not_dead
test_unrelated_unchecked_consumer_does_not_hide_dead_predicate
test_backtick_substitution_is_unchecked
test_mentions_are_not_call_sites
test_quoted_command_shape_is_not_a_call_site
test_heredoc_payload_is_not_a_call_site
test_punctuated_heredoc_does_not_hide_later_functions
test_escaped_heredoc_payload_is_not_code
test_multiple_heredocs_are_reported_unchecked
test_function_keyword_definition_is_scanned
test_quoted_awk_function_is_not_shell_syntax
test_explicit_indirect_call_counts
test_call_in_quoted_substitution_counts
test_multiline_double_quoted_command_shape_is_not_a_call
test_same_line_double_quoted_command_shape_is_not_a_call
test_unterminated_double_quote_is_unchecked
test_call_site_inside_its_own_file_counts
test_blanket_exemption_cannot_silence
test_adjacent_mark_keeps_one_and_still_reports_it
test_mark_must_be_adjacent_to_the_definition
test_no_enrolled_file_is_could_not_observe
test_outbound_library_stays_enrolled
test_control_is_wired_into_the_automatic_check_path
test_repository_has_no_dead_predicates_under_the_control

printf '\nall fm-dead-predicate-check tests passed\n'
