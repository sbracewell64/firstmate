#!/usr/bin/env bash
# Tests for bin/fm-review-mutation.sh, the proof owner that answers whether a
# NAMED TARGET ASSERTION ran and what it concluded.
#
# The predecessor it replaces failed by running a whole suite and treating an
# exact textual `ok - <case>` / `not ok - <case>: <failure>` line as proof that
# the named assertion had executed. Its catalogue routed many distinct cases
# through that one broad-suite wrapper, including cases whose stated purpose was
# proving that labels and proxies cannot establish execution.
#
# So the decisive control here is a probe that prints exactly that line, and the
# proof owner's own success record with it, while never evaluating the assertion
# at all. A label-reading implementation returns PASS for it. The assertion is
# that this one returns FAIL.
#
# The other controls name the proxy or the law each refuses:
#
#   label            the matching success line in the probe's own output
#   own-literal      this script's own emitted record, planted in that output
#   attribution      a substitution that moves the verdict for another reason
#   occurrence       a target that is not uniquely located
#   apparatus        the machinery moving the verdict rather than the mutation
#   isolation        a clone that shares object storage with the source
#   source-custody   the source mutated by the control that reads it
#   immutability     a second generation written over the first
#   stored-outcome   a record believed rather than re-derived
#   precedence       an observation gap masking a real finding
#   prose            a caller declaration reaching a verdict
#
# Four seams exist so these controls can be re-run against deliberately
# defective builds and watched going red; docs/verification/review-mutation-proof.md
# records those runs. Each defaults to the shipped artifact, so none of them
# changes anything in production:
#
#   FM_REVIEW_MUTATION_BIN     the proof owner under test
#   FM_VERIFY_BIN              the wrapper that transports its result, which
#                              resolves the proof owner from its OWN directory
#   FM_REVIEW_MUTATION_RECORD  the verification record the drift control reads.
#                              The drift control's subject is the RECORD, not the
#                              binary, so overriding the binary cannot redden it;
#                              without this seam it would be the one control that
#                              could never be watched red, which is exactly the
#                              condition it was written to detect elsewhere.
#   FM_REVIEW_MUTATION_ONLY    the single declared control to run, refused when
#                              it does not name a member of FM_CONTROLS.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Read by tests/lib.sh pass() to record executed test identities for the drift control.
# shellcheck disable=SC2034
FM_TEST_IDENTITY_CONTRACT=1
fm_git_identity fmtest fmtest@example.invalid

BIN=${FM_REVIEW_MUTATION_BIN:-$ROOT/bin/fm-review-mutation.sh}
# The wrapper is a second seam because the adapter that transports this result
# is its own thing to watch red: bin/fm-verify.sh resolves the proof owner from
# its OWN directory, so overriding only the binary above would still exercise
# the shipped adapter against the shipped proof owner.
VERIFY_BIN=${FM_VERIFY_BIN:-$ROOT/bin/fm-verify.sh}
TMP_ROOT=$(fm_test_tmproot fm-review-mutation-tests)

# The exact target assertion every fixture case names. It occurs once in the
# honest suite, which is what makes it a legal mutation target. These are the
# bytes of shell source, not shell to run here, so the single quotes are the
# point.
# shellcheck disable=SC2016
TARGET='[ "$(cat subject.txt)" = "expected" ]'
# shellcheck disable=SC2016
FALSIFY='[ "$(cat subject.txt)" = "never-matches" ]'
SATISFY='true'

# The record row this script emits on success. Probes plant it on purpose: if a
# case passes because of it, the proof owner is reading its own success text
# back out of a stream it must never open.
PASS_LITERAL='  review-mutation,PASS,verified,'

write_bytes() {  # <path> <content>
  printf '%s' "$2" >"$1"
}

inventory_digest_file() {  # <path>
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

source_snapshot() {  # <directory>
  local root=$1 path relative kind digest
  while IFS= read -r path; do
    relative=${path#"$root"/}
    if [ -f "$path" ]; then
      kind="file"
      digest=$(inventory_digest_file "$path") || return 1
    elif [ -L "$path" ]; then
      kind="link"
      digest=$(readlink "$path") || return 1
    else
      kind=directory
      digest=-
    fi
    printf '%s\t%s\t%s\n' "$kind" "$relative" "$digest"
  done < <(find "$root" -mindepth 1 -print | LC_ALL=C sort)
}

# A source the proof owner will accept: a linked worktree, never a primary
# checkout. Returns the case directory.
make_case() {  # <name> [subject-content]
  local name=$1 subject=${2:-expected} case_dir
  case_dir=$TMP_ROOT/$name
  mkdir -p "$case_dir/primary/tests"
  git init -q "$case_dir/primary"
  printf '%s\n' "$subject" >"$case_dir/primary/subject.txt"

  # The honest suite: it really evaluates the target assertion.
  cat >"$case_dir/primary/tests/honest.sh" <<EOF
#!/usr/bin/env bash
# recurrence guard
$TARGET || { printf 'not ok - assertion-A\n'; exit 1; }
printf 'ok - assertion-A\n'
EOF

  # The retired defect, as a probe: it prints the exact line a label-reading
  # implementation accepts, plus this script's own success record, and never
  # evaluates the assertion.
  cat >"$case_dir/primary/tests/liar.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok - assertion-A\n'
printf 'verify[1]{verifier,result,reason,evidence_ref}:\n'
printf '  review-mutation,PASS,verified,/dev/null\n'
printf 'FM_RECURRENCE_ASSERTION_EXECUTED case=assertion-A\n'
exit 0
EOF

  # An honest run that ALSO plants this script's FAILURE record in its output,
  # to check the literal cannot hurt a real execution any more than it can help
  # a fake one. It really runs the honest suite, so the mutated file is the one
  # its verdict depends on.
  cat >"$case_dir/primary/tests/honest-noisy.sh" <<'EOF'
#!/usr/bin/env bash
printf '  review-mutation,FAIL,verifier_reported_failure,/dev/null\n'
printf 'not ok - assertion-A\n'
exec bash tests/honest.sh
EOF

  git -C "$case_dir/primary" add -A
  git -C "$case_dir/primary" commit -qm candidate
  git -C "$case_dir/primary" worktree add -q --detach "$case_dir/src" HEAD

  write_bytes "$case_dir/target.bytes" "$TARGET"
  write_bytes "$case_dir/falsify.bytes" "$FALSIFY"
  write_bytes "$case_dir/satisfy.bytes" "$SATISFY"
  printf '%s\n' "$case_dir"
}

run_prove() {  # <case-dir> <out-name> <probe argv...>
  local case_dir=$1 out=$2
  shift 2
  "$BIN" prove --case "case-$out" --source "$case_dir/src" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/$out" -- "$@"
}

record_result() {  # <dir> -> the result token
  "$BIN" result "$1" 2>/dev/null | sed -n 's/^  review-mutation,\([A-Z_]*\),.*/\1/p'
}

record_reason() {  # <dir> -> the reason token
  "$BIN" result "$1" 2>/dev/null | sed -n 's/^  review-mutation,[A-Z_]*,\([a-z_]*\),.*/\1/p'
}

record_basis() {  # <dir> -> the basis token from stderr
  "$BIN" result "$1" 2>&1 >/dev/null | sed -n 's/^fm-review-mutation: basis: //p'
}

# --- the decisive control ---------------------------------------------------

test_a_matching_success_line_cannot_establish_that_the_target_ran() {
  local case_dir out code
  case_dir=$(make_case decisive)

  # The probe emits exactly the line the retired substrate accepted, plus this
  # script's own PASS record, and exits 0. It never evaluates the assertion.
  set +e
  out=$(run_prove "$case_dir" liar bash tests/liar.sh 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" \
    "a target that did not execute must FAIL even when a suite printed its success line"
  assert_contains "$out" 'review-mutation,FAIL,' \
    "the case must classify FAIL, not PASS and not could-not-observe"
  assert_contains "$out" 'basis: target_not_executed' \
    "the record must say the verdict was not controlled by the target"

  # And the reason it failed is not the reason a real failing assertion fails.
  [ "$(record_basis "$case_dir/liar")" = target_not_executed ] \
    || fail "a non-executing target and a failing target must not share a basis"

  # The proof of the mechanism: all three executions agreed, so the probe's
  # verdict never depended on the bytes the case named.
  local rec=$case_dir/liar/record.json
  [ "$(jq -r '.dimensions.baseline_execution.value.result' "$rec")" = PASS ] \
    || fail "the baseline run of the label-printing probe must be observed PASS"
  [ "$(jq -r '.dimensions.falsified_execution.value.result' "$rec")" = PASS ] \
    || fail "the falsified run must be observed PASS, which is what makes this a finding"
  pass "label: a matching success line cannot establish that the named target ran"
}

test_the_proof_owners_own_success_literal_cannot_reach_a_verdict() {
  local case_dir out code
  case_dir=$(make_case own_literal)

  # The literal is in the liar's stream and the liar still fails, which is
  # asserted above. Here the opposite direction: an honest probe that plants
  # this script's FAILURE record still passes, so the literal is inert in both
  # directions rather than merely ignored when convenient.
  set +e
  out=$(run_prove "$case_dir" noisy bash tests/honest-noisy.sh 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" \
    "a real execution must pass even while printing this script's failure record"
  assert_contains "$out" "$PASS_LITERAL" "the emitted record is the proof owner's own"
  assert_contains "$(cat "$case_dir/noisy/exec/baseline/review.raw")" \
    'review-mutation,FAIL,' "the planted literal must really be in the captured stream"
  pass "own-literal: this script's emitted record is inert inside a probe's output"
}

# --- the three honest outcomes ----------------------------------------------

test_a_target_that_executed_and_passed_is_a_pass() {
  local case_dir out code rec
  case_dir=$(make_case executed_pass)
  set +e
  out=$(run_prove "$case_dir" honest bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 0 "$code" "an executed target that concluded pass is PASS"
  assert_contains "$out" 'review-mutation,PASS,verified,' "the record must classify PASS"
  [ "$(record_basis "$case_dir/honest")" = target_executed_and_concluded_pass ] \
    || fail "the basis must say the target executed and concluded pass"

  rec=$case_dir/honest/record.json
  # Bidirectional control is what established execution, so both directions
  # are asserted rather than the verdict alone.
  [ "$(jq -r '.dimensions.falsified_execution.value.result' "$rec")" = FAIL ] \
    || fail "falsifying the target must make the probe fail"
  [ "$(jq -r '.dimensions.satisfied_execution.value.result' "$rec")" = PASS ] \
    || fail "satisfying the target must make the probe pass"
  [ "$(jq -r '.dimensions.baseline_execution.value.result' "$rec")" = PASS ] \
    || fail "the unmutated candidate must be the run that reports the conclusion"
  pass "a target that genuinely executed and passed is PASS"
}

test_a_target_that_executed_and_failed_is_a_fail() {
  local case_dir out code
  case_dir=$(make_case executed_fail wrong)
  set +e
  out=$(run_prove "$case_dir" honest bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "an executed target that concluded fail is FAIL"
  assert_contains "$out" 'review-mutation,FAIL,verifier_reported_failure,' \
    "the record must classify FAIL"
  [ "$(record_basis "$case_dir/honest")" = target_executed_and_concluded_fail ] \
    || fail "the basis must distinguish a failing target from one that never ran"
  [ "$(jq -r '.dimensions.satisfied_execution.value.result' "$case_dir/honest/record.json")" = PASS ] \
    || fail "the satisfying direction is what makes the failing baseline attributable"
  pass "a target that executed and failed is FAIL, with a basis distinct from non-execution"
}

test_an_unattributable_substitution_is_could_not_observe() {
  local case_dir out code
  case_dir=$(make_case attribution)
  # Both substitutions break the file rather than flipping the assertion, so
  # the falsified run's badness is not attributable to the target.
  write_bytes "$case_dir/falsify.bytes" '((('
  write_bytes "$case_dir/satisfy.bytes" ')))'
  set +e
  out=$(run_prove "$case_dir" broken bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" \
    "a substitution that moves the verdict for another reason is could-not-observe"
  assert_contains "$out" 'review-mutation,NO_VERIFIER_RAN,no_verdict_reached,' \
    "an unattributable control must not reach PASS or FAIL"
  [ "$(record_basis "$case_dir/broken")" = control_not_attributable ] \
    || fail "the basis must name the broken attribution"
  pass "attribution: a satisfying substitution that does not satisfy is could-not-observe"
}

# --- the exactly-one-occurrence guard ---------------------------------------

test_a_target_occurring_more_than_once_is_refused() {
  local case_dir out code
  case_dir=$(make_case occurrence_many)
  write_bytes "$case_dir/target.bytes" 'printf'
  set +e
  out=$(run_prove "$case_dir" many bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a target with more than one occurrence has no single site"
  assert_contains "$out" 'exactly one occurrence is required' \
    "the refusal must name the guard"
  [ ! -f "$case_dir/many/record.json" ] || fail "a refused case must write no record"
  pass "occurrence: a target appearing multiple times is refused"
}

test_a_target_occurring_zero_times_is_refused() {
  local case_dir out code
  case_dir=$(make_case occurrence_none)
  write_bytes "$case_dir/target.bytes" 'THIS_TEXT_IS_NOT_IN_THE_FILE'
  set +e
  out=$(run_prove "$case_dir" none bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a target that is not there cannot be mutated"
  assert_contains "$out" 'target occurs 0 times' "the refusal must report the count it saw"
  pass "occurrence: a target appearing zero times is refused"
}

test_overlapping_occurrences_are_counted_separately() {
  local case_dir out code
  case_dir=$(make_case occurrence_overlap)
  # "aa" occupies two start positions in "aaa". A non-overlapping count reports
  # one and mutates a site nobody chose.
  printf 'aaa\n' >"$case_dir/primary/overlap.txt"
  git -C "$case_dir/primary" add -A
  git -C "$case_dir/primary" commit -qm overlap
  git -C "$case_dir/src" checkout -q --detach HEAD 2>/dev/null
  write_bytes "$case_dir/target.bytes" 'aa'
  set +e
  out=$("$BIN" prove --case overlap --source "$case_dir/src" \
    --candidate "$(git -C "$case_dir/primary" rev-parse HEAD)" --path overlap.txt \
    --target "$case_dir/target.bytes" --falsify "$case_dir/falsify.bytes" \
    --satisfy "$case_dir/satisfy.bytes" --out "$case_dir/overlap" \
    -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "overlapping occurrences must not collapse into one site"
  assert_contains "$out" 'target occurs 2 times' \
    "overlapping start positions must be counted separately"
  pass "occurrence: overlapping occurrences are counted by start position"
}

# --- the apparatus control --------------------------------------------------

test_the_identity_substitution_reproduces_the_candidate_tree() {
  local case_dir rec
  case_dir=$(make_case apparatus)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  rec=$case_dir/honest/record.json
  # The baseline runs through the whole splice-blob-tree-commit-clone-launch
  # path, so if its tree equals the candidate's, nothing the other two runs
  # showed is an artifact of the machinery.
  [ "$(jq -r '.dimensions.baseline_tree.value' "$rec")" \
    = "$(jq -r '.dimensions.candidate_tree.value' "$rec")" ] \
    || fail "the identity substitution must reproduce the candidate tree exactly"
  [ "$(jq -r '.dimensions.falsified_tree.value' "$rec")" \
    != "$(jq -r '.dimensions.candidate_tree.value' "$rec")" ] \
    || fail "the falsifying substitution must change the tree"
  [ "$(jq -r '.dimensions.falsified_tree.value' "$rec")" \
    != "$(jq -r '.dimensions.satisfied_tree.value' "$rec")" ] \
    || fail "the two substitutions must produce different trees"
  pass "apparatus: substituting the target with itself reproduces the candidate tree"
}

test_a_substitution_identical_to_the_target_is_refused() {
  local case_dir out code
  case_dir=$(make_case inert_substitution)
  write_bytes "$case_dir/falsify.bytes" "$TARGET"
  set +e
  out=$(run_prove "$case_dir" inert bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a falsifying substitution equal to the target falsifies nothing"
  assert_contains "$out" 'the falsifying substitution is the target itself' \
    "the refusal must name what was not tested"
  pass "apparatus: a substitution equal to the target is refused"
}

# --- source custody and isolation -------------------------------------------

test_the_source_is_never_mutated() {
  local case_dir before_head before_tree before_refs before_status expected samples
  case_dir=$(make_case custody)
  before_head=$(git -C "$case_dir/src" rev-parse HEAD)
  before_tree=$(git -C "$case_dir/src" rev-parse 'HEAD^{tree}')
  before_refs=$(git -C "$case_dir/primary" for-each-ref --format='%(refname) %(objectname)')
  before_status=$(git -C "$case_dir/src" status --porcelain)
  expected=$(git -C "$case_dir/src" rev-parse 'HEAD:tests/honest.sh')

  # The end state is not the property. Restore-in-finally would satisfy every
  # after-the-fact check while a concurrent reader saw the mutated file, so the
  # source is sampled DURING the run - by the probe itself, which is the one
  # thing running at the moment any mutation would be live. Three executions,
  # three samples.
  set +e
  run_prove "$case_dir" honest bash -c \
    "git -C '$case_dir/src' hash-object -- '$case_dir/src/tests/honest.sh' >> '$case_dir/samples'" \
    >/dev/null 2>&1
  set -e
  samples=$(sort -u "$case_dir/samples" 2>/dev/null)
  [ "$(wc -l <"$case_dir/samples" 2>/dev/null)" = 3 ] \
    || fail "the source must have been sampled once per execution"
  [ "$samples" = "$expected" ] \
    || fail "the source file must be unmutated at every moment an execution was live"

  [ "$(git -C "$case_dir/src" rev-parse HEAD)" = "$before_head" ] \
    || fail "the source's HEAD must be untouched"
  [ "$(git -C "$case_dir/src" rev-parse 'HEAD^{tree}')" = "$before_tree" ] \
    || fail "the source's tree must be untouched"
  [ "$(git -C "$case_dir/primary" for-each-ref --format='%(refname) %(objectname)')" = "$before_refs" ] \
    || fail "the mutation must create no ref in the source repository"
  [ "$(git -C "$case_dir/src" status --porcelain)" = "$before_status" ] \
    || fail "the source working tree must be untouched"
  [ "$(git -C "$case_dir/primary" cat-file -t \
      "$(jq -r '.dimensions.falsified_commit.value' "$case_dir/honest/record.json")" 2>&1)" \
    != commit ] \
    || fail "the mutant commit must not exist in the source repository at all"
  pass "source-custody: the control never mutates the artifact it protects, at any moment"
}

test_the_disposable_clone_shares_no_object_storage() {
  local case_dir staging
  case_dir=$(make_case isolation)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  staging=$(jq -r '.dimensions.staging_root.value' "$case_dir/honest/record.json")
  [ -d "$staging" ] || fail "the record must name a clone that exists"
  # Losing --no-local is invisible to every other check, so the property is
  # measured rather than the flag trusted.
  [ -z "$(find "$staging/.git/objects" -type f -links +1 -print 2>/dev/null | head -n 1)" ] \
    || fail "the disposable clone must share no object storage with the source"
  [ ! -e "$staging/.git/objects/info/alternates" ] \
    || fail "the disposable clone must carry no alternates"
  [ "$(git -C "$staging" rev-parse --git-common-dir)" = .git ] \
    || fail "the disposable clone must own its repository administration"
  pass "isolation: the mutation clone owns its administration and shares no objects"
}

test_a_refused_source_is_never_written_to() {
  local case_dir before after out code
  case_dir=$(make_case refused_custody)

  # The output path is placed INSIDE the checkout that is about to be refused.
  # A build that claims its output directory before it judges the source prints
  # a perfectly correct refusal and leaves a directory behind in the thing it
  # refused - the control mutating the artifact it protects. The refusal text is
  # not the property under test here; the absence of a trace is.
  before=$(find "$case_dir/primary" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)
  set +e
  out=$("$BIN" prove --case refused --source "$case_dir/primary" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/primary/evidence" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  after=$(find "$case_dir/primary" -mindepth 1 -maxdepth 1 | LC_ALL=C sort)

  expect_code 2 "$code" "a primary checkout as source is could-not-observe"
  assert_contains "$out" 'refuses a primary checkout as its source' \
    "the refusal must name what it rejected"
  [ ! -e "$case_dir/primary/evidence" ] \
    || fail "a refused source must carry no trace of the refusal"
  [ "$before" = "$after" ] \
    || fail "refusing a source must leave its contents exactly as they were"
  pass "source-custody: a refused source is never written to, not even the output directory"
}

test_a_traversing_output_is_refused_without_touching_the_source() {
  local case_dir before after out code
  case_dir=$(make_case traversing_output)
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" prove --case traversal --source "$case_dir/src" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/new/../src/evidence" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "an output path containing traversal is refused"
  [ "$before" = "$after" ] \
    || fail "a traversing output refusal must leave the source byte-identical"
  assert_contains "$out" 'must not contain a .. component' \
    "the refusal must name the closed traversal rule"
  pass "source-custody: traversal in a nonexistent output suffix creates nothing in the source"
}

test_prove_refuses_output_through_a_symlinked_source_ancestor() {
  local case_dir before after out code
  case_dir=$(make_case prove_symlinked_output)
  ln -s "$case_dir/src" "$case_dir/source-alias"
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" prove --case symlinked-output --source "$case_dir/src" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/source-alias/evidence" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "prove output through a symlinked source ancestor is refused"
  assert_contains "$out" 'output directory is inside the source checkout' \
    "the prove refusal must name the physical source containment violation"
  [ ! -e "$case_dir/src/evidence" ] \
    || fail "prove containment refusal must happen before creating output"
  [ "$before" = "$after" ] \
    || fail "prove containment refusal must leave the source byte-identical"
  pass "source-custody: prove resolves a symlinked output ancestor physically"
}

test_prove_protects_the_checkout_when_source_is_a_subdirectory() {
  local case_dir before after out code
  case_dir=$(make_case prove_subdirectory_source)
  mkdir "$case_dir/src/evidence-target"
  ln -s "$case_dir/src/evidence-target" "$case_dir/evidence-link"
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" prove --case subdirectory-source --source "$case_dir/src/tests" \
    --candidate HEAD --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/evidence-link" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "prove protects the checkout root for a subdirectory source"
  assert_contains "$out" 'output directory is inside the source checkout' \
    "the prove refusal must name checkout-root containment"
  [ -z "$(ls -A "$case_dir/src/evidence-target")" ] \
    || fail "prove must refuse an output-leaf symlink before writing through it"
  [ "$before" = "$after" ] \
    || fail "prove with a subdirectory source must leave the checkout byte-identical"
  pass "source-custody: prove protects the checkout root for a subdirectory source"
}

test_refuses_a_primary_checkout_as_its_source() {
  local case_dir out code
  case_dir=$(make_case primary_source)
  set +e
  out=$("$BIN" prove --case primary --source "$case_dir/primary" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/out" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a primary checkout is refused as a mutation source"
  assert_contains "$out" 'refuses a primary checkout as its source' \
    "the refusal must name the source it rejected"
  pass "source-custody: a primary checkout is refused as the source"
}

# --- immutability and re-derivation -----------------------------------------

test_refuses_to_overwrite_an_existing_record() {
  local case_dir out code first
  case_dir=$(make_case immutable)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  first=$(jq -r '.recorded_at' "$case_dir/honest/record.json")
  set +e
  out=$(run_prove "$case_dir" honest bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a second generation must not be written over the first"
  assert_contains "$out" 'a record is written once' "the refusal must name the rule"
  [ "$(jq -r '.recorded_at' "$case_dir/honest/record.json")" = "$first" ] \
    || fail "the first generation must survive the refused second"
  pass "immutability: a second prove into an occupied directory is refused"
}

test_a_record_whose_mutants_are_gone_is_could_not_observe() {
  local case_dir staging
  case_dir=$(make_case stored_outcome)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  [ "$(record_result "$case_dir/honest")" = PASS ] || fail "the case must pass before the evidence is removed"
  staging=$(jq -r '.dimensions.staging_root.value' "$case_dir/honest/record.json")
  rm -rf "$staging"
  # The record still says everything it said a moment ago. The answer must not.
  [ "$(record_result "$case_dir/honest")" = NO_VERIFIER_RAN ] \
    || fail "a record whose mutation evidence is gone must be could-not-observe"
  [ "$(record_basis "$case_dir/honest")" = mutation_evidence_unreadable ] \
    || fail "the basis must name the unreadable evidence"
  pass "stored-outcome: the result is re-derived from evidence, never read from the record"
}

test_an_edited_record_cannot_be_read_into_a_verdict() {
  local case_dir rec
  case_dir=$(make_case edited_record)
  set +e
  run_prove "$case_dir" liar bash tests/liar.sh >/dev/null 2>&1
  set -e
  [ "$(record_result "$case_dir/liar")" = FAIL ] || fail "the label case must fail before editing"
  rec=$case_dir/liar/record.json
  # Rewrite the stored execution results into the shape of a passing case. The
  # answer comes from re-reading the executions, so the edit must not land.
  jq '.dimensions.falsified_execution.value.result = "FAIL"
      | .dimensions.satisfied_execution.value.result = "PASS"' "$rec" >"$rec.new"
  mv "$rec.new" "$rec"
  [ "$(record_result "$case_dir/liar")" = FAIL ] \
    || fail "edited execution results must not change the derived verdict"
  pass "stored-outcome: edited execution results in the record cannot reach a verdict"
}

test_an_execution_from_the_wrong_variant_is_could_not_observe() {
  local case_dir
  case_dir=$(make_case wrong_execution)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  rm -rf "$case_dir/honest/exec/baseline"
  cp -R "$case_dir/honest/exec/satisfied" "$case_dir/honest/exec/baseline"
  [ "$(record_result "$case_dir/honest")" = NO_VERIFIER_RAN ] \
    || fail "an execution for another mutation must not enter the fold"
  pass "stored-outcome: every execution is bound to its mutation and probe argv"
}

test_preserved_mutation_bytes_are_rederived() {
  local case_dir
  case_dir=$(make_case changed_bytes)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  printf 'exit 0\n' >"$case_dir/honest/work/falsify.bytes"
  [ "$(record_result "$case_dir/honest")" = NO_VERIFIER_RAN ] \
    || fail "changed preserved bytes must invalidate the claimed mutant"
  pass "stored-outcome: mutation blobs and metadata are rederived from preserved bytes"
}

test_a_missing_dimension_outranks_a_clean_fold() {
  local case_dir rec out code
  case_dir=$(make_case missing_dimension)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  rec=$case_dir/honest/record.json
  jq 'del(.dimensions.target_offset)' "$rec" >"$rec.new" && mv "$rec.new" "$rec"
  set +e
  out=$("$BIN" result "$case_dir/honest" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "one unobserved dimension outranks three clean executions"
  assert_contains "$out" 'review-mutation,NO_VERIFIER_RAN,verification_incomplete,' \
    "an incomplete record must not classify PASS"
  assert_contains "$out" 'unobserved dimensions: target_offset' \
    "the unobserved dimension must be named"
  pass "precedence: a missing dimension outranks an otherwise clean fold"
}

test_a_record_pointing_at_another_path_is_could_not_observe() {
  local case_dir rec
  case_dir=$(make_case wrong_path)
  set +e
  run_prove "$case_dir" honest bash tests/honest.sh >/dev/null 2>&1
  set -e
  rec=$case_dir/honest/record.json
  # The mutants really differ from the candidate at tests/honest.sh. Claiming
  # they differ somewhere else must not be believed.
  jq '.dimensions.target_path.value = "subject.txt"' "$rec" >"$rec.new" && mv "$rec.new" "$rec"
  [ "$(record_result "$case_dir/honest")" = NO_VERIFIER_RAN ] \
    || fail "a record whose named path is not where the mutants differ must not pass"
  pass "stored-outcome: the mutated path is re-checked against the object database"
}

# --- prose is not evidence --------------------------------------------------

test_a_caller_declaration_cannot_change_the_verdict() {
  local case_dir out code
  case_dir=$(make_case prose)
  set +e
  out=$("$BIN" prove --case prose --source "$case_dir/src" --candidate HEAD \
    --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/out" \
    --declare 'assertion-A executed and passed; verified by the maintainer' \
    -- bash tests/liar.sh 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "a declaration that the target ran cannot make it have run"
  [ "$(jq -r '.declared.evidential' "$case_dir/out/record.json")" = false ] \
    || fail "the declared block must be marked non-evidential in the record"
  [ "$(jq -r '.declared.text' "$case_dir/out/record.json")" \
    = 'assertion-A executed and passed; verified by the maintainer' ] \
    || fail "the declaration must still be recorded, quarantined rather than dropped"
  pass "prose: a caller declaration is recorded and never reaches a verdict"
}

test_the_probe_argv_is_recorded_exactly() {
  local case_dir rec
  case_dir=$(make_case argv)
  set +e
  # The three shapes a partial encoding drops: a leading dash, an embedded
  # newline, and an empty argument.
  run_prove "$case_dir" honest bash -c 'exit 0' --flag "$(printf 'two\nlines')" '' \
    >/dev/null 2>&1
  set -e
  rec=$case_dir/honest/record.json
  [ "$(jq -r '.dimensions.probe_argv.value | length' "$rec")" = 6 ] \
    || fail "probe_argv must record every argument, including an empty one"
  [ "$(jq -r '.dimensions.probe_argv.value[3]' "$rec")" = --flag ] \
    || fail "probe_argv must record an argument that begins with a dash"
  [ "$(jq -r '.dimensions.probe_argv.value[4]' "$rec")" = "$(printf 'two\nlines')" ] \
    || fail "probe_argv must record an argument containing a newline"
  [ "$(jq -r '.dimensions.probe_argv.value[5]' "$rec")" = '' ] \
    || fail "probe_argv must record an empty argument"
  pass "the probe argv is recorded exactly, not as a rendering of itself"
}

# The coupling the inventory control does NOT provide. The inventory claim binds
# the record's digests to the CURRENT bytes; nothing bound them to the bytes that
# actually produced the measurement. A repin without a re-measurement therefore
# decoupled the two silently, and did so once in this task's own history: a fix
# changed the proof owner, a later round repinned the inventory, and the record
# went on reporting a measurement taken against bytes that no longer existed
# while every control stayed green.
#
# So the record also carries the digests AS MEASURED, and this control fails when
# they differ from the current subject. Inventory says "these are the files";
# measurement says "these are the bytes the matrix was taken against". Keeping
# both and requiring them to agree is what makes staleness observable instead of
# merely unlikely.
test_recorded_measurement_describes_the_current_subject() {
  local record=${FM_REVIEW_MUTATION_RECORD:-$ROOT/docs/verification/review-mutation-proof.md}
  local path documented actual measured_any=0

  [ -r "$record" ] || fail "the mutation verification record must be readable"
  for path in bin/fm-review-mutation.sh bin/fm-verify.sh \
    tests/fm-review-mutation.test.sh tests/review-mutation-red-matrix.py; do
    documented=$(sed -n "s|^measured_sha256: $path \([0-9a-f][0-9a-f]*\)$|\1|p" "$record")
    [ "${#documented}" = 64 ] \
      || fail "the record must carry one parseable measured digest for $path"
    [ "$(printf '%s\n' "$documented" | wc -l | tr -d ' ')" = 1 ] \
      || fail "the record must carry exactly one measured digest for $path"
    actual=$(inventory_digest_file "$ROOT/$path") \
      || fail "the current digest could not be observed for $path"
    [ "$documented" = "$actual" ] \
      || fail "the recorded measurement describes different bytes than the current $path"
    measured_any=1
  done
  # An absent measured block must not read as agreement: no digests parsed is
  # could-not-observe, which is not a pass.
  [ "$measured_any" = 1 ] || fail "the record carries no measured digests at all"

  pass "the recorded measurement describes the bytes now present, not an earlier subject"
}

# --- the catalogue fold -----------------------------------------------------

catalogue_json() {  # <path> <case-json>...
  local out=$1
  shift
  printf '%s\n' "$@" | jq -s '{cases: .}' >"$out"
}

test_catalogue_refuses_output_inside_a_linked_worktree_source() {
  local case_dir before after out code
  case_dir=$(make_case catalogue_source_output)
  printf '%s\n' '{"cases": []}' >"$case_dir/catalogue.json"
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/src/evidence" 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "catalogue output inside a linked-worktree source is refused"
  assert_contains "$out" 'output directory is inside the source checkout' \
    "the refusal must name the source containment violation"
  [ "$before" = "$after" ] \
    || fail "catalogue containment refusal must leave the linked-worktree source byte-identical"
  pass "source-custody: catalogue refuses output inside a linked-worktree source"
}

test_catalogue_refuses_output_through_a_symlinked_source_ancestor() {
  local case_dir before after out code
  case_dir=$(make_case catalogue_symlinked_output)
  printf '%s\n' '{"cases": []}' >"$case_dir/catalogue.json"
  ln -s "$case_dir/src" "$case_dir/source-alias"
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/source-alias/evidence" 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "catalogue output through a symlinked source ancestor is refused"
  assert_contains "$out" 'output directory is inside the source checkout' \
    "the catalogue refusal must name the physical source containment violation"
  [ ! -e "$case_dir/src/evidence" ] \
    || fail "catalogue containment refusal must happen before creating output"
  [ "$before" = "$after" ] \
    || fail "catalogue containment refusal must leave the source byte-identical"
  pass "source-custody: catalogue resolves a symlinked output ancestor physically"
}

test_catalogue_protects_the_checkout_when_source_is_a_subdirectory() {
  local case_dir before after out code
  case_dir=$(make_case catalogue_subdirectory_source)
  printf '%s\n' '{"cases": []}' >"$case_dir/catalogue.json"
  mkdir "$case_dir/src/evidence-target"
  ln -s "$case_dir/src/evidence-target" "$case_dir/evidence-link"
  before=$(source_snapshot "$case_dir/src")
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" \
    --source "$case_dir/src/tests" --candidate HEAD --out "$case_dir/evidence-link" 2>&1)
  code=$?
  set -e
  after=$(source_snapshot "$case_dir/src")

  expect_code 2 "$code" "catalogue protects the checkout root for a subdirectory source"
  assert_contains "$out" 'output directory is inside the source checkout' \
    "the catalogue refusal must name checkout-root containment"
  [ -z "$(ls -A "$case_dir/src/evidence-target")" ] \
    || fail "catalogue must refuse an output-leaf symlink before writing through it"
  [ "$before" = "$after" ] \
    || fail "catalogue with a subdirectory source must leave the checkout byte-identical"
  pass "source-custody: catalogue protects the checkout root for a subdirectory source"
}

test_output_outside_the_source_is_accepted() {
  local case_dir out code
  case_dir=$(make_case outside_output)
  catalogue_json "$case_dir/catalogue.json" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"honest", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/honest.sh"]}')"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/evidence" 2>&1)
  code=$?
  set -e

  expect_code 0 "$code" "an output path outside the source remains accepted"
  assert_contains "$out" 'review-mutation-catalogue,PASS,' \
    "an accepted outside output must proceed through the catalogue"
  [ -f "$case_dir/evidence/catalogue.json" ] \
    || fail "an accepted outside output must contain the completed catalogue"
  pass "source-custody: legitimate output outside the source remains accepted"
}

test_one_failing_case_makes_the_catalogue_fail() {
  local case_dir out code
  case_dir=$(make_case catalogue_fail)
  catalogue_json "$case_dir/catalogue.json" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"honest", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/honest.sh"]}')" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"liar", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/liar.sh"]}')"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/cat" 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "one failing case must make the whole catalogue fail"
  assert_contains "$out" 'review-mutation-catalogue,FAIL,' "the fold must classify FAIL"
  [ "$(jq -r '.cases[] | select(.case == "honest") | .result' "$case_dir/cat/catalogue.json")" = PASS ] \
    || fail "the passing case must still be recorded as passing"
  [ "$(jq -r '.cases[] | select(.case == "liar") | .result' "$case_dir/cat/catalogue.json")" = FAIL ] \
    || fail "the failing case must be recorded as failing"
  pass "precedence: one failing case makes the catalogue fail"
}

test_a_failing_case_outranks_an_unobservable_one() {
  local case_dir out code
  case_dir=$(make_case catalogue_precedence)
  catalogue_json "$case_dir/catalogue.json" \
    "$(jq -n --arg t "$TARGET" '{case:"unobservable", path:"tests/honest.sh", target:$t, falsify:"(((", satisfy:")))", probe:["bash","tests/honest.sh"]}')" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"liar", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/liar.sh"]}')"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/cat" 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "an observation gap must never mask a real finding"
  assert_contains "$out" 'review-mutation-catalogue,FAIL,' \
    "a catalogue holding both a failure and a gap must report the failure"
  [ "$(jq -r '.cases[] | select(.case == "unobservable") | .result' "$case_dir/cat/catalogue.json")" \
    = NO_VERIFIER_RAN ] || fail "the unobservable case must still be recorded as unobservable"
  pass "precedence: a failure outranks a could-not-observe in the catalogue fold"
}

test_an_unobservable_case_outranks_a_passing_one() {
  local case_dir out code
  case_dir=$(make_case catalogue_gap)
  catalogue_json "$case_dir/catalogue.json" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"honest", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/honest.sh"]}')" \
    "$(jq -n --arg t "$TARGET" '{case:"unobservable", path:"tests/honest.sh", target:$t, falsify:"(((", satisfy:")))", probe:["bash","tests/honest.sh"]}')"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/cat" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a catalogue with an unobservable case is not a passing catalogue"
  assert_contains "$out" 'review-mutation-catalogue,NO_VERIFIER_RAN,' \
    "a gap must not be folded into a pass"
  pass "precedence: a could-not-observe outranks a pass in the catalogue fold"
}

test_an_empty_catalogue_is_could_not_observe() {
  local case_dir out code
  case_dir=$(make_case catalogue_empty)
  printf '%s\n' '{"cases": []}' >"$case_dir/catalogue.json"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/cat" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "zero findings over an empty universe is not a clean universe"
  assert_contains "$out" 'declares no cases' "the refusal must name the empty catalogue"
  pass "precedence: an empty catalogue is could-not-observe, never clean"
}

test_a_catalogue_with_duplicate_identities_is_refused() {
  local case_dir out code
  case_dir=$(make_case catalogue_duplicate)
  catalogue_json "$case_dir/catalogue.json" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"same", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/honest.sh"]}')" \
    "$(jq -n --arg t "$TARGET" --arg f "$FALSIFY" --arg s "$SATISFY" \
      '{case:"same", path:"tests/honest.sh", target:$t, falsify:$f, satisfy:$s, probe:["bash","tests/liar.sh"]}')"
  set +e
  out=$("$BIN" catalogue --catalogue "$case_dir/catalogue.json" --source "$case_dir/src" \
    --candidate HEAD --out "$case_dir/cat" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "two cases sharing an identity make the fold ambiguous"
  assert_contains "$out" 'duplicate case identities' "the refusal must name the collision"
  pass "a catalogue with duplicate case identities is refused"
}

# --- the landed consumer ----------------------------------------------------

test_fm_verify_transports_the_result() {
  local case_dir out code
  case_dir=$(make_case verify_adapter)
  set +e
  run_prove "$case_dir" liar bash tests/liar.sh >/dev/null 2>&1
  out=$("$VERIFY_BIN" review-mutation "$case_dir/liar" 2>&1)
  code=$?
  set -e
  expect_code 1 "$code" "the wrapper must transport FAIL as FAIL"
  assert_contains "$out" 'review-mutation,FAIL,verifier_reported_failure,' \
    "the wrapper must report the proof owner's result under its own verifier name"

  set +e
  out=$("$VERIFY_BIN" review-mutation "$case_dir/absent-record" 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a record directory that is not there is could-not-observe"
  assert_contains "$out" 'review-mutation,NO_VERIFIER_RAN,' \
    "a missing record must not classify PASS"
  pass "bin/fm-verify.sh transports the proof owner's three-valued result"
}

test_a_symlinked_target_path_is_refused() {
  local case_dir out code
  case_dir=$(make_case symlink_target)
  ln -s tests/honest.sh "$case_dir/primary/link.sh"
  git -C "$case_dir/primary" add -A
  git -C "$case_dir/primary" commit -qm link
  set +e
  out=$("$BIN" prove --case symlink --source "$case_dir/src" \
    --candidate "$(git -C "$case_dir/primary" rev-parse HEAD)" --path link.sh \
    --target "$case_dir/target.bytes" --falsify "$case_dir/falsify.bytes" \
    --satisfy "$case_dir/satisfy.bytes" --out "$case_dir/out" \
    -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "a symlink is not the file whose bytes the case names"
  assert_contains "$out" 'not a regular file' "the refusal must name what it saw"
  pass "a target path that is not a regular file is refused"
}

test_a_missing_execution_substrate_is_could_not_observe() {
  local case_dir out code fake
  case_dir=$(make_case substrate_absent)
  # A build whose substrate is gone must refuse, not fall back to reading the
  # probe's output itself. The whole point is that it has no such fallback.
  fake=$case_dir/bin
  mkdir -p "$fake"
  cp "$BIN" "$fake/fm-review-mutation.sh"
  cp "$ROOT/bin/fm-verify-lib.sh" "$fake/"
  cp "$ROOT/bin/fm-verify.sh" "$fake/"
  set +e
  out=$("$fake/fm-review-mutation.sh" prove --case absent --source "$case_dir/src" \
    --candidate HEAD --path tests/honest.sh --target "$case_dir/target.bytes" \
    --falsify "$case_dir/falsify.bytes" --satisfy "$case_dir/satisfy.bytes" \
    --out "$case_dir/out" -- bash tests/honest.sh 2>&1)
  code=$?
  set -e
  expect_code 2 "$code" "no execution substrate means no observation of execution"
  assert_contains "$out" 'execution substrate is unavailable' \
    "the refusal must name the missing substrate"
  pass "a build with no execution substrate refuses rather than judging output itself"
}

# This proves inventory agreement only and is not evidence that any matrix row was measured.
# The drift control. It proves INVENTORY AGREEMENT ONLY - that the record's
# documented control count and file digests match the suite that is actually
# running - and it is NOT evidence that any matrix row was ever measured. A
# green inventory sitting on top of unmeasured rows is precisely the collapse
# the record's two separate claims exist to prevent.
#
# It counts from the suite's own declared control array, never from a second
# number written down somewhere, and it reports its own success only after it
# has established the thing that success attests to.
test_verification_record_inventory_matches_executed_controls() {
  local record=${FM_REVIEW_MUTATION_RECORD:-$ROOT/docs/verification/review-mutation-proof.md}
  local documented_count executed_count documented path actual

  [ -r "$record" ] || fail "the mutation verification record must be readable"
  documented_count=$(sed -n 's/^inventory_control_count: \([0-9][0-9]*\)$/\1/p' "$record")
  [ -n "$documented_count" ] \
    || fail "the mutation verification record must carry one parseable inventory control count"
  [ "$(printf '%s\n' "$documented_count" | wc -l | tr -d ' ')" = 1 ] \
    || fail "the mutation verification record must carry exactly one inventory control count"
  executed_count=${#FM_CONTROLS[@]}
  [ "$documented_count" = "$executed_count" ] \
    || fail "the documented control count ($documented_count) must equal the suite's declared control count ($executed_count)"

  # The measured subjects, plus the harness that defines the defects. The
  # harness is included deliberately: it is the measuring instrument, and a
  # changed defect catalogue means the recorded matrix rows describe defects
  # that are no longer the ones on disk.
  for path in bin/fm-review-mutation.sh bin/fm-verify.sh \
    tests/fm-review-mutation.test.sh tests/review-mutation-red-matrix.py; do
    documented=$(sed -n "s|^inventory_sha256: $path \([0-9a-f][0-9a-f]*\)$|\\1|p" "$record")
    [ "${#documented}" = 64 ] \
      || fail "the mutation verification record must carry one parseable digest for $path"
    [ "$(printf '%s\n' "$documented" | wc -l | tr -d ' ')" = 1 ] \
      || fail "the mutation verification record must carry exactly one digest for $path"
    actual=$(inventory_digest_file "$ROOT/$path") || fail "the current digest could not be observed for $path"
    [ "$documented" = "$actual" ] \
      || fail "the documented digest must match the current bytes of $path"
  done

  # Reported last, and only now: everything it attests to has been established.
  pass "the verification record inventory agrees with the executed controls"
}

# The declared control set, in order. Naming it once lets a measurement run a
# single control against a defect build, which is what a COMPLETE red matrix
# needs: this suite stops at its first failing control, so a defect that would
# redden several of them would otherwise only ever be seen reddening one.
FM_CONTROLS=(
  test_a_matching_success_line_cannot_establish_that_the_target_ran
  test_the_proof_owners_own_success_literal_cannot_reach_a_verdict
  test_a_target_that_executed_and_passed_is_a_pass
  test_a_target_that_executed_and_failed_is_a_fail
  test_an_unattributable_substitution_is_could_not_observe
  test_a_target_occurring_more_than_once_is_refused
  test_a_target_occurring_zero_times_is_refused
  test_overlapping_occurrences_are_counted_separately
  test_the_identity_substitution_reproduces_the_candidate_tree
  test_a_substitution_identical_to_the_target_is_refused
  test_the_source_is_never_mutated
  test_a_refused_source_is_never_written_to
  test_a_traversing_output_is_refused_without_touching_the_source
  test_prove_refuses_output_through_a_symlinked_source_ancestor
  test_prove_protects_the_checkout_when_source_is_a_subdirectory
  test_the_disposable_clone_shares_no_object_storage
  test_refuses_a_primary_checkout_as_its_source
  test_refuses_to_overwrite_an_existing_record
  test_a_record_whose_mutants_are_gone_is_could_not_observe
  test_an_edited_record_cannot_be_read_into_a_verdict
  test_an_execution_from_the_wrong_variant_is_could_not_observe
  test_preserved_mutation_bytes_are_rederived
  test_a_missing_dimension_outranks_a_clean_fold
  test_a_record_pointing_at_another_path_is_could_not_observe
  test_a_caller_declaration_cannot_change_the_verdict
  test_the_probe_argv_is_recorded_exactly
  test_catalogue_refuses_output_inside_a_linked_worktree_source
  test_catalogue_refuses_output_through_a_symlinked_source_ancestor
  test_catalogue_protects_the_checkout_when_source_is_a_subdirectory
  test_output_outside_the_source_is_accepted
  test_one_failing_case_makes_the_catalogue_fail
  test_a_failing_case_outranks_an_unobservable_one
  test_an_unobservable_case_outranks_a_passing_one
  test_an_empty_catalogue_is_could_not_observe
  test_a_catalogue_with_duplicate_identities_is_refused
  test_fm_verify_transports_the_result
  test_a_symlinked_target_path_is_refused
  test_a_missing_execution_substrate_is_could_not_observe
  test_verification_record_inventory_matches_executed_controls
  test_recorded_measurement_describes_the_current_subject
)

if [ -n "${FM_REVIEW_MUTATION_ONLY:-}" ]; then
  # Refused rather than silently running nothing: a measurement that selects a
  # control which does not exist would report a clean run having observed
  # nothing at all.
  for control in "${FM_CONTROLS[@]}"; do
    [ "$control" = "$FM_REVIEW_MUTATION_ONLY" ] && break
    control=
  done
  [ -n "$control" ] || fail "FM_REVIEW_MUTATION_ONLY names no declared control: $FM_REVIEW_MUTATION_ONLY"
  "$FM_REVIEW_MUTATION_ONLY"
else
  for control in "${FM_CONTROLS[@]}"; do
    "$control"
  done
  fm_test_contract "$(basename "${BASH_SOURCE[0]}")" || exit 1
fi
