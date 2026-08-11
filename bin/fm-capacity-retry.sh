#!/usr/bin/env bash
# fm-capacity-retry.sh - the durable record of work that was DEFERRED because no
# model meeting its capability floor had capacity, and the code that resumes it
# when capacity returns.
#
# THE FAILURE THIS CLOSES. Recovering from an exhausted provider window used to
# require a human to notice and say continue. Work that was lawful to run sat
# idle, not because anything was wrong with it, but because the only thing that
# could restart it was attention. Overnight 2026-08-10/11 that cost five lanes a
# night. Nothing here decides what to run or which model runs it; it only makes
# an already-authorized dispatch resume by itself once the reason it was held
# has cleared.
#
# THIS IS NOT A SECOND SCHEDULER, AND THE DISTINCTION IS THE WHOLE DESIGN. It
# evaluates no route, reads no floor and applies no policy of its own. What it
# does on resume is offer the route owner's eligible pool, in pool order, back
# to bin/fm-spawn.sh with the SAME typed dispatch fields and recorded effort
# band. The route owner excludes candidates that cannot express that band, and
# spawn rechecks ROUTE, capacity, ADMIT, the model registry, the attempt budget
# and the pool-slot check at the one chokepoint that owns them.
#
# NO STORED COMMAND LINE. The record holds TYPED FIELDS and nothing else, and
# every one is re-validated against its own closed vocabulary or path-safety
# rule before it is passed as a separate argv element to a direct execution of
# bin/fm-spawn.sh. Nothing is ever expanded by a shell. A state file that could
# name a command to run would turn this directory into an execution vector, and
# this repo has already paid once for that shape in state/<id>.check.sh - hence
# fm-check-register.sh and the .pr-check-quarantine sweep. The lesson is applied
# here rather than relearned.
#
# WHY RESUMING IS NOT A NEW AUTHORITY. The deferral records a dispatch firstmate
# had already decided to make: this task, this project, this delivery mode, this
# yolo posture, this route. Only capacity stopped it. Completing that decision
# once its single blocker clears is finishing an authorized action, not taking a
# new one, and every gate that authorized it runs again on the way through. It
# spends no attempt, because a task the fleet had no capacity for did not fail.
#
# WHY NO MODEL TURN IS SPENT. The tick is CODE, called from the watcher's
# existing per-cycle reconciliation and from session start. It never asks an
# agent whether capacity has returned, and it does not poll a provider on a
# timer either: a deferral is re-checked no earlier than the reset time the
# provider itself published, and when no provider published one, on a doubling
# backoff. A capacity check costs one bounded quota-axi read, not a turn.
#
# DURABILITY. state/<id>.capacity is a plain key=value file, so a deferral
# survives firstmate restart, terminal closure, host reboot and session
# replacement. Nothing here keys on a pid: this fleet has measured that after any
# restart every pid-based record is invalid at once, so recovery is keyed on the
# task id and on the record's own timestamps.
#
# BOUNDS. Every deferral is counted by bin/fm-attempt.sh, which owns both the
# total deferral budget and the stagnation rule that stops a wait whose observed
# capacity picture has not moved. Reaching either bound is the unified terminal
# state budget_exhausted, declared as a `failed:` status line by that owner. This
# file never invents a second counter. If that owner cannot record the count,
# the wait fails closed because no enforceable bound remains.
#
# Usage:
#   fm-capacity-retry.sh defer <id> --route <R> --floor <F> --pool <a,b,...>
#                                   --reason <text> [--retry-after <epoch>]
#                                   [--signature <s>] --project <dir>
#                                   (--mode <m> --yolo <on|off> | --scout)
#                                   --reason-code <CODE>
#                                   [--harness <h>] [--model <m>] [--effort <e>]
#                                   [--backend <b>] [--tooling-gap-item <id>]
#                                   [--attempt-budget <n>] [--slot-base <ref>]
#                                   [--contribution-target <ref>]
#       Record or refresh one capacity deferral and count it. Exit 0 when the
#       wait is still within bounds, 3 when a bound is spent. Called by
#       bin/fm-spawn.sh at the moment it refuses a dispatch for capacity.
#   fm-capacity-retry.sh tick [--id <id>] [--force]
#       Resume every deferral whose retry condition is met, by re-entering
#       bin/fm-spawn.sh. --force ignores the retry condition for one named id.
#       Prints one line per deferral acted on and nothing for a quiet sweep.
#   fm-capacity-retry.sh list [--json]
#       Every deferral this home holds, with its state and next check.
#   fm-capacity-retry.sh release <id>
#       Drop a deferral without resuming it. Used by teardown and by an operator
#       who has decided the work should not run.
#   fm-capacity-retry.sh --help
#
# Exit status:
#   0  the requested action completed - including a tick that resumed nothing
#      because nothing was due, which is the ordinary quiet case
#   1  the action could not be completed and the reason is on stderr
#   2  usage error
#   3  a deferral bound is spent, so this work has stopped waiting
#
# Environment:
#   FM_HOME                       the firstmate home whose state/ is read
#   FM_CAPACITY_RECHECK_BASE      seconds before the first blind re-check (900)
#   FM_CAPACITY_RECHECK_CAP       the ceiling that backoff doubles toward (10800)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-reasoning-lib.sh
. "$SCRIPT_DIR/fm-reasoning-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# shellcheck source=bin/fm-capacity-lib.sh
. "$SCRIPT_DIR/fm-capacity-lib.sh"

RECHECK_BASE=${FM_CAPACITY_RECHECK_BASE:-900}
RECHECK_CAP=${FM_CAPACITY_RECHECK_CAP:-10800}
CAPACITY_SCHEMA=fm-capacity-deferral.v1
ATTEMPT_BIN=${FM_ATTEMPT_BIN:-$FM_ROOT/bin/fm-attempt.sh}
RECORD_COMMIT_BIN=${FM_CAPACITY_RECORD_COMMIT_BIN:-mv}
# The stable token a resumed dispatch prints, so a supervisor can tell an
# automatic resume from an operator one without reading prose.
CAPACITY_RESUMED_TOKEN=FM_CAPACITY_RESUMED

usage() {
  LC_ALL=C awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-capacity-retry.sh"
}

die() { printf 'error: %s\n' "$1" >&2; exit 2; }

is_count() { case "${1-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

record_path() { printf '%s/%s.capacity\n' "$STATE" "$1"; }

# One key's value from a key=value record, last assignment winning. An absent
# file or key yields the empty string, and every caller decides what absence
# means rather than being handed a guess.
field() {  # <file> <key>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$1"
}

# Values are stored one per line in a key=value record, so a newline or a tab
# would silently truncate or corrupt the field that follows. Collapsed rather
# than rejected: a caller assembling a reason sentence should not have to know
# this file's storage format.
clean() { printf '%s' "${1-}" | LC_ALL=C tr '\t\r\n' '   '; }

# ---------------------------------------------------------------------------
# Field validation - every stored value is re-checked before it becomes argv
# ---------------------------------------------------------------------------

# A value that could be read as a flag, or that carries a control character, is
# refused rather than passed on. Nothing here is ever expanded by a shell, so
# quoting is not the exposure; a value that starts with a dash silently becoming
# an option to bin/fm-spawn.sh is.
plain_value() {  # <value>
  case "${1-}" in
    -*) return 1 ;;
    *[![:print:]]*) return 1 ;;
    *) return 0 ;;
  esac
}

valid_mode() {  # <mode>
  case "${1-}" in no-mistakes|direct-PR|local-only) return 0 ;; *) return 1 ;; esac
}

valid_yolo() {  # <yolo>
  case "${1-}" in on|off) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# defer - record or refresh one deferral, and count it
# ---------------------------------------------------------------------------

cmd_defer() {
  local id=${1-} rec tmp now
  local route='' floor='' pool='' reason='' retry_after=0 signature=''
  local project='' mode='' yolo='' scout=0 reason_code='' harness='' model='' effort=''
  local backend='' tooling_gap_item='' attempt_budget='' defer_out rc first_deferred
  local slot_base='' contribution_target=''
  [ -n "$id" ] || die "defer needs a task id"
  fm_task_id_path_safe "$id" || die "invalid task id: $id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --route) [ "$#" -ge 2 ] || die "--route needs a value"; route=$2; shift 2 ;;
      --floor) [ "$#" -ge 2 ] || die "--floor needs a value"; floor=$2; shift 2 ;;
      --pool) [ "$#" -ge 2 ] || die "--pool needs a value"; pool=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      --retry-after) [ "$#" -ge 2 ] || die "--retry-after needs a value"; retry_after=$2; shift 2 ;;
      --signature) [ "$#" -ge 2 ] || die "--signature needs a value"; signature=$2; shift 2 ;;
      --project) [ "$#" -ge 2 ] || die "--project needs a value"; project=$2; shift 2 ;;
      --mode) [ "$#" -ge 2 ] || die "--mode needs a value"; mode=$2; shift 2 ;;
      --yolo) [ "$#" -ge 2 ] || die "--yolo needs a value"; yolo=$2; shift 2 ;;
      --scout) scout=1; shift ;;
      --reason-code) [ "$#" -ge 2 ] || die "--reason-code needs a value"; reason_code=$2; shift 2 ;;
      --harness) [ "$#" -ge 2 ] || die "--harness needs a value"; harness=$2; shift 2 ;;
      --model) [ "$#" -ge 2 ] || die "--model needs a value"; model=$2; shift 2 ;;
      --effort) [ "$#" -ge 2 ] || die "--effort needs a value"; effort=$2; shift 2 ;;
      --backend) [ "$#" -ge 2 ] || die "--backend needs a value"; backend=$2; shift 2 ;;
      --tooling-gap-item) [ "$#" -ge 2 ] || die "--tooling-gap-item needs a value"; tooling_gap_item=$2; shift 2 ;;
      --attempt-budget) [ "$#" -ge 2 ] || die "--attempt-budget needs a value"; attempt_budget=$2; shift 2 ;;
      --slot-base) [ "$#" -ge 2 ] || die "--slot-base needs a value"; slot_base=$2; shift 2 ;;
      --contribution-target) [ "$#" -ge 2 ] || die "--contribution-target needs a value"; contribution_target=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  [ -n "$route" ] || die "defer needs --route"
  [ -n "$project" ] || die "defer needs --project"
  [ -n "$reason_code" ] || die "defer needs --reason-code"
  is_count "$retry_after" || retry_after=0
  if [ "$scout" -eq 0 ]; then
    valid_mode "$mode" || die "defer needs a valid --mode or --scout, not '$mode'"
    valid_yolo "$yolo" || die "defer needs --yolo on or off, not '$yolo'"
  fi

  # A deferral that cannot be made durable must not be reported as recorded: the
  # work would then be held by nothing at all and would never resume.
  [ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null \
    || { echo "error: could not create $STATE to record the capacity deferral for $id" >&2; return 1; }
  rec=$(record_path "$id")
  tmp="$rec.tmp.$$"
  now=$(date -u +%s)
  # A refresh keeps the moment the wait STARTED, because that is what makes a
  # long wait visible; only last_checked moves.
  first_deferred=$(field "$rec" deferred_at)
  is_count "$first_deferred" || first_deferred=$now
  {
    printf 'schema=%s\n' "$CAPACITY_SCHEMA"
    printf 'task=%s\n' "$id"
    printf 'deferred_at=%s\n' "$first_deferred"
    printf 'last_checked=%s\n' "$now"
    printf 'retry_after=%s\n' "$retry_after"
    printf 'route=%s\n' "$(clean "$route")"
    printf 'floor=%s\n' "$(clean "$floor")"
    printf 'pool=%s\n' "$(clean "$pool")"
    printf 'reason=%s\n' "$(clean "$reason")"
    printf 'signature=%s\n' "$(clean "$signature")"
    printf 'project=%s\n' "$(clean "$project")"
    printf 'scout=%s\n' "$scout"
    [ "$scout" -eq 1 ] || printf 'mode=%s\n' "$(clean "$mode")"
    [ "$scout" -eq 1 ] || printf 'yolo=%s\n' "$(clean "$yolo")"
    printf 'reason_code=%s\n' "$(clean "$reason_code")"
    [ -z "$harness" ] || printf 'harness=%s\n' "$(clean "$harness")"
    [ -z "$model" ] || printf 'model=%s\n' "$(clean "$model")"
    [ -z "$effort" ] || printf 'effort=%s\n' "$(clean "$effort")"
    [ -z "$backend" ] || printf 'backend=%s\n' "$(clean "$backend")"
    [ -z "$tooling_gap_item" ] || printf 'tooling_gap_item=%s\n' "$(clean "$tooling_gap_item")"
    [ -z "$attempt_budget" ] || printf 'attempt_budget=%s\n' "$(clean "$attempt_budget")"
    [ -z "$slot_base" ] || printf 'slot_base=%s\n' "$(clean "$slot_base")"
    [ -z "$contribution_target" ] || printf 'contribution_target=%s\n' "$(clean "$contribution_target")"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; echo "error: could not write the capacity deferral for $id" >&2; return 1; }
  mv -f -- "$tmp" "$rec" 2>/dev/null || { rm -f -- "$tmp"; echo "error: could not commit the capacity deferral for $id" >&2; return 1; }

  # The bound is bin/fm-attempt.sh's, not this file's. A spent bound leaves the
  # record in place and marked terminal, so the wait is inspectable rather than
  # silently gone, and so nothing ticks it again.
  rc=0
  defer_out=$(FM_HOME="$FM_HOME" "$ATTEMPT_BIN" defer "$id" --signature "$signature" 2>&1) || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf '%s\n' "$defer_out" >&2
    mark_terminal "$id" "deferral bound spent"
    return 3
  fi
  if [ "$rc" -ne 0 ]; then
    mark_terminal "$id" "attempt count could not be recorded"
    printf 'failed: waiting for capacity ended because the attempt count could not be recorded by %s defer %s against %s: %s\n' \
      "$ATTEMPT_BIN" "$id" "$STATE/$id.attempt" "$(clean "$defer_out")" \
      >> "$STATE/$id.status" 2>/dev/null || true
    printf 'error: capacity deferral for %s ended because the attempt count could not be recorded; command %s defer %s could not write %s: %s\n' \
      "$id" "$ATTEMPT_BIN" "$id" "$STATE/$id.attempt" "$defer_out" >&2
    return 1
  fi
  printf 'deferred %s route=%s retry_after=%s %s\n' "$id" "$route" "$retry_after" "$defer_out"
}

# A deferral whose bound is spent stays on disk, marked, so an operator can see
# what was waiting and why it stopped. Marking is separate from writing the
# record so the two never race to define the same field.
mark_terminal() {  # <id> <why>
  local id=$1 why=$2 rec
  rec=$(record_path "$id")
  [ -f "$rec" ] || return 0
  printf 'terminal=%s\n' "$(clean "$why")" >> "$rec" 2>/dev/null || true
}

current_capacity_signature() {  # <record-file>
  local rec=$1 route decision models observation config_file
  route=$(field "$rec" route)
  config_file=$(fm_route_config_path "$CONFIG")
  if ! decision=$(fm_route_decision "$CONFIG" "$route" "" "" "$STATE"); then
    printf 'capacity=could_not_observe@none\n'
    return 0
  fi
  models=$(printf '%s' "$decision" | jq -r '.candidates[]?.model' 2>/dev/null)
  if [ -z "$models" ]; then
    printf 'capacity=could_not_observe@none\n'
    return 0
  fi
  observation=$(fm_capacity_observe "$config_file" "$models")
  if [ "$(printf '%s' "$observation" | jq -r '.source.status // "unreadable"' 2>/dev/null)" != read ]; then
    printf 'capacity=could_not_observe@none\n'
    return 0
  fi
  printf '%s' "$observation" | jq -r '
    [ .models[]? | .model + "=" + (.verdict // "could_not_observe")
        + "@" + ((.until // "none") | tostring) ] | sort | join(" ")' 2>/dev/null \
    || printf 'capacity=could_not_observe@none\n'
}

stop_wait_for_record_failure() {  # <id> <record-file> <detail>
  local id=$1 rec=$2 detail=$3 reason out rc=0
  reason="the deferral record could not be written at $rec: $detail"
  out=$(FM_HOME="$FM_HOME" "$ATTEMPT_BIN" stop-defer "$id" --reason "$reason" 2>&1) || rc=$?
  mark_terminal "$id" "deferral record could not be written"
  if [ "$rc" -ne 0 ]; then
    printf 'error: capacity wait for %s could not be durably stopped after %s: %s\n' "$id" "$reason" "$out" >&2
    return 1
  fi
  printf 'error: capacity deferral for %s ended because the deferral record could not be written at %s; capacity had not remained exhausted: %s\n' \
    "$id" "$rec" "$detail" >&2
  return 1
}

keep_waiting() {  # <record-file> <refusal>
  local rec=$1 refusal=$2 id signature now tmp rc=0 defer_out sig line
  id=$(field "$rec" task)
  signature=$(current_capacity_signature "$rec")
  case "$refusal" in
    *FM_SPAWN_CAPACITY_DEFERRED*|*FM_SPAWN_CAPACITY_EXHAUSTED*) sig= ;;
    *) sig=$(printf '%s' "$refusal" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C cut -c1-300) ;;
  esac
  if [ -n "$sig" ]; then
    line="blocked: waiting for capacity remains active after the resumed dispatch was refused: $sig"
    grep -qxF -- "$line" "$STATE/$id.status" 2>/dev/null \
      || printf '%s\n' "$line" >> "$STATE/$id.status" 2>/dev/null || true
  fi
  defer_out=$(FM_HOME="$FM_HOME" "$ATTEMPT_BIN" defer "$id" --signature "$signature" 2>&1) || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf '%s\n' "$defer_out" >&2
    mark_terminal "$id" "deferral bound spent"
    return 3
  fi
  if [ "$rc" -ne 0 ]; then
    mark_terminal "$id" "attempt count could not be recorded"
    printf 'failed: waiting for capacity ended because the attempt count could not be recorded by %s defer %s against %s: %s\n' \
      "$ATTEMPT_BIN" "$id" "$STATE/$id.attempt" "$(clean "$defer_out")" \
      >> "$STATE/$id.status" 2>/dev/null || true
    printf 'error: capacity deferral for %s ended because the attempt count could not be recorded; command %s defer %s could not write %s: %s\n' \
      "$id" "$ATTEMPT_BIN" "$id" "$STATE/$id.attempt" "$defer_out" >&2
    return 1
  fi
  now=$(date -u +%s)
  tmp="$rec.tmp.$$"
  if ! awk -F= -v now="$now" -v signature="$(clean "$signature")" '
    $1 == "last_checked" { print "last_checked=" now; checked=1; next }
    $1 == "signature" { print "signature=" signature; signed=1; next }
    { print }
    END {
      if (!checked) print "last_checked=" now
      if (!signed) print "signature=" signature
    }
  ' "$rec" > "$tmp" 2>/dev/null || ! "$RECORD_COMMIT_BIN" -f -- "$tmp" "$rec" 2>/dev/null; then
    rm -f -- "$tmp"
    stop_wait_for_record_failure "$id" "$rec" "the atomic refresh command $RECORD_COMMIT_BIN -f -- $tmp $rec failed"
    return $?
  fi
  return 0
}

# ---------------------------------------------------------------------------
# tick - resume what is due
# ---------------------------------------------------------------------------

# When this deferral may next be checked. A reset time the PROVIDER published
# always wins, because guessing earlier only spends reads and guessing later
# wastes the capacity. With no published reset, a doubling backoff from the last
# check keeps a blind wait cheap without letting it stall.
next_check_epoch() {  # <record-file>
  local rec=$1 retry_after last deferrals backoff i
  retry_after=$(field "$rec" retry_after); is_count "$retry_after" || retry_after=0
  last=$(field "$rec" last_checked); is_count "$last" || last=$(field "$rec" deferred_at)
  is_count "$last" || last=0
  deferrals=$("$ATTEMPT_BIN" show "$(field "$rec" task)" 2>/dev/null \
    | LC_ALL=C sed -n 's/.*deferrals=\([0-9]*\).*/\1/p')
  is_count "$deferrals" || deferrals=0
  backoff=$RECHECK_BASE
  i=0
  while [ "$i" -lt "$deferrals" ] && [ "$backoff" -lt "$RECHECK_CAP" ]; do
    backoff=$((backoff * 2))
    i=$((i + 1))
  done
  [ "$backoff" -le "$RECHECK_CAP" ] || backoff=$RECHECK_CAP
  backoff=$((last + backoff))
  if [ "$retry_after" -gt "$backoff" ]; then
    printf '%s\n' "$retry_after"
  else
    printf '%s\n' "$backoff"
  fi
}

# Rebuild the dispatch argv from typed fields, refusing any value that does not
# survive its own check. A field that fails is a stop, not a substitution: a
# resume that dropped an unreadable --mode would run the work under a delivery
# posture nobody chose.
build_spawn_args() {  # <record-file> [<model-override>] -> sets SPAWN_ARGS
  local rec=$1 model_override=${2:-} id project scout mode yolo reason_code v k
  SPAWN_ARGS=()
  id=$(field "$rec" task)
  fm_task_id_path_safe "$id" || { echo "the recorded task id is not path-safe: $id" >&2; return 1; }
  project=$(field "$rec" project)
  plain_value "$project" || { echo "the recorded project path is not a plain value: $project" >&2; return 1; }
  [ -d "$project" ] || { echo "the recorded project directory no longer exists: $project" >&2; return 1; }
  SPAWN_ARGS=("$id" "$project")
  scout=$(field "$rec" scout)
  if [ "$scout" = 1 ]; then
    SPAWN_ARGS+=(--scout)
  else
    mode=$(field "$rec" mode)
    valid_mode "$mode" || { echo "the recorded delivery mode is not one this fleet ships: $mode" >&2; return 1; }
    yolo=$(field "$rec" yolo)
    valid_yolo "$yolo" || { echo "the recorded yolo posture is neither on nor off: $yolo" >&2; return 1; }
    SPAWN_ARGS+=(--mode "$mode" --yolo "$yolo")
  fi
  reason_code=$(field "$rec" reason_code)
  fm_reason_code_known "$reason_code" \
    || { echo "the recorded reason code is not in the closed vocabulary: $reason_code" >&2; return 1; }
  SPAWN_ARGS+=(--reason-code "$reason_code")
  v=$(field "$rec" route)
  [ -z "$v" ] || { plain_value "$v" || { echo "the recorded route is not a plain value: $v" >&2; return 1; }; SPAWN_ARGS+=(--route "$v"); }
  # The floor is passed back deliberately. bin/fm-spawn.sh refuses a dispatch
  # whose explicit floor disagrees with the route's configured one, so a policy
  # edit made while this work waited stops the resume instead of quietly running
  # it under a different rung of the ladder.
  v=$(field "$rec" floor)
  [ -z "$v" ] || { plain_value "$v" || { echo "the recorded capability floor is not a plain value: $v" >&2; return 1; }; SPAWN_ARGS+=(--capability-floor "$v"); }
  # The base contract travels with the dispatch. A resume that dropped it would
  # resolve a different read base or a different contribution target than the
  # call firstmate actually made, which is a different task wearing the same id.
  # --traceparent is deliberately NOT replayed: a trace id names one attempt in
  # flight, and reusing a stale one would attach this run to a trace that ended.
  for k in harness effort backend tooling-gap-item attempt-budget slot-base contribution-target; do
    v=$(field "$rec" "$(printf '%s' "$k" | tr '-' '_')")
    [ -n "$v" ] || continue
    plain_value "$v" || { echo "the recorded $k is not a plain value: $v" >&2; return 1; }
    SPAWN_ARGS+=("--$k" "$v")
  done
  if [ -n "$model_override" ]; then
    plain_value "$model_override" || { echo "the substitute model is not a plain value: $model_override" >&2; return 1; }
    SPAWN_ARGS+=(--model "$model_override")
  else
    v=$(field "$rec" model)
    [ -z "$v" ] || { plain_value "$v" || { echo "the recorded model is not a plain value: $v" >&2; return 1; }; SPAWN_ARGS+=(--model "$v"); }
  fi
  return 0
}

# One deferral has exactly three durable outcomes after a due check: RESUMED,
# ADVANCED through the attempt-owned bound, or STOPPED with a declaration.
# A not-due record retains the durable future check established by its prior
# advance, a terminal record is already stopped, and an already-dispatched task
# retires the obsolete wait rather than creating a second worker.
tick_one() {  # <record-file> <force>
  local rec=$1 force=$2 id now due out rc route effort candidate eligible
  id=$(field "$rec" task)
  if [ -z "$id" ]; then
    printf 'terminal=the deferral record has no task id\n' >> "$rec" 2>/dev/null || true
    printf 'capacity deferral stopped: %s has no task id and cannot be resumed\n' "$rec" >&2
    return 1
  fi
  if [ -n "$(field "$rec" terminal)" ]; then
    return 0
  fi
  if "$ATTEMPT_BIN" show "$id" 2>/dev/null | grep -q 'terminal=budget_exhausted'; then
    mark_terminal "$id" "attempt owner stopped the deferral"
    return 0
  fi
  # Work that is already live is not waiting for capacity. This is the one
  # reconciliation the tick owes: a deferral left behind by a dispatch that
  # later succeeded some other way must not spawn a second worker.
  if [ -f "$STATE/$id.meta" ]; then
    rm -f -- "$rec"
    printf 'capacity deferral for %s dropped: the task is already dispatched\n' "$id"
    return 0
  fi
  if [ "$force" -ne 1 ]; then
    now=$(date -u +%s)
    due=$(next_check_epoch "$rec")
    [ "$now" -ge "$due" ] || return 0
  fi
  if ! build_spawn_args "$rec"; then
    mark_terminal "$id" "the deferral record could not be turned back into a dispatch"
    printf 'failed: waiting for capacity ended because the deferral record could not be turned back into a dispatch\n' \
      >> "$STATE/$id.status" 2>/dev/null || true
    printf 'capacity deferral for %s stopped: its recorded dispatch no longer validates, so it was not resumed\n' "$id" >&2
    return 1
  fi
  # Read before the record can be removed: a field read from a deleted file is
  # an empty string, and an empty route in the resume line reads as a resume
  # nobody can trace.
  route=$(field "$rec" route)
  rc=0
  out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" "${SPAWN_ARGS[@]}" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$rec"
    # The backlog hold placed when the work was deferred describes a wait that
    # has ended. Left behind it would show a task as held while its worker is
    # actually running, which is exactly the kind of derived state that outlives
    # the fact it was derived from. Idempotent, and best effort: a hold that
    # cannot be cleared is a stale backlog line, never a second worker.
    if fm_tasks_axi_backend_available "$CONFIG"; then
      tasks-axi unhold "$id" --file "$DATA/backlog.md" >/dev/null 2>&1 \
        || printf 'warning: %s resumed but its backlog hold could not be cleared\n' "$id" >&2
    fi
    printf '%s: %s resumed automatically once capacity returned; no operator action was needed\n' \
      "$CAPACITY_RESUMED_TOKEN" "$id" >> "$STATE/$id.status" 2>/dev/null || true
    printf '%s resumed automatically: capacity returned for route %s\n' "$id" "$route"
    return 0
  fi
  case "$out" in
    *FM_SPAWN_CAPACITY_DEFERRED*)
      # Still blocked. bin/fm-spawn.sh has already refreshed this record and
      # counted the deferral through bin/fm-attempt.sh, including stopping the
      # wait when a bound is spent, so there is nothing to do but stay quiet.
      return 0
      ;;
    *FM_SPAWN_CAPACITY_EXHAUSTED*)
      effort=$(field "$rec" effort)
      eligible=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-route.sh" eligible --route "$route" --effort "$effort" 2>/dev/null) || eligible=
      while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        fm_route_model_expresses_effort "$CONFIG" "$candidate" "$effort" || continue
        build_spawn_args "$rec" "$candidate" || continue
        rc=0
        out=$(FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-spawn.sh" "${SPAWN_ARGS[@]}" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
          rm -f -- "$rec"
          if fm_tasks_axi_backend_available "$CONFIG"; then
            tasks-axi unhold "$id" --file "$DATA/backlog.md" >/dev/null 2>&1 \
              || printf 'warning: %s resumed but its backlog hold could not be cleared\n' "$id" >&2
          fi
          printf '%s: %s resumed onto %s in route %s because it can express recorded effort band %s\n' \
            "$CAPACITY_RESUMED_TOKEN" "$id" "$candidate" "$route" "$effort" \
            >> "$STATE/$id.status" 2>/dev/null || true
          printf '%s resumed automatically onto %s in route %s because it can express recorded effort band %s\n' \
            "$id" "$candidate" "$route" "$effort"
          return 0
        fi
        case "$out" in *FM_SPAWN_CAPACITY_DEFERRED*) return 0 ;; esac
      done <<EOF
$eligible
EOF
      keep_waiting "$rec" "$out"
      return $?
      ;;
  esac
  keep_waiting "$rec" "$out"
}

cmd_tick() {
  local only='' force=0 rec status=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --id) [ "$#" -ge 2 ] || die "--id needs a value"; only=$2; shift 2 ;;
      --force) force=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ "$force" -eq 0 ] || [ -n "$only" ] || die "--force applies to one named --id"
  [ -d "$STATE" ] || return 0
  for rec in "$STATE"/*.capacity; do
    [ -e "$rec" ] || continue
    if [ -n "$only" ]; then
      [ "$(field "$rec" task)" = "$only" ] || continue
    fi
    tick_one "$rec" "$force" || status=1
  done
  return "$status"
}

# ---------------------------------------------------------------------------
# list and release
# ---------------------------------------------------------------------------

cmd_list() {
  local json=0 rec id now due state
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -d "$STATE" ] || return 0
  now=$(date -u +%s)
  for rec in "$STATE"/*.capacity; do
    [ -e "$rec" ] || continue
    id=$(field "$rec" task)
    due=$(next_check_epoch "$rec")
    if [ "$json" -eq 1 ]; then
      command -v jq >/dev/null 2>&1 || die "jq is required for --json"
      # jq splits each line on its FIRST "=", so a value containing one survives
      # intact; the record's own writer already collapsed newlines and tabs, so
      # no line can carry a second field.
      jq -R -s -c --argjson due "$due" --argjson now "$now" '
        [ split("\n")[] | select(index("=") != null)
          | {key: .[:index("=")], value: .[index("=")+1:]} ]
        | from_entries
        | . + {next_check: $due, due: ($now >= $due)}' "$rec"
    else
      if [ -n "$(field "$rec" terminal)" ]; then
        state=STOPPED
      elif [ "$now" -ge "$due" ]; then
        state=due
      else
        state=waiting
      fi
      printf '%s route=%s floor=%s %s next_check=%s %s\n' \
        "$id" "$(field "$rec" route)" "$(field "$rec" floor)" \
        "$state" "$due" "$(field "$rec" reason)"
    fi
  done
}

cmd_release() {
  local id=${1-}
  [ -n "$id" ] || die "release needs a task id"
  fm_task_id_path_safe "$id" || die "invalid task id: $id"
  rm -f -- "$(record_path "$id")"
}

[ "$#" -ge 1 ] || { usage; exit 2; }
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  defer) cmd_defer "$@" ;;
  tick) cmd_tick "$@" ;;
  list) cmd_list "$@" ;;
  release) cmd_release "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (defer tick list release)" ;;
esac
