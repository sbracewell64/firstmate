#!/usr/bin/env bash
# fm-lane-custody.test.sh - behavior tests for LOCAL lane custody: the parked
# custody ref that lets bin/fm-teardown.sh return a slot whose work is committed,
# clean, and deliberately unpublished.
#
# THE CONTROLS THIS SUITE OWNS.
#
#   1. a clean, committed lane parks, and the ref lands in the SHARED store
#   2. the parked objects survive worktree return, branch deletion and `git gc`,
#      and the SAME sequence loses them once the custody ref is released
#   3. a released lane reopens into a fresh worktree at the exact head and tree
#   4. a missing custody ref is not-held
#   5. a moved custody ref is not-held
#   6. two custody refs for one task are not-held, because the parked head is
#      then ambiguous
#   7. an unreachable object is not-held, and says so rather than reporting a
#      store it could not read
#   8. dirty bytes refuse - at park, and again at teardown for a lane that went
#      dirty after it was parked
#   9. a head that is not the branch tip refuses, and a stated head that is not
#      the worktree's refuses
#  10. a tampered head/tree/task binding is unreadable, not held
#  11. a second custody for a DIFFERENT head of the same task is refused
#  12. teardown recognizes a parked lane, and refuses the identical lane unparked
#  13. teardown never parks custody for itself
#  14. teardown never removes a custody ref or its record
#  15. another task's custody never releases this task
#  16. an ordinary spawn recycling the same slot leaves a parked ref intact
#  17. release requires the exact head, and retires ref and record together
#  18. a partial listing is could-not-observe, not a short list
#
# EVERY REFUSAL HERE IS PAIRED. A mechanism that refuses everything satisfies
# every refusal control at once, so each refusal case first drives the SAME
# fixture unperturbed and asserts it succeeds, then applies exactly one
# perturbation and asserts the refusal. That pairing is what makes the refusal
# attributable to the perturbation rather than to a mechanism that never works.
#
# CONTROL 2 IS THE ONE THAT CANNOT BE ASSUMED. "A ref keeps objects reachable"
# is a property of git, not of this code, and the whole design rests on it. It is
# therefore observed here with its negative control in the same fixture: the gc
# that leaves the commit alone with the ref present is only evidence because the
# gc that collects it with the ref absent is run beside it.
#
# WHAT THIS SUITE DELIBERATELY DOES NOT TEST. Teardown's remote authorities -
# reachable from a remote, published at the forge, landed in the trunk - are
# owned and already proven by tests/fm-teardown.test.sh. The cases below drive
# teardown only where custody changes its answer.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

FM_TEST_IDENTITY_CONTRACT=1

CUSTODY="$ROOT/bin/fm-lane-custody.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-custody) || exit 1

TASK=custody-x1
BRANCH="fm/$TASK"

# --- fixture -----------------------------------------------------------------

# One case directory:
#   <case>/home/{state,data,config}   the operational home
#   <case>/origin.git                 a bare origin, so the clone has one
#   <case>/project                    the project clone
#   <case>/wt                         the task worktree, on $BRANCH
#   <case>/fakebin                    stubs for everything teardown shells out to
# The worktree carries one real (non-empty) commit, because every identity this
# suite asserts is a tree digest and an empty commit would make several of them
# indistinguishable from each other.
new_case() {  # <name>
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$fakebin"

  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  # No pull request exists for anything: the point of these cases is a lane the
  # forge has never heard of, so publication must answer "nothing to name" rather
  # than reach a real gh.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$dir/project" worktree add -q -b "$BRANCH" "$dir/wt" main

  printf 'lane work\n' > "$dir/wt/work.txt"
  git -C "$dir/wt" add -- work.txt
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "lane work"

  touch "$dir/home/state/.last-watcher-beat"
  printf '%s\n' "$dir"
}

write_meta() {  # <case> [mode] [task-id]
  local dir=$1 mode=${2:-no-mistakes} id=${3:-$TASK}
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "deliverable=ship" \
    "mode=$mode" \
    "yolo=off"
}

run_custody() {  # <case> <args...>
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_DATA_OVERRIDE="$dir/home/data" \
    "$CUSTODY" "$@"
}

run_teardown() {  # <case> <args...>
  local dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$dir/home" \
  FM_STATE_OVERRIDE="$dir/home/state" \
  FM_CONFIG_OVERRIDE="$dir/home/config" \
  FM_DATA_OVERRIDE="$dir/home/data" \
  PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$@"
}

wt_head() {  # <case>
  git -C "$1/wt" rev-parse HEAD
}

custody_ref() {  # <case> [task-id]
  local dir=$1 id=${2:-$TASK}
  git -C "$dir/project" for-each-ref --format='%(refname) %(objectname)' "refs/fm/custody/$id/"
}

record_of() {  # <case> [task-id]
  printf '%s/home/data/lane-custody/%s.json\n' "$1" "${2:-$TASK}"
}

# The token bin/fm-lane-custody.sh printed, so a case reads the verdict it
# published rather than inferring one from an exit status.
token_of() {  # <output>
  printf '%s\n' "$1" | sed -n 's/^custody: \([a-z-]*\) .*/\1/p' | head -1
}

# Recycle the task worktree the way an ordinary slot handover does: detach it
# onto the trunk, drop the lane branch, and discard everything in the tree. This
# is the state a parked lane's slot is in once it has been handed to the next
# task, and it is the state every reachability claim below has to survive.
recycle_slot() {  # <case>
  local dir=$1
  git -C "$dir/wt" checkout -q --detach main
  git -C "$dir/wt" reset -q --hard
  git -C "$dir/wt" clean -qxdff
  git -C "$dir/project" branch -qD "$BRANCH" 2>/dev/null || true
}

# Collect everything no ref keeps alive, the way a maintenance run would.
hard_gc() {  # <case>
  git -C "$1/project" reflog expire --expire=now --expire-unreachable=now --all
  git -C "$1/project" gc --prune=now --quiet
}

object_present() {  # <case> <sha>
  git -C "$1/project" cat-file -e "$2^{commit}" 2>/dev/null
}

# --- park --------------------------------------------------------------------

test_park_writes_a_shared_ref_and_a_durable_record() {
  local dir head out refs
  dir=$(new_case park-ok)
  write_meta "$dir"
  head=$(wt_head "$dir")

  out=$(run_custody "$dir" park "$TASK") || fail "park failed: $out"
  expect_code held "$(token_of "$out")" "park did not report held"

  # Read the ref from the PROJECT, not from the worktree that wrote it: a ref
  # only the writing worktree can see would be inside the thing teardown is about
  # to return, which is the one place it must not be.
  refs=$(custody_ref "$dir")
  assert_contains "$refs" "refs/fm/custody/$TASK/$head $head" \
    "the custody ref is not visible in the shared store"

  assert_present "$(record_of "$dir")" "no custody record was written"
  assert_grep "\"head\": \"$head\"" "$(record_of "$dir")" "the record does not bind the head"
  assert_grep "\"branch\": \"$BRANCH\"" "$(record_of "$dir")" "the record does not bind the branch"
  assert_grep "\"tree\": \"$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')\"" \
    "$(record_of "$dir")" "the record does not bind the tree"
  pass "a clean committed lane parks under a ref the whole repository can see"
}

test_park_is_idempotent_at_the_same_head() {
  local dir out count
  dir=$(new_case park-idempotent)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "first park failed"
  out=$(run_custody "$dir" park "$TASK") || fail "second park failed: $out"
  expect_code held "$(token_of "$out")" "the second park did not report held"
  count=$(custody_ref "$dir" | grep -c . || true)
  expect_code 1 "$count" "parking twice at one head left more than one custody ref"
  pass "parking the same head twice converges on one custody ref"
}

test_park_refuses_a_dirty_worktree() {
  local dir out rc
  dir=$(new_case park-dirty)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "the unperturbed lane did not park"
  run_custody "$dir" release "$TASK" --head "$(wt_head "$dir")" >/dev/null || fail "release failed"

  # Exactly one perturbation: an untracked file the worker left behind.
  printf 'scratch\n' > "$dir/wt/scratch.txt"
  set +e
  out=$(run_custody "$dir" park "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a dirty worktree did not refuse"
  expect_code not-held "$(token_of "$out")" "a dirty worktree did not report not-held"
  assert_contains "$out" "scratch.txt" "the refusal did not name the offending bytes"
  assert_absent "$(record_of "$dir")" "a refused park still wrote a record"
  pass "untracked bytes refuse a park, and the clean lane before them did not"
}

test_park_refuses_a_head_that_is_not_the_worktrees() {
  local dir out rc other
  dir=$(new_case park-wrong-head)
  write_meta "$dir"
  other=$(git -C "$dir/wt" rev-parse 'HEAD^')
  run_custody "$dir" park "$TASK" --head "$(wt_head "$dir")" >/dev/null \
    || fail "stating the real head did not park"
  run_custody "$dir" release "$TASK" --head "$(wt_head "$dir")" >/dev/null || fail "release failed"

  set +e
  out=$(run_custody "$dir" park "$TASK" --head "$other" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a stated head that is not the worktree's did not refuse"
  expect_code not-held "$(token_of "$out")" "the wrong stated head did not report not-held"
  pass "a stated head other than the worktree's refuses, and the real one parks"
}

test_park_refuses_a_head_that_is_not_the_branch_tip() {
  local dir out rc
  dir=$(new_case park-not-tip)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "the unperturbed lane did not park"
  run_custody "$dir" release "$TASK" --head "$(wt_head "$dir")" >/dev/null || fail "release failed"

  # Exactly one perturbation: HEAD leaves the branch. Custody binds a branch, so
  # there is nothing coherent to park from a detached checkout.
  git -C "$dir/wt" checkout -q --detach HEAD
  set +e
  out=$(run_custody "$dir" park "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a detached HEAD did not refuse"
  expect_code not-held "$(token_of "$out")" "a detached HEAD did not report not-held"
  assert_contains "$out" "detached" "the refusal did not name the detached HEAD"
  pass "a detached HEAD refuses a park, and the same lane on its branch parks"
}

test_park_refuses_a_second_custody_for_a_different_head() {
  local dir out rc first
  dir=$(new_case park-collision)
  write_meta "$dir"
  first=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "the first park failed"

  printf 'more work\n' >> "$dir/wt/work.txt"
  git -C "$dir/wt" add -- work.txt
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "more work"

  set +e
  out=$(run_custody "$dir" park "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a second head for one task did not refuse"
  expect_code not-held "$(token_of "$out")" "the colliding head did not report not-held"
  assert_contains "$out" "$first" "the refusal did not name the head already held"
  assert_contains "$(custody_ref "$dir")" "$first" "the refused park disturbed the head already held"
  expect_code 1 "$(custody_ref "$dir" | grep -c . || true)" \
    "the refused park still created a second custody ref"
  pass "a second custody for a different head of one task is refused and changes nothing"
}

# --- reachability ------------------------------------------------------------

test_the_parked_ref_is_what_survives_gc_after_the_slot_is_recycled() {
  local dir head control
  dir=$(new_case gc-reachability)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"

  recycle_slot "$dir"
  hard_gc "$dir"
  object_present "$dir" "$head" || fail "the parked commit was collected despite its custody ref"
  control=$(run_custody "$dir" verify "$TASK") || fail "verify after gc failed: $control"
  expect_code held "$(token_of "$control")" "verify after gc did not report held"
  assert_contains "$control" "scope=objects" \
    "a worktree-less verify claimed more than the objects it could see"

  # The negative control, in the same fixture: without the ref, the identical
  # sequence loses the commit. Without this, "it survived" would be evidence
  # about gc's mood rather than about the ref.
  run_custody "$dir" release "$TASK" --head "$head" >/dev/null || fail "release failed"
  hard_gc "$dir"
  if object_present "$dir" "$head"; then
    fail "the negative control did not go red: the commit survived with no ref holding it"
  fi
  pass "the custody ref is what keeps a recycled lane's objects through gc (control goes red without it)"
}

test_reopen_rematerializes_the_lane_at_the_exact_head_and_tree() {
  local dir head tree out
  dir=$(new_case reopen)
  write_meta "$dir"
  head=$(wt_head "$dir")
  tree=$(git -C "$dir/wt" rev-parse 'HEAD^{tree}')
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  recycle_slot "$dir"
  hard_gc "$dir"

  out=$(run_custody "$dir" reopen "$TASK" --into "$dir/reopened") || fail "reopen failed: $out"
  expect_code held "$(token_of "$out")" "reopen did not report held"
  assert_contains "$out" "identity=exact" "reopen did not publish the identity proof"
  expect_code "$head" "$(git -C "$dir/reopened" rev-parse HEAD)" "the reopened lane is at another head"
  expect_code "$tree" "$(git -C "$dir/reopened" rev-parse 'HEAD^{tree}')" "the reopened lane carries another tree"
  expect_code "$BRANCH" "$(git -C "$dir/reopened" symbolic-ref --short HEAD)" "the reopened lane is on another branch"
  assert_grep 'lane work' "$dir/reopened/work.txt" "the reopened lane lost its content"
  pass "a parked lane reopens into a fresh worktree at the exact head, tree and branch"
}

test_reopen_never_writes_into_an_existing_path() {
  local dir out rc
  dir=$(new_case reopen-occupied)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  recycle_slot "$dir"
  run_custody "$dir" reopen "$TASK" --into "$dir/first" >/dev/null || fail "the unperturbed reopen failed"

  mkdir -p "$dir/occupied"
  printf 'someone else\n' > "$dir/occupied/keep.txt"
  set +e
  out=$(run_custody "$dir" reopen "$TASK" --into "$dir/occupied" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "reopen into an existing path did not refuse"
  assert_grep 'someone else' "$dir/occupied/keep.txt" "the refused reopen disturbed the existing path"
  pass "reopen refuses an existing path, and the same custody reopens into a fresh one"
}

# --- verify refusals ---------------------------------------------------------

test_a_missing_custody_ref_is_not_held() {
  local dir head out rc
  dir=$(new_case ref-missing)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane >/dev/null \
    || fail "the unperturbed lane did not verify"

  git -C "$dir/project" update-ref -d "refs/fm/custody/$TASK/$head"
  set +e
  out=$(run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a missing custody ref did not refuse"
  expect_code not-held "$(token_of "$out")" "a missing custody ref did not report not-held"
  pass "a custody ref deleted under a live record is not-held"
}

test_a_moved_custody_ref_is_not_held() {
  local dir head other out rc
  dir=$(new_case ref-moved)
  write_meta "$dir"
  head=$(wt_head "$dir")
  other=$(git -C "$dir/wt" rev-parse 'HEAD^')
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane >/dev/null \
    || fail "the unperturbed lane did not verify"

  git -C "$dir/project" update-ref "refs/fm/custody/$TASK/$head" "$other"
  set +e
  out=$(run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a moved custody ref did not refuse"
  expect_code not-held "$(token_of "$out")" "a moved custody ref did not report not-held"
  assert_contains "$out" "$other" "the refusal did not name where the ref moved to"
  pass "a custody ref pointed at another commit is not-held"
}

test_two_custody_refs_for_one_task_are_ambiguous() {
  local dir other out rc
  dir=$(new_case ref-ambiguous)
  write_meta "$dir"
  other=$(git -C "$dir/wt" rev-parse 'HEAD^')
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane >/dev/null \
    || fail "the unperturbed lane did not verify"

  # A stray second ref, as a partly-completed hand edit or an older scheme would
  # leave. Nothing here picks a winner.
  git -C "$dir/project" update-ref "refs/fm/custody/$TASK/$other" "$other"
  set +e
  out=$(run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "two custody refs for one task did not refuse"
  expect_code not-held "$(token_of "$out")" "an ambiguous task did not report not-held"
  assert_contains "$out" "ambiguous" "the refusal did not name the ambiguity"
  pass "two custody refs for one task are refused rather than resolved by preference"
}

test_an_unreachable_object_is_not_held_rather_than_unreadable() {
  local dir head out rc scratch
  dir=$(new_case object-gone)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" >/dev/null || fail "the unperturbed lane did not verify"

  # The ref survives and the OBJECT does not: a store that was restored from a
  # partial copy, or repaired around a lost object, leaves exactly this shape.
  # The ref is written as a file rather than through update-ref, because
  # update-ref refuses to name an object it cannot find and this fixture needs
  # the ref to resolve. A scratch store is used so the object is genuinely absent
  # rather than the store being broken: damaging the real one would fail every
  # read at once and prove nothing about which read misclassified what.
  #
  # The distinction under test is the one M8 in the mutation sweep exposed: the
  # ref check and the object check reach the same refusal for different facts,
  # and a case that trips the ref check proves nothing about the object check.
  scratch="$dir/scratch"
  git init -q -b main "$scratch"
  git -C "$scratch" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unrelated
  mkdir -p "$scratch/.git/refs/fm/custody/$TASK"
  printf '%s\n' "$head" > "$scratch/.git/refs/fm/custody/$TASK/$head"
  jq --arg store "$scratch/.git" '.git_common_dir = $store' "$(record_of "$dir")" > "$dir/rec.json"
  mv "$dir/rec.json" "$(record_of "$dir")"
  # The ref resolves to the recorded head, so the ref check passes and only the
  # object check can produce the refusal below.
  expect_code "$head" \
    "$(git -C "$scratch" rev-parse --verify --quiet "refs/fm/custody/$TASK/$head")" \
    "the fixture's dangling ref does not resolve to the recorded head"
  if git -C "$scratch" cat-file -e "$head^{commit}" 2>/dev/null; then
    fail "the fixture's scratch store unexpectedly holds the parked commit"
  fi

  set +e
  out=$(run_custody "$dir" verify "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "an absent parked commit did not refuse"
  expect_code not-held "$(token_of "$out")" \
    "an absent parked commit was reported as a store that could not be read, not as absent work"
  pass "a parked commit that is not in the store is not-held, never could-not-observe"
}

test_a_tampered_record_is_unreadable_not_held() {
  local dir out rc
  dir=$(new_case record-tampered)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane >/dev/null \
    || fail "the unperturbed lane did not verify"

  # A stale task mapping: this record is filed for $TASK and claims another.
  jq '.task = "some-other-task"' "$(record_of "$dir")" > "$dir/rec.json"
  mv "$dir/rec.json" "$(record_of "$dir")"
  set +e
  out=$(run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "a misbound record did not report could-not-observe"
  expect_code unreadable "$(token_of "$out")" "a misbound record did not report unreadable"
  pass "a record bound to another task is unreadable, and never held"
}

test_a_recorded_tree_that_the_head_does_not_carry_is_not_held() {
  local dir out rc
  dir=$(new_case tree-mismatch)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" >/dev/null || fail "the unperturbed lane did not verify"

  jq --arg tree "$(git -C "$dir/wt" rev-parse 'HEAD^{tree}' | tr '0-9a-f' '1234567890abcde')" \
    '.tree = $tree' "$(record_of "$dir")" > "$dir/rec.json"
  mv "$dir/rec.json" "$(record_of "$dir")"
  set +e
  out=$(run_custody "$dir" verify "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a tree the head does not carry did not refuse"
  expect_code not-held "$(token_of "$out")" "a tree mismatch did not report not-held"
  pass "a recorded tree the parked head does not carry is not-held"
}

test_a_lane_that_went_dirty_after_parking_is_not_held() {
  local dir out rc
  dir=$(new_case lane-dirty-after-park)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane >/dev/null \
    || fail "the unperturbed lane did not verify"

  printf 'uncommitted\n' >> "$dir/wt/work.txt"
  set +e
  out=$(run_custody "$dir" verify "$TASK" --worktree "$dir/wt" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "a lane dirtied after parking did not refuse"
  expect_code not-held "$(token_of "$out")" "a dirtied lane did not report not-held"
  # The objects are untouched: only the LANE claim fails, and the narrower one
  # must not be widened into it.
  out=$(run_custody "$dir" verify "$TASK") || fail "the objects-only verify should still hold"
  assert_contains "$out" "scope=objects" "the objects-only verify claimed lane scope"
  pass "a lane dirtied after parking loses the lane claim and keeps the objects claim"
}

test_require_lane_refuses_to_answer_without_a_worktree() {
  local dir out rc
  dir=$(new_case require-lane)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_custody "$dir" verify "$TASK" >/dev/null || fail "the objects-only verify failed"

  set +e
  out=$(run_custody "$dir" verify "$TASK" --require-lane 2>&1)
  rc=$?
  set -e
  expect_code 2 "$rc" "--require-lane without a worktree did not fail as a usage error"
  assert_contains "$out" "cannot be verified without one" \
    "the refusal did not say why the narrower answer was withheld"
  pass "--require-lane withholds the narrower objects-only answer instead of passing it off"
}

# --- release and list --------------------------------------------------------

test_release_requires_the_exact_head_and_retires_both_artifacts() {
  local dir head out rc
  dir=$(new_case release)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"

  set +e
  out=$(run_custody "$dir" release "$TASK" --head "$(git -C "$dir/wt" rev-parse 'HEAD^')" 2>&1)
  rc=$?
  set -e
  expect_code 3 "$rc" "release with another head did not refuse"
  assert_present "$(record_of "$dir")" "the refused release still removed the record"
  assert_contains "$(custody_ref "$dir")" "$head" "the refused release still removed the ref"

  out=$(run_custody "$dir" release "$TASK" --head "$head") || fail "release failed: $out"
  expect_code released "$(token_of "$out")" "release did not report released"
  assert_absent "$(record_of "$dir")" "release left the record behind"
  expect_code 0 "$(custody_ref "$dir" | grep -c . || true)" "release left the custody ref behind"
  pass "release refuses any head but the parked one, then retires ref and record together"
}

test_a_partial_listing_is_could_not_observe() {
  local dir out rc
  dir=$(new_case list-partial)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  out=$(run_custody "$dir" list) || fail "the unperturbed listing failed: $out"
  assert_contains "$out" "ref_state=present" "the listing did not report the live ref"

  printf 'not json\n' > "$dir/home/data/lane-custody/another-task.json"
  set +e
  out=$(run_custody "$dir" list 2>&1)
  rc=$?
  set -e
  expect_code 4 "$rc" "a partial listing did not report could-not-observe"
  assert_contains "$out" "INCOMPLETE" "the partial listing did not say it was incomplete"
  assert_contains "$out" "$TASK" "the partial listing dropped the entry it could read"
  pass "a listing with an unreadable record is could-not-observe, not a short list"
}

# --- teardown recognition ----------------------------------------------------

test_teardown_refuses_the_same_lane_unparked_and_releases_it_parked() {
  local dir out rc
  dir=$(new_case teardown-recognition)
  write_meta "$dir"

  set +e
  out=$(run_teardown "$dir" "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown released an unpublished, unparked lane"
  assert_contains "$out" "REFUSED" "teardown did not refuse the unparked lane"
  assert_contains "$out" "custody: not-held" \
    "teardown did not report which of the three values custody reached"
  assert_present "$dir/home/state/$TASK.meta" "the refused teardown still cleared task state"

  # Exactly one perturbation: the lane is parked.
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  out=$(run_teardown "$dir" "$TASK" 2>&1) || fail "teardown refused a parked lane: $out"
  assert_contains "$out" "local custody holds this lane" \
    "teardown did not name custody as the authority it released on"
  assert_absent "$dir/home/state/$TASK.meta" "teardown did not clear the task state"
  pass "teardown refuses an unparked lane and releases the identical lane once parked"
}

test_teardown_never_parks_custody_for_itself() {
  local dir rc
  dir=$(new_case teardown-no-self-park)
  write_meta "$dir"

  set +e
  run_teardown "$dir" "$TASK" >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown released an unparked lane"
  assert_absent "$(record_of "$dir")" "teardown minted its own custody record"
  expect_code 0 "$(custody_ref "$dir" | grep -c . || true)" "teardown minted its own custody ref"
  pass "teardown never mints the custody that would authorize its own cleanup"
}

test_teardown_leaves_the_custody_ref_and_record_intact() {
  local dir head out
  dir=$(new_case teardown-keeps-custody)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"

  run_teardown "$dir" "$TASK" >/dev/null 2>&1 || fail "teardown refused a parked lane"
  # Cleanup demonstrably ran, so the survival below is not survival-by-no-op.
  assert_absent "$dir/home/state/$TASK.meta" "teardown did not clear the task state"
  assert_present "$(record_of "$dir")" "teardown removed the custody record"
  assert_contains "$(custody_ref "$dir")" "$head" "teardown removed the custody ref"

  recycle_slot "$dir"
  hard_gc "$dir"
  out=$(run_custody "$dir" reopen "$TASK" --into "$dir/after-teardown") \
    || fail "the lane could not be reopened after teardown: $out"
  expect_code "$head" "$(git -C "$dir/after-teardown" rev-parse HEAD)" \
    "the lane reopened at another head after teardown"
  pass "cleanup never deletes the only copy: the parked lane reopens after teardown and gc"
}

test_teardown_refuses_a_parked_lane_whose_head_moved() {
  local dir out rc
  dir=$(new_case teardown-head-moved)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"

  # Exactly one perturbation: the worker committed once more after parking, so
  # the custody ref no longer holds what this worktree is about to lose.
  printf 'later work\n' >> "$dir/wt/work.txt"
  git -C "$dir/wt" add -- work.txt
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "later work"

  set +e
  out=$(run_teardown "$dir" "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown released a lane whose head moved past its custody"
  assert_contains "$out" "custody: not-held" "teardown did not report custody as not-held"
  assert_present "$dir/home/state/$TASK.meta" "the refused teardown still cleared task state"
  pass "teardown refuses a parked lane whose head moved past the parked one"
}

test_teardown_refuses_a_parked_lane_that_went_dirty() {
  local dir out rc
  dir=$(new_case teardown-dirty-after-park)
  write_meta "$dir"
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  printf 'uncommitted\n' >> "$dir/wt/work.txt"

  set +e
  out=$(run_teardown "$dir" "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "teardown released a parked lane carrying uncommitted bytes"
  assert_contains "$out" "uncommitted changes" "teardown did not refuse on the dirty bytes"
  assert_present "$dir/home/state/$TASK.meta" "the refused teardown still cleared task state"
  pass "custody never covers uncommitted bytes: a dirtied parked lane still refuses"
}

test_another_tasks_custody_never_releases_this_task() {
  local dir out rc
  dir=$(new_case teardown-wrong-task)
  write_meta "$dir"
  write_meta "$dir" no-mistakes other-task
  run_custody "$dir" park other-task >/dev/null || fail "parking the other task failed"

  set +e
  out=$(run_teardown "$dir" "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "another task's custody released this one"
  assert_contains "$out" "custody: not-held" "teardown did not report this task's custody as not-held"

  # And the same fixture releases once THIS task is parked, so the refusal is
  # attributable to the task binding rather than to a custody path that never works.
  run_custody "$dir" park "$TASK" >/dev/null || fail "parking this task failed"
  run_teardown "$dir" "$TASK" >/dev/null 2>&1 || fail "teardown refused this task's own custody"
  pass "custody parked for another task never releases this one"
}

test_local_only_mode_honors_custody_on_the_same_terms() {
  local dir out rc
  dir=$(new_case teardown-local-only)
  write_meta "$dir" local-only

  set +e
  out=$(run_teardown "$dir" "$TASK" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "local-only teardown released an unmerged, unparked lane"
  assert_contains "$out" "custody: not-held" "local-only teardown did not report custody"

  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  out=$(run_teardown "$dir" "$TASK" 2>&1) || fail "local-only teardown refused a parked lane: $out"
  assert_contains "$out" "local custody holds this lane" \
    "local-only teardown did not name custody as the authority"
  pass "a local-only lane parks and releases on the same terms as any other mode"
}

# --- spawn ------------------------------------------------------------------

test_an_ordinary_spawn_recycling_the_slot_leaves_the_parked_ref_intact() {
  local dir head out
  dir=$(new_case spawn-recycle)
  write_meta "$dir"
  head=$(wt_head "$dir")
  run_custody "$dir" park "$TASK" >/dev/null || fail "park failed"
  run_teardown "$dir" "$TASK" >/dev/null 2>&1 || fail "teardown refused a parked lane"

  # The slot goes back to the pool and the next task takes it. fm-spawn is driven
  # for real here rather than simulated: the question is whether ORDINARY dispatch
  # disturbs a parked ref, and only the real allocator can answer it.
  recycle_slot "$dir"
  mkdir -p "$dir/home/data/next-task" "$dir/home/projects"
  printf 'brief for next-task\n' > "$dir/home/data/next-task/brief.md"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_fake_treehouse "$dir/fakebin"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_PROJECTS_OVERRIDE="$dir/home/projects" FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$dir/wt" \
    PATH="$dir/fakebin:$PATH" \
    "$SPAWN" next-task "$dir/project" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION 2>&1) \
    || fail "the spawn that recycles the slot failed: $out"

  hard_gc "$dir"
  assert_contains "$(custody_ref "$dir")" "$head" "an ordinary spawn removed the parked custody ref"
  object_present "$dir" "$head" || fail "an ordinary spawn let the parked commit be collected"
  out=$(run_custody "$dir" reopen "$TASK" --into "$dir/after-spawn") \
    || fail "the parked lane could not be reopened after an ordinary spawn: $out"
  expect_code "$head" "$(git -C "$dir/after-spawn" rev-parse HEAD)" \
    "the lane reopened at another head after an ordinary spawn"
  pass "an ordinary spawn recycling the same slot never consumes or collects a parked ref"
}

# --- run ---------------------------------------------------------------------

test_park_writes_a_shared_ref_and_a_durable_record
test_park_is_idempotent_at_the_same_head
test_park_refuses_a_dirty_worktree
test_park_refuses_a_head_that_is_not_the_worktrees
test_park_refuses_a_head_that_is_not_the_branch_tip
test_park_refuses_a_second_custody_for_a_different_head
test_the_parked_ref_is_what_survives_gc_after_the_slot_is_recycled
test_reopen_rematerializes_the_lane_at_the_exact_head_and_tree
test_reopen_never_writes_into_an_existing_path
test_a_missing_custody_ref_is_not_held
test_a_moved_custody_ref_is_not_held
test_two_custody_refs_for_one_task_are_ambiguous
test_an_unreachable_object_is_not_held_rather_than_unreadable
test_a_tampered_record_is_unreadable_not_held
test_a_recorded_tree_that_the_head_does_not_carry_is_not_held
test_a_lane_that_went_dirty_after_parking_is_not_held
test_require_lane_refuses_to_answer_without_a_worktree
test_release_requires_the_exact_head_and_retires_both_artifacts
test_a_partial_listing_is_could_not_observe
test_teardown_refuses_the_same_lane_unparked_and_releases_it_parked
test_teardown_never_parks_custody_for_itself
test_teardown_leaves_the_custody_ref_and_record_intact
test_teardown_refuses_a_parked_lane_whose_head_moved
test_teardown_refuses_a_parked_lane_that_went_dirty
test_another_tasks_custody_never_releases_this_task
test_local_only_mode_honors_custody_on_the_same_terms
test_an_ordinary_spawn_recycling_the_slot_leaves_the_parked_ref_intact

fm_test_contract "$0"
