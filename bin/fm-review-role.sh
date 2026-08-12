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

# Stable refusal tokens, matched by tests and callers rather than prose.
FM_REVIEW_TOKEN_ROLE_UNKNOWN=FM_REVIEW_ROLE_UNKNOWN
FM_REVIEW_TOKEN_ROLE_INADMISSIBLE=FM_REVIEW_ROLE_INADMISSIBLE
FM_REVIEW_TOKEN_NO_READONLY=FM_REVIEW_NO_READONLY_BINDING
FM_REVIEW_TOKEN_SELF_REVIEW=FM_REVIEW_SELF_REVIEW_REFUSED
FM_REVIEW_TOKEN_MAKER_UNKNOWN=FM_REVIEW_MAKER_IDENTITY_MISSING
FM_REVIEW_TOKEN_NOT_QUALIFIED=FM_REVIEW_BINDING_NOT_QUALIFIED
FM_REVIEW_TOKEN_CONTRADICTION=FM_REVIEW_POLICY_CONTRADICTION

usage() {
  cat <<'EOF'
Usage:
  fm-review-role.sh list [--json]
  fm-review-role.sh show <role> [--json]
  fm-review-role.sh harness-readonly [<harness>] [--json]
  fm-review-role.sh reconcile [--json]
  fm-review-role.sh check --role <id> --reviewer <provider/model> --harness <name>
                          [--effort <level>] [--maker <provider/model>]
                          [--maker-process <id>] [--reviewer-process <id>]
                          [--reviewed-head <sha>] [--route <ROUTE>] [--json]

check answers one question: may this reviewer be assigned to this maker's
artifact, on this harness? Every input it needs is an input, not an assumption -
a missing maker identity is could-not-observe and refuses, it does not default
to eligible.

reconcile reads this home's routing config and reports pooled models whose
actual route membership contradicts an exclusivity claim the same file makes
about them in prose. It changes nothing.

harness-readonly reports which harnesses this repo has MEASURED a read-only
launch binding for. A harness with no record may not host a read-only role.

Exit status: 0 eligible, 1 refused (a violation was observed), 2 unevaluable
(could-not-observe). Both non-zero values fail closed.
EOF
}

die_unevaluable() { echo "error: $*" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || die_unevaluable "jq is required to read review-roles/"
[ -d "$ROLES" ] || die_unevaluable "$ROLES does not exist, so no review role can be read; this is could-not-observe, never an absent obligation"
SCHEMA=$ROLES/schema.json
[ -f "$SCHEMA" ] || die_unevaluable "$SCHEMA is missing, so no role can be validated against its contract"

role_path() { printf '%s/%s.json\n' "$ROLES" "$1"; }

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
       end)
    ]'

role_violations() {  # <role-file> -> JSON array
  jq -c -s "$ROLE_VIOLATIONS_JQ" "$SCHEMA" "$1" 2>/dev/null
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
  local head='' route='' json=0 want=''
  local a
  for a in "$@"; do
    if [ -n "$want" ]; then
      case "$want" in
        role) role=$a ;; reviewer) reviewer=$a ;; harness) harness=$a ;;
        effort) effort=$a ;; maker) maker=$a ;; maker-process) maker_proc=$a ;;
        reviewer-process) reviewer_proc=$a ;; reviewed-head) head=$a ;; route) route=$a ;;
      esac
      want=''
      continue
    fi
    case "$a" in
      --role|--reviewer|--harness|--effort|--maker|--maker-process|--reviewer-process|--reviewed-head|--route)
        want=${a#--} ;;
      --role=*) role=${a#--role=} ;;
      --reviewer=*) reviewer=${a#--reviewer=} ;;
      --harness=*) harness=${a#--harness=} ;;
      --effort=*) effort=${a#--effort=} ;;
      --maker=*) maker=${a#--maker=} ;;
      --maker-process=*) maker_proc=${a#--maker-process=} ;;
      --reviewer-process=*) reviewer_proc=${a#--reviewer-process=} ;;
      --reviewed-head=*) head=${a#--reviewed-head=} ;;
      --route=*) route=${a#--route=} ;;
      --json) json=1 ;;
      *) die_unevaluable "unknown argument to check: $a" ;;
    esac
  done
  [ -z "$want" ] || die_unevaluable "--$want requires a value"
  [ -n "$role" ] || die_unevaluable "check requires --role"
  [ -n "$reviewer" ] || die_unevaluable "check requires --reviewer"
  [ -n "$harness" ] || die_unevaluable "check requires --harness; the read-only binding is a property of the harness, so an unnamed one cannot be checked"

  local file
  file=$(role_path "$role")
  if [ ! -f "$file" ]; then
    echo "error: $FM_REVIEW_TOKEN_ROLE_UNKNOWN: no review role '$role' in $ROLES. Defined: $(role_ids | tr '\n' ' ')" >&2
    exit 2
  fi
  local rv
  rv=$(role_violations "$file") || die_unevaluable "$file could not be parsed against $SCHEMA"
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
  elif [ -n "$effort" ]; then
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

  # 5. THE REVIEWED ARTIFACT. A change review of another head or of stale bytes
  # does not satisfy the obligation, so the head is an input rather than
  # something recorded afterwards.
  if [ "$requires_head" = true ] && [ -z "$head" ]; then
    add_viol reviewed_head_unpinned \
      "--reviewed-head, because role $role reviews the exact change before landing" \
      "absent; a review not pinned to a head cannot be shown to have read these bytes"
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
    contra=$(jq -c "$RECONCILE_JQ" "$cfg_file" 2>/dev/null || printf '[]')
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
    f=$(role_path "$1")
    [ -f "$f" ] || { echo "error: $FM_REVIEW_TOKEN_ROLE_UNKNOWN: no review role '$1'. Defined: $(role_ids | tr '\n' ' ')" >&2; exit 2; }
    v=$(role_violations "$f")
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
  *) echo "error: unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
