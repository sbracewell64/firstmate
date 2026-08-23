#!/usr/bin/env bash
# Compatibility conformance for the terminal projection, across the REAL
# boundary its existing consumers read.
#
# WHAT THIS SUITE IS FOR, AND WHAT IT CANNOT ESTABLISH
#
# The terminal vocabulary changed owner on this branch: semantics/state-families.json
# now owns it and bin/fm-semantics.sh compile emits loopspecs/terminal-states.json
# from it. Nothing about that move is safe because it was intended; it is safe
# only if the consumers that already read that file get the same answers through
# the same interface. So every case here drives a REAL consumer -
# bin/fm-loopspec.sh - across the regenerated file, rather than re-reading the
# file itself and calling that a crossing.
#
# It cannot establish that the seam is QUALIFIED. A seam reaches that state on a
# production-shaped crossing plus a witnessed red at the seam itself, and a test
# suite is neither. What passing here establishes is narrower and worth stating
# exactly: the producer emits what this consumer accepts, the consumer resolves
# the same values it resolved before the owner moved, and an unmapped value still
# refuses. semantics/seams.json calls that NOT_YET_EXERCISED, which is not a pass,
# and bin/fm-semantics.sh adoption reports it as could-not-observe rather than
# letting this suite be credited with the crossing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEM="$ROOT/bin/fm-semantics.sh"
LS="$ROOT/bin/fm-loopspec.sh"
TMP_ROOT=$(fm_test_tmproot fm-semantics-compat)

OUT=""
CODE=0

# ls_run <registry-dir> <state-dir> <args...> - drive the real consumer.
ls_run() {
  local reg=$1 st=$2
  shift 2
  OUT=$(FM_ROOT_OVERRIDE="$ROOT" FM_LOOPSPEC_DIR="$reg" FM_STATE_OVERRIDE="$st" \
        "$LS" "$@" 2>&1)
  CODE=$?
}

# new_crossing <name> - build a producer/boundary/consumer triple.
#
# The register is a private copy of the owners; the boundary is a registry
# directory the compiler writes terminal-states.json into; the consumer is the
# real bin/fm-loopspec.sh pointed at that registry. Echoes "<register> <registry> <state>".
new_crossing() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/semantics" "$d/loopspecs" "$d/bin" "$d/state" "$d/registry"
  cp -R "$ROOT/semantics/." "$d/semantics/"
  cp "$ROOT/bin/fm-semantics.sh" "$ROOT/bin/fm-semantics-lib.sh" "$d/bin/"
  cp "$ROOT/loopspecs/schema.json" "$ROOT/loopspecs/triggers.json" "$d/registry/"
  cp "$ROOT"/loopspecs/*.json "$d/loopspecs/" 2>/dev/null || true
  printf '%s %s %s\n' "$d/semantics" "$d/registry" "$d/state"
}

# emit <register> <registry> - run the producer and place the boundary artifact.
emit() {
  local register=$1 registry=$2 root
  root=$(dirname "$register")
  FM_SEMANTICS_DIR="$register" "$root/bin/fm-semantics.sh" compile >/dev/null 2>&1 \
    || fail "the producer failed to compile"
  cp "$root/loopspecs/terminal-states.json" "$registry/terminal-states.json"
}

# --- the crossing, in both directions ----------------------------------------

test_the_consumer_reads_the_regenerated_boundary_identically() {
  local reg registry state before after
  read -r reg registry state <<<"$(new_crossing identical)"
  # What the consumer answered from the file as it shipped, before the owner moved.
  cp "$ROOT/loopspecs/terminal-states.json" "$registry/terminal-states.json"
  ls_run "$registry" "$state" terminal-map
  expect_code 0 "$CODE" "the consumer should read the shipped boundary"
  before=$OUT
  # What it answers from a file the producer regenerated from the owners.
  emit "$reg" "$registry"
  ls_run "$registry" "$state" terminal-map
  expect_code 0 "$CODE" "the consumer should read the regenerated boundary"
  after=$OUT
  [ -n "$before" ] || fail "the consumer produced no rows, so the comparison would be vacuous"
  [ "$before" = "$after" ] || fail "the consumer answered differently after the owner moved"
  pass "the existing consumer answers identically across the regenerated boundary, row for row"
}

test_every_source_state_still_resolves_through_the_consumer() {
  local reg registry state src st resolved rows=0
  read -r reg registry state <<<"$(new_crossing resolve-all)"
  emit "$reg" "$registry"
  # Walk every source row the owner declares and resolve it through the REAL
  # consumer. A mapping that is total in the file but unresolvable through the
  # interface would still be a broken seam.
  while IFS=$'\t' read -r src st; do
    [ -n "$src" ] || continue
    ls_run "$registry" "$state" terminal-map --resolve "$src" "$st"
    expect_code 0 "$CODE" "the consumer should resolve $src/$st"
    resolved=$OUT
    assert_contains "$resolved" "LOOPSPEC_TERMINAL_MAP $src $st ->" "resolution of $src/$st"
    rows=$((rows + 1))
  done < <(jq -r '.sources[] | select(.projected_to_terminal_states) | .source as $s
                  | .map[] | "\($s)\t\(.state)"' "$reg/state-families.json")
  # Report the positive count. "No failures" is satisfied by zero rows.
  [ "$rows" -ge 26 ] || fail "only $rows source states were resolved; the sweep did not cover the mapping"
  pass "all $rows projected source states resolve through the real consumer after the owner moved"
}

test_an_unmapped_value_still_refuses_at_the_boundary() {
  local reg registry state
  read -r reg registry state <<<"$(new_crossing unmapped)"
  emit "$reg" "$registry"
  ls_run "$registry" "$state" terminal-map --resolve loopspec not_a_terminal_state
  [ "$CODE" -ne 0 ] || fail "an unmapped value passed through the boundary"
  assert_contains "$OUT" "refuse_unmapped_terminal" "the consumer should keep its stable refusal token"
  ls_run "$registry" "$state" terminal-map --resolve not-a-source no_delta
  [ "$CODE" -ne 0 ] || fail "an unknown source vocabulary passed through the boundary"
  pass "an unmapped value and an unknown source vocabulary still refuse at the boundary, never defaulting"
}

test_the_consumer_still_validates_its_specs_against_the_boundary() {
  local reg registry state
  read -r reg registry state <<<"$(new_crossing spec-validate)"
  emit "$reg" "$registry"
  cp "$ROOT"/loopspecs/approved-work-reconciliation.json "$ROOT"/loopspecs/fork-landing.json "$registry/"
  ls_run "$registry" "$state" validate
  expect_code 0 "$CODE" "the shipped specs should still validate against the regenerated boundary"
  assert_contains "$OUT" "LOOPSPEC_VALIDATE ok" "the consumer should report its own success token"
  pass "the consumer still validates its shipped specs against the regenerated boundary, enums and all"
}

test_the_boundary_artifact_is_not_listed_as_a_spec() {
  local reg registry state
  read -r reg registry state <<<"$(new_crossing not-a-spec)"
  emit "$reg" "$registry"
  ls_run "$registry" "$state" list
  expect_code 0 "$CODE" "the consumer should list its specs"
  assert_not_contains "$OUT" "terminal-states" "the vocabulary artifact must not be read as a loop"
  pass "the regenerated boundary artifact is still skipped by the consumer spec enumeration"
}

test_the_added_generated_block_is_invisible_to_the_consumer() {
  local reg registry state with
  read -r reg registry state <<<"$(new_crossing generated-block)"
  emit "$reg" "$registry"
  jq -e '.generated.by' "$registry/terminal-states.json" >/dev/null \
    || fail "the producer did not stamp the generated block"
  ls_run "$registry" "$state" terminal-map --unified
  expect_code 0 "$CODE" "the consumer should read a file carrying the generated block"
  with=$OUT
  jq --indent 2 'del(.generated)' "$registry/terminal-states.json" > "$registry/.t" \
    && mv "$registry/.t" "$registry/terminal-states.json"
  ls_run "$registry" "$state" terminal-map --unified
  expect_code 0 "$CODE" "the consumer should read a file without it"
  [ -n "$with" ] || fail "the consumer produced nothing, so the comparison would be vacuous"
  [ "$with" = "$OUT" ] || fail "the generated block changed what the consumer answered"
  pass "the only bytes the move added are invisible to the consumer, which is what makes it a compatible projection"
}

# --- watched reds at the crossing --------------------------------------------
#
# Each of these drives the crossing RED on purpose. A control that has never
# failed has measured nothing, and this fleet has already paid for a recognizer
# that was vacuous on the day it landed.

test_watched_red_a_broken_producer_is_caught_before_the_consumer_sees_it() {
  local reg registry state root
  read -r reg registry state <<<"$(new_crossing red-producer)"
  root=$(dirname "$reg")
  # Break the owner in a way that would silently widen the vocabulary.
  jq --indent 2 '(.terminal_reasons[] | select(.name == "cancelled") | .family) = "ASCENDED"' \
    "$reg/state-families.json" > "$reg/.t" && mv "$reg/.t" "$reg/state-families.json"
  OUT=$(FM_SEMANTICS_DIR="$reg" "$root/bin/fm-semantics.sh" validate 2>&1)
  CODE=$?
  expect_code 3 "$CODE" "the producer must refuse before it emits"
  assert_contains "$OUT" "ASCENDED" "the refusal must name the value that has no image"
  pass "watched red: a producer whose vocabulary left the owner refuses before anything reaches the boundary"
}

test_watched_red_a_tampered_boundary_is_caught_by_the_drift_check() {
  local reg registry state root
  read -r reg registry state <<<"$(new_crossing red-drift)"
  root=$(dirname "$reg")
  emit "$reg" "$registry"
  OUT=$(FM_SEMANTICS_DIR="$reg" "$root/bin/fm-semantics.sh" compile --check 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "the freshly compiled tree must start green, or the red below proves nothing"
  jq --indent 2 '(.unified[] | select(.name == "cancelled") | .kind) = "success"' \
    "$root/loopspecs/terminal-states.json" > "$root/loopspecs/.t" \
    && mv "$root/loopspecs/.t" "$root/loopspecs/terminal-states.json"
  OUT=$(FM_SEMANTICS_DIR="$reg" "$root/bin/fm-semantics.sh" compile --check 2>&1)
  CODE=$?
  expect_code 3 "$CODE" "a boundary edited behind the owner must refuse"
  assert_contains "$OUT" "refuse_stale_projection" "the drift refusal must carry its stable token"
  pass "watched red: a boundary artifact edited behind its owner is refused as drift rather than believed"
}

test_watched_red_a_consumer_reading_a_truncated_boundary_refuses() {
  local reg registry state
  read -r reg registry state <<<"$(new_crossing red-consumer)"
  emit "$reg" "$registry"
  ls_run "$registry" "$state" terminal-map --unified
  expect_code 0 "$CODE" "the crossing must start green"
  # Remove one unified state while leaving every source row that maps to it.
  jq --indent 2 '.unified |= map(select(.name != "cancelled"))' \
    "$registry/terminal-states.json" > "$registry/.t" \
    && mv "$registry/.t" "$registry/terminal-states.json"
  ls_run "$registry" "$state" terminal-map --unified
  [ "$CODE" -ne 0 ] || fail "the consumer accepted a boundary whose mapping was no longer total"
  assert_contains "$OUT" "refuse_invalid_spec" "the consumer must refuse a map that does not hold together"
  pass "watched red: the consumer refuses a boundary whose total mapping was broken, rather than answering from it"
}

test_watched_red_a_producer_that_cannot_read_its_owner_emits_nothing() {
  local reg registry state root
  read -r reg registry state <<<"$(new_crossing red-unreadable)"
  root=$(dirname "$reg")
  printf 'not json\n' > "$reg/state-families.json"
  OUT=$(FM_SEMANTICS_DIR="$reg" "$root/bin/fm-semantics.sh" compile 2>&1)
  CODE=$?
  expect_code 4 "$CODE" "an unreadable owner is could-not-observe, never an empty successful emit"
  assert_absent "$registry/terminal-states.json" "nothing may be written from an owner that could not be read"
  pass "watched red: a producer that cannot read its owner emits nothing and answers could-not-observe"
}

# --- honesty about the seam state --------------------------------------------

test_this_suite_does_not_claim_the_seam_is_qualified() {
  # The declared seam vocabulary must keep a distinct value for a mechanism that
  # works in tests and has never crossed for real. If NOT_YET_EXERCISED were ever
  # folded into could-not-observe, a suite like this one would start reading as
  # a qualification.
  OUT=$(jq -r '[.seam_states[] | select(.state == "NOT_YET_EXERCISED")] | length' \
        "$ROOT/semantics/seams.json")
  [ "$OUT" = "1" ] || fail "the seam vocabulary lost its distinct unexercised value"
  OUT=$(jq -r '.seam_states[] | select(.state == "NOT_YET_EXERCISED") | .is_a_pass' \
        "$ROOT/semantics/seams.json")
  [ "$OUT" = "false" ] || fail "an unexercised seam is being counted as a pass"
  OUT=$("$SEM" adoption 2>&1) || true
  assert_contains "$OUT" "AP4 real producer-boundary-consumer . CNO" \
    "a real crossing must stay unobserved while only tests have run"
  pass "passing this suite does not qualify the seam: an unexercised crossing keeps its own non-pass value"
}

test_the_consumer_reads_the_regenerated_boundary_identically
test_every_source_state_still_resolves_through_the_consumer
test_an_unmapped_value_still_refuses_at_the_boundary
test_the_consumer_still_validates_its_specs_against_the_boundary
test_the_boundary_artifact_is_not_listed_as_a_spec
test_the_added_generated_block_is_invisible_to_the_consumer
test_watched_red_a_broken_producer_is_caught_before_the_consumer_sees_it
test_watched_red_a_tampered_boundary_is_caught_by_the_drift_check
test_watched_red_a_consumer_reading_a_truncated_boundary_refuses
test_watched_red_a_producer_that_cannot_read_its_owner_emits_nothing
test_this_suite_does_not_claim_the_seam_is_qualified
