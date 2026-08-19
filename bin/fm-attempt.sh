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
# TWO NOUNS, ONE LINEAGE: THE WORK ATTEMPT AND THE EXECUTION ATTEMPT.
# Everything above counts ATTEMPTS AT THE WORK - "may this task be tried
# again?". A second question shares the word and is not that question: which
# WORKER INCARNATION is currently executing this lane. They separate the moment
# a lane's provider window closes mid-flight: the work did not fail, the runtime
# did not die, and nothing may be retried - but the binding that was executing
# it can no longer execute anything. Under the count above that relaunch is a
# CONTINUATION, so a successor on a different model would inherit the identity
# of the attempt that produced the earlier evidence.
#
# So the record also carries an EXECUTION lineage, and the two never move
# together:
#
#   execution=<k>            the execution attempt now open, monotonic for the
#                            life of the task id and never reused.
#   execution_id=<id>/e<k>   the stamp evidence is attributed to.
#   execution_binding=<h>/<m>  the harness/model binding it runs on.
#   execution_effort=<band>  its recorded effort band, empty when unstated.
#   execution_dispatch=<launching|active|sanctioned|ended>  where this execution
#                            stands. `launching` was minted by an ordinary spawn
#                            whose launch has not been confirmed; `active` has a
#                            confirmed launch; `sanctioned` was minted by
#                            `replace` and is waiting for its successor dispatch;
#                            `ended` was closed by `end` because the work attempt
#                            it ran under ended without landing. `end` closes the
#                            open execution before it records the ended flag, so
#                            ended=1 and an executing dispatch state are mutually
#                            exclusive by construction, not by convention.
#   execution_head=<sha>     the branch head observed when it was minted.
#
# A REPLACEMENT MOVES THE EXECUTION AND LEAVES THE WORK ALONE. `replace` mints
# a successor execution in the SAME lane - same task id, same slot, same
# worktree, same branch and head, same attempt number - and spends no attempt,
# because a provider that ran out of window did not fail the work. That is the
# whole point of keeping both numbers in one record: a reader cannot see one
# without the other, and neither can be advanced by touching the other.
#
# THE SUCCESSOR IS NEVER THE SAME WORKER. `execution_id` changes, so evidence
# produced after the replacement is attributed to the successor and evidence
# produced before it stays attributed to the predecessor. state/<id>.lineage is
# the append-only ledger that makes that structural rather than conventional: a
# closed execution's line is never rewritten, because nothing here rewrites the
# ledger at all. An unchanged worktree is not an unchanged producer - the same
# law that governs head-bound evidence across a rebase.
#
# WHAT `open` MAY NOT DO, AND THE ONE CASE WHERE IT MAY. A relaunch that keeps
# the SAME binding continues the execution already open, exactly as it continues
# the attempt. A relaunch that CHANGES it is refused and pointed at `replace`,
# so a lane cannot be rebound by passing a different --binding to an ordinary
# spawn. That refusal is what makes `replace` the only door.
#
# The exception is an execution still in `launching`: its metadata was published
# and its launch never completed, so it PRODUCED NOTHING and there is no producer
# to preserve. Re-recording that ordinal onto another binding is what lets the
# capacity owner's in-pool substitution work at all - a dispatch that failed to
# launch on one model and is retried on the next never had two producers, it had
# none. An execution that reached `active` is the opposite case and is refused.
#
# An ENDED work attempt is the other admission. Its execution is closed and
# nothing is executing, so the re-dispatch a forced discard deliberately leaves
# possible is a genuine retry, not a rebind: it opens a FRESH ordinal on
# whatever binding it declares, never a continuation of the discarded run, so
# the discarded evidence keeps its own producer and the retry gets its own.
#
# THE RESIDUE, STATED RATHER THAN CLOSED. `active` is recorded after the launch
# is confirmed, by a separate call. If that call fails - the state directory
# became unwritable between publishing metadata and confirming the launch - a
# LIVE execution is left recorded as `launching`, and a later relaunch could
# then rebind it without passing through `replace`. The failure is loud and
# names the reconciliation, and it cannot happen silently, because `open` itself
# refuses to launch when it cannot write that record at all. Closing it properly
# needs the launch confirmation and the metadata publication to be one atomic
# write, which they are not.
#
# EVERY REPLACEMENT CONDITION IS THREE-VALUED, AND EVERY ONE COMES FROM ITS
# EXISTING OWNER. This file evaluates no capacity, no route, no qualification
# and no liveness of its own; it asks the owner that already answers, and a
# condition that owner could not establish REFUSES rather than defaulting to
# permitted:
#
#   worktree custody and process quiescence  bin/fm-worktree-guard.sh owner-state
#   agent quiescence at the endpoint         fm_backend_agent_state (bin/fm-backend.sh)
#   an operation still in flight             bin/fm-crew-state.sh
#   route, floor, availability, registry,
#     role qualification and capacity        bin/fm-route.sh eligible
#   assignment independence from the maker   bin/fm-qualification.sh reviewer
#
# A provider that refused for quota proves that ATTEMPT cannot continue. It
# proves nothing about any other process, lane or slot, so nothing here kills,
# reclaims, resets or releases anything - it refuses instead.
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
#   fm-attempt.sh execution <id>
#       Print "execution=<k> execution_id=<id> execution_binding=<b> \
#       execution_dispatch=<state>" for the execution attempt now open. A task
#       with no execution lineage prints execution=0 and empty fields, which is
#       could-not-observe about its producer and never a claim that one ran.
#   fm-attempt.sh lineage <id>
#       Print the append-only execution ledger, oldest first. Nothing rewrites
#       it, so a closed execution's attribution is preserved by construction.
#   fm-attempt.sh replace <id> --alternate <model> --reason <text>
#                              [--alternate-harness <h>] [--alternate-effort <e>]
#                              [--maker <model>] [--check]
#       Decide whether this lane's execution attempt may be replaced by a
#       successor on <model>, and - unless --check - MINT that successor. Every
#       safety condition above must be observed good. --check decides and
#       commits nothing. --maker names the binding that MADE the work this lane
#       reviews, when the lane is a reviewing assignment; a route whose floor
#       requires an adjudicated contract and no known maker cannot establish
#       assignment independence and is refused.
#       --alternate-harness and --alternate-effort default to the lane's own
#       recorded harness and effort, because a replacement states what MOVES;
#       inheriting an axis is never admitting it, and the route is re-checked
#       against the whole resulting binding either way.
#   fm-attempt.sh dispatched <id> --execution <execution-id>
#       Record that a spawn CONFIRMED the launch of that exact execution, moving
#       it to active. bin/fm-spawn.sh's hook; refuses any id but
#       the one execution the record currently holds open, so a crash between
#       the mint and the launch can only ever leave ONE execution to recover.
#   `check` and `open` additionally take --binding <harness>/<model>, --effort
#       <band>, and --succeeding. The binding is what makes an unsanctioned
#       rebind refusable at the chokepoint; --succeeding declares that this
#       launch IS the sanctioned successor dispatch, which is the only thing
#       allowed past a record that holds one.
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
# `replace`'s answers, which are the same four bin/fm-route.sh already uses plus
# one, so a caller that reads nothing but the status still stops safely:
#   0  sanctioned
#   1  REFUSED     - a safety condition was observed BAD
#   2  usage error, or a policy surface that could not be read at all
#   3  HELD        - no eligible alternate exists. 3 means here exactly what it
#                    means for an exhausted budget above: the work stays where
#                    it is. It is never a reason to lower a floor.
#   4  COULD_NOT_OBSERVE - a required condition could not be established. It is
#                    a real result, and it refuses.
ATTEMPT_REPLACE_REFUSED_EXIT=1
ATTEMPT_REPLACE_HELD_EXIT=3
ATTEMPT_REPLACE_UNOBSERVED_EXIT=4
# The schema tag of one line of state/<id>.lineage.
FM_ATTEMPT_LINEAGE_SCHEMA=fm-execution-lineage.v1
# Set to 1 only by the one path that mints or advances an execution; every other
# writer preserves the lineage it finds. Defaulted here so `set -u` cannot make
# an ordinary write depend on whether a replacement ran first in this process.
ATTEMPT_EXEC_SET=0

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
  local exec_n exec_id exec_binding exec_effort exec_dispatch exec_head
  rec="$STATE/$id.attempt"
  if [ "$#" -ge 10 ]; then
    deferrals=$7 defer_budget=$8 signature=$9 stagnant=${10}
  else
    deferrals=$(attempt_field "$rec" deferrals)
    defer_budget=$(attempt_field "$rec" deferral_budget)
    signature=$(attempt_field "$rec" defer_signature)
    stagnant=$(attempt_field "$rec" defer_stagnant)
  fi
  # The execution lineage is PRESERVED by every writer and set by exactly one.
  # Only the paths that mint or advance an execution set ATTEMPT_EXEC_SET, so a
  # check, an open, an end, a deferral and a terminal declaration all rewrite
  # this record without being able to move a producer identity. That asymmetry
  # is the same one the deferral fields already rely on, and for the same
  # reason: a field a passing writer can silently drop is a field that will be
  # dropped.
  if [ "${ATTEMPT_EXEC_SET:-0}" = 1 ]; then
    exec_n=${ATTEMPT_EXEC_N:-} exec_id=${ATTEMPT_EXEC_ID:-}
    exec_binding=${ATTEMPT_EXEC_BINDING:-} exec_effort=${ATTEMPT_EXEC_EFFORT:-}
    exec_dispatch=${ATTEMPT_EXEC_DISPATCH:-} exec_head=${ATTEMPT_EXEC_HEAD:-}
  else
    exec_n=$(attempt_field "$rec" execution)
    exec_id=$(attempt_field "$rec" execution_id)
    exec_binding=$(attempt_field "$rec" execution_binding)
    exec_effort=$(attempt_field "$rec" execution_effort)
    exec_dispatch=$(attempt_field "$rec" execution_dispatch)
    exec_head=$(attempt_field "$rec" execution_head)
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
    [ -z "$exec_n" ] || printf 'execution=%s\n' "$exec_n"
    [ -z "$exec_id" ] || printf 'execution_id=%s\n' "$exec_id"
    [ -z "$exec_binding" ] || printf 'execution_binding=%s\n' "$exec_binding"
    [ -z "$exec_effort" ] || printf 'execution_effort=%s\n' "$exec_effort"
    [ -z "$exec_dispatch" ] || printf 'execution_dispatch=%s\n' "$exec_dispatch"
    [ -z "$exec_head" ] || printf 'execution_head=%s\n' "$exec_head"
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

parse_budget_flag() {  # <args...> -> sets PARSED_BUDGET, PARSED_BINDING, PARSED_EFFORT, PARSED_SUCCEEDING
  PARSED_BUDGET=''
  PARSED_BINDING=''
  PARSED_EFFORT=''
  PARSED_SUCCEEDING=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --binding)
        [ "$#" -ge 2 ] || die "--binding needs a value"
        PARSED_BINDING=$2
        shift 2
        ;;
      --effort)
        [ "$#" -ge 2 ] || die "--effort needs a value"
        PARSED_EFFORT=$2
        shift 2
        ;;
      --succeeding)
        PARSED_SUCCEEDING=1
        shift
        ;;
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
# ATTEMPT_FAILURES, ATTEMPT_NEXT, ATTEMPT_IS_NEW, and ATTEMPT_WAS_ENDED - the
# last captured here because `open` rewrites the record (clearing the ended
# flag) before the execution lineage looks at it.
attempt_resolve() {  # <id> <explicit-budget-or-empty>
  local id=$1 explicit=${2-}
  ATTEMPT_BUDGET_RESOLVED=$(attempt_budget "$id" "$explicit")
  ATTEMPT_PRIOR=$(attempt_prior "$id")
  ATTEMPT_FAILURES=$(attempt_failures "$id")
  ATTEMPT_WAS_ENDED=0
  ! attempt_ended "$id" || ATTEMPT_WAS_ENDED=1
  if [ "$ATTEMPT_PRIOR" -eq 0 ]; then
    # Nothing has been attempted yet, so the first launch opens attempt 1
    # whether or not anything ever failed.
    ATTEMPT_IS_NEW=1
    ATTEMPT_NEXT=1
    return 0
  fi
  if [ "$ATTEMPT_WAS_ENDED" -eq 1 ] || [ "$ATTEMPT_FAILURES" -gt "$(attempt_failures_seen "$id")" ]; then
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
  attempt_exec_guard "$id" "$PARSED_BINDING" "$PARSED_SUCCEEDING"
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
  # An ordinary launch also records WHO is executing, so a lane always has a
  # producer to attribute its evidence to and a replacement always has a
  # predecessor to preserve.
  attempt_exec_open "$id" "$PARSED_BINDING" "$PARSED_EFFORT" "$PARSED_SUCCEEDING"
  printf 'attempt=%s attempt_budget=%s\n' "$ATTEMPT_NEXT" "$ATTEMPT_BUDGET_RESOLVED"
}

cmd_end() {
  local id=${1-} prior budget have state
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "end takes only a task id"
  # Only a task that has an open attempt can end one. Recording an end for a
  # task nobody attempted would invent a retry out of nothing.
  prior=$(attempt_prior "$id")
  [ "$prior" -gt 0 ] || return 0
  budget=$(attempt_budget "$id" '')
  # The end CLOSES the open execution BEFORE it records the ended flag, in that
  # order, so no durable record ever carries ended=1 with an execution still
  # recorded as executing - a contradiction every reader would otherwise have
  # to know to disbelieve.
  have=$(attempt_exec_n "$id")
  state=$(attempt_field "$STATE/$id.attempt" execution_dispatch)
  if [ "$have" -gt 0 ] && [ "$state" != ended ]; then
    attempt_exec_commit "$id" "$have" \
      "$(attempt_field "$STATE/$id.attempt" execution_binding)" \
      "$(attempt_field "$STATE/$id.attempt" execution_effort)" \
      ended \
      "$(attempt_field "$STATE/$id.attempt" execution_head)" \
      || die "could not close execution $id/e$have at $STATE/$id.attempt"
    attempt_lineage_append "$id" "event=closed" "execution=$id/e$have" \
      "ts=$(date +%s)" "disposition=discarded" \
      || die "could not record the close of $id/e$have at $STATE/$id.lineage"
  fi
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

# --- the execution lineage -------------------------------------------------

# The task's current execution ordinal. Absent reads 0, which is
# could-not-observe about the producer and never a claim that one ran.
attempt_exec_n() {  # <id> -> ordinal on stdout
  local n
  n=$(attempt_field "$STATE/$1.attempt" execution)
  attempt_is_count "$n" || n=0
  printf '%s' "$n"
}

# One line of the append-only ledger. Nothing in this file ever rewrites or
# truncates it, so a closed execution's attribution survives by construction
# rather than by anyone remembering to preserve it. A ledger that cannot be
# appended is a refusal at every call site: an execution whose producer was
# never recorded cannot later be told apart from one whose producer was.
attempt_lineage_append() {  # <id> <field>...
  local id=$1 line
  shift
  line="$FM_ATTEMPT_LINEAGE_SCHEMA"
  while [ "$#" -gt 0 ]; do
    line="$line $(attempt_clean_signature "$1")"
    shift
  done
  [ -d "$STATE" ] || mkdir -p "$STATE" 2>/dev/null || return 1
  printf '%s\n' "$line" >> "$STATE/$id.lineage" 2>/dev/null
}

# Commit one execution onto the record. The ONLY writer of the lineage fields;
# every other path preserves what it finds (see attempt_write).
attempt_exec_commit() {  # <id> <ordinal> <binding> <effort> <dispatch> <head>
  local id=$1
  ATTEMPT_EXEC_SET=1
  ATTEMPT_EXEC_N=$2
  ATTEMPT_EXEC_ID="$id/e$2"
  ATTEMPT_EXEC_BINDING=$3
  ATTEMPT_EXEC_EFFORT=$4
  ATTEMPT_EXEC_DISPATCH=$5
  ATTEMPT_EXEC_HEAD=$6
  attempt_write "$id" "$(attempt_prior "$id")" "$(attempt_budget "$id" '')" \
    "$(attempt_field "$STATE/$id.attempt" terminal)" \
    "$(attempt_failures_seen "$id")" \
    "$(attempt_field "$STATE/$id.attempt" ended)"
  local rc=$?
  ATTEMPT_EXEC_SET=0
  return "$rc"
}

# The refusal that makes `replace` the only door. An ordinary relaunch declaring
# a DIFFERENT binding is refused before anything is created, so a lane cannot be
# rebound by editing a spawn command line: the successor identity, the
# quiescence proof and the admissibility of the alternate all live behind the
# one verb that mints a successor.
attempt_exec_guard() {  # <id> <binding-or-empty> <succeeding-0-or-1>
  local id=$1 binding=${2-} succeeding=${3-0} recorded state
  state=$(attempt_field "$STATE/$id.attempt" execution_dispatch)
  # An ENDED work attempt has nothing executing: its execution is closed (or,
  # on a record written before `end` closed them, the ended flag says the run
  # is over), its evidence is already attributed, and the re-dispatch a forced
  # discard deliberately admits is a genuine retry, not a rebind.
  # attempt_exec_open mints that retry a fresh execution.
  if [ "$state" = ended ] || [ "${ATTEMPT_WAS_ENDED:-0}" = 1 ] || attempt_ended "$id"; then
    return 0
  fi
  # A record written before this vocabulary existed names no state; read it as
  # the strict one, because the permissive readings are the ones that let a lane
  # be rebound without a gate.
  [ -n "$state" ] || [ "$(attempt_exec_n "$id")" -eq 0 ] || state=active
  if [ "$state" = sanctioned ] && [ "$succeeding" != 1 ]; then
    printf 'error: %s already has a sanctioned successor execution (%s on %s) waiting to be launched. Launch it with bin/fm-spawn.sh --succeed-execution, which keeps this lane its slot and worktree; an ordinary dispatch would take a second slot for work that already holds one.\n' \
      "$id" "$(attempt_field "$STATE/$id.attempt" execution_id)" \
      "$(attempt_field "$STATE/$id.attempt" execution_binding)" >&2
    exit "$ATTEMPT_REPLACE_REFUSED_EXIT"
  fi
  [ -n "$binding" ] || return 0
  recorded=$(attempt_field "$STATE/$id.attempt" execution_binding)
  [ -n "$recorded" ] || return 0
  [ "$binding" != "$recorded" ] || return 0
  # A launch that never completed produced nothing, so there is no producer to
  # preserve and the ordinal may simply be re-recorded onto the new binding.
  [ "$state" != launching ] || return 0
  printf 'error: %s is executing on %s and this launch declares %s. A lane is not rebound by relaunching it: run bin/fm-attempt.sh replace %s --alternate <model> --reason <text>, which checks that the execution now open is quiescent, that the alternate is admissible, and mints a successor identity so the earlier evidence keeps its own producer.\n' \
    "$id" "$recorded" "$binding" "$id" >&2
  exit "$ATTEMPT_REPLACE_REFUSED_EXIT"
}

# Mint execution 1 for a task that has none, and refuse a binding change that
# did not go through `replace`. Called from `open`, so an ordinary spawn records
# its producer without a second command, and an ordinary spawn cannot rebind a
# lane by passing a different --binding.
attempt_exec_open() {  # <id> <binding-or-empty> <effort-or-empty> <succeeding>
  local id=$1 binding=${2-} effort=${3-} succeeding=${4-0} have recorded state next
  have=$(attempt_exec_n "$id")
  recorded=$(attempt_field "$STATE/$id.attempt" execution_binding)
  state=$(attempt_field "$STATE/$id.attempt" execution_dispatch)
  if [ "$have" -eq 0 ]; then
    attempt_exec_commit "$id" 1 "$binding" "$effort" launching '' \
      || die "could not record execution 1 for $id at $STATE/$id.attempt"
    attempt_lineage_append "$id" "event=opened" "execution=$id/e1" "ordinal=1" \
      "attempt=$(attempt_prior "$id")" "binding=${binding:-unknown}" \
      "effort=${effort:-unstated}" "ts=$(date +%s)" \
      || die "could not record the producer of execution 1 for $id at $STATE/$id.lineage"
    return 0
  fi
  # A retry after the work attempt ended is a NEW incarnation: a fresh ordinal
  # on the declared binding, with its own opened line, never a continuation of
  # the execution whose run was discarded - whatever binding it declares.
  if [ "$state" = ended ] || [ "${ATTEMPT_WAS_ENDED:-0}" = 1 ] || attempt_ended "$id"; then
    next=$((have + 1))
    attempt_exec_commit "$id" "$next" "$binding" "$effort" launching '' \
      || die "could not record execution $next for $id at $STATE/$id.attempt"
    attempt_lineage_append "$id" "event=opened" "execution=$id/e$next" "ordinal=$next" \
      "attempt=$(attempt_prior "$id")" "binding=${binding:-unknown}" \
      "effort=${effort:-unstated}" "ts=$(date +%s)" "predecessor=$id/e$have" \
      "reason=retry after the prior work attempt ended" \
      || die "could not record the producer of execution $next for $id at $STATE/$id.lineage"
    return 0
  fi
  attempt_exec_guard "$id" "$binding" "$succeeding"
  # A sanctioned successor is left exactly as the gate minted it; its dispatch is
  # confirmed separately, so nothing here may quietly declare it running.
  [ "$state" != sanctioned ] || return 0
  # Otherwise: adopt this launch's binding onto the open ordinal. That is a
  # no-op for a continuation on the same binding, fills in a producer a record
  # predating this never had, and re-points an execution whose launch never
  # completed - the three cases the guard above has already separated from a
  # rebind it must refuse.
  if [ -n "$binding" ] && [ "$binding" != "$recorded" ]; then
    attempt_exec_commit "$id" "$have" "$binding" "$effort" launching \
      "$(attempt_field "$STATE/$id.attempt" execution_head)" \
      || die "could not record the producer of execution $have for $id"
    attempt_lineage_append "$id" "event=relaunched" "execution=$id/e$have" \
      "ordinal=$have" "binding=$binding" "effort=${effort:-unstated}" \
      "ts=$(date +%s)" "previous_binding=${recorded:-unknown}" \
      "reason=the prior launch of this execution was never confirmed" \
      || die "could not record the re-pointed producer of execution $have for $id"
  fi
}

cmd_execution() {
  local id=${1-} n
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "execution takes only a task id"
  n=$(attempt_exec_n "$id")
  printf 'execution=%s execution_id=%s execution_binding=%s execution_effort=%s execution_dispatch=%s execution_head=%s\n' \
    "$n" \
    "$(attempt_field "$STATE/$id.attempt" execution_id)" \
    "$(attempt_field "$STATE/$id.attempt" execution_binding)" \
    "$(attempt_field "$STATE/$id.attempt" execution_effort)" \
    "$(attempt_field "$STATE/$id.attempt" execution_dispatch)" \
    "$(attempt_field "$STATE/$id.attempt" execution_head)"
}

cmd_lineage() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "lineage takes only a task id"
  [ -f "$STATE/$id.lineage" ] || return 0
  cat -- "$STATE/$id.lineage"
}

# --- the replacement gate --------------------------------------------------

# Every refusal prints WHY and WHICH of the three values it reached, because a
# caller acting on the exit status alone still has to be able to tell a lane
# that is unsafe to replace from one whose safety could not be established.
replace_refuse() {  # <text>
  printf 'error: REFUSED - %s\n' "$1" >&2
  exit "$ATTEMPT_REPLACE_REFUSED_EXIT"
}

replace_unobserved() {  # <text>
  printf 'error: COULD_NOT_OBSERVE - %s\n' "$1" >&2
  exit "$ATTEMPT_REPLACE_UNOBSERVED_EXIT"
}

replace_held() {  # <text>
  printf 'error: HELD - %s\n' "$1" >&2
  exit "$ATTEMPT_REPLACE_HELD_EXIT"
}

# The process table has to be READABLE before its silence means anything. Every
# occupancy verdict downstream is drawn from the absence of matching entries,
# and absence read out of a table that could not be listed is exactly the
# could-not-observe this refuses. A root holding no numeric entry at all is not
# a machine with no processes; it is a root that was not read.
replace_proc_readable() {
  local root=${FM_PROC_ROOT_OVERRIDE:-/proc} dir
  [ -d "$root" ] || return 1
  for dir in "$root"/[0-9]*; do
    [ -d "$dir" ] && return 0
  done
  return 1
}

# The lane's worktree custody AND whether anything still lives in it, from the
# one owner that already answers both. Its four words map onto exactly the three
# values this gate needs, and none of them is narrowed:
#   dead        the recorded owner identity no longer matches and no live
#               evidence remains - quiescent, and nothing owns an effect.
#   alive       something is still running in this lane's slot.
#   unresolved  the slot is claimed but no owner identity was ever recorded, so
#               who owns it cannot be established.
#   unclaimed   no metadata claims the slot at all, so custody is unknown.
replace_custody_gate() {  # <id> <worktree>
  local id=$1 wt=$2 line state owner
  replace_proc_readable \
    || replace_unobserved "the process table at ${FM_PROC_ROOT_OVERRIDE:-/proc} could not be listed, so nothing can be concluded from finding no process in $wt"
  line=$("$FM_ROOT/bin/fm-worktree-guard.sh" owner-state "$wt" 2>/dev/null) \
    || replace_unobserved "bin/fm-worktree-guard.sh could not report who owns $wt"
  state=${line%%$'\t'*}
  owner=${line#*$'\t'}
  owner=${owner%%$'\t'*}
  # WHO owns it is settled before WHAT state it is in, because they are different
  # questions with different answers. A slot another lane holds is a refusal
  # whatever its process state: a provider refusing THIS lane for quota is
  # evidence about this lane's binding and about nothing else, and it authorizes
  # reclaiming no other lane's work.
  [ "$state" != unclaimed ] \
    || replace_unobserved "no task record claims $wt, so this lane's worktree custody is not established and a successor cannot be told it inherits it"
  [ "$owner" = "$id" ] \
    || replace_refuse "$wt is held by $owner, not $id. A provider refusing $id for quota says nothing about $owner's work, and no lane is ever reclaimed from another"
  [ "$state" != unresolved ] \
    || replace_unobserved "$wt is claimed by $owner but no owner process identity was ever recorded for it, so whether anything still owns an effect there cannot be established"
  [ "$state" != alive ] \
    || replace_refuse "$id's execution attempt is not quiescent: ${line##*$'\t'}. Replacement resumes only once the process holding this lane is gone"
  [ "$state" = dead ] \
    || replace_unobserved "bin/fm-worktree-guard.sh reported $wt as '$state', which this gate has no rule for"
}

# The endpoint's own agent, which the worktree cannot answer for: a backend that
# runs the agent off this host leaves no occupant behind at all. Only `dead` and
# `missing` license recovery in that owner's contract, and this gate does not
# widen it.
replace_agent_gate() {  # <id> <backend> <target>
  local id=$1 backend=$2 target=$3 verdict
  [ -n "$target" ] \
    || replace_unobserved "$id's metadata records no endpoint, so whether its worker is still running cannot be established"
  # shellcheck source=bin/fm-backend.sh disable=SC1091
  . "$FM_ROOT/bin/fm-backend.sh"
  verdict=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || verdict=unreadable
  case "$verdict" in
    dead|missing) return 0 ;;
    alive) replace_refuse "a worker is still running at $id's endpoint ($backend $target). Replacement resumes once it is gone" ;;
    *) replace_unobserved "$id's endpoint ($backend $target) reported '$verdict', so whether a worker is still running there could not be established" ;;
  esac
}

# An operation already in flight is not this gate's to interrupt. An ACTIVE
# validation run owns the lane's branch whether or not a worker is at the
# endpoint - the pipeline executes in its own daemon - so replacing the worker
# under it duplicates ownership of a push, a pull request, or a merge. Read
# through the one owner of a crew's current state; its own words are used, and
# no step name is enumerated here, because a vocabulary this file restated would
# drift the moment that owner added a step.
replace_inflight_gate() {  # <id>
  local id=$1 json state bin
  bin=${FM_CREW_STATE_BIN:-$FM_ROOT/bin/fm-crew-state.sh}
  json=$("$bin" "$id" --json 2>/dev/null) \
    || replace_unobserved "bin/fm-crew-state.sh could not report what $id is currently doing, so whether an operation is in flight is unestablished"
  state=$(printf '%s' "$json" | LC_ALL=C sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  case "$state" in
    working|parked)
      replace_refuse "$id has a validation run in flight (state $state). It owns this lane's branch, and a push, pull request or merge it is midway through cannot be made not to have happened by replacing the worker" ;;
    '')
      replace_unobserved "bin/fm-crew-state.sh reported no state for $id, so whether an operation is in flight is unestablished" ;;
    stale|unknown)
      replace_unobserved "bin/fm-crew-state.sh reported $id as '$state', which is precisely the absence of usable evidence about what is in flight" ;;
  esac
}

# What the successor inherits, observed rather than assumed. The worktree is
# retained across the replacement, so its content is durable by construction;
# what has to be established is that the lane's HEAD can be READ, because that
# head is what the successor's own evidence will later be bound to.
replace_head_of() {  # <worktree> -> sha on stdout, nonzero when unreadable
  git --no-optional-locks -C "$1" rev-parse HEAD 2>/dev/null
}

# Whether this home routes at all. An ABSENT dispatch config is a home with no
# routed pool, which the routing owner is silent about by design; an config that
# EXISTS and cannot be read is could-not-observe, and the two must never collapse
# into each other.
replace_route_configured() {
  [ -f "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/crew-dispatch.json" ]
}

# The alternate binding, judged by the owners that already compose floor, pool
# order, availability, cost and routability, role qualification and current
# provider capacity - each with its own ruled disposition, including capacity's
# deliberate asymmetry, which is not re-decided here. The decision record it
# returns is KEPT, because the independence gate below needs the same route's
# declared capability contracts and reading them a second time could read a
# different file.
REPLACE_DECISION=
replace_alternate_gate() {  # <id> <route> <alternate>
  local id=$1 route=$2 alternate=$3 bin json rc eligible why
  bin=${FM_ROUTE_BIN:-$FM_ROOT/bin/fm-route.sh}
  if ! replace_route_configured; then
    printf 'note: this home configures no routed pool, so route eligibility is unconfigured for %s and the alternate carries only the model registry behind it\n' "$alternate" >&2
    return 0
  fi
  [ -n "$route" ] \
    || replace_unobserved "this home routes dispatches but $id's metadata records no route, so whether $alternate may run this lane cannot be established"
  rc=0
  json=$("$bin" eligible --route "$route" --json 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3)
      why=$("$bin" zero-route --route "$route" 2>&1 || true)
      replace_held "route $route has no eligible candidate, so this lane stays on the execution it has. $(printf '%s' "$why" | tr '\n' ' ')" ;;
    *)
      replace_unobserved "bin/fm-route.sh could not read route $route, so $alternate's admissibility is unestablished" ;;
  esac
  REPLACE_DECISION=$json
  eligible=$(printf '%s' "$json" | jq -r '[ .candidates[]? | select(.eligible) | .model ] | .[]' 2>/dev/null) \
    || replace_unobserved "route $route's decision record could not be parsed, so $alternate's admissibility is unestablished"
  [ -n "$eligible" ] \
    || replace_held "route $route reports no eligible candidate, so this lane stays on the execution it has"
  printf '%s\n' "$eligible" | LC_ALL=C grep -qxF -- "$alternate" \
    || replace_refuse "$alternate is not currently eligible on route $route. Eligible now: $(printf '%s' "$eligible" | tr '\n' ' '). An ineligible alternate is not made eligible by the primary being out of window"
}

# Assignment independence, which no qualification record grants and which is
# therefore decided per assignment rather than carried by the binding. A route
# whose floor requires an ADJUDICATED capability contract is a reviewing
# assignment: replacing its worker with the binding that made the work under
# review is refused BY CONTRACT, not merely unavailable, and a lane whose maker
# is unknown cannot establish the predicate at all.
#
# The declared contracts are read off the decision record the eligibility gate
# already fetched, so both terms see one read of one route.
replace_independence_gate() {  # <id> <route> <alternate> <maker>
  local id=$1 route=$2 alternate=$3 maker=$4 qbin contracts c adjudicated=0 out dir
  local -a required=()
  qbin=${FM_QUALIFICATION_BIN:-$FM_ROOT/bin/fm-qualification.sh}
  dir=${FM_QUALIFICATION_CONTRACT_DIR:-$FM_ROOT/qualifications/contracts}
  [ -n "$REPLACE_DECISION" ] || return 0
  contracts=$(printf '%s' "$REPLACE_DECISION" \
    | jq -r '(.floor_axes.requires_capabilities // []) | .[]' 2>/dev/null) \
    || replace_unobserved "route $route's declared capability contracts could not be read, so whether this assignment must be independent of its maker is unestablished"
  [ -n "$contracts" ] || return 0
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    required+=("--contract" "$c")
    [ -f "$dir/$c.json" ] \
      || replace_unobserved "capability contract $c, required by route $route, could not be read at $dir, so whether this assignment must be independent of its maker is unestablished"
    if [ "$(jq -r '.adjudication.required // false' "$dir/$c.json" 2>/dev/null)" = true ]; then
      adjudicated=1
    fi
  done <<EOF
$contracts
EOF
  [ "$adjudicated" -eq 1 ] || return 0
  [ -n "$maker" ] \
    || replace_unobserved "route $route requires an adjudicated capability contract, so this lane is a reviewing assignment, and no maker is recorded for it. An independence predicate that could not be evaluated is not a satisfied one; pass --maker <model>"
  out=$("$qbin" reviewer --maker "$maker" --reviewer "$alternate" "${required[@]}" 2>&1) \
    || replace_refuse "$alternate may not take this assignment: $(printf '%s' "$out" | tr '\n' ' ')"
}

cmd_replace() {
  local id=${1-} alternate='' harness='' effort='' maker='' reason='' check=0
  local rec meta wt backend target route binding have head lockdir next
  require_id "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --alternate) [ "$#" -ge 2 ] || die "--alternate needs a value"; alternate=$2; shift 2 ;;
      --alternate-harness) [ "$#" -ge 2 ] || die "--alternate-harness needs a value"; harness=$2; shift 2 ;;
      --alternate-effort) [ "$#" -ge 2 ] || die "--alternate-effort needs a value"; effort=$2; shift 2 ;;
      --maker) [ "$#" -ge 2 ] || die "--maker needs a value"; maker=$2; shift 2 ;;
      --reason) [ "$#" -ge 2 ] || die "--reason needs a value"; reason=$2; shift 2 ;;
      --check) check=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$alternate" ] || die "replace needs --alternate <model>"
  [ -n "$reason" ] || die "replace needs --reason <text>: a replacement nobody can read the cause of is one nobody can audit"
  case "$effort" in
    ''|low|medium|high|xhigh|max) ;;
    *) die "--alternate-effort must be one of low, medium, high, xhigh, max" ;;
  esac
  reason=$(attempt_clean_signature "$reason")

  meta="$STATE/$id.meta"
  [ -f "$meta" ] \
    || replace_unobserved "$id has no task metadata, so this lane's slot, worktree, endpoint and route are all unestablished"
  wt=$(attempt_field "$meta" worktree)
  [ -n "$wt" ] \
    || replace_unobserved "$id's metadata records no worktree, so the custody a successor would inherit is unestablished"
  [ -d "$wt" ] \
    || replace_unobserved "$id's recorded worktree $wt is not present, so the work a successor would continue cannot be observed to be there"
  backend=$(attempt_field "$meta" backend)
  [ -n "$backend" ] || backend=tmux
  target=$(attempt_field "$meta" window)
  route=$(attempt_field "$meta" route)
  # The axes the replacement does NOT change default to the lane's own recorded
  # ones, so a caller states only what actually moves. Every one of them is still
  # recomputed against the route below - inheriting a value is not admitting it.
  [ -n "$harness" ] || harness=$(attempt_field "$meta" harness)
  if [ -z "$effort" ]; then
    effort=$(attempt_field "$meta" effort)
    [ "$effort" != default ] || effort=''
    # An empty band here is an UNSTATED sanction, and the successor gate pins
    # effort exactly as it pins harness and model - a pin against nothing would
    # accept whatever the launch declared, which is the silent depth change the
    # gate exists to prevent. Choosing the band is firstmate's routing decision,
    # so it is stated here, deliberately, at replace time.
    [ -n "$effort" ] || replace_unobserved "the effort axis of $id's successor is unstated: the lane's recorded effort is '$(attempt_field "$meta" effort)' and this replace supplied no --alternate-effort, so the band the successor gate would pin cannot be established. Choosing the band is firstmate's routing decision; state it with --alternate-effort <low|medium|high|xhigh|max>"
  fi
  binding=$harness
  [ -z "$binding" ] || binding="$binding/"
  binding="$binding$alternate"

  have=$(attempt_exec_n "$id")
  [ "$have" -gt 0 ] \
    || replace_unobserved "$id has no recorded execution attempt, so there is nothing to replace and no predecessor to attribute its evidence to"

  replace_custody_gate "$id" "$wt"
  replace_agent_gate "$id" "$backend" "$target"
  replace_inflight_gate "$id"
  head=$(replace_head_of "$wt") \
    || replace_unobserved "the branch head in $wt could not be read, so what the successor would inherit - and what its own evidence would be bound to - is unestablished"
  replace_alternate_gate "$id" "$route" "$alternate"
  replace_independence_gate "$id" "$route" "$alternate" "$maker"

  if [ "$check" -eq 1 ]; then
    printf 'sanctioned successor=%s/e%s binding=%s head=%s (checked only; nothing was committed)\n' \
      "$id" "$((have + 1))" "$binding" "$head"
    return 0
  fi

  # ONE successor, whatever happens next. The mint is a single atomic rewrite of
  # the record, taken under a lock this task id alone can hold, and the record is
  # the only authority on which execution is open. A crash before it leaves the
  # predecessor open; a crash after it leaves exactly the successor, in pending,
  # for recovery to launch. There is no window in which two executions are open,
  # because there is no state in which two are recorded.
  lockdir="$STATE/$id.attempt.lock"
  fm_lock_try_acquire "$lockdir" \
    || replace_unobserved "another replacement of $id is already in progress (holding $lockdir${FM_LOCK_HELD_PID:+, pid $FM_LOCK_HELD_PID}); whether it has already minted a successor is unestablished from here"
  # shellcheck disable=SC2064
  trap "fm_lock_release '$lockdir' 2>/dev/null || true" EXIT
  have=$(attempt_exec_n "$id")
  next=$((have + 1))
  # The close is written BEFORE the successor is committed, and that ordering is
  # a chosen tradeoff: a commit that fails leaves this append-only ledger
  # carrying a close for an execution the record still holds open, and a retried
  # replace then appends a second close for the same ordinal. Committing first
  # would instead risk a crash leaving a successor whose predecessor's close was
  # never written at all. The .attempt record is the stated authority on which
  # execution is open either way, so the ledger tolerates a spurious close
  # rather than a missing one.
  attempt_lineage_append "$id" "event=closed" "execution=$id/e$have" \
    "ts=$(date +%s)" "disposition=replaced" "successor=$id/e$next" "reason=$reason" \
    || replace_unobserved "the close of $id/e$have could not be recorded at $STATE/$id.lineage, and an execution whose end was never written cannot be told apart from one still running"
  attempt_exec_commit "$id" "$next" "$binding" "$effort" sanctioned "$head" \
    || replace_unobserved "the successor could not be recorded at $STATE/$id.attempt; nothing was launched"
  attempt_lineage_append "$id" "event=opened" "execution=$id/e$next" "ordinal=$next" \
    "attempt=$(attempt_prior "$id")" "binding=$binding" "effort=${effort:-unstated}" \
    "ts=$(date +%s)" "predecessor=$id/e$have" "head=$head" "reason=$reason" \
    || replace_unobserved "the producer of $id/e$next could not be recorded at $STATE/$id.lineage"
  printf 'sanctioned execution=%s execution_id=%s/e%s execution_binding=%s predecessor=%s/e%s attempt=%s head=%s\n' \
    "$next" "$id" "$next" "$binding" "$id" "$have" "$(attempt_prior "$id")" "$head"
}

cmd_dispatched() {
  local id=${1-} want='' open_id
  require_id "$id"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --execution) [ "$#" -ge 2 ] || die "--execution needs a value"; want=$2; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [ -n "$want" ] || die "dispatched needs --execution <execution-id>"
  open_id=$(attempt_field "$STATE/$id.attempt" execution_id)
  [ -n "$open_id" ] || die "$id has no recorded execution attempt to mark dispatched"
  [ "$open_id" = "$want" ] \
    || die "$id currently holds $open_id open, not $want. Marking a stale execution dispatched would leave two executions claiming the same lane"
  attempt_exec_commit "$id" "$(attempt_exec_n "$id")" \
    "$(attempt_field "$STATE/$id.attempt" execution_binding)" \
    "$(attempt_field "$STATE/$id.attempt" execution_effort)" \
    active \
    "$(attempt_field "$STATE/$id.attempt" execution_head)" \
    || die "could not record the dispatch of $want"
  printf 'execution=%s execution_dispatch=active\n' "$open_id"
}

cmd_retire() {
  local id=${1-}
  require_id "$id"
  shift
  [ "$#" -eq 0 ] || die "retire takes only a task id"
  rm -f -- "$STATE/$id.attempt" "$STATE/$id.lineage"
  # Reap the replace lock only when one is actually present: acquiring through
  # fm_lock_try_acquire creates the lock's parent directory, and retire runs at
  # the tail of teardown flows whose state directory may itself have just been
  # removed (a remote secondmate home retires its whole home before this call),
  # so an unconditional probe would resurrect the removed home.
  if [ -e "$STATE/$id.attempt.lock" ] || [ -L "$STATE/$id.attempt.lock" ]; then
    if fm_lock_try_acquire "$STATE/$id.attempt.lock" 2>/dev/null; then
      fm_lock_release "$STATE/$id.attempt.lock" 2>/dev/null || true
    fi
  fi
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
  execution) cmd_execution "$@" ;;
  lineage) cmd_lineage "$@" ;;
  replace) cmd_replace "$@" ;;
  dispatched) cmd_dispatched "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown subcommand: $SUBCOMMAND (show check open defer stop-defer end retire execution lineage replace dispatched)" ;;
esac
