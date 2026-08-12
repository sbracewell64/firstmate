#!/usr/bin/env bash
set -u

ROOT=${FM_REVIEW_RECURRENCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
EVIDENCE=${1:-$ROOT/docs/verification/review-control-recurrence-evidence.json}
[ -f "$EVIDENCE" ] || { echo "COULD_NOT_OBSERVE: recurrence evidence is absent" >&2; exit 2; }
jq -e 'length == 49 and all(.[]; .assertion_execution_observed == true)' "$EVIDENCE" >/dev/null \
  || { echo "COULD_NOT_OBSERVE: recurrence evidence is incomplete" >&2; exit 2; }
while IFS=$'\t' read -r commit protection; do
  file=${protection%%:*}
  git -C "$ROOT" cat-file -e "$commit^{commit}" 2>/dev/null \
    || { echo "COULD_NOT_OBSERVE: evidence candidate is unavailable" >&2; exit 2; }
  [ -z "$(git -C "$ROOT" diff --name-only "$commit"..HEAD -- "$file")" ] \
    || { echo "COULD_NOT_OBSERVE: protected file changed after evidence was measured: $file" >&2; exit 2; }
done < <(jq -r '.[] | [.candidate_commit,.protection] | @tsv' "$EVIDENCE")
echo CURRENT
