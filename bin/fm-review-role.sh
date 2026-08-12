#!/usr/bin/env bash
# fm-review-role.sh - the only interpreter of review-roles/, and the single
# owner of the ASSIGNMENT decision "may this candidate review this maker's
# artifact, on this harness, right now?"
#
# WHY THIS EXISTS. The runtime floor required a mandatory design review for a
# long time and it never happened, because the requirement was written as prose
# naming a MODEL. Nothing routes prose. When that model became unavailable the
# requirement did not fail loudly - it silently ceased to exist, and two runtime
# candidates were implemented with no review at all. The first repair replaced
# prose naming a model with prose naming PROPERTIES - mutation_authority
# FORBIDDEN, independence ASSIGNMENT-RELATIVE - and an independent checker
# rejected it by the cheapest possible method: it deleted each field, and
# separately inverted each field, and observed zero violations either way.
#
#   A requirement that only appears in prose is not an executable control.
#   A capability requirement must be enforceable, assignable, and capable of
#   becoming RED.
#
# So every field this command reads is load-bearing: deleting one or inverting
# one changes the verdict. tests/fm-review-role.test.sh applies exactly those
# mutations and watches each control go red, because a control that stays green
# when its protection is removed proves nothing.
#
# WHAT THIS DOES NOT OWN, which is most of it. This is a composer, not a new
# engine, and it deliberately adds no second source of truth:
#
#   the reviewer contract   review-roles/*.json, validated against
#                           review-roles/schema.json
#   ROUTE and the floor     bin/fm-route-lib.sh - untouched. This command asks it
#                           whether the reviewer is admitted by the route it
#                           claims and never re-decides pools, efforts or holds.
#   independence            bin/fm-independence-lib.sh - the four dimensions, the
#                           three values, the fold, and the never-infer-a-name-
#                           match rule. This command supplies a direction
#                           (prospective) and consumes the same records.
#   read-only launch flags  bin/fm-launch-lib.sh - the single owner of every
#                           verified launch command, extended with the measured
#                           read-only binding per harness.
#   model identity          bin/fm-model-registry-lib.sh, through the above.
#
# SUBCOMMANDS (see --help):
#   list | show <role> | harness-readonly [<harness>] | reconcile | check ...
#   | assignment --task <id>
#
# check and assignment answer two different questions on purpose. check is
# PROSPECTIVE - may this assignment be made - and passing it is an intention.
# assignment is RETROSPECTIVE - what does the durable record establish about a
# review that was dispatched - and only it can discharge a review obligation. A
# process invocation is not proof that the intended agent role started, and
# absence of mutation is not proof of enforcement by a reviewer that never
# started, so "produced no writes" never reads as "reviewed".
#
# EXIT STATUS, and the third value is a real one:
#   0  ELIGIBLE     every required predicate observed satisfied
#   1  REFUSED      a violation was OBSERVED
#   2  UNEVALUABLE  could-not-observe: an input was missing or unreadable
#
# 1 and 2 are both non-zero deliberately. A caller writing `if fm-review-role.sh
# check ...` fails closed on either, and a caller that needs to tell "policy says
# no" from "nobody could look" reads the status. What must never happen is
# could-not-observe reading as eligible, because an assignment nobody could
# evaluate is exactly the assignment a self-review slips through.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
FM_ROOT=${FM_ROOT_OVERRIDE:-$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd -P)}
FM_HOME=${FM_HOME:-$FM_ROOT}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
ROLES=${FM_REVIEW_ROLES_OVERRIDE:-$FM_ROOT/review-roles}

# shellcheck source=bin/fm-launch-lib.sh
. "$SCRIPT_DIR/fm-launch-lib.sh"
# shellcheck source=bin/fm-independence-lib.sh
. "$SCRIPT_DIR/fm-independence-lib.sh"
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# shellcheck source=bin/fm-status-event-lib.sh
. "$SCRIPT_DIR/fm-status-event-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

# Stable refusal tokens, matched by tests and callers rather than prose.
FM_REVIEW_TOKEN_ROLE_UNKNOWN=FM_REVIEW_ROLE_UNKNOWN
FM_REVIEW_TOKEN_ROLE_INADMISSIBLE=FM_REVIEW_ROLE_INADMISSIBLE
FM_REVIEW_TOKEN_NO_READONLY=FM_REVIEW_NO_READONLY_BINDING
FM_REVIEW_TOKEN_SELF_REVIEW=FM_REVIEW_SELF_REVIEW_REFUSED
FM_REVIEW_TOKEN_MAKER_UNKNOWN=FM_REVIEW_MAKER_IDENTITY_MISSING
FM_REVIEW_TOKEN_NOT_QUALIFIED=FM_REVIEW_BINDING_NOT_QUALIFIED
FM_REVIEW_TOKEN_CONTRADICTION=FM_REVIEW_POLICY_CONTRADICTION
FM_REVIEW_TOKEN_ASSIGNMENT_UNPROVED=FM_REVIEW_ASSIGNMENT_UNPROVED
FM_REVIEW_TOKEN_LAUNCH_NOT_CONSUMED=FM_REVIEW_LAUNCH_OUTCOME_NOT_CONSUMED

# The one launch outcome that establishes the role. Named once, read from the
# schema everywhere else, so renaming it in the contract cannot leave a second
# spelling behind in the code.
FM_REVIEW_LAUNCH_OK=launch_succeeded_as_requested

usage() {
  cat <<'EOF'
Usage:
  fm-review-role.sh list [--json]
  fm-review-role.sh show <role> [--json]
  fm-review-role.sh harness-readonly [<harness>] [--json]
  fm-review-role.sh reconcile [--json]
  fm-review-role.sh check --role <id> --reviewer <provider/model> --harness <name>
                          --effort <level> [--maker <provider/model>]
                          [--maker-process <id>] [--reviewer-process <id>]
                          [--reviewed-head <sha>] [--candidate-worktree <path>]
                          [--route <ROUTE>] [--json]
  fm-review-role.sh assignment --task <id> [--json]
  fm-review-role.sh capture --task <id> --kind <acknowledgement|verdict>

check answers one question: may this reviewer be assigned to this maker's
artifact, on this harness? Every input it needs is an input, not an assumption -
a missing maker identity is could-not-observe and refuses, it does not default
to eligible. check is PROSPECTIVE and is never evidence that a review happened.

assignment answers the retrospective question from the task's durable record:
what does it establish about a review that was dispatched? It requires all seven
facts in the schema's assignment_evidence, consumes the recorded launch outcome
rather than inferring one from the spawn having been attempted, and leaves the
review requirement UNSATISFIED when any fact is missing. It prints a
bin/fm-verify-lib.sh result record so the answer is read through fm_verify_case.
A reviewer that produced no writes is NOT thereby a reviewer that ran.

reconcile reads this home's routing config and reports pooled models whose
actual route membership contradicts an exclusivity claim the same file makes
about them in prose. It changes nothing.

harness-readonly reports which harnesses this repo has MEASURED a read-only
launch binding for. A harness with no record may not host a read-only role.

Exit status: 0 eligible, 1 refused (a violation was observed), 2 unevaluable
(could-not-observe). Both non-zero values fail closed.
EOF
}

review_artifact_path() {  # <task> <kind>
  case "$2" in
    acknowledgement) printf '%s/%s.review-ack.json' "$STATE" "$1" ;;
    verdict) printf '%s/%s.review-verdict.json' "$STATE" "$1" ;;
    *) return 1 ;;
  esac
}

review_artifact_raw_path() {  # <task> <kind>
  case "$2" in
    acknowledgement) printf '%s/%s.review-ack.raw' "$STATE" "$1" ;;
    verdict) printf '%s/%s.review-verdict.raw' "$STATE" "$1" ;;
    *) return 1 ;;
  esac
}

review_artifact_filter() {  # <kind> <binding> <role> <target> <assignment>
  case "$1" in
    acknowledgement)
      jq -ce --arg b "$2" --arg r "$3" --arg t "$4" --arg a "$5" '
        select(type == "object")
        | select(keys == ["assignment_received","review_assignment_id","review_role","review_target_commit","reviewer_binding","schema"])
        | select(.schema == "fm-review-ack.v1" and .assignment_received == true
          and .reviewer_binding == $b and .review_role == $r
          and .review_target_commit == $t and .review_assignment_id == $a)'
      ;;
    verdict)
      jq -ce --arg b "$2" --arg r "$3" --arg t "$4" --arg a "$5" '
        select(type == "object")
        | select(keys == ["evidence_refs","findings","review_assignment_id","review_role","review_target_commit","reviewer_binding","schema","verdict"])
        | select(.schema == "fm-review-verdict.v1"
          and .reviewer_binding == $b and .review_role == $r
          and .review_target_commit == $t and .review_assignment_id == $a
          and (.verdict == "approve" or .verdict == "reject")
          and (.findings | type) == "array"
          and (.evidence_refs | type) == "array"
          and all(.evidence_refs[]; type == "string" and length > 0))'
      ;;
    *) return 1 ;;
  esac
}

capture_review_artifact() {  # <task> <kind> <captured-output>
  local task=$1 kind=$2 capture=$3 meta=$STATE/$task.meta binding role target assignment line event json path raw_path tmp raw_tmp
  local in_frame=0 frame_kind='' frame_bytes='' payload=''
  [ -f "$meta" ] || return 1
  binding=$(meta_field "$meta" model)
  role=$(meta_field "$meta" review_role)
  target=$(meta_field "$meta" reviewed_head)
  assignment=$(meta_field "$meta" review_assignment_id)
  [ -n "$binding" ] && [ -n "$role" ] && [ -n "$target" ] && [ "$assignment" = "$task" ] || return 1
  if [ "$kind" = verdict ]; then
    while IFS= read -r line; do
      case "$line" in *"$FM_STATUS_EVENT_SCHEMA"*) event=$FM_STATUS_EVENT_SCHEMA${line#*"$FM_STATUS_EVENT_SCHEMA"} ;; *) continue ;; esac
      fm_status_event_parse "$event" || continue
      [ "$FM_STATUS_EVENT_KEY" = review-execution ] && [ "$FM_STATUS_EVENT_PHASE" = "$role" ] \
        && printf '%s\n' "$FM_STATUS_EVENT_EVIDENCE" | grep -Fxq -- "$target" || continue
      case "$FM_STATUS_EVENT_VERB" in done|failed) ;; *) continue ;; esac
      if ! grep -Fqx "fm-status-event.v1 verb=$FM_STATUS_EVENT_VERB key=review-execution phase=$role evidence=$target summary=captured reviewer execution" "$STATE/$task.status" 2>/dev/null; then
        printf 'fm-status-event.v1 verb=%s key=review-execution phase=%s evidence=%s summary=captured reviewer execution\n' \
          "$FM_STATUS_EVENT_VERB" "$role" "$target" >> "$STATE/$task.status" || return 1
      fi
    done <<EOF
$capture
EOF
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_frame" -eq 0 ]; then
      case "$line" in
        'FM-REVIEW-ARTIFACT-BEGIN kind='*' bytes='*)
          frame_kind=${line#FM-REVIEW-ARTIFACT-BEGIN kind=}
          frame_bytes=${frame_kind#* bytes=}
          frame_kind=${frame_kind%% bytes=*}
          case "$frame_bytes" in ''|*[!0-9]*) continue ;; esac
          [ "$frame_kind" = "$kind" ] || continue
          in_frame=1
          payload=''
          ;;
      esac
      continue
    fi
    if [ "$line" = "FM-REVIEW-ARTIFACT-END kind=$kind" ]; then
      [ "${#payload}" -eq "$frame_bytes" ] || return 1
      json=$(printf '%s' "$payload" | review_artifact_filter "$kind" "$binding" "$role" "$target" "$assignment" 2>/dev/null) || return 1
      path=$(review_artifact_path "$task" "$kind") || return 1
      raw_path=$(review_artifact_raw_path "$task" "$kind") || return 1
      tmp=$path.tmp.$$
      raw_tmp=$raw_path.tmp.$$
      printf '%s' "$payload" > "$raw_tmp" || return 1
      printf '%s\n' "$json" > "$tmp" || return 1
      mv -f "$raw_tmp" "$raw_path" || return 1
      mv -f "$tmp" "$path" || return 1
      return 0
    fi
    payload=$payload$line
  done <<EOF
$capture
EOF
  return 1
}

die_unevaluable() { echo "error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die_unevaluable "jq is required to read review-roles/"
[ -d "$ROLES" ] || die_unevaluable "$ROLES does not exist, so no review role can be read; this is could-not-observe, never an absent obligation"
SCHEMA=$ROLES/schema.json
[ -f "$SCHEMA" ] || die_unevaluable "$SCHEMA is missing, so no role can be validated against its contract"

role_id_valid() { [[ $1 =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; }

role_path() {
  role_id_valid "$1" || return 1
  printf '%s/%s.json\n' "$ROLES" "$1"
}

role_ids() {
  local f b
  for f in "$ROLES"/*.json; do
    [ -e "$f" ] || continue
    b=$(basename "$f" .json)
    [ "$b" != schema ] || continue
    printf '%s\n' "$b"
  done
}

# ---------------------------------------------------------------------------
# Role admission - the contract validator
# ---------------------------------------------------------------------------
#
# EVERY required predicate is required, and its value must come from that
# predicate's closed vocabulary. A role missing one is INADMISSIBLE and refuses;
# it does not quietly check the predicates that survived. That is the difference
# between this and the configuration it replaces: there, deleting a field
# shrank the check silently, so deletion was invisible.
#
# shellcheck disable=SC2016 # jq program, not shell expansion.
ROLE_VIOLATIONS_JQ='
  . as [$schema, $role]
  | ($schema.required_predicates) as $req
  | ($schema.predicate_vocabularies) as $vocab
  | ($role.predicates // {}) as $p
  | [
      (if ($role.review_role_schema_version? // null) != $schema.review_role_schema_version
       then {rule:"schema_version_mismatch", path:"/review_role_schema_version",
             configured:($schema.review_role_schema_version|tostring),
             observed:(($role.review_role_schema_version // "absent")|tostring)}
       else empty end),
      (if $role.id != $requested_role
       then {rule:"role_id_mismatch", path:"/id",
             configured:$requested_role,
             observed:(($role.id // "absent")|tostring)}
       else empty end),
      (if (($role.activity? | type) != "string")
          or (($schema.activities | has($role.activity)) | not)
       then {rule:"activity_unknown", path:"/activity",
             configured:(($schema.activities | keys) - ["rule"] | join(", ")),
             observed:(($role.activity // "absent")|tostring)}
       else empty end),
      (["id","reviews_floor","obligation_point","does_not_discharge","source"][]
       | . as $k
       | if (($role[$k]? | type) != "string") or (($role[$k] | length) == 0)
         then {rule:"required_field_missing", path:("/" + $k),
               configured:"a non-empty string", observed:"absent"}
         else empty end),
      # THE DELETION CONTROL. A required predicate that is not present is a
      # violation naming the predicate, so removing one from a role file changes
      # the verdict rather than shrinking the check.
      ($req[]
       | . as $k
       | if ($p | has($k)) | not
         then {rule:"predicate_missing", path:("/predicates/" + $k),
               configured:(($vocab[$k] // ["a value"]) | join(" | ")),
               observed:"absent"}
         # THE INVERSION CONTROL. A present predicate whose value is outside its
         # closed vocabulary is refused BY NAME rather than skipped. An axis that
         # silently enforces nothing for an unrecognised value is an axis an
         # operator believes is armed.
         elif (($vocab[$k] // null) != null) and (($vocab[$k] | index($p[$k])) == null)
         then {rule:"predicate_value_unknown", path:("/predicates/" + $k),
               configured:($vocab[$k] | join(" | ")), observed:($p[$k]|tostring)}
         else empty end),
      # Bind the key before testing membership: written as ($req | index(.)) the
      # "." has already been rebound to $req by the pipe, so it searches the list
      # for ITSELF, finds it at 0, and never reports an unknown predicate. Same
      # rebinding class as the one the reconciler below carried, and just as
      # silent: both read as a clean result rather than as a broken check.
      ($p | keys[] | . as $pk | select(($req | index($pk)) == null)
       | {rule:"predicate_unknown", path:("/predicates/" + $pk),
          configured:($req | join(", ")), observed:$pk}),
      ($schema.refused_keys[]
       | . as $k
       | if ($role | has($k))
         then {rule:"refused_key_present", path:("/" + $k),
               configured:"derived per assignment, never stored",
               observed:($role[$k]|tostring)}
         else empty end),
      ($schema.independence_dimensions[]
       | . as $d
       | if (($role.independence[$d]? | type) != "string")
         then {rule:"independence_dimension_missing", path:("/independence/" + $d),
               configured:($schema.independence_requirement | keys | join(" | ")),
               observed:"absent"}
         elif (($schema.independence_requirement | has($role.independence[$d])) | not)
         then {rule:"independence_requirement_unknown", path:("/independence/" + $d),
               configured:($schema.independence_requirement | keys | join(" | ")),
               observed:($role.independence[$d])}
         else empty end),
      (if (($role.qualified_bindings? | type) != "array") or (($role.qualified_bindings | length) == 0)
       then {rule:"qualified_bindings_missing", path:"/qualified_bindings",
             configured:"at least one binding with its own effort and evidence",
             observed:"absent or empty"}
       else ($role.qualified_bindings | to_entries[]
             | .key as $i | .value as $b
             | (["binding","effort","evidence_class","evidence"][]
                | . as $k
                | if (($b[$k]? | type) != "string") or (($b[$k] | length) == 0)
                  then {rule:"qualified_binding_incomplete",
                        path:("/qualified_bindings/" + ($i|tostring) + "/" + $k),
                        configured:"a non-empty string", observed:"absent"}
                  else empty end),
               (if (["empirical","policy"] | index($b.evidence_class // "")) == null
                then {rule:"evidence_class_unknown",
                      path:("/qualified_bindings/" + ($i|tostring) + "/evidence_class"),
                      configured:"empirical | policy",
                      observed:(($b.evidence_class // "absent")|tostring)}
                else empty end))
       end),
      (if $role.activity == "change" and $role.requires_pinned_head != true
       then {rule:"pinned_head_requirement_missing", path:"/requires_pinned_head",
             configured:"true for change review roles",
             observed:(($role.requires_pinned_head // "absent")|tostring)}
       elif ($role | has("requires_pinned_head")) and (($role.requires_pinned_head | type) != "boolean")
       then {rule:"pinned_head_requirement_invalid", path:"/requires_pinned_head",
             configured:"a boolean",
             observed:($role.requires_pinned_head|tostring)}
       else empty end)
    ]'

role_violations() {  # <role-file> <requested-role> -> JSON array
  jq -c -s --arg requested_role "$2" "$ROLE_VIOLATIONS_JQ" "$SCHEMA" "$1" 2>/dev/null
}

render_violations() {  # <json-array> <prefix>
  printf '%s' "$1" | jq -r --arg p "${2:-}" '
    .[]? | "  " + .rule + ": " + $p + .path
      + " requires " + (.configured|tostring)
      + "; observed " + (.observed|tostring)' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Policy contradiction reconciliation
# ---------------------------------------------------------------------------
#
# One file that simultaneously authorises and forbids a membership has no single
# answer, and a reader quoting whichever clause agrees with them is how the
# contradiction survives. This detects it mechanically: for every model any pool
# contains, compare its ACTUAL route membership against any exclusivity claim
# the same file makes about it in prose. Prose is not enforcement, but prose
# that contradicts the enforced structure is a deterministic reconciliation
# failure, which is a real red rather than an opinion.
#
# It reads the config only. Repairing the config is the home operator's, because
# config/ is home-private and this command never writes it.
# shellcheck disable=SC2016 # jq program, not shell expansion.
RECONCILE_JQ="$FM_ROUTE_ENTRIES_JQ"'
  . as $cfg
  | [ route_entries[] | select((.rule.pool? | type) == "array")
      | {route: .id, pool: .rule.pool} ] as $memberships
  | ($memberships | map(.route) | unique) as $all_routes
  | ([ $memberships[] | .pool[] ] | unique) as $models
  | ([ $cfg | .. | strings ]) as $prose
  | [ $models[]
      | . as $m
      | ($m | split("/") | last) as $bare
      | ([ $memberships[] | select(.pool | index($m)) | .route ] | unique) as $actual
      | [ $prose[]
          | . as $claim
          | select($claim | test($bare; "i"))
          | select($claim | test("alone|only route|only pool|no other route|only[^.]{0,40}route whose pool"; "i"))
          # BIND THE ROUTE ID BEFORE TESTING. Written as select($claim | test(.))
          # the "." inside test() has already been rebound to $claim by the pipe,
          # so every claim was tested against ITSELF as a regex and always
          # matched - which made this whole detector green on a configuration
          # known to contradict itself. Named capture is what keeps it armed.
          | ([ $all_routes[] | . as $r | select($claim | test($r; "i")) ]) as $named
          | select(($named | length) > 0)
          | select(([ $actual[] | . as $ar | select(($named | index($ar)) == null) ] | length) > 0)
          | {claim: ($claim[0:200]), names: $named} ] as $contradicting
      | select(($contradicting | length) > 0)
      | {model: $m, actual_routes: $actual, contradicted_by: $contradicting} ]'

cmd_reconcile() {
  local json=0 file out n
  [ "${1:-}" != --json ] || json=1
  file=$(fm_route_config_path "$CONFIG")
  if [ ! -f "$file" ]; then
    [ "$json" -eq 0 ] || printf '{"schema":"fm-review-reconcile.v1","evaluable":false,"reason":"no routing config"}\n'
    [ "$json" -eq 1 ] || echo "unevaluable: $file does not exist, so no policy claim could be reconciled against pool membership"
    exit 2
  fi
  out=$(jq -c "$RECONCILE_JQ" "$file" 2>/dev/null) || {
    [ "$json" -eq 0 ] || printf '{"schema":"fm-review-reconcile.v1","evaluable":false,"reason":"unreadable routing config"}\n'
    [ "$json" -eq 1 ] || echo "unevaluable: $file could not be parsed, so its claims could not be reconciled"
    exit 2
  }
  n=$(printf '%s' "$out" | jq 'length')
  if [ "$json" -eq 1 ]; then
    printf '{"schema":"fm-review-reconcile.v1","evaluable":true,"contradictions":%s}\n' "$out"
  elif [ "$n" = 0 ]; then
    echo "reconciled: no pooled model's route membership contradicts an exclusivity claim in $file"
  else
    printf '%s: %s pooled model(s) in %s are claimed exclusive to a route they are not exclusive to:\n' \
      "$FM_REVIEW_TOKEN_CONTRADICTION" "$n" "$file"
    printf '%s' "$out" | jq -r '.[] | "  " + .model + ": actually in " + (.actual_routes|join(", "))
      + "; the file also claims " + ([.contradicted_by[].names|join("+")]|join(" / "))
      + " exclusively -- " + (.contradicted_by[0].claim|tostring)'
    echo "  one file cannot both authorise and forbid a membership; repair the config so the policy has one answer"
  fi
  [ "$n" = 0 ] || exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# harness-readonly
# ---------------------------------------------------------------------------

cmd_harness_readonly() {
  local json=0 harness='' a
  for a in "$@"; do
    case "$a" in
      --json) json=1 ;;
      -*) die_unevaluable "unknown option: $a" ;;
      *) harness=$a ;;
    esac
  done
  local roster
  roster=$(launch_harnesses) || die_unevaluable "the launch roster could not be derived from bin/fm-launch-lib.sh; that is could-not-observe, never an empty fleet"
  if [ -n "$harness" ]; then
    local posture flags mech
    posture=$(launch_readonly_posture "$harness") || {
      echo "$harness is not a launchable adapter, so it has no read-only posture to report" >&2
      exit 2
    }
    flags=$(launch_readonly_flags "$harness" 2>/dev/null || true)
    mech=${posture#enforced }
    [ "$posture" != unknown ] || mech=''
    if [ "$json" -eq 1 ]; then
      jq -n --arg h "$harness" --arg p "$posture" --arg m "$mech" --arg f "$flags" \
        '{schema:"fm-review-harness-readonly.v1", harness:$h, posture:$p,
          mechanism:(if $m == "" then null else $m end),
          flags:(if $f == "" then null else $f end)}'
    else
      printf '%s %s%s\n' "$harness" "$posture" "$([ -z "$flags" ] || printf ': %s' "$flags")"
    fi
    [ "$posture" = unknown ] && exit 2
    exit 0
  fi
  if [ "$json" -eq 1 ]; then
    local rows='[]' h p f
    while IFS= read -r h; do
      [ -n "$h" ] || continue
      p=$(launch_readonly_posture "$h") || continue
      f=$(launch_readonly_flags "$h" 2>/dev/null || true)
      rows=$(printf '%s' "$rows" | jq -c --arg h "$h" --arg p "$p" --arg f "$f" \
        '. + [{harness:$h, posture:$p, mechanism:(if ($p|startswith("enforced ")) then ($p|ltrimstr("enforced ")) else null end), flags:(if $f == "" then null else $f end)}]')
    done <<EOF
$roster
EOF
    jq -n --argjson r "$rows" '{schema:"fm-review-harness-readonly.v1", harnesses:$r}'
  else
    launch_readonly_posture
  fi
  exit 0
}

# ---------------------------------------------------------------------------
# check - the assignment decision
# ---------------------------------------------------------------------------

cmd_check() {
  local role='' reviewer='' harness='' effort='' maker='' maker_proc='' reviewer_proc=''
  local head='' candidate_worktree='' route='' json=0 want=''
  local a
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        role) role=$a ;; reviewer) reviewer=$a ;; harness) harness=$a ;;
        effort) effort=$a ;; maker) maker=$a ;; maker-process) maker_proc=$a ;;
        reviewer-process) reviewer_proc=$a ;; reviewed-head) head=$a ;;
        candidate-worktree) candidate_worktree=$a ;; route) route=$a ;;
      esac
      want=''
      continue
    fi
    case "$a" in
      --role|--reviewer|--harness|--effort|--maker|--maker-process|--reviewer-process|--reviewed-head|--candidate-worktree|--route)
        want=${a#--} ;;
      --role=*) role=${a#--role=} ;;
      --reviewer=*) reviewer=${a#--reviewer=} ;;
      --harness=*) harness=${a#--harness=} ;;
      --effort=*) effort=${a#--effort=} ;;
      --maker=*) maker=${a#--maker=} ;;
      --maker-process=*) maker_proc=${a#--maker-process=} ;;
      --reviewer-process=*) reviewer_proc=${a#--reviewer-process=} ;;
      --reviewed-head=*) head=${a#--reviewed-head=} ;;
      --candidate-worktree=*) candidate_worktree=${a#--candidate-worktree=} ;;
      --route=*) route=${a#--route=} ;;
      --json) json=1 ;;
      *) die_unevaluable "unknown argument to check: $a" ;;
    esac
  done
  [ -z "$want" ] || die_unevaluable "--$want requires a value"
  [ -n "$role" ] || die_unevaluable "check requires --role"
  role_id_valid "$role" || die_unevaluable "$FM_REVIEW_TOKEN_ROLE_UNKNOWN: role ids must be lowercase hyphen-separated slugs"
  [ -n "$reviewer" ] || die_unevaluable "check requires --reviewer"
  [ -n "$harness" ] || die_unevaluable "check requires --harness; the read-only binding is a property of the harness, so an unnamed one cannot be checked"

  local file
  file=$(role_path "$role")
  if [ ! -f "$file" ]; then
    echo "error: $FM_REVIEW_TOKEN_ROLE_UNKNOWN: no review role '$role' in $ROLES. Defined: $(role_ids | tr '\n' ' ')" >&2
    exit 2
  fi
  local rv
  rv=$(role_violations "$file" "$role") || die_unevaluable "$file could not be parsed against $SCHEMA"
  if [ "$(printf '%s' "$rv" | jq 'length')" != 0 ]; then
    echo "error: $FM_REVIEW_TOKEN_ROLE_INADMISSIBLE: review role '$role' does not satisfy $SCHEMA, so no assignment may be checked against it:" >&2
    render_violations "$rv" "$role" >&2
    exit 2
  fi

  local mutation independence_req_json requires_head activity
  mutation=$(jq -r '.predicates.mutation_authority' "$file")
  activity=$(jq -r '.activity' "$file")
  requires_head=$(jq -r '.requires_pinned_head // false' "$file")
  independence_req_json=$(jq -c '.independence' "$file")

  # Violations OBSERVED for this assignment, in the same shape the routing
  # library renders, so one reader understands both.
  local viols='[]'
  add_viol() {  # <rule> <configured> <observed>
    viols=$(printf '%s' "$viols" | jq -c --arg r "$1" --arg c "$2" --arg o "$3" \
      '. + [{rule:$r, configured:$c, observed:$o}]')
  }

  # 1. READ-ONLY AUTHORITY, ENFORCED AT LAUNCH. mutation_authority is not a note
  # to the agent: it selects the binding. forbidden means this command will only
  # admit a harness this repo has MEASURED refusing a write, and refuses every
  # other - which is a real constraint on where a reviewer may run, reported as
  # one rather than replaced with an instruction in the brief.
  local ro_flags='' ro_mech=''
  if [ "$mutation" = forbidden ]; then
    if ro_flags=$(launch_readonly_flags "$harness" 2>/dev/null); then
      ro_mech=$(launch_readonly_recorded "$harness" | cut -f1)
    else
      add_viol "$FM_REVIEW_TOKEN_NO_READONLY" \
        "a harness with a measured read-only launch binding" \
        "$harness has none recorded in bin/fm-launch-lib.sh, so a read-only role cannot be bound to it"
    fi
  else
    add_viol mutation_authority_not_forbidden \
      "forbidden (a review role confers no mutation authority over the candidate)" \
      "$mutation"
  fi

  # 2. CAPABILITY. The binding must be qualified for THIS role - not for review
  # generally, and not for making. A binding absent from the role's list is not
  # qualified whatever it is qualified for elsewhere.
  local qb
  qb=$(jq -c --arg b "$reviewer" '.qualified_bindings[] | select(.binding == $b)' "$file")
  if [ -z "$qb" ]; then
    add_viol "$FM_REVIEW_TOKEN_NOT_QUALIFIED" \
      "$(jq -r '[.qualified_bindings[].binding] | join(", ")' "$file")" \
      "$reviewer is not a qualified binding for role $role"
  elif [ -z "$effort" ]; then
    add_viol effort_not_qualified_for_binding \
      "$(printf '%s' "$qb" | jq -r '.effort') (the explicit setting qualified for $reviewer on this role)" \
      "absent; reviewer effort is binding-specific and cannot be inherited from a harness default"
  else
    local qeffort
    qeffort=$(printf '%s' "$qb" | jq -r '.effort')
    [ "$effort" = "$qeffort" ] || add_viol effort_not_qualified_for_binding \
      "$qeffort (the setting qualified for $reviewer on this role; never inherited and never ordered against another spelling)" \
      "$effort"
  fi

  # 3. AUTHOR IDENTITY AS AN INPUT. A missing maker identity fails closed. This
  # is the input the routing decision never had, and its absence is exactly the
  # case a self-review passes through.
  if [ -z "$maker" ]; then
    add_viol "$FM_REVIEW_TOKEN_MAKER_UNKNOWN" \
      "--maker naming the binding that authored the artifact" \
      "absent; with no author identity this assignment cannot be distinguished from a self-review"
  fi

  # 4. ASSIGNMENT-RELATIVE INDEPENDENCE, from the library that owns the
  # dimensions. A required dimension must be OBSERVED to hold; could-not-observe
  # refuses.
  local indep=''
  if [ -n "$maker" ]; then
    indep=$(fm_independence_assignment "$maker" "$reviewer" "$maker_proc" "$reviewer_proc")
    local dim res label reason req
    while IFS=$'\t' read -r dim res label reason; do
      [ -n "$dim" ] || continue
      req=$(printf '%s' "$independence_req_json" | jq -r --arg d "$dim" '.[$d] // "reported"')
      [ "$req" = required ] || continue
      [ "$res" != PASS ] || continue
      if [ "$res" = FAIL ]; then
        add_viol "$FM_REVIEW_TOKEN_SELF_REVIEW" \
          "independence dimension '$dim' required by role $role" "$label: $reason"
      else
        add_viol independence_unobserved \
          "independence dimension '$dim' required by role $role" \
          "$label: $reason"
      fi
    done <<EOF
$(fm_independence_each_dimension "$indep")
EOF
  fi

  # 5. THE REVIEWED ARTIFACT. Every review names the artifact it reads. A
  # change review of another head or of stale bytes
  # does not satisfy the obligation, so the head is an input rather than
  # something recorded afterwards.
  if [ -z "$head" ]; then
    add_viol review_target_unidentified \
      "--reviewed-head naming the review target" \
      "absent; no review can be shown to have read an assigned artifact"
  elif [[ $head == *[[:space:]]* ]] || [[ $head == *$'\n'* ]] || [[ $head == *$'\r'* ]]; then
    add_viol review_target_unencodable \
      "a non-empty whitespace-free target identifier" "$head"
  elif [ "$requires_head" = true ]; then
    if [[ ! $head =~ ^[0-9a-fA-F]{40}$ ]]; then
      add_viol reviewed_head_invalid \
        "a full 40-character commit id" "$head"
    elif [ -z "$candidate_worktree" ]; then
      add_viol candidate_worktree_unobserved \
        "--candidate-worktree identifying the artifact whose head is reviewed" \
        "absent; the reviewed commit cannot be bound to candidate bytes"
    else
      local candidate_head candidate_status
      candidate_head=$(git -C "$candidate_worktree" rev-parse --verify HEAD 2>/dev/null) \
        || die_unevaluable "$candidate_worktree has no readable git HEAD, so the reviewed commit cannot be verified"
      if [ "${head,,}" != "${candidate_head,,}" ]; then
        add_viol reviewed_head_mismatch \
          "candidate worktree HEAD $candidate_head" "$head"
      fi
      candidate_status=$(git -C "$candidate_worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null) \
        || die_unevaluable "$candidate_worktree has no readable worktree status, so its bytes cannot be bound to the reviewed commit"
      if [ -n "$candidate_status" ]; then
        add_viol candidate_worktree_dirty \
          "a clean candidate worktree whose bytes equal commit $candidate_head" \
          "tracked or untracked changes make the candidate differ from the reviewed commit"
      fi
    fi
  fi

  # 6. THE ROUTE, when this home enforces routed pools. Asked of the routing
  # library rather than re-decided here.
  local route_note='' rc=0
  if [ -n "$route" ]; then
    fm_route_pools_configured "$CONFIG" && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      local decision drc=0 refusal
      decision=$(fm_route_decision "$CONFIG" "$route" "$reviewer" "$effort" "$STATE") || drc=$?
      if [ "$drc" -ne 0 ]; then
        route_note=$(fm_route_undetermined_refusal "$drc" "$CONFIG" "$STATE")
        add_viol route_undetermined "a readable routing decision for route $route" "$route_note"
      elif ! refusal=$(fm_route_refusal_from_decision "$CONFIG" "$route" "$reviewer" "$decision" "$STATE"); then
        add_viol route_refused "route $route admits this reviewer" "$(printf '%s' "$refusal" | tr '\n' ' ')"
      else
        route_note="route $route admits $reviewer"
      fi
    else
      route_note="this home configures no routed pool, so --route $route was recorded and not checked"
    fi
  fi

  # 7. POLICY CONTRADICTION. A config that both authorises and forbids the
  # reviewer's membership has no single answer; reporting it as eligible would
  # be quoting the clause that agrees.
  local contra='[]' cfg_file
  cfg_file=$(fm_route_config_path "$CONFIG")
  if [ -f "$cfg_file" ]; then
    contra=$(jq -c "$RECONCILE_JQ" "$cfg_file" 2>/dev/null) \
      || die_unevaluable "$cfg_file could not be parsed, so its policy contradictions could not be evaluated"
    if [ "$(printf '%s' "$contra" | jq --arg m "$reviewer" '[.[] | select(.model == $m)] | length')" != 0 ]; then
      add_viol "$FM_REVIEW_TOKEN_CONTRADICTION" \
        "one answer about which routes may contain $reviewer" \
        "$cfg_file claims it exclusive to a route it is not exclusive to; run fm-review-role.sh reconcile"
    fi
  fi

  local n
  n=$(printf '%s' "$viols" | jq 'length')
  if [ "$json" -eq 1 ]; then
    jq -n --arg role "$role" --arg act "$activity" --arg rev "$reviewer" --arg mk "$maker" \
          --arg h "$harness" --arg mech "$ro_mech" --arg flags "$ro_flags" --arg head "$head" \
          --argjson v "$viols" --argjson n "$n" \
      '{schema:"fm-review-assignment.v1", role:$role, activity:$act,
        reviewer:$rev, maker:(if $mk == "" then null else $mk end), harness:$h,
        readonly_mechanism:(if $mech == "" then null else $mech end),
        readonly_flags:(if $flags == "" then null else $flags end),
        reviewed_head:(if $head == "" then null else $head end),
        violations:$v, eligible:($n == 0)}'
  elif [ "$n" = 0 ]; then
    printf 'ELIGIBLE: %s may perform %s review role %s of %s work, launched read-only on %s (%s: %s)\n' \
      "$reviewer" "$activity" "$role" "$maker" "$harness" "$ro_mech" "$ro_flags"
    [ -z "$route_note" ] || printf '  %s\n' "$route_note"
  else
    printf 'REFUSED: %s may not be assigned review role %s%s:\n' \
      "$reviewer" "$role" "$([ -z "$maker" ] || printf ' for work made by %s' "$maker")"
    printf '%s' "$viols" | jq -r '.[] | "  " + .rule + ": requires " + .configured + "; observed " + .observed'
  fi
  [ "$n" = 0 ] || exit 1
  exit 0
}

# ---------------------------------------------------------------------------
# assignment: the RETROSPECTIVE half, and the reason it exists as a separate
# subcommand rather than a flag on check.
#
#   check       may this reviewer be assigned? Answered BEFORE anything runs.
#   assignment  what does the durable record establish about one that was?
#
# Collapsing them is the defect this closes. A dispatch that passed check wrote
# review_role= into the task's metadata and nothing ever read it again, so the
# presence of that field was the only thing between a later reader and the
# conclusion that a review had happened - a conclusion drawn from an intention.
#
#   A process invocation is not proof that the intended agent role started.
#   Absence of mutation is not proof that read-only enforcement worked if the
#   reviewer never successfully started.
#
# So this command refuses the inference "produced no writes -> reviewed", and
# requires all seven facts in the schema's assignment_evidence. Six established
# and one missing is could-not-observe, which leaves the review requirement
# UNSATISFIED rather than waived, assumed, or degraded to a warning.
#
# It prints a bin/fm-verify-lib.sh result record, so a consumer reads it through
# fm_verify_case and cannot write a two-branch read of a three-valued answer.

meta_field() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# The launch-outcome vocabulary borrows from two existing owners and owns
# nothing itself, so this refuses a schema that has quietly grown a sixth
# vocabulary: every result must be a value of bin/fm-verify-lib.sh's three-valued
# observation type, and every maps_to must be a unified state that
# loopspecs/terminal-states.json actually declares. An unreadable terminal-state
# file is could-not-observe and refuses too - it is never assumed to agree.
TERMINAL_STATES=${FM_TERMINAL_STATES_OVERRIDE:-$FM_ROOT/loopspecs/terminal-states.json}

launch_outcomes_admissible() {
  local bad
  [ -f "$TERMINAL_STATES" ] \
    || die_unevaluable "$TERMINAL_STATES is unreadable, so the launch outcomes cannot be shown to reuse the unified terminal-state vocabulary rather than invent a sixth"
  # Each outcome is bound to $o BEFORE it is inspected: a bare "." inside a
  # function argument here would refer to the piped value rather than the
  # outcome, which is exactly the rebinding that once made a detector on this
  # branch report a self-contradicting configuration as clean.
  bad=$(jq -r --slurpfile ts "$TERMINAL_STATES" '
      ([$ts[0].unified[].name]) as $known
      | [ .launch_outcomes.outcomes[]?
          | . as $o
          | select((["PASS","FAIL","NO_VERIFIER_RAN"] | index($o.result)) == null
                   or ($known | index($o.maps_to)) == null)
          | $o.name ]
      | join(" ")' "$SCHEMA" 2>/dev/null) \
    || die_unevaluable "$SCHEMA could not be read for its launch outcomes"
  [ -z "$bad" ] \
    || die_unevaluable "$FM_REVIEW_TOKEN_ROLE_INADMISSIBLE: launch outcome(s) $bad do not reuse an existing vocabulary; each result must be a bin/fm-verify-lib.sh value and each maps_to must be declared in $TERMINAL_STATES"
  [ "$(jq -r '[.launch_outcomes.outcomes[]?] | length' "$SCHEMA" 2>/dev/null)" != 0 ] \
    || die_unevaluable "$FM_REVIEW_TOKEN_ROLE_INADMISSIBLE: $SCHEMA declares no launch outcomes, so no launch result could be read and every review would rest on the spawn having been attempted"
}

# The outcome vocabulary is READ FROM THE SCHEMA rather than written here, so
# deleting an outcome or inverting its result changes what this command does.
launch_outcome_result() {  # <name> -> PASS|FAIL|NO_VERIFIER_RAN
  local r
  r=$(jq -r --arg n "$1" \
    '.launch_outcomes.outcomes[]? | select(.name == $n) | .result' "$SCHEMA" 2>/dev/null) || return 1
  case "$r" in
    PASS|FAIL|NO_VERIFIER_RAN) printf '%s' "$r" ;;
    *) return 1 ;;
  esac
}

task_review_execution() {  # <status-path> <role> <target>
  local line execution=''
  [ -f "$1" ] || return 1
  while IFS= read -r line; do
    fm_status_event_parse "$line" || continue
    [ "$FM_STATUS_EVENT_KEY" = review-execution ] || continue
    [ "$FM_STATUS_EVENT_PHASE" = "$2" ] || continue
    [ "$FM_STATUS_EVENT_EVIDENCE" = "$3" ] || continue
    case "$FM_STATUS_EVENT_VERB" in done) execution=done ;; failed) execution=failed ;; esac
  done <"$1"
  [ -n "$execution" ] || return 1
  printf '%s' "$execution"
}

cmd_capture() {
  local task='' kind='' want='' a capture
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in task) task=$a ;; kind) kind=$a ;; esac
      want=''
      continue
    fi
    case "$a" in --task) want=task ;; --task=*) task=${a#--task=} ;; --kind) want=kind ;; --kind=*) kind=${a#--kind=} ;; *) die_unevaluable "unknown argument to capture: $a" ;; esac
  done
  [ -n "$task" ] && [ -n "$kind" ] || die_unevaluable "capture requires --task and --kind"
  capture=$(cat)
  capture_review_artifact "$task" "$kind" "$capture" || return 2
}

cmd_assignment() {
  local task='' json=0 want='' a
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in task) task=$a ;; esac
      want=''
      continue
    fi
    case "$a" in
      --task) want=task ;;
      --task=*) task=${a#--task=} ;;
      --json) json=1 ;;
      *) die_unevaluable "unknown argument to assignment: $a" ;;
    esac
  done
  [ -z "$want" ] || die_unevaluable "--$want requires a value"
  [ -n "$task" ] || die_unevaluable "assignment requires --task"
  launch_outcomes_admissible

  local meta=$STATE/$task.meta
  [ -f "$meta" ] && [ ! -L "$meta" ] \
    || die_unevaluable "$FM_REVIEW_TOKEN_ASSIGNMENT_UNPROVED: $meta is not a readable durable record, so nothing establishes that a review happened"

  local binding role mech flags launch head verdict='' opened=0 execution='' artifact ack_path verdict_path ack_raw verdict_raw
  binding=$(meta_field "$meta" model)
  role=$(meta_field "$meta" review_role)
  mech=$(meta_field "$meta" review_readonly_mechanism)
  flags=$(meta_field "$meta" review_readonly_flags)
  launch=$(meta_field "$meta" review_launch)
  head=$(meta_field "$meta" reviewed_head)

  [ -n "$role" ] \
    || die_unevaluable "$FM_REVIEW_TOKEN_ASSIGNMENT_UNPROVED: $meta records no review_role=, so this task claims no review obligation and none may be read into it"

  # The declared role decides whether a pinned head is one of the seven facts.
  local requires_head=false file
  file=$(role_path "$role") || die_unevaluable "$FM_REVIEW_TOKEN_ROLE_UNKNOWN: $role"
  local missing='[]'
  add_missing() {  # <fact> <why>
    missing=$(printf '%s' "$missing" | jq -c --arg f "$1" --arg w "$2" '. + [{fact:$f, observed:$w}]')
  }
  if [ ! -f "$file" ]; then
    add_missing intended_role "review_role=$role does not resolve to a role in $ROLES"
  else
    local rv
    if rv=$(role_violations "$file" "$role") && [ "$(printf '%s' "$rv" | jq 'length')" = 0 ]; then
      requires_head=$(jq -r '.requires_pinned_head // false' "$file")
    else
      add_missing intended_role "review_role=$role does not satisfy $SCHEMA, so the contract it claims to discharge cannot be read"
    fi
  fi

  ack_path=$(review_artifact_path "$task" acknowledgement)
  verdict_path=$(review_artifact_path "$task" verdict)
  ack_raw=$(review_artifact_raw_path "$task" acknowledgement)
  verdict_raw=$(review_artifact_raw_path "$task" verdict)
  if [ ! -s "$verdict_path" ]; then
    local backend target capture
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    if [ -n "$target" ]; then
      capture=$(fm_backend_capture "$backend" "$target" 240 "$task" 2>/dev/null) || capture=''
      [ -z "$capture" ] || capture_review_artifact "$task" verdict "$capture" || true
    fi
  fi
  if [ -s "$ack_raw" ] && artifact=$(review_artifact_filter acknowledgement "$binding" "$role" "$head" "$task" < "$ack_raw" 2>/dev/null) \
    && [ "$artifact" = "$(cat "$ack_path" 2>/dev/null)" ]; then
    opened=1
  fi
  if [ -s "$verdict_raw" ] && artifact=$(review_artifact_filter verdict "$binding" "$role" "$head" "$task" < "$verdict_raw" 2>/dev/null) \
    && [ "$artifact" = "$(cat "$verdict_path" 2>/dev/null)" ]; then
    verdict=$(printf '%s' "$artifact" | jq -r '.verdict')
  fi
  execution=$(task_review_execution "$STATE/$task.status" "$role" "$head") || execution=''

  [ -n "$binding" ] || add_missing intended_binding "the record names no model= so the reviewing binding is unknown"
  { [ -n "$mech" ] && [ -n "$flags" ]; } \
    || add_missing readonly_authority_active "the record carries no enforced read-only launch binding; an instruction not to write is not this fact"
  if [ -z "$head" ]; then
    add_missing review_target_commit "the record names no reviewed_head= target identifier"
  elif [ "$requires_head" = true ]; then
    if [[ ! $head =~ ^[0-9a-fA-F]{40}$ ]]; then
      add_missing review_target_commit "reviewed_head=$head is not a full commit id"
    else
      local recorded_worktree current_head
      recorded_worktree=$(meta_field "$meta" worktree)
      current_head=$(git -C "$recorded_worktree" rev-parse --verify HEAD 2>/dev/null) || current_head=''
      [ -n "$current_head" ] && [ "${current_head,,}" = "${head,,}" ] \
        || add_missing review_target_commit "the current candidate commit does not equal reviewed_head=$head"
    fi
  fi
  [ "$opened" = 1 ] || add_missing role_established "no reviewer-authored opening event agrees with role=$role and target=$head"
  [ -n "$verdict" ] || add_missing review_result "no attributable structured verdict artifact is pinned to this assignment and target"

  # THE LAUNCH OUTCOME, consumed rather than inferred. An absent one is the
  # defect this task exists to close: it means the caller concluded a review
  # from a spawn having been attempted.
  local lresult='' reason='' outcome=''
  if [ -z "$launch" ]; then
    outcome=could_not_observe
    lresult=NO_VERIFIER_RAN
    reason="$FM_REVIEW_TOKEN_LAUNCH_NOT_CONSUMED: the record carries no review_launch= so the launch outcome was never observed; a spawn having been attempted is not a review"
  elif ! lresult=$(launch_outcome_result "$launch"); then
    outcome=could_not_observe
    lresult=NO_VERIFIER_RAN
    reason="review_launch=$launch is not an outcome declared in $SCHEMA so it cannot be read"
  else
    outcome=$launch
  fi

  local n n_without_result
  n=$(printf '%s' "$missing" | jq 'length')
  n_without_result=$(printf '%s' "$missing" | jq '[.[] | select(.fact != "review_result")] | length')

  # role_established is strictly stronger than launch_result: a live agent that
  # never took its instructions is alive and reviewing nothing, and the review
  # result is what separates them.
  local result
  if [ "$lresult" = FAIL ]; then
    result=FAIL
    reason="the reviewer did not run: launch outcome $outcome"
  elif [ "$lresult" = NO_VERIFIER_RAN ]; then
    result=NO_VERIFIER_RAN
    [ -n "$reason" ] || reason="the launch outcome could not be observed: $outcome"
  elif [ "$outcome" != "$FM_REVIEW_LAUNCH_OK" ]; then
    # The contract calls this outcome a pass, but only one outcome establishes
    # the role. Both must agree, so a contract that relabels some other outcome
    # a pass cannot smuggle it through as an established review.
    result=NO_VERIFIER_RAN
    reason="outcome $outcome is recorded as a pass but $FM_REVIEW_LAUNCH_OK is the only outcome that establishes the role"
  elif [ "$opened" != 1 ]; then
    result=NO_VERIFIER_RAN
    reason="the reviewer role was not established from reviewer-authored evidence"
  elif [ "$n_without_result" != 0 ]; then
    result=NO_VERIFIER_RAN
    reason="the launch established the role but the assignment is not proved: $(printf '%s' "$missing" | jq -r '[.[].fact] | join(" ")') not established"
  else
    case "$execution:$verdict" in
      done:approve) result=PASS; reason="all seven assignment facts established with launch outcome $outcome" ;;
      done:reject) result=FAIL; reason="the reviewer recorded a negative verdict" ;;
      done:) result=NO_VERIFIER_RAN; reason="completed review execution carried no verdict" ;;
      failed:reject) result=FAIL; reason="the failed review run recorded a validated negative verdict" ;;
      failed:approve) result=NO_VERIFIER_RAN; reason="failed review execution cannot support its captured approval" ;;
      failed:) result=NO_VERIFIER_RAN; reason="failed review execution carried no verdict" ;;
      *) die_unevaluable "FM_REVIEW_EXECUTION_VERDICT_UNENUMERATED: execution=${execution:-absent} verdict=${verdict:-absent}" ;;
    esac
  fi

  if [ "$json" -eq 1 ]; then
    jq -n --arg t "$task" --arg role "$role" --arg b "$binding" --arg h "$head" \
          --arg mech "$mech" --arg launch "$outcome" --arg v "$verdict" --arg x "$execution" \
          --arg res "$result" --arg why "$reason" --argjson miss "$missing" \
      '{schema:"fm-review-assignment-proof.v1", task:$t, role:$role,
        binding:(if $b == "" then null else $b end),
        readonly_mechanism:(if $mech == "" then null else $mech end),
        reviewed_head:(if $h == "" then null else $h end),
        launch_outcome:$launch, review_execution_state:(if $x == "" then null else $x end),
        review_verdict:(if $v == "" then null else $v end),
        result:$res, reason:$why, unestablished:$miss,
        review_requirement:(if $res == "PASS" then "SATISFIED" else "UNSATISFIED" end)}'
  else
    # bin/fm-verify-lib.sh record shape, so the answer is consumed through
    # fm_verify_case rather than re-read as a two-valued one.
    printf '  review-assignment:%s,%s,%s,%s\n' "$task" "$result" "$reason" "$meta"
    if [ "$result" = PASS ]; then
      printf 'SATISFIED: %s reviewed %s under role %s launched read-only (%s)\n' \
        "$binding" "${head:-the declared artifact}" "$role" "$mech"
    else
      printf 'UNSATISFIED: the review requirement for %s is not discharged by this record\n' "$task"
      [ "$n" = 0 ] || printf '%s' "$missing" | jq -r '.[] | "  " + .fact + ": " + .observed'
    fi
  fi

  case "$result" in
    PASS) exit 0 ;;
    FAIL) exit 1 ;;
    *) exit 2 ;;
  esac
}

# ---------------------------------------------------------------------------

case "${1:-}" in
  -h|--help|'') usage; exit 0 ;;
  list)
    shift
    if [ "${1:-}" = --json ]; then
      role_ids | jq -R -s -c 'split("\n") | map(select(length>0)) | {schema:"fm-review-roles.v1", roles:.}'
    else
      role_ids
    fi
    ;;
  show)
    shift
    [ -n "${1:-}" ] || die_unevaluable "show requires a role id"
    role_id_valid "$1" || die_unevaluable "$FM_REVIEW_TOKEN_ROLE_UNKNOWN: role ids must be lowercase hyphen-separated slugs"
    f=$(role_path "$1")
    [ -f "$f" ] || { echo "error: $FM_REVIEW_TOKEN_ROLE_UNKNOWN: no review role '$1'. Defined: $(role_ids | tr '\n' ' ')" >&2; exit 2; }
    v=$(role_violations "$f" "$1")
    if [ "$(printf '%s' "$v" | jq 'length')" != 0 ]; then
      echo "error: $FM_REVIEW_TOKEN_ROLE_INADMISSIBLE: '$1' does not satisfy $SCHEMA:" >&2
      render_violations "$v" "$1" >&2
      exit 2
    fi
    jq . "$f"
    ;;
  harness-readonly) shift; cmd_harness_readonly "$@" ;;
  reconcile) shift; cmd_reconcile "${1:-}" ;;
  check) shift; cmd_check "$@" ;;
  assignment) shift; cmd_assignment "$@" ;;
  capture) shift; cmd_capture "$@" ;;
  *) echo "error: unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
