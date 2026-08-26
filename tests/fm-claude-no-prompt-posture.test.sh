#!/usr/bin/env bash
# tests/fm-claude-no-prompt-posture.test.sh - the guarantee that an unattended
# claude worker cannot reach an interactive permission gate.
#
# Why this file exists. An unattended worker that stops on a permission prompt
# does not report a blocker; it sits at a healthy-looking idle pane holding a
# slot, so the failure is silent by construction and supervision cannot see it.
# The obvious defense - a bypass flag - does NOT provide it: Claude Code carries
# permission circuit breakers flagged bypassImmune whose ask a bypass does not
# suppress and which "cannot be auto-allowed by permission rules". The measured
# pair behind that claim, and the live-harness command that refreshes it, live in
# docs/verification/claude-permission-posture.md; this suite is the portable half
# and runs with no harness installed.
#
# Three things are pinned here, because the posture fails in three different
# places:
#   1. the composed launch command carries the posture, for every kind;
#   2. the per-task settings bin/fm-spawn.sh generates carry it too, without
#      losing the busy-state hooks that share that file;
#   3. a launch that could still reach a gate is REFUSED before a worker exists,
#      including one that arrived through the raw-launch escape hatch.
set -u

# Derive the expected test list from the declarations rather than maintaining a
# second list, so a case that is added and never invoked fails the suite.
FM_TEST_IDENTITY_CONTRACT=1

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-launch-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-claude-no-prompt-posture)

CANONICAL_FLAGS=$(launch_claude_permission_flags)

# --------------------------------------------------------------------------
# 1. The composed launch command.

test_every_claude_kind_carries_the_posture() {
  local kind cmd
  for kind in ship scout secondmate primary; do
    cmd=$(launch_template claude "$kind") \
      || fail "launch_template refused claude for kind=$kind"
    assert_contains "$cmd" "$CANONICAL_FLAGS" \
      "the claude $kind launch does not carry the canonical no-prompt posture"
    assert_not_contains "$cmd" '--dangerously-skip-permissions' \
      "the claude $kind launch still carries a bypass flag, which does not suppress bypassImmune asks"
    assert_not_contains "$cmd" '--allow-dangerously-skip-permissions' \
      "the claude $kind launch still enables the bypass flag"
  done
  pass "every claude launch kind carries the no-prompt posture and no bypass flag"
}

# A secondmate is launched in a provisioned home where bin/fm-spawn.sh writes no
# per-task settings file, so a posture carried ONLY by that file would leave
# every secondmate launch denying ordinary work. Pin that the argv carries it.
test_secondmate_posture_rides_the_argv_not_only_the_settings_file() {
  local cmd
  cmd=$(launch_template claude secondmate)
  assert_contains "$cmd" "--settings '" \
    "a secondmate claude launch must carry its permission rules on the argv, because no per-task settings file is written for it"
  pass "the secondmate claude launch carries its permission rules on the argv"
}

# The posture has two halves and needs both. Measured on Claude Code 2.1.246:
# the mode with no allow rules denied an ordinary shell write, so a worker
# launched that way is inert rather than unattended. This is the executable
# statement of that: the owner must publish BOTH halves, and they must agree.
test_the_posture_publishes_both_halves_and_they_agree() {
  local mode json flags
  mode=$(launch_claude_permission_mode)
  [ "$mode" = dontAsk ] \
    || fail "the canonical mode is '$mode'; dontAsk is the mode measured to refuse instead of ask"
  json=$(launch_claude_permissions_json)
  printf '%s' "$json" | jq -e '.allow | length > 0' >/dev/null \
    || fail "the canonical permissions carry no allow rules, so the mode would deny ordinary work"
  [ "$(printf '%s' "$json" | jq -r '.defaultMode')" = "$mode" ] \
    || fail "the settings defaultMode and the launch mode disagree, so the two carriers would not match"
  flags=$(launch_claude_permission_flags)
  assert_contains "$flags" "--permission-mode $mode" "the launch flags omit the mode"
  assert_contains "$flags" "$json" "the launch flags omit the generated permission rules"
  pass "the canonical posture publishes both halves and the carriers agree"
}

# The commitment register asks bin/fm-launch-lib.sh whether a launched session
# still enforces permissions, and reads 'unrestricted' as enforcement DISABLED.
# claude now genuinely enforces, so a stale 'unrestricted' here would understate
# the fleet while a fabricated one elsewhere would overstate it.
test_claude_is_recorded_as_enforced_and_no_other_adapter_fabricates_it() {
  local h posture enforced=0
  [ "$(launch_permission_posture claude)" = enforced ] \
    || fail "claude launches with permission rules deciding, so its recorded posture must be enforced"
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    [ "$h" != claude ] || continue
    posture=$(launch_permission_posture "$h")
    [ "$posture" != enforced ] \
      || fail "$h claims enforced permissions, but nothing in this repo records that for it"
  done <<EOF
$(launch_harnesses)
EOF
  enforced=$(launch_permission_posture | awk '$2 == "enforced"' | wc -l)
  [ "$enforced" -eq 1 ] \
    || fail "expected exactly one enforced adapter (claude), found $enforced"
  pass "claude records enforced permissions and no other adapter fabricates that posture"
}

# --------------------------------------------------------------------------
# 2. The preflight decision table.
#
# Driven through the public function rather than through a spawn, so every arm
# is covered cheaply; the spawn cases below prove the refusal actually stops a
# real launch before a worker exists.

preflight_refuses() {  # <label> <command> <expected-fragment>
  local label=$1 cmd=$2 want=$3 err rc
  err=$(launch_claude_posture_preflight "$cmd" probe 2>&1 >/dev/null)
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "$label: the preflight ACCEPTED a launch that could reach a permission gate"
  assert_contains "$err" "FM_CLAUDE_PROMPT_POSTURE" "$label: the refusal is not typed"
  assert_contains "$err" "$want" "$label: the refusal did not name the offending token"
}

test_preflight_accepts_only_the_canonical_posture() {
  local kind
  for kind in ship scout secondmate primary; do
    launch_claude_posture_preflight "$(launch_template claude "$kind")" probe \
      || fail "the preflight refused the shipped claude $kind launch, so the guard and the template disagree"
  done
  pass "the preflight accepts every shipped claude launch"
}

test_preflight_refuses_a_bypass_launch() {
  preflight_refuses "bypass flag" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "brief"' \
    '--dangerously-skip-permissions'
  preflight_refuses "bypass enabler" \
    'claude --allow-dangerously-skip-permissions --permission-mode dontAsk' \
    '--allow-dangerously-skip-permissions'
  pass "a bypassed claude launch is refused and the offending flag is named"
}

test_preflight_refuses_a_non_canonical_or_missing_mode() {
  preflight_refuses "wrong mode" \
    "claude --permission-mode acceptEdits --settings '$(launch_claude_permissions_json)'" \
    'acceptEdits'
  preflight_refuses "bypass mode by name" \
    "claude --permission-mode bypassPermissions --settings '$(launch_claude_permissions_json)'" \
    'bypassPermissions'
  preflight_refuses "no mode" \
    "claude --settings '$(launch_claude_permissions_json)' \"brief\"" \
    '--permission-mode'
  pass "a claude launch whose mode is missing or not dontAsk is refused"
}

# Rules-without-mode and mode-without-rules are DIFFERENT failures and both are
# real: the first still asks, the second denies ordinary work. Each must be
# refused on its own terms rather than one standing in for the other.
test_preflight_refuses_a_missing_or_substituted_settings_override() {
  preflight_refuses "no settings" \
    'claude --permission-mode dontAsk "brief"' \
    '--settings'
  preflight_refuses "substituted settings" \
    "claude --permission-mode dontAsk --settings '{\"allow\":[]}'" \
    'not the canonical generated posture'
  preflight_refuses "second settings" \
    "claude --permission-mode dontAsk --settings '$(launch_claude_permissions_json)' --settings /tmp/other.json" \
    '2 --settings'
  preflight_refuses "prompt tool" \
    "claude --permission-mode dontAsk --settings '$(launch_claude_permissions_json)' --permission-prompt-tool mcp__ask" \
    '--permission-prompt-tool'
  pass "a claude launch whose permission rules are missing, replaced, or duplicated is refused"
}

# The captain's standing command posture: a generated command carrying a broad
# removal is a defect to repair, not something to approve. That class is also
# exactly what reaches a bypassImmune circuit breaker, so it belongs in this
# guard rather than in a reviewer's memory.
test_preflight_refuses_a_broad_removal_in_a_launch_command() {
  preflight_refuses "broad rm" \
    "claude --permission-mode dontAsk --settings '$(launch_claude_permissions_json)' && rm -rf x/*" \
    "invokes 'rm'"
  preflight_refuses "absolute rm" \
    "claude --permission-mode dontAsk --settings '$(launch_claude_permissions_json)' ; /bin/rm -f state" \
    "invokes 'rm'"
  # A word that merely CONTAINS rm is not a removal, and refusing it would make
  # the guard useless for ordinary task ids.
  launch_claude_posture_preflight \
    "claude $CANONICAL_FLAGS \"$(printf 'confirm-rm-handling brief')\"" probe \
    || fail "the preflight refused an ordinary word containing 'rm', so the removal check is over-broad"
  pass "a broad removal is refused and an ordinary word containing rm is not"
}

# A guard that reads only the first line is a guard that can be stepped over: the
# shell would still run the rest. Every check must see the whole command.
test_preflight_reads_the_whole_command_not_just_its_first_line() {
  preflight_refuses "removal on a later line" \
    "claude $CANONICAL_FLAGS"$'\n'"rm -rf /" \
    "invokes 'rm'"
  preflight_refuses "bypass on a later line" \
    "claude $CANONICAL_FLAGS"$'\n'"claude --dangerously-skip-permissions" \
    '--dangerously-skip-permissions'
  pass "the preflight reads every line of a launch command, not only the first"
}

# --------------------------------------------------------------------------
# 3. The real spawn: refusal before creation, and the generated settings.

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" claude
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  set -- "$@" --mode no-mistakes --yolo off --reason-code NL_RULE_CLASSIFICATION
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# The escape hatch is the path a hand-written claude command reaches the fleet
# by, so it is the one that most needs this guard. The refusal must land before
# a worker exists: a refusal that still left a task record and a pane would have
# created the wedged worker it was meant to prevent.
test_spawn_refuses_a_raw_bypass_launch_before_creating_anything() {
  local rec id=posture-raw-bypass out rc
  rec=$(make_spawn_case raw-bypass "$id")
  read_case_record "$rec"
  # shellcheck disable=SC2016  # deliberate: the placeholders expand in the worker's pane, not here
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    'CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$(__OPINPUT__ encode launch-brief < __BRIEF__)"')
  rc=$?
  [ "$rc" -ne 0 ] \
    || fail "fm-spawn ACCEPTED a raw claude launch carrying a bypass flag: $out"
  assert_contains "$out" 'FM_CLAUDE_PROMPT_POSTURE' "the spawn refusal is not the typed posture refusal: $out"
  assert_contains "$out" '--dangerously-skip-permissions' "the spawn refusal does not name the offending token: $out"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "the refused spawn still recorded a task, so it refused after creating a worker rather than before"
  assert_absent "$WT_DIR/.claude/settings.local.json" \
    "the refused spawn still wrote worker settings into a worktree"
  pass "a raw claude launch that could reach a permission gate is refused before any worker exists"
}

test_spawn_accepts_a_raw_launch_carrying_the_canonical_posture() {
  local rec id=posture-raw-ok out
  rec=$(make_spawn_case raw-ok "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" \
    "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude $CANONICAL_FLAGS \"\$(__OPINPUT__ encode launch-brief < __BRIEF__)\"")
  expect_code 0 $? "a raw claude launch carrying the canonical posture must be accepted: $out"
  assert_present "$HOME_DIR/state/$id.meta" "the accepted spawn recorded no task"
  pass "a raw claude launch carrying the canonical posture is accepted"
}

# The generated settings file is shared with the busy-state hooks. Adding the
# posture must not cost them, because a worktree whose hooks are gone reports a
# worker as permanently busy.
test_generated_settings_carry_the_posture_and_keep_the_hooks() {
  local rec id=posture-settings out settings want_allow got_allow ev
  rec=$(make_spawn_case settings "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "claude spawn should succeed: $out"
  settings="$WT_DIR/.claude/settings.local.json"
  assert_present "$settings" "claude spawn wrote no settings file"
  jq -e . "$settings" >/dev/null \
    || fail "adding the permission posture made the generated settings invalid JSON"

  [ "$(jq -r '.permissions.defaultMode' "$settings")" = "$(launch_claude_permission_mode)" ] \
    || fail "the generated settings do not carry the canonical defaultMode"
  want_allow=$(launch_claude_permission_allow | sort | tr '\n' ' ')
  got_allow=$(jq -r '.permissions.allow[]' "$settings" | sort | tr '\n' ' ')
  [ "$got_allow" = "$want_allow" ] \
    || fail "the generated allow rules drifted from their owner:
  owner:    $want_allow
  settings: $got_allow"

  for ev in UserPromptSubmit Stop StopFailure SessionEnd; do
    jq -e ".hooks[\"$ev\"][0].hooks[0].command" "$settings" >/dev/null \
      || fail "the permission posture displaced the $ev busy-state hook"
  done
  jq -e '.statusLine.command' "$settings" >/dev/null \
    || fail "the permission posture displaced the context-pressure statusLine"
  pass "the generated settings carry the posture and keep every hook that shares the file"
}

# The posture is one fleet-wide generated value. A task-local rule is exactly the
# ad hoc approval the captain's standing instruction refuses, so two tasks must
# get byte-identical permissions.
test_generated_posture_is_fleet_wide_not_task_specific() {
  local rec a b
  rec=$(make_spawn_case fleetwide-a posture-fleet-a)
  read_case_record "$rec"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" posture-fleet-a "$PROJ_DIR" >/dev/null 2>&1
  a=$(jq -cS '.permissions' "$WT_DIR/.claude/settings.local.json")
  rec=$(make_spawn_case fleetwide-b posture-fleet-b)
  read_case_record "$rec"
  run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" posture-fleet-b "$PROJ_DIR" >/dev/null 2>&1
  b=$(jq -cS '.permissions' "$WT_DIR/.claude/settings.local.json")
  [ -n "$a" ] && [ "$a" != null ] || fail "the first task generated no permissions block"
  [ "$a" = "$b" ] \
    || fail "two tasks generated different permission rules, so the posture is task-specific:
  a: $a
  b: $b"
  pass "every task gets the same fleet-wide permission posture"
}

test_every_claude_kind_carries_the_posture
test_secondmate_posture_rides_the_argv_not_only_the_settings_file
test_the_posture_publishes_both_halves_and_they_agree
test_claude_is_recorded_as_enforced_and_no_other_adapter_fabricates_it
test_preflight_accepts_only_the_canonical_posture
test_preflight_refuses_a_bypass_launch
test_preflight_refuses_a_non_canonical_or_missing_mode
test_preflight_refuses_a_missing_or_substituted_settings_override
test_preflight_refuses_a_broad_removal_in_a_launch_command
test_preflight_reads_the_whole_command_not_just_its_first_line
test_spawn_refuses_a_raw_bypass_launch_before_creating_anything
test_spawn_accepts_a_raw_launch_carrying_the_canonical_posture
test_generated_settings_carry_the_posture_and_keep_the_hooks
test_generated_posture_is_fleet_wide_not_task_specific

echo "all fm-claude-no-prompt-posture tests passed"
fm_test_contract "${BASH_SOURCE[0]}"
