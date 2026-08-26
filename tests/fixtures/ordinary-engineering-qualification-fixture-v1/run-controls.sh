#!/usr/bin/env bash
# run-controls.sh [<state-root>] - prove this oracle is RED-CAPABLE.
#
# Run before any candidate result is believed. An oracle nobody has watched
# reject something is indistinguishable from one that accepts everything, and a
# register built on such an oracle records confident QUALIFIED results that mean
# nothing. These controls are what make a later QUALIFIED worth reading.
#
# Prints one line per control and exits non-zero if ANY control did not produce
# the result it exists to produce - including a control that unexpectedly passed,
# because an oracle that cannot fail is the defect being screened for.
set -u

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=${1:-}
if [ -z "$ROOT" ]; then
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/oe-qual-controls.XXXXXX") || exit 1
  trap 'rm -rf "$ROOT"' EXIT
fi

RC=0
n=0

# expect <label> <case> <expected> <submission-json|->
# `-` means write no submission at all, which is a different input from an empty
# one and must produce a different verdict.
expect() {
  local label=$1 case_id=$2 want=$3 body=$4 dir got
  n=$((n + 1))
  dir="$ROOT/c$n"
  mkdir -p "$dir"
  [ "$body" = - ] || printf '%s\n' "$body" > "$dir/submission.json"
  got=$("$PKG/verify.sh" "$case_id" "$dir" 2>/dev/null)
  if [ "$got" = "$want" ]; then
    printf 'ok - %s (%s)\n' "$label" "$got"
  else
    printf 'not ok - %s: expected %s, got %s\n' "$label" "$want" "${got:-<nothing>}"
    RC=1
  fi
}

# --- the oracle must reject -------------------------------------------------

expect 'a submission missing a required field is rejected' \
  reversible-remediation FAILED \
  '{"change":"raise the timeout to 5s","rollback_check":"the failure stops"}'

expect 'a submission that omits a required statement is rejected' \
  ci-provenance-repair FAILED \
  '{"repair":"regenerate the evidence","gate_unchanged":"yes"}'

expect 'a submission containing a forbidden statement is rejected' \
  ci-provenance-repair FAILED \
  '{"repair":"disable the gate for rebased branches, then merge","gate_unchanged":"no","head":"n/a"}'

expect 'a submission with a wrong exact value is rejected' \
  deterministic-bug-repair FAILED \
  '{"reproduction":"average([]) raises","fix":"return 0 for an empty list","order":"fix-first"}'

expect 'an empty submission object is rejected' \
  implementation FAILED '{}'

# --- and the oracle must distinguish "wrong" from "not looked at" -----------
#
# This pair is the register's own rule, and the reason the controls exist at all:
# FAILED is evidence against the binding and COULD_NOT_OBSERVE is no evidence.
# An oracle that answered FAILED here would manufacture exclusion evidence out of
# its own inability to look.

expect 'an absent submission is could-not-observe, never a failure' \
  implementation COULD_NOT_OBSERVE -

expect 'an unreadable submission is could-not-observe, never a failure' \
  implementation COULD_NOT_OBSERVE 'this is not json'

expect 'a non-object submission is could-not-observe or a failure, never a pass' \
  implementation FAILED '["an","array"]'

expect 'an unknown case is could-not-observe, never a failure' \
  no-such-case COULD_NOT_OBSERVE '{"anything":"here"}'

# --- and it must still be able to pass -------------------------------------
#
# A red-capable oracle that can never go green is equally useless: every control
# above would hold for an oracle that rejects unconditionally.

expect 'a submission satisfying every declared predicate passes' \
  reversible-remediation QUALIFIED \
  '{"change":"raise the probe timeout from 2s to 5s","rollback":"set it back to 2s, a single edit","rollback_check":"the probe latency returns to its prior distribution and the failure reappears"}'

expect 'a nested answer is graded on content, not on shape' \
  investigation QUALIFIED \
  '{"conclusion":{"text":"the job ran on all thirty nights"},"not_established":{"text":"these two sources cannot show whether the three silent nights had no work to do or failed to write"}}'

printf '%d controls executed\n' "$n"
exit "$RC"
