#!/usr/bin/env bash
# fm-landing-authorization.test.sh - behavior tests for the one-use, head-bound
# landing authorization and its exactly-once spend.
#
# THE CONTROLS THIS SUITE OWNS. Each was observed failing for its intended reason
# before it was trusted; docs/verification/inbound-ruling-authorization.md records
# those observations with the exact commands and output.
#
#   1. a fresh, correctly bound, unspent authorization IS consumed successfully
#   2. a second spend is refused and performs no act
#   3. a head other than the approved one is refused
#   4. a head that moved on the forge is refused even when the caller states the
#      approved head
#   5. a restart inside the spend window leaves a determinable state
#   6. an authorization for a superseded request is refused
#   7. minting requires a ruled request and an authorizing verdict
#   8. minting the same ruling twice grants one authorization
#   9. a correlation record filed under another id is refused
#  10. an unobservable head stops the spend without destroying the authorization
#  11. a spend already in flight is refused
#  12. a partial enumeration is could-not-observe, not a short list
#  13. reconciliation cannot reclaim a live spender's authorization
#  14. malformed authorization ids cannot address the store
#  15. malformed or misbound authorization records are unreadable
#
# CONTROL 1 IS NOT OPTIONAL AND IS NOT DECORATION. Every other control here is a
# refusal, and a mechanism that refuses everything satisfies all of them at once.
# So the refusal cases below do not merely assert a refusal: each first drives the
# SAME fixture unperturbed and asserts it succeeds, then applies exactly one
# perturbation and asserts the refusal. That pairing is what makes each refusal
# attributable to the perturbation rather than to a mechanism that never works.
#
# WHAT THIS SUITE DELIBERATELY DOES NOT TEST. Establishing that a ruling answers a
# given request, refusing an unrelated ruling, refusing an ambiguous ruling body,
# and invalidating a moved request are owned and already proven by
# tests/fm-outbound-artifact.test.sh. A parallel test here would assert the same
# property against a second implementation, which is how two control planes start.

set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FM_TEST_IDENTITY_CONTRACT=1

AUTH="$ROOT/bin/fm-landing-authorization.sh"

HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222

TMP_ROOT=$(fm_test_tmproot fm-landing-auth) || exit 1

# --- fixtures ----------------------------------------------------------------

# One case directory: an operational home carrying a `ruled` correlation record,
# and a gh stub whose answer for the pull request head is a file the test moves.
#
# The correlation record is written as DATA in the schema the outbound owner
# publishes, never by calling that owner's script: this suite proves the
# authority layer, and reaching into the other lane's emitter to build a fixture
# would couple the two exactly where they are meant to be separable.
new_case() {  # <name> [<request-id>] [<state>] [<verdict>] [<head>]
  local name=$1 rid=${2:-fm-ob-abcdef123456} state=${3:-ruled} verdict=${4:-accepted}
  local head=${5:-$HEAD_A} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/data/outbound-artifacts" "$dir/fakebin" || return 1
  printf '%s\n' "$head" > "$dir/forge_head"

  jq -n --arg rid "$rid" --arg state "$state" --arg verdict "$verdict" --arg head "$head" \
    '{schema:"fm-outbound-artifact.v1",
      request_id:$rid,
      channel:"sol-control",
      identity:{gate:"EXACT_HEAD_BROWSER_REVIEW_REQUIRED",
                project:"demo-project",
                repo:"owner/control",
                item:"demo-item",
                pr:"https://github.com/owner/demo/pull/7",
                head:$head},
      venue:"owner/control#2",
      state:$state,
      comment_id:"900",
      attempts:1,
      created:"2026-08-17T00:00:00Z",
      updated:"2026-08-17T00:00:00Z",
      ruling:(if $state == "emitted" then null
              else {comment_id:"901", verdict:$verdict, observed:"2026-08-17T01:00:00Z"} end),
      resumed:null,
      disposition:null,
      superseded_by:null}' > "$dir/home/data/outbound-artifacts/$rid.json" || return 1

  # The forge stub. It answers only the one question this mechanism asks, and it
  # reproduces the stdout trap on demand: `gh api` prints its error body to
  # stdout, so a stub that only ever fails loudly could not exercise the guard
  # against adopting that body as a head.
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
head_file="$FM_TEST_FORGE_HEAD"
value=$(cat "$head_file" 2>/dev/null)
case $value in
  FAIL) exit 1 ;;
  STDOUT_ERROR) printf '%s\n' '{"message":"Not Found","status":"404"}'; exit 0 ;;
  *) printf '%s\n' "$value" ;;
esac
SH
  chmod +x "$dir/fakebin/gh" || return 1
  printf '%s\n' "$dir"
}

# The act an authorization pays for. Appends one line per invocation, so "exactly
# once" is counted rather than asserted.
act_script() {  # <dir>
  local dir=$1
  cat > "$dir/act.sh" <<SH
#!/usr/bin/env bash
printf 'landed\n' >> '$dir/act.log'
exit \${FM_TEST_ACT_RC:-0}
SH
  chmod +x "$dir/act.sh"
  printf '%s\n' "$dir/act.sh"
}

act_count() {  # <dir>
  local dir=$1
  [ -e "$dir/act.log" ] || { printf '0\n'; return 0; }
  grep -c . "$dir/act.log"
}

# Every variable the command under test reads is passed EXPLICITLY here rather
# than relying on a `VAR=x run_auth ...` prefix reaching a grandchild process.
# The fault injection is the one that matters: a prefix that silently failed to
# export would make the restart control pass by never crashing at all, which is
# exactly the vacuous green this suite exists to avoid.
run_auth() {  # <dir> <args...>
  local dir=$1; shift
  ( cd "$dir" || exit 9
    PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_TEST_FORGE_HEAD="$dir/forge_head" \
    "$AUTH" "$@" )
}

mint_id() {  # <dir> [<request-id>]
  run_auth "$1" mint "${2:-fm-ob-abcdef123456}" | awk '{print $1}'
}

set_forge_head() { printf '%s\n' "$2" > "$1/forge_head"; }

fm_auth_id_shape() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^fm-auth-[0-9a-f]{32}$'
}

corr_path() {  # <dir> [<request-id>]
  printf '%s/home/data/outbound-artifacts/%s.json\n' "$1" "${2:-fm-ob-abcdef123456}"
}

blocking_act_script() {  # <dir>
  local dir=$1
  printf '%s\n' '#!/usr/bin/env bash' \
    ": > '$dir/act-entered'" \
    "printf '%s\\n' \"\$\$\" > '$dir/act-child'" \
    "while [ ! -e '$dir/act-release' ]; do sleep 0.01; done" > "$dir/blocking-act.sh"
  chmod +x "$dir/blocking-act.sh"
  printf '%s\n' "$dir/blocking-act.sh"
}

crash_spend_during_act() {  # <dir> <auth-id> <act>
  local dir=$1 id=$2 act=$3 claim record owner child child_group job i
  claim="$dir/home/data/landing-authorizations/.$id.claim"
  record="$dir/home/data/landing-authorizations/$id.json"
  run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" > "$dir/crash-spend.out" 2>&1 &
  job=$!
  fm_test_reap "$job"
  for i in $(seq 1 300); do
    if [ -s "$claim/owner-pid" ] \
      && [ -s "$dir/act-child" ] \
      && [ "$(jq -r '.state // ""' "$record" 2>/dev/null)" = spending ]; then
      break
    fi
    sleep 0.01
  done
  [ -s "$claim/owner-pid" ] || fail "restart: spender did not record its claim identity"
  [ "$(jq -r '.state // ""' "$record" 2>/dev/null)" = spending ] \
    || fail "restart: spender did not persist intent before SIGKILL"
  owner=$(cat "$claim/owner-pid")
  child=$(cat "$dir/act-child")
  fm_test_reap "$owner"
  fm_test_reap "$child"
  child_group=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d '[:space:]')
  [ "$child_group" = "$owner" ] \
    || fail "restart: blocking act group $child_group differs from owner $owner"
  kill -KILL "$owner" || fail "restart: could not SIGKILL spender $owner"
  wait "$job" 2>/dev/null || true
  [ -d "$claim" ] || fail "restart: SIGKILL did not leave an orphaned claim"
  kill -0 -- "-$owner" 2>/dev/null \
    || fail "restart: blocking act did not survive its wrapper"
  CRASH_GROUP=$owner
}

wait_for_group_exit() {  # <group>
  local group=$1 i
  for i in $(seq 1 300); do
    kill -0 -- "-$group" 2>/dev/null || return 0
    sleep 0.01
  done
  return 1
}

# --- 1: the non-vacuity control ----------------------------------------------

test_a_fresh_authorization_is_minted_and_spent_exactly_once() {
  local dir id act out rc
  dir=$(new_case nonvacuity) || fail "nonvacuity: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  fm_auth_id_shape "$id" || fail "nonvacuity: mint printed no authorization id: $id"

  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "nonvacuity: status of a fresh authorization"
  [ "$out" = granted ] || fail "nonvacuity: fresh authorization reported '$out', not granted"

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "nonvacuity: spending a fresh, correctly bound authorization: $out"
  assert_contains "$out" "spent:" "nonvacuity: the spend did not report itself spent"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "nonvacuity: the act ran $(act_count "$dir") times, not once"

  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = spent ] || fail "nonvacuity: after spending, status reported '$out', not spent"
  pass "a fresh, correctly bound, unspent authorization is consumed successfully"
}

# --- 2: exactly once ---------------------------------------------------------

test_a_second_spend_is_refused_and_performs_no_act() {
  local dir id act out rc
  dir=$(new_case exactly-once) || fail "exactly-once: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")

  run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" >/dev/null 2>&1 \
    || fail "exactly-once: the first spend did not succeed"
  [ "$(act_count "$dir")" = 1 ] || fail "exactly-once: the first spend did not run the act once"

  # A duplicate delivery converges rather than erroring: the caller learns the
  # authority is exhausted and the act does not run again.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  # The act count is asserted FIRST so that when this control goes red it names
  # the hazard - a second landing - rather than a missing message about one.
  [ "$(act_count "$dir")" = 1 ] \
    || fail "exactly-once: the act ran $(act_count "$dir") times across two spends"
  expect_code 0 "$rc" "exactly-once: a duplicate spend must converge, not error"
  assert_contains "$out" "FM_AUTH_ALREADY_SPENT" \
    "exactly-once: the duplicate spend did not name the exhausted authority"
  pass "a second spend is refused and performs no act"
}

# --- 3: bound to one exact head ----------------------------------------------

test_a_head_other_than_the_approved_one_is_refused() {
  local dir id act out rc
  dir=$(new_case head-bound) || fail "head-bound: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_B" -- "$act" 2>&1); rc=$?
  expect_code 3 "$rc" "head-bound: a different head must refuse: $out"
  assert_contains "$out" "FM_AUTH_HEAD_MISMATCH" "head-bound: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "head-bound: the act ran under the wrong head"

  # Red calibration: the same authorization, same fixture, correct head, succeeds.
  # Without this the refusal above is also satisfied by an authorization that can
  # never be spent at all.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "head-bound: the approved head must still spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "head-bound: the approved head did not run the act"
  pass "a head other than the approved one is refused"
}

# --- 4: the condition is not anchored to what the caller supplies ------------

test_a_moved_forge_head_is_refused_even_when_the_caller_states_the_approved_head() {
  local dir id act out rc
  dir=$(new_case moved-head) || fail "moved-head: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")

  # The caller passes the head the ruling approved, so every caller-side check
  # agrees. Only an INDEPENDENT observation can catch that the forge has moved -
  # which is the whole reason the head is observed rather than accepted.
  set_forge_head "$dir" "$HEAD_B"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 3 "$rc" "moved-head: a moved forge head must refuse: $out"
  assert_contains "$out" "FM_AUTH_STALE_HEAD" "moved-head: refusal token"
  assert_contains "$out" "$HEAD_B" "moved-head: the refusal did not name the head it observed"
  [ "$(act_count "$dir")" = 0 ] || fail "moved-head: the act ran against a moved head"

  # A head that moved can never come back to this authorization, so it is retired
  # rather than left to re-decide the same refusal on every later attempt.
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = void ] || fail "moved-head: after a moved head the authorization is '$out', not void"

  # Red calibration on a sibling fixture: identical in every way except that the
  # forge head never moved.
  dir=$(new_case moved-head-control) || fail "moved-head: control fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "moved-head control: an unmoved head must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "moved-head control: the act did not run"
  pass "a moved forge head is refused even when the caller states the approved head"
}

# --- 5: restart inside the spend window --------------------------------------

test_a_restart_inside_the_spend_window_leaves_a_determinable_state() {
  local dir id act out rc
  dir=$(new_case restart) || fail "restart: fixture failed"
  act=$(blocking_act_script "$dir")
  id=$(mint_id "$dir")

  crash_spend_during_act "$dir" "$id" "$act"

  # The state after the crash is DETERMINABLE and is neither of the neighbours.
  # Reporting granted would invite a retry that lands twice; reporting spent
  # would strand work that may never have landed.
  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  [ "$out" = indeterminate ] \
    || fail "restart: after a crash mid-spend the status is '$out', not indeterminate"
  expect_code 4 "$rc" "restart: an indeterminate status must report could-not-observe"

  # And a further spend does not guess.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 4 "$rc" "restart: spending an indeterminate authorization must be could-not-observe"
  assert_contains "$out" "FM_AUTH_SPEND_INDETERMINATE" "restart: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "restart: the act ran despite an indeterminate state"

  # Reconciliation is the only way out, and it needs an observation.
  out=$(run_auth "$dir" reconcile "$id" --observed not-applied 2>&1); rc=$?
  expect_code 2 "$rc" "restart: reconciling with no evidence must be a usage error"

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'pr 7 shows no merge commit' 2>&1); rc=$?
  expect_code 4 "$rc" "restart: reconciliation reclaimed while the act child lived: $out"
  : > "$dir/act-release"
  wait_for_group_exit "$CRASH_GROUP" || fail "restart: blocking act group did not exit"
  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'pr 7 shows no merge commit' 2>&1)
  assert_contains "$out" "granted" "restart: reconciling not-applied did not restore the authority"
  act=$(act_script "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "restart: after reconciliation the authority must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "restart: the reconciled authority did not run the act once"

  # The other reconciliation direction exhausts the authority rather than
  # restoring it, so an act that DID happen is never paid for twice.
  dir=$(new_case restart-applied) || fail "restart-applied: fixture failed"
  act=$(blocking_act_script "$dir")
  id=$(mint_id "$dir")
  crash_spend_during_act "$dir" "$id" "$act"
  : > "$dir/act-release"
  wait_for_group_exit "$CRASH_GROUP" || fail "restart-applied: blocking act group did not exit"
  run_auth "$dir" reconcile "$id" --observed applied --evidence 'pr 7 merged at 1111111' >/dev/null 2>&1 \
    || fail "restart-applied: reconciling applied failed"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = spent ] || fail "restart-applied: reconciled-applied reports '$out', not spent"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "restart-applied: a spent authority must converge"
  assert_contains "$out" "FM_AUTH_ALREADY_SPENT" "restart-applied: the authority was not exhausted"
  [ "$(act_count "$dir")" = 0 ] \
    || fail "restart-applied: the act ran after the spend was reconciled as already applied"
  pass "a restart inside the spend window leaves a determinable state"
}

# --- 6: superseded request ---------------------------------------------------

test_an_authorization_for_a_superseded_request_is_refused() {
  local dir id act out rc path
  dir=$(new_case superseded) || fail "superseded: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  path=$(corr_path "$dir")

  jq '.state = "superseded"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 3 "$rc" "superseded: a superseded request must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_SUPERSEDED" "superseded: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "superseded: the act ran for a superseded request"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = void ] || fail "superseded: the authorization is '$out', not void"

  # A request that has since been answered by a DIFFERENT ruling is likewise no
  # longer the approval this authority rests on.
  dir=$(new_case superseded-ruling) || fail "superseded-ruling: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  path=$(corr_path "$dir")
  jq '.ruling.comment_id = "999"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 3 "$rc" "superseded-ruling: a replaced ruling must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_SUPERSEDED" "superseded-ruling: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "superseded-ruling: the act ran under a replaced ruling"

  # Red calibration: the same fixture with the request untouched spends.
  dir=$(new_case superseded-control) || fail "superseded-control: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "superseded-control: an untouched request must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "superseded-control: the act did not run"
  pass "an authorization for a superseded request is refused"
}

# --- 7: what may be minted ---------------------------------------------------

test_minting_requires_a_ruled_request_and_an_authorizing_verdict() {
  local dir out rc
  dir=$(new_case mint-emitted '' emitted) || fail "mint-emitted: fixture failed"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "mint-emitted: an unruled request must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_NOT_RULED" "mint-emitted: refusal token"

  dir=$(new_case mint-declined '' ruled rejected) || fail "mint-declined: fixture failed"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "mint-declined: a declining verdict must refuse: $out"
  assert_contains "$out" "FM_AUTH_VERDICT_DECLINED" "mint-declined: refusal token"

  # An unknown word is could-not-observe, NOT a decline and never an approval.
  # The two refusals are different exit codes because they are different repairs:
  # one respects a decision, the other closes a vocabulary gap.
  dir=$(new_case mint-unknown '' ruled 'noted with interest') || fail "mint-unknown: fixture failed"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 4 "$rc" "mint-unknown: an unrecognized verdict must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_VERDICT_UNRECOGNIZED" "mint-unknown: refusal token"

  # Red calibration: the same shape with an authorizing verdict mints.
  dir=$(new_case mint-control) || fail "mint-control: fixture failed"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 0 "$rc" "mint-control: an authorizing verdict must mint: $out"
  pass "minting requires a ruled request and an authorizing verdict"
}

# --- 8: one approval grants one authority ------------------------------------

test_minting_the_same_ruling_twice_grants_one_authorization() {
  local dir first second third path count
  dir=$(new_case mint-idempotent) || fail "mint-idempotent: fixture failed"
  first=$(mint_id "$dir")
  second=$(mint_id "$dir")
  [ "$first" = "$second" ] \
    || fail "mint-idempotent: the same ruling minted two ids, $first and $second"
  count=$(find "$dir/home/data/landing-authorizations" -name '*.json' -type f | wc -l)
  [ "$count" -eq 1 ] || fail "mint-idempotent: $count authorization records for one ruling"

  # A moved head is a different authorization rather than the same one gone
  # stale, which is what makes "bound to one exact head" a property of the
  # identity rather than a rule enforced beside it.
  path=$(corr_path "$dir")
  jq --arg h "$HEAD_B" '.identity.head = $h' "$path" > "$path.new" && mv "$path.new" "$path"
  third=$(mint_id "$dir")
  [ "$third" != "$first" ] \
    || fail "mint-idempotent: a different head reused the authorization id $first"
  pass "minting the same ruling twice grants one authorization"
}

# --- 9: location is not identity ---------------------------------------------

test_a_correlation_record_filed_under_another_id_is_refused() {
  local dir out rc path
  dir=$(new_case misplaced) || fail "misplaced: fixture failed"
  path=$(corr_path "$dir")
  jq '.request_id = "fm-ob-999999999999"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "misplaced: a record naming another request must refuse: $out"
  assert_contains "$out" "FM_AUTH_CORRELATION_MISPLACED" "misplaced: refusal token"

  # An absent record and an unreadable one are different answers, and neither is
  # an approval.
  dir=$(new_case unreadable) || fail "unreadable: fixture failed"
  printf 'not json at all\n' > "$(corr_path "$dir")"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 4 "$rc" "unreadable: an unreadable record must be could-not-observe: $out"

  dir=$(new_case absent) || fail "absent: fixture failed"
  rm -f "$(corr_path "$dir")"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "absent: an absent record must refuse: $out"
  assert_contains "$out" "FM_AUTH_CORRELATION_ABSENT" "absent: refusal token"
  pass "a correlation record filed under another id is refused"
}

# --- 10: an unobservable head is not a pass and not a void -------------------

test_an_unobservable_head_stops_the_spend_without_destroying_the_authorization() {
  local dir id act out rc
  dir=$(new_case head-unobservable) || fail "head-unobservable: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")

  set_forge_head "$dir" FAIL
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 4 "$rc" "head-unobservable: a failed observation must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_HEAD_UNOBSERVED" "head-unobservable: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "head-unobservable: the act ran on an unobserved head"

  # Could-not-observe must not destroy the authority: nothing was learned about
  # the head, so nothing is decided about the authorization either.
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = granted ] \
    || fail "head-unobservable: an unobservable head left the authorization '$out', not granted"

  # The stdout trap: gh prints its error body to stdout, and a reader that only
  # checks the exit status carries that body forward as a head.
  set_forge_head "$dir" STDOUT_ERROR
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 4 "$rc" "head-unobservable: an error body on stdout must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_HEAD_UNOBSERVED" "head-unobservable: stdout-trap token"
  [ "$(act_count "$dir")" = 0 ] || fail "head-unobservable: the act ran on an error body"

  # Red calibration: restore the real head and the same authorization spends.
  set_forge_head "$dir" "$HEAD_A"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "head-unobservable: an observable head must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "head-unobservable: the act did not run once"
  pass "an unobservable head stops the spend without destroying the authorization"
}

# --- 11: one authority, one spender ------------------------------------------

test_a_spend_already_in_flight_is_refused() {
  local dir id act out rc
  dir=$(new_case in-flight) || fail "in-flight: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")

  mkdir -p "$dir/home/data/landing-authorizations/.$id.claim" \
    || fail "in-flight: could not stage the claim"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 3 "$rc" "in-flight: a held claim must refuse: $out"
  assert_contains "$out" "FM_AUTH_SPEND_IN_FLIGHT" "in-flight: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "in-flight: the act ran while another spend held the claim"

  # Red calibration: release the claim and the same authorization spends.
  rmdir "$dir/home/data/landing-authorizations/.$id.claim"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 0 "$rc" "in-flight: a released claim must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "in-flight: the act did not run once"
  pass "a spend already in flight is refused"
}

# --- 12: enumeration is three-valued -----------------------------------------

test_a_partial_enumeration_is_could_not_observe_rather_than_a_short_list() {
  local dir id out rc
  dir=$(new_case enumeration) || fail "enumeration: fixture failed"

  # An absent store is genuinely empty, and says so with a count rather than with
  # silence - silence is also what an unreadable store looks like.
  out=$(run_auth "$dir" list 2>&1); rc=$?
  expect_code 0 "$rc" "enumeration: an absent store must be readable as empty: $out"
  assert_contains "$out" "count=0" "enumeration: an empty store did not report its count"

  id=$(mint_id "$dir")
  out=$(run_auth "$dir" list 2>&1); rc=$?
  expect_code 0 "$rc" "enumeration: a readable store must enumerate: $out"
  assert_contains "$out" "$id" "enumeration: the minted authorization was not listed"
  assert_contains "$out" "count=1" "enumeration: the count was wrong"

  # One unreadable record makes the whole listing incomplete. Reporting the rest
  # as if it were the whole set is the substitution that turns a broken read into
  # a confident negative answer.
  printf 'corrupt\n' > "$dir/home/data/landing-authorizations/fm-auth-00000000000000000000000000000000.json"
  out=$(run_auth "$dir" list 2>&1); rc=$?
  expect_code 4 "$rc" "enumeration: an unreadable member must make the listing could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_ENUMERATION_UNOBSERVED" "enumeration: refusal token"
  assert_contains "$out" "unreadable" "enumeration: the unreadable member was not named"
  pass "a partial enumeration is could-not-observe rather than a short list"
}

# --- 13: reconciliation owns the claim before changing durable state ---------

test_reconciliation_cannot_reclaim_a_live_spenders_authorization() {
  local dir id act out rc pid i
  dir=$(new_case live-reconcile) || fail "live-reconcile: fixture failed"
  id=$(mint_id "$dir")
  act="$dir/blocking-act.sh"
  printf '%s\n' '#!/usr/bin/env bash' \
    "printf 'landed\\n' >> '$dir/act.log'" \
    ": > '$dir/act-entered'" \
    "while [ ! -e '$dir/act-release' ]; do sleep 0.01; done" > "$act"
  chmod +x "$act"

  run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" >"$dir/spend.out" 2>&1 &
  pid=$!
  fm_test_reap "$pid"
  for i in $(seq 1 200); do
    [ -e "$dir/act-entered" ] && break
    sleep 0.01
  done
  [ -e "$dir/act-entered" ] || fail "live-reconcile: spender never entered the act"

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'forge has not reported applied' 2>&1); rc=$?
  expect_code 4 "$rc" "live-reconcile: reconciliation reclaimed a live spender: $out"
  assert_contains "$out" "FM_AUTH_SPEND_INDETERMINATE" "live-reconcile: refusal token"
  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  [ "$out" = indeterminate ] || fail "live-reconcile: reconciliation changed live state to '$out'"
  expect_code 4 "$rc" "live-reconcile: live spend status must remain indeterminate"

  : > "$dir/act-release"
  wait "$pid" || fail "live-reconcile: original spender did not finish"
  [ "$(act_count "$dir")" = 1 ] || fail "live-reconcile: act did not run exactly once"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = spent ] || fail "live-reconcile: completed spender left status '$out'"
  pass "reconciliation cannot reclaim a live spender's authorization"
}

# --- 14: ids are validated at the store boundary -----------------------------

test_malformed_authorization_ids_cannot_address_the_store() {
  local dir out rc
  dir=$(new_case malformed-id) || fail "malformed-id: fixture failed"
  mkdir -p "$dir/home/data"
  printf '%s\n' '{"schema":"fm-landing-authorization.v1","state":"spent"}' > "$dir/home/data/outside.json"

  out=$(run_auth "$dir" status ../outside 2>&1); rc=$?
  expect_code 4 "$rc" "malformed-id: traversal id reached a record path: $out"
  [ "$out" = unreadable ] || fail "malformed-id: traversal id reported '$out', not unreadable"
  pass "malformed authorization ids cannot address the store"
}

# --- 15: records prove their shape and identity ------------------------------

test_malformed_or_misbound_authorization_records_are_unreadable() {
  local dir id act path out rc
  dir=$(new_case malformed-record) || fail "malformed-record: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  printf '%s\n' '{"schema":"fm-landing-authorization.v1","state":"spent"}' > "$path"
  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  expect_code 4 "$rc" "malformed-record: skeletal record was trusted: $out"
  [ "$out" = unreadable ] || fail "malformed-record: skeletal record reported '$out'"

  dir=$(new_case misbound-record) || fail "misbound-record: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  jq '.grant.item = "different-item"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" 2>&1); rc=$?
  expect_code 4 "$rc" "misbound-record: identity mismatch reached spend: $out"
  assert_contains "$out" "FM_AUTH_RECORD_UNREADABLE" "misbound-record: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "misbound-record: act ran from a misbound record"

  dir=$(new_case record-control) || fail "record-control: fixture failed"
  act=$(act_script "$dir")
  id=$(mint_id "$dir")
  run_auth "$dir" spend "$id" --head "$HEAD_A" -- "$act" >/dev/null 2>&1 \
    || fail "record-control: valid record did not spend"
  [ "$(act_count "$dir")" = 1 ] || fail "record-control: valid record did not run the act once"
  pass "malformed or misbound authorization records are unreadable"
}

# --- run ---------------------------------------------------------------------

test_a_fresh_authorization_is_minted_and_spent_exactly_once
test_a_second_spend_is_refused_and_performs_no_act
test_a_head_other_than_the_approved_one_is_refused
test_a_moved_forge_head_is_refused_even_when_the_caller_states_the_approved_head
test_a_restart_inside_the_spend_window_leaves_a_determinable_state
test_an_authorization_for_a_superseded_request_is_refused
test_minting_requires_a_ruled_request_and_an_authorizing_verdict
test_minting_the_same_ruling_twice_grants_one_authorization
test_a_correlation_record_filed_under_another_id_is_refused
test_an_unobservable_head_stops_the_spend_without_destroying_the_authorization
test_a_spend_already_in_flight_is_refused
test_a_partial_enumeration_is_could_not_observe_rather_than_a_short_list
test_reconciliation_cannot_reclaim_a_live_spenders_authorization
test_malformed_authorization_ids_cannot_address_the_store
test_malformed_or_misbound_authorization_records_are_unreadable

fm_test_contract "$0"
