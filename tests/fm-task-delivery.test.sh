#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-reflag.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout reflag require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The consumer half of the pairing assertion below. Both libraries are pure -
# they observe nothing and create nothing - so sourcing them costs this suite
# nothing and lets it drive the REAL reader rather than a restatement of it.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-autonomy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
REFLAG="$ROOT/bin/fm-reflag.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off --reason-code NL_RULE_CLASSIFICATION)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off --reason-code NL_RULE_CLASSIFICATION)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off --reason-code NL_RULE_CLASSIFICATION)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off --reason-code NL_RULE_CLASSIFICATION)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout --reason-code NL_RULE_CLASSIFICATION)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Reflagging is where a scout's ship contract is finally decided, so it requires
# the same explicit values and writes them into the task's durable record.
test_reflag_requires_and_records_the_delivery_contract() {
  local home meta out status
  home="$TMP_ROOT/reflag/home"
  mkdir -p "$home/state"
  meta="$home/state/reflag-d1.meta"

  write_scout_meta() {
    printf 'window=fm-reflag-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" reflag-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reflagging without --mode should exit non-zero"
  assert_contains "$out" "reflagging requires --mode" "the reflag refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "a refused reflag still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" reflag-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reflagging without --yolo should exit non-zero"
  assert_contains "$out" "reflagging requires --yolo" "the reflag refusal did not name the missing approval posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" reflag-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reflagging on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "reflag did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" reflag-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a reflag carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "reflagging did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "reflagging did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "reflagging did not record the decided approval posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "the reflag hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "reflagging left more than one mode= line in the task record"
  pass "fm-reflag: the scout-to-ship move requires the delivery contract and records it exactly once"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

# --- the autonomy-state pairing assertion ------------------------------------
#
# THE PROPERTY: the set of autonomy-state values the PRODUCERS write equals the
# set the CONSUMER accepts, and the consumer TELLS THEM APART. Both halves are
# load-bearing, and the second is the one that was missing.
#
# The defect this pins: bin/fm-spawn.sh wrote `yolo=on`, and the
# decision-disposition fold in bin/fm-classify-lib.sh tested `yolo= 1`. Its
# SELF_HANDLE branch was unreachable by any value the fleet writes, so every
# routine decision on a task carrying standing routine authority was rendered
# as owed by the captain. 48 of 49 open decisions were misaddressed that way.
#
# WHY "IS EVERY WRITTEN VALUE RECOGNISED" IS NOT ENOUGH. Under that defect both
# written values returned CAPTAIN_REQUIRED_AND_BLOCKING - a real disposition,
# not a refusal - so a test asking only "does the consumer answer" would have
# been green throughout. The vocabulary collapsed silently: two producer values
# that MEAN different things reached one consumer answer. So this asserts the
# partition, not the totality: the self value must reach SELF_HANDLE, the
# captain value must not, and the two must differ.
#
# Nothing here reads either script's source. Every producer value comes from
# RUNNING the producer and reading the record it wrote, so a producer that
# starts writing a different spelling is caught by this suite rather than by a
# grep that agrees with whatever the file happens to say.

# A fake tmux that lets a spawn run to completion and report the pane as the
# worktree, plus the treehouse stub, so fm-spawn actually writes state/<id>.meta.
make_producer_fakebin() {  # <dir> -> prints fakebin
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n'; exit 0 ;; esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# Run one REAL ship or scout spawn to completion and print the `yolo=` line it
# wrote, or the literal ABSENT when it wrote none. Extra args go to fm-spawn.
run_producer_spawn() {  # <name> <id> <spawn-arg>...
  local name=$1 id=$2 case_dir home proj wt fakebin line
  shift 2
  case_dir="$TMP_ROOT/producer/$name"
  home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(make_producer_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$wt" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" >/dev/null 2>&1 \
    || { printf 'SPAWN_FAILED\n'; return 0; }
  line=$(grep '^yolo=' "$home/state/$id.meta" 2>/dev/null | tail -1) || true
  [ -n "$line" ] || { printf 'ABSENT\n'; return 0; }
  printf '%s\n' "${line#yolo=}"
}

# Run one REAL reflag and print the `yolo=` value it wrote.
run_producer_reflag() {  # <name> <yolo>
  local name=$1 want=$2 home meta line
  home="$TMP_ROOT/producer/$name/home"
  mkdir -p "$home/state"
  meta="$home/state/$name.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$name" > "$meta"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$REFLAG" "$name" --mode direct-PR --yolo "$want" >/dev/null 2>&1 \
    || { printf 'REFLAG_FAILED\n'; return 0; }
  line=$(grep '^yolo=' "$meta" 2>/dev/null | tail -1) || true
  [ -n "$line" ] || { printf 'ABSENT\n'; return 0; }
  printf '%s\n' "${line#yolo=}"
}

# Ask the REAL consumer what a task carrying <written> resolves to. Pass ABSENT
# to write no posture at all, which is what a scout's record looks like.
disposition_for_written() {  # <home> <task> <written> <verb>
  local home=$1 task=$2 written=$3 verb=$4
  mkdir -p "$home/state" "$home/data"
  {
    printf 'window=x\nworktree=%s\n' "$home"
    [ "$written" = ABSENT ] || printf 'yolo=%s\n' "$written"
  } > "$home/state/$task.meta"
  decision_disposition "$task" k "$verb" "$home"
}

# The owner's own reader keeps THREE values, and the third is a real result
# rather than a missing one. The decision fold reaches only two of them (it
# establishes the record is readable first), so the unreadable case has no other
# control and would otherwise be asserted by nobody.
test_autonomy_reader_keeps_three_values() {
  local dir meta got rc
  dir="$TMP_ROOT/reader"
  mkdir -p "$dir"
  meta="$dir/task.meta"

  printf 'window=x\nyolo=%s\n' "$FM_AUTONOMY_STATE_SELF" > "$meta"
  got=$(fm_autonomy_state_of_meta "$meta"); rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$FM_AUTONOMY_STATE_SELF" ] \
    || fail "a recorded member read back as rc=$rc value='$got'"

  printf 'window=x\n' > "$meta"
  got=$(fm_autonomy_state_of_meta "$meta"); rc=$?
  [ "$rc" -eq 1 ] && [ -z "$got" ] \
    || fail "an absent posture read back as rc=$rc value='$got' rather than the absent answer"

  printf 'window=x\nyolo=1\n' > "$meta"
  got=$(fm_autonomy_state_of_meta "$meta"); rc=$?
  # The raw value comes back so a caller can NAME what it could not read.
  [ "$rc" -eq 2 ] && [ "$got" = 1 ] \
    || fail "an uninterpretable posture read back as rc=$rc value='$got'"

  # The LAST line wins, matching every other reader of this file.
  printf 'yolo=%s\nyolo=%s\n' "$FM_AUTONOMY_STATE_CAPTAIN" "$FM_AUTONOMY_STATE_SELF" > "$meta"
  got=$(fm_autonomy_state_of_meta "$meta"); rc=$?
  [ "$rc" -eq 0 ] && [ "$got" = "$FM_AUTONOMY_STATE_SELF" ] \
    || fail "a repeated posture line did not resolve last-wins, rc=$rc value='$got'"

  # An absent file is could-not-observe, never the absent-FIELD answer: "this
  # task recorded no posture" and "there is no record here" are different facts.
  got=$(fm_autonomy_state_of_meta "$dir/nothing-here.meta"); rc=$?
  [ "$rc" -eq 2 ] \
    || fail "a missing record read back as rc=$rc rather than could-not-observe"

  # Normalization is identity-or-refuse. Widening it to fold `1` or `true` onto
  # a member would rebuild the second vocabulary this library exists to end.
  for got in 1 true yes ON Off ''; do
    fm_autonomy_state_normalize "$got" >/dev/null \
      && fail "normalization accepted '$got', reopening a second spelling for one fact"
  done
  pass "the autonomy-state reader keeps three values and normalization stays identity-or-refuse"
}

test_autonomy_state_producers_and_consumer_are_paired() {
  local home self_written captain_written scout_written reflag_on reflag_off
  local got_self got_captain got_scout member observed n=0
  home="$TMP_ROOT/pairing/home"
  mkdir -p "$home/state" "$home/data"

  # --- producer side, observed by running each producer -----------------------
  self_written=$(run_producer_spawn ship-self pair-self claude \
    --mode no-mistakes --yolo on --reason-code NL_RULE_CLASSIFICATION)
  captain_written=$(run_producer_spawn ship-captain pair-captain claude \
    --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION)
  scout_written=$(run_producer_spawn scout pair-scout claude \
    --scout --reason-code NL_RULE_CLASSIFICATION)
  reflag_on=$(run_producer_reflag reflag-self on)
  reflag_off=$(run_producer_reflag reflag-captain off)

  for observed in "$self_written" "$captain_written" "$reflag_on" "$reflag_off"; do
    case "$observed" in
      SPAWN_FAILED|REFLAG_FAILED|ABSENT)
        fail "a producer that must record a posture recorded '$observed' instead" ;;
    esac
  done
  [ "$scout_written" = ABSENT ] \
    || fail "a scout spawn recorded a posture ('$scout_written'); its deliverable is a report, not a merge"

  # --- pairing, both directions ----------------------------------------------
  # Every value a producer wrote is one the consumer's owner accepts.
  for observed in "$self_written" "$captain_written" "$reflag_on" "$reflag_off"; do
    fm_autonomy_state_is_known "$observed" \
      || fail "a producer wrote '$observed', which the consumer's vocabulary does not accept"
  done
  # And every value the consumer accepts is one some producer actually writes,
  # so a member nothing can emit cannot sit in the set reading as a contract.
  for member in $FM_AUTONOMY_STATE_VOCABULARY; do
    n=$((n + 1))
    case "$member" in
      "$self_written"|"$captain_written"|"$reflag_on"|"$reflag_off") ;;
      *) fail "the consumer accepts '$member', which no producer here emits: dead vocabulary" ;;
    esac
  done
  [ "$n" -eq 2 ] || fail "the autonomy vocabulary has $n members; every one must be driven, not counted"

  # --- the partition: the consumer TELLS THE TWO APART ------------------------
  got_self=$(disposition_for_written "$home" pair-a "$self_written" blocked)
  got_captain=$(disposition_for_written "$home" pair-b "$captain_written" blocked)
  [ "$got_self" = SELF_HANDLE ] \
    || fail "a task the producer recorded as '$self_written' resolved to $got_self, so standing routine authority never reaches SELF_HANDLE"
  [ "$got_captain" != SELF_HANDLE ] \
    || fail "a task the producer recorded as '$captain_written' resolved to SELF_HANDLE"
  [ "$got_self" != "$got_captain" ] \
    || fail "both written postures collapsed to $got_self, so the consumer does not distinguish them"

  # A scout's absent posture is a LIVE producer state, not a broken record: it
  # granted no standing authority, so the captain holds the decision.
  got_scout=$(disposition_for_written "$home" pair-c ABSENT blocked)
  [ "$got_scout" = CAPTAIN_REQUIRED_AND_BLOCKING ] \
    || fail "an absent posture resolved to $got_scout rather than the captain's"

  # NOT DRIVEN HERE, and named rather than assumed: a --secondmate spawn records
  # a FIXED posture instead of taking one, and provisioning a standing home is
  # out of this suite's reach. Its constant is covered as a VALUE by the
  # captain-side case above; that it is the constant that path writes is not
  # something this assertion observes.
  pass "the autonomy-state vocabulary has one owner, every member is produced, and the consumer partitions them"
}

# The registry is where the captain's CONTRIBUTION posture lives: which of a
# fork layout's two trunks this project contributes to, a fact the checkout
# cannot supply and the resolver previously derived from the remotes instead.
#
# The two answers this file gives are independent on purpose. A contribution
# token this cannot name refuses that query, because choosing between a fork and
# an upstream on the captain's behalf is what the token exists to prevent - but
# the delivery gate is not part of that question, so it keeps answering.
test_project_mode_reads_the_registered_contribution_posture() {
  local home out err rc
  home="$TMP_ROOT/project-contribution/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- plainproj [no-mistakes] - fixture (added 2026-01-01)
- forkproj [no-mistakes contribute=fork] - fixture (added 2026-01-01)
- upproj [direct-PR +yolo contribute=upstream] - fixture (added 2026-01-01)
- bareproj [contribute=fork] - fixture (added 2026-01-01)
- dupeproj [no-mistakes contribute=fork contribute=upstream] - fixture (added 2026-01-01)
- typoproj [no-mistakes contribute=forq] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution plainproj 2>/dev/null)
  [ "$out" = "default" ] || fail "a project registering no posture must derive it (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution missingproj 2>/dev/null)
  [ "$out" = "default" ] || fail "an unregistered project must derive its posture (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution forkproj 2>/dev/null)
  [ "$out" = "fork" ] || fail "a registered fork posture was not read (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution upproj 2>/dev/null)
  [ "$out" = "upstream" ] || fail "a registered upstream posture was not read (got '$out')"

  # The token composes with the other annotations rather than replacing them.
  out=$(FM_HOME="$home" "$PROJECT_MODE" upproj 2>/dev/null)
  [ "$out" = "direct-PR on" ] || fail "the contribution token disturbed the delivery posture (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution bareproj 2>/dev/null)
  [ "$out" = "fork" ] || fail "a standalone contribution token was not read (got '$out')"
  out=$(FM_HOME="$home" "$PROJECT_MODE" bareproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a standalone contribution token was read as a mode (got '$out')"

  # A posture this cannot name is refused, with nothing on stdout to mistake for
  # an answer - and the delivery gate for the same project still resolves.
  for proj in dupeproj typoproj; do
    rc=0
    out=$(FM_HOME="$home" "$PROJECT_MODE" --contribution "$proj" 2>/dev/null) || rc=$?
    [ "$rc" -ne 0 ] || fail "$proj: an unnameable contribution posture must refuse"
    [ -z "$out" ] || fail "$proj: a refused posture still printed '$out'"
    err=$(FM_HOME="$home" "$PROJECT_MODE" --contribution "$proj" 2>&1 >/dev/null)
    assert_contains "$err" "contribution posture" "$proj: the refusal must say what it could not name"
    out=$(FM_HOME="$home" "$PROJECT_MODE" "$proj" 2>/dev/null)
    [ "$out" = "no-mistakes off" ] \
      || fail "$proj: a broken contribution token silently changed the delivery gate (got '$out')"
  done

  # The two queries answer different questions and do not combine.
  rc=0
  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw --contribution forkproj 2>/dev/null) || rc=$?
  [ "$rc" -ne 0 ] || fail "--raw and --contribution must not combine"
  [ -z "$out" ] || fail "a refused query combination still printed '$out'"
  pass "fm-project-mode: the registered contribution posture is read, composes, and refuses what it cannot name"
}

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_reflag_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
test_project_mode_reads_the_registered_contribution_posture
test_autonomy_reader_keeps_three_values
test_autonomy_state_producers_and_consumer_are_paired
echo "# all fm-task-delivery tests passed"
