#!/usr/bin/env bash
# Behavior tests for bin/fm-review-role.sh - the executable review control.
#
# THE POINT OF THIS FILE, which is not the usual point of a test file. The
# configuration this control replaces was rejected because an independent
# checker deleted each of its safety fields, and separately inverted each of
# them, and observed zero violations either way. A field that can be deleted or
# inverted without changing behaviour is documentation, not enforcement.
#
# So every case below is a PAIR, in this order:
#
#   1. the unmutated fixture must be ELIGIBLE - proving the control can say yes,
#      because a check that refuses everything is as useless as one that refuses
#      nothing and is much easier to write by accident;
#   2. the mutation is applied and the SAME check must go RED, naming the rule.
#
# A case that only asserts the red half would pass against a check that is
# broken shut. A case that only asserts the green half would pass against a
# check that is vacuous. Both halves, every time.
#
# Two bugs found while writing this file are why the pairing is not optional:
# a jq pipe rebinding "." made the policy reconciler test every claim against
# ITSELF and report a self-contradicting configuration as clean, and the same
# rebinding silently disabled the unknown-predicate check. Both read as a clean
# result rather than as a broken check.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RR="$ROOT/bin/fm-review-role.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-review-role) || fail "could not create fixture root"
ROLES="$TMP_ROOT/review-roles"
CONFIG="$TMP_ROOT/config"
STATE="$TMP_ROOT/state"
mkdir -p "$ROLES" "$CONFIG" "$STATE"

# The roles under test are COPIES of the tracked ones, so a mutation never
# touches the repository and every case starts from the shipped contract rather
# than from a fixture that has drifted away from it.
cp "$ROOT/review-roles/schema.json" "$ROLES/"
cp "$ROOT/review-roles/runtime-design-review.json" "$ROLES/"
cp "$ROOT/review-roles/runtime-change-review.json" "$ROLES/"

cat > "$CONFIG/models.json" <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "claude": {"access_class": "A", "cost_posture": "subscription-flat", "status": "active"},
    "openai-codex": {"access_class": "A", "cost_posture": "subscription-flat", "status": "active"}
  },
  "models": {
    "claude/opus": {"provider": "claude", "model_id": "opus", "harness": "claude",
      "cost_class": "subscription-flat", "status": "approved-primary",
      "limits": {"shared_quota_pool": "claude-max"}},
    "openai-codex/gpt-5.6-luna": {"provider": "openai-codex", "model_id": "gpt-5.6-luna",
      "harness": "pi", "cost_class": "subscription-flat", "status": "approved-primary",
      "limits": {"shared_quota_pool": "openai-codex-oauth"}}
  }
}
JSON

export FM_REVIEW_ROLES_OVERRIDE=$ROLES
export FM_CONFIG_OVERRIDE=$CONFIG
export FM_STATE_OVERRIDE=$STATE

DESIGN=$ROLES/runtime-design-review.json

# The assignment every case starts from: a qualified reviewer, a different
# maker, an enforced-read-only harness. It must be ELIGIBLE, or no mutation
# below proves anything.
check_baseline() {
  "$RR" check --role runtime-design-review \
    --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
    --maker claude/opus --maker-process task-maker --reviewer-process task-review \
    --reviewed-head design-spec-v1 "$@" 2>&1
}

# mutate <jq-program>: rewrite the design role in place.
mutate() {
  local tmp
  tmp=$(mktemp "$DESIGN.XXXXXX") || fail "mktemp failed"
  jq "$1" "$DESIGN" > "$tmp" || fail "mutation failed: $1"
  mv -f "$tmp" "$DESIGN"
}

restore() { cp "$ROOT/review-roles/runtime-design-review.json" "$DESIGN"; }

# green_then_red <label> <jq-mutation> <expected-token>
# The whole contract of this file in one helper: assert the control says yes on
# the shipped contract, apply the mutation, assert the SAME check goes red and
# names the rule.
green_then_red() {
  local label=$1 mutation=$2 token=$3 out rc
  restore
  out=$(check_baseline); rc=$?
  expect_code 0 "$rc" "$label: baseline must be ELIGIBLE before the mutation, or the red half proves nothing"
  assert_contains "$out" "ELIGIBLE" "$label: baseline must be ELIGIBLE"

  mutate "$mutation"
  out=$(check_baseline); rc=$?
  [ "$rc" != 0 ] || fail "$label: the control stayed GREEN after its protection was removed, which proves nothing"
  assert_contains "$out" "$token" "$label: the refusal must name the rule that fired"
  restore
  pass "$label"
}

# --- 1. the read-only requirement: delete it, and invert it ------------------

green_then_red "read-only requirement DELETED goes red" \
  'del(.predicates.mutation_authority)' \
  'predicate_missing'

green_then_red "read-only requirement INVERTED goes red" \
  '.predicates.mutation_authority = "permitted"' \
  'mutation_authority_not_forbidden'

# The inversion must also change what the control DOES, not merely what it
# says: with mutation forbidden the assignment carries an enforced read-only
# launch binding, and that binding is the thing the field selects.
restore
out=$(check_baseline --json)
mech=$(printf '%s' "$out" | jq -r '.readonly_mechanism')
flags=$(printf '%s' "$out" | jq -r '.readonly_flags')
[ "$mech" = allowlist ] || fail "an eligible read-only assignment must carry the measured launch mechanism, not just the claim (got: $mech)"
[ "$flags" = "--tools read,grep,find,ls" ] || fail "the assignment must carry the exact measured read-only flags (got: $flags)"
pass "an eligible read-only assignment carries the measured launch binding"

# --- 2. read-only must be ENFORCED AT LAUNCH, not instructed -----------------
#
# A harness this repo has not MEASURED refusing a write may not host a read-only
# role. This is the case that separates an enforced binding from a brief that
# asks nicely.
restore
out=$("$RR" check --role runtime-design-review \
  --reviewer openai-codex/gpt-5.6-luna --harness grok --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 1 "$rc" "a harness with no measured read-only binding must be refused"
assert_contains "$out" "FM_REVIEW_NO_READONLY_BINDING" \
  "the refusal must name the missing read-only binding"

# Every harness the launch library can launch reports a posture, and a harness
# nobody measured reports unknown rather than silently passing.
out=$("$RR" harness-readonly 2>&1)
assert_contains "$out" "pi enforced allowlist" "pi has a measured allowlist binding"
assert_contains "$out" "pi-signed unknown" "pi-signed stays unknown until its exact executable is measured"
assert_contains "$out" "codex enforced sandbox" "codex has a measured sandbox binding"
assert_contains "$out" "claude enforced denylist" "claude has a measured denylist binding"
assert_contains "$out" "grok unknown" "an unmeasured harness must report unknown, never enforced"
pass "read-only enforcement is per-harness and unmeasured harnesses report unknown"

# --- 3. self-review is mechanically refused ---------------------------------

restore
out=$("$RR" check --role runtime-design-review \
  --reviewer claude/opus --harness pi --effort xhigh \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 1 "$rc" "assigning the author as its own reviewer must be refused"
assert_contains "$out" "FM_REVIEW_SELF_REVIEW_REFUSED" "the refusal must name self-review"

# The same binding is NOT intrinsically ineligible - independence is
# assignment-relative. Opus reviewing Luna-made work is eligible, and a control
# that refused it would be enforcing a model property instead.
out=$("$RR" check --role runtime-design-review \
  --reviewer claude/opus --harness pi --effort xhigh \
  --maker openai-codex/gpt-5.6-luna --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 0 "$rc" "independence is assignment-relative: the same binding must be eligible against a different maker"
pass "self-review refused while the same binding stays eligible elsewhere"

# --- 4. author identity removed fails CLOSED --------------------------------

out=$("$RR" check --role runtime-design-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --reviewer-process task-review --reviewed-head design-spec-v1 2>&1); rc=$?
[ "$rc" != 0 ] || fail "an assignment with no author identity must not be eligible"
assert_contains "$out" "FM_REVIEW_MAKER_IDENTITY_MISSING" \
  "the refusal must name the missing author identity"

# Independence must not be satisfiable by a name comparison alone. With the
# model registry removed, two DIFFERENT names are no longer evidence of two
# models, and the required dimension becomes could-not-observe - which refuses.
mv "$CONFIG/models.json" "$CONFIG/models.json.away"
out=$(check_baseline); rc=$?
[ "$rc" != 0 ] || fail "with no declared model identities, independence must be could-not-observe and refuse"
assert_contains "$out" "independence_unobserved" \
  "an unobservable required dimension must refuse rather than pass on name inequality"
mv "$CONFIG/models.json.away" "$CONFIG/models.json"
pass "author identity and undeclared identity both fail closed"

# --- 5. a reviewer below the capability floor ------------------------------

green_then_red "a binding removed from the role is no longer qualified" \
  '.qualified_bindings = [.qualified_bindings[] | select(.binding != "openai-codex/gpt-5.6-luna")]' \
  'FM_REVIEW_BINDING_NOT_QUALIFIED'

green_then_red "an effort other than the one qualified for this binding goes red" \
  '(.qualified_bindings[] | select(.binding == "openai-codex/gpt-5.6-luna") | .effort) = "high"' \
  'effort_not_qualified_for_binding'

restore
out=$("$RR" check --role runtime-design-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 1 "$rc" "omitting a binding-specific reviewer effort must go red"
assert_contains "$out" "effort_not_qualified_for_binding" \
  "the missing-effort refusal must name the binding-specific capability rule"
pass "omitting reviewer effort fails closed"

codex_reviewer_template=$(
  # shellcheck source=bin/fm-launch-lib.sh
  . "$ROOT/bin/fm-launch-lib.sh"
  launch_template codex reviewer
)
codex_reviewer_model_flags='--model test-reviewer --sandbox read-only --skip-git-repo-check '
codex_reviewer_effort_flags='-c model_reasoning_effort=\"max\" '
codex_reviewer_command=${codex_reviewer_template//__MODELFLAG__/$codex_reviewer_model_flags}
codex_reviewer_command=${codex_reviewer_command//__EFFORTFLAG__/$codex_reviewer_effort_flags}
assert_contains "$codex_reviewer_command" '--sandbox read-only' \
  "the exact composed Codex reviewer command must carry the read-only sandbox"
case "$codex_reviewer_command" in
  *--dangerously-bypass-approvals-and-sandbox*)
    fail "the exact composed Codex reviewer command retained the sandbox bypass"
    ;;
esac
pass "the exact composed Codex reviewer command is read-only without a bypass"

# --- 6. a required reviewer predicate removed ------------------------------
#
# Run over EVERY required predicate rather than a sampled one: a loop that
# checked one predicate would leave the other seventeen able to vanish silently,
# which is the defect being repaired, one predicate over.
restore
n_pred=$(jq -r '.required_predicates | length' "$ROLES/schema.json")
[ "$n_pred" -ge 18 ] || fail "the role contract should carry at least 18 required predicates, found $n_pred"
while IFS= read -r pred; do
  [ -n "$pred" ] || continue
  restore
  mutate "del(.predicates[\"$pred\"])"
  out=$(check_baseline); rc=$?
  [ "$rc" != 0 ] || fail "deleting required predicate '$pred' left the control GREEN"
  assert_contains "$out" "predicate_missing" "deleting '$pred' must name predicate_missing"
  assert_contains "$out" "$pred" "the refusal must name the predicate that went missing: $pred"
done <<EOF
$(jq -r '.required_predicates[]' "$ROLES/schema.json")
EOF
restore
pass "every one of the $n_pred required predicates goes red when deleted"

# A predicate whose value falls outside its closed vocabulary is refused BY
# NAME, not skipped. A misspelling is the likeliest way a floor ever reaches
# this code, and an axis that silently enforces nothing for it is an axis an
# operator believes is armed.
green_then_red "a predicate value outside its vocabulary goes red" \
  '.predicates.tool_loop = "verified_read_only_evidence_acquisition"' \
  'predicate_value_unknown'

green_then_red "a predicate the contract does not define goes red" \
  '.predicates.coding = "not-required"' \
  'predicate_unknown'

# --- 6b. transcription fidelity --------------------------------------------
#
# A DIFFERENT control from the ones above, guarding a different failure. Those
# catch a role file that breaks its own schema. This one catches a role file
# that stays schema-valid while quietly saying something weaker than the source
# it claims to transcribe - which is exactly what the rejected configuration
# did, and no schema could have caught it, because "not-required" is a perfectly
# valid value for a predicate that must nevertheless be "expert" here.
#
# The values below are the two transcription defects the independent checker
# found, pinned so they cannot return, plus the two the same finding implicates.
# Read through the command rather than off the file, so it is the published
# contract under test.
transcription_drift() {  # <role> -> one line per drifted predicate
  local role=$1 shown
  shown=$("$RR" show "$role" 2>/dev/null) || { echo "$role: not readable"; return 0; }
  printf '%s' "$shown" | jq -r '
    .predicates as $p
    | [ (if $p.implementation_comprehension != "expert"
         then "implementation_comprehension must stay expert: writing no code does not imply needing no expert comprehension of code"
         else empty end),
        (if $p.patch_generation != "not-required"
         then "patch_generation must stay not-required and DISTINCT from implementation_comprehension; collapsing the two is the defect"
         else empty end),
        (if $p.context != "fitted-to-artifact"
         then "context must stay fitted-to-artifact; a fixed ceiling was invented where the source required capacity fitted to the actual artifact"
         else empty end),
        (if $p.tool_loop != "verified-read-only-evidence-acquisition"
         then "tool_loop must stay verified-read-only-evidence-acquisition; required is weaker than the source contract and admits an unprobed model"
         else empty end),
        (if $p.mutation_authority != "forbidden"
         then "mutation_authority must stay forbidden" else empty end) ]
    | .[]'
}

for r in runtime-design-review runtime-change-review; do
  drift=$(transcription_drift "$r")
  [ -z "$drift" ] || fail "$r has drifted from its transcribed source:"$'\n'"$drift"
done

# The negative control: the same reader must REPORT drift when it is present,
# or the clean result above is vacuous.
mutate '.predicates.implementation_comprehension = "not-required"'
drift=$(transcription_drift runtime-design-review)
assert_contains "$drift" "implementation_comprehension must stay expert" \
  "the drift reader must fire when expert implementation comprehension is weakened"
restore
mutate '.predicates.context = "fixed-ceiling"'
drift=$(transcription_drift runtime-design-review)
assert_contains "$drift" "context must stay fitted-to-artifact" \
  "the drift reader must fire when a fixed context ceiling is invented"
restore
mutate '.predicates.tool_loop = "required"'
drift=$(transcription_drift runtime-design-review)
assert_contains "$drift" "tool_loop must stay verified-read-only" \
  "the drift reader must fire when the verified read-only evidence loop is weakened to required"
restore
pass "both roles match their transcribed source, and the drift reader fires when they do not"

# --- 7. a required independence dimension removed --------------------------

green_then_red "removing a required independence dimension goes red" \
  'del(.independence.model)' \
  'independence_dimension_missing'

green_then_red "inverting a required independence dimension is visible" \
  '.independence.model = "self-review-allowed"' \
  'independence_requirement_unknown'

# Downgrading model independence from required to reported must change the
# VERDICT of a self-review, not merely the wording - otherwise the requirement
# is decorative exactly as before.
restore
mutate '.independence.model = "reported"'
out=$("$RR" check --role runtime-design-review \
  --reviewer claude/opus --harness pi --effort xhigh \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 0 "$rc" "with model independence downgraded to reported, self-review is admitted - which is what makes the required setting load-bearing"
restore
out=$("$RR" check --role runtime-design-review \
  --reviewer claude/opus --harness pi --effort xhigh \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head design-spec-v1 2>&1); rc=$?
expect_code 1 "$rc" "restored to required, the same self-review must be refused"
pass "the independence requirement changes the verdict, so it is enforcement rather than prose"

# --- 8. contradictory policy claims ----------------------------------------
#
# One file that simultaneously authorises and forbids a membership has no single
# answer. The pair here is a config WITHOUT the contradiction (must reconcile)
# and the same config WITH it (must go red), so the detector is proven to
# discriminate rather than to always-fire or always-pass.
write_dispatch() {  # <extra-route-json-or-empty>
  local extra=${1:-}
  cat > "$CONFIG/crew-dispatch.json" <<JSON
{
  "rules": [
    {"route": "R3-MAX", "floor": "F-IMPL-MAX",
     "pool": ["openai-codex/gpt-5.6-luna"],
     "why": "This is the ONLY route whose pool may contain gpt-5.6-luna; it belongs to R3-MAX alone."}
    $extra
  ],
  "_floors": {"F-IMPL-MAX": {}, "F-RUNTIME-REVIEW": {}}
}
JSON
}

write_dispatch ""
out=$("$RR" reconcile 2>&1); rc=$?
expect_code 0 "$rc" "a config whose membership matches its own exclusivity claim must reconcile"
assert_contains "$out" "reconciled" "the clean config must report reconciled"

write_dispatch ',{"route": "R1-RUNTIME-REVIEW", "floor": "F-RUNTIME-REVIEW", "pool": ["openai-codex/gpt-5.6-luna"]}'
out=$("$RR" reconcile 2>&1); rc=$?
expect_code 1 "$rc" "a config claiming a model exclusive to one route while pooling it in two must go red"
assert_contains "$out" "FM_REVIEW_POLICY_CONTRADICTION" "the refusal must name the contradiction"
assert_contains "$out" "R1-RUNTIME-REVIEW" "the refusal must name the membership the claim denies"

# And the contradiction must reach the ASSIGNMENT decision, not only the
# standalone report: an eligible verdict that ignores a self-contradicting
# policy is quoting the clause that agrees.
out=$(check_baseline); rc=$?
[ "$rc" != 0 ] || fail "an assignment must not be eligible while the policy contradicts itself about the reviewer"
assert_contains "$out" "FM_REVIEW_POLICY_CONTRADICTION" "the assignment refusal must name the contradiction"
rm -f "$CONFIG/crew-dispatch.json"
pass "contradictory policy claims are a deterministic reconciliation failure"

# --- 9. the role registry itself -------------------------------------------

restore
out=$("$RR" list 2>&1)
assert_contains "$out" "runtime-design-review" "the design role must be registered"
assert_contains "$out" "runtime-change-review" "the change role must be registered"

# Design and change are separate contracts and neither discharges the other.
for r in runtime-design-review runtime-change-review; do
  other=$("$RR" show "$r" | jq -r '.does_not_discharge')
  [ -n "$other" ] || fail "$r must say which obligation it does not discharge"
done
a1=$("$RR" show runtime-design-review | jq -r '.activity')
a2=$("$RR" show runtime-change-review | jq -r '.activity')
[ "$a1" != "$a2" ] || fail "the design and change roles must not share one activity"

CHANGE=$ROLES/runtime-change-review.json
tmp=$(mktemp "$CHANGE.XXXXXX") || fail "mktemp failed"
jq 'del(.requires_pinned_head)' "$CHANGE" > "$tmp" || fail "change role mutation failed"
mv -f "$tmp" "$CHANGE"
out=$("$RR" show runtime-change-review 2>&1); rc=$?
expect_code 2 "$rc" "a change role missing its pinned-head requirement must be inadmissible"
assert_contains "$out" "pinned_head_requirement_missing" "the missing pinned-head control must be named"
cp "$ROOT/review-roles/runtime-change-review.json" "$CHANGE"

tmp=$(mktemp "$DESIGN.XXXXXX") || fail "mktemp failed"
jq '.id = "runtime-change-review"' "$DESIGN" > "$tmp" || fail "role id mutation failed"
mv -f "$tmp" "$DESIGN"
out=$("$RR" show runtime-design-review 2>&1); rc=$?
expect_code 2 "$rc" "a role whose id does not match its file must be inadmissible"
assert_contains "$out" "role_id_mismatch" "the mismatched role identity must be named"
restore

out=$("$RR" show ../runtime-design-review 2>&1); rc=$?
expect_code 2 "$rc" "a role id containing path components must be unevaluable"
assert_contains "$out" "role ids must be" "the invalid role id must explain the slug contract"

# A change review must be pinned to the head it read.
out=$("$RR" check --role runtime-design-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review 2>&1); rc=$?
expect_code 1 "$rc" "a design review with no target identifier must be refused"
assert_contains "$out" "review_target_unidentified" "the design refusal must name the missing target"

out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review 2>&1); rc=$?
expect_code 1 "$rc" "a change review with no pinned head must be refused"
assert_contains "$out" "review_target_unidentified" "the refusal must name the missing target"

HEAD_REPO="$TMP_ROOT/candidate"
mkdir -p "$HEAD_REPO"
git -C "$HEAD_REPO" init -q
git -C "$HEAD_REPO" config user.name test
git -C "$HEAD_REPO" config user.email test@example.invalid
printf 'candidate\n' > "$HEAD_REPO/file"
git -C "$HEAD_REPO" add file
git -C "$HEAD_REPO" commit -qm candidate
EXPECTED_HEAD=$(git -C "$HEAD_REPO" rev-parse HEAD)

out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head "$EXPECTED_HEAD" --candidate-worktree "$HEAD_REPO" 2>&1); rc=$?
expect_code 0 "$rc" "a change review pinned to a head must be eligible"

out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head unknown --candidate-worktree "$HEAD_REPO" 2>&1); rc=$?
expect_code 1 "$rc" "a non-commit reviewed head must be refused"
assert_contains "$out" "reviewed_head_invalid" "the malformed head must be named"

out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head 6f6eb8a359b5a8258d8f1cbb899aba1e590535ca \
  --candidate-worktree "$HEAD_REPO" 2>&1); rc=$?
expect_code 1 "$rc" "a reviewed head other than the candidate head must be refused"
assert_contains "$out" "reviewed_head_mismatch" "the wrong head must be named"

printf 'dirty\n' >> "$HEAD_REPO/file"
out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head "$EXPECTED_HEAD" --candidate-worktree "$HEAD_REPO" 2>&1); rc=$?
expect_code 1 "$rc" "tracked candidate changes beyond the reviewed head must be refused"
assert_contains "$out" "candidate_worktree_dirty" "the dirty candidate must be named"
git -C "$HEAD_REPO" restore file
printf 'untracked\n' > "$HEAD_REPO/untracked"
out=$("$RR" check --role runtime-change-review \
  --reviewer openai-codex/gpt-5.6-luna --harness pi --effort max \
  --maker claude/opus --maker-process task-maker --reviewer-process task-review \
  --reviewed-head "$EXPECTED_HEAD" --candidate-worktree "$HEAD_REPO" 2>&1); rc=$?
expect_code 1 "$rc" "untracked candidate bytes beyond the reviewed head must be refused"
assert_contains "$out" "candidate_worktree_dirty" "untracked candidate bytes must be named"
pass "design and change are separate contracts and the change role requires a pinned head"

printf '{broken\n' > "$CONFIG/crew-dispatch.json"
out=$(check_baseline); rc=$?
expect_code 2 "$rc" "an unreadable routing policy must make assignment evaluation unevaluable"
assert_contains "$out" "could not be parsed" "the unreadable policy must not become an empty contradiction set"
rm -f "$CONFIG/crew-dispatch.json"

# An unknown role and an unreadable registry are could-not-observe (exit 2),
# never an absent obligation (exit 0). This is the distinction the whole control
# rests on: nothing to check must never read as nothing to enforce.
out=$("$RR" check --role no-such-role --reviewer openai-codex/gpt-5.6-luna --harness pi 2>&1); rc=$?
expect_code 2 "$rc" "an unknown role must be unevaluable, never eligible"
assert_contains "$out" "FM_REVIEW_ROLE_UNKNOWN" "the refusal must name the unknown role"

restore
mutate 'del(.qualified_bindings)'
out=$(check_baseline); rc=$?
expect_code 2 "$rc" "a role that does not satisfy its own schema must be unevaluable, never eligible"
assert_contains "$out" "FM_REVIEW_ROLE_INADMISSIBLE" "an inadmissible role must be named as such"
restore
pass "an unknown or inadmissible role is could-not-observe, never a silent pass"

# --- 10. the chokepoint ------------------------------------------------------
#
# A check nothing calls is not enforcement, so the last cases drive
# bin/fm-spawn.sh itself. Every case here is a REFUSAL, which happens before any
# worktree, endpoint or metadata exists, and the home's fake backend exits
# non-zero so a case that wrongly got past the gate fails loudly instead of
# leaving a worker behind.
SPAWN="$ROOT/bin/fm-spawn.sh"
SPAWN_HOME="$TMP_ROOT/spawn/home"
SPAWN_BIN="$TMP_ROOT/spawn/fakebin"
mkdir -p "$SPAWN_HOME/data" "$SPAWN_HOME/state" "$SPAWN_HOME/config" \
         "$SPAWN_HOME/projects/proj" "$SPAWN_BIN"
printf '#!/bin/sh\nexit 1\n' > "$SPAWN_BIN/tmux"
chmod +x "$SPAWN_BIN/tmux"
fm_fake_treehouse "$SPAWN_BIN"
cp "$CONFIG/models.json" "$SPAWN_HOME/config/models.json"
git -C "$SPAWN_HOME/projects/proj" init -q
git -C "$SPAWN_HOME/projects/proj" config user.name test
git -C "$SPAWN_HOME/projects/proj" config user.email test@example.invalid
printf 'candidate\n' > "$SPAWN_HOME/projects/proj/file"
git -C "$SPAWN_HOME/projects/proj" add file
git -C "$SPAWN_HOME/projects/proj" commit -qm candidate

write_spawn_brief() {  # <id>
  mkdir -p "$SPAWN_HOME/data/$1"
  printf 'You are a crewmate.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
    > "$SPAWN_HOME/data/$1/brief.md"
}

run_spawn() {  # <args...>
  FM_ROOT_OVERRIDE='' FM_HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$SPAWN_HOME/state" FM_DATA_OVERRIDE="$SPAWN_HOME/data" \
    FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects" FM_CONFIG_OVERRIDE="$SPAWN_HOME/config" \
    FM_REVIEW_ROLES_OVERRIDE="$ROLES" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' PATH="$SPAWN_BIN:$PATH" \
    "$SPAWN" "$@" 2>&1
}

write_spawn_brief review-self
out=$(run_spawn review-self "$SPAWN_HOME/projects/proj" --scout --reason-code SEMANTIC_REVIEW \
  --harness pi --model claude/opus --effort xhigh \
  --review-role runtime-design-review --maker claude/opus --maker-process task-maker --reviewed-head design-spec-v1); rc=$?
[ "$rc" != 0 ] || fail "the spawn chokepoint admitted a self-review"
assert_contains "$out" "FM_REVIEW_SELF_REVIEW_REFUSED" "the spawn refusal must name self-review"
assert_absent "$SPAWN_HOME/state/review-self.meta" "a refused review spawn must leave no metadata behind"

write_spawn_brief review-nomaker
out=$(run_spawn review-nomaker "$SPAWN_HOME/projects/proj" --scout --reason-code SEMANTIC_REVIEW \
  --harness pi --model openai-codex/gpt-5.6-luna --effort max \
  --review-role runtime-design-review --reviewed-head design-spec-v1); rc=$?
[ "$rc" != 0 ] || fail "the spawn chokepoint admitted a review with no author identity"
assert_contains "$out" "FM_REVIEW_MAKER_IDENTITY_MISSING" "the spawn refusal must name the missing author"
assert_absent "$SPAWN_HOME/state/review-nomaker.meta" "a refused review spawn must leave no metadata behind"

write_spawn_brief review-badharness
out=$(run_spawn review-badharness "$SPAWN_HOME/projects/proj" --scout --reason-code SEMANTIC_REVIEW \
  --harness grok --model openai-codex/gpt-5.6-luna --effort max \
  --review-role runtime-design-review --maker claude/opus --maker-process task-maker --reviewed-head design-spec-v1); rc=$?
[ "$rc" != 0 ] || fail "the spawn chokepoint admitted a review on a harness with no measured read-only binding"
assert_contains "$out" "FM_REVIEW_NO_READONLY_BINDING" "the spawn refusal must name the missing read-only binding"

write_spawn_brief review-unknownrole
out=$(run_spawn review-unknownrole "$SPAWN_HOME/projects/proj" --scout --reason-code SEMANTIC_REVIEW \
  --harness pi --model openai-codex/gpt-5.6-luna --effort max \
  --review-role no-such-role --maker claude/opus); rc=$?
[ "$rc" != 0 ] || fail "the spawn chokepoint admitted a claim against a role that does not exist"
assert_contains "$out" "FM_REVIEW_ROLE_UNKNOWN" "an unknown role must refuse at the chokepoint, never pass unchecked"

write_spawn_brief review-shorthand
out=$(cd "$TMP_ROOT" && run_spawn review-shorthand projects/proj --scout --reason-code SEMANTIC_REVIEW \
  --harness pi --model openai-codex/gpt-5.6-luna --effort max \
  --review-role runtime-change-review --maker claude/opus --maker-process task-maker \
  --reviewed-head "$(git -C "$SPAWN_HOME/projects/proj" rev-parse HEAD)"); rc=$?
[ "$rc" != 0 ] || fail "the fake backend unexpectedly launched a shorthand review spawn"
assert_not_contains "$out" "no readable git HEAD" "project shorthand must resolve before reviewed-head verification"

printf 'next\n' >> "$SPAWN_HOME/projects/proj/file"
git -C "$SPAWN_HOME/projects/proj" commit -qam next
REVIEW_HEAD=$(git -C "$SPAWN_HOME/projects/proj" rev-parse HEAD)
PREVIOUS_HEAD=$(git -C "$SPAWN_HOME/projects/proj" rev-parse HEAD^)
write_spawn_brief review-wrong-slot
out=$(run_spawn review-wrong-slot "$SPAWN_HOME/projects/proj" --scout --reason-code SEMANTIC_REVIEW \
  --harness pi --model openai-codex/gpt-5.6-luna --effort max \
  --review-role runtime-change-review --maker claude/opus --maker-process task-maker \
  --reviewed-head "$REVIEW_HEAD" --slot-base "$PREVIOUS_HEAD"); rc=$?
[ "$rc" != 0 ] || fail "a change review admitted a reviewer slot based on different bytes"
assert_contains "$out" "requires reviewer slot base $REVIEW_HEAD" "change review must bind slot placement to its reviewed head"

# A secondmate provisions a standing home and discharges no review obligation,
# so the claim is refused rather than silently recorded.
out=$(run_spawn review-sm "$SPAWN_HOME/projects/proj" --secondmate --review-role runtime-design-review 2>&1); rc=$?
[ "$rc" != 0 ] || fail "a secondmate spawn must not accept a review-role claim"
assert_contains "$out" "review-role applies to ship and scout" "the secondmate refusal must say why"
pass "the spawn chokepoint refuses self-review, a missing author, an unenforceable harness and an unknown role"

# --- 9. the launch outcome must be CONSUMED, never inferred -----------------
#
# check answers "may this assignment be made". Passing it is an INTENTION, and
# the defect this section closes is that the intention was the only durable
# record: state/<id>.meta carried review_role= written at dispatch and nothing
# ever read it again.
#
#   A process invocation is not proof that the intended agent role started.
#   Absence of mutation is not proof that read-only enforcement worked if the
#   reviewer never successfully started.
#
# A reviewer that never started and a reviewer that started and lawfully refused
# to write look almost identical from outside: no writes, a quiet endpoint, a
# plausible terminal state. So every case here mutates a COMPLETE, satisfied
# record and requires the proof to collapse.

SCHEMA_COPY=$ROLES/schema.json
restore_schema() { cp "$ROOT/review-roles/schema.json" "$SCHEMA_COPY"; }

write_assignment_record() {  # <id>
  {
    echo "model=openai-codex/gpt-5.6-luna"
    echo "review_role=runtime-design-review"
    echo "review_maker=claude/opus"
    echo "review_readonly_mechanism=allowlist"
    echo "review_readonly_flags=--tools read,grep,find,ls"
    echo "reviewed_head=design-spec-v1"
    echo "review_launch=launch_succeeded_as_requested"
  } > "$STATE/$1.meta"
  printf 'fm-status-event.v1 verb=working key=review-opening phase=runtime-design-review evidence=design-spec-v1 summary=review role and target established\n' > "$STATE/$1.status"
  printf 'fm-status-event.v1 verb=done key=review-verdict phase=PASS evidence=design-spec-v1 summary=review passed\n' >> "$STATE/$1.status"
}

assignment_out() { "$RR" assignment --task rev-proof 2>&1; }

# strip_meta <key>: remove one recorded fact from an otherwise complete record.
strip_meta() { grep -v "^$1=" "$STATE/rev-proof.meta" > "$STATE/rev-proof.meta.tmp" \
  && mv -f "$STATE/rev-proof.meta.tmp" "$STATE/rev-proof.meta"; }

# The green half, asserted once here and re-asserted inside every pair below: a
# complete record must PROVE the review, or no mutation proves anything.
write_assignment_record rev-proof
out=$(assignment_out); rc=$?
expect_code 0 "$rc" "a complete review record must prove the assignment, or every red half below is vacuous"
assert_contains "$out" "SATISFIED" "the complete record must report the requirement satisfied"
assert_contains "$out" "review-assignment:rev-proof,PASS," "the answer must be a fm-verify-lib result record so it is read through fm_verify_case"
pass "a complete review record proves the assignment"

# proof_collapses <label> <mutator> <token> <expected-exit>
proof_collapses() {
  local label=$1 mutator=$2 token=$3 want=$4 out rc
  restore_schema
  write_assignment_record rev-proof
  out=$(assignment_out); rc=$?
  expect_code 0 "$rc" "$label: the unmutated record must be SATISFIED first"

  declare -F "$mutator" >/dev/null 2>&1 \
    || fail "$label: mutator $mutator is not a defined function, so nothing would have been mutated and the case would pass for the wrong reason"
  "$mutator" || fail "$label: the mutation itself failed, so the red half would not be measuring what it claims"
  out=$(assignment_out); rc=$?
  [ "$rc" != 0 ] || fail "$label: the proof stayed SATISFIED after its evidence was removed, which proves nothing"
  expect_code "$want" "$rc" "$label: the collapse must be reported as the right kind of result"
  assert_contains "$out" "UNSATISFIED" "$label: the review requirement must read UNSATISFIED, never waived or downgraded"
  assert_contains "$out" "$token" "$label: the answer must name what was not established"
  restore_schema
  pass "$label"
}

# Each mutation is a FUNCTION rather than a string handed to eval: the mutators
# manipulate the fixture, and a fixture step that silently failed to apply would
# leave the record intact and the case would pass for the wrong reason.
set_launch() { grep -v "^review_launch=" "$STATE/rev-proof.meta" > "$STATE/rev-proof.meta.k" \
  && { cat "$STATE/rev-proof.meta.k"; echo "review_launch=$1"; } > "$STATE/rev-proof.meta"; }

mut_no_launch() { strip_meta review_launch; }
mut_launch_failed() { set_launch launch_failed; }
mut_role_not_established() { set_launch role_not_established; }
mut_no_binding() { strip_meta model; }
mut_no_mechanism() { strip_meta review_readonly_mechanism; }
mut_no_flags() { strip_meta review_readonly_flags; }
mut_no_verdict() { sed -i '/key=review-verdict/d' "$STATE/rev-proof.status"; }
mut_done_without_verdict() { sed -i 's/key=review-verdict phase=PASS/key=review-finished phase=review/' "$STATE/rev-proof.status"; }
mut_negative_verdict() { sed -i 's/key=review-verdict phase=PASS/key=review-verdict phase=FAIL/' "$STATE/rev-proof.status"; }
mut_wrong_opening_target() { sed -i 's/key=review-opening phase=runtime-design-review evidence=design-spec-v1/key=review-opening phase=runtime-design-review evidence=other-spec/' "$STATE/rev-proof.status"; }
mut_change_role() { sed -i "s/^review_role=.*/review_role=runtime-change-review/" "$STATE/rev-proof.meta"; }
mut_invert_success() {
  jq '(.launch_outcomes.outcomes[] | select(.name == "launch_succeeded_as_requested") | .result) = "FAIL"' \
    "$SCHEMA_COPY" > "$SCHEMA_COPY.t" && mv -f "$SCHEMA_COPY.t" "$SCHEMA_COPY"
}

# THE DEFECT ITSELF: a record that never consumed a launch outcome. This is a
# review concluded from a spawn having been attempted.
proof_collapses "a record with no launch outcome cannot prove a review" \
  mut_no_launch 'FM_REVIEW_LAUNCH_OUTCOME_NOT_CONSUMED' 2

# THE MEASURED MISORDERED-LAUNCH SHAPE. The probe in
# docs/verification/read-only-reviewer-launch.md recorded a claude launch whose
# flags were ordered so the brief was swallowed: it exits 1, writes nothing, and
# leaves an endpoint that looks exactly like an enforced read-only reviewer that
# found nothing to change. A caller that does not inspect the launch result
# would count it as a valid review; this must refuse it as an observed failure,
# not as could-not-observe and not as a pass.
proof_collapses "a launch that failed is never counted as a review" \
  mut_launch_failed 'the reviewer did not run' 1

# A live agent that never took its instructions: alive, and reviewing nothing.
proof_collapses "a live agent that never took the role is never counted as a review" \
  mut_role_not_established 'the reviewer did not run' 1

# Each remaining required fact, removed one at a time. Six established facts and
# one missing fact is could-not-observe, never a pass.
proof_collapses "an unknown reviewing binding cannot prove a review" \
  mut_no_binding 'intended_binding' 2
proof_collapses "a review with no enforced read-only binding cannot prove itself" \
  mut_no_mechanism 'readonly_authority_active' 2
proof_collapses "recording a mechanism without the flags that carried it cannot prove a review" \
  mut_no_flags 'readonly_authority_active' 2
proof_collapses "a review that never reached a verdict is not a completed review" \
  mut_no_verdict 'review_result' 2
proof_collapses "a done lifecycle event without a reviewer verdict proves no result" \
  mut_done_without_verdict 'review_result' 2
proof_collapses "a reviewer-authored negative verdict is observed bad" \
  mut_negative_verdict 'negative verdict' 1
proof_collapses "an opening event for another target does not establish the role" \
  mut_wrong_opening_target 'role_established' 2

# A change role additionally requires the exact reviewed commit.
proof_collapses "a change review with no pinned head cannot prove which bytes were read" \
  mut_change_role 'review_target_commit' 2

# --- 10. the outcome vocabulary is read from the contract, not hardcoded -----
#
# If the names below were written into the script, deleting or inverting them in
# the contract would change nothing - documentation, not enforcement.

proof_collapses "inverting the success outcome in the contract changes the verdict" \
  mut_invert_success 'the reviewer did not run' 1

# The name and the result must AGREE. Reading the result from the contract alone
# would let a contract relabel some other outcome a pass and smuggle it through
# as an established review, so only one named outcome establishes the role.
mut_relabel_other_outcome_pass() {
  jq '(.launch_outcomes.outcomes[] | select(.name == "role_not_established") | .result) = "PASS"' \
    "$SCHEMA_COPY" > "$SCHEMA_COPY.t" && mv -f "$SCHEMA_COPY.t" "$SCHEMA_COPY" \
    && set_launch role_not_established
}
proof_collapses "a contract that relabels another outcome a pass still cannot establish the role" \
  mut_relabel_other_outcome_pass 'is the only outcome that establishes the role' 2

# The vocabulary borrows from two existing owners and owns nothing itself, so a
# schema that quietly grew a sixth vocabulary must be refused rather than read.
restore_schema
write_assignment_record rev-proof
out=$(assignment_out); rc=$?
expect_code 0 "$rc" "the shipped contract must be admissible before the drift cases"
jq '(.launch_outcomes.outcomes[] | select(.name == "launch_failed") | .maps_to) = "launch_went_wrong"' \
  "$SCHEMA_COPY" > "$SCHEMA_COPY.t" && mv -f "$SCHEMA_COPY.t" "$SCHEMA_COPY"
out=$(assignment_out); rc=$?
expect_code 2 "$rc" "an outcome mapped onto a terminal state nothing declares must be could-not-observe"
assert_contains "$out" "launch_failed" "the refusal must name the outcome that stopped reusing the unified vocabulary"
restore_schema

jq '(.launch_outcomes.outcomes[] | select(.name == "could_not_observe") | .result) = "OBSERVED_ENOUGH"' \
  "$SCHEMA_COPY" > "$SCHEMA_COPY.t" && mv -f "$SCHEMA_COPY.t" "$SCHEMA_COPY"
out=$(assignment_out); rc=$?
expect_code 2 "$rc" "a result outside the three-valued observation type must be refused"
restore_schema

jq 'del(.launch_outcomes)' "$SCHEMA_COPY" > "$SCHEMA_COPY.t" && mv -f "$SCHEMA_COPY.t" "$SCHEMA_COPY"
out=$(assignment_out); rc=$?
expect_code 2 "$rc" "deleting the launch outcomes entirely must refuse, not fall back to trusting the spawn"
assert_contains "$out" "declares no launch outcomes" "the refusal must say the contract went missing"
restore_schema
pass "the launch-outcome vocabulary reuses its owners and refuses to drift from them"

# The two questions must stay separate: an eligible assignment is not a proof.
# This is the inference the whole section refuses, stated as a test.
restore_schema
write_assignment_record rev-proof
strip_meta review_launch
out=$(check_baseline); rc=$?
expect_code 0 "$rc" "check must still say this assignment MAY be made"
out=$(assignment_out); rc=$?
[ "$rc" != 0 ] || fail "an assignment that check approved was read as a review that happened"
assert_contains "$out" "UNSATISFIED" "passing check must never discharge the review obligation on its own"
pass "an eligible assignment is not evidence that a review happened"

echo "ok: fm-review-role"
