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
  '  echo "FM_RECURRENCE_ASSERTION_EXECUTED id=case-0 result=PASS"; exit 0' 'fi' \
  'echo "FM_RECURRENCE_ASSERTION_EXECUTED id=case-0 result=FAIL failure=expected protected identity"' \
  'exit 1' > "$origin/tests/target.test.sh"
cp "$ROOT/tests/lib.sh" "$origin/tests/lib.sh"
git -C "$origin" add .
git -C "$origin" commit -qm fixture
git -C "$origin" worktree add -q --detach "$candidate" HEAD
sha=$(git -C "$candidate" rev-parse HEAD)
spec=$TMP_ROOT/spec.json
jq -n '[range(0;38) | {
  case:("case-" + tostring), finding:("finding-" + tostring), file:"bin/control.sh",
  location:"protection", assertion_command:["bash","tests/target.test.sh"], target_assertion_id:"case-0",
  expected_negative_failure:"expected protected identity", search:"PROTECTED=true",
  replacement:"PROTECTED=false"}]' > "$spec"

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
jq -e '.[0].candidate_commit == $sha and (.[0].mutation | contains("PROTECTED=false"))' --arg sha "$sha" "$out" >/dev/null \
  || fail "evidence omitted the measured source identity or exact patch"
pass "runner records the exact source SHA and applied patch"
[ -z "$(git -C "$candidate" status --porcelain=v1 --untracked-files=all)" ] || fail "runner dirtied the authoritative candidate"
pass "runner resets its disposable state without dirtying the candidate"

jq '.[0].search="ABSENT-PROTECTION"' "$spec" > "$TMP_ROOT/zero.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/zero.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/zero.out" 2>&1; then
  fail "zero-match mutation produced evidence"
fi
grep -Fq 'mutation target matched 0 times' "$TMP_ROOT/zero.out" || fail "zero-match refusal was not classified"
[ "$before" = "$(git -C "$candidate" hash-object bin/control.sh)" ] || fail "zero-match run mutated the candidate"
pass "runner refuses zero-match mutations without touching the candidate"

grep -Fqx "$sha" < <(git -C "$candidate" rev-parse HEAD) || fail "fixture source SHA changed"
pass "runner establishes the source SHA at runtime"

jq '.[0].expected_negative_failure="unrelated identity"' "$spec" > "$TMP_ROOT/unrelated.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/unrelated.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/unrelated.out" 2>&1; then
  fail "unrelated failure identity produced evidence"
fi
grep -Fq 'unexpected identity' "$TMP_ROOT/unrelated.out" || fail "unrelated failure was not classified"
pass "runner rejects a red with the wrong failure identity"
[ ! -e "$out" ] || rm -f "$out"
jq '.[0].assertion_command=["command-that-does-not-exist"]' "$spec" > "$TMP_ROOT/setup.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/setup.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/setup.out" 2>&1; then
  fail "setup failure produced evidence"
fi
[ ! -e "$out" ] || fail "setup failure published evidence"
grep -Fq 'baseline assertion did not pass' "$TMP_ROOT/setup.out" || fail "setup failure was classified as an assertion"
pass "runner distinguishes setup failure and withholds evidence"

jq '.[0].file="../outside"' "$spec" > "$TMP_ROOT/escape.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/escape.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/escape.out" 2>&1; then
  fail "out-of-clone protection produced evidence"
fi
grep -Fq 'outside the clone' "$TMP_ROOT/escape.out" || fail "out-of-clone protection was not classified"
pass "runner confines every mutation to its disposable clone"

if FM_REVIEW_RECURRENCE_ROOT=$origin FM_REVIEW_RECURRENCE_SPEC=$spec \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/primary.out" 2>&1; then
  fail "primary checkout was accepted"
fi
grep -Fq 'refuses the primary checkout' "$TMP_ROOT/primary.out" || fail "unsafe checkout refusal was not classified"
pass "runner refuses an unsafe authoritative checkout"

printf 'dirty\n' > "$candidate/dirty"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$spec \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/dirty.out" 2>&1; then
  fail "dirty candidate was accepted"
fi
grep -Fq 'requires a clean candidate' "$TMP_ROOT/dirty.out" || fail "dirty start refusal was not classified"
rm "$candidate/dirty"
pass "runner refuses a dirty candidate"

jq '.[0].replacement="PROTECTED=true"' "$spec" > "$TMP_ROOT/unflipped.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/unflipped.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/unflipped.out" 2>&1; then
  fail "unapplied mutation produced evidence"
fi
grep -Fq 'did not alter' "$TMP_ROOT/unflipped.out" || fail "unapplied mutation was not classified"
pass "runner refuses an unapplied mutation"

jq '.[0].assertion_command=["sh","-c","echo FM_RECURRENCE_ASSERTION_EXECUTED id=case-0 result=FAIL failure=expected protected identity; exit 1"]' "$spec" > "$TMP_ROOT/supplied.json"
if FM_REVIEW_RECURRENCE_ROOT=$candidate FM_REVIEW_RECURRENCE_SPEC=$TMP_ROOT/supplied.json \
  FM_REVIEW_RECURRENCE_OUT=$out FM_REVIEW_RECURRENCE_TMP=$TMP_ROOT/runner-tmp \
  "$ROOT/bin/fm-review-recurrence.sh" --case case-0 > "$TMP_ROOT/supplied.out" 2>&1; then
  fail "supplied failure strings fabricated baseline evidence"
fi
grep -Fq 'baseline assertion did not pass' "$TMP_ROOT/supplied.out" || fail "supplied strings bypassed observation"
pass "supplied strings cannot fabricate observed evidence"
