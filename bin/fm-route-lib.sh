# shellcheck shell=bash
# fm-route-lib.sh - single owner of the ROUTE and ELIGIBLE decisions read out of
# config/crew-dispatch.json, and of the narrow availability record FAILOVER
# writes.
# Usage: . bin/fm-route-lib.sh
#
# WHY THIS EXISTS. The routing policy already states, in prose a human reads,
# which models a route may use, what capability floor each route requires, and
# that a failed primary is replaced only from inside its own pool. Nothing read
# any of it. A dispatch could name a model no pool contains, run it below its
# route's effort floor, or substitute a plausible sibling from another route,
# and the first evidence would be the work coming back wrong. This library is
# the enforced copy of those rules; the prose stays descriptive.
#
# ONE OWNER PER QUESTION, exactly as the policy's own `_interfaces` block names
# the seams:
#
#   ROUTE     this library      which route, which floor, which ordered pool.
#                               Availability-blind by construction: nothing here
#                               reads quota, fleet load, or an outage.
#   ADMIT     bin/fm-admission.sh  whether the fleet accepts another task at all.
#   ELIGIBLE  this library      the route's pool filtered by the floor, by the
#                               availability record, and by the caller's quota
#                               observation, in pool order. It reads records and
#                               merges what the caller hands it; it never probes
#                               a provider itself, so the shape of this seam is
#                               unchanged - bin/fm-capacity-lib.sh owns the
#                               observation exactly as the model registry owns
#                               cost and reachability.
#   FAILOVER  this library      the ONLY writer of availability state, and it
#                               writes availability alone. A model that keeps
#                               failing is recorded UNAVAILABLE, never demoted;
#                               demotion is a policy change and needs review.
#
# What this library deliberately does NOT own: whether a model may be paid for
# at all, whether the account may reach it, and how many of it may run at once.
# bin/fm-model-registry-lib.sh has owned those since the model registry landed,
# it is already enforced at the spawn chokepoint, and eligibility COMPOSES it
# rather than re-deciding it.
#
# NOT ENFORCED, and it is worth saying why rather than leaving it to be
# rediscovered: config/models.json's per-model `eligible_routes` and
# `prohibited_routes` look like exactly this check and cannot be run as one
# today, because the two files name routes in two different vocabularies. The
# registry's older entries carry tier slugs ("t2-substantive", "t1-risk",
# "long-context-specialist") while its newest entry and every rule here carry
# route ids ("R2-LONGCTX", "R3-MED"), and no mapping between them exists. Wiring
# them together before one vocabulary wins would refuse correct dispatches
# wholesale - the routing policy's own primary at four routes records neither of
# those routes in its registry entry. Reconciling the two is a change to the
# registry, owned by model-onboarding, not something to paper over here.
#
# ENFORCEMENT SCOPE - the same deliberate asymmetry the model registry uses:
#
#   No routed pool configured -> inert. A home whose config/crew-dispatch.json is
#                                absent, or which uses only the documented
#                                harness/model/effort profile schema with no
#                                `pool`, behaves exactly as it did before this
#                                existed. Nothing to check is not a refusal.
#   A routed pool configured   -> fail closed. A dispatch must name the route it
#                                claims, and an unreadable config, an unreadable
#                                availability record, an unknown route, a
#                                duplicate route id, an unstated model, a floor
#                                id `_floors` does not define, a floor axis whose
#                                configured value is outside its closed
#                                vocabulary, a floor axis whose evidence is
#                                missing, and a model the availability record
#                                holds all REFUSE. A safety file that cannot be
#                                read must never read as an absent one, and an
#                                input that is missing must never read as an
#                                input that passed.
#
# Every refusal names the violated rule: the route, the exact JSON config path,
# the configured value, and the observed value. A refusal a reader cannot trace
# back to a line of policy is a refusal nobody can fix.
#
# LUNA MAX PROFILE. The production binding is the exact profile
# openai-codex/gpt-5.6-luna on a supported Pi-family harness with effective max effort. This library owns
# the executable invariant because the same decision feeds check, eligible,
# failover and the spawn chokepoint. A routed Luna pool or primary profile must
# keep the max lock, max-expressible evidence, max floor, max route profile
# effort, and a verified Pi-family harness, or the route refuses before launch.
#
# docs/configuration.md "Crew dispatch profiles" owns the config schema and
# "Model availability record" owns state/model-health.json. This header owns the
# mechanics.

# Idempotent guard: fm-spawn.sh and fm-route.sh may both be in one process tree.
if [ -n "${FM_ROUTE_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_ROUTE_LIB_SOURCED=1

# Reuse the fleet's portable lock owner rather than introducing a second lock
# implementation or a platform-specific flock dependency. fm-spawn.sh already
# sources this library, so only the standalone route command needs this import.
if ! declare -F fm_lock_acquire_wait >/dev/null 2>&1; then
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$(dirname "${BASH_SOURCE[0]}")/fm-wake-lib.sh"
fi

# The availability record's only schema, and the closed state vocabulary it
# accepts. Every state is one a `_failover.conditions.*.sets` value names, so a
# recorded hold always traces back to a condition the policy defines. An
# unknown state is refused rather than stored: a vocabulary that grows at the
# call site cannot be reported on.
FM_ROUTE_HEALTH_SCHEMA='fm-model-health.v1'
FM_ROUTE_HEALTH_STATES='degraded
rate_limited
model_unavailable
provider_unavailable
auth_failure
subscription_quota_exhausted
daily_quota_exhausted
admin_disabled'

# Stable refusal tokens. Tests and callers match these rather than prose.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_ROUTE_TOKEN_REQUIRED=FM_SPAWN_ROUTE_REQUIRED
FM_ROUTE_TOKEN_UNKNOWN=FM_SPAWN_ROUTE_UNKNOWN
FM_ROUTE_TOKEN_UNREADABLE=FM_SPAWN_ROUTE_UNREADABLE
FM_ROUTE_TOKEN_HEALTH_UNREADABLE=FM_ROUTE_HEALTH_UNREADABLE
FM_ROUTE_TOKEN_AMBIGUOUS=FM_SPAWN_ROUTE_AMBIGUOUS
FM_ROUTE_TOKEN_FLOOR_MISMATCH=FM_SPAWN_ROUTE_FLOOR_MISMATCH
FM_ROUTE_TOKEN_POOL=FM_SPAWN_ROUTE_POOL_VIOLATION
FM_ROUTE_TOKEN_FLOOR=FM_SPAWN_ROUTE_FLOOR_VIOLATION
FM_ROUTE_TOKEN_PROFILE=FM_SPAWN_ROUTE_PROFILE_VIOLATION
FM_ROUTE_TOKEN_HELD=FM_SPAWN_ROUTE_MODEL_HELD
FM_ROUTE_TOKEN_NO_CANDIDATE=FM_ROUTE_NO_CANDIDATE
FM_ROUTE_TOKEN_HEALTH_STATE=FM_ROUTE_HEALTH_STATE_UNKNOWN
FM_ROUTE_TOKEN_HOLD_SUBJECT=FM_ROUTE_HOLD_SUBJECT_UNRESOLVED
}

# Where a route may be defined, spelled ONCE so every reader agrees. A route id
# comes from a `rules[]` entry or from the top-level `default` in either its
# object or its array form, and anything that may name a route may also name a
# pool. Two readers disagreeing about where a route lives is how a home ends up
# enforced by one command and inert at the chokepoint.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_ROUTE_ENTRIES_JQ='
def route_entries:
  [ (.rules // []) | to_entries[]?
    | select((.value.route? | type) == "string")
    | {id: .value.route, path: ("/rules/" + (.key | tostring)), rule: .value, source: "rule"} ]
  + ( (.default // null) as $d
      | if ($d | type) == "object" and (($d.route? | type) == "string")
        then [{id: $d.route, path: "/default", rule: $d, source: "default"}]
        elif ($d | type) == "array"
        then [ $d | to_entries[] | select((.value.route? | type) == "string")
               | {id: .value.route, path: ("/default/" + (.key | tostring)), rule: .value, source: "default"} ]
        else [] end );
'

# ---------------------------------------------------------------------------
# Location and presence
# ---------------------------------------------------------------------------

fm_route_config_path() {  # [<config-dir>]
  local cfg=${1:-}
  [ -n "$cfg" ] || cfg="${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}}"
  printf '%s\n' "$cfg/crew-dispatch.json"
}

fm_route_health_path() {  # [<state-dir>]
  local st=${1:-}
  [ -n "$st" ] || st="${STATE:-${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}}"
  printf '%s\n' "$st/model-health.json"
}

# The writer lock is beside the record, so every process that names this
# canonical record resolves the same portable lock regardless of its caller.
fm_route_health_lock_path() {  # [<state-dir>]
  printf '%s.lock\n' "$(fm_route_health_path "${1:-}")"
}

# True when this home's dispatch config carries at least one route that names an
# ordered pool. That, and only that, is what turns enforcement on: the schema
# documented for every other home has no `pool`, so those homes stay inert.
# Exit 0 = enforcing, 1 = nothing to enforce, 2 = the file exists but cannot be
# read, which is unverifiable rather than empty.
fm_route_pools_configured() {  # [<config-dir>]
  local file answer
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  answer=$(jq -r "$FM_ROUTE_ENTRIES_JQ"'
    [ route_entries[]
      | select((.rule.pool? | type) == "array" and ((.rule.pool | length) > 0)) ] | length > 0
  ' "$file" 2>/dev/null) || return 2
  [ "$answer" = true ]
}

# Every model any routed pool lists, one per line. The availability record is
# only useful against these: a hold on anything else can never remove a
# candidate, so recording one would report success for nothing.
fm_route_pool_models() {  # [<config-dir>]
  local file
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r "$FM_ROUTE_ENTRIES_JQ"'
    [ route_entries[] | .rule.pool? | select(type == "array") | .[] | select(type == "string") ]
    | unique | .[]
  ' "$file" 2>/dev/null || return 2
}

# A content digest of the surface this library actually enforces, so a recorded
# dispatch can be proved against the exact policy that checked it. The prose
# `_policy.version` string is deliberately not used: it is maintained by hand
# and has been observed stale, while this cannot be.
fm_route_policy_digest() {  # [<config-dir>]
  local file surface sum
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || { printf 'unconfigured\n'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unreadable\n'; return 0; }
  surface=$(jq -S -c '{rules: (.rules // []), default: (.default // null),
                       floors: (._floors // {}), models: (._models // {})}' "$file" 2>/dev/null) \
    || { printf 'unreadable\n'; return 0; }
  if command -v sha256sum >/dev/null 2>&1; then
    sum=$(printf '%s' "$surface" | sha256sum | awk '{print $1}')
  elif command -v shasum >/dev/null 2>&1; then
    sum=$(printf '%s' "$surface" | shasum -a 256 | awk '{print $1}')
  else
    printf 'unavailable\n'; return 0
  fi
  printf 'sha256:%s\n' "${sum:0:16}"
}

# ---------------------------------------------------------------------------
# The decision program
# ---------------------------------------------------------------------------

# One jq program answers every route question, so the floor axes are spelled
# exactly once and a check and an eligibility listing can never disagree about
# what a floor means. It takes the config as input plus $route, $model, $effort,
# $holds and $now, and prints a decision record.
#
# The three mechanically checkable axes are the ones the policy's own
# `_floors._axes._mechanically_checkable` block names: effort, context, and tool
# loop. The six axes it lists as judged at admission are deliberately NOT
# checked here - reading a passing floor check as evidence on them is the exact
# mistake that block exists to prevent.
#
# A MISSING INPUT IS A VIOLATION, never a skipped check. An unstated model, a
# floor id `_floors` does not define, and a candidate with no recorded evidence
# for an axis the floor declares all produce a named violation carrying the
# config path the evidence is missing from. Enforcement that quietly does
# nothing when an input is absent is indistinguishable from no enforcement, and
# the absent input is exactly the case nobody tests by hand.
#
# AN UNINTERPRETABLE FLOOR IS THE SAME CLASS, and every axis treats it the same
# way: a `tool_loop` or `context_ceiling` or `effort_floor` whose configured
# value is outside its closed vocabulary is refused by name rather than skipped.
# A misspelling - `verified_agentic` for `verified-agentic` - is the likeliest
# way a floor ever reaches this code, and an axis that silently enforces nothing
# for it is a floor an operator believes is armed.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_ROUTE_DECISION_JQ="$FM_ROUTE_ENTRIES_JQ"'
def bands: ["low","medium","high","xhigh","max","ultra"];
def rank($b): (if ($b | type) == "string" then (bands | index($b)) else null end);
def loop_rank($v): (if ($v | type) == "string"
                    then {"not-required":0,"required":1,"verified-agentic":2}[$v]
                    else null end);
def provider_of($m): (if ($m | test("/")) then ($m | split("/") | .[0]) else null end);
def luna_max_profile:
  {name:"luna-max", model:"openai-codex/gpt-5.6-luna", effort:"max",
   harnesses:["pi", "pi-signed"]};
def luna_max_model: luna_max_profile.model;
def luna_max_effort: luna_max_profile.effort;
def luna_max_harness_ok($h): (luna_max_profile.harnesses | index($h)) != null;
def route_profiles($rule; $path):
  if (($rule.use? | type) == "array") then
    [ $rule.use | to_entries[]
      | {profile:.value, path:($path + "/use/" + (.key | tostring))} ]
  elif (($rule.use? | type) == "object") then
    [{profile:$rule.use, path:($path + "/use")}]
  elif ($rule | type) == "object" then
    [{profile:$rule, path:$path}]
  else [] end;
def effective_route_profile($rule; $path; $model; $harness):
  (route_profiles($rule; $path)) as $profiles
  | (if ($harness | length) > 0
     then first($profiles[] | select((.profile.model? // "") == $model
                                     and (.profile.harness? // "") == $harness))
     else null end)
    // (if ($harness | length) == 0 and $model == luna_max_model
        then first($profiles[]
                   | select((.profile.model? // "") == $model
                            and luna_max_harness_ok(.profile.harness? // "")
                            and (.profile.effort? // "") == luna_max_effort))
        else null end)
    // first($profiles[] | select((.profile.model? // "") == $model))
    // $profiles[0]?
    // {profile:{}, path:$path};

# A route is DEFINED by a rule. The top-level `default` names which route is the
# default and carries its profile, so a default pointing at an existing rule is
# not a second definition of that route - only a rules[] id used twice is, and
# that one is refused because every check against it would be meaningless.
. as $cfg
| route_entries as $entries
| ($entries | map(select(.source == "rule" and .id == $route))) as $rule_matches
| (if ($rule_matches | length) > 0 then $rule_matches
   else ($entries | map(select(.source == "default" and .id == $route)) | .[0:1]) end) as $matches
| ($cfg._models // null) as $models
| ($matches | length) as $n
| if $n == 0 then
    {schema:"fm-route-decision.v1", route:$route, route_known:false,
     known_routes:($entries | map(.id) | unique)}
  elif $n > 1 then
    {schema:"fm-route-decision.v1", route:$route, route_known:true,
     duplicate_paths:($matches | map(.path))}
  else
    $matches[0] as $entry
    | $entry.rule as $rule
    | $entry.path as $route_path
    | ($rule.floor? // null) as $floor_id
    | ($cfg._floors // {}) as $floors
    | (if ($floor_id != null) then $floors[$floor_id] else null end) as $floor_raw
    | (($floor_id != null) and (($floors | has($floor_id)) | not)) as $floor_undefined
    | (if ($floor_raw | type) == "object" then $floor_raw else {} end) as $floor
    | (if ($floor_id != null) then ("/_floors/" + $floor_id) else null end) as $floor_path
    | (if (($rule.pool? | type) == "array") then $rule.pool else [] end) as $pool
    | ($route_path + "/pool") as $pool_path
    | (effective_route_profile($rule; $route_path; $model; $harness)) as $route_profile
    | ($floor.effort_floor? // null) as $ef_raw
    | (if ($ef_raw | type) == "string" and (rank($ef_raw) != null) then $ef_raw else null end) as $ef
    | (($ef_raw | type) == "string" and ($ef_raw | startswith("WAIVED"))) as $ef_waived
    | (($ef_raw != null) and ($ef == null) and ($ef_waived | not)) as $ef_malformed
    # The band this dispatch is ACTUALLY running at: the effort it named, else
    # the one the floor states. Carried on the record because band preservation
    # across a capacity substitution is judged against the RUNNING band, not
    # against the floor - a route whose floor states no effort_floor still has a
    # band to preserve the moment a dispatch names one.
    | (if ($effort | length) > 0 then $effort else ($ef // "") end) as $eeff
    | ($floor.context_ceiling? // null) as $ctx_raw
    | (if ($ctx_raw | type) == "number" then $ctx_raw else null end) as $ctx
    | (($ctx_raw != null) and ($ctx == null)) as $ctx_malformed
    | ($floor.tool_loop? // null) as $tl_raw
    | (if (loop_rank($tl_raw) != null) then $tl_raw else null end) as $tl
    | (($tl_raw != null) and ($tl == null)) as $tl_malformed
    | (($floor.selectable_by_crew_rule? // true) == false) as $unselectable
    | ($models[luna_max_model]? // {}) as $luna_record
    | def luna_profile_violations($profile):
       [
         (if (($luna_record.effort_lock? // null) != luna_max_effort)
          then {rule:"luna_max_effort_lock", config_path:("/_models/" + luna_max_model + "/effort_lock"),
                configured:luna_max_effort, observed:($luna_record.effort_lock? // "absent")}
          else empty end),
         (if (($luna_record.effort_expressible? // []) | index(luna_max_effort)) == null
          then {rule:"luna_max_effort_unexpressible", config_path:("/_models/" + luna_max_model + "/effort_expressible"),
                configured:"array containing max", observed:($luna_record.effort_expressible? // "absent")}
          else empty end),
         (if ($ef_raw != luna_max_effort)
          then {rule:"luna_max_floor_effort", config_path:(if $floor_path != null then ($floor_path + "/effort_floor") else ($route_path + "/floor") end),
                configured:luna_max_effort, observed:($ef_raw // "absent")}
          else empty end),
         (if (($profile.profile.effort? // null) != luna_max_effort)
          then {rule:"luna_max_profile_effort", config_path:($profile.path + "/effort"),
                configured:luna_max_effort,
                observed:(if ($profile.profile.effort? // null) == null then "provider default" else $profile.profile.effort end)}
          else empty end),
         (if (luna_max_harness_ok($profile.profile.harness? // "") | not)
          then {rule:"luna_max_harness_unverified", config_path:($profile.path + "/harness"),
                configured:"pi or pi-signed", observed:($profile.profile.harness? // "absent")}
          else empty end)
       ];

    def held($m):
        ($holds.models[$m] // null) as $mh
        | (provider_of($m)) as $p
        | (if $p != null then ($holds.providers[$p] // null) else null end) as $ph
        | if $mh != null then ($mh + {scope:"model", subject:$m})
          elif $ph != null then ($ph + {scope:"provider", subject:$p})
          else null end;

    def violations($m; $e; $profile):
        [ (if $m == luna_max_model then luna_profile_violations($profile)[] else empty end),
          (if ($m == luna_max_model) and ($e != luna_max_effort)
           then {rule:"luna_max_effective_effort", config_path:"/profile/luna-max/effort",
                 configured:luna_max_effort,
                 observed:(if (($e | length) == 0) then "provider default" else $e end)}
           else empty end),
          (if ($floor_undefined)
           then {rule:"floor_undefined", config_path:($route_path + "/floor"),
                 configured:$floor_id,
                 observed:("absent: " + $floor_path + " is not defined, so no axis of the claimed floor can be checked")}
           else empty end),
          (if ($unselectable)
           then {rule:"floor_not_selectable", config_path:($floor_path + "/selectable_by_crew_rule"),
                 configured:"false", observed:$m}
           else empty end),
          (if (($pool | length) > 0) and (($pool | index($m)) == null)
           then {rule:"model_not_in_pool", config_path:$pool_path,
                 configured:($pool | join(", ")), observed:$m}
           else empty end),
          (if ($ef != null) and (($e | length) == 0)
           then {rule:"effort_unstated", config_path:($floor_path + "/effort_floor"),
                 configured:$ef, observed:"provider default"}
           elif ($ef != null) and (rank($e) == null)
           then {rule:"effort_unknown_band", config_path:($floor_path + "/effort_floor"),
                 configured:(bands | join(", ")), observed:$e}
           elif ($ef != null) and (rank($e) < rank($ef))
           then {rule:"effort_below_floor", config_path:($floor_path + "/effort_floor"),
                 configured:$ef, observed:$e}
           else empty end),
          (if ($ef_malformed)
           then {rule:"effort_floor_malformed", config_path:($floor_path + "/effort_floor"),
                 configured:($ef_raw | tostring), observed:"unreadable"}
           else empty end),
          (if ($ef != null) and (($e | length) > 0) and (rank($e) != null)
           then ($models[$m].effort_expressible? // null) as $ee
             | if $ee == null
               then {rule:"effort_unverifiable", config_path:("/_models/" + $m + "/effort_expressible"),
                     configured:"an expressible-band array", observed:"absent"}
               elif ($ee | index($e)) == null
               then {rule:"effort_not_expressible", config_path:("/_models/" + $m + "/effort_expressible"),
                     configured:($ee | join(", ")), observed:$e}
               else empty end
           else empty end),
          (if ($ctx != null)
           then ($models[$m].smart_zone? // null) as $sz
             | if ($sz | type) != "number"
               then {rule:"context_unverifiable", config_path:("/_models/" + $m + "/smart_zone"),
                     configured:("at least " + ($ctx | tostring)), observed:"absent"}
               elif $sz < $ctx
               then {rule:"context_below_floor", config_path:($floor_path + "/context_ceiling"),
                     configured:($ctx | tostring), observed:($sz | tostring)}
               else empty end
           else empty end),
          (if ($ctx_malformed)
           then {rule:"context_ceiling_malformed", config_path:($floor_path + "/context_ceiling"),
                 configured:($ctx_raw | tostring), observed:"unreadable"}
           else empty end),
          (if ($tl_malformed)
           then {rule:"tool_loop_malformed", config_path:($floor_path + "/tool_loop"),
                 configured:($tl_raw | tostring), observed:"unreadable"}
           else empty end),
          (if ($tl != null) and (loop_rank($tl) > 0)
           then ($models[$m].tool_loop? // null) as $mt
             | if (loop_rank($mt) == null)
               then {rule:"tool_loop_unverifiable", config_path:("/_models/" + $m + "/tool_loop"),
                     configured:$tl, observed:($mt // "absent" | tostring)}
               elif (loop_rank($mt) < loop_rank($tl))
               then {rule:"tool_loop_below_floor", config_path:($floor_path + "/tool_loop"),
                     configured:$tl, observed:$mt}
               else empty end
           else empty end) ];

    def resolve($want):
        if ($want | length) == 0 then {resolved:null, resolution:"unstated"}
        elif (($pool | index($want)) != null) then {resolved:$want, resolution:"exact"}
        elif ($want | test("/")) then {resolved:$want, resolution:"qualified"}
        else ([ $pool[] | select(endswith("/" + $want)) ]) as $s
          | if ($s | length) == 1 then {resolved:$s[0], resolution:"suffix"}
            elif ($s | length) > 1 then {resolved:null, resolution:"ambiguous", matches:$s}
            else {resolved:$want, resolution:"bare"} end
        end;

    {schema:"fm-route-decision.v1",
     route:$route, route_known:true, route_path:$route_path,
     floor:$floor_id, floor_path:$floor_path, floor_defined:($floor_undefined | not),
     floor_axes:{effort_floor:$ef, effort_waived:$ef_waived, context_ceiling:$ctx,
                 tool_loop:$tl, selectable:($unselectable | not)},
     models_recorded:($models != null),
     pool:$pool, pool_path:$pool_path, pool_configured:(($pool | length) > 0),
     use:($rule.use? // null),
     promotion_target:($rule.promotion_target? // null),
     subject:( (resolve($model)) as $r
               | $r + {requested:$model, effort:$effort,
                       profile:(if $r.resolved == luna_max_model and $effort == luna_max_effort then luna_max_profile.name else null end),
                       held:(if $r.resolved != null then held($r.resolved) else null end),
                       violations:(if $r.resolved != null then violations($r.resolved; $effort; $route_profile)
                                   elif $r.resolution == "unstated"
                                   then [{rule:"model_unstated", config_path:$pool_path,
                                          configured:(if ($pool | length) > 0 then ($pool | join(", "))
                                                      else "an ordered pool" end),
                                          observed:"no model named on this dispatch, so pool membership and every floor axis are unverifiable"}]
                                   else [] end)} ),
     effort_effective:$eeff,
     candidates:[ $pool | to_entries[]
                  | .value as $c
                  | (effective_route_profile($rule; $route_path; $c; "")) as $candidate_profile
                  | (held($c)) as $h
                  | (violations($c; $eeff; $candidate_profile)) as $v
                  | {model:$c, position:(.key + 1), profile:(if $c == luna_max_model then luna_max_profile.name else null end),
                     held:$h, violations:$v,
                     effort_expressible:($models[$c].effort_expressible? // null),
                     floor_met:(($v | length) == 0),
                     eligible:(($v | length) == 0 and $h == null)} ]}
  end
'

# fm_route_decision <config-dir> <route> <model> <effort> [<state-dir>] [<harness>]
# Print the decision record for one route. Return non-zero when the decision
# could not be made at all, so a caller can tell "no policy" from "policy says
# no" - and WHICH input it could not read, because the two live in different
# files with different repairs:
#
#   2  the routing config is absent or unreadable
#   3  the availability record exists and could not be parsed
#
# Collapsing the two sends an operator to repair a crew-dispatch.json that
# parses perfectly while the truncated model-health.json goes unmentioned, which
# is the same misdirection class as naming a substitute nothing checked.
fm_route_decision() {
  local cfg=$1 route=$2 model=${3:-} effort=${4:-} state=${5:-} harness=${6:-} file holds now
  file=$(fm_route_config_path "$cfg")
  [ -f "$file" ] || return 2
  command -v jq >/dev/null 2>&1 || return 2
  now=$(date -u +%s)
  holds=$(fm_route_health_active "$state" "$now") || return 3
  jq -c --arg route "$route" --arg model "$model" --arg effort "$effort" --arg harness "$harness" \
     --argjson holds "$holds" \
     "$FM_ROUTE_DECISION_JQ" "$file" 2>/dev/null || return 2
}

# fm_route_decision_with_registry <decision-json> <verdict-lines>
# Record the CALLER's registry verdicts on a decision record and recompute
# eligibility with them. <verdict-lines> is one "<model><TAB><refusal>" line per
# candidate, with an empty second field meaning the registry admits it.
#
# This library asks the model registry nothing. Cost, reachability and
# concurrency belong to bin/fm-model-registry-lib.sh and to the caller that
# already holds its answers; merging them here would make this file a second
# owner of a question it explicitly does not own. What it owns is the SHAPE: one
# merge, so a refusal can tell a substitute list that was checked against the
# registry from one that is routing-eligible only.
fm_route_decision_with_registry() {  # <decision-json> <verdict-lines>
  local decision=$1 verdicts=${2:-} merged
  command -v jq >/dev/null 2>&1 || { printf '%s' "$decision"; return 0; }
  merged=$(printf '%s' "$verdicts" | jq -R -s -c '
    [ split("\n")[] | select(length > 0) | (. / "\t")
      | {model: .[0],
         registry_refusal: (if (((.[1] // "") | length) > 0) then .[1] else null end)} ]') \
    || { printf '%s' "$decision"; return 1; }
  printf '%s' "$decision" | jq -c --argjson reg "$merged" '
    .candidates = [ .candidates[]?
      | . as $c
      | (first($reg[] | select(.model == $c.model)) // null) as $r
      | ($r.registry_refusal // null) as $rr
      | $c + {registry_refusal:$rr,
              registry_checked:($r != null),
              eligible:($c.floor_met and ($c.held == null) and ($rr == null))} ]' \
    || { printf '%s' "$decision"; return 1; }
}

# fm_route_decision_with_capacity <decision-json> <capacity-lines>
# Record the CALLER's quota observations on a decision record and recompute
# eligibility with them. <capacity-lines> is one
# "<model><TAB><verdict><TAB><until><TAB><evidence>" line per candidate, exactly
# the shape bin/fm-capacity-lib.sh emits and the same merge shape the registry
# verdicts already use.
#
# This library asks quota-axi nothing, for the same reason it asks the model
# registry nothing: ROUTE is availability-blind by construction and ELIGIBLE
# reads records rather than probing, so a live provider read belongs to the
# caller that decided to pay for it. What this owns is the SHAPE - one merge -
# so a refusal can tell a substitute list that was checked against capacity from
# one that was not.
#
# ONLY `exhausted` REMOVES A CANDIDATE. `could_not_observe` leaves eligibility
# exactly as it was and is carried through for disclosure, because an
# unmeasurable candidate stays eligible with its uncertainty disclosed. There is
# no branch here that adds a candidate or relaxes an axis: capacity can subtract
# from the schedulable set and nothing else.
fm_route_decision_with_capacity() {  # <decision-json> <capacity-lines>
  local decision=$1 lines=${2:-} merged
  command -v jq >/dev/null 2>&1 || { printf '%s' "$decision"; return 0; }
  merged=$(printf '%s' "$lines" | jq -R -s -c '
    [ split("\n")[] | select(length > 0) | (. / "\t")
      | {model: .[0],
         verdict: (.[1] // "could_not_observe"),
         until: (if (((.[2] // "") | length) > 0) then ((.[2] | tonumber?) // null) else null end),
         evidence: (.[3] // "")} ]') \
    || { printf '%s' "$decision"; return 1; }
  # The subject model is bound BEFORE the lookup. Inside a select the input is
  # the capacity row and not the decision, so reading .subject there compares
  # against null and leaves every dispatch unobserved while the read had in fact
  # succeeded - a failure indistinguishable from an honest disclosure, which is
  # exactly why it is spelled out here.
  printf '%s' "$decision" | jq -c --argjson cap "$merged" '
    (.effort_effective // "") as $band
    | def band_expressible($row):
        # Band preservation is a SUBSTITUTION invariant, not a floor axis, which
        # is why it lives here and not in violations(). The subject is already
        # running at $band; anything offered in its place must be able to express
        # the SAME band, or availability has silently changed reasoning depth -
        # the exact degradation this gate exists to prevent, arriving by the one
        # door the floor check does not watch. A floor that states no
        # effort_floor still leaves a running band to preserve.
        #
        # Unverifiable expressibility is NOT eligible. Declining to substitute
        # leaves the task waiting, which the governing ruling names as lawful;
        # substituting on unverified band evidence is the failure itself. This
        # can only ever SUBTRACT from the offered set.
        if ($band | length) == 0 then true
        elif (($row.effort_expressible | type) != "array") then false
        else (($row.effort_expressible | index($band)) != null) end;
      def with_cap($row):
        (first($cap[] | select(.model == $row.model)) // null) as $c
        | $row + {capacity: $c, capacity_checked: ($c != null),
                  band_expressible: band_expressible($row)}
        | . + {eligible: (.floor_met
                          and (.held == null)
                          and ((.registry_refusal // null) == null)
                          and .band_expressible
                          and (($c.verdict // "could_not_observe") != "exhausted"))};
      (.subject.resolved // "") as $subject
    | .candidates = [ .candidates[]? | with_cap(.) ]
    | .subject = (.subject
        + {capacity: (first($cap[] | select(.model == $subject)) // null)})
    | .capacity_merged = true' \
    || { printf '%s' "$decision"; return 1; }
}

# fm_route_capacity_refusal <route> <model> <decision-json>
# The verdict for the ONE model a dispatch names, once capacity has been merged.
# Returns 0 when the dispatch may proceed - including when its capacity could not
# be observed - and 1 with the refusal on stdout when the named model's capacity
# is spent.
#
# The two refusals below are DIFFERENT ANSWERS and must not read as one. A pool
# that still holds a floor-meeting candidate is a SUBSTITUTION: the work can run
# now, on another model, and the caller re-dispatches. A pool with nothing left
# is a DEFERRAL: the work cannot run at all until capacity returns, and the
# lawful outcomes are to wait or to escalate. Neither is ever a reason to lower
# the floor, which is why both name the pool they stayed inside.
fm_route_capacity_refusal() {  # <route> <model> <decision-json>
  local route=$1 model=$2 decision=$3 verdict evidence substitutes until_epoch
  local band band_excluded band_note=''
  verdict=$(printf '%s' "$decision" | jq -r '.subject.capacity.verdict // "could_not_observe"' 2>/dev/null)
  [ "$verdict" = exhausted ] || return 0
  evidence=$(printf '%s' "$decision" | jq -r '.subject.capacity.evidence // "no evidence recorded"' 2>/dev/null)
  substitutes=$(printf '%s' "$decision" | jq -r '[ .candidates[]? | select(.eligible) | .model ] | join(", ")' 2>/dev/null)
  # A sibling withheld to preserve the reasoning band is the one exclusion an
  # operator cannot infer from the pool, and an unexplained short list reads as a
  # smaller pool rather than as a deliberate refusal to change reasoning depth.
  band=$(printf '%s' "$decision" | jq -r '.effort_effective // ""' 2>/dev/null)
  # Compared against false explicitly. `.band_expressible // true` would be the
  # obvious spelling and is wrong: jq treats false as absent, so the alternative
  # fires for exactly the candidates this is meant to name and the disclosure
  # silently empties while the exclusion still happens.
  band_excluded=$(printf '%s' "$decision" | jq -r \
    '[ .candidates[]? | select(.band_expressible == false) | .model ] | join(", ")' 2>/dev/null)
  [ -z "$band_excluded" ] || band_note=$(printf ' Held back from substitution because they cannot be shown to express the %s band this work is running at: %s; substituting one would change reasoning depth, so the work waits instead.' "$band" "$band_excluded")
  until_epoch=$(printf '%s' "$decision" | jq -r '
    [ .candidates[]? | .capacity.until // empty ] | if length > 0 then min else empty end' 2>/dev/null)
  if [ -n "$substitutes" ]; then
    printf '%s: route %s: %s is out of capacity - %s - so it is not an eligible candidate right now. Fail over to the next eligible model inside this route pool, in pool order (%s); every one of those meets the same floor %s requires and expresses the same band.%s Never substitute outside this pool and never lower the floor\n' \
      "$FM_CAPACITY_TOKEN_EXHAUSTED" "$route" "$model" "$evidence" "$substitutes" "$route" "$band_note"
    return 1
  fi
  printf '%s: route %s: %s is out of capacity - %s - and no other candidate in this route pool is eligible either, so there is nothing to fail over to and this work is deferred until capacity returns%s.%s Do not substitute outside this pool and do not lower the floor: a floor that is required and currently unavailable is a wait, not a weaker model\n' \
    "$FM_CAPACITY_TOKEN_DEFERRED" "$route" "$model" "$evidence" \
    "$( [ -n "$until_epoch" ] && printf ' (earliest known recovery: epoch %s)' "$until_epoch" || printf ', with no recovery time published by any provider' )" \
    "$band_note"
  return 1
}

# The routes this home defines, one per line, for a refusal that has to name
# them.
fm_route_ids() {  # [<config-dir>]
  local file
  file=$(fm_route_config_path "${1:-}")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 2
  jq -r "$FM_ROUTE_ENTRIES_JQ"'
    [ route_entries[] | .id ] | unique | .[]
  ' "$file" 2>/dev/null || return 2
}

# The single route that names capability floor $2, for deriving the claim from
# an explicit --capability-floor. Prints nothing and returns 1 when no route or
# more than one route names it: a floor shared by two routes cannot stand in for
# a route id, and guessing one would defeat the check.
fm_route_for_floor() {  # <config-dir> <floor>
  local file matches
  file=$(fm_route_config_path "$1")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  matches=$(jq -r --arg floor "$2" "$FM_ROUTE_ENTRIES_JQ"'
    [ route_entries[] | select(.rule.floor? == $floor) | .id ] | unique | .[]
  ' "$file" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$matches" | grep -c .)" = 1 ] || return 1
  printf '%s\n' "$matches"
}

# Band expressibility is deliberately NOT a standalone predicate. It is part of
# candidate eligibility in fm_route_decision_with_capacity, so every consumer -
# the spawn chokepoint, `fm-route.sh eligible`, `fm-route.sh next` and the
# capacity retry driver - reads one answer. A helper any caller could apply on
# its own was a second band authority free to drift from the one enforced at
# dispatch, which is precisely how a resume could change reasoning depth while
# every individual check still looked correct.

# ---------------------------------------------------------------------------
# Refusal rendering
# ---------------------------------------------------------------------------

# One violation as one line naming the route, the exact config path, and the
# configured value against the observed one. Every refusal this library prints
# is built from these, so no caller invents its own wording for a rule.
fm_route_violation_lines() {  # <route> <decision-json> <jq-path-to-violations>
  local route=$1 decision=$2 path=$3
  printf '%s' "$decision" | jq -r --arg route "$route" "
    $path | .[]? |
    \"  \" + .rule + \": route \" + \$route + \" \" + .config_path
      + \" configures \" + (.configured | tostring)
      + \"; this dispatch observed \" + (.observed | tostring)
  " 2>/dev/null
}

# fm_route_unreadable_refusal <config-dir>
# The one wording for "this home configures routed pools and the policy that
# would check this dispatch cannot be read".
fm_route_unreadable_refusal() {  # <config-dir>
  printf '%s: %s/crew-dispatch.json defines routed pools but its route decision could not be read (missing jq or malformed JSON), so a dispatch cannot be checked against the policy it claims\n' \
    "$FM_ROUTE_TOKEN_UNREADABLE" "$1"
}

# fm_route_health_unreadable_refusal [<state-dir>]
# The other unreadable input, and it names the other file. The routing config
# can be perfect while the availability record is truncated mid-write, and a
# refusal that points at the wrong file costs the operator the whole diagnosis.
fm_route_health_unreadable_refusal() {  # [<state-dir>]
  printf '%s: %s exists but could not be parsed, so which models this fleet currently holds unavailable could not be determined and no dispatch can be checked against the route it claims. Repair or remove that record; the routing config is not what failed here\n' \
    "$FM_ROUTE_TOKEN_HEALTH_UNREADABLE" "$(fm_route_health_path "${1:-}")"
}

# fm_route_undetermined_refusal <fm_route_decision-status> <config-dir>
#                               [<state-dir>]
# The refusal for a decision that could not be made, chosen by WHICH input the
# decision could not read. Spelled once so no caller has to remember the status
# code mapping, and so every surface names the same file for the same cause.
fm_route_undetermined_refusal() {
  case "$1" in
    3) fm_route_health_unreadable_refusal "${3:-}" ;;
    *) fm_route_unreadable_refusal "$2" ;;
  esac
}

# fm_route_refusal_from_decision <config-dir> <route> <model> <decision-json>
#                                [<state-dir>]
# The verdict and its rendering, from a decision record already computed.
# Separated from the evaluation so a caller that also needs the record - the
# spawn chokepoint needs the route's floor - evaluates the policy exactly ONCE:
# two evaluations can observe two different configs or two different
# availability records, and then the refusal and the recorded floor no longer
# describe the same decision.
fm_route_refusal_from_decision() {
  local cfg=$1 route=$2 model=${3:-} decision=$4 state=${5:-} known dup resolution count held substitutes checked
  known=$(printf '%s' "$decision" | jq -r '.route_known')
  if [ "$known" != true ]; then
    printf '%s: route %s is not defined by %s/crew-dispatch.json. Defined: %s\n' \
      "$FM_ROUTE_TOKEN_UNKNOWN" "$route" "$cfg" \
      "$(printf '%s' "$decision" | jq -r '.known_routes | join(", ")')"
    return 1
  fi
  dup=$(printf '%s' "$decision" | jq -r '.duplicate_paths // empty | join(", ")')
  if [ -n "$dup" ]; then
    printf '%s: route %s is defined more than once in %s/crew-dispatch.json (%s); a duplicate route id makes every check against it meaningless\n' \
      "$FM_ROUTE_TOKEN_AMBIGUOUS" "$route" "$cfg" "$dup"
    return 1
  fi
  resolution=$(printf '%s' "$decision" | jq -r '.subject.resolution')
  if [ "$resolution" = ambiguous ]; then
    printf '%s: route %s: the bare model name %s matches more than one pool entry (%s); the mixed-key rule forbids guessing which one was meant\n' \
      "$FM_ROUTE_TOKEN_POOL" "$route" "$model" \
      "$(printf '%s' "$decision" | jq -r '.subject.matches | join(", ")')"
    return 1
  fi
  count=$(printf '%s' "$decision" | jq -r '.subject.violations | length')
  if [ "$count" != 0 ]; then
    printf 'this dispatch violates the route it claims (%s, floor %s):\n' \
      "$route" "$(printf '%s' "$decision" | jq -r '.floor // "unconfigured"')"
    fm_route_violation_lines "$route" "$decision" '.subject.violations'
    return 1
  fi
  # AVAILABILITY. The routing policy admits this model; the record says the
  # fleet currently cannot reach it. Refusing here is what makes `check` and
  # `eligible` answer the same question the same way - two commands in this
  # library giving opposite answers about one model is how a held primary gets
  # dispatched and failover never runs.
  held=$(printf '%s' "$decision" | jq -r '
    .subject.held // empty
    | "the " + .scope + " " + .subject + " is held " + .state
      + (if .until != null then " until epoch " + (.until | tostring)
         else " until it is released explicitly" end)
      + (if ((.evidence // "") | length) > 0 then " (" + .evidence + ")" else "" end)')
  if [ -n "$held" ]; then
    # The substitutes are the candidates the decision already found ELIGIBLE,
    # never the whole pool: offering the model that was just refused as its own
    # replacement is advice an operator cannot act on.
    substitutes=$(printf '%s' "$decision" | jq -r '[ .candidates[]? | select(.eligible) | .model ] | join(", ")')
    # Whether the caller supplied registry verdicts, from the record itself. A
    # routing-only list presented as if it had been checked is the same defect
    # one rung down: the operator dispatches the named substitute and meets a
    # second refusal from an owner nobody mentioned.
    checked=$(printf '%s' "$decision" | jq -r \
      '[ .candidates[]? | select(.eligible) | select(.registry_checked != true) ] | length == 0')
    if [ -n "$substitutes" ] && [ "$checked" = true ]; then
      printf '%s: route %s: %s in %s, so it is not an eligible candidate. Fail over to the next eligible model inside this route pool, in pool order (%s), each already checked against the model registry for cost, reachability and concurrency; never substitute outside this pool and never lower the floor\n' \
        "$FM_ROUTE_TOKEN_HELD" "$route" "$held" "$(fm_route_health_path "$state")" "$substitutes"
    elif [ -n "$substitutes" ]; then
      printf '%s: route %s: %s in %s, so it is not an eligible candidate. Fail over to the next eligible model inside this route pool, in pool order (%s). Those names are routing-eligible ONLY and were NOT checked against the model registry, so cost, reachability and concurrency may still refuse them; run fm-route.sh eligible --route %s for the registry-checked list. Never substitute outside this pool and never lower the floor\n' \
        "$FM_ROUTE_TOKEN_HELD" "$route" "$held" "$(fm_route_health_path "$state")" "$substitutes" "$route"
    else
      printf '%s: route %s: %s in %s, and no other candidate in this route pool is eligible either, so there is nothing to fail over to. Run fm-route.sh eligible --route %s for the terminal report naming every candidate and why, then stop and escalate: do not substitute outside this pool and do not lower the floor\n' \
        "$FM_ROUTE_TOKEN_HELD" "$route" "$held" "$(fm_route_health_path "$state")" "$route"
    fi
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The availability record - FAILOVER's only output
# ---------------------------------------------------------------------------

fm_route_health_state_known() {  # <state>
  local want=$1 known
  while IFS= read -r known; do
    [ "$known" = "$want" ] && return 0
  done <<EOF
$FM_ROUTE_HEALTH_STATES
EOF
  return 1
}

# fm_route_hold_subject <config-dir> <requested-scope: model|provider|""> <subject>
# Which record a hold names, as "<scope> <subject>", or a refusal on stderr.
#
# The scope is NEVER inferred from the shape of the name. A slash says nothing
# about intent, and inferring `provider` from its absence records a hold under a
# key no candidate can ever match while reporting success - which is worse than
# refusing, because the operator then believes failover is armed. So a model is
# resolved against the pools this home actually configures, exactly as a
# dispatch's `--model` is, and a provider hold has to be asked for outright.
fm_route_hold_subject() {
  local cfg=$1 want_scope=${2:-} subject=$3 file pool_models entry providers matches count
  file=$(fm_route_config_path "$cfg")
  pool_models=$(fm_route_pool_models "$cfg") || {
    echo "$FM_ROUTE_TOKEN_HOLD_SUBJECT: $file could not be read, so '$subject' cannot be resolved against the pools a hold would have to match" >&2
    return 1
  }
  if [ -z "$pool_models" ]; then
    echo "$FM_ROUTE_TOKEN_HOLD_SUBJECT: $file configures no routed pool, so an availability hold on '$subject' could not remove any candidate; configure a route with an ordered pool before recording holds" >&2
    return 1
  fi
  if [ "$want_scope" = provider ]; then
    providers=
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        */*) [ "${entry%%/*}" != "$subject" ] || { printf 'provider %s\n' "$subject"; return 0; }
             providers="$providers ${entry%%/*}" ;;
      esac
    done <<EOF
$pool_models
EOF
    echo "$FM_ROUTE_TOKEN_HOLD_SUBJECT: no pool entry in $file names the provider '$subject', so a provider hold on it could not remove any candidate. Configured providers:$(printf '%s' "$providers" | tr ' ' '\n' | sort -u | tr '\n' ' ')" >&2
    return 1
  fi
  matches=
  count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "$entry" = "$subject" ]; then
      printf 'model %s\n' "$entry"
      return 0
    fi
    case "$subject" in
      */*) : ;;
      *) case "$entry" in
           */"$subject") matches="$matches $entry"; count=$((count + 1)) ;;
         esac ;;
    esac
  done <<EOF
$pool_models
EOF
  if [ "$count" -eq 1 ]; then
    printf 'model %s\n' "${matches# }"
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "$FM_ROUTE_TOKEN_HOLD_SUBJECT: the bare name '$subject' matches more than one pool entry in $file ($(printf '%s' "${matches# }" | tr ' ' ',' | sed 's/,/, /g')); the mixed-key rule forbids guessing which one was meant, so name the model in full" >&2
    return 1
  fi
  echo "$FM_ROUTE_TOKEN_HOLD_SUBJECT: '$subject' matches no pool entry in $file, so a hold on it could not remove any candidate. Pool entries: $(printf '%s' "$pool_models" | tr '\n' ' ' | sed 's/ $//'). Pass --scope provider to hold a whole provider instead." >&2
  return 1
}

# fm_route_hold_recorded_scope <state-dir> <subject>
# The scope a hold is ALREADY recorded under, or nothing. Release resolves
# against the record first, so a hold survives a config edit that drops its
# subject from every pool: a record that can be written and not cleared is a
# trap, and clearing an availability hold is always safe.
fm_route_hold_recorded_scope() {
  local state=$1 subject=$2 file
  file=$(fm_route_health_path "$state")
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -er --arg s "$subject" '
    if ((.models // {}) | has($s)) then "model"
    elif ((.providers // {}) | has($s)) then "provider"
    else empty end' "$file" 2>/dev/null
}

fm_route_health_states_oneline() {
  printf '%s\n' "$FM_ROUTE_HEALTH_STATES" | tr '\n' ' ' | sed 's/ $//'
}

# Every hold still in force at epoch $2, as {"models":{...},"providers":{...}}.
# An absent record is an empty one: absence means no REMEMBERED cooldown, never
# a capability assertion, and never a claim that a model is healthy. An expired
# hold is dropped on read rather than swept, so nothing has to run to forget.
fm_route_health_active() {  # [<state-dir>] [<now-epoch>]
  local file now
  file=$(fm_route_health_path "${1:-}")
  now=${2:-$(date -u +%s)}
  if [ ! -f "$file" ] || ! command -v jq >/dev/null 2>&1; then
    printf '{"models":{},"providers":{}}\n'
    return 0
  fi
  jq -c --argjson now "$now" '
    def live: with_entries(select(.value.until == null or (.value.until > $now)));
    {models: ((.models // {}) | live), providers: ((.providers // {}) | live)}
  ' "$file" 2>/dev/null || {
    # A record that exists and cannot be parsed is not an empty record. Refuse
    # rather than silently treating every held model as available again.
    return 1
  }
}

# fm_route_health_write <state-dir> <scope: model|provider> <subject> <state>
#                       <until-epoch|""> <evidence>
# Record one availability hold, atomically and privately. Clearing is the same
# call with an empty state.
#
# This is the ONLY writer. It writes availability and nothing else: it never
# touches rules, floors, or pools, because a model that keeps failing is
# unavailable rather than demoted.
fm_route_health_write() {
  local state=$1 scope=$2 subject=$3 hold=$4 expires=${5:-} evidence=${6:-} release_config=${7:-}
  local file lock tmp now current updated expires_json target_exists recorded_scope resolved rc=0
  file=$(fm_route_health_path "$state")
  command -v jq >/dev/null 2>&1 || { echo "jq is required to record model availability" >&2; return 1; }
  mkdir -p "$(dirname "$file")" || return 1
  expires_json=null
  [ -z "$expires" ] || expires_json=$expires
  case "$scope" in
    model|provider) ;;
    '') [ -z "$hold" ] && [ -n "$release_config" ] \
          || { echo "unknown availability scope: $scope" >&2; return 1; } ;;
    *) echo "unknown availability scope: $scope" >&2; return 1 ;;
  esac
  if [ -n "$hold" ] && ! fm_route_health_state_known "$hold"; then
    echo "$FM_ROUTE_TOKEN_HEALTH_STATE: '$hold' is not an availability state; the vocabulary is closed to the states the policy's failover conditions set. One of: $(fm_route_health_states_oneline)" >&2
    return 1
  fi

  # The exclusion covers the entire read/validate/modify/write transaction.
  # Reading before this point is the lost-update defect: two writers can both
  # derive a new document from one stale snapshot and the later atomic rename
  # erases the first writer's independent binding.
  lock=$(fm_route_health_lock_path "$state")
  if ! fm_lock_acquire_wait "$lock"; then
    echo "could not acquire the availability record lock: $lock" >&2
    return 1
  fi

  # Every path below releases the lock before returning. A stale lock left by an
  # interrupted process is reclaimed by the portable lock owner on its next
  # acquisition; the record itself remains either the old document or the
  # completed atomic replacement.
  now=$(date -u +%s) || { rc=1; now=0; }
  if [ "$rc" -eq 0 ] && ! fm_route_health_active "$state" "$now" >/dev/null 2>&1; then
    echo "existing availability record could not be validated: $file" >&2
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -f "$file" ]; then
      current=$(jq -c . "$file" 2>/dev/null) || {
        echo "existing availability record is malformed: $file" >&2
        rc=1
      }
    else
      current="{\"schema\":\"$FM_ROUTE_HEALTH_SCHEMA\",\"models\":{},\"providers\":{}}"
    fi
  fi

  updated=
  if [ "$rc" -eq 0 ]; then
    if [ -z "$hold" ]; then
      if [ -n "$release_config" ]; then
        recorded_scope=$(printf '%s' "$current" | jq -r --arg subject "$subject" '
          if ((.models // {}) | has($subject)) then "model"
          elif ((.providers // {}) | has($subject)) then "provider"
          else empty end' 2>/dev/null) || {
          echo "could not observe the availability record binding" >&2
          rc=1
        }
        if [ "$rc" -eq 0 ] && [ -n "$recorded_scope" ]; then
          [ -z "$scope" ] || [ "$scope" = "$recorded_scope" ] || {
            echo "$subject is recorded as a $recorded_scope hold, not a $scope one" >&2
            rc=1
          }
          scope=$recorded_scope
        elif [ "$rc" -eq 0 ]; then
          resolved=$(fm_route_hold_subject "$release_config" "$scope" "$subject") || rc=1
          if [ "$rc" -eq 0 ]; then
            scope=${resolved%% *}
            subject=${resolved#* }
          fi
        fi
      fi
    fi
    if [ "$rc" -eq 0 ] && [ -z "$hold" ]; then
      if ! target_exists=$(printf '%s' "$current" | jq -r --arg scope "${scope}s" --arg subject "$subject" \
        '((.[$scope] // {}) | has($subject))' 2>/dev/null); then
        echo "could not observe the availability record binding" >&2
        rc=1
      elif [ "$target_exists" = true ]; then
        updated=$(printf '%s' "$current" | jq -c \
          --arg scope "${scope}s" --arg subject "$subject" \
          '.[$scope] |= del(.[$subject])' 2>/dev/null) || {
          echo "could not update the availability record" >&2
          rc=1
        }
      fi
      # Releasing an absent binding is an idempotent no-op. In particular, it
      # does not create an empty record merely to report that nothing changed.
    else
      updated=$(printf '%s' "$current" | jq -c \
        --arg schema "$FM_ROUTE_HEALTH_SCHEMA" --arg scope "${scope}s" --arg subject "$subject" \
        --arg hold "$hold" --arg evidence "$evidence" \
        --argjson now "$now" --argjson expires "$expires_json" '
        .schema = $schema
        | .models = (.models // {}) | .providers = (.providers // {})
        | .[$scope][$subject] = ((.[$scope][$subject] // {})
            + {state:$hold, until:$expires, recorded_at:$now, evidence:$evidence})
      ' 2>/dev/null) || {
        echo "could not update the availability record" >&2
        rc=1
      }
    fi
  fi

  if [ "$rc" -eq 0 ] && [ -n "$updated" ]; then
    tmp=$(mktemp "$file.XXXXXX") || rc=1
    if [ "$rc" -eq 0 ]; then
      chmod 600 "$tmp" 2>/dev/null || true
      if ! printf '%s\n' "$updated" > "$tmp"; then
        rm -f -- "$tmp"
        tmp=
        rc=1
      fi
    fi
    if [ "$rc" -eq 0 ]; then
      chmod 600 "$tmp" 2>/dev/null || rc=1
    fi
    if [ "$rc" -eq 0 ] && ! mv -f -- "$tmp" "$file"; then
      rm -f -- "$tmp"
      tmp=
      rc=1
    fi
    [ -z "$tmp" ] || rm -f -- "$tmp"
    [ "$rc" -eq 0 ] && chmod 600 "$file" 2>/dev/null || true
  fi

  if ! fm_lock_release "$lock"; then
    rc=1
  fi
  if [ "$rc" -eq 0 ] && [ -z "$hold" ] && [ -n "$release_config" ]; then
    printf '%s %s\n' "$scope" "$subject"
  fi
  return "$rc"
}
