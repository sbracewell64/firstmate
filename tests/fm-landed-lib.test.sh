#!/usr/bin/env bash
# Behavior tests for bin/fm-landed-lib.sh - the shared "has this content already
# landed?" library and, specifically, the boundary between a PROVEN negative and
# a read that could not be made.
#
# THE DEFECT THIS SUITE WAS WRITTEN FOR. fm_landed_push_target_ref mapped every
# failed read of the push url to the same status as "this repository has no
# distinct push target". The push-target ref was then simply absent from
# fm_landed_candidate_refs' output while that function still reported success
# with a NON-EMPTY list, because the local branch and origin's trunk were still
# there. From a call site the result was indistinguishable from a complete list:
# not detectable by checking the status, and not detectable by checking for an
# empty result, because neither is what happened. Containment was then tested
# against a partial universe and "not landed" concluded from it.
#
# WHY THE CONTROLS ARE SHAPED THIS WAY. Three of them are refusals, and a library
# that answered "could not tell" to everything would satisfy all three at once.
# So every could-not-observe case below is paired with the SAME call on an
# unperturbed fixture, asserted to return the definite answer, and only then
# perturbed. The non-vacuity control is not decoration and is not optional.
#
#   1. an ordinary single-remote repository still gets the definite "there is no
#      distinct push target" (1), and a fetch/push split still gets the ref (0)
#   2. an unreadable push url is 2, never 1, at every function that reads it
#   3. an incomplete candidate set reports incomplete EVEN THOUGH its list is
#      non-empty - the exact shape no caller could otherwise detect
#   4. a proven-absent ref, a proven-absent remote and a proven-empty candidate
#      universe all still return their definite negatives
#   5. default-branch resolution does not fall through to a conventional-name
#      guess when what origin/HEAD records went unread
#   6. THE CLASS CONTROL: for every git invocation each entry point makes,
#      failing exactly that one read must produce could-not-observe. This is
#      swept by index rather than written per read, so a read added later to any
#      of these functions is covered the day it is added.
#
# WHAT CONTROL 6 DOES NOT COVER, stated so no reader credits it with more: it
# exercises the reads REACHED by the fixtures below, so a branch no fixture
# enters is not swept. It also inherits git's own classification - a ref whose
# object is missing is reported by git as absent, not as unreadable, so this
# library reports it absent too.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-landed-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-landed-lib)
trap fm_test_cleanup EXIT
fm_git_identity

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_git_fault "$FAKEBIN"
COUNTER="$TMP_ROOT/git-calls"

# Drive one library function in its own process, so a fault injected into it
# cannot leak into the next case and the exit status is read exactly as a caller
# would read it.
DRIVER="$TMP_ROOT/drive.sh"
cat > "$DRIVER" <<'SH'
#!/usr/bin/env bash
set -u
# shellcheck source=/dev/null
. "$FM_LANDED_LIB"
fn=$1
shift
"$fn" "$@"
exit $?
SH
chmod +x "$DRIVER"

# drive <fn> [args...] -> stdout on stdout, status as the exit status.
drive() {
  FM_LANDED_LIB="$LIB" "$DRIVER" "$@"
}

# drive_faulted <match-ere> <fn> [args...]: same, with every git invocation whose
# arguments match <match-ere> failing as an unreadable repository would.
drive_faulted() {
  local match=$1
  shift
  FM_LANDED_LIB="$LIB" FM_FAULT_MATCH="$match" PATH="$FAKEBIN:$PATH" "$DRIVER" "$@"
}

# --- fixtures ----------------------------------------------------------------

# An ordinary single-remote repository: origin fetches and pushes the same url,
# which is the shape "there is no distinct push target" is TRUE for. Every
# could-not-observe case is measured against this same shape so the difference
# under test is the failed read and nothing else.
make_plain() {  # <name>
  local name=$1 base proj
  base="$TMP_ROOT/$name"
  mkdir -p "$base"
  git init -q --bare "$base/origin.git"
  git -C "$base/origin.git" symbolic-ref HEAD refs/heads/main
  proj="$base/proj"
  git init -q -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm initial
  git -C "$proj" remote add origin "$base/origin.git"
  git -C "$proj" push -q origin main
  git -C "$proj" remote set-head origin main
  printf '%s\n' "$proj"
}

# The fetch/push split: origin FETCHES upstream.git and PUSHES fork.git, so the
# fork trunk is reachable through neither conventional ref and lives in
# refs/fm-landing/origin/main. This is the shape whose landing target the defect
# dropped.
make_split() {  # <name>
  local name=$1 base proj
  base="$TMP_ROOT/$name"
  mkdir -p "$base"
  git init -q --bare "$base/upstream.git"
  git -C "$base/upstream.git" symbolic-ref HEAD refs/heads/main
  proj="$base/proj"
  git init -q -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm initial
  git -C "$proj" remote add origin "$base/upstream.git"
  git -C "$proj" push -q origin main
  git -C "$proj" remote set-head origin main
  git clone -q --bare "$base/upstream.git" "$base/fork.git"
  git -C "$proj" remote set-url --push origin "$base/fork.git"
  git -C "$proj" fetch -q "$base/fork.git" '+refs/heads/main:refs/fm-landing/origin/main'
  printf '%s\n' "$proj"
}

# A repository with no remotes at all: "no distinct push target" is true here for
# a different reason, and it must be reached from an enumeration that succeeded.
# With no origin/HEAD to record a default branch either, this is also the fixture
# that drives default-branch resolution through its conventional-name loop rather
# than returning on the first read.
make_no_remote() {  # <name>
  local proj="$TMP_ROOT/$1"
  git init -q -b main "$proj"
  printf 'base\n' > "$proj/README.md"
  git -C "$proj" add README.md
  git -C "$proj" commit -qm initial
  printf '%s\n' "$proj"
}

status_of() {  # <fn> [args...] - run and echo only the status
  local status
  drive "$@" >/dev/null 2>&1
  status=$?
  printf '%s\n' "$status"
}

# --- control 1: the definite answers stay definite ---------------------------

test_plain_repo_has_no_distinct_push_target() {
  local proj status
  proj=$(make_plain plain-negative)

  status=$(status_of fm_landed_push_url "$proj")
  expect_code 1 "$status" "an origin whose fetch and push urls agree is a PROVEN absence of a distinct push url"

  status=$(status_of fm_landed_push_target_ref "$proj" main)
  expect_code 1 "$status" "that same repository has a proven absence of a distinct push TARGET"

  status=$(status_of fm_landed_refresh_push_target "$proj" main)
  expect_code 0 "$status" "with provably nothing to refresh, the refresh succeeds trivially"

  pass "a genuine 'no distinct push target' still returns that answer"
}

test_repo_with_no_remotes_is_a_proven_absence() {
  local proj status
  proj=$(make_no_remote no-remote)

  status=$(status_of fm_landed_remote_listed "$proj" origin)
  expect_code 1 "$status" "a successful enumeration that lists no origin is a proven absence"

  status=$(status_of fm_landed_push_url "$proj")
  expect_code 1 "$status" "no origin at all is a proven absence of a distinct push url"

  pass "a repository with no remotes reaches the negative through an enumeration that succeeded"
}

test_fetch_push_split_names_its_landing_target() {
  local proj out status
  proj=$(make_split split-positive)

  out=$(drive fm_landed_push_target_ref "$proj" main)
  status=$?
  expect_code 0 "$status" "a fetch/push split has a distinct push target"
  [ "$out" = "refs/fm-landing/origin/main" ] \
    || fail "the push target ref is named: got '$out'"

  out=$(drive fm_landed_candidate_refs "$proj" main)
  status=$?
  expect_code 0 "$status" "the candidate set for a readable split repository is complete and non-empty"
  assert_contains "$out" "refs/fm-landing/origin/main" "the landing target is among the candidates"
  assert_contains "$out" "refs/heads/main" "the local branch is among the candidates"

  pass "a readable fetch/push split names its landing target and reports a complete candidate set"
}

test_proven_absences_elsewhere_in_the_path() {
  local proj status out
  proj=$(make_plain plain-absences)

  status=$(status_of fm_landed_ref_exists "$proj" refs/heads/no-such-branch)
  expect_code 1 "$status" "a ref git successfully reported absent is a proven absence"

  status=$(status_of fm_landed_remote_listed "$proj" upstream)
  expect_code 1 "$status" "a remote missing from a successful enumeration is a proven absence"

  out=$(drive fm_landed_candidate_refs "$proj" no-such-trunk)
  status=$?
  expect_code 1 "$status" "a name no ref carries is a PROVEN empty candidate universe"
  [ -z "$out" ] || fail "a proven empty universe prints nothing: got '$out'"

  pass "the proven negatives elsewhere in the landing path are still returned"
}

# --- control 2 and 3: the defect itself --------------------------------------

test_unreadable_push_target_is_not_reported_as_absent() {
  local proj status
  proj=$(make_split split-unreadable)

  # Same fixture, same calls as the positive case above; the only change is that
  # the one read naming the push url fails.
  status=$(FM_LANDED_LIB="$LIB" FM_FAULT_MATCH='remote get-url --push' PATH="$FAKEBIN:$PATH" \
    "$DRIVER" fm_landed_push_url "$proj" >/dev/null 2>&1; printf '%s' $?)
  expect_code 2 "$status" "an unreadable push url is could-not-observe, NOT 'there is no distinct push url'"

  drive_faulted 'remote get-url --push' fm_landed_push_target_ref "$proj" main >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "an unreadable push url leaves the push TARGET could-not-observe, not absent"

  drive_faulted 'remote get-url --push' fm_landed_refresh_push_target "$proj" main >/dev/null 2>&1
  status=$?
  expect_code 2 "$status" "a refresh whose target could not even be named reports the target unread, not 'nothing to refresh'"

  pass "an unreadable push target is never reported as 'no distinct push target'"
}

test_incomplete_candidate_set_is_reported_even_though_it_is_not_empty() {
  local proj out status
  proj=$(make_split split-incomplete)

  out=$(drive_faulted 'remote get-url --push' fm_landed_candidate_refs "$proj" main 2>/dev/null)
  status=$?

  # The heart of the defect: the list is NON-EMPTY and every ref in it is real,
  # so neither an emptiness check nor an inspection of the contents can tell this
  # apart from a complete answer. Only the status can.
  [ -n "$out" ] \
    || fail "the fixture no longer reproduces the defect shape: the partial list must still be non-empty"
  assert_contains "$out" "refs/heads/main" "the refs it COULD read are still offered"
  assert_not_contains "$out" "refs/fm-landing/origin/main" "the unread landing target is genuinely missing from the list"
  expect_code 2 "$status" "a non-empty but incomplete candidate set reports INCOMPLETE"

  pass "an incomplete candidate set is reported as incomplete despite a non-empty list"
}

test_unread_default_branch_record_is_not_replaced_by_a_guess() {
  local proj out status
  proj=$(make_plain plain-default-branch)

  out=$(drive fm_landed_default_branch_name "$proj")
  status=$?
  expect_code 0 "$status" "the readable fixture resolves its default branch"
  [ "$out" = main ] || fail "the readable fixture resolves to main: got '$out'"

  # refs/heads/main exists here, so a fall-through to the conventional names
  # would produce exactly the same answer - which is the point. An answer that
  # happens to be right is still a guess when the record it claims to read went
  # unread.
  out=$(drive_faulted 'symbolic-ref' fm_landed_default_branch_name "$proj" 2>/dev/null)
  status=$?
  expect_code 2 "$status" "an unread origin/HEAD is could-not-observe, not a conventional-name guess"
  [ -z "$out" ] || fail "no name is printed when the record naming it went unread: got '$out'"

  pass "an unread default-branch record does not fall through to a conventional-name guess"
}

# --- control 6: the class control -------------------------------------------
#
# For one entry point on one fixture: run it clean and require the DEFINITE
# answer, then fail each git invocation it made, one at a time, and require
# could-not-observe every time. Sweeping by invocation index rather than by named
# read is what makes this a class control: a read added to any of these functions
# later is swept the day it is added, with no test edit.
sweep_entry_point() {  # <definite-status> <cno-status> <label> <fn> [args...]
  local want_definite=$1 want_cno=$2 label=$3
  shift 3
  local status k fired=0 calls total

  drive "$@" >/dev/null 2>&1
  status=$?
  expect_code "$want_definite" "$status" "$label: the unperturbed call must return a definite answer (otherwise this sweep is vacuous)"

  : > "$COUNTER"
  FM_LANDED_LIB="$LIB" FM_FAULT_AT=0 FM_FAULT_COUNTER="$COUNTER" PATH="$FAKEBIN:$PATH" \
    "$DRIVER" "$@" >/dev/null 2>&1
  total=$(cat "$COUNTER" 2>/dev/null || printf 0)
  case "$total" in ''|*[!0-9]*) total=0 ;; esac
  [ "$total" -gt 0 ] \
    || fail "$label: the sweep observed no git invocation at all, so it checked nothing"

  # Sweep past the clean-path count as well: a failed read can steer the function
  # onto an error path that reads again, and those reads are part of the class.
  for k in $(seq 1 $((total + 4))); do
    : > "$COUNTER"
    FM_LANDED_LIB="$LIB" FM_FAULT_AT="$k" FM_FAULT_COUNTER="$COUNTER" PATH="$FAKEBIN:$PATH" \
      "$DRIVER" "$@" >/dev/null 2>&1
    status=$?
    calls=$(cat "$COUNTER" 2>/dev/null || printf 0)
    case "$calls" in ''|*[!0-9]*) calls=0 ;; esac
    if [ "$calls" -lt "$k" ]; then
      # The fault never fired at this index, so this run proves nothing about a
      # read failure. It must still agree with the clean answer.
      expect_code "$want_definite" "$status" "$label: index $k made no read, so the answer must be unchanged"
      continue
    fi
    fired=$((fired + 1))
    expect_code "$want_cno" "$status" "$label: failing read #$k must report could-not-observe, not a definite answer"
  done
  [ "$fired" -ge "$total" ] \
    || fail "$label: swept $fired of $total observed reads"
  printf '#   %s: %s reads failed one at a time, every one could-not-observe\n' "$label" "$fired"
}

test_no_read_failure_anywhere_can_produce_a_definite_answer() {
  local plain split bare wt

  plain=$(make_plain sweep-plain)
  split=$(make_split sweep-split)
  bare=$(make_no_remote sweep-bare)

  sweep_entry_point 0 2 "ref_exists (present)" fm_landed_ref_exists "$plain" refs/heads/main
  sweep_entry_point 1 2 "ref_exists (absent)" fm_landed_ref_exists "$plain" refs/heads/nope
  sweep_entry_point 0 2 "remote_listed (present)" fm_landed_remote_listed "$plain" origin
  sweep_entry_point 1 2 "remote_listed (absent)" fm_landed_remote_listed "$plain" upstream
  sweep_entry_point 0 2 "default_branch_name (origin/HEAD)" fm_landed_default_branch_name "$plain"
  # No origin/HEAD to read, so this one walks the conventional-name loop and
  # sweeps the reads that loop makes.
  sweep_entry_point 0 2 "default_branch_name (conventional)" fm_landed_default_branch_name "$bare"
  sweep_entry_point 1 2 "push_url (no split)" fm_landed_push_url "$plain"
  sweep_entry_point 0 2 "push_url (split)" fm_landed_push_url "$split"
  sweep_entry_point 1 2 "push_target_ref (no split)" fm_landed_push_target_ref "$plain" main
  sweep_entry_point 0 2 "push_target_ref (split)" fm_landed_push_target_ref "$split" main
  sweep_entry_point 0 2 "candidate_refs (no split)" fm_landed_candidate_refs "$plain" main
  sweep_entry_point 0 2 "candidate_refs (split)" fm_landed_candidate_refs "$split" main
  sweep_entry_point 1 2 "candidate_refs (proven empty)" fm_landed_candidate_refs "$plain" no-such-trunk
  # Both refresh shapes are swept: with provably nothing to refresh, and with a real
  # fetch of the fork trunk, which is the only read in this library that leaves
  # the repository.
  sweep_entry_point 0 2 "refresh_push_target (nothing to refresh)" fm_landed_refresh_push_target "$plain" main
  sweep_entry_point 0 2 "refresh_push_target (fetches the fork trunk)" fm_landed_refresh_push_target "$split" main

  # tree_contains measures a ref against the worktree's own HEAD, so it is swept
  # from inside a worktree in both of its definite directions.
  wt="$TMP_ROOT/sweep-plain/wt"
  git -C "$plain" worktree add --quiet --detach "$wt" main
  sweep_entry_point 0 2 "tree_contains (contained)" fm_landed_tree_contains "$wt" refs/heads/main
  printf 'unlanded\n' > "$wt/work.txt"
  git -C "$wt" add work.txt
  git -C "$wt" commit -qm "unlanded work"
  sweep_entry_point 1 2 "tree_contains (not contained)" fm_landed_tree_contains "$wt" refs/heads/main

  pass "no single read failure anywhere in the landing-resolution path produces a definite answer"
}

test_plain_repo_has_no_distinct_push_target
test_repo_with_no_remotes_is_a_proven_absence
test_fetch_push_split_names_its_landing_target
test_proven_absences_elsewhere_in_the_path
test_unreadable_push_target_is_not_reported_as_absent
test_incomplete_candidate_set_is_reported_even_though_it_is_not_empty
test_unread_default_branch_record_is_not_replaced_by_a_guess
test_no_read_failure_anywhere_can_produce_a_definite_answer
