#!/usr/bin/env bash
# Regression test for the two halves of the launch-brief delivery contract
# (task spawn-refuses-empty-brief-and-confirms-delivery).
#
# THE DEFECT. Every harness except kimi receives its brief as ONE argv element
# that the CREWMATE'S pane shell builds by expanding
# "$(bin/fm-operational-input.sh encode launch-brief < <brief>)"
# (bin/fm-launch-lib.sh's launch_template). fm-spawn types that literal, presses
# Enter, and stops watching. So:
#   - a 0-byte brief made the encoder exit 2 printing NOTHING on stdout or
#     stderr, and `"$(...)"` turned that silent failure into a present-but-EMPTY
#     argument. The harness started, accepted the empty prompt as a valid
#     invocation, and idled forever with an empty composer.
#   - a brief over the kernel's per-argument limit made the pane shell fail with
#     `Argument list too long`, so no session started at all.
# Both were reported as `spawned ...`, because the only delivery confirmation in
# fm-spawn was kimi's: a confirmed KEYSTROKE was credited as a confirmed SESSION.
#
# WHAT IS PINNED HERE. Everything runs through the executables - bin/fm-spawn.sh
# and bin/fm-operational-input.sh - never their source bytes:
#   1. the encoder refuses an empty body LOUDLY (non-zero AND one line of stderr)
#      while success stays silent and single-valued;
#   2. fm-spawn refuses an empty, too-short, placeholder-carrying, or oversized
#      brief with a typed FM_SPAWN_BRIEF_* reason BEFORE any allocation - no
#      window, no metadata;
#   3. after the send, a stub harness that starts WITHOUT consuming the prompt
#      yields FM_SPAWN_DELIVERY_UNCONFIRMED - could-not-observe, never `spawned`,
#      with the lane's records left intact;
#   4. a stub harness that appends the first status event yields `spawned` with
#      the confirming source named, and the wait really does poll for it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
OPINPUT="$ROOT/bin/fm-operational-input.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-brief-delivery)

# --- the encoder's own refusal ---------------------------------------------

test_encoder_refuses_empty_body_loudly() {
  local dir out err status
  dir="$TMP_ROOT/encoder"
  mkdir -p "$dir"
  : > "$dir/empty.md"

  out=$("$OPINPUT" encode launch-brief < "$dir/empty.md" 2>"$dir/err") && status=0 || status=$?
  expect_code 2 "$status" "the encoder should refuse an empty body"
  [ -z "$out" ] || fail "the encoder printed a value for an empty body: '$out'"
  err=$(cat "$dir/err")
  [ -n "$err" ] || fail "the encoder refused an empty body SILENTLY; a caller embedding it in \"\$(...)\" cannot see a bare non-zero status, so silence becomes an empty prompt"
  assert_contains "$err" "FM_OPINPUT_EMPTY_BODY" \
    "the empty-body refusal is not typed"
  [ "$(printf '%s\n' "$err" | wc -l)" -eq 1 ] || fail "the refusal should be exactly one line, got:"$'\n'"$err"

  pass "the encoder refuses an empty body loudly and typed, never silently"
}

test_encoder_success_stays_silent_and_single_valued() {
  local out err
  err="$TMP_ROOT/encoder/ok-err"
  out=$(printf 'a real brief body\n' | "$OPINPUT" encode launch-brief 2>"$err") \
    || fail "the encoder refused a real body"
  assert_contains "$out" "launch-brief: a real brief body" \
    "the encoded value lost its body"
  [ ! -s "$err" ] || fail "a successful encode printed diagnostics: $(cat "$err")"

  # A non-match is a different answer from a refusal and stays silent.
  printf 'not an operational input\n' | "$OPINPUT" kind >/dev/null 2>"$err" && \
    fail "a non-match should exit non-zero"
  [ ! -s "$err" ] || fail "a non-match printed diagnostics: $(cat "$err")"

  pass "a successful encode stays silent and a non-match stays silent"
}

# --- spawn fixtures ---------------------------------------------------------

# make_fakebin <dir>: a fake tmux standing in for the whole session provider.
# Its send-keys arm is the stub HARNESS: when FM_FAKE_DELIVER=1 it appends the
# worker's first status event the moment it sees the launch line, which is what
# a harness that actually consumed the prompt would cause. With FM_FAKE_DELIVER
# unset it starts and consumes nothing - the reported defect's shape.
make_fakebin() {
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
  capture-pane) exit 0 ;;
  has-session|new-session|kill-window) exit 0 ;;
  new-window)
    [ -z "${FM_FAKE_WINDOW_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_WINDOW_LOG"
    exit 0
    ;;
  send-keys)
    [ -z "${FM_FAKE_SEND_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_SEND_LOG"
    case "$*" in
      *launch-brief*)
        # The stub harness consumes the prompt and reports its first turn.
        if [ "${FM_FAKE_DELIVER:-0}" = 1 ] && [ -n "${FM_FAKE_STATUS_FILE:-}" ]; then
          printf 'fm-status-event.v1 verb=working phase=setup summary=stub harness consumed the brief\n' \
            >> "$FM_FAKE_STATUS_FILE"
        fi
        # The stub harness fires its adapter's turn-lifecycle hook instead -
        # exactly what claude's UserPromptSubmit does for the argv launch prompt.
        if [ "${FM_FAKE_DELIVER_BUSY:-0}" = 1 ]; then
          "${FM_FAKE_BUSY_EVENT_BIN:?}" apply "${FM_FAKE_STATE_DIR:?}" "${FM_FAKE_TASK_ID:?}" \
            busy --current-gen --source claude-hook --event user-prompt-submit >/dev/null 2>&1 || true
        fi
        # Release a late-reporting stub. Touched only for the LAUNCH line, which
        # fm-spawn sends after it captures its delivery baseline, so the evidence
        # it releases is unambiguously new.
        [ -z "${FM_FAKE_LAUNCH_SENTINEL:-}" ] || : > "$FM_FAKE_LAUNCH_SENTINEL"
        ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a home, a project with a real worktree, and a fake
# session provider. The brief is left for the caller to write, because what the
# brief CONTAINS is the subject of most cases here.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

# run_spawn <id> [extra env assignments are inherited from the caller]
run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_WINDOW_LOG="$CASE_DIR/window-log" \
    FM_FAKE_SEND_LOG="$CASE_DIR/send-log" \
    FM_FAKE_STATUS_FILE="$HOME_DIR/state/$id.status" \
    FM_FAKE_LAUNCH_SENTINEL="$CASE_DIR/launch-sent" \
    FM_FAKE_BUSY_EVENT_BIN="$ROOT/bin/fm-busy-event.sh" \
    FM_FAKE_STATE_DIR="$HOME_DIR/state" FM_FAKE_TASK_ID="$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off \
    --reason-code NL_RULE_CLASSIFICATION 2>&1
}

# assert_refused_before_allocation <id>: the gate must run before ANY allocation,
# so a refused brief leaves no window and no recorded lane behind.
assert_refused_before_allocation() {
  local id=$1
  assert_absent "$HOME_DIR/state/$id.meta" \
    "a refused brief still published state/$id.meta; the gate ran after allocation"
  [ ! -s "$CASE_DIR/window-log" ] \
    || fail "a refused brief still allocated a window:"$'\n'"$(cat "$CASE_DIR/window-log")"
}

# --- the pre-allocation brief gate ------------------------------------------

test_empty_brief_is_refused_before_allocation() {
  local rec id out status
  id='brief-empty'
  rec=$(make_case empty "$id"); read_case "$rec"
  : > "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$id") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a 0-byte brief"$'\n'"$out"
  assert_contains "$out" "FM_SPAWN_BRIEF_EMPTY" "the empty-brief refusal is not typed"
  assert_not_contains "$out" "spawned $id" "spawn reported success for a 0-byte brief"
  assert_refused_before_allocation "$id"

  pass "a 0-byte brief is refused, typed, before any allocation"
}

test_missing_brief_is_refused() {
  local rec id out status
  id='brief-missing'
  rec=$(make_case missing "$id"); read_case "$rec"
  # deliberately no brief written

  out=$(run_spawn "$id") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a missing brief"$'\n'"$out"
  assert_contains "$out" "FM_SPAWN_BRIEF_MISSING" "the missing-brief refusal is not typed"
  assert_refused_before_allocation "$id"

  pass "a missing brief is refused with a typed reason"
}

test_too_short_brief_is_refused() {
  local rec id out status
  id='brief-short'
  rec=$(make_case short "$id"); read_case "$rec"
  printf 'do it\n' > "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$id") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a brief carrying no task"$'\n'"$out"
  assert_contains "$out" "FM_SPAWN_BRIEF_TOO_SHORT" "the too-short refusal is not typed"
  assert_refused_before_allocation "$id"

  pass "a brief under the declared minimum is refused"
}

# An unfilled scaffold is the failure mode that produces a live agent with
# instructions it cannot act on, so it is refused on the same gate.
test_placeholder_brief_is_refused_before_allocation() {
  local rec id out status
  id='brief-placeholder'
  rec=$(make_case placeholder "$id"); read_case "$rec"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
{TASK}

# Setup
You are in a disposable git worktree.
EOF

  out=$(run_spawn "$id") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an unfilled scaffold"$'\n'"$out"
  assert_contains "$out" "FM_SPAWN_BRIEF_PLACEHOLDER" "the placeholder refusal is not typed"
  assert_refused_before_allocation "$id"

  pass "a brief still carrying the unfilled {TASK} line is refused before allocation"
}

# A FILLED brief must not trip the placeholder check just because its task text
# quotes the token - the scaffold's own safety-gate paragraph does exactly that.
test_filled_brief_quoting_the_token_is_not_refused() {
  local rec id out
  id='brief-quotes-token'
  rec=$(make_case quotes "$id"); read_case "$rec"
  cat > "$HOME_DIR/data/$id/brief.md" <<'EOF'
You are a crewmate: an autonomous worker agent managed by firstmate.

# Task
Fix the launch path. This scaffold cannot inspect the text that replaces `{TASK}` later.
EOF

  out=$(FM_SPAWN_DELIVERY_TIMEOUT_SECS=0 run_spawn "$id") || true
  assert_not_contains "$out" "FM_SPAWN_BRIEF_PLACEHOLDER" \
    "a filled brief that merely quotes {TASK} inline was refused as an unfilled scaffold"

  pass "a filled brief quoting {TASK} inline is not mistaken for a scaffold"
}

test_oversized_brief_is_refused_and_names_the_envelope() {
  local rec id out status envelope
  id='brief-oversized'
  rec=$(make_case oversized "$id"); read_case "$rec"
  # The real, unoverridden envelope: the kernel's per-ARGUMENT limit
  # MAX_ARG_STRLEN = 32 * PAGE_SIZE, which getconf ARG_MAX does not report.
  envelope=$(( 32 * $(getconf PAGESIZE) ))
  # One byte past what the encoded form can carry.
  awk -v n="$envelope" 'BEGIN { for (i = 0; i < n; i++) printf "a" }' \
    > "$HOME_DIR/data/$id/brief.md"

  out=$(run_spawn "$id") && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a brief that cannot be exec'd"$'\n'"$out"
  assert_contains "$out" "FM_SPAWN_BRIEF_TOO_LARGE" "the oversized refusal is not typed"
  assert_contains "$out" "$envelope" \
    "the refusal did not name the measured envelope ($envelope bytes)"
  assert_refused_before_allocation "$id"

  pass "a brief over the measured single-argument envelope is refused and names it"
}

# The envelope is a declared, overridable bound rather than a magic number.
test_envelope_bound_is_declared_and_overridable() {
  local rec id out
  id='brief-envelope-override'
  rec=$(make_case envelope "$id"); read_case "$rec"
  awk 'BEGIN { for (i = 0; i < 400; i++) printf "b" }' > "$HOME_DIR/data/$id/brief.md"

  out=$(FM_SPAWN_MAX_PROMPT_BYTES=200 run_spawn "$id") || true
  assert_contains "$out" "FM_SPAWN_BRIEF_TOO_LARGE" \
    "the declared envelope override was not honoured"
  assert_contains "$out" "200" "the refusal did not name the overridden envelope"

  pass "the launch envelope is a declared bound the caller can override"
}

# --- post-send delivery confirmation ----------------------------------------

test_delivery_unconfirmed_when_stub_never_consumes_the_prompt() {
  local rec id out status
  id='delivery-unconfirmed'
  rec=$(make_case unconfirmed "$id"); read_case "$rec"
  printf 'A real brief with enough content to carry a task.\n' > "$HOME_DIR/data/$id/brief.md"

  # FM_FAKE_DELIVER unset: the stub harness starts and consumes nothing, which
  # is exactly the reported defect - a live pane with an empty composer.
  out=$(FM_SPAWN_DELIVERY_TIMEOUT_SECS=0 run_spawn "$id") && status=0 || status=$?

  assert_contains "$out" "FM_SPAWN_DELIVERY_UNCONFIRMED" \
    "a launch whose brief was never consumed was not reported as could-not-observe"
  assert_not_contains "$out" "spawned $id" \
    "spawn reported success for a session that never took the prompt"
  [ "$status" -ne 0 ] || fail "an unconfirmed delivery exited 0, which reads as success"
  expect_code 3 "$status" "could-not-observe needs its own exit code, distinct from success and failure"

  # Could-not-observe is not a failed spawn: the lane's records must survive so
  # firstmate can inspect and steer rather than blind-retry.
  assert_present "$HOME_DIR/state/$id.meta" \
    "an unconfirmed delivery destroyed the lane's metadata; firstmate cannot inspect it"
  [ -s "$CASE_DIR/window-log" ] || fail "the window was never allocated, so this case did not reach the delivery gate"

  pass "a stub harness that starts without consuming the prompt reports could-not-observe, records intact"
}

test_delivery_confirmed_when_stub_reports_its_first_turn() {
  local rec id out status
  id='delivery-confirmed'
  rec=$(make_case confirmed "$id"); read_case "$rec"
  printf 'A real brief with enough content to carry a task.\n' > "$HOME_DIR/data/$id/brief.md"

  out=$(FM_FAKE_DELIVER=1 FM_SPAWN_DELIVERY_TIMEOUT_SECS=0 run_spawn "$id") && status=0 || status=$?
  expect_code 0 "$status" "the proven path should spawn cleanly"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the proven path did not report a spawn"
  assert_contains "$out" "delivery=status-event" \
    "the success line does not name the evidence that confirmed delivery"
  assert_not_contains "$out" "FM_SPAWN_DELIVERY_UNCONFIRMED" \
    "a delivered brief was reported as unconfirmed"

  pass "a stub harness that appends its first status event confirms delivery, and the source is named"
}

# The seed trap: fm-busy-event.sh arm writes a `busy source=fm-spawn` record at
# seq=1 BEFORE the launch line is sent. Reading that record as evidence would
# confirm delivery on a lane where nothing was delivered - the exact defect.
# claude is the harness whose busy contract IS armed, so it is the one that
# would be fooled.
test_spawn_seed_busy_record_is_not_delivery_evidence() {
  local rec id out
  id='delivery-seed-trap'
  rec=$(make_case seedtrap "$id"); read_case "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf 'A real brief with enough content to carry a task.\n' > "$HOME_DIR/data/$id/brief.md"

  out=$(FM_SPAWN_DELIVERY_TIMEOUT_SECS=0 run_spawn "$id") || true

  # The seed must exist - otherwise this case proves nothing about it.
  assert_present "$HOME_DIR/state/$id.busy-state" \
    "the busy contract was never armed, so the seed trap was not exercised"
  assert_grep "source=fm-spawn" "$HOME_DIR/state/$id.busy-state" \
    "the armed record is not the fm-spawn seed, so this case is vacuous"
  assert_contains "$out" "FM_SPAWN_DELIVERY_UNCONFIRMED" \
    "the fm-spawn seed record was credited as evidence that the brief was delivered"

  pass "the pre-send busy seed is not mistaken for a delivered first turn"
}

# The source that actually fires in the live fleet. claude, pi/pi-signed and
# opencode all report a first turn by ADVANCING the busy record past the spawn
# seed; docs/verification/supervision.md records claude's UserPromptSubmit
# firing for the argv launch prompt specifically. The seed-trap case above proves
# seq=1 is not evidence; this proves seq>1 is.
test_delivery_confirmed_by_busy_record_advancing_past_the_seed() {
  local rec id out status seq
  id='delivery-busy-record'
  rec=$(make_case busyrec "$id"); read_case "$rec"
  printf 'claude\n' > "$HOME_DIR/config/crew-harness"
  printf 'A real brief with enough content to carry a task.\n' > "$HOME_DIR/data/$id/brief.md"

  out=$(FM_FAKE_DELIVER_BUSY=1 FM_SPAWN_DELIVERY_TIMEOUT_SECS=0 run_spawn "$id") && status=0 || status=$?
  expect_code 0 "$status" "an advanced busy record should confirm delivery"$'\n'"$out"
  assert_contains "$out" "delivery=busy-record:claude-hook" \
    "the adapter's own turn-lifecycle event was not the confirming source"

  # The record must really have moved past the seed, or this case is vacuous.
  seq=$(sed -n 's/.* seq=\([0-9]*\) .*/\1/p' "$HOME_DIR/state/$id.busy-state")
  [ -n "$seq" ] && [ "$seq" -gt 1 ] \
    || fail "the busy record never advanced past the spawn seed (seq=${seq:-unset}); this case proves nothing"

  pass "an adapter turn-lifecycle event advancing the busy record confirms delivery"
}

# The bound is a real wait, not a single reading: evidence that arrives late is
# still caught.
test_delivery_wait_polls_until_evidence_arrives() {
  local rec id out status writer_pid
  id='delivery-late'
  rec=$(make_case late "$id"); read_case "$rec"
  printf 'A real brief with enough content to carry a task.\n' > "$HOME_DIR/data/$id/brief.md"

  # A worker whose first turn lands INSIDE the wait rather than at send time.
  # It waits for the launch line itself, so the evidence is provably newer than
  # the baseline fm-spawn captured - a plain sleep would race the fixture setup
  # and land before the baseline, which is not the case under test.
  ( waited=0
    until [ -e "$CASE_DIR/launch-sent" ]; do
      waited=$((waited + 1))
      [ "$waited" -lt 600 ] || exit 0
      sleep 0.1
    done
    sleep 0.6
    printf 'fm-status-event.v1 verb=working phase=setup summary=late first turn\n' \
      >> "$HOME_DIR/state/$id.status" ) &
  writer_pid=$!
  fm_test_reap "$writer_pid"

  out=$(FM_SPAWN_DELIVERY_TIMEOUT_SECS=15 run_spawn "$id") && status=0 || status=$?
  wait "$writer_pid" 2>/dev/null || true
  assert_present "$CASE_DIR/launch-sent" \
    "the launch line was never sent, so this case did not exercise the wait"

  expect_code 0 "$status" "the wait gave up before late evidence arrived"$'\n'"$out"
  assert_contains "$out" "delivery=status-event" \
    "late-arriving first-turn evidence was not the confirming source"

  pass "the delivery wait polls to its bound and catches late first-turn evidence"
}

test_encoder_refuses_empty_body_loudly
test_encoder_success_stays_silent_and_single_valued
test_empty_brief_is_refused_before_allocation
test_missing_brief_is_refused
test_too_short_brief_is_refused
test_placeholder_brief_is_refused_before_allocation
test_filled_brief_quoting_the_token_is_not_refused
test_oversized_brief_is_refused_and_names_the_envelope
test_envelope_bound_is_declared_and_overridable
test_delivery_unconfirmed_when_stub_never_consumes_the_prompt
test_delivery_confirmed_when_stub_reports_its_first_turn
test_spawn_seed_busy_record_is_not_delivery_evidence
test_delivery_confirmed_by_busy_record_advancing_past_the_seed
test_delivery_wait_polls_until_evidence_arrives

echo "# all fm-spawn-brief-delivery tests passed"
