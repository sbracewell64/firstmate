#!/usr/bin/env bash
# tests/fm-blocker-lib.test.sh - dependency-driven re-evaluation of a declared
# wait, colocated with the library that owns it (bin/fm-blocker-lib.sh).
#
# The property under test is BLOCKER MOVEMENT, not elapsed time and not any
# timestamp that happens to change alongside it. Three cases carry that
# distinction and must be read together, because a change that suppressed every
# hold would pass the first one on its own:
#
#   1. a blocker that did NOT move produces no wake;
#   2. a blocker that DID move produces one - the non-vacuity anchor, and the
#      case that proves the fix discriminates rather than deletes;
#   3. an EDIT to a blocker's prose is not movement, so the mechanism is bound to
#      the disposition fields rather than to the record as a whole.
#
# Most cases drive a scripted backlog reader, because a real backlog tool will
# not build an unreadable blocker, a dependency cycle, or a 40-link chain on
# request. One case drives the REAL reader when it is installed, so the field
# grammar this library parses is the grammar the real tool emits rather than the
# grammar the double was written to assume.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-blocker-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-blocker-tests)
LIB="$ROOT/bin/fm-blocker-lib.sh"

# A case gets a state directory, a fixture directory the reader serves records
# from, and a fakebin holding that reader.
make_case() {  # <name> -> case dir
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fixtures" "$dir/fakebin"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
# Test double for the backlog reader: serves one record per fixture file, and
# answers a missing id exactly as the real tool does.
set -u
[ "${1:-}" = show ] || { printf 'error: unsupported command\n' >&2; exit 2; }
id=${2:-}
[ -z "${FM_FAKE_TASKS_LOG:-}" ] || printf '%s\n' "$id" >> "$FM_FAKE_TASKS_LOG"
f="$FM_FAKE_TASKS_DIR/$id"
if [ ! -f "$f" ]; then
  printf 'error: "Task \\"%s\\" not found in this backlog"\ncode: NOT_FOUND\n' "$id"
  exit 1
fi
cat "$f"
exit 0
SH
  chmod +x "$dir/fakebin/tasks-axi"
  printf '%s' "$dir"
}

# Write one fixture record. Defaults describe an ordinary unblocked queued item;
# every field the library reads can be overridden, plus the prose fields it must
# ignore.
put_task() {  # <case-dir> <id> [field=value]...
  local dir=$1 id=$2 kv
  local state=queued blocked_by='-' held=no hold_kind='-' closed='-'
  local title='fixture item' reason='fixture hold' body='fixture body'
  shift 2
  for kv in "$@"; do
    case "$kv" in
      state=*) state=${kv#state=} ;;
      blocked_by=*) blocked_by=${kv#blocked_by=} ;;
      held=*) held=${kv#held=} ;;
      hold_kind=*) hold_kind=${kv#hold_kind=} ;;
      closed=*) closed=${kv#closed=} ;;
      title=*) title=${kv#title=} ;;
      reason=*) reason=${kv#reason=} ;;
      body=*) body=${kv#body=} ;;
      *) fail "put_task: unknown field $kv" ;;
    esac
  done
  local blocked=yes
  [ "$blocked_by" = '-' ] && blocked=no
  {
    printf 'task:\n'
    printf '  id: %s\n' "$id"
    printf '  title: "%s"\n' "$title"
    printf '  state: %s\n' "$state"
    printf '  blocked: %s\n' "$blocked"
    case "$blocked_by" in
      *,*) printf '  blocked_by: "%s"\n' "$blocked_by" ;;
      *)   printf '  blocked_by: %s\n' "$blocked_by" ;;
    esac
    printf '  held: %s\n' "$held"
    printf '  hold_reason: "%s"\n' "$reason"
    printf '  hold_kind: %s\n' "$hold_kind"
    printf '  closed: "%s"\n' "$closed"
    printf '  body: "%s"\n' "$body"
  } > "$dir/fixtures/$id"
}

# Evaluate movement for <task> in <case-dir>, through the scripted reader.
movement() {  # <case-dir> <task> [extra env assignments...]
  local dir=$1 task=$2
  shift 2
  # shellcheck disable=SC2016 # The child script body must reach the fresh
  # interpreter unexpanded; its $1..$3 are that interpreter's own arguments.
  PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$dir/fixtures" \
    env "$@" bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      fm_blocker_movement "$2" "$3"
    ' _ "$LIB" "$task" "$dir/state"
}

# Promote a staged observation, in the same fresh-process style.
commit_baseline() {  # <case-dir> <task> [movement-result]
  local dir=$1 task=$2 result=${3:-} token
  token=$(fm_blocker_token_of "$result")
  bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_blocker_commit "$2" "$3" "$4"
  ' _ "$LIB" "$dir/state" "$task" "$token"
}

verdict_of() { printf '%s' "${1%%	*}"; }
detail_of() { local detail=${1#*	}; printf '%s' "${detail%%	*}"; }

# Establish a baseline for <task>: the first observation can never be a
# comparison, so it is evaluated and committed before a case asserts anything
# about movement.
seed_baseline() {  # <case-dir> <task>
  local dir=$1 task=$2 r
  r=$(movement "$dir" "$task")
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a first observation with no baseline claimed '$(verdict_of "$r")' instead of could-not-observe"
  commit_baseline "$dir" "$task" "$r" || fail "could not commit the first observation"
}

# --- the three cases that carry the property --------------------------------

# CONTROL 1. The defect: a hold whose named blocker has not moved was woken on
# the hour forever. With the baseline in place and the blocker untouched, the
# only verdict that may suppress a wake is reachable, and it is reached.
test_unmoved_blocker_produces_no_wake() {
  local dir r
  dir=$(make_case unmoved)
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unchanged ] \
    || fail "an unmoved blocker did not suppress the recheck: $r"
  case "$(detail_of "$r")" in
    *upstream*) : ;;
    *) fail "the suppression did not name the blocker it rests on: $r" ;;
  esac
  pass "a hold whose named blocker has not moved produces no wake"
}

# CONTROL 2, the non-vacuity anchor. A fix that simply deleted the wake would
# pass control 1 and fail here.
test_moved_blocker_triggers_reevaluation() {
  local dir r
  dir=$(make_case moved)
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  [ "$(verdict_of "$(movement "$dir" held)")" = unchanged ] \
    || fail "the baseline did not settle before the movement was applied"
  put_task "$dir" upstream state=done held=no closed=2026-08-17
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] || fail "a blocker that moved did not trigger re-evaluation: $r"
  case "$(detail_of "$r")" in
    *upstream*) : ;;
    *) fail "the re-evaluation did not name the blocker that moved: $r" ;;
  esac
  pass "a hold whose named blocker moved does trigger re-evaluation"
}

# CONTROL 3. Movement is the PROPERTY; a record that merely changed is the
# proxy. Re-wording a title, a hold reason, or a body must not read as movement,
# or the mechanism degrades back into a note-edit detector.
test_prose_edit_is_not_movement() {
  local dir r
  dir=$(make_case prose-edit)
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external title='original' reason='original' body='original'
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external \
    title='rewritten title' reason='rewritten reason with much more detail' body='rewritten body'
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unchanged ] \
    || fail "an edit to a blocker's prose was read as movement: $r"
  pass "editing a blocker's prose is not movement"
}

# --- the rest of the controls ------------------------------------------------

# A hold with no recorded blocker keeps its existing timer behavior, so nothing
# loses coverage by omission.
test_no_recorded_blocker_keeps_the_timer() {
  local dir r
  dir=$(make_case no-blocker)
  put_task "$dir" held held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = none ] \
    || fail "an item with no recorded blocker did not fall back to its timer: $r"
  pass "a hold with no recorded blocker keeps its existing timer behaviour"
}

# A blocker the backlog cannot produce is could-not-observe. It is never
# narrowed into unchanged (which would suppress) and never into cleared.
test_unreadable_blocker_is_could_not_observe() {
  local dir r
  dir=$(make_case unreadable-blocker)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  rm -f "$dir/fixtures/upstream"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "an unreadable blocker was not reported as could-not-observe: $r"
  case "$(detail_of "$r")" in
    *upstream*) : ;;
    *) fail "could-not-observe did not name the blocker it could not read: $r" ;;
  esac
  pass "a blocker that cannot be read reports could-not-observe and still surfaces"
}

# With no reader at all, nothing about the blocker set is knowable, so no claim
# that a wait is unchanged is available either.
test_absent_reader_is_could_not_observe() {
  local dir r
  dir=$(make_case absent-reader)
  mkdir -p "$dir/emptybin"
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  # An EMPTY PATH rather than a bogus one, and the interpreter reached by its
  # absolute path: a PATH that also loses `bash` would fail before the library
  # ever ran, which is a different observation from the one under test.
  # shellcheck disable=SC2016 # Unexpanded child script body, as above.
  r=$(PATH="$dir/emptybin" FM_FAKE_TASKS_DIR="$dir/fixtures" \
    "$BASH" -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      fm_blocker_movement "$2" "$3"
    ' _ "$LIB" held "$dir/state")
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "an absent backlog reader did not report could-not-observe: $r"
  pass "an absent backlog reader is could-not-observe, never a suppression"
}

test_unreadable_explicit_home_never_falls_back_to_current_directory() {
  local dir cwd explicit_home r first
  dir=$(make_case unreadable-explicit-home)
  cwd="$dir/current-home"
  explicit_home="$dir/unreadable-home"
  mkdir -p "$cwd/fixtures"
  printf 'not a readable backlog directory\n' > "$explicit_home"
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  cp "$dir/fixtures/upstream" "$dir/fixtures/held" "$cwd/fixtures/"

  first=$(cd "$cwd" && PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$cwd/fixtures" \
    bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      fm_blocker_movement "$2" "$3"
    ' _ "$LIB" held "$dir/state")
  commit_baseline "$dir" held "$first" || fail "could not commit the current-directory control baseline"

  r=$(cd "$cwd" && PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$cwd/fixtures" \
    bash -c '
      set -u
      # shellcheck disable=SC1090
      . "$1"
      fm_blocker_movement "$2" "$3" "$4"
    ' _ "$LIB" held "$dir/state" "$explicit_home")
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "an unreadable explicit home consulted the same-id task in the current directory and suppressed: $r"
  pass "an unreadable explicit home surfaces without consulting the current directory"
}

# The very first evaluation has nothing to compare against. Movement is
# unobservable then, so it surfaces once and records the baseline it will use
# next time - it does not quietly assume nothing changed.
test_first_observation_is_could_not_observe() {
  local dir r
  dir=$(make_case first-observation)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a first observation claimed a movement verdict it had no baseline for: $r"
  [ -f "$(fm_blocker_pending_path "$dir/state" held)" ] \
    || fail "the first observation staged nothing, so the next one has no baseline either"
  [ ! -f "$(fm_blocker_record_path "$dir/state" held)" ] \
    || fail "the observation promoted itself to the baseline without a commit"
  pass "a first observation with no baseline is could-not-observe, not unchanged"
}

# A blocker that LEFT the active set moved: the wait's own dependency changed
# even though no surviving blocker's disposition did.
test_blocker_leaving_the_set_is_movement() {
  local dir r
  dir=$(make_case blocker-left)
  put_task "$dir" up-a state=in_flight
  put_task "$dir" up-b state=in_flight
  put_task "$dir" held blocked_by=up-a,up-b held=yes hold_kind=external
  seed_baseline "$dir" held
  put_task "$dir" held blocked_by=up-a held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] \
    || fail "a blocker leaving the active set was not treated as movement: $r"
  case "$(detail_of "$r")" in
    *up-b*) : ;;
    *) fail "the movement did not name the blocker that left: $r" ;;
  esac
  pass "a blocker leaving the active set is movement"
}

# The one that would have been silently wrong. The real backlog drops a blocker
# from the active set the moment it completes, so the LAST blocker clearing looks
# byte-identical to an item that never recorded one. Reading that as "no
# dependency" would suppress exactly the wake this mechanism exists to deliver.
test_last_blocker_clearing_is_movement_then_falls_back_to_the_timer() {
  local dir r
  dir=$(make_case last-blocker-cleared)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  put_task "$dir" held held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] \
    || fail "the last blocker clearing was read as no dependency instead of movement: $r"
  case "$(detail_of "$r")" in
    *upstream*) : ;;
    *) fail "the movement did not name the blocker that cleared: $r" ;;
  esac
  commit_baseline "$dir" held "$r"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = none ] \
    || fail "an item whose blockers have all cleared did not fall back to its timer: $r"
  pass "the last blocker clearing is movement, and the wait then falls back to its timer"
}

# Precedence, both directions. A failure outranks could-not-observe, which
# outranks pass: an unreadable blocker must never mask one that moved, and an
# unchanged blocker must never mask one that could not be read.
test_movement_outranks_could_not_observe() {
  local dir r
  dir=$(make_case precedence-moved)
  put_task "$dir" up-a state=in_flight
  put_task "$dir" up-b state=in_flight
  put_task "$dir" held blocked_by=up-a,up-b held=yes hold_kind=external
  seed_baseline "$dir" held
  put_task "$dir" up-a state=done closed=2026-08-17
  rm -f "$dir/fixtures/up-b"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] \
    || fail "an unreadable blocker masked one that had moved: $r"
  pass "a moved blocker outranks an unreadable one"
}

test_could_not_observe_outranks_unchanged() {
  local dir r
  dir=$(make_case precedence-cno)
  put_task "$dir" up-a state=in_flight
  put_task "$dir" up-b state=in_flight
  put_task "$dir" held blocked_by=up-a,up-b held=yes hold_kind=external
  seed_baseline "$dir" held
  rm -f "$dir/fixtures/up-b"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "an unchanged blocker masked one that could not be read: $r"
  pass "an unreadable blocker outranks an unchanged one"
}

# A cycle is refused rather than followed: waiting for movement in a loop would
# wait forever, so the wait surfaces and no baseline is recorded that could later
# suppress it.
test_cycle_is_refused() {
  local dir r
  dir=$(make_case cycle)
  put_task "$dir" held blocked_by=up-a held=yes hold_kind=external
  put_task "$dir" up-a blocked_by=up-b
  put_task "$dir" up-b blocked_by=up-a
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = cycle ] || fail "a dependency cycle was not refused: $r"
  case "$(detail_of "$r")" in
    *up-a*up-b*) : ;;
    *) fail "the refusal did not name the loop it found: $r" ;;
  esac
  [ ! -f "$(fm_blocker_pending_path "$dir/state" held)" ] \
    || fail "a refused cycle staged a baseline that could later suppress the wait"
  pass "a dependency cycle is refused rather than followed"
}

# A self-edge is the shortest cycle, and it must be refused on the same terms.
test_self_edge_is_refused() {
  local dir r
  dir=$(make_case self-edge)
  put_task "$dir" held blocked_by=held held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = cycle ] || fail "a self-blocking item was not refused: $r"
  pass "an item recorded as blocking itself is refused"
}

# Both bounds exist, and both make the FACT discoverable at the moment they
# bite: a graph that ran past a bound was not enumerated, so no cycle claim is
# available and the wait surfaces naming the bound that stopped it.
test_depth_bound_is_could_not_observe_and_names_itself() {
  local dir r i prev
  dir=$(make_case depth-bound)
  put_task "$dir" held blocked_by=chain-1 held=yes hold_kind=external
  i=1
  while [ "$i" -le 12 ]; do
    prev=$i; i=$((i + 1))
    put_task "$dir" "chain-$prev" blocked_by="chain-$i"
  done
  put_task "$dir" "chain-$i" state=in_flight
  r=$(movement "$dir" held FM_BLOCKER_MAX_DEPTH=4)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a chain past the depth bound claimed a verdict it had not enumerated: $r"
  case "$(detail_of "$r")" in
    *FM_BLOCKER_MAX_DEPTH=4*) : ;;
    *) fail "the depth bound was not named where it bit: $r" ;;
  esac
  pass "a blocker chain past the depth bound is could-not-observe and names the bound"
}

test_node_bound_is_could_not_observe_and_names_itself() {
  local dir r i prev
  dir=$(make_case node-bound)
  put_task "$dir" held blocked_by=chain-1 held=yes hold_kind=external
  i=1
  while [ "$i" -le 12 ]; do
    prev=$i; i=$((i + 1))
    put_task "$dir" "chain-$prev" blocked_by="chain-$i"
  done
  put_task "$dir" "chain-$i" state=in_flight
  r=$(movement "$dir" held FM_BLOCKER_MAX_NODES=3)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a graph past the node bound claimed a verdict it had not enumerated: $r"
  case "$(detail_of "$r")" in
    *FM_BLOCKER_MAX_NODES=3*) : ;;
    *) fail "the node bound was not named where it bit: $r" ;;
  esac
  pass "a blocker graph past the node bound is could-not-observe and names the bound"
}

test_node_bound_applies_across_a_wide_graph() {
  local dir r
  dir=$(make_case wide-node-bound)
  put_task "$dir" held blocked_by=wide-a,wide-b,wide-c,wide-d held=yes hold_kind=external
  put_task "$dir" wide-a
  put_task "$dir" wide-b
  put_task "$dir" wide-c
  put_task "$dir" wide-d
  r=$(movement "$dir" held FM_BLOCKER_MAX_NODES=3)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a wide graph exceeded the global node bound without surfacing: $r"
  case "$(detail_of "$r")" in
    *FM_BLOCKER_MAX_NODES=3*) : ;;
    *) fail "the wide graph did not name the global node bound where it bit: $r" ;;
  esac
  pass "the node bound applies to total expansion across a wide graph"
}

test_shared_descendant_is_expanded_once() {
  local dir out count
  dir=$(make_case shared-descendant)
  put_task "$dir" held blocked_by=left,right held=yes hold_kind=external
  put_task "$dir" left blocked_by=shared
  put_task "$dir" right blocked_by=shared
  put_task "$dir" shared
  export FM_FAKE_TASKS_LOG="$dir/reader.log"
  out=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$dir/fixtures" \
    FM_FAKE_TASKS_LOG="$FM_FAKE_TASKS_LOG" bash -c '
      set -u
      . "$1"
      fm_blocker_cycle "$2"
    ' _ "$LIB" held)
  [ -z "$out" ] || fail "an acyclic shared-descendant graph reported a cycle: $out"
  count=$(grep -c '^shared$' "$FM_FAKE_TASKS_LOG" 2>/dev/null || true)
  [ "$count" -eq 1 ] || fail "the shared descendant was expanded $count times instead of once"
  unset FM_FAKE_TASKS_LOG
  pass "a finished shared descendant is not re-expanded across siblings"
}

# The dependency is durable, not in-memory. This constructs the restart rather
# than reasoning about it: the baseline is written by one process, and every
# later evaluation runs in a fresh interpreter that inherits no shell state, so
# only the file on disk can carry the dependency across.
test_dependency_survives_a_restart() {
  local dir r
  dir=$(make_case restart)
  put_task "$dir" upstream state=in_flight held=yes hold_kind=external
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  [ -f "$(fm_blocker_record_path "$dir/state" held)" ] \
    || fail "the baseline was not written to disk, so nothing could survive a restart"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unchanged ] \
    || fail "a fresh process did not recover the recorded dependency: $r"
  # The disconfirming half: the recovered baseline is a real comparison, not a
  # file whose mere presence answers unchanged.
  put_task "$dir" upstream state=done held=no closed=2026-08-17
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] \
    || fail "the recovered baseline answered unchanged regardless of the blocker: $r"
  pass "the dependency survives a restart, and the recovered baseline still discriminates"
}

# A wake decided but not yet delivered must not be lost. The observation is only
# promoted by an explicit commit, so a process killed before that point
# recomputes the same verdict and repeats the wake.
test_uncommitted_observation_repeats_the_wake() {
  local dir r
  dir=$(make_case uncommitted)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  put_task "$dir" upstream state=done closed=2026-08-17
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] || fail "the movement was not detected at all: $r"
  # No commit here - this is the killed-between-deciding-and-recording case.
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = moved ] \
    || fail "an uncommitted observation swallowed the wake it had already decided: $r"
  commit_baseline "$dir" held "$r"
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unchanged ] \
    || fail "the committed observation did not become the new baseline: $r"
  pass "an observation that was never committed repeats its wake instead of swallowing it"
}

assert_nonstaging_discards_stale_pending() {  # <case-dir> <task> <verdict> [env...]
  local dir=$1 task=$2 expected=$3 record pend before r
  shift 3
  record=$(fm_blocker_record_path "$dir/state" "$task")
  pend=$(fm_blocker_pending_path "$dir/state" "$task")
  printf '%s\ntask=%s\nobserved=1\n' "$FM_BLOCKER_RECORD_MAGIC" "$task" > "$record"
  before=$(cat "$record")
  printf '%s\ntask=%s\nobserved=2\nblocker=ghost\tstate=done\n' \
    "$FM_BLOCKER_RECORD_MAGIC" "$task" > "$pend"
  r=$(movement "$dir" "$task" "$@")
  [ "$(verdict_of "$r")" = "$expected" ] \
    || fail "$task did not reach the expected non-staging verdict $expected: $r"
  [ ! -f "$pend" ] || fail "$task left a stale pending observation committable"
  commit_baseline "$dir" "$task" "$r" || fail "$task could not run a no-op commit"
  [ "$(cat "$record")" = "$before" ] || fail "$task promoted a stale pending observation"
  r=$(movement "$dir" "$task" "$@")
  [ "$(verdict_of "$r")" = "$expected" ] \
    || fail "$task fabricated $(verdict_of "$r") after discarding stale pending state: $r"
}

test_nonstaging_verdicts_discard_stale_pending() {
  local dir r

  dir=$(make_case stale-pending-unreadable)
  assert_nonstaging_discards_stale_pending "$dir" missing unobserved

  dir=$(make_case stale-pending-none)
  put_task "$dir" held
  assert_nonstaging_discards_stale_pending "$dir" held none

  dir=$(make_case stale-pending-cycle)
  put_task "$dir" held blocked_by=up-a
  put_task "$dir" up-a blocked_by=held
  assert_nonstaging_discards_stale_pending "$dir" held cycle

  dir=$(make_case stale-pending-bound)
  put_task "$dir" held blocked_by=up-a
  put_task "$dir" up-a blocked_by=up-b
  put_task "$dir" up-b
  assert_nonstaging_discards_stale_pending "$dir" held unobserved FM_BLOCKER_MAX_DEPTH=1

  dir=$(make_case stale-pending-missing-state)
  r=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$dir/fixtures" bash -c '
    set -u
    . "$1"
    fm_blocker_movement held "$2"
  ' _ "$LIB" "$dir/absent-state")
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a missing state directory did not remain could-not-observe: $r"

  pass "every non-staging verdict discards stale pending observations"
}

test_staging_failure_is_could_not_observe_and_leaves_no_pending() {
  local dir r probe
  dir=$(make_case staging-failure)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  chmod 0500 "$dir/state"
  probe="$dir/state/.write-probe"
  if : > "$probe" 2>/dev/null; then
    rm -f "$probe"
    chmod 0700 "$dir/state"
    printf 'skip - blocker staging failure (state remains writable)\n'
    return 0
  fi
  r=$(movement "$dir" held)
  chmod 0700 "$dir/state"
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a staging failure was treated as an observed verdict: $r"
  case "$(detail_of "$r")" in
    *could\ not\ be\ recorded*) : ;;
    *) fail "the staging failure did not name the durable observation failure: $r" ;;
  esac
  [ ! -f "$(fm_blocker_pending_path "$dir/state" held)" ] \
    || fail "a staging failure left a committable pending observation"
  pass "a staging failure is could-not-observe and leaves nothing committable"
}

test_canonical_task_ids_guard_blocker_state_paths() {
  local dir id before after r
  dir=$(make_case canonical-task-ids)
  printf 'keep\n' > "$dir/state/.hidden.blockers.pending"
  printf 'keep\n' > "$dir/state/...blockers.pending"
  before=$(find "$dir/state" -type f -print | LC_ALL=C sort)
  for id in .hidden ..; do
    r=$(movement "$dir" "$id")
    [ "$(verdict_of "$r")" = unobserved ] \
      || fail "the canonical task-id rejection did not surface for $id: $r"
    [ -z "$(fm_blocker_record_path "$dir/state" "$id" 2>/dev/null)" ] \
      || fail "the public record path accepted canonical-invalid id $id"
    [ -z "$(fm_blocker_pending_path "$dir/state" "$id" 2>/dev/null)" ] \
      || fail "the public pending path accepted canonical-invalid id $id"
    fm_blocker_commit "$dir/state" "$id" bogus-token \
      || fail "commit did not safely ignore canonical-invalid id $id"
  done
  after=$(find "$dir/state" -type f -print | LC_ALL=C sort)
  [ "$after" = "$before" ] \
    || fail "canonical-invalid task ids created or removed blocker state"
  pass "canonical task-id validation guards every blocker state path"
}

test_stale_staging_temp_is_reclaimed() {
  local dir r pend
  dir=$(make_case stale-staging-temp)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  seed_baseline "$dir" held
  pend=$(fm_blocker_pending_path "$dir/state" held)
  r=$(PATH="$dir/fakebin:$PATH" FM_FAKE_TASKS_DIR="$dir/fixtures" bash -c '
    set -u
    . "$1"
    pend=$(fm_blocker_pending_path "$2" "$3")
    printf "crash residue\n" > "$pend.tmp.$$"
    fm_blocker_movement "$3" "$2"
  ' _ "$LIB" "$dir/state" held)
  [ "$(verdict_of "$r")" = unchanged ] \
    || fail "a stale staging temp prevented the true unchanged verdict: $r"
  if find "$dir/state" -name 'held.blockers.pending.tmp.*' -print | grep . >/dev/null 2>&1; then
    fail "a reclaimed staging temp survived the successful observation"
  fi
  [ -f "$pend" ] || fail "reclaiming the stale temp did not atomically stage the current observation"
  pass "a stale staging temp is overwritten and reclaimed"
}

# A blocker id outside the id grammar makes the SET unenumerable rather than
# being skipped, because a smaller set would compare equal and suppress.
test_malformed_blocker_id_is_could_not_observe() {
  local dir r
  dir=$(make_case malformed-id)
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by='upstream,../escape' held=yes hold_kind=external
  r=$(movement "$dir" held)
  [ "$(verdict_of "$r")" = unobserved ] \
    || fail "a malformed blocker id was silently dropped from the set: $r"
  pass "a malformed blocker id makes the set unenumerable rather than smaller"
}

# Every verdict this library can print is a declared member of its vocabulary,
# and the membership predicate covers exactly that set. A verdict added later
# without teaching the consumers is what this closes.
test_movement_vocabulary_is_total() {
  local dir v r seen='' expect
  for v in $FM_BLOCKER_MOVEMENT_VOCABULARY; do
    fm_blocker_movement_is_known "$v" || fail "declared verdict '$v' is not recognised by its own predicate"
  done
  fm_blocker_movement_is_known cleared && fail "an undeclared verdict was accepted as known"
  fm_blocker_movement_is_known '' && fail "an empty verdict was accepted as known"

  dir=$(make_case vocabulary)
  # none
  put_task "$dir" plain held=yes hold_kind=external
  seen="$seen $(verdict_of "$(movement "$dir" plain)")"
  # unobserved (first observation), then unchanged, then moved
  put_task "$dir" upstream state=in_flight
  put_task "$dir" held blocked_by=upstream held=yes hold_kind=external
  r=$(movement "$dir" held)
  seen="$seen $(verdict_of "$r")"
  commit_baseline "$dir" held "$r"
  r=$(movement "$dir" held)
  seen="$seen $(verdict_of "$r")"
  commit_baseline "$dir" held "$r"
  put_task "$dir" upstream state=done closed=2026-08-17
  seen="$seen $(verdict_of "$(movement "$dir" held)")"
  # cycle
  put_task "$dir" loop blocked_by=loop held=yes hold_kind=external
  seen="$seen $(verdict_of "$(movement "$dir" loop)")"

  for v in $seen; do
    fm_blocker_movement_is_known "$v" || fail "the library printed an undeclared verdict '$v'"
  done
  for expect in none unobserved unchanged moved cycle; do
    case " $seen " in
      *" $expect "*) : ;;
      *) fail "the vocabulary walk never produced '$expect', so it proves nothing about that arm" ;;
    esac
  done
  pass "every printed verdict is a declared member of the movement vocabulary, and all five are reachable"
}

# Anti-vacuity for the double above: the real backlog tool's field grammar is
# what this library actually parses in production, so drive it once for real.
test_real_backlog_grammar_is_parsed() {
  local dir home r
  if ! command -v tasks-axi >/dev/null 2>&1; then
    printf 'skip - real backlog grammar (tasks-axi not installed)\n'
    return 0
  fi
  dir=$(make_case real-grammar)
  home="$dir/home"
  mkdir -p "$home/data"
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  ( cd "$home" \
    && tasks-axi add real-upstream --title "upstream fixture" \
    && tasks-axi add real-held --title "held fixture" \
    && tasks-axi block real-held --by real-upstream \
    && tasks-axi hold real-held --reason "waiting on the upstream item" --kind external ) >/dev/null 2>&1 \
    || fail "could not seed a real backlog fixture"

  r=$(FM_HOME="$home" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_blocker_set "$2"
  ' _ "$LIB" real-held)
  [ "$r" = real-upstream ] \
    || fail "the real backlog grammar did not yield the recorded blocker (got '$r')"

  r=$(FM_HOME="$home" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_blocker_movement "$2" "$3"
  ' _ "$LIB" real-held "$dir/state")
  [ "$(verdict_of "$r")" = unobserved ] || fail "a real first observation was not could-not-observe: $r"
  commit_baseline "$dir" real-held "$r"
  r=$(FM_HOME="$home" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_blocker_movement "$2" "$3"
  ' _ "$LIB" real-held "$dir/state")
  [ "$(verdict_of "$r")" = unchanged ] || fail "a real unmoved blocker did not suppress: $r"
  commit_baseline "$dir" real-held "$r"

  ( cd "$home" && tasks-axi "done" real-upstream ) >/dev/null 2>&1 \
    || fail "could not move the real blocker"
  r=$(FM_HOME="$home" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    fm_blocker_movement "$2" "$3"
  ' _ "$LIB" real-held "$dir/state")
  [ "$(verdict_of "$r")" = moved ] || fail "a real blocker that moved did not trigger re-evaluation: $r"
  pass "the real backlog tool's own grammar drives the same verdicts as the double"
}

test_unmoved_blocker_produces_no_wake
test_moved_blocker_triggers_reevaluation
test_prose_edit_is_not_movement
test_no_recorded_blocker_keeps_the_timer
test_unreadable_blocker_is_could_not_observe
test_absent_reader_is_could_not_observe
test_unreadable_explicit_home_never_falls_back_to_current_directory
test_first_observation_is_could_not_observe
test_blocker_leaving_the_set_is_movement
test_last_blocker_clearing_is_movement_then_falls_back_to_the_timer
test_movement_outranks_could_not_observe
test_could_not_observe_outranks_unchanged
test_cycle_is_refused
test_self_edge_is_refused
test_depth_bound_is_could_not_observe_and_names_itself
test_node_bound_is_could_not_observe_and_names_itself
test_node_bound_applies_across_a_wide_graph
test_shared_descendant_is_expanded_once
test_dependency_survives_a_restart
test_uncommitted_observation_repeats_the_wake
test_nonstaging_verdicts_discard_stale_pending
test_staging_failure_is_could_not_observe_and_leaves_no_pending
test_canonical_task_ids_guard_blocker_state_paths
test_stale_staging_temp_is_reclaimed
test_malformed_blocker_id_is_could_not_observe
test_movement_vocabulary_is_total
test_real_backlog_grammar_is_parsed

printf 'all fm-blocker-lib tests passed\n'
