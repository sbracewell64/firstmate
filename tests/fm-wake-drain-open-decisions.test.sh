#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions.test.sh - behavior tests for the OPEN
# DECISIONS section bin/fm-wake-drain.sh prints on every drain (including the
# empty-queue fast path). The section is pure wiring around
# fm-classify-lib.sh's status_open_decisions fold (the ONE authoritative
# open/resolved statement); these tests exercise the real drain script over
# crafted status logs and assert on its printed output, not on the fold's own
# source text.
#
# The section's own property, beyond the wiring: it presents the COMPLETE open
# universe, or says explicitly and in band that it could not. A listing that
# showed a fifth of the universe under a trailing "N more omitted" footnote read
# as a complete statement about what needs the captain and was not one, so
# exceeding the presentation bound is now reported as CNO_DECISION_UNIVERSE - an
# instrument defect carrying both counts - and never as a quiet truncation. Every
# entry also carries one disposition from the closed vocabulary
# fm-classify-lib.sh owns, so no entry can be left for the reader to interpret.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# The autonomy-state members, so a fixture below cannot spell a posture the
# fleet does not write. bin/fm-autonomy-lib.sh is pure.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-autonomy-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-tests)

test_buried_decision_still_surfaces() {
  local dir state out
  dir=$(make_case buried)
  state="$dir/state"
  out="$dir/drain.out"
  # The needs-decision line sits under later routine and unrelated-key lines,
  # exactly the burial scenario the fix targets: last-line-only reads would
  # show "resolved [key=other]" and hide the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task1.status"
  printf 'working: continuing other work\n' >> "$state/task1.status"
  printf 'resolved [key=other]: unrelated decision closed\n' >> "$state/task1.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a buried decision"

  grep -F 'OPEN DECISIONS' "$out" >/dev/null || fail "buried decision produced no OPEN DECISIONS section"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "buried needs-decision was not surfaced with its task, key, and note"
  pass "a needs-decision buried under later routine/other-key lines still reports as open"
}

test_explicit_resolution_closes_it() {
  local dir state out
  dir=$(make_case resolved)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task2.status"
  printf 'resolved [key=api-shape]: went with REST\n' >> "$state/task2.status"
  printf 'done: shipped\n' >> "$state/task2.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an explicit resolution"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "an explicitly resolved decision still printed as open: $(cat "$out")"
  fi
  pass "an explicit resolved [key=X] closes the keyed decision"
}

test_later_unrelated_terminal_line_does_not_close_it() {
  local dir state out
  dir=$(make_case unrelated-terminal)
  state="$dir/state"
  out="$dir/drain.out"
  # A later done: with no matching [key=...] token opens/closes only the
  # "default" key; it must never clear the still-open api-shape decision.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task3.status"
  printf 'done: unrelated later milestone\n' >> "$state/task3.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed after an unrelated terminal line"

  grep -F 'task3' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "a later unrelated terminal line incorrectly cleared the open decision"
  pass "a later unrelated terminal line never clears an open decision"
}

test_no_open_decisions_prints_nothing() {
  local dir state out
  dir=$(make_case none-open)
  state="$dir/state"
  out="$dir/drain.out"
  printf 'working: on it\n' > "$state/task4.status"
  printf 'done: shipped clean\n' > "$state/task5.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with no open decisions"

  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the empty case printed an OPEN DECISIONS section: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the empty case with no queued wakes was not silent: $(cat "$out")"
  pass "no open decisions across the fleet prints nothing"
}

test_open_decision_surfaces_even_with_an_unrelated_queued_wake() {
  local dir state out
  dir=$(make_case fleet-wide)
  state="$dir/state"
  out="$dir/drain.out"
  # task6 has a buried, still-open decision but generates NO new queue record
  # this turn; task7 is what actually wakes the drain. The fleet-wide scan
  # must still catch task6's decision alongside task7's own raw row.
  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$state/task6.status"
  printf 'working: continuing\n' >> "$state/task6.status"
  printf 'blocked: waiting on credentials\n' > "$state/task7.status"
  append_wake "$state" signal task7.status "blocked: waiting on credentials" \
    || fail "queueing the unrelated wake failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a mixed fleet"

  grep "$(printf '\tsignal\ttask7.status\t')" "$out" >/dev/null || fail "task7's own raw row is missing"
  grep -F 'task6' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "task6's buried decision was not surfaced even though only task7 queued a wake"
  pass "the open-decision section is fleet-wide, not scoped to this drain's own queued records"
}

test_buried_decision_surfaces_on_the_empty_queue_fast_path() {
  local dir state out
  dir=$(make_case empty-queue-fast-path)
  state="$dir/state"
  out="$dir/drain.out"
  # No wake is queued at all (the empty-queue exit), but the decision is still
  # open on disk - session-start relies on exactly this path.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$state/task8.status"
  printf 'working: continuing\n' >> "$state/task8.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "empty-queue drain failed"

  grep -F 'task8' "$out" | grep -F '[key=api-shape]' >/dev/null \
    || fail "the empty-queue fast path did not surface a still-open decision"
  pass "a buried open decision surfaces even when the wake queue itself is empty"
}

test_status_symlink_is_not_followed() {
  local dir state out
  dir=$(make_case status-symlink)
  state="$dir/state"
  out="$dir/drain.out"
  mkdir -p "$dir/outside"
  printf 'needs-decision [key=local]: keep this visible\n' > "$state/local.status"
  printf 'needs-decision [key=foreign]: do not expose this\n' > "$dir/outside/foreign.status"
  ln -s ../outside/foreign.status "$state/linked.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed with a symlinked status file"

  grep -F 'local [key=local] CNO_DECISION_SUBJECT needs-decision: keep this visible' "$out" >/dev/null \
    || fail "the valid local decision did not surface alongside a rejected status symlink"
  if grep -F 'do not expose this' "$out" >/dev/null; then
    fail "the fleet scan followed a status symlink outside the state directory"
  fi
  pass "the fleet-wide decision scan does not follow status symlinks"
}

# THE PROPERTY: every open decision reaches the section, at the size of universe
# this fleet actually carries. Driven with a positive count of entries actually
# printed, because "nothing was omitted" is satisfied by a section that
# enumerated nothing at all - and at a REALISTIC size, because the defect this
# replaces dropped 55 of 75 entries and a fixture small enough to fit any bound
# would have passed against it.
UNIVERSE_SIZE=80
test_the_whole_universe_is_listed() {
  local dir state out i shown note
  dir=$(make_case whole-universe)
  state="$dir/state"
  out="$dir/drain.out"
  # A note of the length real escalations carry, so the fixture exercises the
  # presentation bound rather than sitting comfortably inside any bound at all.
  note='the worker reached a gate it cannot answer under the accepted contract and needs a ruling before it can continue, with the alternatives and their consequences recorded'
  for i in $(seq 1 "$UNIVERSE_SIZE"); do
    printf 'needs-decision [key=k%s]: %s (%s)\n' "$i" "$note" "$i" > "$state/task$i.status"
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed on a full universe"

  shown=$(grep -c '^task[0-9]* \[key=k[0-9]*\] ' "$out" || true)
  [ "$shown" -eq "$UNIVERSE_SIZE" ] \
    || fail "the section listed $shown of $UNIVERSE_SIZE open decisions; enumeration must complete"
  grep -F "OPEN DECISIONS ($UNIVERSE_SIZE, complete" "$out" >/dev/null \
    || fail "a complete listing must say how many it is complete over: $(head -3 "$out")"
  grep -F 'CNO_DECISION_UNIVERSE' "$out" >/dev/null \
    && fail "the shipped presentation bound must admit a universe of $UNIVERSE_SIZE real-length entries"
  for i in 1 40 "$UNIVERSE_SIZE"; do
    grep -F "[key=k$i]" "$out" >/dev/null || fail "decision k$i never reached the section"
  done
  pass "the open-decision section lists the complete universe at fleet scale"
}

# THE PROPERTY: when a bound IS exceeded, the section reports could-not-observe
# with both counts and names it an instrument defect, ahead of the entries. The
# defect build is the old shape: a quiet trailing omission footnote.
test_exceeding_the_bound_is_reported_as_cno_not_truncated() {
  local dir state out i first_line
  dir=$(make_case cno-universe)
  state="$dir/state"
  out="$dir/drain.out"
  for i in $(seq 1 12); do
    printf 'needs-decision [key=k%s]: decision number %s needs a ruling\n' "$i" "$i" \
      > "$state/task$i.status"
  done

  # A bound small enough that most entries cannot be presented.
  FM_WAKE_OPEN_DECISION_BYTES=200 FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "drain failed when the presentation bound was exceeded"

  first_line=$(head -1 "$out")
  case "$first_line" in
    CNO_DECISION_UNIVERSE:*) ;;
    *) fail "the incompleteness must lead the section, not trail it: $first_line" ;;
  esac
  grep -F 'of 12 entries' "$out" >/dev/null \
    || fail "the report must name the size of the universe it could not present: $(cat "$out")"
  grep -F 'INSTRUMENT DEFECT' "$out" >/dev/null \
    || fail "omitted entries must be named an instrument defect, not additional captain decisions"
  grep -F 'INCOMPLETE' "$out" >/dev/null \
    || fail "a truncated listing must never be labelled complete"
  grep -F 'byte cap' "$out" >/dev/null \
    && fail "the quiet byte-cap footnote is the defect shape and must not return"

  # THE CONTROL: the same twelve decisions under the shipped bound report no
  # incompleteness at all, so the case above is about the bound rather than about
  # a section that always shouts.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed under the shipped bound"
  grep -F 'CNO_DECISION_UNIVERSE' "$out" >/dev/null \
    && fail "control: the shipped bound must present twelve decisions completely"
  grep -F 'OPEN DECISIONS (12, complete' "$out" >/dev/null \
    || fail "control: twelve decisions must be presented completely: $(cat "$out")"
  pass "exceeding the presentation bound is reported as CNO_DECISION_UNIVERSE, never truncated quietly"
}

# THE PROPERTY: every entry carries exactly one disposition from the closed set,
# including the entries whose disposition could not be established.
test_every_entry_carries_a_disposition() {
  local dir state drain_out line seen vocab
  dir=$(make_case disposition)
  state="$dir/state"
  drain_out="$dir/drain.out"
  mkdir -p "$dir/data/dtask"
  printf 'needs-decision [key=derived]: no metadata for this one\n' > "$state/dtask.status"
  printf 'blocked [key=blocking]: work has stopped\n' >> "$state/dtask.status"
  # The captain-side posture the producer actually writes: this case is about
  # the DERIVED captain answer, and a posture outside the vocabulary would now
  # (correctly) be could-not-observe instead.
  printf 'worktree=%s\nyolo=%s\n' "$dir" "$FM_AUTONOMY_STATE_CAPTAIN" > "$state/dtask.meta"
  # shellcheck disable=SC2016  # the backticks are the literal fence the fold reads, not a substitution
  printf '# decision\n\n```disposition\nBROWSER_SOL\n```\n' > "$dir/data/dtask/decision-derived.md"

  FM_DATA_OVERRIDE="$dir/data" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" \
    || fail "drain failed while reporting dispositions"

  vocab=$(
    . "$ROOT/bin/fm-classify-lib.sh"
    printf '%s' "$FM_DECISION_DISPOSITION_VOCABULARY"
  )
  seen=0
  while IFS= read -r line; do
    case "$line" in
      'task'*|'dtask '*) ;;
      *) continue ;;
    esac
    seen=$((seen + 1))
    printf '%s\n' "$vocab" | tr ' ' '\n' | grep -Fqx "$(printf '%s' "$line" | awk '{print $3}')" \
      || fail "entry carries no vocabulary disposition: $line"
  done < "$drain_out"
  [ "$seen" -eq 2 ] || fail "expected 2 entries to check, checked $seen"
  grep -F 'dtask [key=derived] BROWSER_SOL' "$drain_out" >/dev/null \
    || fail "a recorded disposition must be the one reported: $(cat "$drain_out")"
  grep -F 'dtask [key=blocking] CAPTAIN_REQUIRED_AND_BLOCKING' "$drain_out" >/dev/null \
    || fail "an unrecorded blocked decision must derive its disposition: $(cat "$drain_out")"
  pass "every listed decision carries one disposition from the closed vocabulary"
}

test_buried_decision_still_surfaces
test_the_whole_universe_is_listed
test_exceeding_the_bound_is_reported_as_cno_not_truncated
test_every_entry_carries_a_disposition
test_explicit_resolution_closes_it
test_later_unrelated_terminal_line_does_not_close_it
test_no_open_decisions_prints_nothing
test_open_decision_surfaces_even_with_an_unrelated_queued_wake
test_buried_decision_surfaces_on_the_empty_queue_fast_path
test_status_symlink_is_not_followed
