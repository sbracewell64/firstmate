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
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"
# fm-route-lib.sh sources fm-availability-lib.sh, so both the supported hold
# writer and the observation record's owner arrive together; wiring only one of
# them is how a probe result reaches half a record.
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# The fleet's three-valued observation type, whose fm_verify_case is what
# fm_availability_case delegates the exhaustiveness rule to. This script is a
# production consumer of that rule, not a test of it.
# shellcheck source=bin/fm-verify-lib.sh
. "$SCRIPT_DIR/fm-verify-lib.sh"
# The backlog backend, so a broken reader can file its own repair work through
# the infrastructure this home already uses rather than through a new store.
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# The open-item check a TOOLING_GAP dispatch is certified against, reused here
# so the sweep files an item that check will actually accept.
# shellcheck source=bin/fm-reasoning-lib.sh
. "$SCRIPT_DIR/fm-reasoning-lib.sh"

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
#
# The detail is SANITIZED here, at the boundary where provider text first enters
# this fleet's own records. It is the output of a remote service or a vendor CLI
# and it travels to two places that both matter - an operator's terminal and a
# durable record other tools read back - so terminal control sequences,
# credential-shaped strings and unbounded length are all removed by the record's
# owner before either sees it. Stripping tabs and newlines alone, which is what
# this used to do, protected the field boundaries and nothing else.
probe_record() {  # <key> <shape> <rc-or-empty> <latency-or-empty> <detail>
  local key=$1 shape=$2 rc=${3:-} lat=${4:-} detail=${5:-}
  [ -n "$rc" ] || rc='-'
  [ -n "$lat" ] || lat='-'
  [ -n "$detail" ] || detail="the reader exited without producing any output to report"
  detail=$(fm_availability_sanitize "$detail")
  fm_availability_has_substance "$detail" \
    || detail="the reader reported no evidence, which is itself the defect to repair"
  printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$shape" "$rc" "$lat" "$detail"
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
  local PROBE_CWD
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
  # A fresh EMPTY directory per probe, and the probe runs in it. Whatever
  # directory this sweep was started from is a real project with real
  # instructions, hooks and credentials in it, and a probe has no business
  # reading any of them. A failure to create one is a reader failure, which is a
  # could-not-observe like any other rather than a silently skipped isolation.
  PROBE_CWD=$(mktemp -d "${TMPDIR:-/tmp}/fm-model-probe.XXXXXX") || {
    probe_record "$key" 'unprobeable' '' '' \
      "could not create an isolated working directory for the probe, so it was not run"
    return 0
  }
  t0=$(date +%s)
  case "$harness" in
    claude)
      # THE PROBE RUNS WITH NOTHING OF THIS MACHINE'S ATTACHED TO IT. The
      # question is exactly "does this provider serve this model to this
      # account", and every ambient input is either a way to get a wrong answer
      # or a way for a probe to have a side effect. The pi arm has said
      # --no-tools --no-session since it was written; this arm used to pass only
      # --strict-mcp-config, which addresses MCP and nothing else, so its
      # boundary is spelled out in full here:
      #
      #   an empty working directory - no project CLAUDE.md, no .claude/, no
      #     project hooks, and nothing for a tool to reach even if one ran. A
      #     compromised repo cannot instruct or affect a probe it is not in.
      #   --setting-sources ''      - loads NO user, project or local settings,
      #     which is where hooks live. This is the one that makes "a hostile
      #     hook cannot fabricate a positive result" true rather than hoped.
      #   --strict-mcp-config with an empty --mcp-config - no MCP servers.
      #   --tools ''                - disables every built-in tool.
      #   --disallowed-tools        - deny known tools by name as a second layer.
      #   --no-session-persistence  - the probe leaves no session behind, the
      #     same property --no-session gives the pi arm.
      #   --agents '{}' --system-prompt - no subagents, and a fixed prompt in
      #     place of the inherited one.
      #
      # A flag this CLI stops accepting turns the probe into a client-error,
      # which is UNOBSERVABLE and a tooling gap - loud, and never a false
      # positive about the model.
      out=$( cd "$PROBE_CWD" && timeout "$PROBE_TIMEOUT" \
            env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
                -u CLAUDE_CODE_SIMPLE -u FM_HOME -u FM_TASK_ID \
            "$harness" -p --model "$model_id" \
            --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
            --tools '' \
            --disallowed-tools 'Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit' \
            --no-session-persistence --agents '{}' \
            --system-prompt 'Answer with one word only.' \
            'Reply with the single word: ok' \
            </dev/null 2>&1)
      rc=$?
      ;;
    *)
      out=$( cd "$PROBE_CWD" && timeout "$PROBE_TIMEOUT" "$harness" -p --provider "$provider" --model "$model_id" \
            --no-tools --no-session --thinking off 'Reply with the single word: ok' \
            </dev/null 2>&1)
      rc=$?
      ;;
  esac
  rm -rf "$PROBE_CWD"
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
    PROBE_KEYS[n]=$key
    probe_one "$key" "$harness" "$provider" "$model_id" > "$TMPD/$n.out" 2>/dev/null &
    PROBE_PIDS[n]=$!
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

# The repair item a broken reader files against itself, and the ONE place the
# `broken reader -> TOOLING_GAP -> reader repair work` loop closes.
#
# The gap block used to record `backlog_item: null` always, which closed the
# first hop and left the second to whoever happened to read the record. The
# backlog is already this fleet's issue store and bin/fm-reasoning-lib.sh
# already requires a TOOLING_GAP dispatch to name an OPEN item in it, so the
# item is filed here through the same backend the rest of this home uses. No new
# store, no second tracker.
#
# The id is DERIVED from the candidate, so the same broken reader converges on
# the same item instead of filing a new one on every sweep, and an item that is
# already open is reused rather than duplicated.
#
# Prints ONE token on stdout either way: the item id with status 0, or an
# `unfiled-<why>` status with status 1. Failing to file is never fatal - an
# unobservable candidate must still be recorded and still excluded - and the
# caller records the reason, so an unfiled repair is an explicitly incomplete
# record rather than a silent null.
# shellcheck disable=SC2329 # Reached only from a handler invoked by name.
gap_backlog_item() {  # <model-key>
  local key=$1 id
  # One id per candidate, in the backlog's own slug shape.
  id="reader-repair-$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  if fm_backlog_item_open "$DATA" "$id"; then
    printf '%s\n' "$id"
    return 0
  fi
  if ! fm_tasks_axi_backend_available "$CONFIG"; then
    # A home that has opted out of the backlog tool, or has no compatible one,
    # gets an explicitly incomplete record rather than a fabricated item id.
    printf 'unfiled-backend-unavailable\n'
    return 1
  fi
  if ! ( cd "$FM_HOME" && tasks-axi add "$id" \
           "repair the availability reader for $key" \
           --kind ship --body "bin/fm-model-verify.sh could not observe $key. The candidate is excluded from routing until the reader answers. Evidence: state/model-observation.json, and bin/fm-route.sh availability gaps." \
         ) >/dev/null 2>&1; then
    printf 'unfiled-backend-refused\n'
    return 1
  fi
  # Filed is not the same as findable. The certification check reads open
  # checkbox lines out of the backlog file, so the item is confirmed through
  # that same reader before it is recorded as filed.
  if fm_backlog_item_open "$DATA" "$id"; then
    printf '%s\n' "$id"
    return 0
  fi
  printf 'unfiled-not-open-after-add\n'
  return 1
}

# The three handlers, one per observation. They are separate functions rather
# than arms of a `case` so this script consumes the result through
# fm_availability_case, which delegates to fm_verify_case and therefore refuses
# a consumer that branches two ways or folds could-not-observe into either other
# outcome. That rule used to be available in a library and enforced only in
# tests, while production branched on the value directly with `*)` as the
# AVAILABLE arm - so an empty or unexpected observation reached the permissive
# branch. That is the original defect class, in the consumer built to prevent it.
#
# Each reads the loop's variables by dynamic scope, exactly as fm_verify_case's
# contract describes.
# shellcheck disable=SC2329 # Invoked by name through fm_availability_case.
record_available() {
  # AVAILABLE records the observation and nothing else. It never releases a
  # hold: releasing is an explicit decision with its own supported command, and
  # a positive probe that quietly cleared an admin_disabled hold would be stale
  # evidence overriding a deliberate one.
  fm_availability_record_write "$STATE" "$key" "$FM_AVAIL_AVAILABLE" "$shape" \
    "bin/fm-model-verify.sh" "$detail" "$lat" "$NOW_ISO"
}

# shellcheck disable=SC2329 # Invoked by name through fm_availability_case.
record_unavailable() {
  local hold_state rc
  # THE HOLD IS WRITTEN FIRST, and this order is the safety property. Routing
  # reads both records, but the hold is the one that carries an expiry and a
  # release command, so it is the one an operator acts on. Writing the
  # observation first meant a failed or raced hold write left a durable
  # observed-unavailable result behind with no exclusion attached to it. Now the
  # fail-closed record lands first, and if the second write fails the candidate
  # is still excluded rather than still eligible.
  fm_availability_transition_begin "$STATE" || return 1
  if hold_state=$(fm_availability_hold_state "$shape"); then
    if ! fm_route_health_write "$STATE" model "$key" "$hold_state" '' \
           "probe $shape at $NOW_ISO: $detail"; then
      # Hold subject resolution fails for a model no routed pool names, which is
      # benign - routing cannot select such a model at all - and it also fails
      # for a malformed record, which is not. The observation is recorded either
      # way, and it is independently enforced by routing, so the pair cannot
      # come apart into "measured unavailable, treated as eligible".
      echo "MODEL_VERIFY: $key was established UNAVAILABLE and its availability hold could not be written; the observation record is what is excluding it" >&2
    fi
  fi
  fm_availability_record_write_locked "$STATE" "$key" "$FM_AVAIL_UNAVAILABLE" "$shape" \
    "bin/fm-model-verify.sh" "$detail" "$lat" "$NOW_ISO"
  rc=$?
  fm_availability_transition_end "$STATE"
  return "$rc"
}

# shellcheck disable=SC2329 # Invoked by name through fm_availability_case.
record_unobservable() {
  local routes gap item status
  # The routes a broken reader is currently blocking are part of the repair
  # evidence: a gap on a candidate no pool names costs nothing, and one on a
  # single-candidate pool has stopped a route outright.
  routes=$(fm_route_routes_for_model "$CONFIG" "$key" 2>/dev/null || true)
  if item=$(gap_backlog_item "$key"); then status=; else status=$item; item=; fi
  gap=$(fm_availability_gap_block "$reader" \
    "$key" 'entitlement-and-liveness' "$shape" "$detail" "$NOW_ISO" "$routes" "$item" "$status")
  fm_availability_record_write "$STATE" "$key" "$FM_AVAIL_UNOBSERVABLE" "$shape" \
    "$reader" "$detail" "$lat" "$NOW_ISO" "$gap"
}

record_results() {
  local key shape rc lat detail observation reader
  while IFS=$'\t' read -r key shape rc lat detail; do
    [ -n "$key" ] || continue
    [ "$rc" != '-' ] || rc=
    [ "$lat" != '-' ] || lat=
    reader="bin/fm-model-verify.sh probe via ${HARNESS_OF[$key]:-an unresolved harness}"
    observation=$(fm_availability_from_shape "$shape" 2>/dev/null)
    fm_availability_case "$observation" "$reader" "$detail" \
      record_available record_unavailable record_unobservable || return 1
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
        # The repair item is named rather than requested. Filing it is the
        # sweep's own job now, so this line reports which item to dispatch, or
        # UNFILED with the reason when the backlog backend could not be used.
        item=$(jq -r --arg k "$key" \
          '.models[$k].tooling_gap | (.backlog_item // ("UNFILED (" + (.backlog_item_status // "reason unrecorded") + ")"))' \
          "$(fm_availability_record_path "$STATE")" 2>/dev/null || true)
        echo "TOOLING_GAP: $key could not be observed by bin/fm-model-verify.sh ($shape, rc=${rc:--}, ${lat:--}s) - $detail. This is a broken reader, not a provider fact: the candidate is excluded from routing until the reader is repaired, and releasing a hold will not restore it. Repair item=${item:-UNFILED}; see fm-route.sh availability gaps for the recorded evidence."
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
