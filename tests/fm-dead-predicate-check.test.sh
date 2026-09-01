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
# shellcheck disable=SC2016 # Fixture programs expand only after they are written and executed.
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

test_explicit_indirect_call_counts() {
  local dir out rc
  # shellcheck disable=SC2016 # The generated fixture expands callback at runtime.
  dir=$(fixture indirect 'live_one() { return 0; }' 'dispatch() { "$2"; }
# indirect-call: live_one bin/consumer.sh:4
dispatch value live_one')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an explicitly identified indirect call was refused, exit $rc: $out"
  pass "an explicit indirect call site counts as consulted"
}

# THE MARK CASES. A mark is the one call form that is DECLARED rather than
# written, which is what makes it the one form a fabricated comment could forge.
# Every case below drives the control to a verdict from a fixture that differs by
# the dispatch alone, so a mark can never be observed to carry a verdict the code
# does not.

test_fabricated_mark_with_no_dispatch_is_refused_and_dead() {
  local dir out rc
  # THE WATCHED RED, and the exact shape that was measured red on this control.
  # The name occurs twice in the whole fixture: at its definition, and inside a
  # comment. There is no dispatch. One generation of this control read the
  # comment as positive proof and answered ALIVE, which is a proxy marker
  # upgrading an unobserved construct into a semantic fact.
  dir=$(fixture fabricated-mark 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one
echo unrelated'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a fabricated mark did not turn the control red, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*dead_one' \
    || fail "the fabricated mark was not refused by name: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' \
    || fail "the predicate the fabricated mark named was not reported dead: $out"
  pass "a fabricated indirect-call mark naming no dispatch site is refused, and the predicate stays dead"
}

test_quoted_trap_dispatch_named_by_a_site_counts() {
  local dir out rc
  # The positive arm, and its own negative control in the same fixture shape. A
  # single-quoted trap handler is a real call whose text this control's quote
  # walk blanks by design, so it is exactly the case a mark exists for. The first
  # arm proves the fixture is dead WITHOUT the mark, so the second arm's pass is
  # attributable to the verified site rather than to the fixture being alive
  # anyway.
  dir=$(fixture trap-site-negative 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" 'trap '\''cleanup_handler'\'' EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "trap site: the unmarked control arm was not dead, exit $rc: $out"

  dir=$(fixture trap-site 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:3
trap '\''cleanup_handler'\'' EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a mark naming a real quoted-trap dispatch was refused, exit $rc: $out"
  printf '%s' "$out" | grep -q 'alive=1' \
    || fail "the verified mark did not resolve the predicate as consulted: $out"
  pass "a mark naming a real quoted-trap dispatch counts, and the same fixture is dead without it"
}

test_mark_naming_a_wrong_line_is_refused() {
  local dir out rc
  # The line number is part of the claim. A mark left behind when its dispatch
  # moved must refuse rather than drift onto whatever now sits at that line,
  # because a mark that survives its own site is a stale positive.
  dir=$(fixture mark-wrong-line 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:1
trap '\''cleanup_handler'\'' EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark naming the wrong line was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*does not mention cleanup_handler' \
    || fail "the stale mark was not refused by name: $out"
  pass "a mark naming a line that does not dispatch the function is refused"
}

test_deleting_the_dispatch_while_keeping_the_mark_cannot_keep_it_alive() {
  local dir out rc
  # Same fixture, same mark, dispatch deleted. The verdict must follow the code.
  dir=$(fixture dispatch-deleted 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:3
trap '\''cleanup_handler'\'' EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "dispatch-deleted: the baseline arm was not alive, exit $rc: $out"
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:3
trap - EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "deleting the dispatch left the mark carrying the call, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*cleanup_handler' \
    || fail "the orphaned mark was not refused: $out"
  pass "deleting the invocation while keeping the mark does not preserve the call fact"
}

test_mark_site_past_end_of_file_is_refused() {
  local dir out rc
  dir=$(fixture mark-past-eof 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:900
trap '\''cleanup_handler'\'' EXIT'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark naming a line past end of file was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*past the end' \
    || fail "the out-of-range site was not named: $out"
  pass "a mark naming a line past the end of its site file is refused"
}

test_mark_site_in_an_unparseable_file_is_refused() {
  local dir out rc
  # A mark may not rescue a call site this control cannot read. The line-local
  # read cannot tell an unreadable file's payload text from its code, so a mark
  # pointing into a heredoc would let the "write a mark instead of repairing the
  # construct" move back in through the site.
  dir=$(fixture mark-unparseable-site 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/unparseable.sh:4'
  add_unparseable_consumer "$dir" 'cleanup_handler'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark into an unparseable file was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*not a file this control can parse' \
    || fail "the unparseable site was not named: $out"
  printf '%s' "$out" | grep -q 'alive=1' \
    && fail "a mark into an unparseable file was counted as a call: $out"
  pass "a mark naming a site inside a file this control cannot parse is refused"
}

test_mark_site_that_is_the_definition_is_refused() {
  local dir out rc
  dir=$(fixture mark-definition-site 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/sample-lib.sh:3'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark naming the definition was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*is the definition of' \
    || fail "the definition site was not named: $out"
  pass "a mark naming the function's own definition as its dispatch site is refused"
}

test_mark_site_inside_a_multiline_string_is_refused() {
  local dir out rc
  # The site is judged in FILE context, not line context. Read on its own, the
  # middle line of a multi-line string looks like a bare command; read through
  # the file's quote walk it is the data it actually is.
  dir=$(fixture mark-multiline-string-site 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:4
message="first
cleanup_handler
last"'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark into a multi-line string was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*cleanup_handler' \
    || fail "the quoted-data site was not refused: $out"
  pass "a mark naming a line inside a multi-line string is refused, because the site is read in file context"
}

test_mark_site_handing_the_name_to_an_output_command_is_refused() {
  local dir out rc
  # Opaque data at a site, exactly as it is everywhere else in this control.
  dir=$(fixture mark-output-command-site 'cleanup_handler() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: cleanup_handler bin/plain-consumer.sh:3
echo cleanup_handler'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mark naming an output command was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*opaque data' \
    || fail "the output-command site was not named: $out"
  pass "a mark naming a site that only prints the function name is refused"
}

test_mark_naming_a_bare_pass_by_name_dispatch_counts() {
  local dir out rc
  # The shape this repository actually uses: a validator handed to its caller by
  # name and invoked through a variable. The name is a bare word at the site, so
  # the shell really does hand that word to something that dispatches it.
  dir=$(fixture mark-pass-by-name 'validate_one() { return 0; }')
  # shellcheck disable=SC2016 # The generated fixture dispatches at runtime.
  add_plain_consumer "$dir" 'dispatch() { "$2"; }
# indirect-call: validate_one bin/plain-consumer.sh:4
dispatch value validate_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a mark naming a bare pass-by-name dispatch was refused, exit $rc: $out"
  pass "a mark naming a bare pass-by-name dispatch site counts as consulted"
}

test_arbitrary_command_arguments_are_refused_and_dead() {
  local command dir out rc
  for command in 'grep dead_one FILE' 'cp dead_one target' 'logger dead_one'; do
    dir=$(fixture "mark-argument-${command%% *}" 'dead_one() { return 0; }')
    add_plain_consumer "$dir" "# indirect-call: dead_one bin/plain-consumer.sh:3
$command"
    out=$(run_check "$dir" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "$command was accepted as dispatch, exit $rc: $out"
    printf '%s' "$out" | grep -q 'REFUSED.*dead_one' || fail "$command was not refused by name: $out"
    printf '%s' "$out" | grep -q 'DEAD.*dead_one' || fail "$command kept the predicate alive: $out"
  done
  pass "arguments to non-dispatching commands cannot manufacture call evidence"
}

test_data_mark_does_not_suppress_another_unsupported_use() {
  local dir out rc
  dir=$(fixture mark-data-and-unsupported 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:3
grep dead_one FILE
unknown_consumer --callback dead_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "the refused mark did not retain exit 3, exit $rc: $out"
  printf '%s' "$out" | grep -q 'CNO.*dead_one' || fail "the separate unsupported use did not yield CNO: $out"
  printf '%s' "$out" | grep -q 'unsupported call-site form for dead_one.*unknown_consumer' \
    || fail "the separate observation gap was not named: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' && fail "the observation gap collapsed to DEAD: $out"
  pass "a refused data mark suppresses only its exact classified source line"
}

test_assignment_site_is_refused_and_dead() {
  local dir out rc
  dir=$(fixture mark-assignment 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:3
value=dead_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "an assignment site was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*dead_one' || fail "the assignment mark was not refused: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' || fail "the assignment kept the predicate alive: $out"
  pass "an assignment cannot manufacture indirect-call evidence"
}

test_function_named_assignment_tokens_are_refused() {
  local body dir out rc
  for body in 'dead_one=value' 'env dead_one=value true'; do
    dir=$(fixture "named-assignment-${body%%=*}" 'dead_one() { return 0; }')
    add_plain_consumer "$dir" "# indirect-call: dead_one bin/plain-consumer.sh:3
$body"
    out=$(run_check "$dir" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "$body was accepted as a command head, exit $rc: $out"
    printf '%s' "$out" | grep -q 'REFUSED.*assignment' || fail "$body lacked a named refusal: $out"
    printf '%s' "$out" | grep -q 'DEAD.*dead_one' || fail "$body kept the predicate alive: $out"
  done
  pass "function-named assignment tokens are never command heads"
}

test_real_command_head_with_argument_counts() {
  local dir out rc
  dir=$(fixture real-command-head 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:3
dead_one --flag'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a genuine command head was refused, exit $rc: $out"
  pass "a genuine command head followed by an argument counts"
}

test_pass_by_name_ignores_definition_inside_quoted_data() {
  local dir out rc
  dir=$(fixture quoted-callee-definition 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'message="start
dispatch() { $2; }
end"
# indirect-call: live_one bin/plain-consumer.sh:6
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a quoted callee definition proved dispatch, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
    || fail "the quoted callee definition lacked a named refusal: $out"
  pass "a callee definition inside quoted data proves nothing"
}

test_pass_by_name_ignores_quoted_dispatch_data() {
  local dir out rc
  dir=$(fixture quoted-callee-dispatch 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'dispatch() {
  printf '\''%s\n'\'' '\''; "$2"'\''
}
# indirect-call: live_one bin/plain-consumer.sh:6
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "quoted dispatch data proved a call, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
    || fail "the quoted dispatch data lacked a named refusal: $out"
  pass "quoted text inside a callee body cannot prove parameter dispatch"
}

test_pass_by_name_requires_the_exact_argument_position() {
  local dir out rc
  dir=$(fixture mismatched-callee-position 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'dispatch() { "$1"; }
# indirect-call: live_one bin/plain-consumer.sh:4
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a mismatched positional dispatch was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
    || fail "the mismatched position lacked a named refusal: $out"
  pass "pass-by-name proof binds the exact positional argument"
}

test_pass_by_name_rejects_bound_variable_reassignment() {
  local dir out rc
  dir=$(fixture mutated-bound-variable 'dead_one() { return 0; }')
  add_plain_consumer "$dir" 'dispatch() { local check=${2:-}; check=echo; "$check"; }
# indirect-call: dead_one bin/plain-consumer.sh:4
dispatch value dead_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a reassigned callback variable was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
    || fail "the reassigned callback lacked a named refusal: $out"
  pass "pass-by-name proof rejects bound-variable reassignment"
}

test_pass_by_name_rejects_positional_mutation() {
  local body dir out rc variant=0
  for body in 'dispatch() { shift; "$2"; }' 'dispatch() { set -- a echo; "$2"; }' 'dispatch() { set a echo; "$2"; }'; do
    variant=$((variant + 1))
    dir=$(fixture "mutated-position-$variant" 'dead_one() { return 0; }')
    add_plain_consumer "$dir" "$body
# indirect-call: dead_one bin/plain-consumer.sh:4
dispatch value dead_one"
    out=$(run_check "$dir" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "positional mutation was accepted, exit $rc: $out"
    printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
      || fail "the positional mutation lacked a named refusal: $out"
  done
  pass "pass-by-name proof rejects positional-parameter mutation"
}

test_pass_by_name_rejects_unadmitted_bound_name_uses() {
  local body dir out rc variant=0
  for body in \
    'dispatch() { local check=${2:-}; check+=_suffix; "$check"; }' \
    'dispatch() { local check=${2:-}; read check; "$check"; }' \
    'dispatch() { local check=${2:-}; printf -v check echo; "$check"; }'; do
    variant=$((variant + 1))
    dir=$(fixture "unadmitted-bound-name-$variant" 'dead_one() { return 0; }')
    add_plain_consumer "$dir" "$body
# indirect-call: dead_one bin/plain-consumer.sh:4
dispatch value dead_one"
    out=$(run_check "$dir" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "an unadmitted bound-name use was accepted, exit $rc: $out"
    printf '%s' "$out" | grep -q 'REFUSED.*no proven command-head dispatch' \
      || fail "the unadmitted bound-name use lacked a named refusal: $out"
  done
  pass "pass-by-name proof admits only non-mutating bound-name expansions"
}

test_pass_by_name_refuses_payload_executing_bodies() {
  local body dir out rc variant=0
  for body in \
    'dispatch() { local check=${2:-}; eval '\''check=echo'\''; "$check"; }' \
    'dispatch() { local check=${2:-}; source /dev/null; "$check"; }' \
    'dispatch() { local check=${2:-}; . /dev/null; "$check"; }' \
    'dispatch() { local check=${2:-}; MODE=x eval '\''check=echo'\''; "$check"; }' \
    'dispatch() { local check=${2:-}; MODE=x source /dev/null; "$check"; }'; do
    variant=$((variant + 1))
    dir=$(fixture "payload-executing-body-$variant" 'dead_one() { return 0; }')
    add_plain_consumer "$dir" "$body
# indirect-call: dead_one bin/plain-consumer.sh:4
dispatch value dead_one"
    out=$(run_check "$dir" 2>&1); rc=$?
    [ "$rc" -eq 3 ] || fail "a payload-executing callee was accepted, exit $rc: $out"
    printf '%s' "$out" | grep -q 'REFUSED.*pass-by-name relation is could-not-observe' \
      || fail "the payload-executing callee lacked a named could-not-observe refusal: $out"
    printf '%s' "$out" | grep -q 'ALIVE.*dead_one' \
      && fail "the payload-executing callee promoted an unobservable relation to ALIVE: $out"
  done
  pass "payload-executing callees are refused as could-not-observe"
}

test_pass_by_name_accepts_unmutated_local_binding() {
  local dir out rc
  dir=$(fixture unmutated-local-binding 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'dispatch() { local a=$1 check=${2:-} b; "$check"; }
# indirect-call: live_one bin/plain-consumer.sh:4
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "an unmutated local callback binding was refused, exit $rc: $out"
  pass "pass-by-name proof accepts an unmutated multi-name local binding"
}

test_pass_by_name_accepts_production_shaped_body() {
  local dir out rc
  dir=$(fixture production-shaped-binding 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'helper() { return 0; }
dispatch() {
  local a=$1 check=${2:-} b
  b=value
  if helper; then
    helper "$b"
  fi
  [ -n "$check" ] && ! "$check" "$b"
}
# indirect-call: live_one bin/plain-consumer.sh:12
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a production-shaped callback body was refused, exit $rc: $out"
  pass "pass-by-name proof permits unrelated assignments, control flow, and helper calls"
}

test_dynamic_local_helper_mutation_is_a_declared_limit() {
  local dir out rc
  dir=$(fixture dynamic-local-helper-limit 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'mutate() { check=echo; }
dispatch() { local check=${2:-}; mutate; "$check"; }
# indirect-call: live_one bin/plain-consumer.sh:5
dispatch value live_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "the declared dynamic-local helper limit changed, exit $rc: $out"
  pass "dynamic-local mutation through a called helper remains outside observation"
}

test_comparison_site_is_refused_and_dead() {
  local dir out rc
  dir=$(fixture mark-comparison 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:3
[ "$value" = dead_one ]'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a comparison site was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*dead_one' || fail "the comparison mark was not refused: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' || fail "the comparison kept the predicate alive: $out"
  pass "a test comparison cannot manufacture indirect-call evidence"
}

test_trap_trailing_comment_site_is_refused_and_dead() {
  local dir out rc
  dir=$(fixture mark-trap-comment 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:3
trap '\''other'\'' EXIT # dead_one'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a trap trailing comment was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*dead_one' || fail "the trap-comment mark was not refused: $out"
  printf '%s' "$out" | grep -q 'DEAD.*dead_one' || fail "the trap comment kept the predicate alive: $out"
  pass "a trap-line trailing comment cannot manufacture indirect-call evidence"
}

test_quoted_marker_string_is_not_discovered() {
  local dir out rc
  dir=$(fixture quoted-marker 'live_one() { return 0; }' 'live_one
printf '\''%s\n'\'' '\''# indirect-call: live_one bin/consumer.sh:900'\''')
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a quoted marker string produced a refusal, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED' && fail "quoted marker data was discovered as a mark: $out"
  pass "a quoted marker string is data and never a mark"
}

test_a_refused_mark_is_red_even_when_the_function_is_alive() {
  local dir out rc
  # A refused mark is a written claim the code does not support, so it is red on
  # its own account. Letting a real call elsewhere absorb it would leave
  # manufactured evidence in the tree with nothing reporting it.
  dir=$(fixture refused-mark-still-red 'live_one() { return 0; }')
  add_plain_consumer "$dir" 'live_one
# indirect-call: live_one bin/plain-consumer.sh:900'
  out=$(run_check "$dir" 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "a refused mark on a live function was not red, exit $rc: $out"
  printf '%s' "$out" | grep -q 'REFUSED.*live_one' \
    || fail "the refused mark was not reported: $out"
  printf '%s' "$out" | grep -q 'DEAD' \
    && fail "a function with a real call site was reported dead: $out"
  pass "a mark that cannot be verified is red even when the function has a real call site"
}

test_mark_is_reported_in_json_with_its_site_and_reason() {
  local dir out rc
  # The JSON is what a downstream consumer reads, so the refusal has to be a
  # typed record there and not only a line of prose.
  dir=$(fixture mark-json 'dead_one() { return 0; }')
  add_plain_consumer "$dir" '# indirect-call: dead_one bin/plain-consumer.sh:900'
  out=$(run_check "$dir" --json 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "the JSON arm did not refuse, exit $rc: $out"
  printf '%s' "$out" | jq -e '
    .schema == "fm-dead-predicate-check.v2"
    and ((.refused_marks | length) == 1)
    and (.refused_marks[0].function == "dead_one")
    and (.refused_marks[0].site == "bin/plain-consumer.sh:900")
    and ((.refused_marks[0].reason | length) > 0)
    and (.alive == 0)
  ' >/dev/null \
    || fail "the refusal was not a typed JSON record: $out"
  pass "a refused mark is reported as a typed record naming its site and its reason"
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
    .schema == "fm-dead-predicate-check.v2"
    and (.alive > 0)
    and ((.dead | length) == 0)
    and ((.could_not_observe | length) == 0)
    and ((.refused_marks | length) == 0)
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
test_explicit_indirect_call_counts
test_fabricated_mark_with_no_dispatch_is_refused_and_dead
test_quoted_trap_dispatch_named_by_a_site_counts
test_mark_naming_a_wrong_line_is_refused
test_deleting_the_dispatch_while_keeping_the_mark_cannot_keep_it_alive
test_mark_site_past_end_of_file_is_refused
test_mark_site_in_an_unparseable_file_is_refused
test_mark_site_that_is_the_definition_is_refused
test_mark_site_inside_a_multiline_string_is_refused
test_mark_site_handing_the_name_to_an_output_command_is_refused
test_mark_naming_a_bare_pass_by_name_dispatch_counts
test_arbitrary_command_arguments_are_refused_and_dead
test_data_mark_does_not_suppress_another_unsupported_use
test_assignment_site_is_refused_and_dead
test_function_named_assignment_tokens_are_refused
test_real_command_head_with_argument_counts
test_pass_by_name_ignores_definition_inside_quoted_data
test_pass_by_name_ignores_quoted_dispatch_data
test_pass_by_name_requires_the_exact_argument_position
test_pass_by_name_rejects_bound_variable_reassignment
test_pass_by_name_rejects_positional_mutation
test_pass_by_name_rejects_unadmitted_bound_name_uses
test_pass_by_name_refuses_payload_executing_bodies
test_pass_by_name_accepts_unmutated_local_binding
test_pass_by_name_accepts_production_shaped_body
test_dynamic_local_helper_mutation_is_a_declared_limit
test_comparison_site_is_refused_and_dead
test_trap_trailing_comment_site_is_refused_and_dead
test_quoted_marker_string_is_not_discovered
test_a_refused_mark_is_red_even_when_the_function_is_alive
test_mark_is_reported_in_json_with_its_site_and_reason
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
