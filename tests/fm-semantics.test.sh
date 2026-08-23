#!/usr/bin/env bash
# Behavioral regressions for the semantics register: owner invariants, the
# deterministic compiler, drift refusal, the design preflight, and inheritance
# manifests.
#
# Every guarantee here is proved through bin/fm-semantics.sh's public interface -
# its exit status, its stable refusal tokens, and the bytes it emits - never by
# reading the script's own source.
#
# Every block drives its control RED against a mutated fixture register before
# trusting the green result on the shipped one, because a checker that cannot
# fail proves nothing by passing. The shipped register is never mutated: each
# case copies it into its own temp root and points FM_SEMANTICS_DIR there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEM="$ROOT/bin/fm-semantics.sh"
TMP_ROOT=$(fm_test_tmproot fm-semantics)

OUT=""
CODE=0

# sem_run <register-dir> <args...> - capture combined output and exit code.
sem_run() {
  local dir=$1
  shift
  OUT=$(FM_SEMANTICS_DIR="$dir" "$SEM" "$@" 2>&1)
  CODE=$?
}

# new_register <name> - a private copy of the shipped register; echoes its path.
new_register() {
  local d="$TMP_ROOT/$1"
  mkdir -p "$d"
  cp -R "$ROOT/semantics/." "$d/"
  printf '%s\n' "$d"
}

# mutate <register> <file> <jq-program> - rewrite one owner document in place.
mutate() {
  local dir=$1 file=$2 program=$3 tmp
  tmp=$(mktemp "$dir/.mutate.XXXXXX") || fail "mutate: could not create scratch"
  jq --indent 2 "$program" "$dir/$file" > "$tmp" || fail "mutate: jq failed on $file"
  mv "$tmp" "$dir/$file"
}

# --- owner invariants ---------------------------------------------------------

test_the_shipped_register_holds_together() {
  sem_run "$ROOT/semantics" validate
  expect_code 0 "$CODE" "the shipped register should satisfy every declared invariant"
  assert_contains "$OUT" "every declared owner invariant holds" "validate should say so plainly"
  pass "the shipped semantic register satisfies every invariant it declares"
}

test_a_successor_naming_an_undeclared_family_is_refused() {
  local reg
  reg=$(new_register successor-drift)
  # Negative control first: the unmutated copy must be green, or the red below
  # would prove only that the copy was broken.
  sem_run "$reg" validate
  expect_code 0 "$CODE" "the private copy should start green"
  mutate "$reg" state-families.json \
    '(.families[] | select(.name == "ACTIVE") | .legal_successors) |= (. + ["ASCENDED"])'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a successor outside the vocabulary must refuse"
  assert_contains "$OUT" "refuse_invalid_owner" "the refusal must carry its stable token"
  assert_contains "$OUT" "ASCENDED" "the refusal must name the undeclared successor"
  pass "a legal successor outside the declared vocabulary is refused, never defaulted"
}

test_a_terminal_family_may_not_grow_a_way_back() {
  local reg
  reg=$(new_register resurrection-edge)
  mutate "$reg" state-families.json \
    '(.families[] | select(.name == "SUPERSEDED") | .legal_successors) = ["ACTIVE"]'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an edge out of SUPERSEDED must refuse at the owner"
  assert_contains "$OUT" "SUPERSEDED" "the refusal must name the family that grew an edge"
  pass "no-stale-resurrection is enforced structurally: SUPERSEDED cannot be given a successor"
}

test_a_nonterminal_family_without_a_wake_is_refused() {
  local reg
  reg=$(new_register orphan-family)
  mutate "$reg" state-families.json \
    '(.families[] | select(.name == "WAITING_EXTERNAL") | .wake_is) = ""'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a nonterminal family with no wake must refuse"
  assert_contains "$OUT" "wake_is" "the refusal must name the missing obligation field"
  pass "a nonterminal family that names no wake is refused at the owner, not at read time"
}

test_a_source_row_leaving_the_vocabulary_is_refused() {
  local reg
  reg=$(new_register unmapped-row)
  mutate "$reg" state-families.json \
    '(.sources[] | select(.source == "crew-state") | .map[] | select(.state == "working") | .unified) = "BUSY"'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an unmapped source value must refuse"
  assert_contains "$OUT" "BUSY" "the refusal must name the value that has no image"
  pass "an unmapped source value refuses rather than defaulting onto a plausible family"
}

test_an_observation_result_row_must_name_an_observation_verdict() {
  local reg
  reg=$(new_register observation-row)
  mutate "$reg" state-families.json \
    '(.sources[] | select(.source == "crew-state") | .map[] | select(.state == "unknown")) |= del(.observation_verdict)'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an observation row with no verdict must refuse"
  assert_contains "$OUT" "unknown" "the refusal must name the row"
  pass "an observation-result row without an observation verdict is refused, so an unmade observation cannot read as a work claim"
}

test_a_reason_code_in_two_namespaces_breaks_lookup_and_is_refused() {
  local reg
  reg=$(new_register duplicate-code)
  mutate "$reg" reasons.json \
    '(.namespaces[] | select(.namespace == "transition") | .codes) |= (. + [{"code":"SFI_ORPHAN","verdict":"REFUSE","means":"x","repair":"y"}])'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a code declared twice must refuse"
  assert_contains "$OUT" "SFI_ORPHAN" "the refusal must name the ambiguous code"
  pass "a reason code declared in two namespaces is refused, because its namespace could no longer be resolved by lookup"
}

test_a_gate_that_may_grant_early_is_refused() {
  local reg
  reg=$(new_register early-grant)
  mutate "$reg" laws.json \
    '(.gate_placement[] | select(.id == "G1") | .may_grant) = true'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an early gate that may grant must refuse"
  assert_contains "$OUT" "G3" "the refusal must name the only predicate that may grant"
  pass "only the effect-proximal predicate may grant; an early gate that could grant is refused at the owner"
}

test_an_unowned_edge_must_state_its_consequence() {
  local reg
  reg=$(new_register silent-unowned)
  mutate "$reg" identity.json \
    '(.edges[] | select(.status == "UNOWNED") | .consequence) = ""'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an unowned edge with no stated consequence must refuse"
  pass "an ownerless namespace edge must state what it costs, so zero owners is visible as a defect rather than as an absence"
}

test_a_venue_axis_that_is_also_an_identity_axis_is_refused() {
  local reg
  reg=$(new_register venue-overlap)
  sem_run "$reg" validate
  expect_code 0 "$CODE" "the private copy should start green"
  mutate "$reg" identity.json \
    '(.canonical_subject.subject_types[] | select(.subject_type == "outbound_request") | .venue_axes) |= (. + ["head"])'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a venue axis that is also an identity axis must refuse"
  assert_contains "$OUT" "a transport cannot become a subject" \
    "the refusal must name the class: where a review was asked is not what it is about"
  pass "a subject type in which a venue axis is also an identity axis is refused, which is what makes transport-versus-subject mechanical rather than a caution"
}

test_a_referential_integrity_rule_naming_no_declared_axis_is_refused() {
  local reg
  reg=$(new_register vacuous-integrity)
  mutate "$reg" identity.json \
    '(.canonical_subject.subject_types[] | select(.subject_type == "outbound_request") | .referential_integrity) |= (. + ["sprocket must belong to widget"])'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a rule about an axis that does not exist must refuse"
  assert_contains "$OUT" "naming no declared axis" "the refusal must say why the rule could never fire"
  pass "a referential-integrity rule naming no declared axis is refused, so a rule cannot go quietly vacuous"
}

test_a_census_extension_without_a_consumer_action_is_a_synonym() {
  local reg
  reg=$(new_register synonym-extension)
  mutate "$reg" census.json \
    '(.rows[] | select(.classification == "SUBJECT_SPECIFIC_EXTENSION") | .consumer_action_distinction) = ""'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an extension with no consumer-action distinction must refuse"
  assert_contains "$OUT" "synonym" "the refusal must say why the distinction is not one"
  pass "a subject-specific extension with no consumer-action distinction is refused as a synonym"
}

test_an_adapter_without_a_retirement_condition_is_refused() {
  local reg
  reg=$(new_register permanent-adapter)
  mutate "$reg" census.json \
    '(.rows[] | select(.classification == "ADAPTER")) |= del(.retires_on)'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "an adapter with no retirement condition must refuse"
  assert_contains "$OUT" "permanent hidden second path" "the refusal must name what an unretired adapter becomes"
  pass "an adapter that names nothing it retires on is refused, because a permanent adapter is a hidden second path"
}

test_the_register_may_not_grow_a_runtime() {
  local reg
  reg=$(new_register runtime-key)
  mutate "$reg" state-families.json '. + {"queue": ["a"]}'
  sem_run "$reg" validate
  expect_code 3 "$CODE" "a runtime-shaped key must refuse outright"
  assert_contains "$OUT" "refused key queue" "the refusal must name the key"
  pass "a runtime-shaped key anywhere in the register is refused outright, not ignored"
}

test_an_unreadable_owner_is_could_not_observe_and_never_a_pass() {
  local reg
  reg=$(new_register unreadable-owner)
  printf 'not json at all\n' > "$reg/reasons.json"
  sem_run "$reg" validate
  expect_code 4 "$CODE" "an unreadable owner must be could-not-observe, not a pass and not a refusal"
  assert_contains "$OUT" "not readable JSON" "the diagnostic must name what could not be read"
  pass "an unreadable owner answers could-not-observe: an unreadable register and a clean one never share a verdict"
}

# --- compiler and drift -------------------------------------------------------

test_the_shipped_projections_are_fresh() {
  sem_run "$ROOT/semantics" compile --check
  expect_code 0 "$CODE" "the committed projections should reproduce from the owners"
  assert_contains "$OUT" "byte-for-byte" "the check should say what it proved"
  pass "every committed projection reproduces byte-for-byte from its owners"
}

test_a_hand_edited_projection_is_refused_as_drift() {
  local work
  work="$TMP_ROOT/drift"
  mkdir -p "$work/semantics" "$work/loopspecs" "$work/bin"
  cp -R "$ROOT/semantics/." "$work/semantics/"
  cp "$ROOT/loopspecs/terminal-states.json" "$work/loopspecs/"
  cp "$ROOT/bin/fm-semantics.sh" "$ROOT/bin/fm-semantics-lib.sh" "$work/bin/"
  # Green first, so the red below is attributable to the hand edit alone.
  OUT=$(FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile --check 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "the copied tree should start fresh"
  jq --indent 2 '.description = "hand edited"' "$work/loopspecs/terminal-states.json" \
    > "$work/loopspecs/.t" && mv "$work/loopspecs/.t" "$work/loopspecs/terminal-states.json"
  OUT=$(FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile --check 2>&1)
  CODE=$?
  expect_code 3 "$CODE" "a hand-edited projection must refuse"
  assert_contains "$OUT" "refuse_stale_projection" "the refusal must carry its stable token"
  assert_contains "$OUT" "loopspecs/terminal-states.json" "the refusal must name the drifted file"
  pass "a hand edit of a generated projection is refused as drift and names the file to recompile"
}

test_compiling_twice_produces_identical_bytes() {
  local work a b
  work="$TMP_ROOT/determinism"
  mkdir -p "$work/semantics" "$work/loopspecs" "$work/bin"
  cp -R "$ROOT/semantics/." "$work/semantics/"
  cp "$ROOT/bin/fm-semantics.sh" "$ROOT/bin/fm-semantics-lib.sh" "$work/bin/"
  FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile >/dev/null 2>&1 \
    || fail "the first compile should succeed"
  a=$(cat "$work/loopspecs/terminal-states.json" "$work/semantics/generated/semantics.projection.json" \
          "$work/semantics/generated/semantics.projection.sh")
  FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile >/dev/null 2>&1 \
    || fail "the second compile should succeed"
  b=$(cat "$work/loopspecs/terminal-states.json" "$work/semantics/generated/semantics.projection.json" \
          "$work/semantics/generated/semantics.projection.sh")
  [ "$a" = "$b" ] || fail "two compiles of one register produced different bytes"
  pass "the compiler is deterministic: two runs over one register emit identical bytes"
}

test_an_owner_edit_moves_the_recorded_source_digest() {
  local work before after
  work="$TMP_ROOT/digest"
  mkdir -p "$work/semantics" "$work/loopspecs" "$work/bin"
  cp -R "$ROOT/semantics/." "$work/semantics/"
  cp "$ROOT/bin/fm-semantics.sh" "$ROOT/bin/fm-semantics-lib.sh" "$work/bin/"
  FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile >/dev/null 2>&1 \
    || fail "the first compile should succeed"
  before=$(jq -r '.generated.source_digest' "$work/loopspecs/terminal-states.json")
  jq --indent 2 '(.families[] | select(.name == "ACTIVE") | .description) = "changed"' \
    "$work/semantics/state-families.json" > "$work/semantics/.t" \
    && mv "$work/semantics/.t" "$work/semantics/state-families.json"
  FM_SEMANTICS_DIR="$work/semantics" "$work/bin/fm-semantics.sh" compile >/dev/null 2>&1 \
    || fail "the second compile should succeed"
  after=$(jq -r '.generated.source_digest' "$work/loopspecs/terminal-states.json")
  [ -n "$before" ] && [ -n "$after" ] || fail "the projection recorded no source digest"
  [ "$before" != "$after" ] || fail "an owner edit left the recorded source digest unchanged"
  pass "a projection records the digest of the owners it was compiled from, and an owner edit moves it"
}

test_the_compiled_shell_projection_parses_and_carries_the_vocabulary() {
  local proj
  proj="$ROOT/semantics/generated/semantics.projection.sh"
  assert_present "$proj" "the shell projection should be committed"
  bash -n "$proj" || fail "the compiled shell projection does not parse"
  # Consume it the way a shell owner would, and read a value out of it.
  OUT=$(bash -c '. "$1"; printf "%s|%s|%s\n" "$FM_SEMANTICS_FAMILIES" \
        "$FM_SEMANTICS_SUCCESSORS_SUPERSEDED" "$FM_SEMANTICS_VALIDATOR_VERDICTS"' _ "$proj") \
    || fail "the shell projection could not be sourced"
  assert_contains "$OUT" "WAITING_EXTERNAL" "the projection should carry the family vocabulary"
  assert_contains "$OUT" "PASS REFUSE CNO" "the projection should carry the validator verdicts"
  assert_contains "$OUT" "||" "SUPERSEDED should project an empty successor set"
  pass "the compiled shell projection parses, sources cleanly, and carries the vocabulary a shell owner would consume"
}

# --- preflight and manifests --------------------------------------------------

test_preflight_refuses_a_name_an_owner_already_covers() {
  sem_run "$ROOT/semantics" preflight --concept state_family --name ACTIVE
  expect_code 3 "$CODE" "reuse is mandatory where a shared semantics applies"
  assert_contains "$OUT" "refuse_preflight" "the refusal must carry its stable token"
  assert_contains "$OUT" "reuse is MANDATORY" "the refusal must say reuse is required"
  pass "the design preflight refuses a concept an existing owner already covers"
}

test_preflight_admits_a_genuinely_new_name() {
  sem_run "$ROOT/semantics" preflight --concept reason --name TOTALLY_NEW_CODE
  expect_code 0 "$CODE" "a name no owner covers may be proposed"
  assert_contains "$OUT" "consumer-action distinction" "the pass must state what a proposal still owes"
  pass "the design preflight admits a genuinely new name and still names the rationale it owes"
}

test_preflight_resolves_across_every_declared_concept() {
  local concept name
  # A preflight that silently answered "new" for a concept it could not read
  # would be the vacuity this control exists to prevent, so each declared
  # concept is driven against a member that really exists.
  for concept in "state_family:ACTIVE" "terminal_reason:goal_met" "reason:IDENT_MOVED" \
                 "reason_namespace:effect" "identity_namespace:N1" "subject_type:repo_object" \
                 "protocol:fm-sol-control/v1" "seam_state:NOT_YET_EXERCISED"; do
    name=${concept#*:}
    sem_run "$ROOT/semantics" preflight --concept "${concept%%:*}" --name "$name"
    expect_code 3 "$CODE" "preflight should refuse the existing ${concept%%:*} $name"
  done
  pass "every declared preflight concept resolves against a real member, so none can go quietly vacuous"
}

test_the_shipped_manifest_inherits_what_it_declares() {
  sem_run "$ROOT/semantics" manifest --all
  expect_code 0 "$CODE" "the shipped manifest should validate"
  assert_contains "$OUT" "inherits every shared semantics it declares" "the pass should say what it proved"
  pass "the mechanism this branch adds carries its own inheritance manifest and it validates"
}

test_a_manifest_missing_an_inheritance_field_is_refused() {
  local reg
  reg=$(new_register manifest-gap)
  jq --indent 2 'del(.consumes.identity_namespaces)' \
    "$reg/manifests/state-seam-semantics.json" > "$reg/manifests/.t" \
    && mv "$reg/manifests/.t" "$reg/manifests/state-seam-semantics.json"
  sem_run "$reg" manifest --all
  expect_code 3 "$CODE" "an absent inheritance field must refuse"
  assert_contains "$OUT" "refuse_invalid_manifest" "the refusal must carry its stable token"
  assert_contains "$OUT" "identity_namespaces" "the refusal must name the missing field"
  assert_contains "$OUT" "an absent key is not" "the refusal must distinguish an explicit none from an omission"
  pass "an inheritance manifest missing a consumed semantics is refused; an explicit none is a declaration and an absent key is not"
}

test_a_manifest_claiming_a_version_the_owner_does_not_declare_is_refused() {
  local reg
  reg=$(new_register manifest-version)
  jq --indent 2 '.consumes.state_families.version = 99' \
    "$reg/manifests/state-seam-semantics.json" > "$reg/manifests/.t" \
    && mv "$reg/manifests/.t" "$reg/manifests/state-seam-semantics.json"
  sem_run "$reg" manifest --all
  expect_code 3 "$CODE" "a manifest cannot claim to inherit a version that does not exist"
  assert_contains "$OUT" "99" "the refusal must name the claimed version"
  pass "a manifest claiming a vocabulary version the owner does not declare is refused"
}

test_an_extension_without_a_consumer_action_distinction_is_refused() {
  local reg
  reg=$(new_register manifest-extension)
  jq --indent 2 '(.extensions[0].consumer_action_distinction) = ""' \
    "$reg/manifests/state-seam-semantics.json" > "$reg/manifests/.t" \
    && mv "$reg/manifests/.t" "$reg/manifests/state-seam-semantics.json"
  sem_run "$reg" manifest --all
  expect_code 3 "$CODE" "an extension with no consumer-action distinction must refuse"
  assert_contains "$OUT" "synonym" "the refusal must say what an undistinguished extension is"
  pass "a subject-specific extension in a manifest must state a consumer-action difference or be refused as a synonym"
}

test_an_extension_may_not_shadow_a_canonical_name() {
  local reg
  reg=$(new_register manifest-shadow)
  jq --indent 2 '(.extensions[0].name) = "ACTIVE" | (.extensions[0].extends) = "state_family"' \
    "$reg/manifests/state-seam-semantics.json" > "$reg/manifests/.t" \
    && mv "$reg/manifests/.t" "$reg/manifests/state-seam-semantics.json"
  sem_run "$reg" manifest --all
  expect_code 3 "$CODE" "a shadowing extension must refuse"
  assert_contains "$OUT" "shadows canonical family" "the refusal must name the collision"
  pass "a mechanism may not silently redefine a shared word: an extension shadowing a canonical name is refused"
}

test_a_manifest_carrying_a_refused_key_is_refused_outright() {
  local reg
  reg=$(new_register manifest-refused-key)
  jq --indent 2 '. + {"current_state": "green"}' \
    "$reg/manifests/state-seam-semantics.json" > "$reg/manifests/.t" \
    && mv "$reg/manifests/.t" "$reg/manifests/state-seam-semantics.json"
  sem_run "$reg" manifest --all
  expect_code 3 "$CODE" "a refused key must refuse the whole manifest"
  assert_contains "$OUT" "refused key current_state" "the refusal must name the key"
  pass "a manifest carrying a refused state-like key is refused outright rather than having the key ignored"
}

test_an_absent_manifest_is_could_not_observe() {
  local reg
  reg=$(new_register manifest-absent)
  rm -rf "${reg:?}/manifests"
  sem_run "$reg" manifest --all
  expect_code 4 "$CODE" "no manifests at all is could-not-observe, not a clean register"
  pass "a register with no manifests answers could-not-observe rather than reporting every manifest clean"
}

# --- honesty about what this mechanism may be used for ------------------------

test_the_mechanism_reports_itself_not_authoritative() {
  sem_run "$ROOT/semantics" adoption
  expect_code 4 "$CODE" "unmet adoption prerequisites are could-not-observe, never a pass"
  assert_contains "$OUT" "NOT AUTHORITATIVE" "the report must say plainly what this mechanism may not be used for"
  assert_contains "$OUT" "AP4 real producer-boundary-consumer . CNO" \
    "a real crossing cannot be observed from here and must not be claimed"
  assert_contains "$OUT" "AP5 witnessed red ................... CNO" \
    "a red seen in a test suite is evidence for the suite, not for the crossing"
  pass "the mechanism reports its own adoption prerequisites unmet and marks its output diagnostic"
}

test_every_validator_result_line_declares_its_authority() {
  local rec
  rec="$TMP_ROOT/authority-line.json"
  cat > "$rec" <<'JSON'
{"from":"WAITING_EXTERNAL","to":"ACTIVE","subject":{"digest":"d1"},
 "evidence":[{"verdict":"PASS","family":"WAITING_EXTERNAL"}],"context":{}}
JSON
  OUT=$("$SEM" validate-transition "$rec" 2>&1)
  CODE=$?
  expect_code 0 "$CODE" "the fixture transition is legal"
  assert_contains "$OUT" "authority=diagnostic" \
    "a diagnostic verdict must say so in its own text rather than relying on a reader to remember"
  pass "every validator result line declares its own authority, so a diagnostic verdict cannot be read as an authoritative one"
}

test_check_is_the_single_entry_point_and_runs_all_three() {
  sem_run "$ROOT/semantics" check
  expect_code 0 "$CODE" "the shipped register should pass the composed check"
  assert_contains "$OUT" "every declared owner invariant holds" "check must run the owner invariants"
  assert_contains "$OUT" "byte-for-byte" "check must run the drift check"
  assert_contains "$OUT" "inherits every shared semantics" "check must run the manifest check"
  pass "one command composes owner invariants, projection drift, and manifest inheritance, so CI needs no second spelling"
}

test_the_shipped_register_is_valid_json_throughout() {
  local f
  for f in "$ROOT"/semantics/*.json "$ROOT"/semantics/manifests/*.json \
           "$ROOT"/semantics/generated/*.json; do
    jq -e . "$f" >/dev/null 2>&1 || fail "not readable JSON: ${f#"$ROOT"/}"
  done
  pass "every document the register ships is readable JSON"
}

test_the_shipped_register_holds_together
test_a_successor_naming_an_undeclared_family_is_refused
test_a_terminal_family_may_not_grow_a_way_back
test_a_nonterminal_family_without_a_wake_is_refused
test_a_source_row_leaving_the_vocabulary_is_refused
test_an_observation_result_row_must_name_an_observation_verdict
test_a_reason_code_in_two_namespaces_breaks_lookup_and_is_refused
test_a_gate_that_may_grant_early_is_refused
test_an_unowned_edge_must_state_its_consequence
test_a_venue_axis_that_is_also_an_identity_axis_is_refused
test_a_referential_integrity_rule_naming_no_declared_axis_is_refused
test_a_census_extension_without_a_consumer_action_is_a_synonym
test_an_adapter_without_a_retirement_condition_is_refused
test_the_register_may_not_grow_a_runtime
test_an_unreadable_owner_is_could_not_observe_and_never_a_pass
test_the_shipped_projections_are_fresh
test_a_hand_edited_projection_is_refused_as_drift
test_compiling_twice_produces_identical_bytes
test_an_owner_edit_moves_the_recorded_source_digest
test_the_compiled_shell_projection_parses_and_carries_the_vocabulary
test_preflight_refuses_a_name_an_owner_already_covers
test_preflight_admits_a_genuinely_new_name
test_preflight_resolves_across_every_declared_concept
test_the_shipped_manifest_inherits_what_it_declares
test_a_manifest_missing_an_inheritance_field_is_refused
test_a_manifest_claiming_a_version_the_owner_does_not_declare_is_refused
test_an_extension_without_a_consumer_action_distinction_is_refused
test_an_extension_may_not_shadow_a_canonical_name
test_a_manifest_carrying_a_refused_key_is_refused_outright
test_an_absent_manifest_is_could_not_observe
test_the_mechanism_reports_itself_not_authoritative
test_every_validator_result_line_declares_its_authority
test_check_is_the_single_entry_point_and_runs_all_three
test_the_shipped_register_is_valid_json_throughout
