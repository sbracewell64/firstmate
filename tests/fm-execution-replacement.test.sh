#!/usr/bin/env bash
# Behavior tests for SANCTIONED SAME-LANE EXECUTION-ATTEMPT REPLACEMENT: a lane
# whose provider window has closed continuing on a qualified alternate without
# surrendering its work custody and without asking the allocator for a slot.
#
# The measured origin is a lane holding a pool slot with clean committed work and
# an authorized merge waiting on it, whose worker binding answered "the usage
# limit has been reached" while another routed binding had capacity and the pool
# had zero allocatable slots. Nothing was wrong with the work and nothing could
# be retried; what could no longer execute was the BINDING. Every case below is
# one control on that transition.
#
# The cases drive bin/fm-attempt.sh and bin/fm-spawn.sh for real, against a real
# isolated git worktree, a real routed dispatch policy read by the real
# bin/fm-route.sh, and a controlled process table - so a verdict comes from the
# owners that produce it in the fleet rather than from a constant restated here.
set -u

# fail() inside a command substitution kills only the subshell, so an aborting
# make_lane hands its caller an empty string and the suite keeps going - and then
# exits on its LAST case's status, which the runner reads as a pass. The identity
# contract closes that: every declared test must have reported success by the
# end, so a case that never reached its pass() is a nonzero exit rather than a
# `not ok` nobody's exit status carried.
FM_TEST_IDENTITY_CONTRACT=1
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ATTEMPT="$ROOT/bin/fm-attempt.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
GUARD="$ROOT/bin/fm-worktree-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-execution-replacement)

# The lane's own binding and the alternate it may move to. Both live in one
# route's ordered pool; UNPOOLED is deliberately outside it, which is what makes
# "ineligible" observable rather than asserted.
PRIMARY=vendor/large
ALTERNATE=other/small
UNPOOLED=vendor/small

# A routed policy with the shape a live home uses. Read by the real
# bin/fm-route.sh, so eligibility here is the fleet's own answer.
write_routed_config() {  # <home> [floor-extra-json]
  local home=$1 extra=${2:-}
  cat > "$home/config/crew-dispatch.json" <<JSON
{
  "_floors": {
    "F-MED": { "effort_floor": "medium", "context_ceiling": 140000, "tool_loop": "verified-agentic"$extra }
  },
  "_models": {
    "vendor/large": { "smart_zone": 140000, "effort_expressible": ["low","medium","high"], "tool_loop": "verified-agentic" },
    "other/small":  { "smart_zone": 140000, "effort_expressible": ["low","medium"], "tool_loop": "verified-agentic" },
    "vendor/small": { "smart_zone": 140000, "effort_expressible": ["low","medium"], "tool_loop": "verified-agentic" }
  },
  "rules": [
    { "when": "ordinary implementation", "route": "R-MED", "floor": "F-MED",
      "use": { "harness": "codex", "model": "$PRIMARY", "effort": "medium" },
      "pool": ["$PRIMARY", "$ALTERNATE"] }
  ],
  "default": { "harness": "codex", "model": "$PRIMARY", "effort": "medium", "route": "R-MED", "floor": "F-MED" }
}
JSON
}

# One lane, dispatched for real and then left in the state the origin describes:
# committed work in its own worktree, a recorded slot, and a worker that is gone.
# Echoes "<home>|<project>|<worktree>|<fakebin>|<case-dir>|<id>".
make_lane() {  # <name> [floor-extra-json]
  local name=$1 extra=${2:-} case_dir home proj wt fakebin id out rc
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/pool/slot1"
  id="$name-a1"
  fakebin=$(fm_fakebin "$case_dir")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" \
    "$case_dir/pool" "$case_dir/proc/999999"

  # A tmux whose session is GONE, which is the endpoint state a replaced worker
  # leaves behind, and which fm_backend_agent_state classifies as `missing` -
  # one of the two words that license recovery.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
# The pane reports the slot it was actually told to enter, so a dispatch that
# names the WRONG slot lands in the wrong slot instead of quietly landing in the
# right one. A pane that always answered with the expected path would make every
# slot-selection assertion below vacuous.
case "$*" in
  *"treehouse enter "*)
    entered=$*
    entered=${entered#*treehouse enter }
    entered=${entered%% *}
    entered=${entered#\'}
    entered=${entered%\'}
    printf '%s\n' "$entered" > "${FM_FAKE_ENTERED:-/dev/null}"
    ;;
esac
# The pane-liveness probe bin/fm-crew-state.sh reads, answered separately from
# every other tmux call so ONE case can take the endpoint away without changing
# what the session or the slot report. Inert unless the case asks for it.
case "$*" in
  *"#{pane_id}"*)
    if [ -n "${FM_FAKE_PANE_GONE:-}" ]; then
      printf "can't find pane\n" >&2
      exit 1
    fi
    printf '%%0\n'
    exit 0 ;;
esac
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "${FM_FAKE_ENTERED:-/nonexistent}" ] && [ -n "${FM_FAKE_POOL_DIR:-}" ]; then
      printf '%s/%s\n' "$FM_FAKE_POOL_DIR" "$(cat "$FM_FAKE_ENTERED")"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) printf "can't find session: firstmate\n" >&2; exit 1 ;;
  # The stub harness: consume the launch brief and report a first turn, so the
  # dispatch reaches its own subject instead of stopping at the delivery gate.
  send-keys) fm-fake-deliver "$*"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # A treehouse that RECORDS every call, so "the allocator was not consulted" is
  # an observation with a positive counterpart rather than an absence.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:-/dev/null}"
if [ "${1:-}" = status ] && [ "${2:-}" = --help ]; then
  printf 'Usage:\n  treehouse status [flags]\n\nFlags:\n      --json   Print pool status as JSON\n'
  exit 0
fi
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then echo '[]'; exit 0; fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  write_routed_config "$home" "$extra"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n\nDelivery contract: mode=no-mistakes\n' "$id" > "$home/data/$id/brief.md"

  # A crew-state reader that reports an idle lane: no run is executing, so
  # nothing irreversible is in flight.
  # It also REFUSES an argument order the real reader would answer in prose. A
  # stub that ignored its arguments would answer structured JSON to a call the
  # real script renders as prose, and every case here would pass against a gate
  # that never obtained a structured answer in the fleet at all.
  cat > "$case_dir/crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" != --json ]; then
  printf 'stub: --json must be argument 1, got "%s"; bin/fm-crew-state.sh renders prose otherwise\n' "${1:-}" >&2
  exit 2
fi
printf '%s\n' "${FM_FAKE_CREW_STATE_JSON:-{\"state\":\"idle\",\"run_step\":null\}}"
SH
  chmod +x "$case_dir/crew-state.sh"

  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$PRIMARY" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION) || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "the lane's first dispatch must succeed"$'\n'"$out"

  # The lane's committed work, and the worker that made it recorded as the
  # worktree's owner. The recorded identity resolves against nothing live, which
  # is exactly a worker that is gone.
  printf 'lane work\n' > "$wt/work.txt"
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid add work.txt >/dev/null
  git -C "$wt" -c user.name=t -c user.email=t@example.invalid commit -qm "lane work"
  {
    echo "worktree_owner_pid=999999"
    echo "worktree_owner_identity=linux-starttime=1 cmdline-hex=00"
  } >> "$home/state/$id.meta"
  printf '%s\n' "$home|$proj|$wt|$fakebin|$case_dir|$id"
}

# One spawn, with the case's fakes on PATH and its own home. Kept in one place so
# every case dispatches exactly the way the fleet does.
spawn_in() {  # <case-dir> <spawn-args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_PROJECTS_OVERRIDE="$case_dir/home/projects" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$case_dir/pool/slot1" \
    FM_FAKE_TMUX_LOG="$case_dir/tmux.log" FM_FAKE_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    FM_FAKE_ENTERED="$case_dir/entered" FM_FAKE_POOL_DIR="$case_dir/pool" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$1" "$case_dir/project" "${@:2}" 2>&1
}

# One bin/fm-attempt.sh call against the case's home, controlled process table
# and controlled current-state reader.
attempt_in() {  # <case-dir> <args...>
  local case_dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$case_dir/home" \
    FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" \
    FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_PROC_ROOT_OVERRIDE="${FM_PROC_ROOT_FOR_CASE:-$case_dir/proc}" \
    FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN_FOR_CASE:-$case_dir/crew-state.sh}" \
    FM_FAKE_CREW_STATE_JSON="${FM_FAKE_CREW_STATE_JSON:-}" \
    FM_FAKE_PANE_GONE="${FM_FAKE_PANE_GONE:-}" \
    PATH="$case_dir/fakebin:$PATH" \
    "$ATTEMPT" "$@" 2>&1
}

rec_field() {  # <case-dir> <id> <key>
  sed -n "s/^$3=//p" "$1/home/state/$2.attempt" | tail -1
}

meta_field() {  # <case-dir> <id> <key>
  sed -n "s/^$3=//p" "$1/home/state/$2.meta" | tail -1
}

# Replace, with the ordinary arguments a lane whose provider window closed uses.
replace_lane() {  # <case-dir> <id> [extra args...]
  local case_dir=$1 id=$2
  shift 2
  attempt_in "$case_dir" replace "$id" --alternate "$ALTERNATE" \
    --reason "provider window exhausted" "$@"
}

# --- Control 1, 2 and 14: the same slot, no allocator, and never a directory ---

# CONTROL 1: an exhausted primary plus a qualified alternate continues on the
# SAME slot. CONTROL 2: the replacement asks the allocator for nothing.
test_c01_c02_the_lane_continues_on_its_own_slot_and_asks_for_no_other() {
  local rec case_dir id wt out rc first_alloc pre_head
  rec=$(make_lane c01)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  # The contrast that makes the absence below an observation: an ORDINARY
  # dispatch consults the allocator, and the log proves this fake records it.
  first_alloc=$(cat "$case_dir/treehouse.log")
  assert_contains "$first_alloc" "status --json" \
    "the ordinary dispatch must have consulted the treehouse allocator"
  assert_contains "$(cat "$case_dir/tmux.log")" "treehouse get" \
    "the ordinary dispatch must have acquired its slot with treehouse get"

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "an exhausted primary with a qualified alternate must be sanctioned"$'\n'"$out"

  : > "$case_dir/treehouse.log"
  : > "$case_dir/tmux.log"
  pre_head=$(git -C "$wt" rev-parse HEAD)
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor dispatch must succeed"$'\n'"$out"

  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] \
    || fail "the successor must hold the SAME worktree, got $(meta_field "$case_dir" "$id" worktree)"
  [ -f "$wt/work.txt" ] || fail "the lane's committed work must still be in the slot"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$pre_head" ] \
    || fail "a branch-sitting lane's successor must open on the predecessor's exact head"

  assert_not_contains "$(cat "$case_dir/treehouse.log")" "status" \
    "the successor must not consult the allocator at all"
  assert_not_contains "$(cat "$case_dir/tmux.log")" "treehouse get" \
    "treehouse get ACQUIRES and RESETS a slot; a successor must never reach it"
  assert_contains "$(cat "$case_dir/tmux.log")" "treehouse enter 'slot1'" \
    "the successor must enter the slot it already holds, by name - enter does not reset it"
  pass "control 1+2: the lane continues on its own slot and requests no allocator slot"
}

# CONTROL 14: allocation truth comes from the treehouse allocator and the
# ownership record it backs, NEVER from a directory count. The pool directory is
# what changes here; the answer must not.
test_c14_allocation_truth_is_never_a_directory_count() {
  local rec case_dir id wt proj out rc with_five with_one n
  rec=$(make_lane c14)
  IFS='|' read -r _ proj wt _ case_dir id <<EOF
$rec
EOF
  # Four more slots in the pool, and REAL ones: usable worktrees of the same
  # project, so landing on the wrong one would work rather than fail. A pool of
  # empty directories would let a wrong pick fail for the wrong reason.
  # --detach rather than a new branch, so adding is IDEMPOTENT: a second add that
  # silently failed on an existing branch name would leave the pool holding one
  # slot while the case believed it held five, and every assertion below would
  # pass without ever measuring anything.
  add_slots() {
    for n in 2 3 4 5; do
      [ -d "$case_dir/pool/slot$n" ] && continue
      git -C "$proj" worktree add --quiet --detach "$case_dir/pool/slot$n" \
        || fail "the case must be able to add pool slot $n"
    done
    for n in 2 3 4 5; do
      [ -d "$case_dir/pool/slot$n" ] || fail "pool slot $n must exist for this case to measure anything"
    done
  }
  drop_slots() {
    for n in 2 3 4 5; do
      git -C "$proj" worktree remove --force "$case_dir/pool/slot$n" 2>/dev/null || true
      [ ! -d "$case_dir/pool/slot$n" ] || fail "pool slot $n must be gone for this half of the case"
    done
  }
  # The positive counterpart, so the absence asserted below is a contrast and not
  # an assumption: the ORDINARY dispatch took its allocation truth from the
  # allocator's own machine-readable report.
  assert_contains "$(cat "$case_dir/treehouse.log")" "status --json" \
    "the ordinary dispatch must take allocation truth from treehouse itself"

  # Four more sibling slot directories, so a reader counting or listing the pool
  # sees five where it saw one.
  add_slots
  with_five=$(replace_lane "$case_dir" "$id" --check); rc=$?
  [ "$rc" -eq 0 ] || fail "a pool of five directories must not change the verdict"$'\n'"$with_five"
  drop_slots
  with_one=$(replace_lane "$case_dir" "$id" --check); rc=$?
  [ "$rc" -eq 0 ] || fail "a pool of one directory must not change it either"$'\n'"$with_one"
  [ "${with_five#* head=}" = "${with_one#* head=}" ] \
    || fail "the verdict must not depend on how many directories the pool holds"

  # And the successor lands on the slot the RECORD names, not on whatever the
  # pool directory happens to offer.
  add_slots
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  : > "$case_dir/treehouse.log"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor dispatch must succeed"$'\n'"$out"
  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] \
    || fail "the successor must land on the slot the record names, got $(meta_field "$case_dir" "$id" worktree)"
  assert_contains "$(cat "$case_dir/tmux.log")" "treehouse enter 'slot1'" \
    "the successor must name the recorded slot rather than one found by listing the pool"
  assert_not_contains "$(cat "$case_dir/treehouse.log")" "status" \
    "and it must still take no allocation decision of its own"
  pass "control 14: the verdict and the slot follow the allocator's record, never a directory count"
}

# --- Controls 3 and 12: quiescence, and ambiguity that refuses ---------------

# CONTROL 3: replacement is refused until the old worker's process group is
# quiescent.
test_c03_replacement_is_refused_until_the_old_process_group_is_quiescent() {
  local rec case_dir id wt out rc
  rec=$(make_lane c03)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  # A process still sitting in the lane's slot: the shape a worker that has not
  # exited leaves in the process table.
  mkdir -p "$case_dir/proc/4242"
  ln -s "$wt" "$case_dir/proc/4242/cwd"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 1 ] || fail "a lane with a live process in its slot must be REFUSED, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "REFUSED" "the refusal must name which of the three values it reached"
  assert_contains "$out" "not quiescent" "the refusal must say what is still holding the lane"
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] \
    || fail "a refused replacement must mint nothing"
  assert_absent "$case_dir/home/state/$id.lineage.tmp" "a refused replacement writes no partial ledger"

  # Remove the occupant and the same call is sanctioned: the refusal was the
  # occupant, not the apparatus.
  rm -f "$case_dir/proc/4242/cwd"
  rmdir "$case_dir/proc/4242"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "with the occupant gone the same replacement must be sanctioned"$'\n'"$out"
  pass "control 3: replacement is refused while the old process group still holds the lane"
}

# CONTROL 12: ambiguous process or effect ownership is could-not-observe, and
# could-not-observe refuses. Three different ambiguities, three refusals - none
# of them narrowed into either of the other two values.
test_c12_ambiguous_ownership_is_could_not_observe_and_refuses() {
  local rec case_dir id wt out rc
  rec=$(make_lane c12)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  # (a) The slot is claimed, but no owner identity was ever recorded for it.
  grep -v '^worktree_owner_' "$case_dir/home/state/$id.meta" > "$case_dir/meta.tmp"
  cp "$case_dir/home/state/$id.meta" "$case_dir/meta.full"
  mv "$case_dir/meta.tmp" "$case_dir/home/state/$id.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an unrecorded owner identity must be could-not-observe, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "COULD_NOT_OBSERVE" "the answer must name the value it reached"
  cp "$case_dir/meta.full" "$case_dir/home/state/$id.meta"

  # (b) The process table itself could not be listed. Finding no process in a
  # table nobody read is not finding no process.
  out=$(FM_PROC_ROOT_FOR_CASE="$case_dir/empty-proc" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an unreadable process table must be could-not-observe, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "process table" "the answer must name the instrument that could not be read"

  # (c) Another lane holds the slot. A provider refusing THIS lane for quota is
  # evidence about this lane's binding and about nothing else, so the answer is a
  # refusal rather than a reclaim - whatever state the other lane is in.
  sed "s|^endpoint_task_id=.*|endpoint_task_id=aaa-other|" "$case_dir/meta.full" \
    > "$case_dir/home/state/aaa-other.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 1 ] || fail "a slot held by another lane must be REFUSED, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "no lane is ever reclaimed from another" \
    "the refusal must say that another lane is not this lane's to take"
  rm -f "$case_dir/home/state/aaa-other.meta"

  # And an unclaimed worktree is the fourth word the ownership owner can return.
  # It is could-not-observe about custody, never a free slot.
  mkdir -p "$wt/inner"
  out=$(FM_STATE_OVERRIDE="$case_dir/home/state" FM_PROC_ROOT_OVERRIDE="$case_dir/proc" \
    "$GUARD" owner-state "$wt/inner" 2>&1)
  assert_contains "$out" "unclaimed" \
    "a worktree no record claims must report unclaimed, not empty"

  # The control: with all four ambiguities removed, the same call is sanctioned.
  cp "$case_dir/meta.full" "$case_dir/home/state/$id.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "with ownership established the same replacement must be sanctioned"$'\n'"$out"
  pass "control 12: ambiguous process, table, custody and cross-lane ownership never read as permitted"
}

# --- Control 11: an irreversible operation already in flight -----------------

# CONTROL 11: a validation run in flight owns this lane's branch, so replacing
# the worker under it is refused.
test_c11_irreversible_work_in_flight_refuses_replacement() {
  local rec case_dir id out rc
  rec=$(make_lane c11)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(FM_FAKE_CREW_STATE_JSON='{"state":"working","run_step":"push"}' \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 1 ] || fail "a run in flight must REFUSE replacement, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "in flight" "the refusal must name the operation it will not interrupt"
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] \
    || fail "a refused replacement must mint nothing"

  # A reader that answers nothing is could-not-observe, never a quiet lane.
  out=$(FM_FAKE_CREW_STATE_JSON='{}' replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an unanswerable current-state read must be could-not-observe, got rc=$rc"$'\n'"$out"

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "with no run in flight the same replacement must be sanctioned"$'\n'"$out"
  pass "control 11: an operation already in flight refuses replacement"
}

# --- The dead-endpoint quiescence composition -------------------------------

# One structured crew-state answer, in bin/fm-crew-state.sh's own emitted shape.
# Written as a whole object rather than the two-key stub the other cases use,
# because the gate under test reads FOUR typed fields and a stub carrying only
# the field it happens to branch on would make the other three vacuous.
crew_state_json() {  # <state> <source> <precedence> [run_id] [run_step]
  printf '{"schema":1,"id":"x","state":"%s","source":"%s","precedence_applied":"%s"' \
    "$1" "$2" "$3"
  printf ',"busy_signal":null,"agent_liveness":null,"busy_seq":null'
  if [ -n "${5:-}" ]; then printf ',"run_step":"%s"' "$5"; else printf ',"run_step":null'; fi
  if [ -n "${4:-}" ]; then printf ',"run_id":"%s"' "$4"; else printf ',"run_id":null'; fi
  printf ',"terminal_error":null,"evidence_age_secs":null,"detail":"fixture"}\n'
}

# THE THIRD DOOR. A lane whose runtime is fully dead reads `unknown` from the
# current-state owner by design, and that unknown used to refuse - so the one
# lane whose binding most needed to move was the one lane that could never move
# it. Dead custody, an endpoint-absent unknown and no attributed run compose a
# POSITIVE quiescence, and this case drives that composition end to end.
test_a_dead_endpoint_lane_composes_quiescence_and_replaces() {
  local rec case_dir id wt out rc ledger dead_json
  rec=$(make_lane deadep)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  dead_json=$(crew_state_json unknown none endpoint-gone)

  # The check names the composition before anything is committed, so an operator
  # sees WHY an unknown was read as quiescent rather than finding out afterwards.
  out=$(FM_FAKE_CREW_STATE_JSON="$dead_json" replace_lane "$case_dir" "$id" --check); rc=$?
  [ "$rc" -eq 0 ] || fail "a dead-endpoint lane must be replaceable, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "OBSERVED_QUIESCENT" \
    "the gate must record that this unknown was composed into a positive answer"
  assert_contains "$out" "endpoint-gone" \
    "the composition must name the endpoint-absent rule that selected the unknown"
  assert_contains "$out" "no run is attributed" \
    "the composition must name the run conjunct it established"
  assert_contains "$out" "custody as dead" \
    "the composition must name the custody conjunct it established"
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] || fail "--check must commit nothing"

  out=$(FM_FAKE_CREW_STATE_JSON="$dead_json" replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement of a dead-endpoint lane must be sanctioned"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the successor must be e2, got '$(rec_field "$case_dir" "$id" execution_id)'"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$ALTERNATE" ] \
    || fail "the successor must carry the admitted alternate binding"

  # Durable, not merely printed: the ledger line that closes the predecessor says
  # how the in-flight condition was ANSWERED, so a later reader can tell a lane
  # observed idle from one whose quiescence was composed.
  ledger=$(cat "$case_dir/home/state/$id.lineage")
  assert_contains "$ledger" "inflight=observed-quiescent-endpoint-absent" \
    "the close must record that the in-flight condition was composed, not observed idle"

  # End to end: the sanctioned successor launches onto the same slot, worktree
  # and committed work. A composition that only satisfied `replace` would leave
  # the capability exactly as unusable as the refusal did.
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor of a dead-endpoint lane must launch"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = active ] \
    || fail "a confirmed launch must be recorded active, got '$(rec_field "$case_dir" "$id" execution_dispatch)'"
  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] \
    || fail "the lane must keep its own worktree across the replacement"
  [ -f "$wt/work.txt" ] || fail "the lane's committed work must survive the replacement"
  pass "a dead-endpoint lane composes quiescence, replaces, and launches its successor"
}

# The composition's boundaries, asserted as DIVERGENCE from the case above: the
# same lane, the same gate, one conjunct removed at a time. Without these the
# case above would pass just as well against a gate that admitted every unknown.
test_every_other_unknown_still_refuses_replacement() {
  local rec case_dir id out rc
  rec=$(make_lane unkbound)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  # A LIVE endpoint that could not be interpreted. Something was there and its
  # signal was unusable, which is the unknown this gate exists to refuse.
  out=$(FM_FAKE_CREW_STATE_JSON="$(crew_state_json unknown pane busy-signal-unusable)" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an unknown from a live endpoint must be COULD_NOT_OBSERVE, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "busy-signal-unusable" \
    "the refusal must name the rule that selected the unknown it would not compose"

  # An unknown whose rule reports something OTHER than an absent endpoint.
  out=$(FM_FAKE_CREW_STATE_JSON="$(crew_state_json unknown status-log unrecognized-status-verb)" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an unrecognized-verb unknown must be COULD_NOT_OBSERVE, got rc=$rc"$'\n'"$out"

  # An endpoint-absent unknown that STILL has a run attributed to it. The run
  # owns the lane's branch whatever the endpoint is doing, so the pane state
  # never carries this on its own.
  out=$(FM_FAKE_CREW_STATE_JSON="$(crew_state_json unknown run-step endpoint-gone run-77 push)" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "an attributed run must refuse even under an endpoint-absent rule, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "still attributed" \
    "the refusal must name the run conjunct that failed, not the unknown"

  # And a run in flight refuses as a REFUSAL, not as could-not-observe, with the
  # endpoint gone underneath it - the "regardless of pane state" boundary.
  out=$(FM_FAKE_CREW_STATE_JSON="$(crew_state_json working run-step run-step-over-status-log run-78 push)" \
    FM_FAKE_PANE_GONE=1 replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 1 ] || fail "an in-flight run must REFUSE regardless of pane state, got rc=$rc"$'\n'"$out"
  # A prefix assignment on a FUNCTION call outlives the call in bash, unlike one
  # on an external command, so it is cleared rather than left to reach a later
  # case as a fixture nobody asked for.
  FM_FAKE_PANE_GONE=''

  # Nothing above moved the lane.
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] \
    || fail "a refused replacement must mint nothing"
  case "$(cat "$case_dir/home/state/$id.lineage" 2>/dev/null)" in
    *event=closed*) fail "a refused replacement must close no execution on the ledger" ;;
  esac

  # The divergence itself: the same gate, the same lane, the endpoint-absent
  # composition - sanctioned. Without this the refusals above could all be a gate
  # that refuses everything.
  out=$(FM_FAKE_CREW_STATE_JSON="$(crew_state_json unknown none endpoint-gone)" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the composed unknown must still be sanctioned, got rc=$rc"$'\n'"$out"
  pass "every unknown but the composed one still refuses replacement"
}

# WRONG-SUBJECT CONTROL. Every case above feeds the gate a stub, so they measure
# the gate against a shape THIS FILE wrote. This one takes the stub away: the
# real bin/fm-crew-state.sh reads the real lane with its endpoint removed, and
# the tokens it emits are asserted before the same real reader is handed to the
# gate. If the producer ever stops emitting this composition, this case goes red
# while every stubbed case above stays green.
test_the_real_reader_emits_the_composition_the_gate_admits() {
  local rec case_dir id home fakebin out rc json
  rec=$(make_lane realep)
  IFS='|' read -r home _ _ fakebin case_dir id <<EOF
$rec
EOF
  # No validation run for this lane, deterministically: the real reader consults
  # no-mistakes when one is on PATH, and a developer machine has one.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/no-mistakes"

  # The producer's own answer for a run-less lane whose endpoint is gone.
  json=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_FAKE_PANE_GONE=1 \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-crew-state.sh" --json "$id" 2>&1)
  assert_contains "$json" '"state":"unknown"' \
    "the real reader must report unknown for a run-less lane whose endpoint is gone"
  assert_contains "$json" '"precedence_applied":"endpoint-gone"' \
    "the real reader must name endpoint-gone as the rule that selected it"
  assert_contains "$json" '"source":"none"' \
    "the real reader must attribute the answer to no run"
  assert_contains "$json" '"run_id":null' "the real reader must publish no run identity"
  assert_contains "$json" '"run_step":null' "the real reader must publish no run step"

  # The contrast that proves the fixture actually removed the endpoint rather
  # than the reader answering unknown for some unrelated reason.
  json=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    PATH="$fakebin:$PATH" "$ROOT/bin/fm-crew-state.sh" --json "$id" 2>&1)
  case "$json" in
    *'"precedence_applied":"endpoint-gone"'*)
      fail "the same lane with a LIVE endpoint must not read endpoint-gone: $json" ;;
  esac

  # And the gate, reading that same real producer, composes.
  out=$(FM_CREW_STATE_BIN_FOR_CASE="$ROOT/bin/fm-crew-state.sh" FM_FAKE_PANE_GONE=1 \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the gate must compose the REAL reader's answer, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "OBSERVED_QUIESCENT" \
    "the composition over the real reader must record itself the same way"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the real-reader composition must mint the successor"
  FM_FAKE_PANE_GONE=''
  FM_CREW_STATE_BIN_FOR_CASE=''
  pass "the real current-state reader emits the composition the gate admits"
}

# --- Controls 9 and 10: the alternate, and having none ----------------------

# CONTROL 9: an unqualified alternate refuses.
test_c09_an_unqualified_alternate_refuses() {
  local rec case_dir id out rc
  rec=$(make_lane c09)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(attempt_in "$case_dir" replace "$id" --alternate "$UNPOOLED" \
    --reason "provider window exhausted"); rc=$?
  [ "$rc" -eq 1 ] || fail "a model outside the route's pool must be REFUSED, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "not currently eligible" "the refusal must name eligibility as the reason"
  assert_contains "$out" "$ALTERNATE" "the refusal must say which candidates ARE eligible"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$PRIMARY" ] \
    || fail "a refused replacement must leave the lane on its own binding"
  pass "control 9: an alternate the routing owner does not admit refuses"
}

# CONTROL 10: an exhausted primary with NO qualified alternate leaves the lane
# HELD - not failed, not retried, and never resolved by lowering the floor.
test_c10_no_qualified_alternate_leaves_the_lane_held() {
  local rec case_dir id out rc
  rec=$(make_lane c10)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  # Every candidate in the route's pool held by the availability record, which is
  # the routing owner's own way of saying "nothing here can run now".
  FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-route.sh" availability hold "$PRIMARY" --state subscription_quota_exhausted \
      --for-seconds 3600 --evidence "fixture" >/dev/null 2>&1 \
    || fail "the fixture must be able to record an availability hold"
  FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE="$case_dir/home/config" \
    FM_STATE_OVERRIDE="$case_dir/home/state" \
    "$ROOT/bin/fm-route.sh" availability hold "$ALTERNATE" --state subscription_quota_exhausted \
      --for-seconds 3600 --evidence "fixture" >/dev/null 2>&1 \
    || fail "the fixture must be able to hold the alternate too"

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 3 ] || fail "a route with no eligible candidate must leave the lane HELD, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "HELD" "the answer must name the value it reached"
  assert_contains "$out" "stays on the execution it has" \
    "a held lane keeps the execution it has rather than being failed or retried"
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] \
    || fail "a held lane must mint no successor"
  [ -z "$(rec_field "$case_dir" "$id" terminal)" ] \
    || fail "being held is not a terminal state: the work did not fail"
  [ "$(rec_field "$case_dir" "$id" attempt)" = 1 ] \
    || fail "a held lane must spend no attempt"
  pass "control 10: an exhausted primary with no eligible alternate stays held"
}

# --- Controls 4 to 8: what changes, and what must not -----------------------

# CONTROL 4: the successor receives a NEW execution identity. CONTROL 5: the work
# lineage is unchanged. CONTROL 7: the predecessor's evidence keeps ITS producer.
# CONTROL 8: what the successor produces is attributed to the successor.
test_c04_c05_c07_c08_identity_moves_and_work_lineage_does_not() {
  local rec case_dir id wt out rc
  local before_attempt before_slot_base before_target before_state before_project
  local ledger_before predecessor_line
  rec=$(make_lane c04)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  before_attempt=$(rec_field "$case_dir" "$id" attempt)
  before_slot_base=$(meta_field "$case_dir" "$id" slot_base)
  before_target=$(meta_field "$case_dir" "$id" contribution_target)
  before_state=$(meta_field "$case_dir" "$id" base_state)
  before_project=$(meta_field "$case_dir" "$id" project)
  predecessor_line=$(grep 'execution='"$id"'/e1' "$case_dir/home/state/$id.lineage")
  ledger_before=$(cat "$case_dir/home/state/$id.lineage")
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e1" ] \
    || fail "the lane must start on execution 1"

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor dispatch must succeed"$'\n'"$out"

  # CONTROL 4 - a new identity, and a new binding, on a new pane.
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the successor must carry a NEW execution identity, got $(rec_field "$case_dir" "$id" execution_id)"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$ALTERNATE" ] \
    || fail "the successor must be recorded on the alternate binding"
  [ "$(meta_field "$case_dir" "$id" model)" = "$ALTERNATE" ] \
    || fail "the lane's live record must name the model actually running it"

  # CONTROL 5 - the work itself did not move.
  [ "$(rec_field "$case_dir" "$id" attempt)" = "$before_attempt" ] \
    || fail "a replacement must spend no attempt: the work did not fail"
  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] || fail "the worktree must not move"
  [ "$(meta_field "$case_dir" "$id" slot_base)" = "$before_slot_base" ] \
    || fail "the slot base must not be re-derived under a successor"
  [ "$(meta_field "$case_dir" "$id" contribution_target)" = "$before_target" ] \
    || fail "the contribution target must not be re-derived under a successor"
  [ "$(meta_field "$case_dir" "$id" base_state)" = "$before_state" ] \
    || fail "the base state must not change under a successor"
  [ "$(meta_field "$case_dir" "$id" project)" = "$before_project" ] \
    || fail "the project must not change under a successor"
  [ -f "$wt/work.txt" ] || fail "the lane's committed work must survive the replacement"

  # CONTROL 7 - the predecessor's line is still there, byte for byte, still
  # naming the binding that produced it.
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" "$predecessor_line" \
    "the predecessor's producer line must survive unchanged"
  assert_contains "$predecessor_line" "binding=codex/$PRIMARY" \
    "the predecessor must still be attributed to the binding that ran it"
  [ "$(printf '%s\n' "$ledger_before" | head -1)" = "$(head -1 "$case_dir/home/state/$id.lineage")" ] \
    || fail "the ledger is append-only: its first line must never be rewritten"

  # CONTROL 8 - and the successor's own line names the successor, its binding,
  # and what it succeeded.
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" \
    "event=opened execution=$id/e2" "the successor must be opened in the ledger"
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" \
    "predecessor=$id/e1" "the successor's line must name what it replaced"
  assert_contains "$(attempt_in "$case_dir" execution "$id")" "execution_id=$id/e2" \
    "new evidence is stamped with the successor, not the binding that is gone"
  pass "control 4+5+7+8: identity and binding move, work lineage and prior attribution do not"
}

# CONTROL 6: unresolved questions and active obligations survive the
# replacement. They belong to the WORK, and the work did not change hands.
test_c06_unresolved_questions_and_obligations_survive() {
  local rec case_dir id out rc status_before
  rec=$(make_lane c06)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  printf 'fm-status-event.v1 verb=needs-decision phase=review key=schema-choice summary=which schema wins\n' \
    >> "$case_dir/home/state/$id.status"
  printf 'blocked-on=upstream-release\n' > "$case_dir/home/state/$id.blockers"
  mkdir -p "$case_dir/home/data/$id"
  printf 'the captain has not answered yet\n' > "$case_dir/home/data/$id/decision-schema-choice.md"
  status_before=$(cat "$case_dir/home/state/$id.status")

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor dispatch must succeed"$'\n'"$out"

  assert_contains "$(cat "$case_dir/home/state/$id.status")" "key=schema-choice" \
    "an unresolved keyed decision must survive the replacement"
  assert_contains "$(cat "$case_dir/home/state/$id.status")" "$status_before" \
    "the lane's event history must be preserved whole, not truncated"
  assert_present "$case_dir/home/state/$id.blockers" \
    "an active blocker disposition must survive the replacement"
  assert_present "$case_dir/home/data/$id/decision-schema-choice.md" \
    "an open decision document must survive the replacement"
  pass "control 6: unresolved questions and active obligations survive replacement"
}

# --- Control 13: one active attempt, whatever happens -----------------------

# CONTROL 13: a crash or restart during the replacement reconstructs AT MOST one
# active execution attempt.
test_c13_a_crash_during_replacement_leaves_at_most_one_active_attempt() {
  local rec case_dir id out rc opens
  rec=$(make_lane c13)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  # The crash: the successor was minted and nothing launched it.
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "an unlaunched successor must be recorded sanctioned, not active"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "exactly one execution must be open after the mint"

  # Recovery re-runs the replacement. It advances the lineage rather than
  # branching it, so the record still names exactly ONE open execution.
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "recovery must be able to replace again"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e3" ] \
    || fail "a second replacement must advance the lineage, not fork it"
  opens=$(grep -c 'event=opened' "$case_dir/home/state/$id.lineage")
  [ "$opens" -eq 3 ] || fail "the ledger must record three openings, got $opens"
  [ "$(grep -c 'event=closed' "$case_dir/home/state/$id.lineage")" -eq 2 ] \
    || fail "every superseded execution must be closed exactly once"

  # And the stale identity can never be marked as the one that is running.
  out=$(attempt_in "$case_dir" dispatched "$id" --execution "$id/e2"); rc=$?
  [ "$rc" -ne 0 ] || fail "a stale execution must not be markable as dispatched"
  assert_contains "$out" "two executions claiming the same lane" \
    "the refusal must name the state it is preventing"

  # An in-progress replacement holds a lock, so a concurrent one cannot mint a
  # second successor behind its back. The fixture lock is pid-stamped the way
  # the lock library's own writer stamps it - this test process is alive, so
  # the lock is genuinely HELD rather than a bare directory the staleness
  # recovery would steal once it ages past FM_LOCK_STALE_AFTER.
  mkdir "$case_dir/home/state/$id.attempt.lock"
  printf '%s\n' "$$" > "$case_dir/home/state/$id.attempt.lock/pid"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "a concurrent replacement must be could-not-observe, got rc=$rc"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e3" ] \
    || fail "a refused concurrent replacement must mint nothing"
  rm -rf "$case_dir/home/state/$id.attempt.lock"
  pass "control 13: a crash or a concurrent attempt still leaves exactly one active execution"
}

# --- The door: nothing else may rebind a lane -------------------------------

# A lane is not rebound by relaunching it with a different model. That refusal is
# what makes `replace` - and therefore every control above - the only way in.
test_an_ordinary_relaunch_may_not_rebind_the_lane() {
  local rec case_dir id out rc windows_before
  rec=$(make_lane rebind)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  rm -f "$case_dir/home/state/$id.meta"
  windows_before=$(grep -c 'new-window' "$case_dir/tmux.log" 2>/dev/null || true)
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -ne 0 ] || fail "an ordinary relaunch onto a different model must be refused"$'\n'"$out"
  assert_contains "$out" "not rebound by relaunching" \
    "the refusal must point at the verb that does sanction a rebind"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$PRIMARY" ] \
    || fail "a refused relaunch must leave the recorded producer alone"
  # Refused BEFORE anything is created: a refusal that fired only at metadata
  # publication would leave a live window whose shell occupies a pool slot.
  [ "$(grep -c 'new-window' "$case_dir/tmux.log" 2>/dev/null || true)" = "$windows_before" ] \
    || fail "a refused rebind must not create a window"

  # A relaunch on the SAME binding is an ordinary recovery and continues.
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$PRIMARY" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -eq 0 ] || fail "a same-binding relaunch is recovery and must continue"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e1" ] \
    || fail "recovering the same binding must not mint a new producer"
  pass "the only door: an ordinary relaunch cannot rebind a lane"
}

# A successor may be launched only onto the binding a gate admitted.
test_a_successor_may_only_launch_on_the_admitted_binding() {
  local rec case_dir id out rc
  rec=$(make_lane admitted)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$PRIMARY" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "launching a successor onto a binding no gate admitted must be refused"$'\n'"$out"
  assert_contains "$out" "Only the binding a gate admitted may be launched" \
    "the refusal must say what it is protecting"

  # The HARNESS half of the binding, measured separately. A binding is
  # harness/model, and a case that only ever varies the model leaves the harness
  # half unexercised - a defect that compared just the model would pass the whole
  # suite. Both halves are pinned, so both are measured.
  out=$(spawn_in "$case_dir" "$id" --harness pi --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "launching a successor onto a harness no gate admitted must be refused"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "a refused successor launch must leave the sanctioned record untouched"
  pass "a successor launches only onto the binding its gate admitted"
}

# And only at the effort a gate admitted, so all three axes of the sanctioned
# binding - harness, model, effort - are pinned by the one door that launches.
test_a_successor_may_only_launch_at_the_admitted_effort() {
  local rec case_dir id out rc
  rec=$(make_lane effortpin)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_effort)" = medium ] \
    || fail "the sanctioned successor must carry the admitted effort, got $(rec_field "$case_dir" "$id" execution_effort)"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort low \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "launching a successor at an effort no gate admitted must be refused"$'\n'"$out"
  assert_contains "$out" "Only the effort a gate admitted may be launched" \
    "the refusal must name the pinned axis"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "a refused successor launch must leave the sanctioned record untouched"
  pass "a successor launches only at the effort its gate admitted"
}

# An empty recorded effort is an UNSTATED sanction, and an unstated condition is
# one that could not be established - so replace refuses to mint a successor
# carrying no band, and the dispatcher states one with --alternate-effort. The
# stated band is then recorded and pinned exactly as an inherited one is.
test_replace_refuses_an_unstated_effort_sanction() {
  local rec case_dir id out rc
  rec=$(make_lane effortcno)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  sed -i 's/^effort=.*/effort=default/' "$case_dir/home/state/$id.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -ne 0 ] || fail "a replace against a lane whose effort is unstated must refuse"$'\n'"$out"
  assert_contains "$out" "unstated" "the refusal must name the unstated axis"
  assert_contains "$out" "--alternate-effort" \
    "the refusal must tell the dispatcher how to state the band"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" != sanctioned ] \
    || fail "a refused replace must not have minted a successor"

  # Stated explicitly, the band is recorded, pinned, and the lane launches.
  out=$(replace_lane "$case_dir" "$id" --alternate-effort medium); rc=$?
  [ "$rc" -eq 0 ] || fail "a replace that states the band must be sanctioned"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_effort)" = medium ] \
    || fail "the stated band must be recorded, got '$(rec_field "$case_dir" "$id" execution_effort)'"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort low \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "the stated band must be pinned against a different declared one"$'\n'"$out"
  assert_contains "$out" "Only the effort a gate admitted may be launched" \
    "the refusal must name the pinned axis"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "a successor at the stated band must launch normally"$'\n'"$out"
  pass "replace refuses an unstated effort sanction; a stated one is recorded, pinned, and launches"
}

# The launch-side half of the same rule: a sanctioned record that carries no
# band - the shape a record minted before this rule existed can have - refuses
# at the successor gate rather than accepting whatever the launch declared.
test_a_successor_with_no_effort_sanction_refuses_at_launch() {
  local rec case_dir id out rc
  rec=$(make_lane effortempty)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  sed -i '/^execution_effort=/d' "$case_dir/home/state/$id.attempt"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort low \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "a successor against a record with no effort sanction must be refused"$'\n'"$out"
  assert_contains "$out" "records no effort sanction" \
    "the refusal must name the unstated axis"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "a refused successor launch must leave the sanctioned record untouched"
  pass "a successor against a record carrying no effort sanction is refused, never adopted"
}

# The head the successor opens on is the predecessor's exact head. A clean lane
# DETACHED at its own committed head is exactly the shape an ordinary pool slot
# is left in, and the one shape where a slot-base placement would silently
# orphan the predecessor's commits to the reflog - so the invariant is pinned
# both ways: the head is unchanged, and the predecessor's head remains an
# ancestor of (or equal to) the lane head after placement. The branch-sitting
# partner assertion lives in control 1+2, so neither shape is vacuous.
test_a_detached_lane_keeps_the_predecessors_exact_head() {
  local rec case_dir id wt out rc pre_head post_head
  rec=$(make_lane detached)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  git -C "$wt" checkout --quiet --detach
  pre_head=$(git -C "$wt" rev-parse HEAD)
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "a clean detached lane must be replaceable"$'\n'"$out"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the successor dispatch on a detached lane must succeed"$'\n'"$out"
  post_head=$(git -C "$wt" rev-parse HEAD)
  [ "$post_head" = "$pre_head" ] \
    || fail "the successor must open on the predecessor's exact head: $pre_head became $post_head"
  git -C "$wt" merge-base --is-ancestor "$pre_head" HEAD 2>/dev/null \
    || git -C "$wt" merge-base --is-ancestor "$pre_head" "$post_head" \
    || fail "the predecessor's head must remain reachable from the lane head"
  pass "a successor on a clean detached lane opens on the predecessor's exact head"
}

# An orca-backed lane refuses succession as a TYPED outcome - its own exit
# status, a named condition (unverified custody reuse), and a self-contained
# lift condition pointing at the repo-tracked verification record - and the
# refusal touches nothing: no worktree, no metadata, and the sanctioned record
# stays exactly as replace minted it.
test_an_orca_lane_refuses_succession_until_custody_reuse_is_verified() {
  local rec case_dir id wt out rc
  rec=$(make_lane orcalane)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement must be sanctioned"$'\n'"$out"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --backend orca --succeed-execution); rc=$?
  [ "$rc" -eq 3 ] || fail "an orca successor dispatch must be refused with its own status, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "REFUSED" "the refusal must present as an outcome, not a crash"
  assert_contains "$out" "unverified" \
    "the refusal must name the condition rather than reading as permanent unsupport"
  assert_contains "$out" "clears when a verified orca custody-reuse path lands" \
    "the refusal must state its own lift condition"
  assert_contains "$out" "docs/verification/execution-attempt-replacement.md" \
    "the lift condition must point at the repo-tracked verification record"
  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] \
    || fail "a refused orca succession must leave the lane's recorded worktree untouched"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "a refused orca succession must leave the sanctioned successor exactly as replace minted it"

  # The refusal wedged nothing: the very same successor still launches end to
  # end on the default backend.
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the same successor on the default backend must still launch"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = active ] \
    || fail "the launched successor must be recorded active"
  pass "an orca lane refuses succession as unverified custody reuse, and the lane is untouched"
}

# And a successor dispatch with nothing sanctioned is refused outright, so the
# --succeed-execution flag can never become a way to skip the gate.
test_a_successor_dispatch_without_a_sanctioned_successor_is_refused() {
  local rec case_dir id out rc
  rec=$(make_lane unsanctioned)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -ne 0 ] || fail "a successor dispatch with nothing sanctioned must be refused"$'\n'"$out"
  assert_contains "$out" "holds no PENDING successor execution" \
    "the refusal must name what is missing"
  pass "a successor dispatch cannot skip the gate that sanctions it"
}

# An execution is only protected from rebinding once its launch is CONFIRMED. A
# dispatch that published metadata and never started produced nothing, so the
# capacity owner may retry it on the next model in the pool; one that actually
# ran may not be rebound by anything but the gate. That boundary is what the
# launch-confirmation record draws, and it is the reason it exists.
test_only_a_confirmed_launch_is_protected_from_rebinding() {
  local rec case_dir id out rc
  rec=$(make_lane confirmed)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  # The lane's first dispatch launched, so it is active and protected.
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = active ] \
    || fail "a confirmed launch must be recorded active, got $(rec_field "$case_dir" "$id" execution_dispatch)"
  rm -f "$case_dir/home/state/$id.meta"
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION); rc=$?
  [ "$rc" -ne 0 ] || fail "an execution that ran must not be rebound by a relaunch"$'\n'"$out"

  # Now the same lane with a launch that never completed: the record still says
  # launching, and the next model in the pool may take that same ordinal.
  attempt_in "$case_dir" retire "$id" >/dev/null
  out=$(attempt_in "$case_dir" open "$id" --binding "codex/$PRIMARY" --effort medium)
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = launching ] \
    || fail "an execution whose launch is unconfirmed must be recorded launching"
  out=$(attempt_in "$case_dir" open "$id" --binding "codex/$ALTERNATE" --effort medium); rc=$?
  [ "$rc" -eq 0 ] || fail "a launch that never completed produced nothing and may be re-pointed"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$ALTERNATE" ] \
    || fail "the re-pointed execution must name the binding that will actually run it"
  [ "$(rec_field "$case_dir" "$id" execution)" = 1 ] \
    || fail "re-pointing an unlaunched execution must not mint a producer, since none produced anything"
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" "event=relaunched" \
    "the ledger must still say the binding moved, even where no producer changed"

  # And once that one is confirmed, it is protected exactly like the first.
  attempt_in "$case_dir" dispatched "$id" --execution "$id/e1" >/dev/null
  out=$(attempt_in "$case_dir" open "$id" --binding "codex/$PRIMARY" --effort medium); rc=$?
  [ "$rc" -ne 0 ] || fail "a confirmed launch must be protected from rebinding"$'\n'"$out"
  assert_contains "$out" "not rebound by relaunching" "the refusal must point at the gate"
  pass "only a confirmed launch is protected from rebinding; an unstarted one produced nothing"
}

# The discard-retry door, watched in BOTH directions. Ending a work attempt
# closes its execution in the same act, and the ended record then admits a
# genuine retry on ANY binding as a FRESH execution. The live half is the
# non-vacuity partner: before the end, the same different-binding dispatch is
# still refused, so the exemption cannot silently widen into no guard at all.
# The writer half asserts the contradiction can no longer be written: no record
# carries ended=1 with an execution still recorded executing.
test_an_ended_attempt_admits_a_fresh_execution_on_any_binding() {
  local case_dir id out rc
  case_dir="$TMP_ROOT/endedretry"
  id=endedretry-a1
  mkdir -p "$case_dir/home/state" "$case_dir/fakebin" "$case_dir/proc"
  out=$(attempt_in "$case_dir" open "$id" --binding "codex/$PRIMARY" --effort medium); rc=$?
  [ "$rc" -eq 0 ] || fail "the first dispatch must open execution 1"$'\n'"$out"
  out=$(attempt_in "$case_dir" dispatched "$id" --execution "$id/e1"); rc=$?
  [ "$rc" -eq 0 ] || fail "confirming the launch must succeed"$'\n'"$out"

  out=$(attempt_in "$case_dir" check "$id" --binding "codex/$ALTERNATE"); rc=$?
  [ "$rc" -ne 0 ] || fail "a LIVE record must still refuse a second binding"$'\n'"$out"
  assert_contains "$out" "not rebound by relaunching" \
    "the live refusal must keep pointing at replace"

  out=$(attempt_in "$case_dir" end "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "ending the attempt must succeed"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" ended)" = 1 ] \
    || fail "the end must be recorded on the attempt"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = ended ] \
    || fail "ending the attempt must close its execution, got '$(rec_field "$case_dir" "$id" execution_dispatch)'"
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" "event=closed execution=$id/e1" \
    "the close must be on the lineage ledger"
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" "disposition=discarded" \
    "the close must name the discard as its disposition"

  out=$(attempt_in "$case_dir" check "$id" --binding "codex/$ALTERNATE"); rc=$?
  [ "$rc" -eq 0 ] || fail "an ended record must admit a retry on a different binding"$'\n'"$out"
  out=$(attempt_in "$case_dir" open "$id" --binding "codex/$ALTERNATE" --effort medium); rc=$?
  [ "$rc" -eq 0 ] || fail "the retry dispatch must open"$'\n'"$out"
  assert_contains "$out" "attempt=2" "the end must have spent attempt 1, so the retry is attempt 2"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the retry must mint a FRESH execution, got '$(rec_field "$case_dir" "$id" execution_id)'"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$ALTERNATE" ] \
    || fail "the fresh execution must carry the declared binding"
  assert_contains "$(cat "$case_dir/home/state/$id.lineage")" "event=opened execution=$id/e2" \
    "the fresh execution must have its own opened line"
  pass "an ended attempt closes its execution and admits a fresh-execution retry on any binding"
}

# --- The lane the capability's own first day locked out ---------------------

# The record shape of a lane dispatched BEFORE the execution lineage existed:
# an attempt count, a budget, and none of the fields that era never wrote.
# Produced by REMOVING them from a real dispatch rather than by hand-writing a
# record, so the fixture stays the shape a live pre-schema lane actually carries.
strip_lineage() {  # <case-dir> <id>
  local rec="$1/home/state/$2.attempt"
  LC_ALL=C grep -v '^execution' "$rec" > "$rec.pre" && mv -f "$rec.pre" "$rec"
  rm -f "$1/home/state/$2.lineage"
}

# The residue an adoption interrupted between its two writes leaves behind, and
# the same record in each of the states it must NOT be read as.
set_execution_state() {  # <case-dir> <id> <dispatch-state>
  local rec="$1/home/state/$2.attempt"
  {
    LC_ALL=C grep -v '^execution' "$rec"
    printf 'execution=1\nexecution_id=%s/e1\nexecution_binding=codex/%s\n' "$2" "$PRIMARY"
    printf 'execution_effort=medium\nexecution_dispatch=%s\n' "$3"
  } > "$rec.new" && mv -f "$rec.new" "$rec"
}

# THE LIVE RED. Every lane dispatched before this lineage existed carries a
# record with no execution at all, and the reader-side rule "no recorded
# execution attempt, so there is nothing to replace" refused every one of them -
# on the day the capability landed, to its first production use. The lane's
# producer is a durable record the fleet already wrote, so `replace` reads it
# back rather than refusing, and the successor proceeds through every gate the
# ordinary path uses.
test_a_prelineage_lane_adopts_its_recorded_binding_and_replaces() {
  local rec case_dir id wt out rc before_attempt ledger
  rec=$(make_lane preline)
  IFS='|' read -r _ _ wt _ case_dir id <<EOF
$rec
EOF
  before_attempt=$(rec_field "$case_dir" "$id" attempt)
  strip_lineage "$case_dir" "$id"
  [ -z "$(rec_field "$case_dir" "$id" execution)" ] \
    || fail "the fixture must carry no execution lineage"
  assert_contains "$(attempt_in "$case_dir" execution "$id")" "execution=0" \
    "a pre-lineage lane reads as execution=0 - could-not-observe about its producer"

  # The check accounts for the adoption, so it names the execution the mint will
  # actually produce rather than the one bare ordinal arithmetic implies.
  out=$(replace_lane "$case_dir" "$id" --check); rc=$?
  [ "$rc" -eq 0 ] || fail "a pre-lineage lane must be replaceable, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "successor=$id/e2" \
    "the check must name the successor the adoption produces, not e1"
  assert_contains "$out" "adopting=$id/e1" "the check must say what it would adopt"
  assert_contains "$out" "adopted_binding=codex/$PRIMARY" \
    "the check must name the binding the adoption reads out of the lane's own record"
  [ -z "$(rec_field "$case_dir" "$id" execution)" ] || fail "--check must commit nothing"
  [ ! -f "$case_dir/home/state/$id.lineage" ] || fail "--check must write no ledger"

  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "the replacement of a pre-lineage lane must be sanctioned"$'\n'"$out"

  # The successor is e2, on the alternate, sanctioned and waiting - the ordinary
  # shape, reached from a record that had no lineage at all.
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the successor must be e2, got '$(rec_field "$case_dir" "$id" execution_id)'"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$ALTERNATE" ] \
    || fail "the successor must carry the admitted alternate binding"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = sanctioned ] \
    || fail "the successor must be sanctioned and unlaunched"
  [ "$(rec_field "$case_dir" "$id" attempt)" = "$before_attempt" ] \
    || fail "an adoption spends no attempt: the work did not fail"

  # The adopted producer is on the ledger, named as adopted, and says plainly
  # that nobody watched it launch. A line a reader could mistake for a
  # launch-confirmed execution would attribute an observation nobody made.
  ledger=$(cat "$case_dir/home/state/$id.lineage")
  assert_contains "$ledger" "event=opened execution=$id/e1" \
    "the adopted predecessor must have its own opened line"
  assert_contains "$ledger" "disposition=adopted-from-meta" \
    "the adopted line must carry its own provenance disposition"
  assert_contains "$ledger" "launch=unobserved" \
    "the adopted line must never claim its launch was observed"
  assert_contains "$ledger" "evidence_source=state/$id.meta" \
    "the adopted line must name the durable record its binding came from"
  assert_contains "$ledger" "binding=codex/$PRIMARY" \
    "the adopted line must name the binding that produced the work already here"
  assert_contains "$ledger" "event=closed execution=$id/e1" \
    "the adopted predecessor must be superseded in the same mint"
  assert_contains "$ledger" "successor=$id/e2" "the close must name its successor"
  assert_contains "$ledger" "predecessor=$id/e1" \
    "the successor's line must name what it replaced"
  [ "$(printf '%s\n' "$ledger" | grep -c 'event=opened')" -eq 2 ] \
    || fail "the ledger must record exactly two openings, got $(printf '%s\n' "$ledger" | grep -c 'event=opened')"

  # And the successor launches: the whole point of the adoption is that the lane
  # keeps its slot, its worktree and its committed work.
  out=$(spawn_in "$case_dir" "$id" --harness codex --model "$ALTERNATE" --effort medium \
    --route R-MED --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION \
    --succeed-execution); rc=$?
  [ "$rc" -eq 0 ] || fail "the sanctioned successor of an adopted lane must launch"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_dispatch)" = active ] \
    || fail "a confirmed launch must be recorded active, got '$(rec_field "$case_dir" "$id" execution_dispatch)'"
  [ "$(meta_field "$case_dir" "$id" worktree)" = "$wt" ] \
    || fail "the adopted lane must keep its own worktree"
  [ -f "$wt/work.txt" ] || fail "the lane's committed work must survive the adoption"
  [ "$(meta_field "$case_dir" "$id" model)" = "$ALTERNATE" ] \
    || fail "the lane's live record must name the model actually running it"
  pass "a pre-lineage lane adopts its recorded binding, replaces, and launches its successor"
}

# The adoption reads a durable record and never guesses. Metadata that names no
# binding leaves the producer of the work already in this lane unnameable, and
# an unnameable producer is could-not-observe, not a blank one to invent.
test_a_prelineage_lane_without_a_recorded_binding_refuses() {
  local rec case_dir id out rc
  rec=$(make_lane prelinenobind)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  strip_lineage "$case_dir" "$id"
  LC_ALL=C grep -v '^model=' "$case_dir/home/state/$id.meta" > "$case_dir/meta.new" \
    && mv -f "$case_dir/meta.new" "$case_dir/home/state/$id.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "a lane whose binding cannot be read must be COULD_NOT_OBSERVE, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "COULD_NOT_OBSERVE" "the refusal must name which of the three values it reached"
  assert_contains "$out" "model='none'" "the refusal must name the field it could not read"
  [ -z "$(rec_field "$case_dir" "$id" execution)" ] \
    || fail "a refused adoption must commit nothing"
  [ ! -f "$case_dir/home/state/$id.lineage" ] || fail "a refused adoption must write no ledger"

  # The whole metadata missing is the same answer for a stronger reason, and it
  # is the refusal that already owned this case.
  rm -f "$case_dir/home/state/$id.meta"
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "a lane with no metadata at all must be COULD_NOT_OBSERVE, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "no task metadata" "the absent-metadata refusal must keep its own words"
  pass "an adoption with no readable binding refuses could-not-observe and writes nothing"
}

# An adopted execution is the opposite of an unstarted one. Its launch was never
# observed, but the evidence in the lane is ALREADY attributed to it, so the
# permission an unconfirmed `launching` execution has - to be re-pointed onto
# another binding without a gate - must not extend to it. The divergence is
# asserted here so the case cannot go quietly vacuous: the SAME record in
# `launching` is admitted, and only the adopted token is refused.
test_an_adopted_execution_is_not_re_pointed_like_an_unstarted_one() {
  local rec case_dir id out rc
  rec=$(make_lane adoptedtoken)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  strip_lineage "$case_dir" "$id"

  set_execution_state "$case_dir" "$id" adopted
  out=$(attempt_in "$case_dir" check "$id" --binding "codex/$ALTERNATE"); rc=$?
  [ "$rc" -ne 0 ] || fail "an ADOPTED execution must not be re-pointed onto another binding"$'\n'"$out"
  assert_contains "$out" "adopted execution attempt" \
    "the refusal must name the state it is protecting"
  assert_contains "$out" "bin/fm-attempt.sh replace" \
    "the refusal must point at the one verb that mints a successor"
  [ "$(rec_field "$case_dir" "$id" execution_binding)" = "codex/$PRIMARY" ] \
    || fail "a refused rebind must leave the adopted producer alone"

  # THE DIVERGENCE. The same record, differing only in the token, is admitted -
  # so the refusal above is controlled by the token and not by the fixture.
  set_execution_state "$case_dir" "$id" launching
  out=$(attempt_in "$case_dir" check "$id" --binding "codex/$ALTERNATE"); rc=$?
  [ "$rc" -eq 0 ] || fail "an unconfirmed launch produced nothing and must stay re-pointable"$'\n'"$out"

  # A same-binding relaunch of an adopted execution is ordinary recovery and
  # continues, so the strict reading never becomes a second deadlock.
  set_execution_state "$case_dir" "$id" adopted
  out=$(attempt_in "$case_dir" check "$id" --binding "codex/$PRIMARY"); rc=$?
  [ "$rc" -eq 0 ] || fail "recovering an adopted lane on its own binding must continue"$'\n'"$out"

  # And the residue is recoverable rather than a deadlock of its own: `replace`
  # sees an ordinary lineage-bearing lane and advances it, adopting nothing a
  # second time.
  out=$(replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 0 ] || fail "an interrupted adoption must still be replaceable"$'\n'"$out"
  [ "$(rec_field "$case_dir" "$id" execution_id)" = "$id/e2" ] \
    || fail "the successor of an adopted execution must be e2"
  [ "$(grep -c 'disposition=adopted-from-meta' "$case_dir/home/state/$id.lineage" || true)" -eq 0 ] \
    || fail "a record that already carries an execution must never be adopted again"
  pass "an adopted execution is refused a rebind an unstarted one is allowed, and stays replaceable"
}

# --- Assignment independence, which no record grants ------------------------

# A route whose floor requires an ADJUDICATED capability contract is a reviewing
# assignment. Replacement onto the binding that MADE the work under review is
# refused by contract, and a lane whose maker is unknown cannot establish the
# predicate at all.
test_a_reviewing_lane_refuses_a_replacement_that_is_not_independent_of_its_maker() {
  local rec case_dir id out rc cdir
  rec=$(make_lane independence)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  cdir="$case_dir/contracts"
  mkdir -p "$cdir"
  # A contract that declares adjudication, which is what makes the assignment a
  # reviewing one. Read from an overridden directory so the case owns it.
  cat > "$cdir/fixture-change-review.json" <<'JSON'
{
  "qualification_schema_version": 1,
  "id": "fixture-change-review",
  "role": "FIXTURE_CHANGE_REVIEWER",
  "adjudication": { "required": true, "independence_dimensions": ["binding"] }
}
JSON
  write_routed_config "$case_dir/home" ', "requires_capabilities": ["fixture-change-review"]'
  # A qualification reader that answers, so the case measures THIS gate rather
  # than the register's own fixtures: it refuses when maker and reviewer match.
  cat > "$case_dir/qualification.sh" <<'SH'
#!/usr/bin/env bash
maker= reviewer=
while [ $# -gt 0 ]; do
  case "$1" in
    --maker) maker=$2; shift 2 ;;
    --reviewer) reviewer=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$maker" = "$reviewer" ]; then
  printf '%s made this candidate, so it may not review it\n' "$maker" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$case_dir/qualification.sh"
  # The route's floor now requires a contract nothing is qualified for, so the
  # routing owner reports a zero route before independence is ever reached. The
  # eligibility term is stubbed for this case only, so what is measured here is
  # the independence term and nothing else.
  cat > "$case_dir/route.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = eligible ]; then
  printf '{"candidates":[{"model":"other/small","eligible":true}],"floor_axes":{"requires_capabilities":["fixture-change-review"]}}\n'
  exit 0
fi
exit 2
SH
  chmod +x "$case_dir/route.sh"

  # No maker recorded: the predicate cannot be evaluated, and an unevaluated
  # independence predicate is not a satisfied one.
  out=$(FM_ROUTE_BIN="$case_dir/route.sh" \
    FM_QUALIFICATION_BIN="$case_dir/qualification.sh" \
    FM_QUALIFICATION_CONTRACT_DIR="$cdir" \
    replace_lane "$case_dir" "$id"); rc=$?
  [ "$rc" -eq 4 ] || fail "a reviewing lane with no known maker must be could-not-observe, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "independence" "the answer must name the predicate it could not establish"

  # The maker IS the alternate: refused by contract, not merely unavailable.
  out=$(FM_ROUTE_BIN="$case_dir/route.sh" \
    FM_QUALIFICATION_BIN="$case_dir/qualification.sh" \
    FM_QUALIFICATION_CONTRACT_DIR="$cdir" \
    replace_lane "$case_dir" "$id" --maker "$ALTERNATE"); rc=$?
  [ "$rc" -eq 1 ] || fail "replacing a reviewer with its own maker must be REFUSED, got rc=$rc"$'\n'"$out"
  assert_contains "$out" "may not take this assignment" \
    "the refusal must be the assignment predicate's own answer"

  # A different maker, and the same replacement is sanctioned.
  out=$(FM_ROUTE_BIN="$case_dir/route.sh" \
    FM_QUALIFICATION_BIN="$case_dir/qualification.sh" \
    FM_QUALIFICATION_CONTRACT_DIR="$cdir" \
    replace_lane "$case_dir" "$id" --maker "$PRIMARY"); rc=$?
  [ "$rc" -eq 0 ] || fail "an independent alternate must be sanctioned"$'\n'"$out"
  pass "a reviewing lane refuses a replacement that is not independent of its maker"
}

# --- Retirement -------------------------------------------------------------

# The ledger retires with the record it belongs to, through the one owner that
# retires either of them.
test_the_lineage_retires_with_the_attempt_record() {
  local rec case_dir id
  rec=$(make_lane retire)
  IFS='|' read -r _ _ _ _ case_dir id <<EOF
$rec
EOF
  assert_present "$case_dir/home/state/$id.lineage" "the lane must have a ledger to retire"
  attempt_in "$case_dir" retire "$id" >/dev/null
  assert_absent "$case_dir/home/state/$id.attempt" "an ordinary release retires the record"
  assert_absent "$case_dir/home/state/$id.lineage" "and retires its ledger with it"
  pass "the execution ledger retires with the attempt record"
}

test_c01_c02_the_lane_continues_on_its_own_slot_and_asks_for_no_other
test_c14_allocation_truth_is_never_a_directory_count
test_c03_replacement_is_refused_until_the_old_process_group_is_quiescent
test_c12_ambiguous_ownership_is_could_not_observe_and_refuses
test_c11_irreversible_work_in_flight_refuses_replacement
test_c09_an_unqualified_alternate_refuses
test_c10_no_qualified_alternate_leaves_the_lane_held
test_c04_c05_c07_c08_identity_moves_and_work_lineage_does_not
test_c06_unresolved_questions_and_obligations_survive
test_c13_a_crash_during_replacement_leaves_at_most_one_active_attempt
test_an_ordinary_relaunch_may_not_rebind_the_lane
test_a_successor_may_only_launch_on_the_admitted_binding
test_a_successor_may_only_launch_at_the_admitted_effort
test_replace_refuses_an_unstated_effort_sanction
test_a_successor_with_no_effort_sanction_refuses_at_launch
test_a_detached_lane_keeps_the_predecessors_exact_head
test_an_orca_lane_refuses_succession_until_custody_reuse_is_verified
test_a_successor_dispatch_without_a_sanctioned_successor_is_refused
test_only_a_confirmed_launch_is_protected_from_rebinding
test_an_ended_attempt_admits_a_fresh_execution_on_any_binding
test_a_reviewing_lane_refuses_a_replacement_that_is_not_independent_of_its_maker
test_a_prelineage_lane_adopts_its_recorded_binding_and_replaces
test_a_prelineage_lane_without_a_recorded_binding_refuses
test_an_adopted_execution_is_not_re_pointed_like_an_unstarted_one
test_the_lineage_retires_with_the_attempt_record
test_a_dead_endpoint_lane_composes_quiescence_and_replaces
test_every_other_unknown_still_refuses_replacement
test_the_real_reader_emits_the_composition_the_gate_admits

fm_test_contract "$0" || exit 1
