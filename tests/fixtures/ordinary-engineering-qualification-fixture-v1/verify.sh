#!/usr/bin/env bash
# verify.sh <case-id> <state-dir> - grade one candidate submission.
#
# Prints EXACTLY ONE value from the register's five-value vocabulary and nothing
# else, because qualifications/schema.json refuses a synonym rather than reading
# one charitably: the measured failure that vocabulary exists for was a candidate
# emitting "pass" and an evaluator being tempted to accept it.
#
#   QUALIFIED             the submission satisfies every declared predicate
#   FAILED                the predicate ran and the submission did not satisfy it
#   COULD_NOT_OBSERVE     no submission, an unreadable one, or a missing case
#
# FAILED and COULD_NOT_OBSERVE are deliberately NOT interchangeable. The first is
# evidence against the binding and is preserved as an exclusion; the second is no
# evidence at all and never records a negative. A grader that reported a missing
# submission as FAILED would manufacture exclusion evidence out of its own
# inability to look, which is exactly the conversion the register forbids.
#
# The grading key lives in cases.json, which setup.sh never copies into the
# disposable state - so the candidate is graded on the job rather than on having
# read its own answer key.
set -u

PKG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CASE=${1:-}
STATE=${2:-}

cno() { printf 'COULD_NOT_OBSERVE\n'; exit 0; }

[ -n "$CASE" ] && [ -n "$STATE" ] || cno
command -v jq >/dev/null 2>&1 || cno
[ -f "$PKG/cases.json" ] || cno

# An unknown case id is could-not-observe rather than a failure: nothing about
# the binding was measured.
jq -e --arg c "$CASE" '.cases[$c] != null' "$PKG/cases.json" >/dev/null 2>&1 || cno

SUB="$STATE/submission.json"
[ -f "$SUB" ] || cno
jq -e . "$SUB" >/dev/null 2>&1 || cno

# One jq program decides the whole verdict, so no shell branch can reach a
# different answer than the predicates declare.
RESULT=$(jq -r -n \
  --slurpfile cases "$PKG/cases.json" \
  --slurpfile sub "$SUB" \
  --arg c "$CASE" '
  ($cases[0].cases[$c]) as $k
  | ($sub[0]) as $s
  | if ($s | type) != "object" then "FAILED"
    else
      # Every text value in the submission, lower-cased, as one haystack. Nested
      # objects and arrays are walked so a candidate that answers in a structure
      # is not penalised for the shape of its answer.
      ([ $s | .. | strings ] | join(" ") | ascii_downcase) as $text
      | ([ ($k.requires // [])[]
           | select((($s[.]? // "") | tostring | length) == 0) ]) as $missing
      | ([ ($k.must_state // [])[]
           | select(($text | contains(ascii_downcase)) | not) ]) as $unstated
      | ([ ($k.must_not_state // [])[]
           | select($text | contains(ascii_downcase)) ]) as $forbidden
      | ([ ($k.equals // {}) | to_entries[]
           | select((($s[.key]? // "") | tostring) != (.value | tostring)) ]) as $wrong
      | if (($missing | length) + ($unstated | length)
            + ($forbidden | length) + ($wrong | length)) == 0
        then "QUALIFIED" else "FAILED" end
    end' 2>/dev/null)

case "$RESULT" in
  QUALIFIED|FAILED) printf '%s\n' "$RESULT" ;;
  *) cno ;;
esac
