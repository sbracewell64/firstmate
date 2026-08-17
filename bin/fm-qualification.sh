#!/usr/bin/env bash
# fm-qualification.sh - read the ROLE QUALIFICATION register, and run the bounded
# workflow that resolves a missing one.
#
# A route can require a capability - "was this binding ever observed to DO this
# job?" - that nothing in this fleet could answer. When it could not, the only
# available outcome was to ask the captain for a task-specific floor exception,
# again, for the same missing evidence. The 2026-08-13 captain ruling separates
# the two facts that had been one: missing qualification is an ENGINEERING STATE
# to resolve, not a captain decision, and a candidate that may satisfy a blocked
# route is qualified empirically through a bounded representative workflow whose
# evidence is then reused.
#
# This command is that path. bin/fm-qualification-lib.sh owns the decision;
# qualifications/schema.json owns the field contract, the state computation and
# every closed vocabulary; this file is their interface and the activation owner.
#
# Usage:
#   fm-qualification.sh contracts [--json]
#       Every capability contract: role, risk class, version, axis, predicate.
#   fm-qualification.sh records [--json]
#       Every record and the state COMPUTED for it right now.
#   fm-qualification.sh state --contract <id> --model <name>
#                            [--harness <name>] [--effort <band>] [--json]
#       The state for one tuple. Exit status is the answer (below).
#   fm-qualification.sh validate [<file>...]
#       Contract and record admissibility. Exit 1 when anything is inadmissible.
#   fm-qualification.sh reviewer --maker <model> --reviewer <model>
#                               --contract <id> [--contract <id>...]
#       May this reviewer take this assignment? Refuses self-review first, then
#       an unqualified reviewer, then a failed independence dimension.
#   fm-qualification.sh activate --route <id> [--blocks <work-id>]
#                               [--budget <n>] [--subject-model <name>]
#                               [--harness <name>] [--effort <band>] [--json]
#       Create or reuse ONE bounded qualification workflow for the cheapest
#       promising candidate on a zero route. Refuses any classification other
#       than QUALIFICATION_REQUIRED.
#   fm-qualification.sh activations [--json]
#       Every activation record and whether it is still active.
#   fm-qualification.sh dispatch <activation-id> [--dry-run]
#       Launch the recorded workflow through bin/fm-spawn.sh, the one chokepoint.
#   fm-qualification.sh resolve <activation-id> --result <RESULT>
#       Close a workflow on its observed result: QUALIFIED unblocks the same
#       blocked work identity, FAILED preserves the exclusion and advances,
#       COULD_NOT_OBSERVE spends one attempt and stays active.
#       A QUALIFIED result is VERIFIED against the register before it is
#       accepted: it is not a word this command may take on trust.
#   fm-qualification.sh --help
#
# Exit status is the answer, so a caller that ignores stdout still stops safely:
#   0  QUALIFIED, or the operation succeeded
#   1  FAILED, refused, or inadmissible
#   2  usage error, or the register could not be read at all
#   3  QUALIFICATION_REQUIRED or QUALIFICATION_STALE - an engineering state, and
#      never an escalation
#   4  COULD_NOT_OBSERVE - the observation did not happen. Never a pass, and never
#      a finding against the binding
#
# NO SECOND SCHEDULER, ROUTER, ISSUE STORE, EVENT SYSTEM OR POLLING LOOP EXISTS
# HERE, and that is a constraint rather than an accident. Activation records
# durable state and blocks the named work identity through the existing backlog
# owner; the worker is launched through bin/fm-spawn.sh so route, admission,
# capacity, cost, entitlement and concurrency are all re-evaluated at the one
# chokepoint; the bound is bin/fm-attempt.sh over the activation's OWN identity;
# duplicate work is refused by composing bin/fm-decision-surface.sh.
#
# Environment:
#   FM_HOME                          the home whose config/, state/ and data/ are read
#   FM_QUALIFICATION_BUDGET          default attempt budget for a workflow (2)
#   FM_QUALIFICATION_TODAY           override today's date (tests)
#   FM_QUALIFICATION_CONTRACT_DIR    read contracts from this directory instead
#   FM_QUALIFICATION_RECORD_DIR      read tracked records from this directory
#   FM_QUALIFICATION_OVERLAY_DIR     read the private record overlay from here
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export STATE CONFIG

# shellcheck source=bin/fm-model-registry-lib.sh
. "$SCRIPT_DIR/fm-model-registry-lib.sh"
# shellcheck source=bin/fm-route-lib.sh
. "$SCRIPT_DIR/fm-route-lib.sh"
# shellcheck source=bin/fm-qualification-lib.sh
. "$SCRIPT_DIR/fm-qualification-lib.sh"

EXIT_OK=0
EXIT_REFUSED=1
EXIT_USAGE=2
EXIT_REQUIRED=3
EXIT_UNOBSERVED=4

ACTIVATION_DIR="$STATE/qualification"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-qualification.sh"
}

die() { printf 'fm-qualification: %s\n' "$1" >&2; exit "$EXIT_USAGE"; }

JSON=0
CMD=
ROUTE=
MODEL=
SUBJECT_MODEL=
HARNESS=
EFFORT=
MAKER=
REVIEWER=
BLOCKS=
BUDGET=${FM_QUALIFICATION_BUDGET:-2}
RESULT=
DRY_RUN=0
CONTRACTS=()
POS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --route) shift; [ $# -gt 0 ] || die "--route needs a value"; ROUTE=$1 ;;
    --route=*) ROUTE=${1#--route=} ;;
    --model) shift; [ $# -gt 0 ] || die "--model needs a value"; MODEL=$1 ;;
    --model=*) MODEL=${1#--model=} ;;
    --subject-model) shift; [ $# -gt 0 ] || die "--subject-model needs a value"; SUBJECT_MODEL=$1 ;;
    --subject-model=*) SUBJECT_MODEL=${1#--subject-model=} ;;
    --harness) shift; [ $# -gt 0 ] || die "--harness needs a value"; HARNESS=$1 ;;
    --harness=*) HARNESS=${1#--harness=} ;;
    --effort) shift; [ $# -gt 0 ] || die "--effort needs a value"; EFFORT=$1 ;;
    --effort=*) EFFORT=${1#--effort=} ;;
    --contract) shift; [ $# -gt 0 ] || die "--contract needs a value"; CONTRACTS+=("$1") ;;
    --contract=*) CONTRACTS+=("${1#--contract=}") ;;
    --maker) shift; [ $# -gt 0 ] || die "--maker needs a value"; MAKER=$1 ;;
    --maker=*) MAKER=${1#--maker=} ;;
    --reviewer) shift; [ $# -gt 0 ] || die "--reviewer needs a value"; REVIEWER=$1 ;;
    --reviewer=*) REVIEWER=${1#--reviewer=} ;;
    --blocks) shift; [ $# -gt 0 ] || die "--blocks needs a value"; BLOCKS=$1 ;;
    --blocks=*) BLOCKS=${1#--blocks=} ;;
    --budget) shift; [ $# -gt 0 ] || die "--budget needs a value"; BUDGET=$1 ;;
    --budget=*) BUDGET=${1#--budget=} ;;
    --result) shift; [ $# -gt 0 ] || die "--result needs a value"; RESULT=$1 ;;
    --result=*) RESULT=${1#--result=} ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    -*) die "unknown option $1" ;;
    *) if [ -z "$CMD" ]; then CMD=$1; else POS+=("$1"); fi ;;
  esac
  shift
done

[ -n "$CMD" ] || { usage; exit "$EXIT_USAGE"; }
command -v jq >/dev/null 2>&1 || die "jq is required to read the qualification register"

# A path-safety rule for every id this command turns into a filename. The one
# owner of that predicate in this fleet already exists, so it is composed rather
# than restated: an id an overlay record could supply must never build a path.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

# The routed model and provider names this home configures, for the contract
# validator's vendor-neutrality layer. An absent routing config simply supplies
# no names, which leaves the refused-key layer doing the work.
routed_names_file() {
  local tmp models m
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-qual-names.XXXXXX") || return 1
  if [ -f "$CONFIG/crew-dispatch.json" ]; then
    models=$(jq -r '
      def route_entries:
        [ (.rules // []) | to_entries[]? | .value ] + [ (.default // empty) ]
        | map(select(type == "object"));
      [ route_entries[] | .pool? | select(type == "array") | .[] | select(type == "string") ]
      + [ (._models // {}) | keys[] ]
      | unique | .[] | select(startswith("_") | not)' "$CONFIG/crew-dispatch.json" 2>/dev/null) || models=
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      printf '%s\n' "$m" >> "$tmp"
      case "$m" in */*) printf '%s\n' "${m%%/*}" >> "$tmp" ;; esac
    done <<EOF
$models
EOF
  fi
  printf '%s\n' "$tmp"
}

cmd_contracts() {
  local dir f
  dir=$(fm_qualification_contract_dir)
  [ -d "$dir" ] || { printf 'fm-qualification: no contract register at %s\n' "$dir" >&2; return "$EXIT_UNOBSERVED"; }
  if [ "$JSON" -eq 1 ]; then
    jq -s -c '.' "$dir"/*.json 2>/dev/null || return "$EXIT_UNOBSERVED"
    return "$EXIT_OK"
  fi
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    jq -r '"\(.id)  role=\(.role)  risk=\(.risk_class)  version=\(.contract_version)  axis=\(.axis)  predicate=\(.executable_predicate.kind)  adjudication=\(if .adjudication.required then "required by " + .adjudication.adjudicator_contract else "not required" end)"' "$f"
  done
  return "$EXIT_OK"
}

cmd_records() {
  local files f rc=0 id contract model harness effort state
  files=$(fm_qualification_record_files) || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'fm-qualification: %s: a record directory exists and could not be listed\n' \
      "$FM_QUAL_TOKEN_UNREADABLE" >&2
    return "$EXIT_UNOBSERVED"
  fi
  if [ "$rc" -eq 1 ]; then
    printf 'fm-qualification: the register holds no records\n'
    return "$EXIT_OK"
  fi
  local out='[]'
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # U+001F, not a tab: bash collapses runs of IFS WHITESPACE, so an empty
    # middle field would shift every later field left.
    IFS=$'\x1f' read -r id contract model harness effort <<EOF2
$(jq -r '[ (.id // ""), (.contract // ""), (.binding.model // ""), (.binding.harness // ""), (.binding.native_effort // "") ] | join("\u001f")' "$f" 2>/dev/null)
EOF2
    state=$(fm_qualification_state "$contract" "$model" "$harness" "$effort")
    if [ "$JSON" -eq 1 ]; then
      out=$(printf '%s' "$out" | jq -c --slurpfile r "$f" --argjson s "$state" \
        '. + [{record: $r[0], state: $s}]')
    else
      printf '%s  contract=%s  binding=%s  harness=%s  effort=%s  recorded=%s  state=%s\n' \
        "$id" "$contract" "$model" "$harness" "$effort" \
        "$(printf '%s' "$state" | jq -r '.recorded_result // "-"')" \
        "$(printf '%s' "$state" | jq -r '.state')"
    fi
  done <<EOF
$files
EOF
  [ "$JSON" -eq 0 ] || printf '%s\n' "$out"
  return "$EXIT_OK"
}

state_exit_code() {  # <state>
  case "$1" in
    QUALIFIED) printf '%s\n' "$EXIT_OK" ;;
    FAILED) printf '%s\n' "$EXIT_REFUSED" ;;
    QUALIFICATION_REQUIRED|QUALIFICATION_STALE) printf '%s\n' "$EXIT_REQUIRED" ;;
    *) printf '%s\n' "$EXIT_UNOBSERVED" ;;
  esac
}

cmd_state() {
  local record state
  [ -n "${CONTRACTS[0]:-}" ] || die "state needs --contract"
  [ -n "$MODEL" ] || die "state needs --model"
  record=$(fm_qualification_state "${CONTRACTS[0]}" "$MODEL" "$HARNESS" "$EFFORT")
  state=$(printf '%s' "$record" | jq -r '.state')
  if [ "$JSON" -eq 1 ]; then
    printf '%s\n' "$record"
  else
    printf '%s\n' "$record" | jq -r '
      "contract \(.contract) · binding \(.model)\(if .harness then " · harness " + .harness else "" end)\(if .native_effort then " · effort " + .native_effort else "" end)",
      "  state:    \(.state)",
      "  record:   \(.record // "none")",
      "  recorded: \(.recorded_result // "-")",
      "  reason:   \(.reason)",
      (if (.dependencies | length) > 0
       then "  dependencies:", (.dependencies[] | "    \(.kind): \(.observation) - \(.detail)")
       else empty end),
      (if (.near_miss | length) > 0
       then "  near misses (a different tuple, not a stale version of this one):",
            (.near_miss[] | "    \(.record) harness=\(.harness) effort=\(.native_effort) \(.result)")
       else empty end)'
  fi
  return "$(state_exit_code "$state")"
}

cmd_validate() {
  local names f rc=0 problems dir line
  names=$(routed_names_file) || names=
  local -a files=()
  if [ "${#POS[@]}" -gt 0 ]; then
    files=("${POS[@]}")
  else
    dir=$(fm_qualification_contract_dir)
    for f in "$dir"/*.json; do [ -f "$f" ] && files+=("$f"); done
    while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$(fm_qualification_record_files || true)
EOF
  fi
  [ "${#files[@]}" -gt 0 ] || { printf 'fm-qualification: nothing to validate\n' >&2; return "$EXIT_UNOBSERVED"; }
  for f in "${files[@]}"; do
    [ -f "$f" ] || { printf 'inadmissible %s: not a file\n' "$f"; rc=1; continue; }
    if jq -e 'has("executable_predicate") or has("axis")' "$f" >/dev/null 2>&1; then
      problems=$(fm_qualification_contract_problems "$f" "$names") || problems='the validator could not run'
    else
      problems=$(fm_qualification_record_problems "$f") || problems='the validator could not run'
    fi
    if [ -n "$problems" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf 'inadmissible %s: %s\n' "$(basename "$f")" "$line"
      done <<EOF
$problems
EOF
      rc=1
    fi
  done
  [ -z "$names" ] || rm -f -- "$names"
  [ "$rc" -eq 0 ] || return "$EXIT_REFUSED"
  printf 'ok: %s contract and record files are admissible\n' "${#files[@]}"
  return "$EXIT_OK"
}

cmd_reviewer() {
  local refusal
  [ -n "$MAKER" ] || die "reviewer needs --maker"
  [ -n "$REVIEWER" ] || die "reviewer needs --reviewer"
  [ "${#CONTRACTS[@]}" -gt 0 ] || die "reviewer needs at least one --contract"
  if ! refusal=$(fm_qualification_reviewer_refusal "$MAKER" "$REVIEWER" "${CONTRACTS[@]}"); then
    printf 'refused: %s\n' "$refusal" >&2
    case "$refusal" in
      *COULD_NOT_OBSERVE*) return "$EXIT_UNOBSERVED" ;;
      *QUALIFICATION_REQUIRED*|*QUALIFICATION_STALE*) return "$EXIT_REQUIRED" ;;
      *) return "$EXIT_REFUSED" ;;
    esac
  fi
  printf 'ok: %s may review %s work for %s · %s\n' \
    "$REVIEWER" "$MAKER" "$(printf '%s' "${CONTRACTS[*]}" | tr ' ' ',')" \
    "$(fm_qualification_independence "$MAKER" "$REVIEWER")"
  return "$EXIT_OK"
}

# ---------------------------------------------------------------------------
# The bounded workflow
# ---------------------------------------------------------------------------

activation_id() {  # <contract> <model> <harness> <effort>
  local digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | sha256sum | awk '{print substr($1,1,40)}')
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s\0%s\0%s\0%s' "$1" "$2" "$3" "$4" | shasum -a 256 | awk '{print substr($1,1,40)}')
  else
    return 1
  fi
  printf 'qualify-%s\n' "$digest"
}

activation_next_id() {  # <tuple-id>
  local tuple=$1 n=2 id
  [ -f "$(activation_file "$tuple")" ] || { printf '%s\n' "$tuple"; return 0; }
  while :; do
    id="$tuple-$n"
    [ -f "$(activation_file "$id")" ] || { printf '%s\n' "$id"; return 0; }
    n=$((n + 1))
  done
}

activation_file() {  # <activation-id>
  printf '%s/%s.activation\n' "$ACTIVATION_DIR" "$1"
}

# THE WORKFLOW IS A BACKLOG TASK, AND THAT IS THE WHOLE DESIGN.
#
# There is exactly ONE durable fact about whether a qualification workflow is
# still live: its own backlog record. The blocked work's dependency on it is not a
# second copy of that fact - bin/fm-fleet-snapshot.sh recomputes
# `unresolved_blocker_ids` on every read, and resolves a blocker if and only if
# its structured record is Done. So the relationship is DERIVED on read by an
# owner that already exists, exactly as qualification state is computed on read
# and expired availability holds are dropped on read rather than swept.
#
# WHY THERE IS NO TRANSFER, COMPENSATION, OR RECONCILIATION LOGIC HERE, and a
# reader who goes looking for it should find this paragraph instead of an absence.
# An earlier design kept the workflow's liveness in a `terminal=` field of its own
# record AND mirrored it into a backlog edge, and every one of five review rounds
# was a different way for those two facts to disagree: a predecessor blocker left
# behind on advancement, a half-written block reported as active, an unblock that
# could not be retried after a terminal write failed. Intermediate states,
# compensation and retry reconciliation are machinery that exists BECAUSE
# something is mirrored. Nothing is mirrored now, so those three findings are
# closed by construction rather than patched, and there is nothing left for a
# reconciliation path to reconcile.
#
# It also fixes a defect none of those rounds could see: `tasks-axi block` refuses
# a blocker that is not itself a task ("Create the blocker task first, or choose an
# existing task id"), and bin/fm-fleet-snapshot.sh leaves a blocker with no record
# open forever. The old edge was therefore never written, and could never have
# resolved if it had been. Registering the workflow as a task is what makes
# `block --by` meet its documented precondition instead of working around it.
qualification_backlog_available() {
  command -v tasks-axi >/dev/null 2>&1
}

# Register the workflow as a work item and make the blocked work depend on it.
# Ordered so nothing is promised before it is confirmed: the task exists before
# anything depends on it, and a failure at either step leaves the work UNBLOCKED
# and re-runnable rather than blocked on something that can never resolve.
qualification_backlog_open() {  # <activation-id> <contract> <model> <work-id>
  local id=$1 contract=$2 model=$3 work=$4
  qualification_backlog_available || return "$EXIT_UNOBSERVED"
  tasks-axi add "$id" "qualify $contract for $model" >/dev/null 2>&1 \
    || tasks-axi show "$id" >/dev/null 2>&1 \
    || return "$EXIT_UNOBSERVED"
  [ -n "$work" ] || return 0
  tasks-axi block "$work" --by "$id" >/dev/null 2>&1 || return "$EXIT_UNOBSERVED"
}

# Close the workflow. This is the ONLY act that releases the blocked work, and it
# releases it by making the blocker resolve rather than by editing the edge, so
# there is no second mutation to fail, retry, or compensate for. It is idempotent
# because `done` on a finished task is.
qualification_backlog_close() {  # <activation-id>
  qualification_backlog_available || return "$EXIT_UNOBSERVED"
  tasks-axi "done" "$1" >/dev/null 2>&1 || return "$EXIT_UNOBSERVED"
}

qualification_backlog_park() {  # <activation-id>
  qualification_backlog_available || return "$EXIT_UNOBSERVED"
  tasks-axi hold "$1" \
    --reason "Qualification attempt budget is spent and Firstmate must decide whether to raise the bound or abandon this qualification" \
    --kind parked >/dev/null 2>&1 || return "$EXIT_UNOBSERVED"
}

# Is this workflow still live, according to the one fact that owns it?
# 0 = live, 1 = finished or absent, EXIT_UNOBSERVED = the owner could not answer.
qualification_backlog_live() {  # <activation-id>
  local state out rc=0
  qualification_backlog_available || return "$EXIT_UNOBSERVED"
  out=$(tasks-axi show "$1" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$out" in *NOT_FOUND*) return 1 ;; *) return "$EXIT_UNOBSERVED" ;; esac
  fi
  state=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*state:[[:space:]]*//p' | head -1)
  case "$state" in
    queued|in_flight) return 0 ;;
    done) return 1 ;;
    *) return "$EXIT_UNOBSERVED" ;;
  esac
}

qualification_dependents() {  # <activation-id>
  local id=$1 snapshot rows
  if [ -n "${FM_DECISION_SURFACE_SNAPSHOT:-}" ]; then
    [ -f "$FM_DECISION_SURFACE_SNAPSHOT" ] || return "$EXIT_UNOBSERVED"
    snapshot=$(cat "$FM_DECISION_SURFACE_SNAPSHOT" 2>/dev/null) || return "$EXIT_UNOBSERVED"
  else
    snapshot=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json 2>/dev/null) \
      || return "$EXIT_UNOBSERVED"
  fi
  rows=$(printf '%s\n' "$snapshot" | jq -ec --arg id "$id" '
    if (.backlog.records | type) != "array" then error("backlog records unavailable")
    else [.backlog.records[]?
          | select((.blocked_by_ids // []) | index($id))
          | .id]
    end
  ' 2>/dev/null) || return "$EXIT_UNOBSERVED"
  printf '%s\n' "$rows" | jq -r '.[]' 2>/dev/null || return "$EXIT_UNOBSERVED"
}

activation_field() {  # <file> <key>
  [ -f "$1" ] || return 1
  awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$1"
}

# Is another workflow for this pair already live? Three independent sources, and
# ANY of them means already-active, and BOTH are derived rather than stored. The
# first asks the backlog owner, which holds the workflow's only liveness fact; the
# second composes the fleet's duplicate-dispatch owner rather than re-deriving "is
# this already running", which is exactly the reconstruction the decision surface
# exists to replace. The activation file is deliberately NOT consulted: it carries
# the workflow's inert parameters and no state, so a stale one on disk can never
# make a finished workflow look live.
activation_already_active() {  # <tuple-id>
  local tuple=$1 id file out rc candidate
  for file in "$(activation_file "$tuple")" "$ACTIVATION_DIR/$tuple"-*.activation; do
    [ -f "$file" ] || continue
    id=$(activation_field "$file" activation || true)
    [ -n "$id" ] || continue
    rc=0
    qualification_backlog_live "$id" || rc=$?
    case "$rc" in
      0) printf '%s\037the backlog owner still holds an open work item for this tuple: %s\n' "$id" "$id"; return 0 ;;
      "$EXIT_UNOBSERVED")
        printf '%s\037whether a workflow for this tuple is already open COULD NOT BE OBSERVED because the backlog owner did not answer\n' "$id"
        return 0 ;;
    esac
  done
  candidate=$(activation_next_id "$tuple")
  if [ -x "$SCRIPT_DIR/fm-decision-surface.sh" ] && fm_task_id_path_safe "$candidate" 2>/dev/null; then
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-decision-surface.sh" check duplicate-dispatch "$candidate" 2>/dev/null)
    case "$out" in
      *"verdict: contradicted"*)
        printf '%s\037the fleet already holds work under this identity: %s\n' "$candidate" "$out"
        return 0 ;;
    esac
  fi
  return 1
}

qualification_route_entries() {
  local owner=${FM_ROUTE_OWNER_COMMAND:-$SCRIPT_DIR/fm-route.sh}
  FM_HOME="$FM_HOME" "$owner" routes --json
}

qualification_bootstrap() {  # <target-route> <target-floor> <model> <harness> <effort> <route-entries>
  local target_route=$1 target_floor=$2 model=$3 harness=$4 effort=$5 entries=$6 row route bootstrap_floor checked rc state
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    route=$(printf '%s' "$row" | jq -r '.id')
    [ -n "$route" ] || continue
    bootstrap_floor=$(printf '%s' "$row" | jq -r '.rule.floor // empty')
    fm_route_floor_meets "$CONFIG/crew-dispatch.json" "$bootstrap_floor" "$target_floor" || continue
    rc=0
    checked=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-route.sh" check --route "$route" \
      --model "$model" --harness "$harness" --effort "$effort" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      state=$(printf '%s' "$checked" | jq -r '.subject.qualification.state // empty' 2>/dev/null)
      [ "$rc" -eq 1 ] && [ "$state" != COULD_NOT_OBSERVE ] && continue
      return 2
    fi
    [ "$(printf '%s' "$checked" | jq -r '.subject.resolved // empty')" = "$model" ] || continue
    printf '%s\037%s\037%s\037%s\n' "$route" "$model" "$harness" "$effort"
    return 0
  done <<EOF
$(printf '%s' "$entries" | jq -c --arg target_route "$target_route" --arg model "$model" '
  .[] | select(.id != $target_route) | select((.rule.pool // []) | index($model))')
EOF
  return 1
}

cmd_activate() {
  local zero rc=0 class model contracts cost id tuple_id file out harness effort bootstrap route_entries route_entry
  local execution_route execution_model execution_harness execution_effort
  [ -n "$ROUTE" ] || die "activate needs --route"
  local -a zero_args=(zero-route --route "$ROUTE" --json)
  [ -z "$HARNESS" ] || zero_args+=(--harness "$HARNESS")
  [ -z "$EFFORT" ] || zero_args+=(--effort "$EFFORT")
  zero=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-route.sh" "${zero_args[@]}" 2>/dev/null) || rc=$?
  if [ -z "$zero" ]; then
    printf 'fm-qualification: the zero-route classification for %s could not be read, so no workflow may be activated on it\n' "$ROUTE" >&2
    return "$EXIT_UNOBSERVED"
  fi
  class=$(printf '%s' "$zero" | jq -r '.classification')
  case "$class" in
    QUALIFICATION_REQUIRED) ;;
    ELIGIBLE)
      printf 'fm-qualification: route %s already has an eligible candidate (%s); a bounded workflow would qualify a binding nothing is waiting on\n' \
        "$ROUTE" "$(printf '%s' "$zero" | jq -r '.eligible | join(", ")')" >&2
      return "$EXIT_OK" ;;
    QUALIFICATION_COULD_NOT_OBSERVE)
      printf 'fm-qualification: route %s is blocked because a qualification could not be OBSERVED, not because one is missing; the repair is to the observation and spending a workflow here would record nothing. %s\n' \
        "$ROUTE" "$(printf '%s' "$zero" | jq -r '[.unobserved[] | .model + ": " + .evidence] | join("; ")')" >&2
      return "$EXIT_UNOBSERVED" ;;
    AWAITING_AVAILABILITY)
      printf 'fm-qualification: route %s is waiting on availability or capacity, which the existing availability and deferral owners handle; qualification is not what is blocking it\n' "$ROUTE" >&2
      return "$EXIT_REQUIRED" ;;
    *)
      printf 'fm-qualification: %s: route %s is classified %s, so no candidate can be made eligible by qualifying it\n' \
        "$FM_QUAL_TOKEN_NO_PROMISING" "$ROUTE" "$class" >&2
      return "$EXIT_REFUSED" ;;
  esac

  # Cheapest first, and an unobservable cost sorts LAST. The route owner already
  # applied that ordering; reading its first row rather than re-sorting here is
  # what keeps one ordering authority.
  model=$(printf '%s' "$zero" | jq -r '.promising[0].model // empty')
  contracts=$(printf '%s' "$zero" | jq -r '(.promising[0].contracts // []) | join(",")')
  cost=$(printf '%s' "$zero" | jq -r '.promising[0].cost_rank // "unobserved"')
  route_entries=$(qualification_route_entries 2>/dev/null) || {
    printf 'fm-qualification: the route owner could not project the configured routes, so no workflow may start\n' >&2
    return "$EXIT_UNOBSERVED"
  }
  route_entry=$(printf '%s' "$route_entries" | jq -c --arg route "$ROUTE" '[.[] | select(.id == $route)] | first // empty')
  [ -n "$route_entry" ] || {
    printf 'fm-qualification: the route owner projection omitted target route %s, so no tuple-bound workflow may start\n' "$ROUTE" >&2
    return "$EXIT_UNOBSERVED"
  }
  IFS=$'\x1f' read -r harness effort <<EOF
$(printf '%s' "$route_entry" | jq -r --arg model "$model" '
  .rule as $r
  | (if ($r.use | type) == "array"
     then ([$r.use[] | select((.model // "") == $model)] | first // {})
     else ($r.use // {}) end) as $p
  | [$p.harness // "", $p.effort // ""] | join("\u001f")' 2>/dev/null)
EOF
  if [ -n "$SUBJECT_MODEL" ] && [ "$SUBJECT_MODEL" = "$model" ]; then
    [ -z "$HARNESS" ] || harness=$HARNESS
    [ -z "$EFFORT" ] || effort=$EFFORT
  fi
  if [ -z "$model" ]; then
    printf 'fm-qualification: %s: route %s classified %s but named no promising candidate\n' \
      "$FM_QUAL_TOKEN_NO_PROMISING" "$ROUTE" "$class" >&2
    return "$EXIT_UNOBSERVED"
  fi
  # ONE contract per workflow. A candidate short of two contracts needs two
  # bounded runs, because a single run that claimed both would be one observation
  # standing in for two, which is the aggregation the adjudicator contract
  # explicitly refuses.
  local contract=${contracts%%,*}
  [ -n "$harness" ] && [ -n "$effort" ] || {
    printf 'fm-qualification: the harness and native effort for %s could not be observed, so no tuple-bound workflow may start\n' "$model" >&2
    return "$EXIT_UNOBSERVED"
  }
  tuple_id=$(activation_id "$contract" "$model" "$harness" "$effort") || {
    printf 'fm-qualification: sha256 is required to derive an unambiguous tuple identity\n' >&2
    return "$EXIT_UNOBSERVED"
  }
  fm_task_id_path_safe "$tuple_id" || die "derived activation id is not path-safe: $tuple_id"

  local target_floor
  target_floor=$(printf '%s' "$zero" | jq -r '.floor // empty')
  local bootstrap_rc=0
  bootstrap=$(qualification_bootstrap "$ROUTE" "$target_floor" "$model" "$harness" "$effort" "$route_entries") || bootstrap_rc=$?
  if [ "$bootstrap_rc" -eq 2 ]; then
    printf 'fm-qualification: bootstrap eligibility for %s could not be observed, so missing qualification is not inferred\n' "$model" >&2
    return "$EXIT_UNOBSERVED"
  elif [ "$bootstrap_rc" -ne 0 ]; then
    printf 'fm-qualification: no route where %s is already eligible also meets target floor %s, so qualification stops without an exemption\n' "$model" "$target_floor" >&2
    return "$EXIT_REQUIRED"
  fi
  IFS=$'\x1f' read -r execution_route execution_model execution_harness execution_effort <<EOF
$bootstrap
EOF

  if out=$(activation_already_active "$tuple_id"); then
    local active_id active_reason
    IFS=$'\x1f' read -r active_id active_reason <<EOF2
$out
EOF2
    if [ -n "$BLOCKS" ] && [[ "$active_reason" == "the backlog owner still holds"* ]] &&
       qualification_backlog_open "$active_id" "$contract" "$model" "$BLOCKS"; then
      :
    elif [ -n "$BLOCKS" ] && [[ "$active_reason" == "the backlog owner still holds"* ]]; then
      printf 'fm-qualification: the live workflow exists but its blocker edge could not be confirmed\n' >&2
      return "$EXIT_UNOBSERVED"
    fi
    printf '%s: %s\n' "$FM_QUAL_TOKEN_DUPLICATE" "$active_reason"
    [ "$JSON" -eq 0 ] || printf '{"schema":"fm-qualification-activation.v1","activation":"%s","created":false,"already_active":true}\n' "$active_id"
    return "$EXIT_OK"
  fi

  id=$(activation_next_id "$tuple_id")
  fm_task_id_path_safe "$id" || die "derived activation incarnation is not path-safe: $id"
  file=$(activation_file "$id")

  case "$BUDGET" in ''|*[!0-9]*) die "--budget must be a whole number" ;; esac
  [ "$BUDGET" -gt 0 ] || die "--budget must be at least 1"

  mkdir -p "$ACTIVATION_DIR" 2>/dev/null || {
    printf 'fm-qualification: could not create %s, so this workflow could not be recorded and must not be started\n' "$ACTIVATION_DIR" >&2
    return "$EXIT_UNOBSERVED"
  }

  # The bound is the ACTIVATION's own attempt record, owned by bin/fm-attempt.sh
  # and deliberately NOT mirrored here. The blocked work identity's count, budget
  # and custody bases are never read, spent or reset by a qualification workflow:
  # a task that was waiting for a capability did not fail, and a workflow that
  # fails twice must not consume the retries the real work is owed.
  #
  # Copying the attempt owner's own output into this record would make a second
  # place to read a count that changes underneath it - and its `show` line
  # literally contains `terminal=`, so a reader grepping this file for a terminal
  # marker would find one inside another field's value.
  local tmp brief_dir brief brief_tmp predicate fixture verify
  brief_dir="$DATA/$id"
  brief="$brief_dir/brief.md"
  mkdir -p "$brief_dir" 2>/dev/null || {
    printf 'fm-qualification: could not create the brief directory for %s\n' "$id" >&2
    return "$EXIT_UNOBSERVED"
  }
  predicate=$(fm_qualification_contract "$contract") || {
    printf 'fm-qualification: could not read contract %s while materializing the workflow brief\n' "$contract" >&2
    return "$EXIT_UNOBSERVED"
  }
  fixture=$(printf '%s' "$predicate" | jq -r '.executable_predicate.fixture // empty')
  verify=$(printf '%s' "$predicate" | jq -r '.executable_predicate.verify // .executable_predicate.check // empty')
  brief_tmp=$(mktemp "$brief.XXXXXX") || {
    printf 'fm-qualification: could not write beside %s\n' "$brief" >&2
    return "$EXIT_UNOBSERVED"
  }
  # The backticks below are Markdown in the brief being written, not command
  # substitution, and the single quotes are what keep them literal.
  # shellcheck disable=SC2016
  {
    printf '# Role qualification workflow\n\n'
    printf 'Establish contract `%s` for binding `%s`, harness `%s`, and native effort `%s`.\n\n' "$contract" "$model" "$harness" "$effort"
    printf 'Run the contract predicate unchanged and preserve its complete evidence package.\n\n'
    [ -z "$fixture" ] || printf 'Use fixture `%s`.\n\n' "$fixture"
    [ -z "$verify" ] || printf 'Use verifier `%s`.\n\n' "$verify"
    printf 'Do not tune the fixture, acceptance criteria, or adjudication to obtain a pass.\n\n'
    printf '# Definition of done\n\n'
    printf 'An admissible tuple-bound qualification record and assignment-distinct adjudication are written, or the exact failed or could-not-observe evidence is preserved.\n'
  } > "$brief_tmp" || { rm -f -- "$brief_tmp"; return "$EXIT_UNOBSERVED"; }
  chmod 600 "$brief_tmp" 2>/dev/null || true
  mv -f -- "$brief_tmp" "$brief" || { rm -f -- "$brief_tmp"; return "$EXIT_UNOBSERVED"; }

  tmp=$(mktemp "$file.XXXXXX") || {
    printf 'fm-qualification: could not write beside %s\n' "$file" >&2
    return "$EXIT_UNOBSERVED"
  }
  {
    printf 'schema=fm-qualification-activation.v1\n'
    printf 'activation=%s\n' "$id"
    printf 'tuple=%s\n' "$tuple_id"
    printf 'contract=%s\n' "$contract"
    printf 'model=%s\n' "$model"
    printf 'harness=%s\n' "$harness"
    printf 'native_effort=%s\n' "$effort"
    printf 'execution_route=%s\n' "$execution_route"
    printf 'execution_model=%s\n' "$execution_model"
    printf 'execution_harness=%s\n' "$execution_harness"
    printf 'execution_effort=%s\n' "$execution_effort"
    printf 'route=%s\n' "$ROUTE"
    printf 'floor=%s\n' "$(printf '%s' "$zero" | jq -r '.floor // ""')"
    printf 'cost_rank=%s\n' "$cost"
    printf 'blocks=%s\n' "$BLOCKS"
    printf 'attempt_budget=%s\n' "$BUDGET"
    printf 'created=%s\n' "$(date -u +%s)"
    printf 'created_date=%s\n' "$(fm_qualification_today)"
  } > "$tmp" || { rm -f -- "$tmp"; printf 'fm-qualification: could not record the workflow\n' >&2; return "$EXIT_UNOBSERVED"; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$file" || { rm -f -- "$tmp"; printf 'fm-qualification: could not record the workflow\n' >&2; return "$EXIT_UNOBSERVED"; }

  # The blocked work identity keeps its identity, its custody and its budget. All
  # that changes is that the workflow becomes a work item of its own and the work
  # depends on it, both through the existing backlog owner - so the
  # dependency-driven re-evaluation already in the fleet returns it to normal
  # eligibility when that item is Done. No second scheduler watches it, and there
  # is no second record of its liveness to keep in step.
  if ! qualification_backlog_open "$id" "$contract" "$model" "$BLOCKS"; then
    printf 'fm-qualification: the backlog owner did not confirm the workflow item for %s%s, so activation could not be observed. Nothing was promised: the work is not blocked and this is safe to re-run\n' \
      "$id" "$( [ -n "$BLOCKS" ] && printf ' and the dependency of %s on it' "$BLOCKS" || printf '' )" >&2
    return "$EXIT_UNOBSERVED"
  fi

  if [ "$JSON" -eq 1 ]; then
    jq -n -c --arg id "$id" --arg contract "$contract" --arg model "$model" \
      --arg route "$ROUTE" --arg blocks "$BLOCKS" --argjson budget "$BUDGET" \
      --arg cost "$cost" \
      '{schema:"fm-qualification-activation.v1", activation:$id, created:true,
        already_active:false, contract:$contract, model:$model, route:$route,
        blocks:(if $blocks == "" then null else $blocks end),
        attempt_budget:$budget, cost_rank:$cost}'
  else
    printf 'activated %s\n  contract: %s\n  binding:  %s (cost rank %s, cheapest promising candidate on route %s)\n  bound:    %s attempts, counted against this workflow and never against %s\n  blocks:   %s\n  next:     bin/fm-qualification.sh dispatch %s\n' \
      "$id" "$contract" "$model" "$cost" "$ROUTE" "$BUDGET" "${BLOCKS:-the blocked work}" \
      "${BLOCKS:-nothing recorded}" "$id"
  fi
  return "$EXIT_OK"
}

cmd_activations() {
  local f id live rc
  [ -d "$ACTIVATION_DIR" ] || { printf 'fm-qualification: no qualification workflow has been activated in this home\n'; return "$EXIT_OK"; }
  local out='[]'
  for f in "$ACTIVATION_DIR"/*.activation; do
    [ -f "$f" ] || continue
    id=$(activation_field "$f" activation || true)
    # Liveness is asked of the owner that holds it, on every read. Three values,
    # because "the backlog could not answer" is not "finished".
    rc=0
    qualification_backlog_live "$id" || rc=$?
    case "$rc" in
      0) live=active ;;
      1) live=closed ;;
      *) live=could-not-observe ;;
    esac
    if [ "$JSON" -eq 1 ]; then
      out=$(printf '%s' "$out" | jq -c --arg id "$id" --arg t "$live" \
        --arg c "$(activation_field "$f" contract || true)" \
        --arg m "$(activation_field "$f" model || true)" \
        --arg r "$(activation_field "$f" route || true)" \
        --arg b "$(activation_field "$f" blocks || true)" \
        '. + [{activation:$id, contract:$c, model:$m, route:$r,
               blocks:(if $b == "" then null else $b end),
               liveness:$t,
               active:($t == "active")}]')
    else
      printf '%s  contract=%s  binding=%s  route=%s  blocks=%s  %s\n' \
        "$id" "$(activation_field "$f" contract || true)" \
        "$(activation_field "$f" model || true)" \
        "$(activation_field "$f" route || true)" \
        "$(activation_field "$f" blocks || printf -- -)" "$live"
    fi
  done
  [ "$JSON" -eq 0 ] || printf '%s\n' "$out"
  return "$EXIT_OK"
}

cmd_dispatch() {
  local id=${POS[0]:-} file contract model route floor blocks harness effort
  local execution_route execution_model execution_harness execution_effort dispatch_rc
  [ -n "$id" ] || die "dispatch needs an activation id"
  fm_task_id_path_safe "$id" || die "unsafe activation id: $id"
  file=$(activation_file "$id")
  [ -f "$file" ] || { printf 'fm-qualification: no activation record at %s\n' "$file" >&2; return "$EXIT_UNOBSERVED"; }
  # Asked of the backlog owner rather than of a field here, so a workflow that was
  # closed elsewhere cannot be re-dispatched from a stale parameters file - and an
  # owner that cannot answer refuses rather than launching on an unread answer.
  dispatch_rc=0
  qualification_backlog_live "$id" || dispatch_rc=$?
  case "$dispatch_rc" in
    1) printf 'fm-qualification: the backlog owner records %s as finished, so it is not re-dispatched\n' "$id" >&2
       return "$EXIT_REFUSED" ;;
    "$EXIT_UNOBSERVED")
       printf 'fm-qualification: whether %s is still open COULD NOT BE OBSERVED, so it is not dispatched; an unread answer is not permission to launch\n' "$id" >&2
       return "$EXIT_UNOBSERVED" ;;
  esac
  contract=$(activation_field "$file" contract || true)
  model=$(activation_field "$file" model || true)
  route=$(activation_field "$file" route || true)
  floor=$(activation_field "$file" floor || true)
  blocks=$(activation_field "$file" blocks || true)
  harness=$(activation_field "$file" harness || true)
  effort=$(activation_field "$file" native_effort || true)
  execution_route=$(activation_field "$file" execution_route || true)
  execution_model=$(activation_field "$file" execution_model || true)
  execution_harness=$(activation_field "$file" execution_harness || true)
  execution_effort=$(activation_field "$file" execution_effort || true)
  [ -n "$contract" ] && [ -n "$model" ] && [ -n "$route" ] \
    || { printf 'fm-qualification: activation %s is incomplete and is not dispatched\n' "$id" >&2; return "$EXIT_REFUSED"; }
  if [ "$execution_model" != "$model" ] || [ "$execution_harness" != "$harness" ] || [ "$execution_effort" != "$effort" ]; then
    printf 'fm-qualification: activation %s assigns the bootstrap run to a binding other than the candidate tuple and is refused\n' "$id" >&2
    return "$EXIT_REFUSED"
  fi

  # EVERY field is re-validated and passed as a SEPARATE argument. The record
  # stores no command line, for the same reason the capacity deferral record
  # stores none: a state file must never be able to name something to run.
  local -a args=("$id" "$FM_HOME" --scout --reason-code NOVEL_DECOMPOSITION
                 --route "$execution_route" --model "$execution_model"
                 --harness "$execution_harness" --effort "$execution_effort")
  # The candidate runs once on the bootstrap route; missing target qualification blocks only the target route, so a second invocation path would manufacture evidence.
  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'bin/fm-spawn.sh'
    printf ' %q' "${args[@]}"
    printf '\n'
    return "$EXIT_OK"
  fi
  printf 'fm-qualification: launching %s for contract %s on %s through the spawn chokepoint\n' \
    "$id" "$contract" "$model"
  : "${blocks:-}"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-spawn.sh" "${args[@]}" || return "$EXIT_REFUSED"
  return "$EXIT_OK"
}

cmd_resolve() {
  local id=${POS[0]:-} file contract model blocks tmp harness effort
  [ -n "$id" ] || die "resolve needs an activation id"
  fm_task_id_path_safe "$id" || die "unsafe activation id: $id"
  [ -n "$RESULT" ] || die "resolve needs --result QUALIFIED|FAILED|COULD_NOT_OBSERVE"
  case "$RESULT" in
    QUALIFIED|FAILED|COULD_NOT_OBSERVE) ;;
    *) die "--result must be QUALIFIED, FAILED, or COULD_NOT_OBSERVE; a synonym is refused rather than normalized" ;;
  esac
  file=$(activation_file "$id")
  [ -f "$file" ] || { printf 'fm-qualification: no activation record at %s\n' "$file" >&2; return "$EXIT_UNOBSERVED"; }
  contract=$(activation_field "$file" contract || true)
  model=$(activation_field "$file" model || true)
  blocks=$(activation_field "$file" blocks || true)
  harness=$(activation_field "$file" harness || true)
  effort=$(activation_field "$file" native_effort || true)

  local terminal=
  case "$RESULT" in
    QUALIFIED) terminal=qualified ;;
    FAILED) terminal=failed ;;
    COULD_NOT_OBSERVE) terminal= ;;
  esac

  # A PASS IS VERIFIED, NEVER TAKEN ON TRUST. --result QUALIFIED is a word a
  # caller types, and a claim anyone can write is a claim that will eventually be
  # written wrongly - which is precisely the defect this register exists inside.
  # So the register is re-read: unless it independently COMPUTES QUALIFIED for
  # this binding against this contract, from an admissible record whose declared
  # dependencies are observed unchanged and whose adjudication returned a pass,
  # the pass is refused and the workflow stays open. FAILED and COULD_NOT_OBSERVE
  # need no such check, because neither one grants anything.
  if [ "$RESULT" = QUALIFIED ] || [ "$RESULT" = FAILED ]; then
    local computed computed_state
    computed=$(fm_qualification_state "$contract" "$model" "$harness" "$effort")
    computed_state=$(printf '%s' "$computed" | jq -r '.state' 2>/dev/null)
    if [ "$computed_state" != "$RESULT" ]; then
      printf 'fm-qualification: refusing to close %s as %s. The register computes %s for %s against %s: %s. Write the record first; this command records what the register can observe, never what a caller asserts\n' \
        "$id" "$RESULT" "$computed_state" "$model" "$contract" \
        "$(printf '%s' "$computed" | jq -r '.reason' 2>/dev/null)" >&2
      case "$computed_state" in
        FAILED) return "$EXIT_REFUSED" ;;
        QUALIFICATION_REQUIRED|QUALIFICATION_STALE) return "$EXIT_REQUIRED" ;;
        *) return "$EXIT_UNOBSERVED" ;;
      esac
    fi
  fi

  # COULD_NOT_OBSERVE is NONTERMINAL and spends exactly one attempt. Nothing
  # adverse is recorded about the binding: an observation that did not happen is
  # not a finding, and writing one would build the reputation the ruling forbids.
  # The workflow item stays open, which is the whole of "still active" - there is
  # no second field to leave un-flipped.
  if [ -z "$terminal" ]; then
    local budget attempt_out rc=0
    budget=$(activation_field "$file" attempt_budget || printf '%s' "$BUDGET")
    attempt_out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-attempt.sh" open "$id" --budget "$budget" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      printf 'fm-qualification: the bound on %s is spent or unrecordable (%s), so this workflow stops rather than retrying without a bound\n' "$id" "$attempt_out" >&2
      qualification_backlog_park "$id" \
        || printf 'fm-qualification: the backlog owner did not confirm parking %s; it remains open and no release is claimed\n' "$id" >&2
      return "$EXIT_UNOBSERVED"
    fi
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-attempt.sh" end "$id" >/dev/null 2>&1 || true
    printf 'fm-qualification: %s remains ACTIVE. The qualification of %s against %s COULD NOT BE OBSERVED, which is neither a pass nor a finding against that binding; one attempt of %s is spent and the repair is to the observation\n' \
      "$id" "$model" "$contract" "$budget"
    return "$EXIT_UNOBSERVED"
  fi

  # A FAILED workflow advances BEFORE it closes, so the successor already holds
  # the dependency when the predecessor stops holding it. Ordering is the entire
  # mechanism: there is no edge to transfer, because closing this item resolves
  # its own blocker and the successor registered its own. Reversed, a successor
  # that failed to register would leave the work eligible with nothing qualified;
  # this way the worst case is that the work is briefly blocked on both, which is
  # safe and clears itself on the next close.
  if [ "$RESULT" = FAILED ]; then
    local advance_out advance_rc=0 dependents dependent advanced=0
    ROUTE=$(activation_field "$file" route || true)
    dependents=$(qualification_dependents "$id") || {
      printf 'fm-qualification: the dependents of %s COULD NOT BE OBSERVED from the fleet snapshot, so it stays open and none can be released\n' "$id" >&2
      return "$EXIT_UNOBSERVED"
    }
    printf 'fm-qualification: %s is observed FAILED. The exclusion evidence for %s against %s is PRESERVED; evaluating the next promising candidate now\n' \
      "$id" "$model" "$contract" >&2
    while IFS= read -r dependent; do
      [ -n "$dependent" ] || [ "$advanced" -eq 0 ] || continue
      BLOCKS=$dependent
      advance_rc=0
      advance_out=$(cmd_activate 2>&1) || advance_rc=$?
      printf '%s\n' "$advance_out" >&2
      if [ "$advance_rc" -ne 0 ] \
         && ! { [ "$advance_rc" -eq "$EXIT_REFUSED" ] && printf '%s' "$advance_out" | grep -qF "$FM_QUAL_TOKEN_NO_PROMISING"; }; then
        printf 'fm-qualification: advancement from %s COULD NOT BE OBSERVED, so it stays open and the blocked work is neither released nor stranded\n' "$id" >&2
        return "$EXIT_UNOBSERVED"
      fi
      advanced=1
    done <<EOF
${dependents:-}
EOF
    if ! qualification_backlog_close "$id"; then
      printf 'fm-qualification: the backlog owner did not confirm closing %s, so it stays open and re-runnable; the successor already holds the dependency and nothing is stranded\n' "$id" >&2
      return "$EXIT_UNOBSERVED"
    fi
    return "$EXIT_REFUSED"
  fi

  # A pass closes the workflow item, and THAT is what returns the blocked work to
  # normal eligibility: bin/fm-fleet-snapshot.sh resolves a blocker exactly when
  # its record is Done. No unblock call exists to fail after the fact, so there is
  # no window in which the work is eligible while the workflow still looks live.
  if ! qualification_backlog_close "$id"; then
    printf 'fm-qualification: the backlog owner did not confirm closing %s, so NO return to eligibility is claimed; the record stands and this is safe to re-run\n' "$id" >&2
    return "$EXIT_UNOBSERVED"
  fi
  printf 'fm-qualification: %s is closed QUALIFIED for %s against %s. The evidence is now reusable for every route requiring that contract, and %s returns to normal eligibility with its identity, custody and budget unchanged\n' \
    "$id" "$model" "$contract" "${blocks:-the blocked work}"
  return "$EXIT_OK"
}

: "${DATA:?}"

case "$CMD" in
  contracts) cmd_contracts; exit $? ;;
  records) cmd_records; exit $? ;;
  state) cmd_state; exit $? ;;
  validate) cmd_validate; exit $? ;;
  reviewer) cmd_reviewer; exit $? ;;
  activate) cmd_activate; exit $? ;;
  activations) cmd_activations; exit $? ;;
  dispatch) cmd_dispatch; exit $? ;;
  resolve) cmd_resolve; exit $? ;;
  *) die "unknown command: $CMD" ;;
esac
