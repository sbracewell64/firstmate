#!/usr/bin/env bash
# fm-landing-authorization.test.sh - behavior tests for the one-use, head-bound
# landing authorization and its exactly-once spend.
#
# Subject: bin/fm-landing-authorization.sh, and the identity, state vocabulary,
# record store and spend predicates it consumes from
# bin/fm-landing-authorization-lib.sh. The publication effect that library also
# carries is verified separately by tests/fm-publication-seam.test.sh.
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
#  16. the act performed is the authority's own, and a caller-asserted act may
#      only agree with it
#  17. an executable swapped after authorization refuses at effect time rather
#      than running whatever is now at that path
#  18. an authority whose effect plan is incomplete or unsupported refuses before
#      the act
#  19. credential-bearing mechanism input is refused before the act
#  20. one approval grants one landing, even when a second plan is presented
#  21. sibling effect plans serialize on one ruling reservation
#  22. a pre-act signal releases its ruling reservation
#  23. a ruling-reservation release failure is observable
#  24. an orphaned granted reservation is reconciled only from evidence
#  25. a live granted reservation cannot be reclaimed
#  26. an act that exits non-zero leaves the authority indeterminate
#  27. a moved project alias cannot retarget the local act
#  28. a moved target ref cannot retarget the local act
#  29. successful exit requires post-effect proof
#  30. the real path end to end: a ruled correlation record mints a plan, the
#      spend constructs the act, and a scratch repository proves it happened
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
  local head=${5:-$HEAD_A} dir real_perl
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
if [[ " $* " == *" [.merged, .head.sha] "* ]]; then
  merged=$(cat "$FM_TEST_FORGE_MERGED" 2>/dev/null) || exit 1
  [ "$merged" != FAIL ] || exit 1
  printf '%s\t%s\n' "$merged" "$value"
  exit 0
fi
case $value in
  FAIL) exit 1 ;;
  STDOUT_ERROR) printf '%s\n' '{"message":"Not Found","status":"404"}'; exit 0 ;;
  *) printf '%s\n' "$value" ;;
esac
SH
  chmod +x "$dir/fakebin/gh" || return 1
  real_perl=$(command -v perl) || return 1
  cat > "$dir/fakebin/perl" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -e ] && [[ "\${2:-}" = *FM_AUTH_GROUP_PROBE* ]]; then
  case \$(cat '$dir/group_probe_mode' 2>/dev/null) in
    ALIVE) exit 0 ;;
    ESRCH) exit 3 ;;
    EPERM) exit 5 ;;
    OTHER) exit 4 ;;
  esac
fi
exec '$real_perl' "\$@"
SH
  chmod +x "$dir/fakebin/perl" || return 1
  act_stub "$dir" || return 1
  printf '%s\n' true > "$dir/forge_merged"
  printf '%s\n' "$dir"
}

# The act an authorization pays for. It is NO LONGER a script the test hands to
# `spend`: the authority constructs its own act from its effect plan, and for a
# `pr-merge` plan that act is `gh-axi pr merge ...`. So this is a gh-axi stub,
# placed where the mint resolves it, and it appends one line per invocation so
# "exactly once" is counted rather than asserted.
#
# EVERY BEHAVIOUR IT VARIES IS FILE-DRIVEN, and that is a requirement rather than
# a style: the mint pins this file's content digest into the plan, so a case that
# rewrote the stub to make it block or fail would be exercising the stale-executable
# refusal instead of the control it meant to run.
act_stub() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/act.log'
: > '$dir/act-entered'
printf '%s\n' "\$\$" > '$dir/act-child'
if [ -e '$dir/act-block' ]; then
  while [ ! -e '$dir/act-release' ]; do sleep 0.01; done
fi
if [ -f '$dir/act-rc' ]; then
  exit "\$(cat '$dir/act-rc')"
fi
exit 0
SH
  chmod +x "$dir/fakebin/gh-axi"
}

arm_blocking_act() { : > "$1/act-block"; }
release_act() { : > "$1/act-release"; }
unblock_future_acts() { rm -f "$1/act-block" "$1/act-release" "$1/act-child"; }

act_count() {  # <dir>
  local dir=$1
  [ -e "$dir/act.log" ] || { printf '0\n'; return 0; }
  grep -c . "$dir/act.log"
}

ruling_reservation() {  # <dir>
  local path
  for path in "$1/home/data/landing-authorizations"/.*.ruling-reservation; do
    [ -d "$path" ] || continue
    printf '%s\n' "$path"
    return 0
  done
  return 1
}

ORPHAN_RESERVATION=
orphan_granted_reservation() {  # <dir> <auth-id>
  local dir=$1 id=$2 claim job owner reservation
  claim="$dir/home/data/landing-authorizations/.$id.claim"
  mkfifo "$dir/orphan-receipt" || return 1
  run_auth "$dir" spend "$id" --head "$HEAD_A" --receipt "$dir/orphan-receipt" \
    > "$dir/orphan-spend.out" 2>&1 &
  job=$!
  fm_test_reap "$job"
  for _ in $(seq 1 300); do
    reservation=$(ruling_reservation "$dir" 2>/dev/null) \
      && [ -s "$claim/owner-pid" ] \
      && [ "$(jq -r '.state' "$dir/home/data/landing-authorizations/$id.json")" = granted ] \
      && break
    sleep 0.01
  done
  [ -n "${reservation:-}" ] || return 1
  owner=$(cat "$claim/owner-pid") || return 1
  kill -KILL "$owner" || return 1
  wait "$job" 2>/dev/null || true
  rm -f "$dir/orphan-receipt"
  [ -d "$reservation" ] || return 1
  [ "$(act_count "$dir")" = 0 ] || return 1
  ORPHAN_RESERVATION=$reservation
}

# The act the authority derives for the shared fixture's plan, as a caller would
# assert it. Written out here rather than read back from the record, because an
# assertion built from the thing it asserts proves nothing.
ASSERT_ACT=(gh-axi pr merge 7 --repo owner/demo --squash)

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
    FM_TEST_FORGE_MERGED="$dir/forge_merged" \
    "$AUTH" "$@" )
}

# The shared plan. Every mint in this suite declares the same `pr-merge` effect,
# so the id, the derived act, and the stub that performs it are all one fixture.
mint_plan() {  # <dir> <request-id> [<extra mint args>...]
  local dir=$1 rid=$2; shift 2
  run_auth "$dir" mint "$rid" --effect pr-merge --method squash "$@"
}

mint_id() {  # <dir> [<request-id>]
  mint_plan "$1" "${2:-fm-ob-abcdef123456}" | awk '{print $1}'
}

set_forge_head() { printf '%s\n' "$2" > "$1/forge_head"; }

set_group_probe_mode() { printf '%s\n' "$2" > "$1/group_probe_mode"; }

fm_auth_id_shape() {  # <candidate>
  printf '%s' "${1:-}" | grep -Eq '^fm-auth-[0-9a-f]{32}$'
}

corr_path() {  # <dir> [<request-id>]
  printf '%s/home/data/outbound-artifacts/%s.json\n' "$1" "${2:-fm-ob-abcdef123456}"
}

crash_spend_during_act() {  # <dir> <auth-id>
  local dir=$1 id=$2 claim record owner child child_group job i
  claim="$dir/home/data/landing-authorizations/.$id.claim"
  record="$dir/home/data/landing-authorizations/$id.json"
  arm_blocking_act "$dir"
  run_auth "$dir" spend "$id" --head "$HEAD_A" > "$dir/crash-spend.out" 2>&1 &
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
  local dir id out rc
  dir=$(new_case nonvacuity) || fail "nonvacuity: fixture failed"
  id=$(mint_id "$dir")
  fm_auth_id_shape "$id" || fail "nonvacuity: mint printed no authorization id: $id"

  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  expect_code 0 "$rc" "nonvacuity: status of a fresh authorization"
  [ "$out" = granted ] || fail "nonvacuity: fresh authorization reported '$out', not granted"

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
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
  local dir id out rc
  dir=$(new_case exactly-once) || fail "exactly-once: fixture failed"
  id=$(mint_id "$dir")

  run_auth "$dir" spend "$id" --head "$HEAD_A" >/dev/null 2>&1 \
    || fail "exactly-once: the first spend did not succeed"
  [ "$(act_count "$dir")" = 1 ] || fail "exactly-once: the first spend did not run the act once"

  # A duplicate delivery converges rather than erroring: the caller learns the
  # authority is exhausted and the act does not run again.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
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
  local dir id out rc
  dir=$(new_case head-bound) || fail "head-bound: fixture failed"
  id=$(mint_id "$dir")

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_B" 2>&1); rc=$?
  expect_code 3 "$rc" "head-bound: a different head must refuse: $out"
  assert_contains "$out" "FM_AUTH_HEAD_MISMATCH" "head-bound: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "head-bound: the act ran under the wrong head"

  # Red calibration: the same authorization, same fixture, correct head, succeeds.
  # Without this the refusal above is also satisfied by an authorization that can
  # never be spent at all.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "head-bound: the approved head must still spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "head-bound: the approved head did not run the act"
  pass "a head other than the approved one is refused"
}

# --- 4: the condition is not anchored to what the caller supplies ------------

test_a_moved_forge_head_is_refused_even_when_the_caller_states_the_approved_head() {
  local dir id out rc
  dir=$(new_case moved-head) || fail "moved-head: fixture failed"
  id=$(mint_id "$dir")

  # The caller passes the head the ruling approved, so every caller-side check
  # agrees. Only an INDEPENDENT observation can catch that the forge has moved -
  # which is the whole reason the head is observed rather than accepted.
  set_forge_head "$dir" "$HEAD_B"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
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
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "moved-head control: an unmoved head must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "moved-head control: the act did not run"
  pass "a moved forge head is refused even when the caller states the approved head"
}

# --- 5: restart inside the spend window --------------------------------------

test_a_restart_inside_the_spend_window_leaves_a_determinable_state() {
  local dir id sibling out rc crashed
  dir=$(new_case restart) || fail "restart: fixture failed"
  id=$(mint_id "$dir")
  sibling=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')

  crash_spend_during_act "$dir" "$id"
  # The crashed spend REACHED its act, which is the whole hazard being modelled,
  # so what every count below measures is the delta from here. Asserting a fixed
  # zero would be asserting the crash never happened.
  crashed=$(act_count "$dir")
  [ "$crashed" -ge 1 ] || fail "restart: the crashed spend never entered its act"

  # The state after the crash is DETERMINABLE and is neither of the neighbours.
  # Reporting granted would invite a retry that lands twice; reporting spent
  # would strand work that may never have landed.
  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  [ "$out" = indeterminate ] \
    || fail "restart: after a crash mid-spend the status is '$out', not indeterminate"
  expect_code 4 "$rc" "restart: an indeterminate status must report could-not-observe"

  # And a further spend does not guess.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "restart: spending an indeterminate authorization must be could-not-observe"
  assert_contains "$out" "FM_AUTH_SPEND_INDETERMINATE" "restart: refusal token"
  [ "$(act_count "$dir")" = "$crashed" ] \
    || fail "restart: the act ran again despite an indeterminate state"

  out=$(run_auth "$dir" spend "$sibling" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "restart: a sibling passed a live ruling reservation: $out"
  assert_contains "$out" "$id" "restart: the orphaned reservation did not name its holder"
  [ "$(act_count "$dir")" = "$crashed" ] \
    || fail "restart: a sibling act ran while the ruling was indeterminate"

  # Reconciliation is the only way out, and it needs an observation.
  out=$(run_auth "$dir" reconcile "$id" --observed not-applied 2>&1); rc=$?
  expect_code 2 "$rc" "restart: reconciling with no evidence must be a usage error"

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'pr 7 shows no merge commit' 2>&1); rc=$?
  expect_code 4 "$rc" "restart: reconciliation reclaimed while the act child lived: $out"
  release_act "$dir"
  wait_for_group_exit "$CRASH_GROUP" || fail "restart: blocking act group did not exit"
  set_group_probe_mode "$dir" EPERM
  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'pr 7 shows no merge commit' 2>&1); rc=$?
  expect_code 4 "$rc" "restart: permission-denied group probe reclaimed the authorization: $out"
  assert_contains "$out" "still exists" "restart: permission denial did not establish group existence"
  set_group_probe_mode "$dir" ESRCH
  out=$(run_auth "$dir" reconcile "$id" --observed not-applied --evidence 'pr 7 shows no merge commit' 2>&1)
  assert_contains "$out" "granted" "restart: reconciling not-applied did not restore the authority"
  unblock_future_acts "$dir"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "restart: after reconciliation the authority must spend: $out"
  [ "$(act_count "$dir")" = "$((crashed + 1))" ] \
    || fail "restart: the reconciled authority did not run the act exactly once more"

  # The other reconciliation direction exhausts the authority rather than
  # restoring it, so an act that DID happen is never paid for twice.
  dir=$(new_case restart-applied) || fail "restart-applied: fixture failed"
  id=$(mint_id "$dir")
  crash_spend_during_act "$dir" "$id"
  crashed=$(act_count "$dir")
  release_act "$dir"
  wait_for_group_exit "$CRASH_GROUP" || fail "restart-applied: blocking act group did not exit"
  run_auth "$dir" reconcile "$id" --observed applied --evidence 'pr 7 merged at 1111111' >/dev/null 2>&1 \
    || fail "restart-applied: reconciling applied failed"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = spent ] || fail "restart-applied: reconciled-applied reports '$out', not spent"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "restart-applied: a spent authority must converge"
  assert_contains "$out" "FM_AUTH_ALREADY_SPENT" "restart-applied: the authority was not exhausted"
  [ "$(act_count "$dir")" = "$crashed" ] \
    || fail "restart-applied: the act ran again after the spend was reconciled as already applied"
  pass "a restart inside the spend window leaves a determinable state"
}

# --- 6: superseded request ---------------------------------------------------

test_an_authorization_for_a_superseded_request_is_refused() {
  local dir id out rc path
  dir=$(new_case superseded) || fail "superseded: fixture failed"
  id=$(mint_id "$dir")
  path=$(corr_path "$dir")

  jq '.state = "superseded"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "superseded: a superseded request must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_SUPERSEDED" "superseded: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "superseded: the act ran for a superseded request"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = void ] || fail "superseded: the authorization is '$out', not void"

  # A request that has since been answered by a DIFFERENT ruling is likewise no
  # longer the approval this authority rests on.
  dir=$(new_case superseded-ruling) || fail "superseded-ruling: fixture failed"
  id=$(mint_id "$dir")
  path=$(corr_path "$dir")
  jq '.ruling.comment_id = "999"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "superseded-ruling: a replaced ruling must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_SUPERSEDED" "superseded-ruling: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "superseded-ruling: the act ran under a replaced ruling"

  # Red calibration: the same fixture with the request untouched spends.
  dir=$(new_case superseded-control) || fail "superseded-control: fixture failed"
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "superseded-control: an untouched request must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "superseded-control: the act did not run"
  pass "an authorization for a superseded request is refused"
}

# --- 7: what may be minted ---------------------------------------------------

test_minting_requires_a_ruled_request_and_an_authorizing_verdict() {
  local dir out rc
  dir=$(new_case mint-emitted '' emitted) || fail "mint-emitted: fixture failed"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "mint-emitted: an unruled request must refuse: $out"
  assert_contains "$out" "FM_AUTH_REQUEST_NOT_RULED" "mint-emitted: refusal token"

  dir=$(new_case mint-declined '' ruled rejected) || fail "mint-declined: fixture failed"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "mint-declined: a declining verdict must refuse: $out"
  assert_contains "$out" "FM_AUTH_VERDICT_DECLINED" "mint-declined: refusal token"

  # An unknown word is could-not-observe, NOT a decline and never an approval.
  # The two refusals are different exit codes because they are different repairs:
  # one respects a decision, the other closes a vocabulary gap.
  dir=$(new_case mint-unknown '' ruled 'noted with interest') || fail "mint-unknown: fixture failed"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 4 "$rc" "mint-unknown: an unrecognized verdict must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_VERDICT_UNRECOGNIZED" "mint-unknown: refusal token"

  # Red calibration: the same shape with an authorizing verdict mints.
  dir=$(new_case mint-control) || fail "mint-control: fixture failed"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
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
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 3 "$rc" "misplaced: a record naming another request must refuse: $out"
  assert_contains "$out" "FM_AUTH_CORRELATION_MISPLACED" "misplaced: refusal token"

  # An absent record and an unreadable one are different answers, and neither is
  # an approval.
  dir=$(new_case unreadable) || fail "unreadable: fixture failed"
  printf 'not json at all\n' > "$(corr_path "$dir")"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 4 "$rc" "unreadable: an unreadable record must be could-not-observe: $out"

  dir=$(new_case absent) || fail "absent: fixture failed"
  rm -f "$(corr_path "$dir")"
  out=$(mint_plan "$dir" fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 4 "$rc" "absent: an absent record must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_CORRELATION_ABSENT" "absent: refusal token"
  pass "a correlation record filed under another id is refused"
}

# --- 10: an unobservable head is not a pass and not a void -------------------

test_an_unobservable_head_stops_the_spend_without_destroying_the_authorization() {
  local dir id out rc
  dir=$(new_case head-unobservable) || fail "head-unobservable: fixture failed"
  id=$(mint_id "$dir")

  set_forge_head "$dir" FAIL
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
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
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "head-unobservable: an error body on stdout must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_HEAD_UNOBSERVED" "head-unobservable: stdout-trap token"
  [ "$(act_count "$dir")" = 0 ] || fail "head-unobservable: the act ran on an error body"

  # Red calibration: restore the real head and the same authorization spends.
  set_forge_head "$dir" "$HEAD_A"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "head-unobservable: an observable head must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "head-unobservable: the act did not run once"
  pass "an unobservable head stops the spend without destroying the authorization"
}

# --- 11: one authority, one spender ------------------------------------------

test_a_spend_already_in_flight_is_refused() {
  local dir id out rc
  dir=$(new_case in-flight) || fail "in-flight: fixture failed"
  id=$(mint_id "$dir")

  mkdir -p "$dir/home/data/landing-authorizations/.$id.claim" \
    || fail "in-flight: could not stage the claim"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "in-flight: a held claim must refuse: $out"
  assert_contains "$out" "FM_AUTH_SPEND_IN_FLIGHT" "in-flight: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "in-flight: the act ran while another spend held the claim"

  # Red calibration: release the claim and the same authorization spends.
  rmdir "$dir/home/data/landing-authorizations/.$id.claim"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "in-flight: a released claim must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "in-flight: the act did not run once"
  pass "a spend already in flight is refused"
}

test_concurrent_spends_revalidate_after_claiming() {
  local dir id first second first_pid second_pid
  dir=$(new_case concurrent-spend) || fail "concurrent-spend: fixture failed"
  id=$(mint_id "$dir")

  run_auth "$dir" spend "$id" --head "$HEAD_A" >"$dir/first.out" 2>&1 &
  first_pid=$!
  fm_test_reap "$first_pid"
  run_auth "$dir" spend "$id" --head "$HEAD_A" >"$dir/second.out" 2>&1 &
  second_pid=$!
  fm_test_reap "$second_pid"
  wait "$first_pid" || true
  wait "$second_pid" || true
  first=$(cat "$dir/first.out")
  second=$(cat "$dir/second.out")
  [ "$(act_count "$dir")" = 1 ] \
    || fail "concurrent-spend: concurrent callers ran the act more than once: $first / $second"
  pass "concurrent spends revalidate after claiming"
}

test_concurrent_mints_cannot_replace_a_spent_record() {
  local dir first second first_pid second_pid id
  dir=$(new_case concurrent-mint) || fail "concurrent-mint: fixture failed"
  mint_plan "$dir" fm-ob-abcdef123456 >"$dir/first-mint.out" 2>&1 &
  first_pid=$!
  fm_test_reap "$first_pid"
  mint_plan "$dir" fm-ob-abcdef123456 >"$dir/second-mint.out" 2>&1 &
  second_pid=$!
  fm_test_reap "$second_pid"
  wait "$first_pid" || true
  wait "$second_pid" || true
  first=$(awk '{print $1}' "$dir/first-mint.out")
  second=$(awk '{print $1}' "$dir/second-mint.out")
  id=${first:-$second}
  fm_auth_id_shape "$id" || fail "concurrent-mint: neither mint produced an authorization"
  run_auth "$dir" spend "$id" --head "$HEAD_A" >/dev/null 2>&1 \
    || fail "concurrent-mint: minted authorization could not be spent"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = spent ] \
    || fail "concurrent-mint: spent record was replaced"
  pass "concurrent mints cannot replace a spent record"
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
  local dir id out rc pid i
  dir=$(new_case live-reconcile) || fail "live-reconcile: fixture failed"
  id=$(mint_id "$dir")
  arm_blocking_act "$dir"

  run_auth "$dir" spend "$id" --head "$HEAD_A" >"$dir/spend.out" 2>&1 &
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

  release_act "$dir"
  wait "$pid" || fail "live-reconcile: original spender did not finish"
  [ "$(act_count "$dir")" = 1 ] || fail "live-reconcile: act did not run exactly once"
  out=$(run_auth "$dir" status "$id" 2>&1)
  [ "$out" = spent ] || fail "live-reconcile: completed spender left status '$out'"
  pass "reconciliation cannot reclaim a live spender's authorization"
}

# --- 14: ids are validated at the store boundary -----------------------------

test_malformed_authorization_ids_cannot_address_the_store() {
  local dir out rc writer
  dir=$(new_case malformed-id) || fail "malformed-id: fixture failed"
  mkdir -p "$dir/home/data/landing-authorizations"
  mkfifo "$dir/home/data/outside.json"
  ( printf '%s\n' '{"schema":"fm-landing-authorization.v1","state":"spent"}' > "$dir/home/data/outside.json"
    : > "$dir/path-reached" ) &
  writer=$!
  fm_test_reap "$writer"

  out=$(run_auth "$dir" status ../outside 2>&1); rc=$?
  kill "$writer" 2>/dev/null || true
  wait "$writer" 2>/dev/null || true
  expect_code 4 "$rc" "malformed-id: traversal id reached a record path: $out"
  [ "$out" = unreadable ] || fail "malformed-id: traversal id reported '$out', not unreadable"
  [ ! -e "$dir/path-reached" ] || fail "malformed-id: traversal id opened a record outside the store"
  pass "malformed authorization ids cannot address the store"
}

# --- 15: records prove their shape and identity ------------------------------

test_malformed_or_misbound_authorization_records_are_unreadable() {
  local dir id path out rc
  dir=$(new_case malformed-record) || fail "malformed-record: fixture failed"
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  printf '%s\n' '{"schema":"fm-landing-authorization.v1","state":"spent"}' > "$path"
  out=$(run_auth "$dir" status "$id" 2>&1); rc=$?
  expect_code 4 "$rc" "malformed-record: skeletal record was trusted: $out"
  [ "$out" = unreadable ] || fail "malformed-record: skeletal record reported '$out'"

  dir=$(new_case misbound-record) || fail "misbound-record: fixture failed"
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  jq '.grant.item = "different-item"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "misbound-record: identity mismatch reached spend: $out"
  assert_contains "$out" "FM_AUTH_RECORD_UNREADABLE" "misbound-record: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "misbound-record: act ran from a misbound record"

  dir=$(new_case record-control) || fail "record-control: fixture failed"
  id=$(mint_id "$dir")
  run_auth "$dir" spend "$id" --head "$HEAD_A" >/dev/null 2>&1 \
    || fail "record-control: valid record did not spend"
  [ "$(act_count "$dir")" = 1 ] || fail "record-control: valid record did not run the act once"
  pass "malformed or misbound authorization records are unreadable"
}

# --- 16: the act belongs to the authority, not to the caller -----------------
#
# THE PROPERTY THIS SECTION OWNS. A valid authorization does not become a licence
# to run something else. Every case here holds a genuinely valid, unspent, exactly
# bound authority - the one that lands in the control below - and perturbs only
# what act the caller names. Each must perform ZERO acts, and the counting fixture
# is what makes that a measurement rather than a hope.

# The act the record actually holds, so a refusal can be attributed to the
# perturbation rather than to a plan nobody looked at.
recorded_act() {  # <dir> <auth-id>
  jq -r '[.effect.executable_path, "pr", "merge", .effect.pr, "--repo", .effect.repo,
          ("--" + .effect.method)] | join(" ")' \
    "$1/home/data/landing-authorizations/$2.json"
}

test_the_act_is_the_authoritys_own_and_an_assertion_may_only_agree() {
  local dir id out rc derived
  dir=$(new_case owner-constructed-act) || fail "owner-act: fixture failed"
  id=$(mint_id "$dir")
  derived=$(recorded_act "$dir" "$id")
  case $derived in
    */fakebin/gh-axi\ pr\ merge\ 7\ --repo\ owner/demo\ --squash) ;;
    *) fail "owner-act: the minted plan derives '$derived', which is not the act this fixture describes" ;;
  esac

  # (a) The withdrawn form. A caller that still believes it supplies the command
  # is told so rather than having its argv quietly reinterpreted as an assertion.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" -- /bin/echo landed 2>&1); rc=$?
  expect_code 2 "$rc" "owner-act: the withdrawn caller-command form must be a usage error: $out"
  [ "$(act_count "$dir")" = 0 ] || fail "owner-act: a caller-supplied command ran"

  # (b) Another executable at another path.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    /bin/echo pr merge 7 --repo owner/demo --squash 2>&1); rc=$?
  expect_code 3 "$rc" "owner-act: a substituted executable must refuse: $out"
  assert_contains "$out" "FM_AUTH_ACT_ASSERTION_MISMATCH" "owner-act: executable-substitution token"
  [ "$(act_count "$dir")" = 0 ] || fail "owner-act: a substituted executable performed an act"

  # (c) Another venue: the same command against a different repository.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    gh-axi pr merge 7 --repo attacker/demo --squash 2>&1); rc=$?
  expect_code 3 "$rc" "owner-act: a substituted repository must refuse: $out"
  assert_contains "$out" "FM_AUTH_ACT_ASSERTION_MISMATCH" "owner-act: venue-substitution token"
  [ "$(act_count "$dir")" = 0 ] || fail "owner-act: a substituted repository performed an act"

  # (d) Another target object.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    gh-axi pr merge 9 --repo owner/demo --squash 2>&1); rc=$?
  expect_code 3 "$rc" "owner-act: a substituted pull request must refuse: $out"
  [ "$(act_count "$dir")" = 0 ] || fail "owner-act: a substituted pull request performed an act"

  # (e) Another mode, and one extra argument the plan never named.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    gh-axi pr merge 7 --repo owner/demo --merge 2>&1); rc=$?
  expect_code 3 "$rc" "owner-act: a substituted merge method must refuse: $out"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    gh-axi pr merge 7 --repo owner/demo --squash --admin 2>&1); rc=$?
  expect_code 3 "$rc" "owner-act: an extra argument must refuse: $out"
  [ "$(act_count "$dir")" = 0 ] || fail "owner-act: a perturbed act was performed"

  # None of the above touched the authority, because none of them was a landing.
  [ "$(run_auth "$dir" status "$id" 2>&1)" = granted ] \
    || fail "owner-act: a refused assertion consumed the authority"

  # Red calibration: the exact assertion lands, once.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- "${ASSERT_ACT[@]}" 2>&1); rc=$?
  expect_code 0 "$rc" "owner-act: the exact asserted act must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "owner-act: the authorised act ran $(act_count "$dir") times"
  grep -qxF 'pr merge 7 --repo owner/demo --squash' "$dir/act.log" \
    || fail "owner-act: the act performed was '$(cat "$dir/act.log")', not the one the plan names"

  # And a caller that names NO act at all still lands exactly the authority's own
  # one, which is the property an assertion can only ever confirm.
  dir=$(new_case owner-constructed-act-unasserted) || fail "owner-act: second fixture failed"
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "owner-act: an unasserted spend must perform the authority's act: $out"
  grep -qxF 'pr merge 7 --repo owner/demo --squash' "$dir/act.log" \
    || fail "owner-act: an unasserted spend performed '$(cat "$dir/act.log")'"
  pass "the act performed is the authority's own, and an asserted act may only agree"
}

# --- 17: a mutable alias resolved at authorization, rechecked at use ---------

test_an_executable_swapped_after_authorization_refuses_at_effect_time() {
  local dir id out rc
  dir=$(new_case swapped-executable) || fail "swapped-exec: fixture failed"
  id=$(mint_id "$dir")

  # The one perturbation: the file at the pinned path is replaced after the
  # authority was granted. The path still resolves and is still executable, so
  # only the content digest can tell.
  cat > "$dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf 'SWAPPED %s\n' "\$*" >> '$dir/act.log'
exit 0
SH
  chmod +x "$dir/fakebin/gh-axi"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "swapped-exec: a replaced executable must refuse: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_PLAN_STALE" "swapped-exec: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "swapped-exec: the replaced executable ran"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = granted ] \
    || fail "swapped-exec: a stale executable consumed the authority"

  # A path that no longer resolves to an executable at all is likewise a refusal
  # rather than a fallback to whatever PATH now offers.
  rm -f "$dir/fakebin/gh-axi"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "swapped-exec: a vanished executable must refuse: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_PLAN_STALE" "swapped-exec: vanished-executable token"

  # Red calibration: restore the exact file the authority pinned and it spends.
  act_stub "$dir"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "swapped-exec: the pinned executable must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "swapped-exec: the pinned executable did not run once"
  pass "an executable swapped after authorization refuses at effect time"
}

# --- 18: an authority that does not determine an act -------------------------

test_an_incomplete_or_unsupported_effect_plan_refuses_before_the_act() {
  local dir id path out rc

  # One required field removed. The authority is otherwise exactly the one that
  # lands, and its own state still says granted.
  dir=$(new_case plan-incomplete) || fail "plan-incomplete: fixture failed"
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  jq 'del(.effect.method)' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "plan-incomplete: a missing plan field must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_PLAN_INCOMPLETE" "plan-incomplete: refusal token"
  assert_contains "$out" "method" "plan-incomplete: the refusal did not name the missing field"
  [ "$(act_count "$dir")" = 0 ] || fail "plan-incomplete: an act ran under an incomplete plan"

  # An effect kind this contract does not perform is a different repair from a
  # missing field, and is never carried through to a pass-through act.
  dir=$(new_case plan-unsupported) || fail "plan-unsupported: fixture failed"
  id=$(mint_id "$dir")
  path="$dir/home/data/landing-authorizations/$id.json"
  jq '.effect.kind = "force-push"' "$path" > "$path.new" && mv "$path.new" "$path"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "plan-unsupported: an unknown effect kind must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_KIND_UNSUPPORTED" "plan-unsupported: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "plan-unsupported: an act ran under an unsupported plan"

  # A mint with no effect plan at all cannot produce an authority.
  dir=$(new_case plan-absent) || fail "plan-absent: fixture failed"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 2>&1); rc=$?
  expect_code 2 "$rc" "plan-absent: minting with no effect plan must be a usage error: $out"
  [ ! -d "$dir/home/data/landing-authorizations" ] \
    || fail "plan-absent: an authority with no effect plan was recorded"

  # A mint declaring an effect this contract does not perform likewise grants
  # nothing rather than recording an act nobody can build.
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 --effect force-push 2>&1); rc=$?
  expect_code 4 "$rc" "plan-absent: an unsupported effect kind must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_KIND_UNSUPPORTED" "plan-absent: unsupported-kind token"

  # Red calibration: the same fixture with a complete, supported plan mints and
  # spends.
  dir=$(new_case plan-control) || fail "plan-control: fixture failed"
  id=$(mint_id "$dir")
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "plan-control: a complete plan must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "plan-control: the complete plan did not run the act once"
  pass "an incomplete or unsupported effect plan refuses before the act"
}

# --- 19: credential-bearing mechanism input ----------------------------------

test_credential_bearing_input_is_refused_before_the_act() {
  local dir id out rc
  dir=$(new_case credential-input) || fail "credential: fixture failed"
  id=$(mint_id "$dir")

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- \
    gh-axi pr merge 7 --repo owner/demo --squash --token ghp_AAAAAAAAAAAAAAAAAAAA 2>&1); rc=$?
  expect_code 3 "$rc" "credential: a token argument must refuse: $out"
  assert_contains "$out" "FM_AUTH_CREDENTIAL_BEARING_INPUT" "credential: refusal token"
  [ "$(act_count "$dir")" = 0 ] || fail "credential: an act ran carrying a credential"

  # A URL carrying userinfo is the same refusal by a different shape.
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 --effect local-fast-forward \
    --project 'https://user:hunter2@example.invalid/repo' --target-branch main 2>&1); rc=$?
  expect_code 3 "$rc" "credential: a credential-bearing project must refuse: $out"
  assert_contains "$out" "FM_AUTH_CREDENTIAL_BEARING_INPUT" "credential: mint refusal token"

  # Red calibration: the same authority, no credential in the assertion, lands.
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" --assert-act -- "${ASSERT_ACT[@]}" 2>&1); rc=$?
  expect_code 0 "$rc" "credential: a credential-free act must spend: $out"
  [ "$(act_count "$dir")" = 1 ] || fail "credential: the credential-free act did not run once"
  pass "credential-bearing mechanism input is refused before the act"
}

# --- 20: one approval, one landing -------------------------------------------
#
# The plan is part of the identity, so a second plan is a second id. That is
# correct for identity and would be wrong for authority if it granted a second
# landing under one approval, so the mint refuses when the same ruling at the
# same head has already been landed.

test_one_approval_grants_one_landing_even_under_a_second_plan() {
  local dir id out rc second
  dir=$(new_case one-landing) || fail "one-landing: fixture failed"
  id=$(mint_id "$dir")

  # A second plan for the same ruling and head is a different authority id, and
  # is minted freely while nothing has landed.
  second=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')
  [ "$second" != "$id" ] \
    || fail "one-landing: two different plans collapsed onto one authorization id"

  run_auth "$dir" spend "$id" --head "$HEAD_A" >/dev/null 2>&1 \
    || fail "one-landing: the first authority did not spend"
  [ "$(act_count "$dir")" = 1 ] || fail "one-landing: the first landing did not happen once"

  # Now that the approval has been landed, a THIRD plan grants nothing.
  out=$(mint_plan "$dir" fm-ob-abcdef123456 --method rebase 2>&1); rc=$?
  expect_code 3 "$rc" "one-landing: re-minting after a landing must refuse: $out"
  assert_contains "$out" "FM_AUTH_RULING_ALREADY_LANDED" "one-landing: refusal token"

  # The already-minted second authority is not a way around it either: the
  # ruling's landing is what is exhausted, not one record.
  out=$(run_auth "$dir" spend "$second" --head "$HEAD_A" 2>&1); rc=$?
  [ "$(act_count "$dir")" = 1 ] \
    || fail "one-landing: one approval performed $(act_count "$dir") landings"
  expect_code 3 "$rc" "one-landing: a sibling authority must refuse after the landing: $out"
  pass "one approval grants one landing, even under a second plan"
}

# --- 21: sibling plans serialize on the ruling -------------------------------

test_concurrent_sibling_plans_share_one_ruling_reservation() {
  local dir first second first_pid second_pid first_rc second_rc combined
  dir=$(new_case concurrent-siblings) || fail "concurrent-siblings: fixture failed"
  first=$(mint_id "$dir")
  second=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')
  arm_blocking_act "$dir"

  run_auth "$dir" spend "$first" --head "$HEAD_A" > "$dir/first.out" 2>&1 &
  first_pid=$!
  fm_test_reap "$first_pid"
  run_auth "$dir" spend "$second" --head "$HEAD_A" > "$dir/second.out" 2>&1 &
  second_pid=$!
  fm_test_reap "$second_pid"

  for _ in $(seq 1 300); do
    [ -e "$dir/act-entered" ] && { ! kill -0 "$first_pid" 2>/dev/null || ! kill -0 "$second_pid" 2>/dev/null; } && break
    sleep 0.01
  done
  [ "$(act_count "$dir")" = 1 ] \
    || fail "concurrent-siblings: concurrent plans entered $(act_count "$dir") acts"
  release_act "$dir"
  wait "$first_pid"; first_rc=$?
  wait "$second_pid"; second_rc=$?
  combined=$(cat "$dir/first.out" "$dir/second.out")

  { [ "$first_rc" -eq 0 ] && [ "$second_rc" -eq 3 ]; } \
    || { [ "$first_rc" -eq 3 ] && [ "$second_rc" -eq 0 ]; } \
    || fail "concurrent-siblings: exits were $first_rc and $second_rc, not one spend and one refusal: $combined"
  assert_contains "$combined" "FM_AUTH_RULING_ALREADY_LANDED" "concurrent-siblings: refusal token"
  if [ "$first_rc" -eq 3 ]; then
    assert_contains "$(cat "$dir/first.out")" "$second" "concurrent-siblings: refusal did not name the holding authorization"
  else
    assert_contains "$(cat "$dir/second.out")" "$first" "concurrent-siblings: refusal did not name the holding authorization"
  fi
  [ "$(act_count "$dir")" = 1 ] \
    || fail "concurrent-siblings: one ruling performed $(act_count "$dir") acts"
  pass "concurrent sibling plans share one ruling reservation"
}

# --- 22: a pre-act signal releases the ruling reservation -------------------

test_a_pre_act_signal_releases_the_ruling_reservation() {
  local dir id sibling job claim owner reservation out rc
  dir=$(new_case signal-before-act) || fail "signal-before-act: fixture failed"
  id=$(mint_id "$dir")
  sibling=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')
  claim="$dir/home/data/landing-authorizations/.$id.claim"
  mkfifo "$dir/receipt" || fail "signal-before-act: receipt fifo failed"

  run_auth "$dir" spend "$id" --head "$HEAD_A" --receipt "$dir/receipt" \
    > "$dir/signalled.out" 2>&1 &
  job=$!
  fm_test_reap "$job"
  for _ in $(seq 1 300); do
    reservation=$(ruling_reservation "$dir" 2>/dev/null) \
      && [ -s "$claim/owner-pid" ] \
      && [ "$(jq -r '.state' "$dir/home/data/landing-authorizations/$id.json")" = granted ] \
      && break
    sleep 0.01
  done
  [ -n "${reservation:-}" ] || fail "signal-before-act: no ruling reservation appeared"
  owner=$(cat "$claim/owner-pid") || fail "signal-before-act: claim owner was unreadable"
  kill -TERM "$owner" || fail "signal-before-act: could not signal spender"
  wait "$job" 2>/dev/null || true
  [ ! -e "$reservation" ] || fail "signal-before-act: signal orphaned $reservation"
  [ "$(act_count "$dir")" = 0 ] || fail "signal-before-act: the signalled spend performed an act"
  rm -f "$dir/receipt"

  out=$(run_auth "$dir" spend "$sibling" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "signal-before-act: the released ruling could not land: $out"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "signal-before-act: the later legitimate spend ran $(act_count "$dir") acts"
  pass "a pre-act signal releases the ruling reservation"
}

# --- 23: a ruling-reservation release failure is observable -----------------

test_a_failed_ruling_reservation_release_is_observable() {
  local dir id job reservation out rc
  dir=$(new_case reservation-release-failure) || fail "reservation-release-failure: fixture failed"
  id=$(mint_id "$dir")
  arm_blocking_act "$dir"
  printf '%s\n' 7 > "$dir/act-rc"

  run_auth "$dir" spend "$id" --head "$HEAD_A" > "$dir/release-failure.out" 2>&1 &
  job=$!
  fm_test_reap "$job"
  for _ in $(seq 1 300); do
    reservation=$(ruling_reservation "$dir" 2>/dev/null) \
      && [ -e "$dir/act-entered" ] \
      && break
    sleep 0.01
  done
  [ -n "${reservation:-}" ] || fail "reservation-release-failure: no ruling reservation appeared"
  : > "$reservation/release-blocker" \
    || fail "reservation-release-failure: could not arm release failure"
  release_act "$dir"
  wait "$job"; rc=$?
  out=$(cat "$dir/release-failure.out")
  expect_code 4 "$rc" "reservation-release-failure: release failure was not could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_INTENT_UNRECORDABLE" "reservation-release-failure: token"
  assert_contains "$out" "$reservation" "reservation-release-failure: path"
  assert_contains "$out" "exited 7" "reservation-release-failure: act outcome"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "reservation-release-failure: the indeterminate act ran $(act_count "$dir") times"
  rm -f "$reservation/release-blocker"
  rmdir "$reservation" || fail "reservation-release-failure: fixture cleanup failed"
  pass "a failed ruling reservation release is observable"
}

# --- 24: an orphaned granted reservation requires evidence ------------------

test_an_orphaned_granted_reservation_is_reconciled_from_evidence() {
  local dir id sibling out rc reservation
  dir=$(new_case orphaned-grant) || fail "orphaned-grant: fixture failed"
  id=$(mint_id "$dir")
  sibling=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')
  orphan_granted_reservation "$dir" "$id" \
    || fail "orphaned-grant: could not create the crash state"
  reservation=$ORPHAN_RESERVATION

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied 2>&1); rc=$?
  expect_code 2 "$rc" "orphaned-grant: reconciliation without evidence settled the reservation: $out"
  [ -d "$reservation" ] || fail "orphaned-grant: evidence-free reconciliation released the reservation"
  out=$(run_auth "$dir" spend "$sibling" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "orphaned-grant: a sibling passed the unsettled reservation: $out"
  [ "$(act_count "$dir")" = 0 ] || fail "orphaned-grant: an unsettled sibling performed an act"

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied \
    --evidence 'pr 7 has no merge commit' 2>&1); rc=$?
  expect_code 0 "$rc" "orphaned-grant: evidence did not settle the absent effect: $out"
  [ ! -e "$reservation" ] || fail "orphaned-grant: not-applied settlement kept the reservation"
  out=$(run_auth "$dir" spend "$sibling" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "orphaned-grant: the ruling was not landable after settlement: $out"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "orphaned-grant: the recovered ruling performed $(act_count "$dir") acts"

  dir=$(new_case orphaned-grant-applied) || fail "orphaned-grant-applied: fixture failed"
  id=$(mint_id "$dir")
  sibling=$(mint_plan "$dir" fm-ob-abcdef123456 --delete-branch | awk '{print $1}')
  orphan_granted_reservation "$dir" "$id" \
    || fail "orphaned-grant-applied: could not create the crash state"
  reservation=$ORPHAN_RESERVATION
  out=$(run_auth "$dir" reconcile "$id" --observed applied \
    --evidence 'pr 7 shows the approved merge' 2>&1); rc=$?
  expect_code 0 "$rc" "orphaned-grant-applied: evidence did not settle the applied effect: $out"
  [ -d "$reservation" ] || fail "orphaned-grant-applied: applied settlement released the reservation"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = spent ] \
    || fail "orphaned-grant-applied: applied settlement did not exhaust the authorization"
  out=$(run_auth "$dir" spend "$sibling" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 3 "$rc" "orphaned-grant-applied: a sibling passed the applied settlement: $out"
  [ "$(act_count "$dir")" = 0 ] || fail "orphaned-grant-applied: a second act ran"
  pass "an orphaned granted reservation is reconciled from evidence"
}

# --- 25: a live granted reservation is not reclaimed ------------------------

test_a_live_granted_reservation_is_not_reclaimed() {
  local dir id claim job owner reservation out rc reader
  dir=$(new_case live-granted-reservation) || fail "live-granted-reservation: fixture failed"
  id=$(mint_id "$dir")
  claim="$dir/home/data/landing-authorizations/.$id.claim"
  mkfifo "$dir/live-receipt" || fail "live-granted-reservation: receipt fifo failed"
  run_auth "$dir" spend "$id" --head "$HEAD_A" --receipt "$dir/live-receipt" \
    > "$dir/live-granted-spend.out" 2>&1 &
  job=$!
  fm_test_reap "$job"
  for _ in $(seq 1 300); do
    reservation=$(ruling_reservation "$dir" 2>/dev/null) \
      && [ -s "$claim/owner-pid" ] \
      && [ "$(jq -r '.state' "$dir/home/data/landing-authorizations/$id.json")" = granted ] \
      && break
    sleep 0.01
  done
  [ -n "${reservation:-}" ] || fail "live-granted-reservation: no reservation appeared"
  owner=$(cat "$claim/owner-pid") || fail "live-granted-reservation: claim owner was unreadable"
  kill -0 "$owner" || fail "live-granted-reservation: holder was not live"

  out=$(run_auth "$dir" reconcile "$id" --observed not-applied \
    --evidence 'forge has not yet reported applied' 2>&1); rc=$?
  expect_code 4 "$rc" "live-granted-reservation: reconciliation reclaimed a live holder: $out"
  assert_contains "$out" "still exists" "live-granted-reservation: liveness refusal"
  [ -d "$reservation" ] || fail "live-granted-reservation: reconciliation released the live reservation"

  (cat "$dir/live-receipt" >/dev/null; cat "$dir/live-receipt" >/dev/null) &
  reader=$!
  fm_test_reap "$reader"
  wait "$job" || fail "live-granted-reservation: holder did not complete normally"
  wait "$reader" || fail "live-granted-reservation: receipt reader failed"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "live-granted-reservation: holder performed $(act_count "$dir") acts"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = spent ] \
    || fail "live-granted-reservation: holder did not record success"
  pass "a live granted reservation is not reclaimed"
}

# --- 26: a non-zero act is not "no effect" -----------------------------------

test_an_act_that_exits_non_zero_leaves_the_authority_indeterminate() {
  local dir id out rc
  dir=$(new_case nonzero-act) || fail "nonzero-act: fixture failed"
  id=$(mint_id "$dir")
  printf '%s\n' 7 > "$dir/act-rc"

  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "nonzero-act: a failed act must be could-not-observe: $out"
  assert_contains "$out" "FM_AUTH_SPEND_INDETERMINATE" "nonzero-act: refusal token"
  [ "$(act_count "$dir")" = 1 ] || fail "nonzero-act: the act did not run once"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = indeterminate ] \
    || fail "nonzero-act: a failed act left the authority determinate"

  # A retry does not reconstruct a different act, and does not reconstruct the
  # same one either: the authority stays indeterminate until an observation
  # settles it.
  rm -f "$dir/act-rc"
  out=$(run_auth "$dir" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "nonzero-act: retrying an indeterminate spend must refuse: $out"
  [ "$(act_count "$dir")" = 1 ] \
    || fail "nonzero-act: a retry performed a second act under an indeterminate authority"
  pass "an act that exits non-zero leaves the authority indeterminate"
}

# --- 27: a moved project alias cannot retarget the local act -----------------

test_a_project_alias_moved_after_mint_performs_no_act() {
  local dir original replacement alias head original_before replacement_before id out rc record
  dir=$(new_case moved-project-alias) || fail "moved-project-alias: fixture failed"
  original="$dir/original"
  replacement="$dir/replacement"
  alias="$dir/project"
  git init -q -b main "$original" || fail "moved-project-alias: original repository failed"
  git -C "$original" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m base || fail "moved-project-alias: original base failed"
  git -C "$original" checkout -q -b work || fail "moved-project-alias: original branch failed"
  git -C "$original" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m work || fail "moved-project-alias: original work failed"
  head=$(git -C "$original" rev-parse HEAD)
  git -C "$original" checkout -q main || fail "moved-project-alias: original checkout failed"
  git clone -q "$original" "$replacement" || fail "moved-project-alias: replacement repository failed"
  git -C "$replacement" checkout -q main || fail "moved-project-alias: replacement checkout failed"
  original_before=$(git -C "$original" rev-parse main)
  replacement_before=$(git -C "$replacement" rev-parse main)
  ln -s "$original" "$alias" || fail "moved-project-alias: alias creation failed"
  record=$(corr_path "$dir")
  jq --arg head "$head" '.identity.head = $head' "$record" > "$record.next" \
    || fail "moved-project-alias: correlation update failed"
  mv "$record.next" "$record"
  printf '%s\n' "$head" > "$dir/forge_head"

  out=$(run_auth "$dir" mint fm-ob-abcdef123456 --effect local-fast-forward \
    --project "$alias" --target-branch main --assert-head "$head" 2>&1); rc=$?
  expect_code 0 "$rc" "moved-project-alias: mint failed: $out"
  id=$(printf '%s' "$out" | awk '{print $1}')
  rm "$alias"
  ln -s "$replacement" "$alias" || fail "moved-project-alias: alias repoint failed"

  out=$(run_auth "$dir" spend "$id" --head "$head" 2>&1); rc=$?
  expect_code 3 "$rc" "moved-project-alias: a repointed alias must refuse: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_PLAN_STALE" "moved-project-alias: refusal token"
  [ "$(git -C "$original" rev-parse main)" = "$original_before" ] \
    || fail "moved-project-alias: the pinned repository landed despite refusal"
  [ "$(git -C "$replacement" rev-parse main)" = "$replacement_before" ] \
    || fail "moved-project-alias: the replacement repository was retargeted"
  pass "a project alias moved after mint performs no act"
}

# --- 28: a moved target ref cannot silently retarget the local act -----------

test_a_target_ref_moved_after_mint_performs_no_act() {
  local dir project base middle head record id out rc
  dir=$(new_case moved-target-ref) || fail "moved-target-ref: fixture failed"
  project="$dir/project"
  git init -q -b main "$project" || fail "moved-target-ref: repository failed"
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m base || fail "moved-target-ref: base failed"
  base=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q -b work || fail "moved-target-ref: work branch failed"
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m middle || fail "moved-target-ref: middle failed"
  middle=$(git -C "$project" rev-parse HEAD)
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m head || fail "moved-target-ref: head failed"
  head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q main || fail "moved-target-ref: main checkout failed"

  record=$(corr_path "$dir")
  jq --arg head "$head" '.identity.head = $head' "$record" > "$record.next" \
    || fail "moved-target-ref: correlation update failed"
  mv "$record.next" "$record"
  printf '%s\n' "$head" > "$dir/forge_head"
  out=$(run_auth "$dir" mint fm-ob-abcdef123456 --effect local-fast-forward \
    --project "$project" --target-branch main --assert-head "$head" 2>&1); rc=$?
  expect_code 0 "$rc" "moved-target-ref: mint failed: $out"
  id=$(printf '%s' "$out" | awk '{print $1}')
  jq -e --arg base "$base" '.effect.target_head == $base' \
    "$dir/home/data/landing-authorizations/$id.json" >/dev/null \
    || fail "moved-target-ref: the plan did not pin the target ref's mint-time object"

  # The alias now names another commit which is still an ancestor of the approved
  # head. An ancestry-only freshness check would silently accept this retarget.
  git -C "$project" update-ref refs/heads/main "$middle" "$base" \
    || fail "moved-target-ref: target ref move failed"
  out=$(run_auth "$dir" spend "$id" --head "$head" 2>&1); rc=$?
  expect_code 3 "$rc" "moved-target-ref: a moved target ref must refuse: $out"
  assert_contains "$out" "FM_AUTH_EFFECT_PLAN_STALE" "moved-target-ref: refusal token"
  [ "$(git -C "$project" rev-parse main)" = "$middle" ] \
    || fail "moved-target-ref: the protected fast-forward ran after the ref moved"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = granted ] \
    || fail "moved-target-ref: a stale ref consumed the authority"
  pass "a target ref moved after mint performs no act"
}

# --- 29: successful exit still needs post-effect proof -----------------------

test_successful_exit_requires_post_effect_proof() {
  local confirmed unconfirmed id out rc evidence
  confirmed=$(new_case post-effect-confirmed) || fail "post-effect: confirmed fixture failed"
  id=$(mint_id "$confirmed")
  out=$(run_auth "$confirmed" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 0 "$rc" "post-effect: confirmed spend failed: $out"
  [ "$(act_count "$confirmed")" = 1 ] || fail "post-effect: confirmed act did not run once"
  evidence=$(jq -r '.spend.evidence // ""' \
    "$confirmed/home/data/landing-authorizations/$id.json")
  [ "$evidence" = "pr-merge merged=true head=$HEAD_A" ] \
    || fail "post-effect: confirmed evidence was '$evidence'"

  unconfirmed=$(new_case post-effect-unconfirmed) || fail "post-effect: unconfirmed fixture failed"
  id=$(mint_id "$unconfirmed")
  printf '%s\n' FAIL > "$unconfirmed/forge_merged"
  out=$(run_auth "$unconfirmed" spend "$id" --head "$HEAD_A" 2>&1); rc=$?
  expect_code 4 "$rc" "post-effect: unconfirmed success must be indeterminate: $out"
  assert_contains "$out" "FM_AUTH_SPEND_INDETERMINATE" "post-effect: indeterminate token"
  [ "$(act_count "$unconfirmed")" = 1 ] || fail "post-effect: unconfirmed act did not run once"
  [ "$(run_auth "$unconfirmed" status "$id" 2>&1)" = indeterminate ] \
    || fail "post-effect: unconfirmed act was recorded as applied"
  evidence=$(jq -r '.spend.evidence // ""' \
    "$unconfirmed/home/data/landing-authorizations/$id.json")
  [ "$evidence" = "pr-merge merged=unobserved head=unobserved" ] \
    || fail "post-effect: unconfirmed evidence was '$evidence'"
  pass "successful exit requires post-effect proof"
}

# --- 30: the real path, end to end -------------------------------------------
#
# Everything above stubs the effect so it can be counted. This one does not: a
# ruled correlation record mints a `local-fast-forward` plan, the spend builds the
# act from that plan, and the act is REAL git advancing a REAL branch in a scratch
# repository created for this case. The proof is the repository's own state
# afterwards, read back with git rather than from anything this mechanism wrote.

test_the_whole_path_lands_one_real_fast_forward_and_proves_it() {
  local dir project head before after out rc id plan

  # The scratch repository. Created here, never reused, and never any checkout
  # this suite did not make.
  dir="$TMP_ROOT/real-path"
  mkdir -p "$dir/home/data/outbound-artifacts" "$dir/fakebin" || fail "real-path: fixture failed"
  project="$dir/project"
  git init -q -b main "$project" || fail "real-path: could not create the scratch repository"
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m base || fail "real-path: base commit failed"
  before=$(git -C "$project" rev-parse main)
  git -C "$project" checkout -q -b fm/demo-item || fail "real-path: branch failed"
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    -c commit.gpgsign=false commit -q --allow-empty -m work || fail "real-path: work commit failed"
  head=$(git -C "$project" rev-parse HEAD)
  git -C "$project" checkout -q main || fail "real-path: returning to main failed"

  # The published head an outside reviewer ruled on is this branch head, which is
  # what makes the local landing the one the ruling approved.
  printf '%s\n' "$head" > "$dir/forge_head"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *" [.merged, .head.sha] "* ]]; then
  printf 'true\t'
fi
cat "$FM_TEST_FORGE_HEAD"
SH
  chmod +x "$dir/fakebin/gh"
  jq -n --arg head "$head" \
    '{schema:"fm-outbound-artifact.v1",
      request_id:"fm-ob-abcdef123456",
      channel:"sol-control",
      identity:{gate:"EXACT_HEAD_BROWSER_REVIEW_REQUIRED",project:"demo-project",
                repo:"owner/control",item:"demo-item",
                pr:"https://github.com/owner/demo/pull/7",head:$head},
      venue:"owner/control#2",state:"ruled",comment_id:"900",attempts:1,
      created:"2026-08-17T00:00:00Z",updated:"2026-08-17T00:00:00Z",
      ruling:{comment_id:"901",verdict:"accepted",observed:"2026-08-17T01:00:00Z"},
      resumed:null,disposition:null,superseded_by:null}' \
    > "$dir/home/data/outbound-artifacts/fm-ob-abcdef123456.json" \
    || fail "real-path: correlation record failed"

  out=$(run_auth "$dir" mint fm-ob-abcdef123456 --effect local-fast-forward \
    --project "$project" --target-branch main --assert-head "$head" 2>&1); rc=$?
  expect_code 0 "$rc" "real-path: minting the plan: $out"
  id=$(printf '%s' "$out" | awk '{print $1}')
  fm_auth_id_shape "$id" || fail "real-path: mint printed no authorization id: $out"

  # The plan is closed: it names the executable by path and digest, the project by
  # a resolved identity, the ref, the exact object, ff-only, and non-force.
  plan=$(jq -r '[.effect.kind,.effect.target_ref,.effect.target_head,.effect.head,.effect.mode,
                 (.effect.force|tostring),.effect.executable_name] | join(" ")' \
    "$dir/home/data/landing-authorizations/$id.json")
  [ "$plan" = "local-fast-forward refs/heads/main $before $head ff-only false git" ] \
    || fail "real-path: the minted plan is '$plan'"
  jq -e '.effect.executable_path | startswith("/")' \
    "$dir/home/data/landing-authorizations/$id.json" >/dev/null \
    || fail "real-path: the plan did not pin an absolute executable path"
  jq -e '.effect.executable_digest | test("^[0-9a-f]{64}$")' \
    "$dir/home/data/landing-authorizations/$id.json" >/dev/null \
    || fail "real-path: the plan did not pin an executable digest"

  # main has not moved yet, so the fast-forward below is attributable.
  [ "$(git -C "$project" rev-parse main)" = "$before" ] \
    || fail "real-path: the scratch repository moved before the landing"

  out=$(run_auth "$dir" spend "$id" --head "$head" --receipt "$dir/receipt" \
    --assert-act -- git -C "$project" merge --ff-only --quiet "$head" 2>&1); rc=$?
  expect_code 0 "$rc" "real-path: spending the authority: $out"
  assert_contains "$out" "spent:" "real-path: the spend did not report itself spent"

  # POST-EFFECT PROOF, read from the repository rather than from the record.
  after=$(git -C "$project" rev-parse main)
  [ "$after" = "$head" ] \
    || fail "real-path: main is at $after, not the authorized $head"
  [ "$after" != "$before" ] || fail "real-path: main never moved, so nothing landed"
  [ "$(cat "$dir/receipt")" = entered ] \
    || fail "real-path: the act receipt does not record that the act was reached"
  [ "$(run_auth "$dir" status "$id" 2>&1)" = spent ] \
    || fail "real-path: the authority was not exhausted by the landing it performed"

  # And the landing is not repeatable.
  out=$(run_auth "$dir" spend "$id" --head "$head" 2>&1); rc=$?
  expect_code 0 "$rc" "real-path: a replayed spend must converge: $out"
  assert_contains "$out" "FM_AUTH_ALREADY_SPENT" "real-path: the authority was not exhausted"
  pass "the whole path lands one real fast-forward and proves it from the repository"
}

# --- run ---------------------------------------------------------------------

run_test_batch() {  # <test-function>...
  local test job output
  local -a jobs=() outputs=()
  for test in "$@"; do
    output="$TMP_ROOT/run-$test.out"
    ( "$test" ) > "$output" 2>&1 &
    job=$!
    fm_test_reap "$job"
    jobs+=("$job")
    outputs+=("$output")
  done
  for test in "$@"; do
    job=${jobs[0]}
    output=${outputs[0]}
    jobs=("${jobs[@]:1}")
    outputs=("${outputs[@]:1}")
    if ! wait "$job"; then
      cat "$output" >&2
      fail "$test failed"
    fi
    cat "$output"
    FM_TEST_PASSED_TESTS="${FM_TEST_PASSED_TESTS:-}${test}"$'\n'
  done
}

run_test_batch \
  test_a_fresh_authorization_is_minted_and_spent_exactly_once \
  test_a_second_spend_is_refused_and_performs_no_act \
  test_a_head_other_than_the_approved_one_is_refused \
  test_a_moved_forge_head_is_refused_even_when_the_caller_states_the_approved_head \
  test_a_restart_inside_the_spend_window_leaves_a_determinable_state \
  test_an_authorization_for_a_superseded_request_is_refused \
  test_minting_requires_a_ruled_request_and_an_authorizing_verdict \
  test_minting_the_same_ruling_twice_grants_one_authorization
run_test_batch \
  test_a_correlation_record_filed_under_another_id_is_refused \
  test_an_unobservable_head_stops_the_spend_without_destroying_the_authorization \
  test_a_spend_already_in_flight_is_refused \
  test_concurrent_spends_revalidate_after_claiming \
  test_concurrent_mints_cannot_replace_a_spent_record \
  test_a_partial_enumeration_is_could_not_observe_rather_than_a_short_list \
  test_reconciliation_cannot_reclaim_a_live_spenders_authorization \
  test_malformed_authorization_ids_cannot_address_the_store
run_test_batch \
  test_malformed_or_misbound_authorization_records_are_unreadable \
  test_the_act_is_the_authoritys_own_and_an_assertion_may_only_agree \
  test_an_executable_swapped_after_authorization_refuses_at_effect_time \
  test_an_incomplete_or_unsupported_effect_plan_refuses_before_the_act \
  test_credential_bearing_input_is_refused_before_the_act \
  test_one_approval_grants_one_landing_even_under_a_second_plan \
  test_concurrent_sibling_plans_share_one_ruling_reservation \
  test_a_pre_act_signal_releases_the_ruling_reservation
run_test_batch \
  test_a_failed_ruling_reservation_release_is_observable \
  test_an_orphaned_granted_reservation_is_reconciled_from_evidence \
  test_a_live_granted_reservation_is_not_reclaimed \
  test_an_act_that_exits_non_zero_leaves_the_authority_indeterminate \
  test_a_project_alias_moved_after_mint_performs_no_act \
  test_a_target_ref_moved_after_mint_performs_no_act \
  test_successful_exit_requires_post_effect_proof \
  test_the_whole_path_lands_one_real_fast_forward_and_proves_it

fm_test_contract "$0"
