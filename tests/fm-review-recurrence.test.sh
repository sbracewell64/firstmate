#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-review-recurrence) || fail "could not create fixture root"
origin=$TMP_ROOT/origin
candidate=$TMP_ROOT/candidate
mkdir -p "$origin"
git -C "$origin" init -q
git -C "$origin" config user.name test
git -C "$origin" config user.email test@example.invalid
mkdir -p "$origin/bin" "$origin/tests" "$origin/docs/verification"
printf 'PROTECTED=true\n' > "$origin/bin/control.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"' \
  'if grep -Fq "PROTECTED=true" "$(dirname "${BASH_SOURCE[0]}")/../bin/control.sh"; then' \
  '  pass "$FM_RECURRENCE_TARGET_ASSERTION"' 'fi' \
  'fail "$FM_RECURRENCE_TARGET_ASSERTION: expected protected identity"' > "$origin/tests/target.test.sh"
cp "$ROOT/tests/lib.sh" "$origin/tests/lib.sh"
git -C "$origin" add .
git -C "$origin" commit -qm fixture
git -C "$origin" worktree add -q --detach "$candidate" HEAD
sha=$(git -C "$candidate" rev-parse HEAD)
spec=$TMP_ROOT/spec.json
jq -n --arg sha "$sha" '[range(0;29) | {
  case:("case-" + tostring), finding:("finding-" + tostring), file:"bin/control.sh",
  location:"protection", suite:"tests/target.test.sh", target_assertion_id:("case-" + tostring),
  expected_negative_failure:"expected protected identity", search:"PROTECTED=true",
  replacement:"PROTECTED=false", candidate_sha:$sha}]' > "$spec"

before=$(git -C "$candidate" hash-object bin/control.sh)
out=$TMP_ROOT/evidence.json
FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$spec \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 >/dev/null
after=$(git -C "$candidate" hash-object bin/control.sh)
[ "$before" = "$after" ] || fail "runner mutated the authoritative candidate"
jq -e 'length == 1 and .[0].mutation_verified and .[0].restored and .[0].confirm_pass and .[0].failure_matches_expected' "$out" >/dev/null \
  || fail "runner did not record the complete isolated observation"
pass "runner isolates mutations and records a target-bound failure"

jq '.[0].search="ABSENT-PROTECTION"' "$spec" > "$TMP_ROOT/zero.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/zero.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/zero.out" 2>&1; then
  fail "zero-match mutation produced evidence"
fi
grep -Fq 'mutation target matched 0 times' "$TMP_ROOT/zero.out" || fail "zero-match refusal was not classified"
[ "$before" = "$(git -C "$candidate" hash-object bin/control.sh)" ] || fail "zero-match run mutated the candidate"
pass "runner refuses zero-match mutations without touching the candidate"

jq '.[0].candidate_sha="0000000000000000000000000000000000000000"' "$spec" > "$TMP_ROOT/base.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/base.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/base.out" 2>&1; then
  fail "base-SHA mismatch produced evidence"
fi
grep -Fq 'instead of' "$TMP_ROOT/base.out" || fail "base-SHA mismatch was not classified"
pass "runner refuses a mutation specification pinned elsewhere"

jq '.[0].expected_negative_failure="unrelated identity"' "$spec" > "$TMP_ROOT/unrelated.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/unrelated.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/unrelated.out" 2>&1; then
  fail "unrelated failure identity produced evidence"
fi
grep -Fq 'unexpected identity' "$TMP_ROOT/unrelated.out" || fail "unrelated failure was not classified"
pass "runner rejects a red with the wrong failure identity"

jq '.[0].file="../outside"' "$spec" > "$TMP_ROOT/escape.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/escape.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/escape.out" 2>&1; then
  fail "out-of-clone protection produced evidence"
fi
grep -Fq 'outside the clone' "$TMP_ROOT/escape.out" || fail "out-of-clone protection was not classified"
pass "runner confines every mutation to its disposable clone"
