#!/usr/bin/env bash
# Behavior tests for qualification-on-zero-route: the route gate
# (bin/fm-route-lib.sh, bin/fm-route.sh), the spawn chokepoint (bin/fm-spawn.sh),
# and the bounded workflow (bin/fm-qualification.sh activate|resolve).
#
# THE RECURRENCE THIS SUITE EXISTS TO CLOSE. A route required a capability, the
# one candidate that could satisfy the route had no evidence for it, and the fleet
# had exactly one available answer: ask the captain for a task-specific floor
# exception. It asked repeatedly, for the same missing evidence, because missing
# qualification and "no model can do this" were the same value. The exact fixture
# is pinned in test_the_recurrence_fixture_* below, together with a MUTATION
# CONTROL that removes the automatic transition and proves the fixture turns red -
# so a pass here is evidence the protection works rather than evidence the fixture
# is satisfiable.
#
# The other properties pinned here:
#
#   1. INERT WHERE NOTHING DECLARES IT. A floor with no requires_capabilities
#      behaves exactly as it did before this existed. Activation must not reach it.
#   2. FOUR CLASSIFICATIONS, ONE ESCALATION. Missing or stale qualification, an
#      unobservable qualification, and a wait on availability are all engineering
#      states. Only "no candidate can be made eligible by qualifying it" reaches
#      the captain.
#   3. CHEAPEST PROMISING FIRST, and an unmeasured cost sorts LAST rather than
#      first - unmeasured is not cheap.
#   4. A PASS RETURNS THE SAME IDENTITY. The blocked work is unblocked, not
#      re-created: its attempt count, retry budget and custody record are the ones
#      it had before.
#   5. AVAILABILITY IS NOT QUALIFICATION. One vendor being unreachable never makes
#      a route unsatisfiable when another binding holds the capability.
#
# Refusal cases stop before any endpoint exists, and a fake `tmux` that exits
# non-zero backstops them, so a case that wrongly proceeded would fail rather than
# quietly create a worker.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
ROUTE="$ROOT/bin/fm-route.sh"
QUAL="$ROOT/bin/fm-qualification.sh"
TMP_ROOT=$(fm_test_tmproot fm-route-qualification)

command -v jq >/dev/null 2>&1 || fail "fm-route-qualification: jq is required"

qualification_activation_id() {
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | sha256sum | awk '{print substr($1,1,40)}')
  else
    digest=$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | shasum -a 256 | awk '{print substr($1,1,40)}')
  fi
  printf 'qualify-%s\n' "$digest"
}

AID_ALPHA=$(qualification_activation_id runtime-job-maker alpha/one pi high)
AID_BETA=$(qualification_activation_id runtime-job-maker beta/two pi high)
AID_ALPHA_XHIGH=$(qualification_activation_id runtime-job-maker alpha/one pi xhigh)
AID_ALPHA_SECOND="$AID_ALPHA-2"

CDIR="$TMP_ROOT/contracts"
RDIR="$TMP_ROOT/records"
NO_OVERLAY="$TMP_ROOT/absent-overlay"
mkdir -p "$CDIR" "$RDIR"

# --- fixture -----------------------------------------------------------------

# THE RECURRENCE SHAPE, spelled as configuration rather than as prose:
#   R-GENHARD requires the general-hard axes only.
#   R-RUNTIME requires the SAME axes PLUS the runtime-job-maker capability.
#   alpha/one meets every general-hard axis - and has no runtime evidence.
#   gamma/three is in the runtime pool and cannot meet its context floor, so no
#   other maker is available on that route.
write_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": {
    "F-GENHARD": { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic" },
    "F-RUNTIME": { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic",
                   "requires_capabilities": ["runtime-job-maker"] },
    "F-REVIEW":  { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic",
                   "requires_capabilities": ["runtime-job-design", "runtime-job-change"] },
    "F-QUAL":    { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic",
                   "requires_capabilities": ["runtime-job-adjudicator"] },
    "F-BROKEN":  { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic",
                   "requires_capabilities": "runtime-job-maker" }
  },
  "_models": {
    "alpha/one":   { "smart_zone": 140000, "effort_expressible": ["high", "xhigh"], "tool_loop": "verified-agentic" },
    "beta/two":    { "smart_zone": 140000, "effort_expressible": ["high", "xhigh"], "tool_loop": "verified-agentic" },
    "gamma/three": { "smart_zone": 100000, "effort_expressible": ["high"], "tool_loop": "verified-agentic" },
    "delta/four":  { "smart_zone": 140000, "effort_expressible": ["high", "xhigh"], "tool_loop": "verified-agentic" }
  },
  "rules": [
    { "when": "difficult generalist work", "route": "R-GENHARD", "floor": "F-GENHARD",
      "use": { "harness": "pi", "model": "alpha/one", "effort": "high" },
      "pool": ["alpha/one", "beta/two"] },
    { "when": "runtime work", "route": "R-RUNTIME", "floor": "F-RUNTIME",
      "use": { "harness": "pi", "model": "alpha/one", "effort": "high" },
      "pool": ["alpha/one", "gamma/three"] },
    { "when": "runtime work with several candidates", "route": "R-RUNTIME-WIDE", "floor": "F-RUNTIME",
      "use": { "harness": "pi", "model": "alpha/one", "effort": "high" },
      "pool": ["alpha/one", "beta/two", "delta/four"] },
    { "when": "runtime review", "route": "R-REVIEW", "floor": "F-REVIEW",
      "use": { "harness": "pi", "model": "beta/two", "effort": "high" },
      "pool": ["beta/two"] },
    { "when": "qualification adjudication", "route": "R-QUAL", "floor": "F-QUAL",
      "use": { "harness": "pi", "model": "beta/two", "effort": "high" },
      "pool": ["beta/two"] },
    { "when": "a floor whose requirement cannot be interpreted", "route": "R-BROKEN", "floor": "F-BROKEN",
      "use": { "harness": "pi", "model": "alpha/one", "effort": "high" },
      "pool": ["alpha/one"] }
  ],
  "default": { "when": "anything else", "route": "R-GENHARD", "floor": "F-GENHARD",
               "harness": "pi", "model": "alpha/one", "effort": "high" }
}
JSON
}

# A floor that declares NO capability at all, for the inert case.
write_unrequiring_config() {  # <home>
  cat > "$1/config/crew-dispatch.json" <<'JSON'
{
  "_floors": {
    "F-PLAIN": { "effort_floor": "high", "context_ceiling": 140000, "tool_loop": "verified-agentic" }
  },
  "_models": {
    "alpha/one": { "smart_zone": 140000, "effort_expressible": ["high"], "tool_loop": "verified-agentic" }
  },
  "rules": [
    { "when": "plain work", "route": "R-PLAIN", "floor": "F-PLAIN",
      "use": { "harness": "pi", "model": "alpha/one", "effort": "high" },
      "pool": ["alpha/one"] }
  ]
}
JSON
}

write_contract() {  # <id> <role> <axis>
  local adjudication=true
  [ "$1" != runtime-job-adjudicator ] || adjudication=false
  cat > "$CDIR/$1.json" <<JSON
{
  "qualification_schema_version": 1,
  "id": "$1",
  "role": "$2",
  "risk_class": "runtime-job-v1",
  "contract_version": "1.0.0",
  "axis": "$3",
  "purpose": "A synthetic contract used only to pin the zero-route behaviour.",
  "grants": "Eligibility on a route whose floor declares this contract.",
  "does_not_grant": ["anything outside this exact contract"],
  "executable_predicate": {
    "kind": "declared_deterministic",
    "check": "bin/fm-qualification.sh",
    "expect": "QUALIFIED"
  },
  "adjudication": { "required": $adjudication, "adjudicator_contract": "runtime-job-adjudicator",
                    "independence_dimensions": ["binding"] },
  "required_freshness_dependencies": ["contract_version"]
}
JSON
}

# write_record <id> <contract> <role> <model> <provider> <result> [jq-filter]
write_record() {
  local id=$1 contract=$2 role=$3 model=$4 provider=$5 result=$6 filter=${7:-.}
  jq --arg id "$id" --arg c "$contract" --arg role "$role" --arg m "$model" \
     --arg p "$provider" --arg r "$result" \
     '.id = $id | .contract = $c | .role = $role | .binding.model = $m
      | .binding.provider = $p | .result = $r | '"$filter" \
    > "$RDIR/$id.json" <<'JSON'
{
  "qualification_schema_version": 1,
  "id": "placeholder",
  "contract": "placeholder",
  "contract_version": "1.0.0",
  "role": "placeholder",
  "risk_class": "runtime-job-v1",
  "binding": { "provider": "placeholder", "model": "placeholder", "harness": "pi",
               "harness_version": "9.9.9", "native_effort": "high" },
  "result": "placeholder",
  "result_evidence": "the deterministic oracle graded the candidate from outside it",
  "measured_context": 120000,
  "observed_at": "2026-08-13",
  "adjudication": { "adjudicator_binding": "zeta/nine", "adjudicator_harness": "pi",
                    "adjudicator_result": "QUALIFIED",
                    "evidence": "the assignment-distinct evaluator graded the retained package" },
  "freshness_dependencies": [ { "kind": "contract_version", "version": "1.0.0" } ],
  "known_limitations": ["synthetic fixture material"]
}
JSON
}

# A model registry that records a price for two candidates and NONE for a third,
# so cheapest-first ordering and the unmeasured-cost rule are both observable.
write_registry() {  # <home>
  cat > "$1/config/models.json" <<'JSON'
{
  "schema": "fm-model-registry.v1",
  "providers": {
    "alpha": { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" },
    "beta":  { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" },
    "gamma": { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" },
    "delta": { "access_class": "A", "cost_posture": "subscription-flat", "status": "active" }
  },
  "models": {
    "alpha/one":   { "provider": "alpha", "model_id": "one", "harness": "pi",
                     "cost_class": "verified-free", "status": "approved-primary",
                     "price_at_verification": { "input": 5, "output": 5 },
                     "limits": { "shared_quota_pool": "alpha-pool" } },
    "beta/two":    { "provider": "beta", "model_id": "two", "harness": "pi",
                     "cost_class": "verified-free", "status": "approved-fallback",
                     "price_at_verification": { "input": 1, "output": 1 },
                     "limits": { "shared_quota_pool": "beta-pool" } },
    "gamma/three": { "provider": "gamma", "model_id": "three", "harness": "pi",
                     "cost_class": "subscription-flat", "status": "approved-fallback",
                     "limits": { "shared_quota_pool": "gamma-pool" } },
    "delta/four":  { "provider": "delta", "model_id": "four", "harness": "pi",
                     "cost_class": "verified-free", "status": "approved-fallback",
                     "limits": { "shared_quota_pool": "delta-pool" } }
  },
  "zero_budget": {
    "allowlist": {
      "alpha/one": { "price_at_verification": { "input": 0, "output": 0 },
                     "verified_at": "2026-08-01T00:00:00Z", "sources": ["provider-doc"],
                     "hard_ceiling": "the provider refuses rather than bills" },
      "beta/two":  { "price_at_verification": { "input": 0, "output": 0 },
                     "verified_at": "2026-08-01T00:00:00Z", "sources": ["provider-doc"],
                     "hard_ceiling": "the provider refuses rather than bills" }
    }
  }
}
JSON
}

# A tasks-axi that records every call, so the backlog blocker and its clearance
# are observed through the existing owner rather than assumed.
# The faithful tasks-axi fake lives in tests/lib.sh as fm_fake_tasks_axi, because
# a fixture that models a tool's refusals is shared infrastructure and two copies
# of it would drift the moment only one was corrected.
write_tasks_axi() {  # <fakebin> <log>
  fm_fake_tasks_axi "$1" "$2"
}

# A fleet snapshot the duplicate-dispatch owner can read, so activation composes
# that owner deterministically instead of running a live census.
write_snapshot() {  # <path> [live-task-id]
  local path=$1 live=${2:-}
  if [ -n "$live" ]; then
    jq -n --arg id "$live" '{tasks: [{id: $id, current_state: {raw: "working"}}],
      main_inventory: {valid: true, reason: null, orphan_in_flight: []},
      backlog: {records: []}, generated: "2026-08-17T00:00:00Z"}' > "$path"
  else
    jq -n '{tasks: [], main_inventory: {valid: true, reason: null, orphan_in_flight: []},
      backlog: {records: []}, generated: "2026-08-17T00:00:00Z"}' > "$path"
  fi
}

write_snapshot_dependents() {  # <path> <blocker> <dependent>...
  local path=$1 blocker=$2 dependent rows='[]'
  shift 2
  for dependent in "$@"; do
    rows=$(printf '%s' "$rows" | jq -c --arg id "$dependent" --arg blocker "$blocker" \
      '. + [{id:$id, structured:true, blocked_by_ids:[$blocker]}]')
  done
  jq -n --argjson rows "$rows" '{tasks: [], main_inventory: {valid: true, reason: null, orphan_in_flight: []},
    backlog: {records: $rows}, generated: "2026-08-17T00:00:00Z"}' > "$path"
}

make_home() {  # <name> [plain]
  local name=$1 shape=${2:-requiring} home fakebin
  home="$TMP_ROOT/$name/home"
  fakebin="$TMP_ROOT/$name/fakebin"
  mkdir -p "$home/config" "$home/state" "$home/data" "$TMP_ROOT/$name/projects/proj" "$fakebin"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$home/tmux.log" > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  fm_fake_treehouse "$fakebin"
  write_tasks_axi "$fakebin" "$TMP_ROOT/$name/tasks-axi.log"
  # The blocked work EXISTS in the backlog, because in production it always does -
  # it is the real work item that is waiting. Seeding it here is what lets the
  # fixture enforce the real `block --by` precondition instead of pretending the
  # dependency can name something that is not a task.
  local id
  for id in watcher-settled-transition-keeps-wedge-timer some-work runtime-task \
            plain-task blocked-runtime-work; do
    printf '%s queued\n' "$id" >> "$TMP_ROOT/$name/tasks-axi.store"
  done
  write_snapshot "$TMP_ROOT/$name/snapshot.json"
  case "$shape" in
    plain) write_unrequiring_config "$home" ;;
    *) write_config "$home" ;;
  esac
  write_registry "$home"
  printf '%s\n' "$home|$fakebin|$TMP_ROOT/$name/tasks-axi.log|$TMP_ROOT/$name/snapshot.json|$TMP_ROOT/$name/projects/proj"
}

read_home() {
  IFS='|' read -r HOME_DIR FAKEBIN TASKS_LOG SNAPSHOT PROJ_DIR <<EOF
$1
EOF
}

qual_env() {
  printf 'FM_QUALIFICATION_CONTRACT_DIR=%s FM_QUALIFICATION_RECORD_DIR=%s FM_QUALIFICATION_OVERLAY_DIR=%s\n' \
    "$CDIR" "$RDIR" "$NO_OVERLAY"
}

run_route() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_QUALIFICATION_CONTRACT_DIR="$CDIR" FM_QUALIFICATION_RECORD_DIR="$RDIR" \
    FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
    "$ROUTE" "$@" 2>&1
}

run_qual() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DECISION_SURFACE_SNAPSHOT="${SNAPSHOT:-}" \
    FM_QUALIFICATION_CONTRACT_DIR="$CDIR" FM_QUALIFICATION_RECORD_DIR="$RDIR" \
    FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
    FM_BACKEND=tmux HERDR_ENV='' \
    PATH="${FAKEBIN:-}:$PATH" \
    "$QUAL" "$@" 2>&1
}

run_spawn() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DECISION_SURFACE_SNAPSHOT="${SNAPSHOT:-}" \
    FM_QUALIFICATION_CONTRACT_DIR="$CDIR" FM_QUALIFICATION_RECORD_DIR="$RDIR" \
    FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux HERDR_ENV='' PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

reset_register() {
  rm -f "$CDIR"/*.json "$RDIR"/*.json
  write_contract runtime-job-maker RUNTIME_JOB_MAKER maker_qualification
  write_contract runtime-job-design RUNTIME_JOB_DESIGNER design_challenge
  write_contract runtime-job-change RUNTIME_JOB_CHANGE_REVIEWER exact_change_review
  write_contract runtime-job-adjudicator RUNTIME_JOB_ADJUDICATOR exact_change_review
  write_record zeta-nine-adjudicator runtime-job-adjudicator RUNTIME_JOB_ADJUDICATOR zeta/nine zeta QUALIFIED \
    '.adjudication.adjudicator_binding = "beta/two"'
}

zero() {  # <home> <route>
  run_route "$1" zero-route --route "$2" --json | tail -1
}

# --- 1. inert where nothing declares it --------------------------------------

# --- 0. the fixture itself, before anything is tested THROUGH it --------------

test_the_fixture_refuses_what_the_real_tool_refuses() {
  # THE CONTROL THAT SHOULD HAVE EXISTED FIRST. Every case below runs through the
  # fake tasks-axi, so a fake that accepts what the real tool rejects makes all of
  # them vacuous - which is exactly what happened: the previous fake exited 0
  # unconditionally and hid the fact that `block` was being refused every time and
  # the design did not function at all. This case pins the fake against the real
  # binary, so it cannot drift back into permissiveness without failing here.
  local rec; rec=$(make_home fixturefidelity); read_home "$rec"
  local out rc=0

  # 1. The refusal that was hidden: block by a blocker that is not a task.
  out=$(PATH="$FAKEBIN:$PATH" tasks-axi add real-work "the blocked work" 2>&1); rc=0
  PATH="$FAKEBIN:$PATH" tasks-axi block real-work --by not-a-task >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "the fixture ACCEPTED a block whose blocker does not exist; the real tool refuses it, and a fake that cannot fail makes every case below vacuous"
  out=$(PATH="$FAKEBIN:$PATH" tasks-axi block real-work --by not-a-task 2>&1 || true)
  assert_contains "$out" "not found" "the fixture refusal does not name the real cause"

  # 2. The same call succeeds once the blocker exists, so the refusal above is
  #    about the precondition and not about the fake refusing everything.
  PATH="$FAKEBIN:$PATH" tasks-axi add a-real-blocker "workflow" >/dev/null 2>&1 \
    || fail "the fixture could not create a task"
  PATH="$FAKEBIN:$PATH" tasks-axi block real-work --by a-real-blocker >/dev/null 2>&1 \
    || fail "the fixture refused a block whose blocker exists; it now refuses everything, which is the opposite vacuity"
  out=$(PATH="$FAKEBIN:$PATH" tasks-axi show a-real-blocker 2>&1) \
    || fail "the fixture refused the flag-free show invocation used by qualification"
  assert_contains "$out" "state: queued" "the fixture show output does not expose the TOON state line"
  PATH="$FAKEBIN:$PATH" tasks-axi show a-real-blocker --json >/dev/null 2>&1 \
    && fail "the fixture accepted show --json even though the real tool rejects that flag"
  PATH="$FAKEBIN:$PATH" tasks-axi hold a-real-blocker --reason "Firstmate decision required" --kind parked >/dev/null 2>&1 \
    || fail "the fixture refused the parked hold used by qualification"
  PATH="$FAKEBIN:$PATH" tasks-axi done a-real-blocker >/dev/null 2>&1 \
    || fail "the fixture refused the done invocation used by qualification"

  # 3. DIFFERENTIAL against the real binary where it is installed. The fake's
  #    verdict must match the real tool's on the same call.
  if command -v tasks-axi >/dev/null 2>&1 && [ "$(command -v tasks-axi)" != "$FAKEBIN/tasks-axi" ]; then
    local real_dir real_rc=0 real_invalid_rc=0
    real_dir=$(mktemp -d "$TMP_ROOT/realaxi.XXXXXX")
    printf 'backend = "markdown"\n\n[markdown]\npath = "backlog.md"\narchive = "done-archive.md"\ndone_keep = 10\n' > "$real_dir/.tasks.toml"
    ( cd "$real_dir" && tasks-axi add real-work "the blocked work" >/dev/null 2>&1 \
      && tasks-axi add a-real-blocker "workflow" >/dev/null 2>&1 \
      && tasks-axi show a-real-blocker >/dev/null 2>&1 \
      && tasks-axi block real-work --by a-real-blocker >/dev/null 2>&1 \
      && tasks-axi hold a-real-blocker --reason "Firstmate decision required" --kind parked >/dev/null 2>&1 \
      && tasks-axi done a-real-blocker >/dev/null 2>&1 ) || real_rc=$?
    [ "$real_rc" -eq 0 ] || fail "the real tasks-axi refused a qualification invocation the fixture accepts"
    ( cd "$real_dir" && tasks-axi show real-work --json >/dev/null 2>&1 ) || real_invalid_rc=$?
    [ "$real_invalid_rc" -ne 0 ] || fail "the real tasks-axi unexpectedly accepted show --json"
    real_rc=0
    ( cd "$real_dir" && tasks-axi block real-work --by not-a-task >/dev/null 2>&1 ) || real_rc=$?
    [ "$real_rc" -ne 0 ] \
      || fail "the REAL tasks-axi accepted a block with a non-existent blocker, so this fleet's blocker contract is not what the fixture models"
  else
    printf '# note: the real tasks-axi is not on PATH, so the differential half of this control could not be observed; the fixture-side assertions above still ran\n'
  fi
  pass "the fixture refuses what the real tool refuses"
}

test_a_floor_declaring_no_capability_is_untouched() {
  local rec
  rec=$(make_home inert plain); read_home "$rec"
  reset_register
  local out rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-PLAIN) || rc=$?
  expect_code 0 "$rc" "a route whose floor declares no capability was refused"
  assert_contains "$out" "alpha/one" "the candidate was withheld by a gate that should be inert"
  local z
  z=$(zero "$HOME_DIR" R-PLAIN)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = ELIGIBLE ] \
    || fail "an inert home reported a zero route"
  [ "$(printf '%s' "$z" | jq -r '.qualification_checked')" = false ] \
    || fail "the register was consulted for a floor that declares no capability"
  pass "a floor declaring no capability is untouched"
}

# --- 2. THE RECURRENCE FIXTURE ----------------------------------------------

test_the_recurrence_fixture_activates_a_bounded_workflow_and_never_asks_the_captain() {
  local rec
  rec=$(make_home recurrence); read_home "$rec"
  reset_register

  # The blocked work identity, with its own accounting already under way. Its
  # attempt record is captured before anything and compared after, because a
  # qualification workflow that reset it would be the accounting failure the
  # governing ruling names outright.
  local work=watcher-settled-transition-keeps-wedge-timer before after
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-attempt.sh" open "$work" --budget 2 >/dev/null 2>&1 \
    || fail "the fixture could not open an attempt for the blocked work"
  before=$(cat "$HOME_DIR/state/$work.attempt")

  # (a) Model A satisfies general-hard.
  local out rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-GENHARD) || rc=$?
  expect_code 0 "$rc" "alpha/one must be eligible on the general-hard route"
  assert_contains "$out" "alpha/one" "alpha/one was not eligible on the general-hard route"

  # (b) The runtime route additionally requires runtime-job-maker, alpha/one has
  #     no evidence for it, and no other maker on that route can satisfy it.
  rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-RUNTIME) || rc=$?
  expect_code 3 "$rc" "a route needing an unqualified capability must have no eligible candidate"
  assert_contains "$out" "QUALIFICATION_REQUIRED" "the report did not name the missing qualification"

  # (c) The classification is QUALIFICATION_REQUIRED and it does NOT escalate.
  local z
  z=$(zero "$HOME_DIR" R-RUNTIME)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_REQUIRED ] \
    || fail "the zero route classified as $(printf '%s' "$z" | jq -r '.classification') rather than QUALIFICATION_REQUIRED"
  [ "$(printf '%s' "$z" | jq -r '.escalation')" = NONE ] \
    || fail "missing evidence escalated to the captain"
  assert_not_contains "$z" "CAPTAIN_EXCEPTION_REQUIRED" \
    "a captain exception was requested solely because evidence was missing"
  [ "$(printf '%s' "$z" | jq -r '[.promising[].model] | join(",")')" = alpha/one ] \
    || fail "the promising candidate was not alpha/one"

  # (d) The bounded workflow activates, blocks the named work through the existing
  #     backlog owner, and is bounded on its OWN identity.
  rc=0
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks "$work") || rc=$?
  expect_code 0 "$rc" "the bounded qualification workflow did not activate"
  assert_contains "$out" "activated $AID_ALPHA" "the workflow identity was not reported"
  assert_present "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "no durable activation record was written, so this work would never resume"
  assert_grep "block $work --by $AID_ALPHA" "$TASKS_LOG" \
    "the blocked work identity was not blocked through the existing backlog owner"
  assert_absent "$HOME_DIR/state/$AID_ALPHA.attempt" \
    "the workflow spent an attempt before it launched"

  # (e) A pass records reusable evidence and returns the SAME identity.
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED
  rc=0
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result QUALIFIED) || rc=$?
  expect_code 0 "$rc" "a qualified result did not close the workflow"
  assert_contains "$out" "returns to normal eligibility" "the reader was not told the work was released"
  # THE CONSTRUCTION, ASSERTED DIRECTLY. The pass releases the work by closing the
  # workflow's own backlog item; the dependency then resolves on read because
  # bin/fm-fleet-snapshot.sh resolves a blocker exactly when its record is Done.
  # The absence of an unblock call is the point, not an oversight - there is no
  # second mutation to fail, retry or compensate for.
  assert_grep "done $AID_ALPHA" "$TASKS_LOG" \
    "the workflow item was not closed, so the blocker never resolves"
  assert_no_grep "unblock" "$TASKS_LOG" \
    "an unblock call exists; the edge must resolve by construction, not by a second mutation"

  # (f) The same blocked identity is eligible again, on the same route.
  rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-RUNTIME) || rc=$?
  expect_code 0 "$rc" "the route still had no eligible candidate after the qualification landed"
  assert_contains "$out" "alpha/one" "the newly qualified binding is not eligible"
  [ "$(printf '%s' "$(zero "$HOME_DIR" R-RUNTIME)" | jq -r '.classification')" = ELIGIBLE ] \
    || fail "the route is still classified as a zero route after a passing qualification"

  # (g) Identity, custody and budget preserved.
  after=$(cat "$HOME_DIR/state/$work.attempt")
  [ "$before" = "$after" ] \
    || fail "the qualification workflow changed the blocked work's attempt record:"$'\n'"before: $before"$'\n'"after:  $after"
  pass "the recurrence fixture activates a bounded workflow and never asks the captain"
}

test_the_recurrence_fixture_turns_red_without_the_automatic_transition() {
  # MUTATION CONTROL. The whole fixture above rests on one transition: a zero
  # route whose only blocker is fixable qualification classifies as
  # QUALIFICATION_REQUIRED rather than as "no model can satisfy this route". This
  # case removes that transition from a COPY of the shipped code and drives the
  # same fixture through the mutant's own public commands. If the fixture stays
  # green here, it is not testing the protection.
  local rec mutant
  rec=$(make_home mutation); read_home "$rec"
  reset_register
  mutant="$TMP_ROOT/mutant"
  mkdir -p "$mutant"
  cp -R "$ROOT/bin" "$mutant/bin" || fail "could not build the mutant tree"

  # The negative control runs FIRST: the unmutated copy must reproduce the real
  # behaviour, so a red result below is attributable to the mutation and not to
  # the copy.
  local z
  z=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_QUALIFICATION_CONTRACT_DIR="$CDIR" \
      FM_QUALIFICATION_RECORD_DIR="$RDIR" FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
      "$mutant/bin/fm-route.sh" zero-route --route R-RUNTIME --json 2>&1 | tail -1)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_REQUIRED ] \
    || fail "the unmutated copy does not reproduce the fixture, so the mutation below proves nothing"

  # Remove the automatic transition. The pattern is a jq fragment, so `$promising`
  # must reach grep unexpanded - the single quotes are the point.
  # shellcheck disable=SC2016
  grep -v 'elif ($promising | length) > 0 then "QUALIFICATION_REQUIRED"' \
    "$mutant/bin/fm-route-lib.sh" > "$mutant/bin/fm-route-lib.sh.new" \
    || fail "the mutation target was not found in the copied library"
  ! cmp -s "$mutant/bin/fm-route-lib.sh" "$mutant/bin/fm-route-lib.sh.new" \
    || fail "the mutation changed nothing, so this control is vacuous"
  mv "$mutant/bin/fm-route-lib.sh.new" "$mutant/bin/fm-route-lib.sh"

  z=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_QUALIFICATION_CONTRACT_DIR="$CDIR" \
      FM_QUALIFICATION_RECORD_DIR="$RDIR" FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" \
      "$mutant/bin/fm-route.sh" zero-route --route R-RUNTIME --json 2>&1 | tail -1)
  local class escalation
  class=$(printf '%s' "$z" | jq -r '.classification' 2>/dev/null || printf 'unreadable')
  escalation=$(printf '%s' "$z" | jq -r '.escalation' 2>/dev/null || printf 'unreadable')
  [ "$class" != QUALIFICATION_REQUIRED ] \
    || fail "removing the automatic transition did not change the classification; the fixture does not test it"
  [ "$class" = NO_MODEL_CAN_SATISFY_ROUTE ] \
    || fail "the mutant classified $class; the recurrence is specifically that missing evidence reads as an unsatisfiable route"
  [ "$escalation" = CAPTAIN_EXCEPTION_REQUIRED ] \
    || fail "the mutant did not reproduce the captain-exception request that is the recurrence itself"

  # And the workflow refuses to activate on the mutant, which is the operational
  # consequence: the work stops and waits for a human.
  local rc=0 out
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
        FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DECISION_SURFACE_SNAPSHOT="$SNAPSHOT" \
        FM_QUALIFICATION_CONTRACT_DIR="$CDIR" FM_QUALIFICATION_RECORD_DIR="$RDIR" \
        FM_QUALIFICATION_OVERLAY_DIR="$NO_OVERLAY" PATH="$FAKEBIN:$PATH" \
        "$mutant/bin/fm-qualification.sh" activate --route R-RUNTIME 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the mutant still activated a bounded workflow"
  assert_contains "$out" "NO_MODEL_CAN_SATISFY_ROUTE" "the mutant's refusal did not name the classification"
  assert_absent "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the mutant wrote an activation record it refused to create"
  pass "the recurrence fixture turns red without the automatic transition"
}

# --- 3. four classifications, one escalation ---------------------------------

test_a_failed_qualification_excludes_and_the_next_candidate_is_evaluated() {
  local rec
  rec=$(make_home failed); read_home "$rec"
  reset_register
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha FAILED \
    '.result_evidence = "the oracle rejected the destructive-safety predicate"'
  local z
  z=$(zero "$HOME_DIR" R-RUNTIME-WIDE)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_REQUIRED ] \
    || fail "a pool holding one excluded candidate and two unqualified ones is still a qualification state"
  [ "$(printf '%s' "$z" | jq -r '[.promising[].model] | join(",")' | grep -c 'alpha/one' || true)" = 0 ] \
    || fail "the excluded candidate was offered as promising"
  assert_contains "$z" "qualification_failed" "the exclusion was not carried on the excluded row"
  assert_contains "$z" "beta/two" "the next plausible candidate was not evaluated"
  # The activation picks a candidate that is NOT the excluded one.
  local out
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE)
  assert_not_contains "$out" "alpha-one" "the workflow was spent on the already-excluded candidate"
  assert_present "$RDIR/alpha-one-runtime.json" "the FAILED exclusion evidence was removed"
  pass "a failed qualification excludes and the next candidate is evaluated"
}

test_an_unobservable_qualification_is_not_a_captain_exception() {
  local rec
  rec=$(make_home unobserved); read_home "$rec"
  reset_register
  # The record exists and is inadmissible, so whether the binding holds the
  # capability could not be OBSERVED - a different fact from not holding it.
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED \
    '.verdict = "QUALIFIED"'
  local z
  z=$(zero "$HOME_DIR" R-RUNTIME)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_COULD_NOT_OBSERVE ] \
    || fail "an unobservable qualification classified as $(printf '%s' "$z" | jq -r '.classification')"
  [ "$(printf '%s' "$z" | jq -r '.escalation')" = NONE ] \
    || fail "an unmade observation escalated to the captain"
  local rc=0 out
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME) || rc=$?
  expect_code 4 "$rc" "an unobservable qualification is could-not-observe, not a workflow to spend"
  assert_contains "$out" "repair is to the observation" "the reader was not told what to repair"
  assert_absent "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "a workflow was activated for a candidate whose evidence could not be read"
  pass "an unobservable qualification is not a captain exception"
}

test_no_model_can_satisfy_route_is_the_only_classification_that_escalates() {
  local rec
  rec=$(make_home unsatisfiable); read_home "$rec"
  reset_register
  # gamma/three cannot meet the context floor, and alpha/one is excluded by a
  # preserved FAILED record whose dependencies have not changed. Nothing here can
  # be fixed by qualifying anything.
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha FAILED
  local z
  z=$(zero "$HOME_DIR" R-RUNTIME)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = NO_MODEL_CAN_SATISFY_ROUTE ] \
    || fail "a route no candidate can satisfy classified as $(printf '%s' "$z" | jq -r '.classification')"
  [ "$(printf '%s' "$z" | jq -r '.escalation')" = CAPTAIN_EXCEPTION_REQUIRED ] \
    || fail "the one classification that needs a captain did not say so"
  local rc=0
  run_route "$HOME_DIR" zero-route --route R-RUNTIME >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "the escalating classification must be distinguishable by exit status"
  pass "NO_MODEL_CAN_SATISFY_ROUTE is the only classification that escalates"
}

test_a_wait_on_availability_is_not_a_qualification_state() {
  local rec
  rec=$(make_home waiting); read_home "$rec"
  reset_register
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED
  run_route "$HOME_DIR" availability hold alpha/one --state rate_limited --evidence 'window spent' \
    >/dev/null 2>&1 || fail "the fixture could not record an availability hold"
  local z
  z=$(zero "$HOME_DIR" R-RUNTIME)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = AWAITING_AVAILABILITY ] \
    || fail "a qualified but unreachable candidate classified as $(printf '%s' "$z" | jq -r '.classification')"
  [ "$(printf '%s' "$z" | jq -r '.escalation')" = NONE ] \
    || fail "a wait escalated to the captain"
  local rc=0 out
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME) || rc=$?
  expect_code 3 "$rc" "activation on a wait must refuse rather than qualify a binding that is already qualified"
  assert_contains "$out" "qualification is not what is blocking it" "the refusal did not separate the two axes"
  pass "a wait on availability is not a qualification state"
}

test_availability_of_one_vendor_is_not_runtime_engineering_availability() {
  local rec
  rec=$(make_home vendor); read_home "$rec"
  reset_register
  # beta/two holds the capability; delta/four does not. Holding beta/two's whole
  # PROVIDER must not make the route unsatisfiable while another binding that
  # satisfies the same predicates exists - and, symmetrically, one vendor being
  # reachable must not stand in for the capability.
  write_record beta-two-runtime runtime-job-maker RUNTIME_JOB_MAKER beta/two beta QUALIFIED
  write_record delta-four-runtime runtime-job-maker RUNTIME_JOB_MAKER delta/four delta QUALIFIED
  local out rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-RUNTIME-WIDE) || rc=$?
  expect_code 0 "$rc" "control: the route had no eligible candidate before any hold"
  run_route "$HOME_DIR" availability hold beta --scope provider --state provider_unavailable \
    --evidence 'provider outage' >/dev/null 2>&1 \
    || fail "the fixture could not record a provider hold"
  rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-RUNTIME-WIDE) || rc=$?
  expect_code 0 "$rc" "one unreachable vendor emptied a route another qualified binding satisfies"
  assert_contains "$out" "delta/four" "the other qualified binding was not offered"
  assert_not_contains "$out" "beta/two" "the held binding was still offered"
  [ "$(printf '%s' "$(zero "$HOME_DIR" R-RUNTIME-WIDE)" | jq -r '.classification')" = ELIGIBLE ] \
    || fail "a reachable qualified binding did not keep the route satisfiable"
  pass "availability of one vendor is not runtime-engineering availability"
}

test_a_malformed_capability_requirement_is_refused_by_name() {
  local rec
  rec=$(make_home malformed); read_home "$rec"
  reset_register
  local out rc=0
  out=$(run_route "$HOME_DIR" eligible --route R-BROKEN) || rc=$?
  expect_code 3 "$rc" "a floor whose capability requirement cannot be interpreted must not enforce nothing"
  assert_contains "$out" "requires_capabilities_malformed" "the violated rule was not named"
  assert_contains "$out" "/_floors/F-BROKEN/requires_capabilities" "the exact config path was not named"
  pass "a malformed capability requirement is refused by name"
}

# --- 4. cheapest promising first ---------------------------------------------

test_the_cheapest_promising_candidate_is_chosen_and_unmeasured_cost_sorts_last() {
  local rec
  rec=$(make_home cheapest); read_home "$rec"
  reset_register
  # alpha/one records a price of 5+5, beta/two records 1+1, and delta/four records
  # NONE - it is registered and priced nowhere, which is unmeasured rather than
  # free. Pool ORDER puts alpha/one first, so choosing beta/two proves the ordering
  # is by observed cost and not by position; delta/four sorting last proves
  # unmeasured cost is never read as cheap.
  local z models
  z=$(zero "$HOME_DIR" R-RUNTIME-WIDE)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_REQUIRED ] \
    || fail "control: the wide route was not a qualification zero route"
  models=$(printf '%s' "$z" | jq -r '[.promising[].model] | join(",")')
  [ "$models" = "beta/two,alpha/one,delta/four" ] \
    || fail "promising candidates were ordered $models; expected cheapest first with unmeasured cost last"
  local out
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE)
  assert_contains "$out" "$AID_BETA" "the workflow was not spent on the cheapest candidate"
  pass "the cheapest promising candidate is chosen and unmeasured cost sorts last"
}

# --- 5. duplicate suppression and the bound ----------------------------------

test_duplicate_qualification_workflows_are_suppressed() {
  local rec
  rec=$(make_home duplicate); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "the first activation failed"
  local first out
  first=$(cat "$HOME_DIR/state/qualification/$AID_ALPHA.activation")
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work)
  assert_contains "$out" "FM_QUALIFICATION_ALREADY_ACTIVE" "a second workflow was created for the same pair"
  [ "$first" = "$(cat "$HOME_DIR/state/qualification/$AID_ALPHA.activation")" ] \
    || fail "the existing activation record was rewritten by the duplicate request"
  [ "$(grep -c "^block some-work" "$TASKS_LOG")" = 2 ] \
    || fail "the duplicate request did not idempotently reconfirm the blocker edge"
  pass "duplicate qualification workflows are suppressed"
}

test_a_completed_tuple_can_activate_a_new_incarnation() {
  local rec out
  rec=$(make_home reactivate); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "the first activation failed"
  PATH="$FAKEBIN:$PATH" tasks-axi done "$AID_ALPHA" >/dev/null 2>&1 \
    || fail "the fixture could not complete the first incarnation"
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work)
  assert_contains "$out" "activated $AID_ALPHA_SECOND" \
    "a completed tuple could not activate a later qualification incarnation"
  assert_present "$HOME_DIR/state/qualification/$AID_ALPHA_SECOND.activation" \
    "the later incarnation was not recorded"
  assert_grep "add $AID_ALPHA_SECOND" "$TASKS_LOG" \
    "the later incarnation did not become a distinct backlog task"
  pass "a completed tuple can activate a new incarnation"
}

test_work_already_in_flight_under_the_workflow_identity_suppresses_activation() {
  local rec
  rec=$(make_home inflight); read_home "$rec"
  reset_register
  # The composed duplicate-dispatch owner, not a second implementation of "is this
  # already running": the census names a live task under the derived identity.
  write_snapshot "$SNAPSHOT" "$AID_ALPHA"
  local out
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work)
  assert_contains "$out" "FM_QUALIFICATION_ALREADY_ACTIVE" "activation ignored work already in flight"
  assert_contains "$out" "already holds work under this identity" "the composed owner was not the source of the answer"
  assert_absent "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "an activation record was written for work already in flight"
  pass "work already in flight under the workflow identity suppresses activation"
}

test_a_could_not_observe_result_spends_one_attempt_and_stays_active() {
  local rec
  rec=$(make_home cno); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work --budget 2 >/dev/null 2>&1 \
    || fail "activation failed"
  local out rc=0
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result COULD_NOT_OBSERVE) || rc=$?
  expect_code 4 "$rc" "a could-not-observe result must not read as a pass or a failure"
  assert_contains "$out" "remains ACTIVE" "the workflow was closed on an unmade observation"
  assert_no_grep "done $AID_ALPHA" "$TASKS_LOG" \
    "an unmade observation closed the workflow item"
  assert_no_grep "terminal=" "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the activation file stores liveness; it must carry inert parameters only"
  assert_absent "$RDIR/alpha-one-runtime.json" "an unmade observation wrote a record against the binding"
  assert_no_grep "unblock some-work" "$TASKS_LOG" "an unmade observation released the blocked work"
  pass "a could-not-observe result spends one attempt and stays active"
}

test_a_failed_result_is_terminal_and_preserves_the_exclusion() {
  local rec
  rec=$(make_home failedresolve); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha FAILED
  local out rc=0
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result FAILED) || rc=$?
  expect_code 1 "$rc" "a failed workflow must be distinguishable by exit status"
  assert_grep "done $AID_ALPHA" "$TASKS_LOG" \
    "the failed workflow item was not closed through the backlog owner"
  assert_present "$RDIR/alpha-one-runtime.json" "the exclusion evidence was removed"
  assert_contains "$out" "PRESERVED" "the reader was not told the exclusion is kept"
  assert_no_grep "unblock some-work" "$TASKS_LOG" "a failed qualification released the blocked work"
  pass "a failed result is terminal and preserves the exclusion"
}

test_an_asserted_failure_without_a_matching_record_is_refused() {
  local rec out rc=0
  rec=$(make_home failedclaim); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result FAILED) || rc=$?
  expect_code 3 "$rc" "an unestablished failure did not remain qualification-required"
  assert_contains "$out" "refusing to close" "the asserted failure was accepted without register evidence"
  assert_no_grep "terminal=" "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "an unestablished failure closed the workflow"
  pass "an asserted failure without a matching record is refused"
}

test_failure_automatically_advances_to_the_next_candidate() {
  local rec out rc=0
  rec=$(make_home failedadvance); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  write_record beta-two-runtime runtime-job-maker RUNTIME_JOB_MAKER beta/two beta FAILED
  write_snapshot_dependents "$SNAPSHOT" "$AID_BETA" some-work
  out=$(run_qual "$HOME_DIR" resolve "$AID_BETA" --result FAILED) || rc=$?
  expect_code 1 "$rc" "a recorded failure did not remain distinguishable"
  assert_present "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "failure printed advice instead of activating the next promising candidate"
  assert_contains "$out" "evaluating the next promising candidate now" \
    "failure did not perform the route-owned transition"
  pass "failure automatically advances to the next candidate"
}

test_failure_advances_every_derived_dependent() {
  local rec out rc=0 first_block second_block predecessor_done
  rec=$(make_home faileddependents); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE --blocks some-work >/dev/null 2>&1 \
    || fail "first activation failed"
  run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE --blocks runtime-task >/dev/null 2>&1 \
    || fail "duplicate activation failed"
  write_record beta-two-runtime runtime-job-maker RUNTIME_JOB_MAKER beta/two beta FAILED
  write_snapshot_dependents "$SNAPSHOT" "$AID_BETA" some-work runtime-task
  out=$(run_qual "$HOME_DIR" resolve "$AID_BETA" --result FAILED) || rc=$?
  expect_code 1 "$rc" "a recorded failure did not remain distinguishable"
  assert_grep "block some-work --by $AID_ALPHA" "$TASKS_LOG" \
    "the first derived dependent was not attached to the successor"
  assert_grep "block runtime-task --by $AID_ALPHA" "$TASKS_LOG" \
    "the duplicate derived dependent was released without qualification"
  first_block=$(grep -nF "block some-work --by $AID_ALPHA" "$TASKS_LOG" | tail -1 | cut -d: -f1)
  second_block=$(grep -nF "block runtime-task --by $AID_ALPHA" "$TASKS_LOG" | tail -1 | cut -d: -f1)
  predecessor_done=$(grep -nF "done $AID_BETA" "$TASKS_LOG" | tail -1 | cut -d: -f1)
  [ "$first_block" -lt "$predecessor_done" ] && [ "$second_block" -lt "$predecessor_done" ] \
    || fail "the predecessor closed before every dependent was attached to its successor"
  pass "failure advances every fleet-derived dependent before closing"
}

test_qualification_dispatch_runs_the_candidate_on_a_bootstrap_route() {
  local rec out
  rec=$(make_home bootstrap); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  out=$(run_qual "$HOME_DIR" dispatch "$AID_ALPHA") || true
  assert_contains "$out" "launching $AID_ALPHA" "the real spawn chokepoint was not entered"
  assert_not_contains "$out" "no brief" "activation did not materialize the brief required by spawn"
  assert_not_contains "$out" "FM_ROUTE_QUALIFICATION_REQUIRED" "the qualifying run reused the blocked target route"
  assert_present "$HOME_DIR/tmux.log" "the candidate dispatch did not reach the real invocation owner"
  assert_grep "execution_model=alpha/one" "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the candidate was not recorded as the worker dispatched through the chokepoint"
  assert_no_grep "execution_model=beta/two" "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the route-supplying binding was incorrectly recorded as the worker"
  assert_grep "execution_route=R-GENHARD" "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the bootstrap route did not preserve the target floor axes"
  pass "qualification dispatch runs the candidate on a bootstrap route"
}

test_bootstrap_dispatch_refuses_a_substituted_worker() {
  local rec tmp out rc=0
  rec=$(make_home wrongworker); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  tmp="$HOME_DIR/state/qualification/$AID_ALPHA.activation.tmp"
  sed 's/^execution_model=.*/execution_model=beta\/two/' \
    "$HOME_DIR/state/qualification/$AID_ALPHA.activation" > "$tmp" \
    && mv "$tmp" "$HOME_DIR/state/qualification/$AID_ALPHA.activation"
  out=$(run_qual "$HOME_DIR" dispatch "$AID_ALPHA") || rc=$?
  expect_code 1 "$rc" "a route-supplying binding was accepted as the qualification worker"
  assert_contains "$out" "other than the candidate tuple" "the inverted worker role was not refused by name"
  assert_absent "$HOME_DIR/tmux.log" "the substituted worker reached the invocation owner"
  pass "bootstrap dispatch refuses a substituted worker"
}

test_qualified_resolution_requires_a_confirmed_close() {
  # A pass releases the work by closing the workflow item, so an owner that will
  # not confirm the close must not produce a claim that the work is available.
  # There is exactly one mutation here, which is why there is nothing to unwind.
  local rec out rc=0
  rec=$(make_home closecno); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED
  # $1 belongs to the fake being written, so it must reach the file unexpanded.
  # shellcheck disable=SC2016
  printf '#!/bin/sh\n[ "$1" != done ]\n' > "$FAKEBIN/tasks-axi"
  chmod +x "$FAKEBIN/tasks-axi"
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result QUALIFIED) || rc=$?
  expect_code 4 "$rc" "an unconfirmed close was reported as successful resolution"
  assert_contains "$out" "NO return to eligibility is claimed" "close uncertainty was reduced to a warning"
  assert_not_contains "$out" "returns to normal eligibility" "resolution claimed a release the backlog owner never confirmed"
  pass "qualified resolution requires a confirmed close"
}

test_an_unconfirmed_step_never_reports_success_and_promises_nothing() {
  # The class control. Each case drives a different durable step to fail and
  # asserts the same two properties: no success is reported, and nothing was
  # promised that would need compensating.
  local rec tmp out rc=0
  rec=$(make_home blockwrite); read_home "$rec"
  reset_register
  printf '#!/bin/sh\nexit 1\n' > "$FAKEBIN/tasks-axi"
  chmod +x "$FAKEBIN/tasks-axi"
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work) || rc=$?
  expect_code 4 "$rc" "a rejected workflow registration was reported as activation"
  assert_not_contains "$out" "activated $AID_ALPHA" "activation was claimed without backlog confirmation"
  assert_contains "$out" "Nothing was promised" "the safe failure direction was not stated to the reader"

  rec=$(make_home bootstrapread); read_home "$rec"
  reset_register
  tmp="$HOME_DIR/config/crew-dispatch.json.tmp"
  jq '._floors["F-GENHARD"].requires_capabilities = ["missing-bootstrap-contract"]' \
    "$HOME_DIR/config/crew-dispatch.json" > "$tmp" && mv "$tmp" "$HOME_DIR/config/crew-dispatch.json"
  rc=0
  out=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work) || rc=$?
  expect_code 4 "$rc" "an unreadable bootstrap qualification was reported as merely missing"
  assert_contains "$out" "could not be observed" "bootstrap read uncertainty was collapsed into QUALIFICATION_REQUIRED"
  assert_not_contains "$out" "no route where" "an unevaluable route was reported as established ineligible"
  pass "an unconfirmed step never reports success and promises nothing"
}


test_qualification_is_enforced_on_the_full_binding_tuple() {
  local rec out rc=0
  rec=$(make_home tuple); read_home "$rec"
  reset_register
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED
  mkdir -p "$HOME_DIR/data/runtime-task"
  printf 'You are a crewmate.\n\n# Definition of done\n' > "$HOME_DIR/data/runtime-task/brief.md"
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" runtime-task "$PROJ_DIR" --scout \
        --reason-code NOVEL_DECOMPOSITION --route R-RUNTIME --model alpha/one --effort xhigh --harness pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "a record at native effort high admitted native effort xhigh"
  assert_contains "$out" "FM_ROUTE_QUALIFICATION_REQUIRED" \
    "the route gate treated distinct native-effort tuples as identical"
  assert_present "$HOME_DIR/state/qualification/$AID_ALPHA_XHIGH.activation" \
    "the workflow identity omitted the differing tuple axes"
  pass "qualification is enforced on the full binding tuple"
}

test_tuple_identity_distinguishes_a_colliding_slug_pair() {
  local rec one two tmp first second
  rec=$(make_home collision-one); read_home "$rec"
  reset_register
  tmp="$HOME_DIR/config/crew-dispatch.json.tmp"
  jq '._models["provider/foo-codex-high"] = {smart_zone:140000, effort_expressible:["high"], tool_loop:"verified-agentic"}
      | .rules = [.rules[] | if .route == "R-RUNTIME" then (.use.model = "provider/foo-codex-high" | .pool = ["provider/foo-codex-high"])
                            elif .route == "R-GENHARD" then .pool += ["provider/foo-codex-high"] else . end]' \
    "$HOME_DIR/config/crew-dispatch.json" > "$tmp" && mv "$tmp" "$HOME_DIR/config/crew-dispatch.json"
  tmp="$HOME_DIR/config/models.json.tmp"
  jq '.providers.provider = .providers.alpha
      | .models["provider/foo-codex-high"] = (.models["alpha/one"] | .provider = "provider" | .model_id = "foo-codex-high")
      | .zero_budget.allowlist["provider/foo-codex-high"] = .zero_budget.allowlist["alpha/one"]' \
    "$HOME_DIR/config/models.json" > "$tmp" && mv "$tmp" "$HOME_DIR/config/models.json"
  one=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --json | tail -1)
  first=$(printf '%s' "$one" | jq -r '.activation')

  rec=$(make_home collision-two); read_home "$rec"
  reset_register
  tmp="$HOME_DIR/config/crew-dispatch.json.tmp"
  jq '._models["provider/foo"] = {smart_zone:140000, effort_expressible:["high"], tool_loop:"verified-agentic"}
      | .rules = [.rules[] | if .route == "R-RUNTIME" then (.use = {harness:"codex", model:"provider/foo", effort:"high"} | .pool = ["provider/foo"])
                            elif .route == "R-GENHARD" then .pool += ["provider/foo"] else . end]' \
    "$HOME_DIR/config/crew-dispatch.json" > "$tmp" && mv "$tmp" "$HOME_DIR/config/crew-dispatch.json"
  tmp="$HOME_DIR/config/models.json.tmp"
  jq '.providers.provider = .providers.alpha
      | .models["provider/foo"] = (.models["alpha/one"] | .provider = "provider" | .model_id = "foo" | .harness = "codex")
      | .zero_budget.allowlist["provider/foo"] = .zero_budget.allowlist["alpha/one"]' \
    "$HOME_DIR/config/models.json" > "$tmp" && mv "$tmp" "$HOME_DIR/config/models.json"
  two=$(run_qual "$HOME_DIR" activate --route R-RUNTIME --json | tail -1)
  second=$(printf '%s' "$two" | jq -r '.activation')

  [ -n "$first" ] && [ -n "$second" ] || fail "the collision controls did not activate both tuples"
  [ "$first" != "$second" ] || fail "distinct tuples collapsed to the same workflow identity"
  pass "tuple identity distinguishes a colliding slug pair"
}

test_failed_advancement_error_remains_observable_and_nonterminal() {
  local rec tmp out rc=0
  rec=$(make_home advancecno); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME-WIDE --blocks some-work >/dev/null 2>&1 \
    || fail "activation failed"
  write_record beta-two-runtime runtime-job-maker RUNTIME_JOB_MAKER beta/two beta FAILED
  write_snapshot_dependents "$SNAPSHOT" "$AID_BETA" some-work
  tmp="$HOME_DIR/config/crew-dispatch.json.tmp"
  jq '.rules = [.rules[] | select(.route != "R-GENHARD")]' "$HOME_DIR/config/crew-dispatch.json" > "$tmp" \
    && mv "$tmp" "$HOME_DIR/config/crew-dispatch.json"
  out=$(run_qual "$HOME_DIR" resolve "$AID_BETA" --result FAILED) || rc=$?
  expect_code 4 "$rc" "an unobservable successor transition was collapsed into ordinary failure"
  assert_contains "$out" "COULD NOT BE OBSERVED" "the failed advancement was swallowed"
  assert_no_grep "terminal=" "$HOME_DIR/state/qualification/$AID_BETA.activation" \
    "the predecessor became terminal before successor activation was established"
  pass "failed advancement error remains observable and nonterminal"
}

test_the_workflow_bound_never_touches_the_blocked_work_accounting() {
  local rec
  rec=$(make_home accounting); read_home "$rec"
  reset_register
  local work=blocked-runtime-work before after
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-attempt.sh" open "$work" --budget 3 >/dev/null 2>&1 \
    || fail "the fixture could not open an attempt for the blocked work"
  before=$(cat "$HOME_DIR/state/$work.attempt")
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks "$work" --budget 1 >/dev/null 2>&1 \
    || fail "activation failed"
  run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result COULD_NOT_OBSERVE >/dev/null 2>&1
  # The workflow's own bound is spent; the blocked work's is untouched.
  assert_present "$HOME_DIR/state/$AID_ALPHA.attempt" \
    "the workflow spent no attempt of its own, so nothing bounds it"
  after=$(cat "$HOME_DIR/state/$work.attempt")
  [ "$before" = "$after" ] \
    || fail "the workflow spent the blocked work's accounting:"$'\n'"before: $before"$'\n'"after:  $after"
  pass "the workflow bound never touches the blocked work accounting"
}

test_a_spent_workflow_bound_stops_rather_than_retrying_unbounded() {
  local rec
  rec=$(make_home bound); read_home "$rec"
  reset_register
  run_qual "$HOME_DIR" activate --route R-RUNTIME --blocks some-work --budget 1 >/dev/null 2>&1 \
    || fail "activation failed"
  run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result COULD_NOT_OBSERVE >/dev/null 2>&1
  local out rc=0
  out=$(run_qual "$HOME_DIR" resolve "$AID_ALPHA" --result COULD_NOT_OBSERVE) || rc=$?
  expect_code 4 "$rc" "a spent bound must stop rather than pass"
  assert_contains "$out" "stops rather than retrying without a bound" "the stop was not explained"
  assert_no_grep "done $AID_ALPHA" "$TASKS_LOG" \
    "the spent bound resolved the blocked dependency without a qualification outcome"
  assert_grep "hold $AID_ALPHA --reason Qualification attempt budget is spent and Firstmate must decide whether to raise the bound or abandon this qualification --kind parked" "$TASKS_LOG" \
    "the spent workflow was not parked with the operational decision it needs"
  [ "$(PATH="$FAKEBIN:$PATH" tasks-axi show "$AID_ALPHA" | awk -F ': ' '$1 ~ /hold-kind/ { print $2; exit }')" = parked ] \
    || fail "the spent workflow is not parked under the backlog owner"
  pass "a spent workflow stays open and parked for Firstmate"
}

# --- 6. two review capabilities on one route --------------------------------

test_a_route_requiring_two_capabilities_needs_both_records() {
  local rec
  rec=$(make_home tworoles); read_home "$rec"
  reset_register
  write_record beta-two-design runtime-job-design RUNTIME_JOB_DESIGNER beta/two beta QUALIFIED
  local z rc=0
  z=$(zero "$HOME_DIR" R-REVIEW)
  [ "$(printf '%s' "$z" | jq -r '.classification')" = QUALIFICATION_REQUIRED ] \
    || fail "a route requiring two capabilities was satisfied by one record"
  run_route "$HOME_DIR" eligible --route R-REVIEW >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "holding one of two required capabilities made a candidate eligible"
  write_record beta-two-change runtime-job-change RUNTIME_JOB_CHANGE_REVIEWER beta/two beta QUALIFIED
  rc=0
  local out
  out=$(run_route "$HOME_DIR" eligible --route R-REVIEW) || rc=$?
  expect_code 0 "$rc" "a candidate holding BOTH required capabilities was still ineligible"
  assert_contains "$out" "beta/two" "the doubly qualified candidate was not offered"
  pass "a route requiring two capabilities needs both records"
}

# --- 7. the spawn chokepoint -------------------------------------------------

test_spawn_refuses_an_unqualified_binding_and_records_the_workflow() {
  local rec
  rec=$(make_home spawnrefuse); read_home "$rec"
  reset_register
  mkdir -p "$HOME_DIR/data/runtime-task"
  printf 'You are a crewmate.\n\n# Definition of done\n' > "$HOME_DIR/data/runtime-task/brief.md"
  local out rc=0
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" runtime-task "$PROJ_DIR" --scout \
        --reason-code NOVEL_DECOMPOSITION --route R-RUNTIME --model alpha/one --effort high --harness pi) || rc=$?
  [ "$rc" -ne 0 ] || fail "the spawn chokepoint launched a worker on an unqualified binding"
  assert_contains "$out" "FM_ROUTE_QUALIFICATION_REQUIRED" "the refusal token was not printed"
  assert_contains "$out" "runtime-job-maker" "the refusal did not name the capability contract"
  assert_contains "$out" "not a captain decision" "the refusal read as an escalation"
  assert_absent "$HOME_DIR/state/runtime-task.meta" "a refused spawn wrote task metadata"
  assert_present "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "the refusal recorded no bounded workflow, so this work would never resume"
  assert_grep "block runtime-task --by $AID_ALPHA" "$TASKS_LOG" \
    "the refused work was not blocked on the workflow that would unblock it"
  pass "spawn refuses an unqualified binding and records the workflow"
}

test_spawn_admits_a_qualified_binding_and_records_what_it_was_checked_against() {
  local rec
  rec=$(make_home spawnadmit); read_home "$rec"
  reset_register
  write_record alpha-one-runtime runtime-job-maker RUNTIME_JOB_MAKER alpha/one alpha QUALIFIED
  mkdir -p "$HOME_DIR/data/runtime-task"
  printf 'You are a crewmate.\n\n# Definition of done\n' > "$HOME_DIR/data/runtime-task/brief.md"
  local out
  # The fake tmux refuses, so this cannot reach a live endpoint. What is asserted
  # is that the qualification gate did not refuse it: the run got past the gate and
  # failed later, at the backend.
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" runtime-task "$PROJ_DIR" --scout \
        --reason-code NOVEL_DECOMPOSITION --route R-RUNTIME --model alpha/one --effort high --harness pi)
  assert_not_contains "$out" "FM_ROUTE_QUALIFICATION_REQUIRED" \
    "a qualified binding was refused by the qualification gate"
  assert_absent "$HOME_DIR/state/qualification/$AID_ALPHA.activation" \
    "a bounded workflow was activated for a binding that is already qualified"
  pass "spawn admits a qualified binding and records what it was checked against"
}

test_spawn_is_untouched_where_no_floor_declares_a_capability() {
  local rec
  rec=$(make_home spawninert plain); read_home "$rec"
  reset_register
  mkdir -p "$HOME_DIR/data/plain-task"
  printf 'You are a crewmate.\n\n# Definition of done\n' > "$HOME_DIR/data/plain-task/brief.md"
  local out
  out=$(run_spawn "$HOME_DIR" "$FAKEBIN" plain-task "$PROJ_DIR" --scout \
        --reason-code NOVEL_DECOMPOSITION --route R-PLAIN --model alpha/one --effort high --harness pi)
  assert_not_contains "$out" "FM_ROUTE_QUALIFICATION" \
    "the qualification gate reached a home whose floors declare no capability"
  assert_absent "$HOME_DIR/state/qualification" \
    "a bounded workflow was recorded in a home that never opted in"
  pass "spawn is untouched where no floor declares a capability"
}

test_the_fixture_refuses_what_the_real_tool_refuses
test_a_floor_declaring_no_capability_is_untouched
test_the_recurrence_fixture_activates_a_bounded_workflow_and_never_asks_the_captain
test_the_recurrence_fixture_turns_red_without_the_automatic_transition
test_a_failed_qualification_excludes_and_the_next_candidate_is_evaluated
test_an_unobservable_qualification_is_not_a_captain_exception
test_no_model_can_satisfy_route_is_the_only_classification_that_escalates
test_a_wait_on_availability_is_not_a_qualification_state
test_availability_of_one_vendor_is_not_runtime_engineering_availability
test_a_malformed_capability_requirement_is_refused_by_name
test_the_cheapest_promising_candidate_is_chosen_and_unmeasured_cost_sorts_last
test_duplicate_qualification_workflows_are_suppressed
test_a_completed_tuple_can_activate_a_new_incarnation
test_work_already_in_flight_under_the_workflow_identity_suppresses_activation
test_a_could_not_observe_result_spends_one_attempt_and_stays_active
test_a_failed_result_is_terminal_and_preserves_the_exclusion
test_an_asserted_failure_without_a_matching_record_is_refused
test_failure_automatically_advances_to_the_next_candidate
test_failure_advances_every_derived_dependent
test_qualification_dispatch_runs_the_candidate_on_a_bootstrap_route
test_bootstrap_dispatch_refuses_a_substituted_worker
test_qualified_resolution_requires_a_confirmed_close
test_an_unconfirmed_step_never_reports_success_and_promises_nothing
test_qualification_is_enforced_on_the_full_binding_tuple
test_tuple_identity_distinguishes_a_colliding_slug_pair
test_failed_advancement_error_remains_observable_and_nonterminal
test_the_workflow_bound_never_touches_the_blocked_work_accounting
test_a_spent_workflow_bound_stops_rather_than_retrying_unbounded
test_a_route_requiring_two_capabilities_needs_both_records
test_spawn_refuses_an_unqualified_binding_and_records_the_workflow
test_spawn_admits_a_qualified_binding_and_records_what_it_was_checked_against
test_spawn_is_untouched_where_no_floor_declares_a_capability
