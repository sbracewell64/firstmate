# shellcheck shell=bash
# fm-capacity-lib.sh - the single owner of QUOTA AND SESSION-WINDOW AVAILABILITY
# as a routing input, expressed as a THREE-VALUED observation per candidate.
# Usage: . bin/fm-capacity-lib.sh
#
# WHY THIS EXISTS. The platform used to discover a pool was exhausted AFTER
# dispatching into it. Overnight 2026-08-10/11 five lanes stalled repeatedly on
# `agent run tests: claude exited: exit status 1` with no defect in the code: the
# claude weekly window was at 11 percent while the codex weekly window had just
# reset to 100. Every stall cost a wake, a diagnosis and a restart, and the whole
# fleet recovered on one config change. Nothing read the quota surface before
# choosing, so the first evidence of exhaustion was always a dead worker.
#
# WHERE THIS SITS. The routing policy's own intake order is
# ROUTE -> ADMIT -> ELIGIBLE -> SCHEDULE -> FAILOVER, and this is an ELIGIBLE
# input, not a second router. It decides nothing about which route a task
# claims, which floor that route requires, or which models are in its pool.
# bin/fm-route-lib.sh still owns all of that and still owns the merge that
# recomputes eligibility; this file only answers, for a model somebody else
# already chose, whether the provider currently says its capacity is spent.
#
#   THE HARD RULE, AND IT IS THE WHOLE POINT. Availability may REMOVE a
#   candidate from the currently schedulable set. It may never lower the
#   required capability floor. There is no code path here that adds a candidate,
#   widens a pool, or relaxes an axis, because the candidate list this observes
#   is produced by the route decision and handed in already floor-filtered.
#
# THREE VALUES, NEVER TWO. Every model gets exactly one of:
#
#   available          an observed bound says capacity remains.
#   exhausted          an observed bound says capacity is spent.
#   could_not_observe  neither could be established.
#
# `could_not_observe` is a real result and is reported as one. It is NOT
# "available" and NOT "unavailable": an unmeasurable candidate stays eligible
# with its uncertainty disclosed, which is the standing dispatch rule in
# AGENTS.md section 4 and the captain's explicit instruction for this seam.
#
# THAT MAKES THIS GATE FAIL TOWARD DISPATCH, WHICH IS DELIBERATE AND IS THE ONE
# PLACE IN THIS REPO WHERE THAT IS RIGHT. Everywhere else an unreadable safety
# input refuses, because there the unreadable input is the thing that would have
# said no. Here the observation can only ever REMOVE a candidate the routing
# policy already admitted, so failing to observe removes nothing and leaves the
# fleet exactly as capable as it was before this landed. Refusing instead would
# make every home without quota-axi undispatchable, which is a far larger
# outage than the one this closes. What must not happen - and does not - is an
# unobserved candidate being reported as observed-good.
#
# NOTHING IS INFERRED FROM A NAME. quota-axi reports providers under ITS OWN
# identifiers (`claude`, `codex`, `cursor`, `copilot`, `grok`, `kimi`) while a
# routed pool names providers under the dispatch policy's identifiers
# (`claude`, `openai-codex`, `google`, `opencode`). Those two vocabularies
# overlap by coincidence, not by contract: `openai-codex` and `codex` are the
# same account only because their OAuth grants were compared claim by claim and
# recorded, and `google` and `opencode` have no quota-axi provider at all. So the
# join is DECLARED, in `_providers.<id>.quota_axi_provider`, and an undeclared
# provider is could_not_observe with the exact field to add. Guessing the mapping
# from a matching prefix is precisely the inference AGENTS.md section 4 forbids,
# and it would silently meter one account against another's window.
#
# QUOTA-AXI OWNS THE WINDOW SEMANTICS AND THIS FILE DOES NOT RESTATE THEM. A
# provider's `quotaSemantics.effectiveAvailability[]` already carries, per scope,
# the effective remaining percentage AFTER taking the minimum across every window
# that bounds it, plus which windows did the bounding. So this reads the entry
# for the most specific scope quota-axi PUBLISHES for a model - `model:<leaf>`
# when there is one, else `all_models` - and takes its number. It never combines
# windows itself, never assumes a model-level window exists where quota-axi
# publishes none, and never treats an account-level window as a per-route
# allowance. A model with no published model-scope simply has no model-level
# bound in quota-axi's model of that account, which is quota-axi's statement
# rather than this file's inference.
#
# WHAT THIS DOES NOT OWN, and it matters because two of them look adjacent:
#
#   state/model-health.json    bin/fm-route-lib.sh, FAILOVER's only output. That
#                              record remembers holds learned from FAILURES and
#                              is written after the fact. This observation is
#                              DERIVED LIVE at every evaluation and is never
#                              stored, so there is no second availability store
#                              and no snapshot to go stale. The two compose:
#                              a candidate is out if either says so.
#   config/models.json         bin/fm-model-registry-lib.sh - cost, entitlement
#                              and concurrency. Being affordable is a different
#                              question from having budget left this week.
#   fleet admission            bin/fm-admission.sh - whether the FLEET accepts
#                              another task at all, which is not about models.
#
# docs/configuration.md "Quota-aware routing" owns the config schema. This
# header owns the mechanics.

# Idempotent guard: fm-spawn.sh, fm-route.sh and fm-capacity-retry.sh may all be
# in one process tree.
if [ -n "${FM_CAPACITY_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_CAPACITY_LIB_SOURCED=1

SCRIPT_DIR_CAPACITY_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR_CAPACITY_LIB/fm-quota-axi-lib.sh"

# The closed verdict vocabulary. Spelled once so no call site invents a fourth
# value and no reader has to guess whether a missing verdict means anything.
# shellcheck disable=SC2034 # Contract constants are consumed by sourcing callers.
{
FM_CAPACITY_SCHEMA='fm-capacity-observation.v1'
FM_CAPACITY_AVAILABLE=available
FM_CAPACITY_EXHAUSTED=exhausted
FM_CAPACITY_UNOBSERVED=could_not_observe
# Stable tokens. Tests and callers match these rather than prose.
FM_CAPACITY_TOKEN_DEFERRED=FM_SPAWN_CAPACITY_DEFERRED
FM_CAPACITY_TOKEN_EXHAUSTED=FM_SPAWN_CAPACITY_EXHAUSTED
FM_CAPACITY_TOKEN_UNOBSERVED=FM_CAPACITY_UNOBSERVED
}

# Seconds allowed for the one bounded quota-axi read. A read that overruns is
# could_not_observe, never a guess in either direction.
FM_CAPACITY_TIMEOUT=${FM_CAPACITY_TIMEOUT:-20}

# The percentage at or below which a published window counts as spent, when the
# policy declares no threshold of its own. Zero is deliberate: the default
# removes a candidate only when the provider itself reports nothing left, so
# landing this cannot narrow any home's schedulable set by surprise. An operator
# who wants a reserve raises it in `_availability.quota_gate`.
FM_CAPACITY_EXHAUSTED_AT_DEFAULT=0

# ---------------------------------------------------------------------------
# The observation program
# ---------------------------------------------------------------------------

# One jq program answers the whole question, so the join rule and the
# three-valued mapping are spelled exactly once. Inputs: the dispatch config as
# stdin, plus $quota (quota-axi's record or null), $models (the candidate list),
# $source (how the read went), $thresh and $now.
#
# EVERY could_not_observe CARRIES ITS REASON AND ITS REPAIR. "Could not observe"
# with no reason is indistinguishable from "nobody looked", which is the state
# this replaces; an operator reading a disclosure has to be able to act on it.
# shellcheck disable=SC2016 # jq program, not shell expansion.
FM_CAPACITY_OBSERVE_JQ='
def provider_of($m): (if ($m | test("/")) then ($m | split("/") | .[0]) else null end);
def leaf_of($m): (if ($m | test("/")) then ($m | split("/") | .[1:] | join("/")) else $m end);

# quota-axi timestamps are UTC and carry fractional seconds plus either a Z or a
# +00:00 offset. Only those two forms are converted; anything else keeps the
# published string and reports no epoch rather than a wrong one, because a
# deferral that resumes at the wrong moment is worse than one that admits it
# does not know when to resume.
def epoch_of($ts):
  if ($ts | type) != "string" then null
  elif ($ts | test("(Z|\\+00:00)$") | not) then null
  else ($ts | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})") | .d + "Z")
       | (try fromdateiso8601 catch null)
  end;

def unobserved($m; $reason; $detail; $repair):
  {model:$m, verdict:"could_not_observe", reason:$reason,
   percent_remaining:null, scope:null, limiting_windows:[],
   resets_at:null, until:null, repair:$repair,
   evidence:("capacity could not be observed for " + $m + " (" + $reason + "): " + $detail)};

. as $cfg
| ($cfg._providers // {}) as $provs
| (($quota.providers // []) | map({key:.provider, value:.}) | from_entries) as $qprov
| [ $models[]
    | . as $m
    | (provider_of($m)) as $p
    | if ($source.status != "read") and ($source.status != "not_needed") then
        unobserved($m; "source_" + $source.status;
                   $source.detail;
                   $source.repair)
      elif $p == null then
        unobserved($m; "unqualified_model";
                   "the pool entry names no provider, so no quota surface can be resolved for it";
                   "name pool entries as <provider>/<model>")
      elif (($provs[$p] | type) != "object") then
        unobserved($m; "provider_undeclared";
                   "the dispatch policy declares no _providers." + $p + " entry, so this provider has no recorded quota surface";
                   "declare /_providers/" + $p + " with quota_observable and, when it is observable, quota_axi_provider")
      elif ($provs[$p].quota_observable == false) then
        unobserved($m; "provider_declares_no_quota_surface";
                   "_providers." + $p + ".quota_observable is false, so this provider publishes no quota this fleet can read";
                   "none - this is a declared property of the provider, not a defect; the candidate stays eligible with its uncertainty disclosed")
      elif ($provs[$p].quota_observable != true) then
        unobserved($m; "quota_observable_undeclared";
                   "_providers." + $p + ".quota_observable is not declared, so whether this provider publishes readable quota is unknown";
                   "set /_providers/" + $p + "/quota_observable to true or false")
      elif (($provs[$p].quota_axi_provider | type) != "string")
           or (($provs[$p].quota_axi_provider | length) == 0) then
        unobserved($m; "quota_axi_provider_unbound";
                   "_providers." + $p + " declares readable quota but names no quota-axi provider, and the two vocabularies are not joined by name";
                   "set /_providers/" + $p + "/quota_axi_provider to the quota-axi provider id this account actually meters against, recorded from evidence rather than from a matching prefix")
      else
        ($provs[$p].quota_axi_provider) as $bind
        | ($qprov[$bind] // null) as $qp
        | if $qp == null then
            unobserved($m; "provider_absent_from_quota_axi";
                       "quota-axi reports no provider " + $bind + ", which _providers." + $p + " binds this provider to";
                       "check the binding at /_providers/" + $p + "/quota_axi_provider against quota-axi --json, and confirm that account is configured for this host")
          elif ($qp.quotaSemantics.status? != "known") then
            unobserved($m; "quota_semantics_unknown";
                       "quota-axi reports provider " + $bind + " with quota semantics "
                         + (($qp.quotaSemantics.status? // "absent") | tostring)
                         + " and credential state " + (($qp.state.status? // "absent") | tostring);
                       "restore the provider credential quota-axi reads, or accept the disclosure; this is not a claim that the provider is out of capacity")
          else
            ((($qp.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope == ("model:" + leaf_of($m)))) | .[0]) //
             (($qp.quotaSemantics.effectiveAvailability // [])
              | map(select(.scope == "all_models")) | .[0]) // null) as $ea
            | if $ea == null then
                unobserved($m; "no_effective_availability_scope";
                           "quota-axi publishes no model:" + leaf_of($m) + " and no all_models availability scope for provider " + $bind;
                           "none available from here - quota-axi owns which scopes it publishes")
              elif ($ea.status? != "known") then
                unobserved($m; "scope_status_unknown";
                           "quota-axi publishes scope " + ($ea.scope | tostring) + " for provider " + $bind
                             + " with status " + (($ea.status // "absent") | tostring);
                           "none available from here - quota-axi owns that status")
              elif (($ea.effectivePercentRemaining | type) != "number") then
                unobserved($m; "percent_unreadable";
                           "quota-axi publishes scope " + ($ea.scope | tostring) + " for provider " + $bind
                             + " with no numeric effectivePercentRemaining";
                           "none available from here - quota-axi owns that field")
              else
                ($ea.effectivePercentRemaining) as $pct
                | (($ea.limitingWindowIds // [])) as $lw
                | (($qp.windows // []) | map(select(.id == ($lw[0] // null))) | .[0]) as $win
                | ($win.resetsAt? // null) as $reset
                | {model:$m,
                   verdict:(if $pct <= $thresh then "exhausted" else "available" end),
                   reason:null,
                   percent_remaining:$pct,
                   scope:$ea.scope,
                   limiting_windows:$lw,
                   resets_at:$reset,
                   until:epoch_of($reset),
                   repair:null,
                   evidence:("quota-axi " + $bind + " " + ($ea.scope | tostring) + " reports "
                             + ($pct | tostring) + " percent remaining"
                             + (if ($lw | length) > 0 then " bounded by " + ($lw | join(", ")) else "" end)
                             + (if $reset != null then ", resetting at " + $reset else ", publishing no reset time" end))}
              end
          end
      end ] as $rows
| {schema:"fm-capacity-observation.v1",
   observed_at:$now,
   threshold_percent_remaining:$thresh,
   source:$source,
   models:($rows | map({key:.model, value:.}) | from_entries),
   exhausted:[ $rows[] | select(.verdict == "exhausted") | .model ],
   unobserved:[ $rows[] | select(.verdict == "could_not_observe") | .model ],
   earliest_recovery:([ $rows[] | select(.verdict == "exhausted") | .until | select(. != null) ] | min)}
'

# fm_capacity_source
# How the one bounded quota-axi read went. Sets TWO globals rather than printing
# one of them: FM_CAPACITY_SOURCE carries the {status, detail, repair} object the
# program above consumes, and FM_CAPACITY_QUOTA carries the raw record. Statuses
# other than `read` make every model could_not_observe with that status as its
# reason, which is why each carries its own repair sentence.
#
# Both are globals BECAUSE a command substitution would run this in a subshell
# and silently drop the record, leaving every candidate could_not_observe while
# the read had in fact succeeded. That failure is invisible from the outside -
# it looks exactly like an honest disclosure - which is precisely why it must not
# be possible to reintroduce by calling this the usual way.
fm_capacity_source() {
  local out
  FM_CAPACITY_QUOTA=null
  FM_CAPACITY_SOURCE='{"status":"unreadable","detail":"the quota source was never resolved","repair":"report this as a defect in bin/fm-capacity-lib.sh"}'
  if [ "${FM_CAPACITY_QUOTA_JSON:-}" != "" ]; then
    # A caller-supplied record, used by the tests and by any surface that has
    # already paid for the read. Validated exactly as a live read is, so a
    # malformed injection cannot become an observation.
    if ! out=$(printf '%s' "$FM_CAPACITY_QUOTA_JSON" | jq -c . 2>/dev/null); then
      FM_CAPACITY_SOURCE='{"status":"unreadable","detail":"the supplied quota record is not valid JSON","repair":"correct FM_CAPACITY_QUOTA_JSON or unset it so the live tool is read"}'
      return 0
    fi
    FM_CAPACITY_QUOTA=$out
    FM_CAPACITY_SOURCE='{"status":"read","detail":"supplied quota record","repair":null}'
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    FM_CAPACITY_SOURCE='{"status":"unreadable","detail":"jq is not installed, so a quota record cannot be read","repair":"install jq"}'
    return 0
  fi
  if ! command -v quota-axi >/dev/null 2>&1; then
    FM_CAPACITY_SOURCE='{"status":"unavailable","detail":"quota-axi is not installed, so no provider window can be read on this host","repair":"install quota-axi; bin/fm-bootstrap.sh reports it as a MISSING diagnostic"}'
    return 0
  fi
  if ! fm_quota_axi_compatible "$FM_CAPACITY_TIMEOUT"; then
    FM_CAPACITY_SOURCE=$(printf '{"status":"incompatible","detail":"the installed quota-axi is older than %s or did not report a version, and an unparseable version is never assumed current","repair":"upgrade quota-axi to at least %s"}' \
      "$FM_QUOTA_AXI_MIN" "$FM_QUOTA_AXI_MIN")
    return 0
  fi
  if ! out=$(fm_quota_axi_bounded "$FM_CAPACITY_TIMEOUT" --json); then
    FM_CAPACITY_SOURCE=$(printf '{"status":"unreadable","detail":"quota-axi --json did not complete within %s seconds or exited non-zero","repair":"run quota-axi --json by hand and repair whatever it reports"}' \
      "$FM_CAPACITY_TIMEOUT")
    return 0
  fi
  if ! out=$(printf '%s' "$out" | jq -c 'select((.providers | type) == "array")' 2>/dev/null) || [ -z "$out" ]; then
    FM_CAPACITY_SOURCE='{"status":"unreadable","detail":"quota-axi --json returned no readable providers array","repair":"run quota-axi --json by hand and repair whatever it reports"}'
    return 0
  fi
  FM_CAPACITY_QUOTA=$out
  FM_CAPACITY_SOURCE='{"status":"read","detail":"quota-axi --json","repair":null}'
}

# The configured exhaustion threshold, or the default. A threshold outside 0-100
# is refused back to the default rather than applied, because a negative one
# would remove nothing and a value above 100 would remove everything, and both
# would look like the gate working.
fm_capacity_threshold() {  # <config-file>
  local file=$1 v
  [ -f "$file" ] || { printf '%s\n' "$FM_CAPACITY_EXHAUSTED_AT_DEFAULT"; return 0; }
  command -v jq >/dev/null 2>&1 || { printf '%s\n' "$FM_CAPACITY_EXHAUSTED_AT_DEFAULT"; return 0; }
  v=$(jq -r --argjson d "$FM_CAPACITY_EXHAUSTED_AT_DEFAULT" '
    (._availability.quota_gate.exhausted_at_percent_remaining // $d)
    | if (type == "number") and (. >= 0) and (. <= 100) then . else $d end' "$file" 2>/dev/null) \
    || v=$FM_CAPACITY_EXHAUSTED_AT_DEFAULT
  printf '%s\n' "$v"
}

# True when at least one configured provider declares a quota-axi binding.
# Without one, no model in this home can resolve to a quota-axi provider, so
# reading the tool could not change a single verdict - every model would land on
# its own per-provider reason either way. Skipping the read there keeps an
# unbound home, which is every home until an operator declares a binding, paying
# nothing for this gate while still getting the disclosure that names the field
# to add.
fm_capacity_binding_configured() {  # <config-file>
  local file=$1
  [ -f "$file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ "$(jq -r '[ (._providers // {}) | to_entries[]
                | select((.value | type) == "object")
                | select((.value.quota_axi_provider | type) == "string")
                | select((.value.quota_axi_provider | length) > 0) ] | length > 0' \
        "$file" 2>/dev/null)" = true ]
}

# fm_capacity_observe <config-file> <models-newline-separated>
# The observation record for those models. Always returns 0 and always prints a
# record: a source that could not be read is a could_not_observe VERDICT, not an
# error, because this gate can only remove candidates and removing none is the
# safe direction (see the header).
fm_capacity_observe() {
  local file=$1 models=$2 source thresh models_json now
  command -v jq >/dev/null 2>&1 || {
    printf '{"schema":"%s","observed_at":0,"source":{"status":"unreadable","detail":"jq is not installed","repair":"install jq"},"models":{},"exhausted":[],"unobserved":[],"earliest_recovery":null}\n' \
      "$FM_CAPACITY_SCHEMA"
    return 0
  }
  if fm_capacity_binding_configured "$file"; then
    fm_capacity_source
  else
    FM_CAPACITY_QUOTA=null
    FM_CAPACITY_SOURCE='{"status":"not_needed","detail":"no configured provider declares a quota-axi binding, so no read could change a verdict","repair":null}'
  fi
  source=$FM_CAPACITY_SOURCE
  thresh=$(fm_capacity_threshold "$file")
  now=$(date -u +%s)
  models_json=$(printf '%s\n' "$models" | jq -R -s -c '[ split("\n")[] | select(length > 0) ] | unique')
  jq -c --argjson quota "${FM_CAPACITY_QUOTA:-null}" \
        --argjson models "$models_json" \
        --argjson source "$source" \
        --argjson thresh "$thresh" \
        --argjson now "$now" \
        "$FM_CAPACITY_OBSERVE_JQ" \
        "$( [ -f "$file" ] && printf '%s' "$file" || printf '/dev/null' )" 2>/dev/null \
    || fm_capacity_all_unobserved "$models_json" "$now" \
         "the dispatch policy could not be read while observing capacity" \
         "repair config/crew-dispatch.json"
}

# EVERY requested model, reported as could-not-observe. A failed read is the one
# case where the third value matters most, and the earlier fallback emitted an
# empty models map with an empty unobserved list - which does not say "we could
# not tell", it says "there are no candidates". Downstream that reads as a pool
# with nothing in it: `fm-route.sh capacity` finds no non-exhausted model, and a
# deferral signature records `unknown` for a model whose row merely went
# missing. Collapsing could-not-observe into either definite value is precisely
# what the three-valued contract forbids, so the degraded record names every
# candidate and states plainly that none of them was measured.
fm_capacity_all_unobserved() {  # <models-json> <now> <detail> <repair>
  local models_json=$1 now=$2 detail=$3 repair=$4
  jq -c -n --argjson models "$models_json" --argjson now "$now" \
     --arg schema "$FM_CAPACITY_SCHEMA" --arg detail "$detail" --arg repair "$repair" '
    {schema: $schema, observed_at: $now,
     source: {status: "unreadable", detail: $detail, repair: $repair},
     models: ( $models
               | map({key: ., value: {model: ., verdict: "could_not_observe",
                                      until: null, evidence: $detail, repair: $repair}})
               | from_entries ),
     exhausted: [],
     unobserved: $models,
     earliest_recovery: null}'
}

# fm_capacity_lines <observation-json>
# The observation as the "<model><TAB><verdict><TAB><until><TAB><evidence>"
# lines bin/fm-route-lib.sh merges onto a decision record. The same shape the
# registry verdicts already use, so the merge seam stays one shape rather than
# two.
fm_capacity_lines() {  # <observation-json>
  printf '%s' "$1" | jq -r '
    .models[]? | [.model, .verdict, (.until // "" | tostring),
                  (.evidence + (if .repair != null and (.repair | length) > 0
                                then " - repair: " + .repair else "" end))]
    | @tsv' 2>/dev/null
}

# One human line per candidate, for a refusal or an operator listing. The
# verdict is always named, including could_not_observe, because a disclosure
# that is not printed is a disclosure nobody made.
fm_capacity_report_lines() {  # <observation-json>
  printf '%s' "$1" | jq -r '
    .models[]? | "  " + .model + ": " + .verdict + " - " + .evidence
      + (if .repair != null and (.repair | length) > 0 then " (repair: " + .repair + ")" else "" end)
  ' 2>/dev/null
}
