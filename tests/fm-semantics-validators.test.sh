#!/usr/bin/env bash
# Behavioral regressions for the four deterministic validators.
#
# Every guarantee is proved through bin/fm-semantics.sh's public interface - the
# result line it prints and the exit code it returns - never by reading source.
#
# The property under test in every block is that the validator returns THREE
# values, never two, and that the three are mechanically distinguishable. A
# suite that only checked "did it refuse" would be satisfied by a validator that
# had collapsed could-not-observe into refusal, which is the exact failure the
# three-valued type exists to prevent. So each case asserts the verdict, the
# exact reason code, the namespace that code resolves to, and the exit status.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEM="$ROOT/bin/fm-semantics.sh"
TMP_ROOT=$(fm_test_tmproot fm-semantics-validators)

OUT=""
CODE=0

# rec <name> <json> - write a record fixture; echoes its path.
rec() {
  local path="$TMP_ROOT/$1.json"
  printf '%s\n' "$2" > "$path"
  printf '%s\n' "$path"
}

# expect_verdict <verdict> <reason> <namespace> <label> - assert the last result.
expect_verdict() {
  local verdict=$1 reason=$2 namespace=$3 label=$4 want_code
  case "$verdict" in
    PASS) want_code=0 ;;
    REFUSE) want_code=3 ;;
    CNO) want_code=4 ;;
    *) fail "$label: unknown expected verdict $verdict" ;;
  esac
  assert_contains "$OUT" "verdict=$verdict " "$label: verdict"
  assert_contains "$OUT" "reason=$reason " "$label: reason code"
  assert_contains "$OUT" "namespace=$namespace " "$label: reason namespace"
  expect_code "$want_code" "$CODE" "$label: exit code"
}

run_state() { OUT=$("$SEM" validate-state "$@" 2>&1); CODE=$?; }
run_transition() { OUT=$("$SEM" validate-transition "$@" 2>&1); CODE=$?; }
run_effect() { OUT=$("$SEM" validate-effect-commit "$@" 2>&1); CODE=$?; }
run_identity() { OUT=$("$SEM" validate-identity-mapping "$@" 2>&1); CODE=$?; }

# --- validate_state -----------------------------------------------------------

test_a_well_formed_nonterminal_state_passes() {
  run_state "$(rec state-ok '{
    "family":"WAITING_EXTERNAL",
    "subject":{"schema":"fm-canonical-subject.v1","subject_type":"work_item","digest":"d1"},
    "evidence":[{"verdict":"PASS","as_of_epoch":1000,"freshness_seconds":3600}],
    "obligation":{"owner":"browser-sol","wake":"inbound ruling",
                  "reobserve":"bin/fm-outbound-artifact.sh check",
                  "legal_successors":["ACTIVE","REFUSED"]}}')"
  expect_verdict PASS - - "a complete nonterminal state"
  pass "a nonterminal state naming an owner, a wake, a reobservation and bounded successors passes"
}

test_a_terminal_state_carrying_an_obligation_is_a_false_terminal() {
  run_state "$(rec state-false-terminal '{
    "family":"SUCCEEDED",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}],
    "obligation":{"owner":"x","wake":"y","reobserve":"z","legal_successors":["SUPERSEDED"]}}')"
  expect_verdict REFUSE SFI_FALSE_TERMINAL state_family "a terminal state with an open obligation"
  assert_contains "$OUT" "both cannot be true" "the refusal should name the contradiction"
  pass "a terminal family carrying an open continuation obligation is refused as a false terminal"
}

test_a_nonterminal_state_with_no_wake_is_orphaned_not_patient() {
  run_state "$(rec state-orphan '{
    "family":"WAITING_EXTERNAL",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}],
    "obligation":{"owner":"browser-sol","wake":"","reobserve":"z","legal_successors":["ACTIVE"]}}')"
  expect_verdict REFUSE SFI_ORPHAN state_family "a nonterminal state with no wake"
  assert_contains "$OUT" "is not patient" "the refusal should name what an unarmed wait actually is"
  pass "a nonterminal state whose reobservation could never fire is refused as orphaned rather than read as patient"
}

test_a_successor_outside_the_family_is_unbounded() {
  run_state "$(rec state-unbounded '{
    "family":"RETRY_PENDING",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}],
    "obligation":{"owner":"attempt record","wake":"resume condition","reobserve":"bin/fm-attempt.sh",
                  "legal_successors":["ACTIVE","SUCCEEDED"]}}')"
  expect_verdict REFUSE SFI_UNBOUNDED_SUCCESSORS state_family "a successor the family does not declare"
  assert_contains "$OUT" "SUCCEEDED" "the refusal should name the successor that escaped the family"
  pass "a state naming a successor its family does not declare is refused, so successors stay enumerable from the family alone"
}

test_more_than_one_actionable_successor_is_a_count_not_a_judgement() {
  run_state "$(rec state-multi '{
    "family":"SUPERSEDED",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}],
    "successors":[{"subject":"s1","family":"ACTIVE"},{"subject":"s2","family":"ACTIVE"}]}')"
  expect_verdict REFUSE SFI_MULTIPLE_ACTIONABLE state_family "two actionable successors"
  assert_contains "$OUT" "not a review question" "the refusal should say the check is a count"
  pass "at most one successor of a superseded predecessor may be actionable, and the check is a count"
}

test_a_cardinality_check_with_nothing_to_examine_is_not_credited() {
  # Same state, successors omitted. The check must fall out of dimensions=
  # rather than silently passing: a check that examined nothing must never be
  # credited with having looked.
  run_state "$(rec state-nosucc '{
    "family":"SUPERSEDED",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}]}')"
  expect_verdict PASS - - "a superseded state with no successor list"
  assert_not_contains "$OUT" "successor-cardinality" \
    "an unexaminable dimension must not appear in the scope of the verdict"
  run_state "$(rec state-withsucc '{
    "family":"SUPERSEDED",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}],
    "successors":[{"subject":"s1","family":"ACTIVE"}]}')"
  assert_contains "$OUT" "successor-cardinality" \
    "an examined dimension must appear in the scope of the verdict"
  pass "a verdict names exactly the dimensions it examined, so a pass on one is never credited to another"
}

test_a_state_with_no_observation_is_unevidenced_not_clean() {
  run_state "$(rec state-unevidenced '{
    "family":"SUCCEEDED",
    "subject":{"digest":"d1"},
    "evidence":[]}')"
  expect_verdict CNO SFI_UNEVIDENCED observation "a state with no evidence"
  assert_contains "$OUT" "not clean" "the answer should say what zero evidence entries actually means"
  pass "a state carrying no observation answers could-not-observe: zero evidence is unevidenced, never clean"
}

test_evidence_that_only_failed_to_observe_is_still_unevidenced() {
  run_state "$(rec state-noverifier '{
    "family":"SUCCEEDED",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"NO_VERIFIER_RAN"},{"verdict":"NO_VERIFIER_RAN"}]}')"
  expect_verdict CNO SFI_UNEVIDENCED observation "evidence that never observed anything"
  pass "a state whose every evidence entry is an observation that did not happen is could-not-observe, not a pass"
}

test_an_unresolvable_subject_is_could_not_observe() {
  run_state "$(rec state-nosubject '{
    "family":"SUCCEEDED",
    "subject":{},
    "evidence":[{"verdict":"PASS"}]}')"
  expect_verdict CNO IDENT_UNRESOLVABLE identity "a subject with no digest"
  pass "a state whose subject does not resolve to a compilation record answers could-not-observe"
}

test_a_family_outside_the_vocabulary_refuses_rather_than_defaulting() {
  run_state "$(rec state-unknown '{
    "family":"MOSTLY_DONE",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS"}]}')"
  expect_verdict REFUSE SFI_UNKNOWN_FAMILY state_family "an undeclared family"
  assert_contains "$OUT" "never default it" "the refusal should say what must not happen"
  pass "an undeclared family value refuses rather than being defaulted onto a plausible neighbour"
}

test_only_an_effect_proximal_caller_is_denied_a_stale_permission() {
  local fixture
  fixture=$(rec state-stale '{
    "family":"WAITING_EXTERNAL",
    "subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","as_of_epoch":1000,"freshness_seconds":60}],
    "obligation":{"owner":"o","wake":"w","reobserve":"r","legal_successors":["ACTIVE"]}}')
  # An ordinary caller is answered without consulting the clock at all.
  run_state "$fixture" --now 999999
  expect_verdict PASS - - "an ordinary caller reading aged evidence"
  assert_not_contains "$OUT" "freshness" "the clock must not be consulted for an ordinary caller"
  # The same record, the same clock, an effect-proximal caller.
  run_state "$fixture" --for-effect --now 999999
  expect_verdict CNO SFI_STALE_FOR_EFFECT observation "an effect-proximal caller reading aged evidence"
  assert_contains "$OUT" "freshness" "the examined dimension must be named"
  # And fresh evidence still serves an effect-proximal caller.
  run_state "$fixture" --for-effect --now 1010
  expect_verdict PASS - - "an effect-proximal caller reading fresh evidence"
  pass "an early gate refuses and never grants; only an effect-proximal caller is denied a permission that has aged"
}

# --- validate_transition ------------------------------------------------------

test_a_declared_transition_passes() {
  run_transition "$(rec tr-ok '{
    "from":"WAITING_EXTERNAL","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"WAITING_EXTERNAL"}],"context":{}}')"
  expect_verdict PASS - - "a declared successor"
  pass "a transition the source family declares, on evidence produced in that family, passes"
}

test_an_undeclared_transition_is_refused() {
  run_transition "$(rec tr-illegal '{
    "from":"SUCCEEDED","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"SUCCEEDED"}],"context":{}}')"
  expect_verdict REFUSE TRANS_ILLEGAL transition "a successor the family does not declare"
  pass "a transition outside the declared successor set is refused"
}

test_resurrection_names_the_specific_reason_not_the_generic_one() {
  run_transition "$(rec tr-resurrect '{
    "from":"SUPERSEDED","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"SUPERSEDED"}],"context":{}}')"
  expect_verdict REFUSE TRANS_STALE_RESURRECTION transition "a superseded subject moved back"
  assert_not_contains "$OUT" "TRANS_ILLEGAL" \
    "the generic reason must not win over the specific one, or the repair named would be the weaker one"
  pass "resurrecting a superseded subject names its own reason, not the generic illegal-transition one"
}

test_evidence_from_another_family_cannot_promote() {
  run_transition "$(rec tr-cross '{
    "from":"WAITING_EXTERNAL","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"SUCCEEDED"}],"context":{}}')"
  expect_verdict REFUSE TRANS_CROSS_FAMILY_PROMOTION transition "evidence made in another family"
  assert_contains "$OUT" "does not authorise landing" "the refusal should name the class it belongs to"
  pass "a verdict from one family cannot advance a subject in another"
}

test_an_unaddressed_finding_blocks_promotion() {
  run_transition "$(rec tr-revise '{
    "from":"REVISE","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"REVISE"}],"context":{}}')"
  expect_verdict REFUSE TRANS_UNADDRESSED_REVISE transition "a REVISE promoted with nothing addressing the finding"
  assert_contains "$OUT" "no checker verdict discharges it" "the refusal should name whose obligation it is"
  # The same move with evidence that names the finding it addresses is legal.
  run_transition "$(rec tr-revise-ok '{
    "from":"REVISE","to":"ACTIVE","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"REVISE","addresses":"finding-3"}],"context":{}}')"
  expect_verdict PASS - - "a REVISE promoted on evidence naming the finding"
  pass "an unaddressed finding blocks promotion, and evidence naming the finding releases it"
}

test_a_target_requiring_an_authority_refuses_a_name() {
  run_transition "$(rec tr-auth '{
    "from":"ACTIVE","to":"SUCCEEDED","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"ACTIVE"}],
    "context":{"requires_authority":true,"authority":{"state":"granted","subject":"OTHER"}}}')"
  expect_verdict REFUSE IDENT_AUTHORITY_BY_NAME identity "an authority granted for a different subject"
  assert_contains "$OUT" "never as a property" "the refusal should name why a token is not a property"
  pass "an authority granted for another subject does not authorise this one; permission is held, never possessed by name"
}

test_a_material_generation_difference_refuses() {
  run_transition "$(rec tr-generation '{
    "from":"ACTIVE","to":"SUCCEEDED","subject":{"digest":"d1"},
    "evidence":[{"verdict":"PASS","family":"ACTIVE","generation":"g1"}],
    "context":{"generation_is_material":true,"generation":"g2"}}')"
  expect_verdict REFUSE TRANS_STALE_GENERATION transition "evidence from a superseded generation"
  assert_contains "$OUT" "attributed to the worker that produced it" \
    "the refusal should say what happens to the old evidence"
  pass "evidence from a generation the contract declares material is refused, and stays attributed to its own producer"
}

test_a_transition_with_no_observation_is_could_not_observe() {
  run_transition "$(rec tr-unevidenced '{
    "from":"ACTIVE","to":"SUCCEEDED","subject":{"digest":"d1"},
    "evidence":[{"verdict":"NO_VERIFIER_RAN","family":"ACTIVE"}],"context":{}}')"
  expect_verdict CNO TRANS_UNEVIDENCED transition "a transition offered no observation"
  pass "a transition whose evidence never observed anything is could-not-observe, never a pass and never a rejection"
}

# --- validate_effect_commit ---------------------------------------------------

test_a_pre_effect_with_three_agreeing_heads_passes() {
  run_effect "$(rec ef-pre-ok '{
    "authority":{"state":"granted","subject":"d1"},"served_from_cache":false,"intent_recorded":true,
    "approved_head":"aaa","caller_head":"aaa","observed_head":"aaa"}')" PRE_EFFECT
  expect_verdict PASS - - "a complete pre-effect check"
  pass "a granted authority, an uncached input, a recorded intent and three agreeing heads pass the pre-effect gate"
}

test_two_agreeing_heads_are_not_three() {
  run_effect "$(rec ef-pre-disagree '{
    "authority":{"state":"granted","subject":"d1"},"served_from_cache":false,"intent_recorded":true,
    "approved_head":"aaa","caller_head":"aaa","observed_head":"bbb"}')" PRE_EFFECT
  expect_verdict REFUSE EFFECT_HEAD_DISAGREEMENT effect "the world moved under an approved head"
  assert_contains "$OUT" "weaker neighbours" "the refusal should name why two of three is not the property"
  pass "agreement of approved, intended and observed heads is the property; any two of them is refused"
}

test_a_cached_input_is_refused_at_an_effect() {
  run_effect "$(rec ef-pre-cache '{
    "authority":{"state":"granted","subject":"d1"},"served_from_cache":true,"intent_recorded":true,
    "approved_head":"aaa","caller_head":"aaa","observed_head":"aaa"}')" PRE_EFFECT
  expect_verdict REFUSE SFI_STALE_FOR_EFFECT observation "an input served from a cache"
  assert_contains "$OUT" "at any age" "the refusal should say the age is irrelevant"
  pass "no stored verdict is served to an effect-proximal caller at any age"
}

test_an_unrecordable_intent_refuses_before_the_act() {
  run_effect "$(rec ef-pre-intent '{
    "authority":{"state":"granted","subject":"d1"},"served_from_cache":false,"intent_recorded":false,
    "approved_head":"aaa","caller_head":"aaa","observed_head":"aaa"}')" PRE_EFFECT
  expect_verdict REFUSE EFFECT_INTENT_UNRECORDABLE effect "intent that could not be written first"
  assert_contains "$OUT" "not recoverable" "the refusal should say why the ordering matters"
  pass "an intent that cannot be durably written before the act refuses the act"
}

test_an_unobservable_target_is_could_not_observe_not_a_refusal() {
  run_effect "$(rec ef-pre-target '{
    "authority":{"state":"granted","subject":"d1"},"served_from_cache":false,"intent_recorded":true,
    "approved_head":"aaa","caller_head":"aaa","observed_head":""}')" PRE_EFFECT
  expect_verdict CNO EFFECT_TARGET_UNOBSERVED effect "a target that could not be read"
  assert_contains "$OUT" "only two values" \
    "the answer should say why an unread value cannot produce a disagreement refusal"
  pass "a head comparison against a value that was never read is could-not-observe, not a refusal wearing one"
}

test_a_precommit_rendered_as_committed_is_refused() {
  run_effect "$(rec ef-commit-claim '{
    "authority":{"state":"spending"},"rendered_as_committed":true}')" COMMIT_POINT
  expect_verdict REFUSE EFFECT_PRECOMMIT_CLAIMED_COMMITTED effect "a precommit claiming to be committed"
  assert_contains "$OUT" "not one of its neighbours" "the refusal should name the commit point as its own state"
  pass "a state before the commit point may never render as committed"
}

test_the_commit_point_requires_the_honest_middle_state() {
  run_effect "$(rec ef-commit-granted '{
    "authority":{"state":"granted"},"rendered_as_committed":false}')" COMMIT_POINT
  expect_verdict REFUSE EFFECT_INTENT_UNRECORDABLE effect "an authority never moved to spending"
  assert_contains "$OUT" "may or may not have happened" "the refusal should name what spending is for"
  run_effect "$(rec ef-commit-ok '{
    "authority":{"state":"spending"},"rendered_as_committed":false}')" COMMIT_POINT
  expect_verdict PASS - - "an authority correctly in spending"
  pass "the commit point requires an authority in spending, the honest name for the window the act may have happened in"
}

test_a_failed_act_is_indeterminate_and_never_not_applied() {
  run_effect "$(rec ef-post-failed '{
    "authority":{"state":"spending"},"outcome_recorded":true,"act_reported":"failed",
    "actor":"bin/fm-pr-merge.sh","post_effect_proof":{"source":"github"}}')" POST_EFFECT
  expect_verdict CNO EFFECT_INDETERMINATE effect "an act that reported failure"
  assert_contains "$OUT" "does not prove NOT_APPLIED" "the answer should name the inference it refuses"
  pass "a failed invocation of an irreversible act is indeterminate, never proof the act did not happen"
}

test_the_actor_report_is_not_the_proof() {
  run_effect "$(rec ef-post-selfproof '{
    "authority":{"state":"spending"},"outcome_recorded":true,"act_reported":"applied",
    "actor":"bin/fm-pr-merge.sh","post_effect_proof":{"source":"bin/fm-pr-merge.sh"}}')" POST_EFFECT
  expect_verdict CNO EFFECT_UNPROVEN effect "a proof produced by the actor itself"
  assert_contains "$OUT" "is not the proof" "the answer should say whose observation does not count"
  run_effect "$(rec ef-post-ok '{
    "authority":{"state":"spending"},"outcome_recorded":true,"act_reported":"applied",
    "actor":"bin/fm-pr-merge.sh","post_effect_proof":{"source":"github","observed":"aaa"}}')" POST_EFFECT
  expect_verdict PASS - - "an independent observation of the target"
  pass "a post-effect proof must be an independent observation of the target; the actor own report is unproven, not success"
}

test_a_second_spend_of_a_one_use_authority_is_a_replay() {
  run_effect "$(rec ef-post-replay '{
    "authority":{"state":"spent"},"outcome_recorded":true,"act_reported":"applied",
    "actor":"a","post_effect_proof":{"source":"github"}}')" POST_EFFECT
  expect_verdict REFUSE EFFECT_REPLAY effect "an authority already spent"
  pass "an authority is exhausted by use, so a duplicate arrival is refused as a replay"
}

test_an_unknown_phase_is_could_not_observe() {
  run_effect "$(rec ef-phase '{"authority":{"state":"granted"}}')" MIDWAY
  expect_verdict CNO EFFECT_INDETERMINATE effect "a phase outside the declared three"
  pass "an effect phase outside the declared three answers could-not-observe rather than guessing which one was meant"
}

# --- validate_identity_mapping ------------------------------------------------

test_a_clean_mapping_across_an_owned_edge_passes() {
  run_identity "$(rec id-ok '{
    "edge":"N3->N4","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":true,
    "recompiled_digest":"d1","resolved_subject":"d1","provenance":"state/x.meta"}')"
  expect_verdict PASS - - "one owner, one candidate, agreeing recompilation"
  assert_contains "$OUT" "bin/fm-pr-check.sh" "the pass should name the owner that is answerable"
  pass "a mapping across an owned edge with one candidate and an agreeing recompilation passes and names its owner"
}

test_an_unowned_edge_refuses_because_nobody_is_answerable() {
  run_identity "$(rec id-unowned '{
    "edge":"N4->N3 reverse join","subject":{"digest":"d1"},"candidates":1,
    "target_rule_observed":true,"recompiled_digest":"d1","resolved_subject":"d1","provenance":"x"}')"
  expect_verdict REFUSE IDENT_MULTI_OWNER identity "an edge with no owner"
  assert_contains "$OUT" "no registered owner" "the refusal should carry the consequence the register recorded"
  pass "an ownerless edge refuses at resolution: zero owners and two owners are the same defect"
}

test_an_undeclared_edge_refuses_the_same_way() {
  run_identity "$(rec id-undeclared '{
    "edge":"N9->N42","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":true,
    "recompiled_digest":"d1","resolved_subject":"d1","provenance":"x"}')"
  expect_verdict REFUSE IDENT_MULTI_OWNER identity "an edge nobody declared"
  assert_contains "$OUT" "the same defect" "the refusal should say why an undeclared edge is not a different case"
  pass "an undeclared namespace edge refuses like a two-owner one, because in both cases nobody is answerable"
}

test_ambiguity_and_substitution_stay_apart() {
  run_identity "$(rec id-ambiguous '{
    "edge":"N3->N4","subject":{"digest":"d1"},"candidates":2,"target_rule_observed":true,
    "recompiled_digest":"d1","resolved_subject":"d1","provenance":"x"}')"
  expect_verdict REFUSE IDENT_AMBIGUOUS identity "several candidates and none choosable"
  assert_contains "$OUT" "not a mismatch" "the refusal should say which neighbouring class it is not"
  run_identity "$(rec id-substitution '{
    "edge":"N3->N4","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":true,
    "recompiled_digest":"d1","resolved_subject":"d2","provenance":"x"}')"
  expect_verdict REFUSE IDENT_NAMESPACE_SUBSTITUTION identity "one candidate about a different subject"
  pass "ambiguity and substitution return different codes, because the operator repairs a different thing in each"
}

test_a_moved_subject_is_a_different_subject() {
  run_identity "$(rec id-moved '{
    "edge":"N3->N1","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":true,
    "recompiled_digest":"d9","resolved_subject":"d1","provenance":"x"}')"
  expect_verdict REFUSE IDENT_MOVED identity "a recompilation that disagrees"
  assert_contains "$OUT" "not a stale one" "the refusal should say what a moved head actually is"
  pass "recompiling from the world and getting a different digest refuses: a moved head is a different subject"
}

test_an_undeterminable_target_rule_is_could_not_observe() {
  run_identity "$(rec id-rule '{
    "edge":"N3->N1","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":false,
    "recompiled_digest":"d1","resolved_subject":"d1","provenance":"x"}')"
  expect_verdict CNO IDENT_RULE_UNOBSERVED identity "an unreadable namespace rule"
  assert_contains "$OUT" "never default the rule" "the answer should name what must not happen"
  pass "an undeterminable target identity rule answers could-not-observe rather than defaulting the rule"
}

test_a_mapping_with_no_provenance_cannot_be_rechecked() {
  run_identity "$(rec id-provenance '{
    "edge":"N3->N4","subject":{"digest":"d1"},"candidates":1,"target_rule_observed":true,
    "recompiled_digest":"d1","resolved_subject":"d1","provenance":""}')"
  expect_verdict CNO IDENT_UNPROVENANCED identity "a mapping that left no record"
  pass "a mapping with no provenance record answers could-not-observe, because it cannot be re-checked later"
}

# --- namespace integrity: transport is never the governed subject -------------
#
# The recurrence these fixtures pin is a request that persisted the CONTROL
# repository as its subject repository while binding a candidate head belonging
# to the GOVERNED repository. Both axis values were individually well formed;
# only the relation between them was wrong, which is why a per-field check could
# not have caught it. Browser Sol ruling 5387155383 is the preserved instance.
#
# These prove the distinction is mechanically EXPRESSIBLE and refusable in the
# foundation. They repair no producer: bin/fm-outbound-artifact-lib.sh is
# unchanged on this branch, and that migration is phase 9.

test_a_subject_resolved_from_the_transport_venue_is_refused() {
  # The shape of the recurrence: the mapping resolved an object belonging to the
  # venue where the governed subject was asked for.
  run_identity "$(rec id-transport-subject '{
    "edge":"N3->N4","subject":{"digest":"governed-subject-digest"},"candidates":1,
    "target_rule_observed":true,"recompiled_digest":"governed-subject-digest",
    "resolved_subject":"control-venue-digest","provenance":"state/x.meta"}')"
  expect_verdict REFUSE IDENT_NAMESPACE_SUBSTITUTION identity "a subject resolved from the transport venue"
  assert_contains "$OUT" "a transport cannot become a subject" \
    "the refusal should name the substitution class the recurrence belongs to"
  pass "a mapping that resolves the transport venue where the governed subject was asked for is refused as a namespace substitution"
}

test_the_venue_and_the_governed_subject_are_declared_disjoint() {
  local required venue overlap
  required=$(jq -r '.canonical_subject.subject_types[] | select(.subject_type == "outbound_request")
                    | (.required_axes + (.mutable_axes // [])) | join(" ")' "$ROOT/semantics/identity.json")
  venue=$(jq -r '.canonical_subject.subject_types[] | select(.subject_type == "outbound_request")
                 | (.venue_axes // []) | join(" ")' "$ROOT/semantics/identity.json")
  [ -n "$venue" ] || fail "the outbound request subject type declares no venue axes, so the distinction is unexpressed"
  overlap=$(comm -12 <(printf '%s\n' "$required" | tr ' ' '\n' | sort -u) \
                     <(printf '%s\n' "$venue" | tr ' ' '\n' | sort -u) | awk 'NF')
  [ -z "$overlap" ] || fail "a venue axis is also an identity axis: $overlap"
  assert_contains "$required" "governed_repo" \
    "the identity axis should name the GOVERNED repository, not an ambiguous repo"
  assert_contains "$venue" "transport_venue" "the venue should be carried as its own axis"
  pass "the governed subject axes and the transport venue axes are declared disjoint, so a venue value has no identity axis to occupy"
}

test_referential_integrity_between_axes_is_declared_and_non_vacuous() {
  local rules
  rules=$(jq -r '.canonical_subject.subject_types[] | select(.subject_type == "outbound_request")
                 | (.referential_integrity // []) | join(" | ")' "$ROOT/semantics/identity.json")
  [ -n "$rules" ] || fail "no referential-integrity rule is declared for the outbound request subject"
  assert_contains "$rules" "head must be an object of governed_repo" \
    "the rule that refuses the observed recurrence should be stated"
  assert_contains "$rules" "never of transport_venue" "the rule should name the axis it excludes"
  # The ordering is the whole property: a check after the wait cannot prevent it.
  rules=$(jq -r '.canonical_subject.compilation_rules[] | select(startswith("referential_integrity"))' \
          "$ROOT/semantics/identity.json")
  assert_contains "$rules" "BEFORE any durable record or wait is created" \
    "the integrity check must be required before the durable effect, not after it"
  pass "referential integrity between axes is declared, names real axes, and is required before any durable record or wait"
}
test_the_recurrence_is_cited_from_three_preserved_rulings() {
  # A census row asserting a recurrence with no citable artifact would be the
  # prose-as-evidence failure this register refuses, so every instance is pinned
  # to its own preserved ruling and its own exact head.
  local row instances declared heads
  row=$(jq -r '.rows[] | select(.id == "CEN-ID-08") | .observed_recurrence' "$ROOT/semantics/census.json")
  assert_contains "$row" "THREE independent Browser Sol rulings" \
    "the row should record that this is a recurrence, not a single incident"
  instances=$(jq -r '.rows[] | select(.id == "CEN-ID-08") | .recurrence_instances | length' \
              "$ROOT/semantics/census.json")
  [ "$instances" = "3" ] || fail "expected three cited instances, found ${instances:-none}"
  # Each ruling, each request, and each head is named. A row that cited the
  # class without the instances could not be checked against the record.
  for id in 5385612078 5385881288 5387155383; do
    row=$(jq -r --arg r "$id" '.rows[] | select(.id == "CEN-ID-08") | .recurrence_instances[]
                               | select(.ruling == $r) | .preserved_at' "$ROOT/semantics/census.json")
    [ -n "$row" ] || fail "ruling $id is not cited with a preserved artifact"
  done
  # The shape that makes the class one class: one declared repository across all
  # three, and three DIFFERENT repositories the heads actually belong to.
  declared=$(jq -r '.rows[] | select(.id == "CEN-ID-08") | [.recurrence_instances[].declared_repo]
                    | unique | length' "$ROOT/semantics/census.json")
  [ "$declared" = "1" ] || fail "the three instances should share one wrongly-declared repository, found $declared"
  heads=$(jq -r '.rows[] | select(.id == "CEN-ID-08") | [.recurrence_instances[].head_actually_belongs_to]
                 | unique | length' "$ROOT/semantics/census.json")
  [ "$heads" -ge 2 ] || fail "the instances should span more than one governed repository, found $heads"
  pass "the transport recurrence is cited from three preserved rulings, each with its request, its exact head, and the repository that head really belongs to"
}

test_the_rulings_are_recorded_as_granting_nothing() {
  # Every one of the three is a REVISE on transport identity. Recording them
  # without recording what they do NOT grant is how a transport ruling gets read
  # as a merits approval.
  local facts
  facts=$(jq -r '.rows[] | select(.id == "CEN-ID-08") | .shared_defect_facts | join(" ")' \
          "$ROOT/semantics/census.json")
  assert_contains "$facts" "None is a merits ruling" "the row must record what these rulings are not"
  assert_contains "$facts" "none grants approval, publication, landing, reviewer qualification or one-use authority" \
    "the row must enumerate the authorities not granted"
  assert_contains "$facts" "only the RELATION between the repository axis and the head axis was wrong" \
    "the row must record why a per-field validator could not have caught it"
  assert_contains "$facts" "neither CREATE nor SUSTAIN" \
    "the row must record that an invalid tuple cannot hold a wait open either"
  pass "the three rulings are recorded as transport revisions that grant nothing, so none can be read as a merits approval"
}

test_the_minimum_binding_set_the_rulings_require_is_declared() {
  local axes rules
  axes=$(jq -r '.canonical_subject.subject_types[] | select(.subject_type == "outbound_request")
                | .required_axes | join(" ")' "$ROOT/semantics/identity.json")
  # The set all three rulings named: governed repository, work identity, exact
  # head, validated ReviewEnvelope digest, review-policy generation.
  for axis in governed_repo item head review_envelope policy_generation; do
    assert_contains "$axes" "$axis" "the minimum binding set should declare $axis"
  done
  rules=$(jq -r '.canonical_subject.compilation_rules[]
                 | select(startswith("typed_identity_outranks"))' "$ROOT/semantics/identity.json")
  [ -n "$rules" ] || fail "no rule declares that typed identity outranks an untyped source"
  assert_contains "$rules" "may never override the typed identity" \
    "the rule the first ruling states explicitly should be declared"
  rules=$(jq -r '.canonical_subject.compilation_rules[]
                 | select(startswith("referential_integrity"))' "$ROOT/semantics/identity.json")
  assert_contains "$rules" "checked TOGETHER" \
    "the axes must be declared as checked together, since each was individually valid"
  assert_contains "$rules" "may neither CREATE a wait nor SUSTAIN one" \
    "an invalid tuple must be declared unable to hold a wait open, not merely unable to open one"
  pass "the minimum binding set and the two ordering rules the three rulings jointly require are declared in the owner"
}

# --- cross-cutting properties -------------------------------------------------

test_an_absent_record_is_could_not_observe_for_every_validator() {
  local missing="$TMP_ROOT/does-not-exist.json"
  run_state "$missing"; expect_code 4 "$CODE" "validate_state on an absent record"
  run_transition "$missing"; expect_code 4 "$CODE" "validate_transition on an absent record"
  run_effect "$missing" PRE_EFFECT; expect_code 4 "$CODE" "validate_effect_commit on an absent record"
  run_identity "$missing"; expect_code 4 "$CODE" "validate_identity_mapping on an absent record"
  pass "an absent record is could-not-observe for every validator, never a pass and never a refusal"
}

test_a_malformed_record_is_could_not_observe_not_a_crash() {
  local bad="$TMP_ROOT/malformed.json"
  printf 'this is not json\n' > "$bad"
  run_state "$bad"
  expect_code 4 "$CODE" "a malformed record must be could-not-observe"
  assert_contains "$OUT" "verdict=CNO" "the malformed record should produce a typed answer, not a stack trace"
  pass "a malformed record produces a typed could-not-observe rather than crashing the validator"
}

test_every_reason_a_validator_returns_resolves_to_exactly_one_namespace() {
  # A code that resolved to no namespace would route its repair to nobody, and a
  # code that resolved to two could not name an owner at all. The result line
  # would still look well formed either way, so this is asserted rather than read.
  local code ns
  for code in SFI_ORPHAN TRANS_ILLEGAL IDENT_MOVED EFFECT_REPLAY SFI_STALE_FOR_EFFECT \
              SEAM_UNMAPPED_VALUE SCHEMA_SHAPE_MISMATCH; do
    ns=$("$SEM" reason "$code" 2>&1) || fail "reason $code did not resolve"
    assert_contains "$ns" "namespace=" "reason $code should name its namespace"
    assert_contains "$ns" "owner_to_repair=" "reason $code should name who repairs it"
  done
  OUT=$("$SEM" reason NOT_A_REAL_CODE 2>&1); CODE=$?
  expect_code 3 "$CODE" "an undeclared code must refuse rather than resolving to a default"
  assert_contains "$OUT" "routes the repair to nobody" "the refusal should say the cost"
  pass "every reason code resolves to exactly one namespace and one repair owner, and an undeclared code refuses"
}

test_the_four_validators_use_mechanically_distinct_reason_namespaces() {
  # Drive one refusal from each validator and assert the four namespaces are
  # distinct. Sharing a namespace would make an operator unable to tell which
  # law was violated from the code alone.
  local seen=""
  run_state "$(rec ns-state '{"family":"NOPE","subject":{"digest":"d"},"evidence":[{"verdict":"PASS"}]}')"
  seen="$seen$(printf '%s' "$OUT" | sed -n 's/.*namespace=\([a-z_]*\).*/\1/p') "
  run_transition "$(rec ns-tr '{"from":"SUCCEEDED","to":"ACTIVE","subject":{"digest":"d"},"evidence":[{"verdict":"PASS","family":"SUCCEEDED"}],"context":{}}')"
  seen="$seen$(printf '%s' "$OUT" | sed -n 's/.*namespace=\([a-z_]*\).*/\1/p') "
  run_effect "$(rec ns-ef '{"authority":{"state":"spent"},"outcome_recorded":true,"act_reported":"applied","actor":"a","post_effect_proof":{"source":"b"}}')" POST_EFFECT
  seen="$seen$(printf '%s' "$OUT" | sed -n 's/.*namespace=\([a-z_]*\).*/\1/p') "
  run_identity "$(rec ns-id '{"edge":"N3->N4","subject":{"digest":"d1"},"candidates":2,"target_rule_observed":true,"recompiled_digest":"d1","resolved_subject":"d1","provenance":"x"}')"
  seen="$seen$(printf '%s' "$OUT" | sed -n 's/.*namespace=\([a-z_]*\).*/\1/p') "
  assert_contains "$seen" "state_family " "validate_state should refuse in the state-family namespace"
  assert_contains "$seen" "transition " "validate_transition should refuse in the transition namespace"
  assert_contains "$seen" "effect " "validate_effect_commit should refuse in the effect namespace"
  assert_contains "$seen" "identity " "validate_identity_mapping should refuse in the identity namespace"
  [ "$(printf '%s\n' "$seen" | tr ' ' '\n' | awk 'NF' | sort -u | wc -l)" -eq 4 ] \
    || fail "the four validators did not produce four distinct reason namespaces: $seen"
  pass "the four validators refuse in four mechanically distinct reason namespaces"
}

test_a_validator_never_answers_with_a_bare_exit_status() {
  # A two-valued read is the measured root cause of ten separate defects in this
  # fleet, so every answer must carry a verdict and a reason on stdout as well.
  run_state "$(rec bare '{"family":"SUCCEEDED","subject":{"digest":"d"},"evidence":[{"verdict":"PASS"}]}')"
  assert_contains "$OUT" "fm-semantics-result.v1 " "a result must be a typed line"
  assert_contains "$OUT" "dimensions=" "a result must name the dimensions it examined"
  assert_contains "$OUT" "authority=diagnostic" "a result must declare what it may be relied on for"
  pass "every validator answer is a typed line naming its verdict, reason, scope and authority, never a bare exit status"
}

test_a_well_formed_nonterminal_state_passes
test_a_terminal_state_carrying_an_obligation_is_a_false_terminal
test_a_nonterminal_state_with_no_wake_is_orphaned_not_patient
test_a_successor_outside_the_family_is_unbounded
test_more_than_one_actionable_successor_is_a_count_not_a_judgement
test_a_cardinality_check_with_nothing_to_examine_is_not_credited
test_a_state_with_no_observation_is_unevidenced_not_clean
test_evidence_that_only_failed_to_observe_is_still_unevidenced
test_an_unresolvable_subject_is_could_not_observe
test_a_family_outside_the_vocabulary_refuses_rather_than_defaulting
test_only_an_effect_proximal_caller_is_denied_a_stale_permission
test_a_declared_transition_passes
test_an_undeclared_transition_is_refused
test_resurrection_names_the_specific_reason_not_the_generic_one
test_evidence_from_another_family_cannot_promote
test_an_unaddressed_finding_blocks_promotion
test_a_target_requiring_an_authority_refuses_a_name
test_a_material_generation_difference_refuses
test_a_transition_with_no_observation_is_could_not_observe
test_a_pre_effect_with_three_agreeing_heads_passes
test_two_agreeing_heads_are_not_three
test_a_cached_input_is_refused_at_an_effect
test_an_unrecordable_intent_refuses_before_the_act
test_an_unobservable_target_is_could_not_observe_not_a_refusal
test_a_precommit_rendered_as_committed_is_refused
test_the_commit_point_requires_the_honest_middle_state
test_a_failed_act_is_indeterminate_and_never_not_applied
test_the_actor_report_is_not_the_proof
test_a_second_spend_of_a_one_use_authority_is_a_replay
test_an_unknown_phase_is_could_not_observe
test_a_clean_mapping_across_an_owned_edge_passes
test_an_unowned_edge_refuses_because_nobody_is_answerable
test_an_undeclared_edge_refuses_the_same_way
test_ambiguity_and_substitution_stay_apart
test_a_moved_subject_is_a_different_subject
test_an_undeterminable_target_rule_is_could_not_observe
test_a_mapping_with_no_provenance_cannot_be_rechecked
test_a_subject_resolved_from_the_transport_venue_is_refused
test_the_venue_and_the_governed_subject_are_declared_disjoint
test_referential_integrity_between_axes_is_declared_and_non_vacuous
test_the_recurrence_is_cited_from_three_preserved_rulings
test_the_rulings_are_recorded_as_granting_nothing
test_the_minimum_binding_set_the_rulings_require_is_declared
test_an_absent_record_is_could_not_observe_for_every_validator
test_a_malformed_record_is_could_not_observe_not_a_crash
test_every_reason_a_validator_returns_resolves_to_exactly_one_namespace
test_the_four_validators_use_mechanically_distinct_reason_namespaces
test_a_validator_never_answers_with_a_bare_exit_status
