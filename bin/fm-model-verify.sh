#!/usr/bin/env bash
# fm-model-verify.sh - live entitlement probes and local price-drift checks for
# the models config/models.json says this home routes to.
# Usage: fm-model-verify.sh [--all] [--model <provider/model>] [--drift-only]
#                           [--dry-run] [--force-probe] [--json] [--timeout <s>]
#          Default: probe only routed models whose recorded evidence is older
#          than their observation level's interval, then run the price-drift
#          comparison. Prints ONE line per model that needs firstmate's attention
#          and nothing at all when everything is current - it runs on the
#          session-start path, so silence is the normal outcome.
#        --all         probe every routed model regardless of its interval.
#        --model       probe exactly this model, ignoring the interval.
#        --drift-only  skip probing entirely; only compare stored prices.
#        --dry-run     print what would be probed, probe nothing.
#        --force-probe probe a model the zero-budget cost decision refuses; the
#                      only override, and it announces itself on stdout.
#        --json        emit the health record to stdout instead of the summary.
#        --timeout     hard ceiling in seconds for the whole sweep (default 90).
#          Exits 0 when everything is current, 2 when any line was printed.
#
# NO PROBE WITHOUT A COST VERDICT. Every probe path, including an explicit
# --model, consults fm_model_zero_budget_decision before issuing a live request:
# the instrument that catches an entitlement error is itself a billable act on a
# metered provider, which is why cost class is established before entitlement
# and not after. A typed --model is not authorization to spend money - under the
# zero-budget rule spending is never implied, only explicitly flagged, and the
# flag is --force-probe.
#
# WHY BOTH CHECKS, FOREVER. The two things that decay are not properties of the
# model - they are properties of the ACCOUNT and of the provider's price list, and
# both change without warning. A model can be perfectly stable while its
# entitlement is revoked and its price is raised. So observation never reaches
# zero: at the maintenance floor these two checks still run.
#   1. The entitlement probe catches a routed model this account cannot actually
#      use. That failure has happened here: a model was configured from a
#      plausible name, never probed, and every dispatch to that tier failed at
#      launch until an investigation found it.
#   2. The price-drift check is the ONLY thing that can catch a repricing,
#      because a name-based allowlist is structurally blind to it. It is a local
#      file read and costs nothing.
#
# STDIN IS ALWAYS CLOSED ON A PROBE. `pi -p` can hang indefinitely with stdin
# open. A wedged probe inside the session-start path would present to supervision
# as a stale session - the monitor becoming the fault - so every probe redirects
# from /dev/null and additionally runs under `timeout`.
#
# THIS SCRIPT NEVER WRITES config/models.json. Availability is volatile and lives
# in state/model-health.json; the registry's status is a durable ROUTING decision.
# Conflating them would make every transient outage permanently degrade the
# routing table, which is exactly the failure the demotion policy is built to
# avoid. A rate-limited model is unavailable, not demoted.
#
# NOR DOES IT WRITE state/model-health.json DIRECTLY, and that is a repair. It
# used to merge its own probe schema into that file, which bin/fm-route-lib.sh
# owns as a NEGATIVE-ONLY hold register keyed on an entry's mere presence. Every
# probed model therefore became a permanent hold - including models whose probe
# had positively reported them reachable - and a harness with no probe path
# recorded the same shape under a state, `unknown`, that no policy condition
# defines and no reason accompanied. Holds now go through that library's
# supported writer in its own closed vocabulary, and what the probe OBSERVED
# goes to state/model-observation.json, whose schema is honest about the third
# value: a probe that could not run observed nothing.
#
# WHERE EACH OF THE THREE OBSERVATIONS LANDS. bin/fm-availability-lib.sh owns
# the mapping; this script owns only the writing.
#   AVAILABLE     an observation entry. No hold, and no release either: a
#                 positive probe never clears a hold somebody else recorded.
#   UNAVAILABLE   an observation entry plus a hold through the supported writer.
#   UNOBSERVABLE  an observation entry carrying a TOOLING_GAP evidence block and
#                 NO hold, because a broken reader is not a provider fact. The
#                 candidate is still excluded from routing - fail-closed is
#                 preserved - but the refusal now names the reader to repair
#                 instead of a hold that releasing would not fix.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"
# fm-route-lib.sh sources fm-availability-lib.sh, so both the supported hold
# writer and the observation record's owner arrive together; wiring only one of
# them is how a probe result reaches half a record.
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"

ALL=0
ONE=
DRIFT_ONLY=0
DRY_RUN=0
FORCE_PROBE=0
AS_JSON=0
TOTAL_TIMEOUT=90
PROBE_TIMEOUT=25

want=
for a in "$@"; do
  if [ -n "$want" ]; then
    case "$want" in
      model)   ONE=$a ;;
      timeout) TOTAL_TIMEOUT=$a ;;
    esac
    want=
    continue
  fi
  case "$a" in
    --all) ALL=1 ;;
    --model) want=model ;;
    --model=*) ONE=${a#--model=} ;;
    --drift-only) DRIFT_ONLY=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --force-probe) FORCE_PROBE=1 ;;
    --json) AS_JSON=1 ;;
    --timeout) want=timeout ;;
    --timeout=*) TOTAL_TIMEOUT=${a#--timeout=} ;;
    *) echo "error: unknown argument '$a'" >&2; exit 1 ;;
  esac
done
[ -z "$want" ] || { echo "error: --$want requires a value" >&2; exit 1; }
case "$TOTAL_TIMEOUT" in
  ''|*[!0-9]*) echo "error: --timeout must be a whole number of seconds" >&2; exit 1 ;;
esac

REG="$CONFIG/models.json"
[ -f "$REG" ] || { [ "$AS_JSON" = 1 ] && echo '{}'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "MODEL_VERIFY: jq is required and not installed"; exit 0; }

if ! err=$(fm_model_registry_validate "$REG"); then
  echo "MODEL_REGISTRY: invalid config/models.json - $err"
  exit 0
fi

NOW_EPOCH=$(date -u +%s)
NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
declare -A HARNESS_OF=()
declare -a PROBE_PIDS=() PROBE_KEYS=()

# ---------------------------------------------------------------------------
# Select the models to probe
# ---------------------------------------------------------------------------
# A model is due when its recorded probe evidence is older than the interval its
# observation level names. Interval-gating is what keeps this affordable on the
# session-start path: in the steady state nothing is due and the sweep costs one
# file read.
select_due() {
  local out rc
  # Bind .key/.value to variables BEFORE any `x | y` pipe: inside a pipe the
  # input rebinds, so `select(approved | index(.value.status))` would index the
  # approved ARRAY rather than the entry. That mistake fails the whole query, and
  # a swallowed failure here would read as "nothing is due" - a sweep that never
  # probes while appearing healthy. Hence the explicit rc check below.
  out=$(jq -r --argjson now "$NOW_EPOCH" --argjson all "$ALL" '
    def secs($iso):
      ($iso // "") as $t
      | if ($t | length) == 0 then null
        else (try ($t | sub("Z$"; "+0000") | strptime("%Y-%m-%dT%H:%M:%S%z") | mktime) catch null)
        end;
    def approved: ["approved-primary","approved-fallback","approved-specialist"];
    . as $r
    | ($r.models // {}) | to_entries[]
    | .key as $k | .value as $e
    | ($e.status? // "") as $st
    | select(approved | index($st))
    | (($r.observation?.levels?[($e.observation_level? // "O4")]?.probe_max_age_days?) // 1) as $maxd
    | (secs($e.evidence?.probe?.at?)) as $at
    | select($all == 1 or $at == null or (($now - $at) > ($maxd * 86400)))
    | [$k, ($e.harness? // "pi"), ($e.provider? // ($k | split("/")[0])),
       ($e.model_id? // ($k | split("/") | .[1:] | join("/")))]
    | @tsv
  ' "$REG" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "MODEL_VERIFY: could not determine which models are due for a probe: $out" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

if [ -n "$ONE" ]; then
  DUE=$(jq -r --arg k "$ONE" '
    (.models[$k]? // null) as $e
    | if $e == null then empty
      else [$k, ($e.harness? // "pi"), ($e.provider? // ($k | split("/")[0])),
            ($e.model_id? // ($k | split("/") | .[1:] | join("/")))] | @tsv end' "$REG" 2>/dev/null || true)
  if [ -z "$DUE" ]; then
    echo "MODEL_VERIFY: $ONE is not in config/models.json"
    exit 1
  fi
else
  DUE=$(select_due) || exit 2
fi

# ---------------------------------------------------------------------------
# Cost gate: no live request without a zero-budget verdict
# ---------------------------------------------------------------------------
# The probe that catches an entitlement error is itself a billable act on a
# metered provider, which is why cost class is established BEFORE entitlement
# and not after. Both paths land here - the interval-gated sweep and an explicit
# --model - because a typed model name is not authorization to spend money. A
# refused model is skipped entirely: no request is issued and its prior health
# record is left untouched. --force-probe is the only override, and it announces
# itself so an authorized billable probe is never invisible in the output.
NEEDS_ACTION=0
if [ "$DRIFT_ONLY" != 1 ] && [ -n "$DUE" ]; then
  ALLOWED=
  while IFS=$'\t' read -r key harness provider model_id; do
    [ -n "$key" ] || continue
    if reason=$(fm_model_zero_budget_decision "$key"); then
      ALLOWED="${ALLOWED}${key}"$'\t'"${harness}"$'\t'"${provider}"$'\t'"${model_id}"$'\n'
    elif [ "$FORCE_PROBE" = 1 ]; then
      echo "MODEL_VERIFY: --force-probe overrides the cost refusal for $key - this probe is a billable act: $reason"
      ALLOWED="${ALLOWED}${key}"$'\t'"${harness}"$'\t'"${provider}"$'\t'"${model_id}"$'\n'
    else
      echo "MODEL_VERIFY: refusing to probe $key - $reason (--force-probe is the only override)"
      NEEDS_ACTION=1
    fi
  done <<EOF
$DUE
EOF
  DUE=$ALLOWED
fi

# ---------------------------------------------------------------------------
# Probe
# ---------------------------------------------------------------------------
# One probe result as one line, and the ONLY place this file's wire format is
# spelled: "<key>\t<shape>\t<rc>\t<latency>\t<detail>".
#
# NO FIELD IS EVER EMPTY, and that is a fix rather than a style. Tab is an IFS
# WHITESPACE character, so bash's `read` collapses a run of consecutive tabs into
# a single delimiter: a record printed as `key\tshape\t\t\tdetail` was read back
# with the detail sitting in `rc` and the detail variable empty, which is exactly
# how this fleet's session start came to report `claude/opus could not be probed
# - ` with nothing after the dash. A failure that cannot say why is a failure
# nobody can repair, so absent numbers are written `-` and an empty detail is
# replaced by a statement that the reader produced none.
probe_record() {  # <key> <shape> <rc-or-empty> <latency-or-empty> <detail>
  local key=$1 shape=$2 rc=${3:-} lat=${4:-} detail=${5:-}
  [ -n "$rc" ] || rc='-'
  [ -n "$lat" ] || lat='-'
  [ -n "$detail" ] || detail="the reader exited without producing any output to report"
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$shape" "$rc" "$lat" "$(printf '%s' "$detail" | tr -d '\t\n')"
}

# One probe. stdin closed (</dev/null) AND bounded by `timeout` - two independent
# reasons this cannot wedge the caller.
#
# TWO PROBE PATHS, because a harness with none is a reader that cannot observe.
# `claude` had no arm here, so every claude-routed model recorded a
# could-not-observe forever while being demonstrably entitled and live. Its
# command shape is not invented: config/models.json's own identity evidence for
# claude/opus records `claude -p --model opus` as how that model's resolved id
# was established, so this is the already-verified path rather than a new one.
probe_one() {
  local key=$1 harness=$2 provider=$3 model_id=$4 out rc t0 t1 lat shape
  case "$harness" in
    pi|pi-signed|claude) ;;
    *)
      probe_record "$key" 'unprobeable' '' '' \
        "no verified probe path for harness $harness, so nothing observed this model"
      return 0
      ;;
  esac
  if ! command -v "$harness" >/dev/null 2>&1; then
    probe_record "$key" 'unprobeable' '' '' \
      "$harness is not installed on this machine, so the reader could not run"
    return 0
  fi
  t0=$(date +%s)
  case "$harness" in
    claude)
      # --strict-mcp-config keeps a probe from loading this home's MCP servers:
      # the question is whether the provider serves this model, and a probe that
      # drags in unrelated tooling can fail for reasons that say nothing about it.
      out=$(timeout "$PROBE_TIMEOUT" "$harness" -p --model "$model_id" \
            --strict-mcp-config 'Reply with the single word: ok' \
            </dev/null 2>&1)
      rc=$?
      ;;
    *)
      out=$(timeout "$PROBE_TIMEOUT" "$harness" -p --provider "$provider" --model "$model_id" \
            --no-tools --no-session --thinking off 'Reply with the single word: ok' \
            </dev/null 2>&1)
      rc=$?
      ;;
  esac
  t1=$(date +%s)
  lat=$((t1 - t0))
  if [ "$rc" = 124 ]; then
    probe_record "$key" 'timeout' "$rc" "$lat" "probe exceeded ${PROBE_TIMEOUT}s without returning"
    return 0
  fi
  shape=$(fm_model_probe_classify "$rc" "$out")
  probe_record "$key" "$shape" "$rc" "$lat" "$(printf '%s' "$out" | head -1)"
}

RESULTS=
if [ "$DRIFT_ONLY" != 1 ] && [ -n "$DUE" ]; then
  if [ "$DRY_RUN" = 1 ]; then
    while IFS=$'\t' read -r key harness provider model_id; do
      [ -n "$key" ] || continue
      echo "MODEL_VERIFY: would probe $key via $harness ($provider/$model_id)"
    done <<EOF
$DUE
EOF
    exit 0
  fi
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-verify.XXXXXX") || exit 1
  trap 'rm -rf "$TMPD"' EXIT
  n=0
  while IFS=$'\t' read -r key harness provider model_id; do
    [ -n "$key" ] || continue
    # Which reader was asked is part of a tooling gap's repair evidence, and the
    # result line carries only what the reader observed, so the binding is kept
    # here rather than widened into the wire format.
    HARNESS_OF[$key]=$harness
    n=$((n + 1))
    PROBE_KEYS[$n]=$key
    probe_one "$key" "$harness" "$provider" "$model_id" > "$TMPD/$n.out" 2>/dev/null &
    PROBE_PIDS[$n]=$!
  done <<EOF
$DUE
EOF
  # Hard total ceiling for the whole sweep: reap whatever finished by the
  # deadline and turn every straggler into an observation of the failed reader.
  deadline=$((NOW_EPOCH + TOTAL_TIMEOUT))
  while [ -n "$(jobs -pr)" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep 1
  done
  running="$(jobs -pr)"
  timed_out=()
  for i in "${!PROBE_PIDS[@]}"; do
    pid=${PROBE_PIDS[$i]}
    if printf '%s\n' "$running" | grep -qx "$pid"; then
      timed_out+=("$i")
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  for i in "${timed_out[@]}"; do
    probe_record "${PROBE_KEYS[$i]}" 'timeout' 124 "$TOTAL_TIMEOUT" \
      "sweep exceeded its ${TOTAL_TIMEOUT}s total ceiling before this probe returned" > "$TMPD/$i.out"
  done
  RESULTS=$(cat "$TMPD"/*.out 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Record what each probe OBSERVED, in the three-valued type
# ---------------------------------------------------------------------------
# bin/fm-availability-lib.sh decides what each shape means and owns the
# observation record; bin/fm-route-lib.sh's supported writer owns holds. This
# loop only routes each result to the right one of them, so no schema is
# authored here and none can cross into the other's file again.
mkdir -p "$STATE"

record_results() {
  local key shape rc lat detail observation hold_state routes gap reader
  while IFS=$'\t' read -r key shape rc lat detail; do
    [ -n "$key" ] || continue
    [ "$rc" != '-' ] || rc=
    [ "$lat" != '-' ] || lat=
    reader="bin/fm-model-verify.sh probe via ${HARNESS_OF[$key]:-an unresolved harness}"
    observation=$(fm_availability_from_shape "$shape" 2>/dev/null)
    case "$observation" in
      "$FM_AVAIL_UNOBSERVABLE")
        # The routes a broken reader is currently blocking are part of the
        # repair evidence: a gap on a candidate no pool names costs nothing,
        # and one on a single-candidate pool has stopped a route outright.
        routes=$(fm_route_routes_for_model "$CONFIG" "$key" 2>/dev/null || true)
        gap=$(fm_availability_gap_block "$reader" \
          "$key" 'entitlement-and-liveness' "$shape" "$detail" "$NOW_ISO" "$routes" '')
        fm_availability_record_write "$STATE" "$key" "$observation" "$shape" \
          "$reader" "$detail" "$lat" "$NOW_ISO" "$gap" || return 1
        ;;
      "$FM_AVAIL_UNAVAILABLE")
        fm_availability_record_write "$STATE" "$key" "$observation" "$shape" \
          "bin/fm-model-verify.sh" "$detail" "$lat" "$NOW_ISO" || return 1
        # Through the supported writer, in ITS closed vocabulary. A hold this
        # script authored directly is the defect this whole path exists to end.
        if hold_state=$(fm_availability_hold_state "$shape"); then
          fm_route_health_write "$STATE" model "$key" "$hold_state" '' \
            "probe $shape at $NOW_ISO: $detail" || return 1
        fi
        # A model no routed pool names cannot be held by subject resolution and
        # does not need to be: the observation record already carries the fact.
        ;;
      *)
        # AVAILABLE records the observation and nothing else. It never releases
        # a hold: releasing is an explicit decision with its own supported
        # command, and a positive probe that quietly cleared an admin_disabled
        # hold would be stale evidence overriding a deliberate one.
        fm_availability_record_write "$STATE" "$key" "$observation" "$shape" \
          "bin/fm-model-verify.sh" "$detail" "$lat" "$NOW_ISO" || return 1
        ;;
    esac
  done <<EOF
$RESULTS
EOF
}

if [ -n "$RESULTS" ]; then
  record_results || echo "MODEL_VERIFY: one or more probe results could not be recorded, so this sweep observed less than it reports"
fi

if [ "$AS_JSON" = 1 ]; then
  # The observation record, because that is what this command produced. The hold
  # record is a different question with a different owner: read it with
  # fm-route.sh availability.
  OBS=$(fm_availability_record_path "$STATE")
  if [ -f "$OBS" ]; then cat "$OBS"; else printf '{"models":{}}\n'; fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Report only what firstmate should act on
# ---------------------------------------------------------------------------
if [ -n "$RESULTS" ]; then
  while IFS=$'\t' read -r key shape rc lat detail; do
    [ -n "$key" ] || continue
    case "$shape" in
      ok) ;;
      entitlement-refused)
        echo "MODEL_VERIFY: $key is REFUSED by the provider for this account - it must not be routed to: $detail"
        NEEDS_ACTION=1
        ;;
      unknown-model)
        echo "MODEL_VERIFY: $key was not recognised by its provider (identity error, not an outage): $detail"
        NEEDS_ACTION=1
        ;;
      *)
        # Every remaining shape is a could-not-observe, and it is reported as
        # repairable work rather than as a fact about the model. The reason is
        # always present: this line existing with nothing after the dash is the
        # exact defect the record format was changed to make impossible.
        echo "TOOLING_GAP: $key could not be observed by bin/fm-model-verify.sh ($shape, rc=${rc:--}, ${lat:--}s) - $detail. This is a broken reader, not a provider fact: the candidate is excluded from routing until the reader is repaired, and releasing a hold will not restore it. File the repair as backlog work and see fm-route.sh availability gaps."
        NEEDS_ACTION=1
        ;;
    esac
  done <<EOF
$RESULTS
EOF
fi

# The hold record's own integrity, reported where the probe path can see it.
# Foreign entries can only come from a writer that is not the supported one, and
# each one is silently excluding a candidate under a state no policy defines.
# Detect-only by design: reinterpreting them here would re-admit candidates
# nothing ever cleared, so the repair is named and left to the supported writer.
foreign=$(fm_route_health_foreign_entries "$STATE" 2>/dev/null || true)
if [ -n "$foreign" ]; then
  while read -r scope subject state; do
    [ -n "$subject" ] || continue
    echo "MODEL_VERIFY: the availability record holds $scope $subject under '$state', which is not an availability state this fleet defines, so it is excluding that candidate under a hold no policy condition set. Repair it with: bin/fm-route.sh availability release $subject$( [ "$scope" = provider ] && printf ' --scope provider')"
    NEEDS_ACTION=1
  done <<EOF
$foreign
EOF
fi

drift=$(fm_model_price_drift "$REG" || true)
if [ -n "$drift" ]; then
  printf '%s\n' "$drift"
  NEEDS_ACTION=1
fi

# Exit 2 when anything was printed, so a caller can branch on the result without
# re-parsing the lines. Bootstrap deliberately ignores this and treats the printed
# lines as the signal, matching every other detect-only check there.
[ "$NEEDS_ACTION" = 0 ] || exit 2
exit 0
