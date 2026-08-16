#!/usr/bin/env bash
# Behavior tests for bin/fm-outbound-artifact.sh - the OUTBOUND transport
# invariant: an item may not remain in a state implying an outstanding outbound
# artifact while no applicable durable artifact exists.
#
# WATCHED-RED DISCIPLINE. Every control here is driven to RED first, for its
# intended reason, and only then to green from the opposite structured state. A
# control that only ever answers one way enforces nothing, and this fleet has
# already shipped a probe that failed unconditionally while measuring nothing.
# So each case asserts BOTH the red verdict AND its specific token, because a red
# reached for the wrong reason is not the control anyone thought they had.
#
# The seven controls the task contract names, each paired here with its negative:
#   1. review-required with no control request goes RED
#   2. an exact head change makes the previous request inapplicable
#   3. one scheduler cycle cannot create duplicate requests
#   4. a transient forge failure retries without losing the request
#   5. a ruling wakes the exact waiting item
#   6. an UNRELATED ruling cannot wake that item
#   7. disposition and closure complete the correlation
#
# The forge is a PATH shim, so every case drives the real code path - the real
# identity digest, the real record writes, the real retry loop - and only the
# network is fake. Fleet state is a canned fm-fleet-snapshot.v1 document through
# FM_OUTBOUND_SNAPSHOT, so no case depends on a live fleet or a spawned worker.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-outbound-artifact-tests)

command -v jq >/dev/null 2>&1 || { printf 'skip: jq not found\n'; exit 0; }

OB="$ROOT/bin/fm-outbound-artifact.sh"

# --- fixtures ---------------------------------------------------------------

HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222

make_home() {  # <name> -> prints home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/config" "$home/state" "$home/projects"
  printf '%s\n' "$home"
}

# One item at a Browser Sol review gate with a pull request, and one ordinary
# queued row that must never be flagged. The ordinary row is the fixture's own
# negative control: a sweep that flags everything is as useless as one that
# flags nothing.
write_snapshot() {  # <path> [<hold-kind>] [<hold-reason>]
  local path=$1
  local kind=${2:-external}
  local reason=${3:-SUBMITTED FOR INDEPENDENT REVIEW as SOL-FM-X-001}
  jq -n --arg kind "$kind" --arg reason "$reason" '
    {schema:"fm-fleet-snapshot.v1",
     backlog:{present:true,records:[
       {order:1,state:"queued",structured:true,id:"waiting-item",
        title:"needs independent review",hold_kind:$kind,hold_reason:$reason,
        repo:"demo",pr_url:"https://github.com/o/r/pull/4",body_excerpt:null},
       {order:2,state:"queued",structured:true,id:"ordinary-item",
        title:"ordinary queued work",hold_kind:null,hold_reason:null,
        repo:"demo",pr_url:null,body_excerpt:null}]}}' > "$path"
}

configure_venue() {  # <home>
  printf '{"repo":"o/control","issue":2}\n' > "$1/config/sol-control.json"
}

# The forge shim. Behavior is driven entirely by files in its own state dir, so a
# case can change what the forge does between two invocations of the command
# under test - which is what makes the retry and crash-recovery cases real.
#
#   head            the sha reported for pull request 4
#   comments        one "<id> <body-substring>" per line, the issue's comments
#   fail_remaining  N post attempts fail before any succeed
#   post_log        appended once per POST that the shim accepted
make_gh() {  # <dir>
  mkdir -p "$1/bin" "$1/forge"
  printf '%s\n' "$HEAD_A" > "$1/forge/head"
  : > "$1/forge/comments"
  printf '0\n' > "$1/forge/fail_remaining"
  : > "$1/forge/post_log"
  cat > "$1/bin/gh" <<'SH'
#!/usr/bin/env bash
# Minimal gh api shim: pull request head reads, issue comment listing, and
# comment creation with a scripted failure budget.
F="$FORGE_DIR"
path=
for a in "$@"; do case $a in repos/*) path=$a ;; esac; done
is_post=0
case " $* " in *" --input "*) is_post=1 ;; esac

case "$path" in
  */pulls/4)
    cat "$F/head"; exit 0 ;;
  */issues/*/comments)
    if [ "$is_post" = 1 ]; then
      body=$(cat)
      left=$(cat "$F/fail_remaining" 2>/dev/null || echo 0)
      if [ "$left" -gt 0 ]; then
        printf '%s\n' "$((left - 1))" > "$F/fail_remaining"
        echo "simulated transport failure" >&2
        exit 1
      fi
      rid=$(printf '%s' "$body" | sed -n 's/.*\(fm-ob-[0-9a-f]*\).*/\1/p' | head -1)
      id=$(( $(wc -l < "$F/comments") + 900 ))
      printf '%s %s\n' "$id" "$rid" >> "$F/comments"
      printf 'posted %s\n' "$rid" >> "$F/post_log"
      printf '{"id":%s}\n' "$id"
      exit 0
    fi
    # Listing: --jq carries a contains("<rid>") filter; honour it literally.
    want=
    prev=
    for a in "$@"; do
      case $prev in --jq) want=$(printf '%s' "$a" | sed -n 's/.*contains("\([^"]*\)").*/\1/p') ;; esac
      prev=$a
    done
    while read -r id rid; do
      [ -n "$id" ] || continue
      if [ -z "$want" ] || [ "$rid" = "$want" ]; then printf '%s\n' "$id"; fi
    done < "$F/comments"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/bin/gh"
}

# Run the command under test against one case directory.
run_ob() {  # <case-dir> <args...>
  local dir=$1; shift
  PATH="$dir/bin:$PATH" FORGE_DIR="$dir/forge" \
    FM_HOME="$dir/home" FM_OUTBOUND_SNAPSHOT="$dir/snap.json" \
    FM_OUTBOUND_BACKOFF_BASE=0 \
    "$OB" "$@"
}

new_case() {  # <name> -> prints case dir
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  make_gh "$dir"
  make_home "$1/home" >/dev/null
  configure_venue "$dir/home"
  write_snapshot "$dir/snap.json"
  printf '%s\n' "$dir"
}

set_head() { printf '%s\n' "$2" > "$1/forge/head"; }

# --- control 1: waiting with no request goes RED ----------------------------

test_no_request_is_red() {
  local dir out rc
  dir=$(new_case c1)
  # RED: the item is at a review gate and the forge holds no request for it.
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 1: expected defect exit 3, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "control 1: red for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'waiting-item' \
    || fail "control 1: the waiting item was not named: $out"
  # The sweep must not flag the ordinary row - a control that flags everything
  # proves nothing about the one it was built for.
  printf '%s' "$out" | grep -q 'ordinary-item' \
    && fail "control 1: an ordinary queued row was flagged: $out"
  pass "control 1 RED: a review-required item with no request is a defect"
}

test_request_present_is_green() {
  local dir out rc
  dir=$(new_case c1n)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "control 1 negative: emit failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 1 negative: expected 0 once requested, got $rc: $out"
  printf '%s' "$out" | grep -q '1 satisfied' \
    || fail "control 1 negative: not reported satisfied: $out"
  pass "control 1 GREEN: the same item with a request on the forge is satisfied"
}

# --- control 2: an exact head change invalidates the previous request --------

test_head_change_invalidates() {
  local dir out rc before
  dir=$(new_case c2)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 2: emit failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 2: precondition not green, got $rc: $out"
  before=$(cat "$dir/forge/comments")

  # The reviewed head moves. The old request still exists on the forge and is
  # untouched; it simply no longer describes this item.
  set_head "$dir" "$HEAD_B"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 2: a moved head did not go red, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_STALE_HEAD' \
    || fail "control 2: red for the wrong reason: $out"
  [ "$(cat "$dir/forge/comments")" = "$before" ] \
    || fail "control 2: the previous request was mutated rather than left inapplicable"
  pass "control 2 RED: a moved head makes the previous request inapplicable"
}

test_head_change_fresh_request_is_green() {
  local dir out rc first second
  dir=$(new_case c2n)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 2 negative: emit failed"
  first=$(awk '{print $2}' "$dir/forge/comments" | head -1)
  set_head "$dir" "$HEAD_B"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 \
    || fail "control 2 negative: fresh emit failed"
  second=$(awk '{print $2}' "$dir/forge/comments" | tail -1)
  [ "$first" != "$second" ] \
    || fail "control 2 negative: the new head reused the old request id ($first)"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 2 negative: fresh request not accepted, got $rc: $out"
  pass "control 2 GREEN: the moved head generates a fresh request with a new identity"
}

# --- control 3: one scheduler cycle cannot duplicate -------------------------

test_no_duplicate_requests() {
  local dir posts out
  dir=$(new_case c3)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3: first emit failed"
  # Five further cycles at the same identity, exactly as a repeating scheduler
  # would produce.
  for _ in 1 2 3 4 5; do
    out=$(run_ob "$dir" emit waiting-item 2>&1) \
      || fail "control 3: repeat emit errored: $out"
    printf '%s' "$out" | grep -q 'already requested' \
      || fail "control 3: a repeat emit did not report the existing request: $out"
  done
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 3: $posts requests posted for one identity, expected 1"
  pass "control 3: six cycles at one identity posted exactly one request"
}

test_duplicate_control_can_fail() {
  local dir posts
  dir=$(new_case c3n)
  # The negative control for the DEDUPE MECHANISM itself: with the forge unable
  # to report existing comments, the mechanism has nothing to dedupe against and
  # a second post appears. Watching this go wrong is what proves the passing case
  # is the dedupe working rather than the shim never posting twice at all.
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3 negative: emit failed"
  : > "$dir/forge/comments"          # the forge forgets the request
  rm -f "$dir/home/data/outbound-artifacts"/*.json
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 3 negative: emit failed"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 2 ] \
    || fail "control 3 negative: expected the un-dedupable case to post twice, got $posts"
  pass "control 3 NEGATIVE: with no observable prior request the same path does post again"
}

# --- control 4: transport failure retries without losing the request ---------

test_transient_failure_retries() {
  local dir out posts state
  dir=$(new_case c4)
  printf '2\n' > "$dir/forge/fail_remaining"   # two failures, then success
  out=$(run_ob "$dir" emit waiting-item 2>&1) \
    || fail "control 4: emit gave up on a transient failure: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 4: expected exactly one accepted post, got $posts"
  state=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.state')
  [ "$state" = "emitted" ] || fail "control 4: record state is $state, expected emitted"
  pass "control 4 GREEN: two transient failures retried through to one request"
}

test_exhausted_transport_keeps_the_request() {
  local dir out rc attempts state
  dir=$(new_case c4n)
  # RED: every attempt fails. The request must NOT be lost, and the item must NOT
  # be reported as satisfied - the two ways this could quietly go wrong.
  printf '99\n' > "$dir/forge/fail_remaining"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "control 4 negative: expected unevaluable exit 4, got $rc: $out"
  printf '%s' "$out" | grep -q 'NOT lost' \
    || fail "control 4 negative: exhaustion did not report the checkpoint: $out"
  attempts=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.attempts')
  [ "$attempts" -eq 3 ] || fail "control 4 negative: recorded $attempts attempts, expected 3"
  state=$(cat "$dir/home/data/outbound-artifacts"/*.json | jq -r '.state')
  [ "$state" = "emitting" ] \
    || fail "control 4 negative: a failed transport left state $state, not the emitting checkpoint"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 4 negative: item not still red after a failed emit, got $rc"
  pass "control 4 RED: an exhausted transport keeps the checkpoint and leaves the item red"
}

test_crash_recovery_adopts_its_own_request() {
  local dir posts state
  dir=$(new_case c4r)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 4 recovery: emit failed"
  # Simulate a crash between the accepted post and the success write: the record
  # is left at the pre-transport checkpoint while the forge already holds the
  # request. Recovery must adopt it, never post a second one.
  local f
  f=$(ls "$dir/home/data/outbound-artifacts"/*.json | head -1)
  jq '.state = "emitting" | .comment_id = null' "$f" > "$f.x" && mv "$f.x" "$f"
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 4 recovery: recovery emit failed"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 1 ] || fail "control 4 recovery: recovery posted again ($posts total)"
  state=$(jq -r '.state' "$f")
  [ "$state" = "emitted" ] || fail "control 4 recovery: record left at $state, expected emitted"
  pass "control 4 RECOVERY: a crashed emit adopts its own posted request instead of duplicating"
}

# --- controls 5-7: correlation ----------------------------------------------

emitted_request_id() {  # <case-dir>
  jq -r '.request_id' "$(ls "$1/home/data/outbound-artifacts"/*.json | head -1)"
}

test_ruling_wakes_the_exact_item() {
  local dir rid out
  dir=$(new_case c5)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 5: emit failed"
  rid=$(emitted_request_id "$dir")
  out=$(run_ob "$dir" ruling --request "$rid" --comment 555 --issue 2 2>&1) \
    || fail "control 5: ruling refused its own request: $out"
  printf '%s' "$out" | grep -q 'wakes waiting-item' \
    || fail "control 5: the ruling did not name the waiting item: $out"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.ruling.comment_id')" = "555" ] \
    || fail "control 5: the ruling was not correlated onto the request"
  pass "control 5: a ruling on the request wakes exactly the item that asked"
}

test_unrelated_ruling_cannot_wake_the_item() {
  local dir rid out rc
  dir=$(new_case c6)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 6: emit failed"
  rid=$(emitted_request_id "$dir")

  # RED 1: a ruling for an identity nobody asked under.
  out=$(run_ob "$dir" ruling --request fm-ob-deadbeefcafe --comment 777 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: an unknown request id was accepted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RULING_IDENTITY_MISMATCH' \
    || fail "control 6: refused for the wrong reason: $out"

  # RED 2: the right request, but a ruling that arrived on a different issue.
  out=$(run_ob "$dir" ruling --request "$rid" --comment 778 --issue 99 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 6: a foreign-issue ruling was accepted, exit $rc: $out"

  # Neither refusal may have touched the record.
  [ "$(run_ob "$dir" show "$rid" | jq -r '.ruling')" = "null" ] \
    || fail "control 6: an unrelated ruling mutated the waiting item's record"
  [ "$(run_ob "$dir" show "$rid" | jq -r '.state')" = "emitted" ] \
    || fail "control 6: an unrelated ruling advanced the request's state"
  pass "control 6 RED: an unrelated ruling refuses and cannot wake the waiting item"
}

test_disposition_completes_the_correlation() {
  local dir rid rec out rc
  dir=$(new_case c7)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 7: emit failed"
  rid=$(emitted_request_id "$dir")

  # RED: closure cannot skip the chain. An emitted-but-unruled request has no
  # outcome to record, so closing it must refuse.
  out=$(run_ob "$dir" close --request "$rid" --disposition approved 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 7: closure skipped the ruling step, exit $rc: $out"

  run_ob "$dir" ruling --request "$rid" --comment 555 >/dev/null 2>&1 \
    || fail "control 7: ruling failed"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 || fail "control 7: resume failed"
  run_ob "$dir" close --request "$rid" --disposition approved >/dev/null 2>&1 \
    || fail "control 7: close failed"

  rec=$(run_ob "$dir" show "$rid")
  [ "$(printf '%s' "$rec" | jq -r '.state')" = "closed" ] \
    || fail "control 7: final state is not closed"
  [ "$(printf '%s' "$rec" | jq -r '.identity.item')" = "waiting-item" ] \
    || fail "control 7: the closed record lost the item it correlates to"
  [ "$(printf '%s' "$rec" | jq -r '.identity.head')" = "$HEAD_A" ] \
    || fail "control 7: the closed record lost the exact head it was bound to"
  printf '%s' "$rec" | jq -e '.ruling.comment_id and .resumed.at and .disposition.outcome' \
    >/dev/null || fail "control 7: the correlation chain is incomplete: $rec"
  pass "control 7: request, ruling, resumed item and disposition form one closed chain"
}

test_terminal_request_is_not_applicable() {
  local dir rid out rc
  dir=$(new_case c7terminal)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "terminal: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  run_ob "$dir" ruling --request "$rid" --comment 44 >/dev/null 2>&1 \
    || fail "terminal: ruling failed"
  run_ob "$dir" resume --request "$rid" >/dev/null 2>&1 || fail "terminal: resume failed"
  run_ob "$dir" close --request "$rid" --disposition accepted >/dev/null 2>&1 \
    || fail "terminal: close failed"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "terminal: closed request satisfied a new wait: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_NO_ARTIFACT' \
    || fail "terminal: closed request failed for the wrong reason: $out"
  pass "terminal: a closed request cannot satisfy a current wait"
}

test_request_requires_readable_correlation() {
  local dir rid record out rc
  dir=$(new_case c7correlation)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correlation: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  record="$dir/home/data/outbound-artifacts/$rid.json"
  rm "$record"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "correlation: missing record returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CORRELATION_RECORD_MISSING' \
    || fail "correlation: missing record satisfied the wait: $out"

  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correlation: adoption failed"
  jq '.state = "unknown"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "correlation: invalid state returned $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    || fail "correlation: invalid lifecycle state satisfied the wait: $out"

  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "correlation: repair failed"
  jq '.identity.item = "another-item"' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  out=$(run_ob "$dir" ruling --request "$rid" --comment 46 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "correlation: mismatched identity accepted a ruling: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_RECORD_UNREADABLE' \
    || fail "correlation: mismatched identity was not unreadable: $out"
  pass "correlation: missing, invalid, or mismatched records cannot satisfy a wait"
}

test_close_requires_resumed_work() {
  local dir rid out rc state
  dir=$(new_case c7resume)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "resume chain: emit failed"
  rid=$(awk '{print $2}' "$dir/forge/comments")
  run_ob "$dir" ruling --request "$rid" --comment 45 >/dev/null 2>&1 \
    || fail "resume chain: ruling failed"
  out=$(run_ob "$dir" close --request "$rid" --disposition accepted 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "resume chain: close skipped resume: $out"
  state=$(jq -r '.state' "$dir/home/data/outbound-artifacts/$rid.json")
  [ "$state" = "ruled" ] || fail "resume chain: refused close mutated state to $state"
  pass "resume chain: disposition cannot bypass resumed work"
}

# --- fail-closed properties --------------------------------------------------

test_incomplete_binding_refuses_rather_than_emitting_vaguely() {
  local dir out rc posts
  dir=$(new_case c8)
  # The head becomes unobservable: the pull request read returns nothing and no
  # clone or declaration supplies one.
  : > "$dir/forge/head"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 8: a headless emit was not refused, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_INCOMPLETE_BINDING' \
    || fail "control 8: refused for the wrong reason: $out"
  printf '%s' "$out" | grep -q 'head' || fail "control 8: the missing field was not named: $out"
  posts=$(wc -l < "$dir/forge/post_log")
  [ "$posts" -eq 0 ] || fail "control 8: a vague request was posted anyway ($posts)"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 8: the unbindable item was not left red, exit $rc"
  pass "control 8: an incomplete binding refuses to emit and leaves the item red"
}

test_unobservable_forge_is_not_a_pass() {
  local dir out rc
  dir=$(new_case c9)
  run_ob "$dir" emit waiting-item >/dev/null 2>&1 || fail "control 9: emit failed"
  # The venue configuration disappears. The artifact may well still exist, but
  # this sweep cannot see it - which must never read as satisfied.
  rm -f "$dir/home/config/sol-control.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] || fail "control 9: an unobservable forge did not reach 4, got $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_TRANSPORT_UNCONFIGURED' \
    || fail "control 9: unevaluable for the wrong reason: $out"
  printf '%s' "$out" | grep -q '0 satisfied' \
    || fail "control 9: an unobservable artifact was counted as satisfied: $out"
  pass "control 9: an unobservable artifact is could-not-observe, never a pass"
}

test_detect_only_channel_refuses_to_emit() {
  local dir out rc
  dir=$(new_case c10)
  write_snapshot "$dir/snap.json" external "never submitted - no pull request exists for this branch"
  out=$(run_ob "$dir" emit waiting-item 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "control 10: the detect-only channel emitted, exit $rc: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_CHANNEL_DETECT_ONLY' \
    || fail "control 10: refused for the wrong reason: $out"
  [ "$(wc -l < "$dir/forge/post_log")" -eq 0 ] \
    || fail "control 10: the detect-only channel posted something"
  pass "control 10: the pull-request channel detects but never creates the artifact"
}

test_never_submitted_branch_is_recognised() {
  local dir out rc
  dir=$(new_case c11)
  # The shape of the three items found finished on a branch with no pull request
  # anywhere. It must be recognised as a defect, not as legitimate waiting.
  write_snapshot "$dir/snap.json" external "RECLASSIFIED: valid unfinished work, never submitted. No pull request on the fork or upstream."
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "control 11: a never-submitted item passed the invariant: $out"
  printf '%s' "$out" | grep -q 'CONTRIBUTION_SUBMISSION_REQUIRED' \
    || fail "control 11: the never-submitted gate was not typed: $out"
  pass "control 11: a finished branch with no pull request is a transport defect"
}

test_done_rows_are_not_waiting() {
  local dir out rc
  dir=$(new_case c12)
  # The recognizer's own negative control: the identical hold prose on a landed
  # row is history, not an outstanding ask. Without this the sweep would report
  # every historical hold forever and be turned off.
  jq '.backlog.records[0].state = "done"' "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "control 12: a done row was still treated as waiting, exit $rc: $out"
  pass "control 12: a landed row carrying the same hold prose is not waiting"
}

test_unstructured_row_is_not_silently_clear() {
  local dir out rc v
  # A row this parser cannot read must not read as clear. It is classified
  # unreadable, which is the third value rather than a quiet pass.
  v=$(
    # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
    . "$ROOT/bin/fm-outbound-artifact-lib.sh"
    fm_outbound_classify_record '{"structured":false,"raw":"a free-form line"}' | cut -f1
  )
  [ "$v" = "unreadable" ] \
    || fail "control 13: an unparseable row classified as '$v', not unreadable"
  out=$(
    # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
    . "$ROOT/bin/fm-outbound-artifact-lib.sh"
    fm_outbound_classify_record 'not json at all' | cut -f1
  )
  [ "$out" = "unreadable" ] \
    || fail "control 13: unparseable JSON classified as '$out', not unreadable"
  dir=$(new_case c13)
  jq '.backlog.records = [{structured:false,raw:"a free-form line"}]' \
    "$dir/snap.json" > "$dir/snap2.json"
  mv "$dir/snap2.json" "$dir/snap.json"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 4 ] \
    || fail "control 13: unreadable backlog row returned $rc instead of unevaluable: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_BACKLOG_ROW_UNREADABLE' \
    || fail "control 13: sweep silently omitted its unreadable row: $out"
  pass "control 13: an unreadable backlog row is could-not-observe, never clear"
}

test_recognition_survives_a_truncated_hold_reason() {
  local v hay
  # The backlog parser captures a hold with `[^,)]*`, so a hold reason stops at
  # its first comma. On the live backlog that cut "VALID UNFINISHED WORK, never
  # submitted" down to "...WORK" and made this recognizer blind to the exact
  # never-submitted items it exists to catch. The recognizer therefore reads the
  # untruncated raw row, and this pins that: the parsed hold_reason here is
  # truncated exactly as the real parser truncates it, and only `raw` carries the
  # signal.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local rec='{"structured":true,"state":"queued","id":"x","hold_kind":"external",
    "hold_reason":"RECLASSIFIED by the sweep: VALID UNFINISHED WORK",
    "title":"some work","body_excerpt":null,
    "raw":"- [ ] x - some work (hold: RECLASSIFIED by the sweep: VALID UNFINISHED WORK, never submitted. No pull request exists.) (hold-kind: external)"}'

  # RED first: reading only the truncated hold_reason misses it entirely.
  fm_outbound_prose_matches "RECLASSIFIED by the sweep: VALID UNFINISHED WORK" \
    && fail "truncation: the truncated hold_reason should carry no signal, but matched"

  hay=$(fm_outbound_haystack "$rec")
  printf '%s' "$hay" | grep -q 'never submitted' \
    || fail "truncation: the raw row was not read into the recognizer's text"
  v=$(fm_outbound_classify_record "$rec" | cut -f1)
  [ "$v" = "waiting" ] || fail "truncation: a comma in the hold reason hid the gate ($v)"
  v=$(fm_outbound_classify_record "$rec" | cut -f2)
  [ "$v" = "CONTRIBUTION_SUBMISSION_REQUIRED" ] \
    || fail "truncation: gate typed as '$v' rather than the never-submitted gate"
  pass "truncation: a hold reason cut off at its first comma is still recognised"
}

test_forge_error_body_is_not_a_head() {
  local dir out rc
  dir=$(new_case c14)
  # `gh api` prints its error payload to STDOUT and exits non-zero. Observed
  # against a live backlog, an unvalidated read carried a 404 body forward as the
  # exact head and rendered it as evidence. The cascade must treat that as no
  # observation at all.
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '{"message":"Not Found","status":"404"}\n'
exit 1
SH
  chmod +x "$dir/bin/gh"
  out=$(run_ob "$dir" check 2>&1); rc=$?
  [ "$rc" -eq 3 ] || fail "forge error: expected a defect, got $rc: $out"
  printf '%s' "$out" | grep -q 'Not Found' \
    && fail "forge error: a 404 body was carried forward as the exact head: $out"
  printf '%s' "$out" | grep -q 'FM_OUTBOUND_HEAD_UNOBSERVED' \
    || fail "forge error: not reported as an unobserved head: $out"
  pass "forge error: an error payload is no observation, not a head"
}

test_untyped_gate_is_reported_as_untyped() {
  local cls
  # The empty middle field. `IFS=$'\t' read` collapses runs of tabs because tab
  # is IFS whitespace, which silently shifted the tier into the gate and printed
  # "gate: prose" against the live backlog. An untyped gate must survive as
  # empty, because untyped is the condition the binding check refuses on.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  cls=$(fm_outbound_classify_record '{"structured":true,"state":"queued","id":"y",
    "hold_kind":"external","hold_reason":"Browser Sol something unclassified",
    "title":"t","body_excerpt":null,"raw":"raw"}')
  [ "$(printf '%s' "$cls" | cut -f1)" = "waiting" ] || fail "untyped: not recognised as waiting"
  [ -z "$(printf '%s' "$cls" | cut -f2)" ] \
    || fail "untyped: gate field is '$(printf '%s' "$cls" | cut -f2)', expected empty"
  [ "$(printf '%s' "$cls" | cut -f3)" = "prose" ] \
    || fail "untyped: tier field lost, got '$(printf '%s' "$cls" | cut -f3)'"
  pass "untyped: an unclassifiable gate stays empty and does not absorb the tier"
}

# --- identity properties -----------------------------------------------------

test_identity_binds_every_named_axis() {
  # Each axis the contract names must change the request id on its own. An axis
  # that does not is an axis the identity does not actually bind, and dedupe
  # would then merge two genuinely different asks.
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local base axis id
  base=$(fm_outbound_request_id AWAITING_BROWSER_SOL proj o/r item 4 "$HEAD_A")
  [ -n "$base" ] || fail "identity: no request id produced"
  for axis in \
    "ARCHITECTURE_RULING_REQUIRED proj o/r item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL other o/r item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/other item 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r other 4 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r item 5 $HEAD_A" \
    "AWAITING_BROWSER_SOL proj o/r item 4 $HEAD_B"
  do
    # shellcheck disable=SC2086
    id=$(fm_outbound_request_id $axis)
    [ "$id" != "$base" ] || fail "identity: '$axis' did not change the request id"
  done
  # And it must be stable: the same identity twice is the same id, or dedupe
  # cannot work at all.
  [ "$(fm_outbound_request_id AWAITING_BROWSER_SOL proj o/r item 4 "$HEAD_A")" = "$base" ] \
    || fail "identity: the same identity produced two different ids"
  pass "identity: gate, project, repo, item, pull request and head each bind, and are stable"
}

test_binding_refuses_a_vague_head() {
  # shellcheck source=bin/fm-outbound-artifact-lib.sh disable=SC1091
  . "$ROOT/bin/fm-outbound-artifact-lib.sh"
  local bad
  for bad in "" "main" "the current head" "HEAD" "latest" \
    "${HEAD_A%?????????????????????????????????}" \
    "${HEAD_A%?}"; do
    fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i "$bad" >/dev/null 2>&1 \
      && fail "binding: '$bad' was accepted as an exact head"
  done
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i "$HEAD_A" >/dev/null 2>&1 \
    || fail "binding: a real sha was rejected"
  fm_outbound_binding_missing AWAITING_BROWSER_SOL p o/r i \
    "${HEAD_A}${HEAD_A%????????????????}" >/dev/null 2>&1 \
    || fail "binding: a full sha256 object id was rejected"
  pass "binding: only full canonical object ids are accepted as exact heads"
}

# --- run ---------------------------------------------------------------------

test_no_request_is_red
test_request_present_is_green
test_head_change_invalidates
test_head_change_fresh_request_is_green
test_no_duplicate_requests
test_duplicate_control_can_fail
test_transient_failure_retries
test_exhausted_transport_keeps_the_request
test_crash_recovery_adopts_its_own_request
test_ruling_wakes_the_exact_item
test_unrelated_ruling_cannot_wake_the_item
test_disposition_completes_the_correlation
test_terminal_request_is_not_applicable
test_request_requires_readable_correlation
test_close_requires_resumed_work
test_incomplete_binding_refuses_rather_than_emitting_vaguely
test_unobservable_forge_is_not_a_pass
test_detect_only_channel_refuses_to_emit
test_never_submitted_branch_is_recognised
test_done_rows_are_not_waiting
test_unstructured_row_is_not_silently_clear
test_forge_error_body_is_not_a_head
test_recognition_survives_a_truncated_hold_reason
test_untyped_gate_is_reported_as_untyped
test_identity_binds_every_named_axis
test_binding_refuses_a_vague_head

printf '\nall fm-outbound-artifact tests passed\n'
