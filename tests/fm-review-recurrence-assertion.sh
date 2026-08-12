#!/usr/bin/env bash
set -u

[ "$#" -eq 3 ] || exit 2
case_name=$1
suite=$2
failure=$3
out=$(bash "$suite" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -Fqx "ok - $case_name"; then
  printf 'FM_RECURRENCE_ASSERTION_EXECUTED id=%s result=PASS\n' "$case_name"
  exit 0
fi
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fqx "not ok - $case_name: $failure"; then
  printf 'FM_RECURRENCE_ASSERTION_EXECUTED id=%s result=FAIL failure=%s\n' "$case_name" "$failure"
  exit 1
fi
printf '%s\n' "$out" >&2
exit 2
