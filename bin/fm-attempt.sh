#!/usr/bin/env bash
# The single owner of a task's DURABLE ATTEMPT COUNT and its RETRY BUDGET, so
# "should this be retried?" is arithmetic over a recorded number rather than a
# judgment made inside the worker that is failing.
#
# Nothing counted attempts before this: no state field, no metadata field. The
# only bound on repetition was a line of prose in the generated brief - "if you
# hit the same obstacle twice, stop" - which made the WORKER the arbiter of its
# own retry budget, evaluated from a context that resets on every relaunch. A
# count the worker cannot see and cannot reset replaces it.
#
# THE DURABLE RECORD. state/<id>.attempt, key=value, last assignment winning:
#
#   attempt=<n>          attempts COMMITTED for this task id so far.
#   attempt_budget=<b>   the most attempts this task id may commit.
#   terminal=<state>     written only when a budget is exhausted (below).
#   updated=<epoch>      when the record last changed.
#   deferrals=<n>        capacity deferrals recorded for this task id so far.
#   deferral_budget=<b>  the most capacity deferrals it may record.
#   defer_signature=<s>  the capacity picture the last deferral observed.
#   defer_stagnant=<n>   consecutive deferrals that observed that same picture.
#
# WHY CAPACITY DEFERRALS ARE COUNTED HERE AND NOT SOMEWHERE ELSE. A deferral is
# not a retry of failed work - nothing failed, the fleet simply had no capacity
# meeting the task's floor - so it must never spend an attempt, and it does not.
# But it is the same QUESTION this file already owns: how many times may this
# task id repeat something before the repetition itself is the problem? Keeping
# both counts in one record means a task cannot be bounded by one and unbounded
# by the other, and means a reader joins on one file rather than two.
#
# TWO BOUNDS, BECAUSE THEY CATCH DIFFERENT FAILURES. `deferral_budget` bounds the
# total, so a wait can never become an infinite poll. `defer_stagnant` bounds
# consecutive deferrals that observed the IDENTICAL capacity picture, so a wait
# that is not progressing stops long before the total budget would notice - and a
# wait that IS progressing, because a reset time appeared or a candidate came
# back, resets that counter and keeps going. Either bound reaching its limit is
# the same unified terminal state as an exhausted attempt budget, declared the
# same way, because in both cases a declared bound was reached before the goal
# was met.
#
# The same two numbers are published onto state/<id>.meta as attempt= and
# attempt_budget= by bin/fm-spawn.sh, so every reader that already joins on task
# metadata sees the count without learning a second file. This record is the
# authority; meta carries the readable copy.
#
# WHAT SPENDS AN ATTEMPT: A RECORDED FAILURE, NOT A LAUNCH. An attempt
# increments only when the PRIOR attempt has a recorded FAILED terminal outcome.
# A spawn that follows no recorded failure - a dead runtime, an agent-free husk
# left by a session restart, a freeze, any recovery reclaim - is a CONTINUATION
# of the same attempt: the count persists and does not move, and a continuation
# is never refused however often it happens.
#
# The outcome record draws that line, not the spawn event, which is the whole
# reason this increment depends on CFVC-12: "a retry is meaningless without a
# terminal outcome that can say the prior attempt failed". Counting launches
# instead conflates recovering a task whose RUNTIME died with retrying work that
# FAILED, and would refuse to bring a healthy task back after two session
# restarts.
#
# The failure signal read here is the `failed:` verb on the task's own status
# log - the same declaration bin/fm-wake-ledger.sh derives outcome=failed from,
# so this reads CFVC-12's evidence rather than a private second signal. failures=
# records how many such declarations had been seen when the count last moved, so
# only a failure NEWER than the last counted attempt spends the next one. This
# script's own budget-exhaustion declaration is deliberately excluded from that
# tally: it announces a stop that already happened and must never itself look
# like the failure that justifies another attempt.
#
# A wedged worker is no exception. Relaunching one continues the same attempt
# unless the wedge was recorded as a failure first, which is what makes the
# decision arithmetic over a record rather than a judgment about how stuck it
# looked.
#
# MIGRATION - AN ABSENT FIELD READS AS ATTEMPT 1. A task dispatched before this
# existed has no record and no meta field, yet it plainly had an attempt. So the
# prior count is resolved in this order: the durable record when present; else 1
# when the task's meta exists (that metadata IS the evidence of an attempt);
# else 0. A pre-existing task therefore retries at attempt 2 rather than
# restarting its budget at 1.
#
# WHAT SURVIVES A TEARDOWN. bin/fm-teardown.sh retires the record on an ordinary
# release and PRESERVES it under --force. An ordinary release means the task
# reached a sanctioned completion - landed work, or a parked release whose pull
# request is still open - so the count retires with the task it measured and a
# re-dispatch of that id starts a fresh budget. --force is the discard path:
# the work was thrown away, a re-dispatch of that id is a genuine retry, and
# resetting its count there would make the budget unbounded by simply
# discarding between attempts.
#
# EXHAUSTION IS A NAMED TERMINAL STATE, NOT A SILENT STOP. When the budget is
# spent, `open` and `check` refuse the next attempt, record
# terminal=budget_exhausted, and append one
# `failed: attempt budget exhausted ...` line to state/<id>.status.
#
#   budget_exhausted is CFVC-11's UNIFIED terminal-state vocabulary
#   (loopspecs/terminal-states.json), not a third vocabulary invented here: "a
#   declared bound - iterations, wall clock, context, capacity or cost - was
#   reached before the goal was met". FM_ATTEMPT_TERMINAL_STATE below is that
#   one name, and tests/fm-attempt.test.sh asserts it against that file
#   whenever the file is present.
#
# A STOP THAT WAS NEVER MEASURABLE IS A SECOND, DIFFERENT TERMINAL STATE. A
# capacity wait can also end because the count that bounds it could not be
# written at all, and that is not exhaustion - it is could-not-observe on the
# bound itself. `stop-defer` therefore requires the caller to name which of the
# two it saw and records terminal=blocked_by_evidence_integrity for the second,
# so a defective recorder is never reported as a pool that was tried and found
# empty. Both names come from the same unified file; see
# FM_ATTEMPT_UNOBSERVABLE_STATE below.
#
#   The status append is deliberately the ONLY terminal producer here. A
#   `failed:` status line is what CFVC-12's terminal-outcome derivation reads
#   (bin/fm-wake-ledger.sh `derive`/`sweep`), so exhaustion books outcome=failed
#   through that owner instead of a second producer writing its own ledger line.
#   Before that derivation exists the append still wakes firstmate, which is the
#   part that makes the stop audible either way.
#
# SECONDMATES ARE EXEMPT. A secondmate is persistent and its relaunch is routine
# liveness recovery, run unattended at session start; counting those as retries
# would eventually refuse to bring a healthy long-lived secondmate back up.
# bin/fm-spawn.sh calls this for ship and scout kinds only.
#
# THERE IS NO RESET. A budget raised by an explicit --budget is the only way
# past an exhausted count, and it is recorded, so the override is inspectable
# afterwards. A reset verb would hand back exactly the discretion this replaces.
#
# Usage:
#   fm-attempt.sh show <id>
#       Print "attempt=<n> attempt_budget=<b>" for the resolved prior count.
#       An unknown task prints attempt=0 with the default budget.
#   fm-attempt.sh check <id> [--budget <n>]
#       Decide whether the next spawn is within budget, committing nothing.
#       Exit 0 when it is, 3 when a NEW attempt would exceed the budget. A
#       continuation always exits 0. Called before a spawn creates anything, so
#       a refused retry allocates no worktree or endpoint.
#   fm-attempt.sh open <id> [--budget <n>]
#       Same decision, then COMMIT the result durably and print
#       "attempt=<n> attempt_budget=<b>" for the attempt now open - incremented
#       when a new failure justified it, unchanged on a continuation. Called at
#       the moment a spawn publishes task metadata, so an attempt that never
#       reached a launch does not spend budget.
#   fm-attempt.sh end <id>
#       Record that the open attempt ENDED without landing, so the next spawn is
#       a new attempt rather than a continuation. Teardown's --force hook: a
#       discard deletes the status log along with the task's own failure
#       declaration, so the end is recorded here or the evidence goes with it.
#       A task with no open attempt records nothing.
#   fm-attempt.sh defer <id> [--defer-budget <n>] [--signature <s>]
#                            [--stagnation-limit <n>]
#       Record one CAPACITY deferral for this task id and decide whether waiting
#       again is still within bounds. Exit 0 and print
#       "deferrals=<n> deferral_budget=<b> stagnant=<k> stagnation_limit=<l>"
#       when it is; exit 3, record terminal=budget_exhausted and append one
#       `failed:` line when either bound is spent. Spends no attempt: a task the
#       fleet had no capacity for did not fail.
#   fm-attempt.sh stop-defer <id> --reason <text>
#                            --observation observed-bad|could-not-observe
#       Stop a capacity wait when its retry owner cannot durably maintain the
#       record that makes another check safe, and print the resulting
#       "terminal=<state>". --observation is REQUIRED and names which of the two
#       stops this is: observed-bad records terminal=budget_exhausted, the bound
#       was reached; could-not-observe records
#       terminal=blocked_by_evidence_integrity, the bound was never enforceable.
#       There is no default, because defaulting would report a broken recorder
#       as an exhausted pool. A task already in a terminal state keeps the state
#       it was first recorded in and is not rewritten.
#   fm-attempt.sh retire <id>
#       Remove the record. Teardown's ordinary-release hook.
#
# --budget sets the budget for this task id from here on and is recorded; absent,
# a recorded budget stands, and an unrecorded one defaults to
# FM_ATTEMPT_BUDGET_DEFAULT (2). A default that is not a positive integer is
# refused outright rather than compared, so a misconfigured environment can
# never unbind the budget. Two is not arbitrary: it is the same threshold
# the prose it replaces used, and the one LoopSpec's no_progress block already
# encodes.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fm-wake-lib.sh owns FM_ROOT/FM_HOME/STATE resolution.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm-pr-lib.sh owns fm_task_id_path_safe, the task-id path-safety predicate.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

# The unified terminal states this file may produce. Two, not one.
#
# A bound that was REACHED and a bound that was never OBSERVABLE are different
# facts, and recording them under one name makes a broken recorder read exactly
# like an exhausted pool: the fleet is told "we tried everything" when the truth
# is "we could not tell how many times we tried". One is a routing fact worth
# acting on, the other is a defect in the instrument, and the repair differs.
# Both names are CFVC-11's unified vocabulary (loopspecs/terminal-states.json),
# which already separates them - budget_exhausted is "a declared bound was
# reached before the goal was met", while blocked_by_evidence_integrity is "a
# required source was unreadable, so absence of evidence could not be
# distinguished from evidence of absence". That is precisely a deferral count
# that cannot be written: the could-not-observe lands on the BOUND ITSELF, not
# on a detail beside it, and a bound you cannot observe is not a bound.
FM_ATTEMPT_TERMINAL_STATE=budget_exhausted
FM_ATTEMPT_UNOBSERVABLE_STATE=blocked_by_evidence_integrity
ATTEMPT_BUDGET_DEFAULT=${FM_ATTEMPT_BUDGET_DEFAULT:-2}
# How many capacity deferrals one task id may record, and how many CONSECUTIVE
# deferrals may observe an unchanged capacity picture before the wait is called
# stagnant. Both are deliberately far larger than the attempt budget: a provider
# window can legitimately take days to reset, and stopping a lawful wait early
# is the failure this closes rather than the one it guards against.
ATTEMPT_DEFER_BUDGET_DEFAULT=${FM_ATTEMPT_DEFER_BUDGET_DEFAULT:-24}
ATTEMPT_DEFER_STAGNATION_DEFAULT=${FM_ATTEMPT_DEFER_STAGNATION_DEFAULT:-8}
# Exit code for a refused retry, distinct from an argument error (2) so a caller
# can tell "this task is out of budget" from "you called me wrong".
ATTEMPT_EXHAUSTED_EXIT=3

usage() {
  LC_ALL=C awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SCRIPT_DIR/fm-attempt.sh"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# One key's value from a key=value file, last assignment winning. An absent file
# or key yields the empty string; every caller decides what absence means rather
# than being handed a guess.
attempt_field() {  # <file> <key>
  [ -f "$1" ] || return 0
  LC_ALL=C awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$1"
}

attempt_is_count() {  # <value>
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# The migration rule in one place: record, else metadata-implies-one, else none.
attempt_prior() {  # <id> -> count on stdout
  local id=$1 n rec
  rec="$STATE/$id.attempt"
  n=$(attempt_field "$rec" attempt)
  if attempt_is_count "$n"; then
    printf '%s' "$n"
    return 0
  fi
  if [ -f "$STATE/$id.meta" ]; then
    n=$(attempt_field "$STATE/$id.meta" attempt)
    attempt_is_count "$n" && [ "$n" -gt 0 ] || n=1
    printf '%s' "$n"
    return 0
  fi
  printf '0'
}

# Declared failures on the task's own status log - the same `failed:` verb
# bin/fm-wake-ledger.sh derives outcome=failed from, so the two read one signal.
# This script's OWN budget-exhaustion declaration is excluded: it reports a stop
# that already happened, and counting it would let one refusal manufacture the
# very failure that justifies the next attempt.
attempt_failures() {  # <id> -> count on stdout
  local file="$STATE/$1.status"
  [ -f "$file" ] || { printf '0'; return 0; }
  # One pass, and never `grep -c`, which prints 0 AND exits 1 on no match, so a
  # `|| printf 0` fallback silently yields "0\n0" and every later comparison
  # errors out into a false "not exceeded".
  LC_ALL=C awk '
    /^failed: attempt budget exhausted/ { next }
    /^failed:/ { n += 1 }
    END { printf "%d", n + 0 }
  ' "$file" 2>/dev/null || printf '0'
}

# How many declared failures had been seen when the count last moved. An absent
# field reads as 0, so a pre-existing record whose task already failed treats
# that failure as new exactly once.
attempt_failures_seen() {  # <id> -> count on stdout
  local n
  n=$(attempt_field "$STATE/$1.attempt" failures)
  attempt_is_count "$n" || n=0
  printf '%s' "$n"
}

# The deferral count and its bound, resolved the same way and defaulting the
# same way, so `show` never has to decide what an absent field means.
attempt_defer_count() {  # <id> -> count on stdout
  local n
  n=$(attempt_field "$STATE/$1.attempt" deferrals)
  attempt_is_count "$n" || n=0
  printf '%s' "$n"
}

attempt_defer_budget() {  # <id> -> budget on stdout
  local b
  b=$(attempt_field "$STATE/$1.attempt" deferral_budget)
  attempt_is_count "$b" && [ "$b" -gt 0 ] || b=$ATTEMPT_DEFER_BUDGET_DEFAULT
  printf '%s' "$b"
}

# Explicit flag wins, then the record, then the task metadata, then the default.
attempt_budget() {  # <id> <explicit-or-empty> -> budget on stdout
  local id=$1 explicit=${2-} b
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"
    return 0
  fi
  for b in \
    "$(attempt_field "$STATE/$id.attempt" attempt_budget)" \
    "$(attempt_field "$STATE/$id.meta" attempt_budget)"; do
    if attempt_is_count "$b" && [ "$b" -gt 0 ]; then
      printf '%s' "$b"
      return 0
    fi
  done
  printf '%s' "$ATTEMPT_BUDGET_DEFAULT"
}

# Whole record rewritten from the values passed, so a field can never be left
# behind from an earlier state. Written to a temp file and moved into place, so
# a concurrent reader sees either the old record or the new one.
#
# The four deferral fields are optional trailing arguments, and OMITTING them
# PRESERVES what the record already holds. That distinction is load-bearing: the
# attempt path rewrites this record on every check, open and end, and if those
# writes dropped the deferral count then a single relaunch would silently
# unbound a wait this file exists to bound. Passing them explicitly is how the
# deferral path sets them; passing none is how every other path leaves them
# alone.
attempt_write() {  # <id> <attempt> <budget> <terminal-or-empty> <failures> <ended>
                   #   [<deferrals> <deferral-budget> <signature> <stagnant>]
  local id=$1 n=$2 b=$3 term=${4-} failures=${5-0} ended=${6-0} rec tmp
  local deferrals defer_budget signature stagnant
  rec="$STATE/$id.attempt"
  if [ "$#" -ge 10 ]; then
    deferrals=$7 defer_budget=$8 signature=$9 stagnant=${10}
  else
    deferrals=$(attempt_field "$rec" deferrals)
    defer_budget=$(attempt_field "$rec" deferral_budget)
    signature=$(attempt_field "$rec" defer_signature)
    stagnant=$(attempt_field "$rec" defer_stagnant)
  fi
  # An absent ended flag is written as the 0 it means, so the record's shape does
  # not depend on which caller last wrote it.
  attempt_is_count "$ended" || ended=0
  [ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null || return 1
  tmp="$rec.tmp.$$"
  {
    printf 'attempt=%s\n' "$n"
    printf 'attempt_budget=%s\n' "$b"
    printf 'failures=%s\n' "$failures"
    printf 'ended=%s\n' "$ended"
    [ -z "$deferrals" ] || printf 'deferrals=%s\n' "$deferrals"
    [ -z "$defer_budget" ] || printf 'deferral_budget=%s\n' "$defer_budget"
    [ -z "$signature" ] || printf 'defer_signature=%s\n' "$signature"
    [ -z "$stagnant" ] || printf 'defer_stagnant=%s\n' "$stagnant"
    [ -z "$term" ] || printf 'terminal=%s\n' "$term"
    printf 'updated=%s\n' "$(date +%s)"
  } > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# Did an authority record that the open attempt ENDED without landing? A forced
# teardown discards the work AND deletes the status log that would otherwise
# carry the failure declaration, so the end has to be recorded here or the
# evidence disappears with the log - and discarding between attempts would
# silently make the budget unbounded.
attempt_ended() {  # <id>
  [ "$(attempt_field "$STATE/$1.attempt" ended)" = 1 ]
}

# The refusal. Recorded once per exhaustion: a second refused spawn must not
# append a second failure declaration for the same stop, because the status log
# is a wake surface and the terminal fact has not changed.
# The tally passed in is the one ALREADY SEEN, never the current count: a
# refusal opens nothing, so it must not consume the pending failure and quietly
# turn the next spawn into a continuation of an attempt that never started.
attempt_refuse() {  # <id> <prior> <budget> <failures-already-seen>
  local id=$1 prior=$2 budget=$3 failures=${4-0} already
  already=$(attempt_field "$STATE/$id.attempt" terminal)
  attempt_write "$id" "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" "$failures" \
    "$(attempt_field "$STATE/$id.attempt" ended)" \
    || printf 'warning: could not record the exhausted attempt budget for %s\n' "$id" >&2
  if [ "$already" != "$FM_ATTEMPT_TERMINAL_STATE" ]; then
    printf '%s: attempt budget exhausted after %s of %s attempts (%s)\n' \
      failed "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" \
      >> "$STATE/$id.status" 2>/dev/null \
      || printf 'warning: could not append the exhausted-budget failure for %s\n' "$id" >&2
  fi
  printf 'error: %s has spent its retry budget: %s of %s attempts used (%s). Raise it deliberately with --attempt-budget <n> if another attempt is warranted; it is recorded.\n' \
    "$id" "$prior" "$budget" "$FM_ATTEMPT_TERMINAL_STATE" >&2
}

parse_budget_flag() {  # <args...> -> sets PARSED_BUDGET
  PARSED_BUDGET=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --budget)
        [ "$#" -ge 2 ] || die "--budget needs a value"
        PARSED_BUDGET=$2
        attempt_is_count "$PARSED_BUDGET" && [ "$PARSED_BUDGET" -gt 0 ] \
          || die "--budget must be a positive integer: $PARSED_BUDGET"
        shift 2
        ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
}

require_id() {  # <id>
  [ -n "${1-}" ] || die "a task id is required"
  fm_task_id_path_safe "$1" || die "invalid task id: $1"
}

cmd_show() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "show takes only a task id"
  printf 'attempt=%s attempt_budget=%s deferrals=%s deferral_budget=%s terminal=%s\n' \
    "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" \
    "$(attempt_defer_count "$id")" "$(attempt_defer_budget "$id")" \
    "$(attempt_field "$STATE/$id.attempt" terminal)"
}

# The one decision both check and open make: is the next spawn a NEW attempt or
# a CONTINUATION of the one already open? A failure declared since the count
# last moved is what makes it new; anything else - a dead runtime, a husk, a
# reclaim - continues. Sets ATTEMPT_PRIOR, ATTEMPT_BUDGET_RESOLVED,
# ATTEMPT_FAILURES, ATTEMPT_NEXT, and ATTEMPT_IS_NEW.
attempt_resolve() {  # <id> <explicit-budget-or-empty>
  local id=$1 explicit=${2-}
  ATTEMPT_BUDGET_RESOLVED=$(attempt_budget "$id" "$explicit")
  ATTEMPT_PRIOR=$(attempt_prior "$id")
  ATTEMPT_FAILURES=$(attempt_failures "$id")
  if [ "$ATTEMPT_PRIOR" -eq 0 ]; then
    # Nothing has been attempted yet, so the first launch opens attempt 1
    # whether or not anything ever failed.
    ATTEMPT_IS_NEW=1
    ATTEMPT_NEXT=1
    return 0
  fi
  if attempt_ended "$id" || [ "$ATTEMPT_FAILURES" -gt "$(attempt_failures_seen "$id")" ]; then
    ATTEMPT_IS_NEW=1
    ATTEMPT_NEXT=$((ATTEMPT_PRIOR + 1))
    return 0
  fi
  ATTEMPT_IS_NEW=0
  ATTEMPT_NEXT=$ATTEMPT_PRIOR
}

cmd_check() {
  local id=${1-}
  require_id "$id"
  shift
  parse_budget_flag "$@"
  attempt_resolve "$id" "$PARSED_BUDGET"
  # Only a NEW attempt can exceed the budget. A continuation is never refused,
  # however many times a dead runtime has to be replaced.
  if [ "$ATTEMPT_IS_NEW" -eq 1 ] && [ "$ATTEMPT_PRIOR" -ge "$ATTEMPT_BUDGET_RESOLVED" ]; then
    attempt_refuse "$id" "$ATTEMPT_PRIOR" "$ATTEMPT_BUDGET_RESOLVED" "$(attempt_failures_seen "$id")"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi
  printf 'attempt=%s attempt_budget=%s\n' "$ATTEMPT_NEXT" "$ATTEMPT_BUDGET_RESOLVED"
}

cmd_open() {
  local id=${1-}
  require_id "$id"
  shift
  parse_budget_flag "$@"
  attempt_resolve "$id" "$PARSED_BUDGET"
  if [ "$ATTEMPT_IS_NEW" -eq 1 ] && [ "$ATTEMPT_PRIOR" -ge "$ATTEMPT_BUDGET_RESOLVED" ]; then
    attempt_refuse "$id" "$ATTEMPT_PRIOR" "$ATTEMPT_BUDGET_RESOLVED" "$(attempt_failures_seen "$id")"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi
  # The failure tally is committed with the count, so the failure that justified
  # this attempt can never justify a second one. A continuation rewrites the
  # same count and tally, which is what keeps a repeated reclaim free.
  #
  # A commit that cannot be made durable is refused rather than launched
  # uncounted: an attempt nobody recorded is exactly the state this replaces.
  attempt_write "$id" "$ATTEMPT_NEXT" "$ATTEMPT_BUDGET_RESOLVED" '' "$ATTEMPT_FAILURES" 0 \
    || die "could not record attempt $ATTEMPT_NEXT for $id at $STATE/$id.attempt"
  printf 'attempt=%s attempt_budget=%s\n' "$ATTEMPT_NEXT" "$ATTEMPT_BUDGET_RESOLVED"
}

cmd_end() {
  local id=${1-} prior budget
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "end takes only a task id"
  # Only a task that has an open attempt can end one. Recording an end for a
  # task nobody attempted would invent a retry out of nothing.
  prior=$(attempt_prior "$id")
  [ "$prior" -gt 0 ] || return 0
  budget=$(attempt_budget "$id" '')
  attempt_write "$id" "$prior" "$budget" \
    "$(attempt_field "$STATE/$id.attempt" terminal)" "$(attempt_failures "$id")" 1 \
    || die "could not record the end of attempt $prior for $id"
}

# The capacity-deferral refusal. Recorded once per exhaustion for the same
# reason the attempt refusal is: the status log is a wake surface and repeating
# a terminal fact that has not changed only costs supervision turns.
attempt_defer_refuse() {  # <id> <deferrals> <budget> <stagnant> <limit> <cause>
  local id=$1 n=$2 budget=$3 stagnant=$4 limit=$5 cause=$6 already
  already=$(attempt_field "$STATE/$id.attempt" terminal)
  attempt_write "$id" "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" \
    "$FM_ATTEMPT_TERMINAL_STATE" "$(attempt_failures_seen "$id")" \
    "$(attempt_field "$STATE/$id.attempt" ended)" \
    "$n" "$budget" "$(attempt_field "$STATE/$id.attempt" defer_signature)" "$stagnant" \
    || printf 'warning: could not record the exhausted deferral budget for %s\n' "$id" >&2
  if [ "$already" != "$FM_ATTEMPT_TERMINAL_STATE" ]; then
    printf '%s: waiting for capacity stopped after %s deferrals of %s allowed, the last %s of them observing an unchanged capacity picture against a stagnation limit of %s (%s)\n' \
      failed "$n" "$budget" "$stagnant" "$limit" "$FM_ATTEMPT_TERMINAL_STATE" \
      >> "$STATE/$id.status" 2>/dev/null \
      || printf 'warning: could not append the exhausted-deferral failure for %s\n' "$id" >&2
  fi
  printf 'error: %s has stopped waiting for capacity: %s (%s). The work was never dispatched into a pool that could not run it, and it is not lost - it is held in the backlog. A higher --defer-budget must be chosen before the bound is spent; there is no in-place grant after exhaustion. Continuing now requires a new decision: run bin/fm-capacity-retry.sh release %s and then bin/fm-attempt.sh retire %s; both are required. Then dispatch the task afresh as a new work item.\n' \
    "$id" "$cause" "$FM_ATTEMPT_TERMINAL_STATE" "$id" "$id" >&2
}

# A signature is compared, never parsed, so it only has to be stable and to fit
# on one line of a key=value record. Whitespace is collapsed rather than
# rejected, because a caller building one from a candidate list should not have
# to know this file's storage format.
attempt_clean_signature() {  # <raw>
  printf '%s' "${1-}" | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ' | LC_ALL=C sed 's/^ //; s/ $//'
}

cmd_defer() {
  local id=${1-} budget signature stagnation prior_sig deferrals stagnant
  require_id "$id"
  shift
  PARSED_DEFER_BUDGET='' PARSED_SIGNATURE='' PARSED_STAGNATION=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --defer-budget)
        [ "$#" -ge 2 ] || die "--defer-budget needs a value"
        PARSED_DEFER_BUDGET=$2
        attempt_is_count "$PARSED_DEFER_BUDGET" && [ "$PARSED_DEFER_BUDGET" -gt 0 ] \
          || die "--defer-budget must be a positive integer: $PARSED_DEFER_BUDGET"
        shift 2 ;;
      --stagnation-limit)
        [ "$#" -ge 2 ] || die "--stagnation-limit needs a value"
        PARSED_STAGNATION=$2
        attempt_is_count "$PARSED_STAGNATION" && [ "$PARSED_STAGNATION" -gt 0 ] \
          || die "--stagnation-limit must be a positive integer: $PARSED_STAGNATION"
        shift 2 ;;
      --signature)
        [ "$#" -ge 2 ] || die "--signature needs a value"
        PARSED_SIGNATURE=$(attempt_clean_signature "$2")
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  budget=$PARSED_DEFER_BUDGET
  if [ -z "$budget" ]; then
    budget=$(attempt_field "$STATE/$id.attempt" deferral_budget)
    attempt_is_count "$budget" && [ "$budget" -gt 0 ] || budget=$ATTEMPT_DEFER_BUDGET_DEFAULT
  fi
  stagnation=$PARSED_STAGNATION
  [ -n "$stagnation" ] || stagnation=$ATTEMPT_DEFER_STAGNATION_DEFAULT

  deferrals=$(attempt_field "$STATE/$id.attempt" deferrals)
  attempt_is_count "$deferrals" || deferrals=0
  stagnant=$(attempt_field "$STATE/$id.attempt" defer_stagnant)
  attempt_is_count "$stagnant" || stagnant=0
  prior_sig=$(attempt_field "$STATE/$id.attempt" defer_signature)

  # The total bound is checked BEFORE committing, exactly as the attempt budget
  # is: a refusal records nothing new to wait on, so it must not consume the
  # deferral it is refusing.
  if [ "$deferrals" -ge "$budget" ]; then
    attempt_defer_refuse "$id" "$deferrals" "$budget" "$stagnant" "$stagnation" \
      "the deferral budget of $budget is spent"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi

  deferrals=$((deferrals + 1))
  # An unchanged picture advances the stagnation counter; any change resets it,
  # because a wait whose observed picture is moving is a wait that is working.
  # A caller that supplies no signature can never look stagnant, which is why
  # the total budget above still bounds it.
  if [ -n "$PARSED_SIGNATURE" ] && [ "$PARSED_SIGNATURE" = "$prior_sig" ]; then
    stagnant=$((stagnant + 1))
  else
    stagnant=1
  fi

  if [ "$stagnant" -ge "$stagnation" ]; then
    attempt_write "$id" "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" '' \
      "$(attempt_failures_seen "$id")" "$(attempt_field "$STATE/$id.attempt" ended)" \
      "$deferrals" "$budget" "${PARSED_SIGNATURE:-$prior_sig}" "$stagnant" \
      || die "could not record deferral $deferrals for $id at $STATE/$id.attempt"
    attempt_defer_refuse "$id" "$deferrals" "$budget" "$stagnant" "$stagnation" \
      "$stagnant consecutive deferrals observed an unchanged capacity picture, so the wait is not progressing"
    exit "$ATTEMPT_EXHAUSTED_EXIT"
  fi

  attempt_write "$id" "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" \
    "$(attempt_field "$STATE/$id.attempt" terminal)" \
    "$(attempt_failures_seen "$id")" "$(attempt_field "$STATE/$id.attempt" ended)" \
    "$deferrals" "$budget" "${PARSED_SIGNATURE:-$prior_sig}" "$stagnant" \
    || die "could not record deferral $deferrals for $id at $STATE/$id.attempt"
  printf 'deferrals=%s deferral_budget=%s stagnant=%s stagnation_limit=%s\n' \
    "$deferrals" "$budget" "$stagnant" "$stagnation"
}

cmd_stop_defer() {
  local id=${1-} reason='' observation='' state already
  require_id "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      --observation)
        [ "$#" -ge 2 ] || die "--observation needs a value"
        observation=$2
        shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$reason" ] || die "stop-defer needs --reason"
  # --observation has NO DEFAULT, and that is the whole point. A caller that
  # does not say which of the two facts it observed would land on whichever
  # state this file happened to prefer, and any preference here is
  # budget_exhausted - the exact collapse that makes an instrument failure
  # indistinguishable from an exhausted pool. Refusing the call is what keeps
  # the distinction from decaying back into one name the next time a stop site
  # is added: a new caller cannot compile-by-habit into the wrong terminal.
  case "$observation" in
    observed-bad) state=$FM_ATTEMPT_TERMINAL_STATE ;;
    could-not-observe) state=$FM_ATTEMPT_UNOBSERVABLE_STATE ;;
    '') die "stop-defer needs --observation observed-bad|could-not-observe: a bound that was reached and a bound that could not be observed are different terminal states and this file will not guess which one you saw" ;;
    *) die "--observation must be observed-bad or could-not-observe, not '$observation'" ;;
  esac
  reason=$(attempt_clean_signature "$reason")
  already=$(attempt_field "$STATE/$id.attempt" terminal)
  # A stop that is already recorded keeps the state it was first recorded in.
  # The first terminal answer is the true one: letting a later stop overwrite it
  # would let a broken recorder erase a genuine exhaustion, or an exhaustion
  # mask an earlier instrument failure. Either direction loses the diagnosis.
  if [ -n "$already" ]; then
    printf 'terminal=%s\n' "$already"
    return 0
  fi
  attempt_write "$id" "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" \
    "$state" "$(attempt_failures_seen "$id")" \
    "$(attempt_field "$STATE/$id.attempt" ended)" \
    || die "could not stop the capacity deferral for $id at $STATE/$id.attempt"
  printf 'failed: waiting for capacity ended because %s (%s)\n' "$reason" "$state" \
    >> "$STATE/$id.status" 2>/dev/null \
    || die "could not declare the stopped capacity deferral for $id at $STATE/$id.status"
  printf 'terminal=%s\n' "$state"
}

cmd_retire() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "retire takes only a task id"
  rm -f -- "$STATE/$id.attempt"
}

attempt_is_count "$ATTEMPT_BUDGET_DEFAULT" && [ "$ATTEMPT_BUDGET_DEFAULT" -gt 0 ] \
  || die "FM_ATTEMPT_BUDGET_DEFAULT must be a positive integer: $ATTEMPT_BUDGET_DEFAULT"
# A misconfigured environment must never unbind a bound. Both deferral defaults
# are refused outright rather than compared, exactly as the attempt budget is.
attempt_is_count "$ATTEMPT_DEFER_BUDGET_DEFAULT" && [ "$ATTEMPT_DEFER_BUDGET_DEFAULT" -gt 0 ] \
  || die "FM_ATTEMPT_DEFER_BUDGET_DEFAULT must be a positive integer: $ATTEMPT_DEFER_BUDGET_DEFAULT"
attempt_is_count "$ATTEMPT_DEFER_STAGNATION_DEFAULT" && [ "$ATTEMPT_DEFER_STAGNATION_DEFAULT" -gt 0 ] \
  || die "FM_ATTEMPT_DEFER_STAGNATION_DEFAULT must be a positive integer: $ATTEMPT_DEFER_STAGNATION_DEFAULT"

[ "$#" -ge 1 ] || { usage; exit 2; }
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  show) cmd_show "$@" ;;
  end) cmd_end "$@" ;;
  check) cmd_check "$@" ;;
  open) cmd_open "$@" ;;
  defer) cmd_defer "$@" ;;
  stop-defer) cmd_stop_defer "$@" ;;
  retire) cmd_retire "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (show check open defer stop-defer end retire)" ;;
esac
