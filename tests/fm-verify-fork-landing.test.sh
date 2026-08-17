#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-verify-fork-landing) \
  || fail "could not create a temp root"
FIXTURE_BIN="$TMP_ROOT/bin"
mkdir -p "$FIXTURE_BIN"
cp "$ROOT/bin/fm-verify-fork-landing.sh" "$FIXTURE_BIN/"
cp "$ROOT/bin/fm-retrieval-lib.sh" "$FIXTURE_BIN/"

cat > "$FIXTURE_BIN/fm-control-read.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_TEST_RETRIEVAL_RECORD"
exit "${FM_TEST_RETRIEVAL_STATUS:-0}"
SH

cat > "$FIXTURE_BIN/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FIXTURE_BIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'summary: "1 passed, 1 total"\n'
SH

chmod +x "$FIXTURE_BIN/fm-control-read.sh" "$FIXTURE_BIN/gh" \
  "$FIXTURE_BIN/gh-axi"

FIELDS='source,retrieval,reason,pages,records,duplicates,reported,candidates,matches,quoted_only,prefix_rejected,claim,conclusion,selected,evidence_ref'
FM_TEST_IDENTITY_CONTRACT=1
OUT=
RC=0

run_verifier() {  # <record>
  RC=0
  OUT=$(PATH="$FIXTURE_BIN:$PATH" FM_TEST_RETRIEVAL_RECORD=$1 \
    "$FIXTURE_BIN/fm-verify-fork-landing.sh" \
    --event-key feature/test 2>&1) || RC=$?
}

test_v2_present_reaches_the_selected_pull_request() {
  local record
  record="retrieval[2]{$FIELDS}:
  endpoint:pulls,complete,enumerated,1,1,0,unknown,1,1,0,0,latest,PRESENT,42,evidence"
  run_verifier "$record"
  expect_code 0 "$RC" "a v2 PRESENT record must verify"
  assert_contains "$OUT" "fork pull request 42 exists" \
    "the v2 selected pull request was not consumed"
  pass "fork landing consumes a v2 PRESENT retrieval record"
}

test_v2_ambiguity_remains_unavailable() {
  local record
  record="retrieval[2]{$FIELDS}:
  endpoint:pulls,complete,enumerated,1,2,0,unknown,2,2,0,0,latest,PRESENT,42,evidence"
  run_verifier "$record"
  expect_code 2 "$RC" "a v2 ambiguous subject must remain unavailable"
  assert_contains "$OUT" "2 open pull requests" \
    "the v2 ambiguity count was not preserved"
  assert_contains "$OUT" "subject is ambiguous" \
    "the v2 ambiguity was not reported as unavailable"
  pass "fork landing keeps v2 ambiguous retrieval unavailable"
}

test_v1_present_remains_accepted() {
  local record
  record="retrieval[1]{$FIELDS}:
  endpoint:labels=%2C,complete,enumerated,1,1,0,unknown,1,1,0,0,latest,PRESENT,43,evidence=%25"
  run_verifier "$record"
  expect_code 0 "$RC" "a legacy v1 PRESENT record must remain accepted"
  assert_contains "$OUT" "fork pull request 43 exists" \
    "the v1 selected pull request was not consumed"
  pass "fork landing retains v1 retrieval compatibility"
}

test_v2_present_reaches_the_selected_pull_request
test_v2_ambiguity_remains_unavailable
test_v1_present_remains_accepted

fm_test_contract "$0"
