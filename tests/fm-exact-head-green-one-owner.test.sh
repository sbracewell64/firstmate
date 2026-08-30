#!/usr/bin/env bash
# Controls for the ONE OWNER of "is this exact candidate head sufficiently
# validated under the currently applicable required gate set?"
#
# THE MEASURED INCIDENT. Until 2026-08-18 two independent classifiers answered
# that question. bin/fm-verify-lib.sh's FM_VERIFY_CHECK_ROLLUP_EXPR classified
# gh's flattened `--json statusCheckRollup` with no attempt reduction, so any
# attempt that ever failed against a head made the head failing forever.
# bin/fm-pr-merge.sh's PR_VERIFY_REDUCE classified a GraphQL rollup that reduced
# repeated executions to the current attempt and reconciled the members against
# totalCount. Driven with one head, one check named CI, an older FAILURE and a
# newer SUCCESS, the first said "failing" and the second said green.
#
# The fixture in test_pre_consolidation_owners_disagreed is that exact subject,
# reproduced from the audit's captured evidence. It is the RED CONTROL: it drives
# the pre-consolidation expression, kept verbatim below, and asserts it still
# disagrees. A regression test that only went green after the fix would prove
# nothing about the defect it names.
#
# What each case here holds:
#   1. the two pre-consolidation owners disagreed on one subject (red control);
#   2. after consolidation both paths through the one owner agree on it;
#   3. only the canonical owner can authorize progress - a caller-supplied
#      verdict from a competing derivation is refused at the consumer, and the
#      pre-hardening consumer is shown accepting it (red control);
#   4. the two consumers of the fold - the verifier and the merge gate - are
#      driven separately against one forge response across a matrix of shapes
#      and never land on opposite sides of the line, which is the one-owner
#      property measured rather than inspected;
#   5. non-vacuity: a genuinely green head still merges, and a red head, an
#      empty check set, and each could-not-observe head still refuse, each in
#      its own words rather than one shared "not green".
#
# Every case reaches its verdict by RUNNING something. None of them reads the
# implementation's own bytes: a test that greps a script for the absence of a
# string proves only that the string is absent, and the property here is what
# the scripts do.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-verify-lib.sh
. "$ROOT/bin/fm-verify-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP=$(fm_test_tmproot fm-one-owner)
HEAD=deadbeefcafefeed0000000000000000deadbeef

# The rule bin/fm-verify-lib.sh carried before the consolidation, verbatim. It is
# here so the divergence can be re-executed rather than described.
# shellcheck disable=SC2016  # a jq program: the $-names must reach jq unexpanded
PRE_CONSOLIDATION_EXPR='
  (.statusCheckRollup // []) as $c
  | if ($c|length) == 0 then "none"
    elif any($c[]; (.conclusion // .state // "") as $s | ($s=="FAILURE" or $s=="STARTUP_FAILURE" or $s=="ERROR")) then "failing"
    elif any($c[]; ((.status // "") != "COMPLETED") and ((.state // "") != "SUCCESS")) then "pending"
    elif ($c|length) >= 100 then "truncated"
    elif all($c[]; (.conclusion // .state // "") == "SUCCESS") then "passing"
    else "inconclusive" end'

# THE SUBJECT BOTH OWNERS WERE DRIVEN WITH, in each source's own shape: one head,
# one check named CI, an older FAILURE superseded by a newer SUCCESS. This is the
# shape PR #116 was observed to have - two attempts at "PR must be raised via
# no-mistakes" - with the verdicts arranged as a re-run that fixed the check.
DIVERGENCE_FLAT='{"statusCheckRollup":[
 {"__typename":"CheckRun","name":"CI","status":"COMPLETED","conclusion":"FAILURE","startedAt":"2026-08-18T05:10:00Z","workflowName":"CI"},
 {"__typename":"CheckRun","name":"CI","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-08-18T05:20:00Z","workflowName":"CI"}]}'

divergence_graphql() {  # [head] [rollup-head]
  local head=${1:-$HEAD} rollup=${2:-}
  [ -n "$rollup" ] || rollup=$head
  jq -nc --arg head "$head" --arg rollup "$rollup" '
    {data: {repository: {pullRequest: {
      headRefOid: $head, mergeable: "MERGEABLE", reviewDecision: "APPROVED",
      commits: {nodes: [{commit: {oid: $rollup, statusCheckRollup: {contexts: {
        totalCount: 2,
        nodes: [
          {__typename: "CheckRun", databaseId: 1, name: "CI", status: "COMPLETED",
           conclusion: "FAILURE", startedAt: "2026-08-18T05:10:00Z",
           checkSuite: {workflowRun: {workflow: {name: "CI"}}}},
          {__typename: "CheckRun", databaseId: 2, name: "CI", status: "COMPLETED",
           conclusion: "SUCCESS", startedAt: "2026-08-18T05:20:00Z",
           checkSuite: {workflowRun: {workflow: {name: "CI"}}}}]}}}}]}}}}}'
}

fold_flat() { printf '%s' "$1" | jq -r "$FM_VERIFY_CHECK_ROLLUP_EXPR"; }
fold_pre_consolidation() { printf '%s' "$1" | jq -r "$PRE_CONSOLIDATION_EXPR"; }
fold_graphql() {
  printf '%s' "$1" | jq -r "$FM_VERIFY_ROLLUP_NORMALIZE_GRAPHQL | ($FM_VERIFY_ROLLUP_FOLD)"
}
counts_graphql() {
  printf '%s' "$1" | jq -r "$FM_VERIFY_ROLLUP_NORMALIZE_GRAPHQL | ($FM_VERIFY_ROLLUP_COUNTS)"
}

# --- 1. the red control: the two old owners, on one subject ------------------

test_pre_consolidation_owners_disagreed() {
  local old new
  old=$(fold_pre_consolidation "$DIVERGENCE_FLAT")
  new=$(fold_graphql "$(divergence_graphql)")
  [ "$old" = failing ] \
    || fail "red control is not red: the pre-consolidation rule answered '$old', not 'failing', so this fixture no longer reproduces the divergence it exists to reproduce"
  [ "$new" = passing ] \
    || fail "red control is not red: the merge-side reduction answered '$new', not 'passing', on the same subject"
  pass "the pre-consolidation owners returned opposite verdicts on one head, so the fixture still reproduces the measured divergence"
}

# --- 2. after consolidation, one answer ---------------------------------------

test_one_owner_agrees_on_the_divergent_subject() {
  local flat graphql lines
  flat=$(fold_flat "$DIVERGENCE_FLAT")
  graphql=$(fold_graphql "$(divergence_graphql)")
  [ "$flat" = "$graphql" ] \
    || fail "the two sources still disagree on the divergent subject: flat=$flat graphql=$graphql"
  [ "$graphql" = passing ] \
    || fail "the one owner answered '$graphql' on a head whose only check's current attempt succeeded"
  lines=$(counts_graphql "$(divergence_graphql)")
  fm_verify_rollup_classify "$lines" \
    || fail "the classifier refused a head whose current attempt succeeded: $FM_VERIFY_ROLLUP_LABEL/$FM_VERIFY_ROLLUP_REASON"
  [ "$FM_VERIFY_ROLLUP_CHECKS" = 1 ] \
    || fail "two attempts at one check reduced to $FM_VERIFY_ROLLUP_CHECKS checks, not 1"
  pass "both sources fold through one owner and agree on the subject that split the two old ones"
}

# A superseded FAILURE must not become invisible: reduction resolves which
# attempt speaks, it does not forgive the one that does.
test_reduction_does_not_forgive_a_current_failure() {
  local reversed
  reversed=$(printf '%s' "$DIVERGENCE_FLAT" \
    | jq -c '.statusCheckRollup |= [.[1] + {conclusion: "SUCCESS"}, .[0] + {conclusion: "FAILURE", startedAt: "2026-08-18T05:30:00Z"}]')
  [ "$(fold_flat "$reversed")" = failing ] \
    || fail "a check whose NEWEST attempt failed must be failing, not resolved away by reduction"
  pass "reduction picks the current attempt and never excuses its verdict"
}

# --- 3. only the canonical owner may authorize --------------------------------

# bin/fm-slot-reservation.sh admits a trunk-repair reservation from a
# bin/fm-verify.sh record the caller hands it. The record shape is public, so a
# caller can write one; what it must not be able to do is name its OWN
# classification of this question as the source.
write_verdict_record() {  # <file> <verifier> <result>
  printf 'verify[1]{verifier,result,reason,evidence_ref}:\n  %s,%s,verifier_reported_failure,/tmp/evidence.log\n' \
    "$2" "$3" > "$1"
}

test_competing_derivation_verdict_is_refused_at_the_consumer() {
  local dir project out rc=0
  dir=$TMP/competing
  mkdir -p "$dir"
  project=$dir/project
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m init

  # RED CONTROL: the pre-hardening admission read the result field and nothing
  # else, so this record - naming a classifier that is not a declared verifier -
  # would have been admitted. Re-executed here so the control is a measurement.
  write_verdict_record "$dir/rogue.txt" my-own-rollup-check FAIL
  local row result verifier
  row=$(grep -A1 '^verify\[1\]' "$dir/rogue.txt" | sed -n '2p')
  row=${row#"${row%%[![:space:]]*}"}
  verifier=$(printf '%s' "$row" | cut -d, -f1)
  result=$(printf '%s' "$row" | cut -d, -f2)
  [ "$result" = FAIL ] \
    || fail "red control is not red: the pre-hardening read did not extract a FAIL from the rogue record"
  [ "$verifier" = my-own-rollup-check ] \
    || fail "red control is not red: the rogue record does not name a competing derivation"
  "$ROOT/bin/fm-verify.sh" --list | grep -qx "$verifier" \
    && fail "red control is not usable: '$verifier' is a declared verifier, so it is not a competing derivation"

  out=$("$ROOT/bin/fm-slot-reservation.sh" open trunk-red-repair \
    --project "$project" --verdict "$dir/rogue.txt" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "a verdict from a competing derivation opened a slot reservation: $out"
  assert_contains "$out" 'bin/fm-verify.sh does not declare' \
    "the refusal must name the registry the verdict failed"
  pass "a caller-supplied verdict from a second derivation of this question is refused at the consumer"
}

# A substring of a declared name is not a declared name, and neither is the
# empty string. Both are shapes a membership test written with the wrong
# delimiters would admit.
test_a_near_miss_verifier_name_is_not_the_owner() {
  local dir project out rc name
  dir=$TMP/nearmiss
  mkdir -p "$dir"
  project=$dir/project
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m init
  for name in pr-check pr-checks-mine '' 'pr checks'; do
    write_verdict_record "$dir/rogue.txt" "$name" FAIL
    rc=0
    out=$("$ROOT/bin/fm-slot-reservation.sh" open trunk-red-repair \
      --project "$project" --verdict "$dir/rogue.txt" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] \
      || fail "verifier name '$name' opened a slot reservation: $out"
  done
  pass "a name that merely resembles a declared verifier, or names none at all, is refused"
}

test_the_declared_owners_verdict_is_still_admitted() {
  local dir project out rc=0
  dir=$TMP/declared
  mkdir -p "$dir"
  project=$dir/project
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m init
  write_verdict_record "$dir/real.txt" pr-checks FAIL
  out=$("$ROOT/bin/fm-slot-reservation.sh" open trunk-red-repair \
    --project "$project" --verdict "$dir/real.txt" 2>&1) || rc=$?
  expect_code 0 "$rc" "the declared owner's own FAIL record must still admit a reservation: $out"
  assert_contains "$out" 'held' "an admitted reservation must read back as held"
  pass "the hardening refuses a competing derivation without refusing the owner, so it is not vacuous"
}

# --- 4. two consumers, one answer ---------------------------------------------

# The one-owner property, measured rather than inspected: bin/fm-verify.sh
# pr-checks and bin/fm-pr-merge.sh are driven against the SAME forge response and
# must always reach the same side of the line. A second derivation anywhere in
# either path shows up here as a shape they answer differently, which is exactly
# how the original defect would have been caught.
#
# Neither consumer's source is read from the other: each makes its own real call
# through its own real query, and the fake forge answers both by evaluating
# whichever -q program it was handed against one fixture file.
make_consumer_case() {  # <name> <members-json> <total> <oid> -> case dir
  local name=$1 members=$2 total=$3 oid=$4 dir fakebin
  dir=$TMP/consumers/$name
  fakebin=$dir/fakebin
  mkdir -p "$dir/state" "$fakebin"
  fm_write_meta "$dir/state/task-x1.meta" \
    "window=fm-task-x1" "worktree=$dir/wt" "project=$dir/project" \
    "kind=ship" "mode=no-mistakes"
  jq -n --argjson members "$members" --argjson total "$total" \
    --arg head "$HEAD" --arg oid "$oid" '
    {data: {repository: {pullRequest: {
      headRefOid: $head, mergeable: "MERGEABLE", reviewDecision: "APPROVED",
      author: {login: "maker"},
      reviews: {totalCount: 1, nodes: [{state: "APPROVED", author: {login: "reviewer"}, commit: {oid: $head}}]},
      commits: {totalCount: 1, nodes: [{commit: {oid: $oid,
        author: {user: {login: "maker"}}, committer: {user: {login: "maker"}},
        statusCheckRollup: {contexts: {
        totalCount: $total, nodes: $members}}}}]}}}}}' > "$dir/pr.json"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
query=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -q|--jq) query=${2:-}; shift; [ "$#" -gt 0 ] && shift ;;
    *) shift ;;
  esac
done
jq -r "$query" "$FM_TEST_FIXTURE"
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/gh-axi"
  : > "$dir/gh-axi.log"
  printf '%s\n' "$dir"
}

# 0 when this consumer says the head may proceed, 1 when it refuses.
verify_says_green() {  # <case-dir>
  FM_TEST_FIXTURE="$1/pr.json" PATH="$1/fakebin:$PATH" \
    "$ROOT/bin/fm-verify.sh" pr-checks https://github.com/example/repo/pull/1 \
    >/dev/null 2>&1
}

merge_says_green() {  # <case-dir>
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$1/state" \
  FM_TEST_FIXTURE="$1/pr.json" FM_TEST_GH_AXI_LOG="$1/gh-axi.log" \
  PATH="$1/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-merge.sh" task-x1 https://github.com/example/repo/pull/1 \
    >/dev/null 2>&1
}

test_both_consumers_return_one_answer_for_one_response() {
  local dir name members total oid want v m
  local run=1 refused=0 merged=0
  while IFS='|' read -r name members total oid want; do
    [ -n "$name" ] || continue
    [ "$oid" != same ] || oid=$HEAD
    dir=$(make_consumer_case "$name" "$members" "$total" "$oid")
    v=0; verify_says_green "$dir" || v=$?
    m=0; merge_says_green "$dir" || m=$?
    if [ "$want" = green ]; then
      [ "$v" -eq 0 ] || fail "$name: the verifier refused a head both consumers must accept"
      [ "$m" -eq 0 ] || fail "$name: the merge gate refused a head both consumers must accept"
      grep -q 'pr merge' "$dir/gh-axi.log" \
        || fail "$name: the merge gate exited 0 without merging"
      merged=$((merged + 1))
    else
      [ "$v" -ne 0 ] || fail "$name: the verifier accepted a head both consumers must refuse"
      [ "$m" -ne 0 ] || fail "$name: the merge gate accepted a head both consumers must refuse"
      grep -q 'pr merge' "$dir/gh-axi.log" \
        && fail "$name: a refused head was merged anyway"
      refused=$((refused + 1))
    fi
    run=$((run + 1))
  done <<EOF
green|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]|1|same|green
red|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"FAILURE"}]|1|same|green-not
empty|[]|0|same|green-not
running|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"IN_PROGRESS","conclusion":null}]|1|same|green-not
cancelled|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"CANCELLED"}]|1|same|green-not
timed-out|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"TIMED_OUT"}]|1|same|green-not
rerun-fixed|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","databaseId":2,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]|2|same|green
rerun-broke|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","databaseId":2,"name":"CI","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]|2|same|green-not
unread-members|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]|9|same|green-not
another-commit|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]|1|1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c|green-not
EOF
  # Positive executed counts, so a loop that silently ran nothing cannot report
  # agreement it never observed.
  [ "$merged" -ge 2 ] \
    || fail "only $merged shapes reached a merge: this control would pass on a gate that refuses everything"
  [ "$refused" -ge 7 ] \
    || fail "only $refused shapes were refused: too few to establish agreement"
  pass "the verifier and the merge gate agreed on all $((merged + refused)) shapes ($merged green, $refused refused), driven separately against one response"
}

# The authoritative source carries the commit its results belong to; the
# flattened one does not. A consumer reading the flattened shape cannot see a
# superseded head at all, so this is the behavior that says which source
# pr-checks actually read.
test_pr_checks_reads_the_source_that_binds_evidence_to_a_head() {
  local dir members rc=0
  members='[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]'
  # RED CONTROL: on the same members, the flattened fold says passing, because
  # nothing in that shape names a commit to disagree with.
  [ "$(printf '{"statusCheckRollup":%s}' "$members" | jq -r "$FM_VERIFY_CHECK_ROLLUP_EXPR")" = passing ] \
    || fail "red control is not red: the flattened source must read these members as passing"
  dir=$(make_consumer_case bound-source "$members" 1 1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c)
  verify_says_green "$dir" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "pr-checks accepted a green rollup belonging to another commit, so it is reading the source that cannot see the difference"
  pass "pr-checks refuses evidence bound to a superseded commit, which only the authoritative source can report"
}

# --- 5. non-vacuity, and three distinguishable refusals ----------------------

# The classifier's answer, its reason, and the exit status it hands a caller that
# reads nothing else. Each shape gets its own row, because the whole point of the
# type is that these do not collapse into one another.
test_each_condition_reaches_its_own_answer() {
  local json label reason rc
  while IFS='|' read -r name members total expect_label expect_reason expect_rc; do
    [ -n "$name" ] || continue
    json=$(jq -nc --argjson members "$members" --argjson total "$total" --arg head "$HEAD" '
      {data: {repository: {pullRequest: {
        headRefOid: $head, mergeable: "MERGEABLE", reviewDecision: "APPROVED",
        commits: {nodes: [{commit: {oid: $head, statusCheckRollup: {contexts: {
          totalCount: $total, nodes: $members}}}}]}}}}}')
    rc=0
    fm_verify_rollup_classify "$(counts_graphql "$json")" || rc=$?
    label=$FM_VERIFY_ROLLUP_LABEL
    reason=$FM_VERIFY_ROLLUP_REASON
    [ "$label" = "$expect_label" ] \
      || fail "$name: expected label $expect_label, got $label"
    [ "$reason" = "$expect_reason" ] \
      || fail "$name: expected reason $expect_reason, got $reason"
    expect_code "$expect_rc" "$rc" "$name: three-valued exit status"
  done <<'EOF'
green|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]|1|passing|verified|0
red|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"FAILURE"}]|1|failing|checks_failed|1
empty|[]|0|none|empty_set|2
still-running|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"IN_PROGRESS","conclusion":null}]|1|pending|checks_pending|2
no-verdict|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"CANCELLED"}]|1|inconclusive|no_verdict|2
members-unread|[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]|7|truncated|members_unread|2
order-unestablished|[{"__typename":"CheckRun","databaseId":null,"name":"CI","status":"COMPLETED","conclusion":"FAILURE","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}},{"__typename":"CheckRun","databaseId":null,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS","checkSuite":{"workflowRun":{"workflow":{"name":"CI"}}}}]|2|truncated|order_undecidable|2
EOF
  pass "green, red, the empty set, and each could-not-observe reach their own label, reason, and exit status"
}

# The empty check set read as green is one of the three measured incidents this
# substrate exists for. It stays a refusal, and it stays its OWN refusal.
test_empty_check_set_is_never_green() {
  local json rc=0
  json=$(jq -nc --arg head "$HEAD" '
    {data: {repository: {pullRequest: {
      headRefOid: $head, mergeable: "MERGEABLE", reviewDecision: "APPROVED",
      commits: {nodes: [{commit: {oid: $head,
        statusCheckRollup: {contexts: {totalCount: 0, nodes: []}}}}]}}}}}')
  fm_verify_rollup_classify "$(counts_graphql "$json")" || rc=$?
  expect_code 2 "$rc" "an empty check set must not exit 0"
  [ "$FM_VERIFY_ROLLUP_LABEL" = none ] \
    || fail "an empty check set must be 'none', got '$FM_VERIFY_ROLLUP_LABEL'"
  [ "$FM_VERIFY_ROLLUP_LABEL" != passing ] \
    || fail "the measured incident reproduced: an empty check set read as green"
  pass "an empty check set is its own refusal and is never read as green"
}

# Evidence GitHub attached to another commit is not this head's evidence, so it
# is a could-not-observe about this head whatever it says about that one.
test_evidence_about_another_commit_is_not_this_heads_evidence() {
  local other json rc=0
  other=cafe0000cafe0000cafe0000cafe0000cafe0000
  json=$(divergence_graphql "$HEAD" "$other")
  fm_verify_rollup_classify "$(counts_graphql "$json")" || rc=$?
  expect_code 2 "$rc" "check results for another commit must not exit 0"
  [ "$FM_VERIFY_ROLLUP_LABEL" = unreadable ] \
    || fail "results for another commit must be unreadable about this head, got '$FM_VERIFY_ROLLUP_LABEL'"
  [ "$FM_VERIFY_ROLLUP_REASON" = subject_mismatch ] \
    || fail "the reason must name the subject, got '$FM_VERIFY_ROLLUP_REASON'"
  pass "a green rollup belonging to a superseded commit is could-not-observe about the head asked about"
}

# The three-valued semantics are the library's own and must survive the new
# boundary: a caller reading only the exit status still cannot turn a
# could-not-observe into a pass or a failure.
# The narrower source reaching the authoritative consumer is a wiring defect, not
# a head state, and it must not arrive wearing a head state's reason.
test_the_narrower_source_cannot_answer_for_a_head() {
  local rc=0 lines
  lines=$(printf '{"statusCheckRollup":[{"__typename":"CheckRun","databaseId":1,"name":"CI","status":"COMPLETED","conclusion":"SUCCESS"}]}' \
    | jq -r "($FM_VERIFY_ROLLUP_NORMALIZE_FLAT) | ($FM_VERIFY_ROLLUP_COUNTS)")
  fm_verify_rollup_classify "$lines" || rc=$?
  expect_code 2 "$rc" "a rollup with no commit to bind to must not exit 0"
  [ "$FM_VERIFY_ROLLUP_LABEL" = unreadable ] \
    || fail "the narrower source must not answer for a head, got '$FM_VERIFY_ROLLUP_LABEL'"
  [ "$FM_VERIFY_ROLLUP_REASON" = source_unbound ] \
    || fail "an unbound source is its own reason, not a head state's, got '$FM_VERIFY_ROLLUP_REASON'"
  pass "a green flattened rollup handed to the authoritative consumer is refused as an unbound source, not read as a green head"
}

test_three_values_survive_the_new_boundary() {
  local rc=0
  fm_verify_rollup_classify "" || rc=$?
  expect_code 2 "$rc" "an empty response must be could-not-observe"
  [ "$FM_VERIFY_ROLLUP_LABEL" = unreadable ] \
    || fail "an empty response must be unreadable, got '$FM_VERIFY_ROLLUP_LABEL'"
  rc=0
  fm_verify_rollup_classify 'label=passing
subject=bound
head=deadbeef
evidence_head=deadbeef
members=3
reported=3
checks=3
unsuccessful=1
failing=0
pending=0
inconclusive=0
undecidable=0' || rc=$?
  expect_code 2 "$rc" "counts that do not reconcile must be could-not-observe, not resolved either way"
  [ "$FM_VERIFY_ROLLUP_REASON" = response_unreadable ] \
    || fail "an unreconciled response must say so, got '$FM_VERIFY_ROLLUP_REASON'"
  pass "an unreadable or unreconciled response is could-not-observe at the new boundary, never flattened into a verdict"
}

# --- the calibration evidence both headers must keep (audit section 16) ------

test_calibration_incidents_survive_the_move() {
  local help out rc=0 big
  # The three measured incidents are read from the wrapper's own help output,
  # which is the surface a reader actually meets, rather than from its source.
  help=$("$ROOT/bin/fm-verify.sh" --help 2>&1) \
    || fail "the verifier's help must be readable"
  assert_contains "$help" 'empty GitHub check-run set read as green' \
    "the empty-check-set incident must survive in what the wrapper tells a reader"
  assert_contains "$help" 'Target closed' \
    "the chrome-devtools-axi protocol-error incident must survive in what the wrapper tells a reader"
  assert_contains "$help" 'git merge-tree exiting 1 both for a real conflict' \
    "the merge-tree exit-status incident must survive in what the wrapper tells a reader"
  assert_contains "$help" 'retrieval_incomplete' \
    "the reason the truncation calibration produces must still be a declared one"

  # The contexts(first:100) calibration, as behavior rather than as prose: the
  # flattened source cannot prove its own extent, so a set filling that page is
  # could-not-observe there. gh 2.96.0 asks for the OLDEST 100 in both its
  # single-request and listing forms, so the newest members - exactly the ones a
  # re-triggered check produces - are the ones missing.
  big=$(jq -nc '{statusCheckRollup: [range(100) | {__typename: "CheckRun",
    name: ("c" + (. | tostring)), status: "COMPLETED", conclusion: "SUCCESS"}]}')
  [ "$(printf '%s' "$big" | jq -r "$FM_VERIFY_CHECK_ROLLUP_EXPR")" = truncated ] \
    || fail "the flattened source must refuse a set filling its page: it has no totalCount to prove the extent with"
  # And its mirror, so the refusal tracks unprovable extent and not member count:
  # the authoritative source proves the same 100 complete and passes them.
  out=$(jq -nc --arg head "$HEAD" '{data: {repository: {pullRequest: {
      headRefOid: $head, mergeable: "MERGEABLE", reviewDecision: "APPROVED",
      commits: {nodes: [{commit: {oid: $head, statusCheckRollup: {contexts: {
        totalCount: 100,
        nodes: [range(100) | {__typename: "CheckRun", databaseId: (900 + .),
          name: ("c" + (. | tostring)), status: "COMPLETED",
          conclusion: "SUCCESS"}]}}}}]}}}}}' \
    | jq -r "$FM_VERIFY_ROLLUP_NORMALIZE_GRAPHQL | ($FM_VERIFY_ROLLUP_COUNTS)")
  fm_verify_rollup_classify "$out" || rc=$?
  expect_code 0 "$rc" "the authoritative source must pass 100 members its totalCount reconciles"
  pass "every calibration incident the audit named survives, in the surface a reader meets and in the behavior it produces"
}

run() {
  "$1"
  FM_TEST_PASSED_TESTS="$FM_TEST_PASSED_TESTS
$1"
}

run test_pre_consolidation_owners_disagreed
run test_one_owner_agrees_on_the_divergent_subject
run test_reduction_does_not_forgive_a_current_failure
run test_competing_derivation_verdict_is_refused_at_the_consumer
run test_a_near_miss_verifier_name_is_not_the_owner
run test_the_declared_owners_verdict_is_still_admitted
run test_both_consumers_return_one_answer_for_one_response
run test_pr_checks_reads_the_source_that_binds_evidence_to_a_head
run test_each_condition_reaches_its_own_answer
run test_empty_check_set_is_never_green
run test_evidence_about_another_commit_is_not_this_heads_evidence
run test_the_narrower_source_cannot_answer_for_a_head
run test_three_values_survive_the_new_boundary
run test_calibration_incidents_survive_the_move
