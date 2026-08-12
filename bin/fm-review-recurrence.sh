#!/usr/bin/env bash
# Execute the review-control mutation experiments in a disposable linked worktree.
# Usage: fm-review-recurrence.sh [--case <exact-case-name>]
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SPEC=$ROOT/tests/review-control-mutations.json
OUT=$ROOT/docs/verification/review-control-recurrence-evidence.json
ONLY=

if [ "${1:-}" = --case ]; then
  [ "$#" -eq 2 ] || { echo "error: --case requires one exact case name" >&2; exit 2; }
  ONLY=$2
elif [ "$#" -ne 0 ]; then
  echo "error: usage: fm-review-recurrence.sh [--case <exact-case-name>]" >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "COULD_NOT_OBSERVE: jq is unavailable" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "COULD_NOT_OBSERVE: git is unavailable" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "COULD_NOT_OBSERVE: mutation specification is absent" >&2; exit 2; }

git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) \
  || { echo "COULD_NOT_OBSERVE: not a git worktree" >&2; exit 2; }
common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "COULD_NOT_OBSERVE: git common directory is unreadable" >&2; exit 2; }
[ "$git_dir" != "$common_dir" ] \
  || { echo "COULD_NOT_OBSERVE: recurrence mutations refuse the primary checkout" >&2; exit 2; }
[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] \
  || { echo "COULD_NOT_OBSERVE: recurrence mutations require a clean worktree" >&2; exit 2; }

candidate=$(git -C "$ROOT" rev-parse HEAD) || exit 2
results=$(mktemp "$ROOT/docs/verification/.review-control-recurrence.XXXXXX") || exit 2
backup=
mutated=
original_hash=

restore_current() {
  [ -n "$mutated" ] || return 0
  cp "$backup" "$mutated" || return 1
  restored_hash=$(git hash-object "$mutated") || return 1
  [ "$restored_hash" = "$original_hash" ] || return 1
  rm -f "$backup"
  backup=
  mutated=
  original_hash=
}

cleanup() {
  if ! restore_current; then
    echo "COULD_NOT_OBSERVE: interrupted mutation could not be restored by content hash" >&2
  fi
  rm -f "$results"
}
trap cleanup EXIT
trap 'cleanup; trap - EXIT; exit 130' HUP INT TERM
printf '[]\n' > "$results"

count=$(jq 'length' "$SPEC") || exit 2
[ "$count" -eq 29 ] || { echo "COULD_NOT_OBSERVE: expected 29 mutation specifications, found $count" >&2; exit 2; }

while IFS= read -r row; do
  name=$(printf '%s' "$row" | jq -r '.case')
  [ -z "$ONLY" ] || [ "$name" = "$ONLY" ] || continue
  file=$(printf '%s' "$row" | jq -r '.file')
  location=$(printf '%s' "$row" | jq -r '.location')
  suite=$(printf '%s' "$row" | jq -r '.suite')
  assertion=$(printf '%s' "$row" | jq -r '.target_assertion_id')
  expected=$(printf '%s' "$row" | jq -r '.expected_negative_failure')
  search=$(printf '%s' "$row" | jq -r '.search')
  replacement=$(printf '%s' "$row" | jq -r '.replacement')
  mutated=$ROOT/$file
  case "$mutated" in "$ROOT"/*) ;; *) echo "COULD_NOT_OBSERVE: $name names a file outside the worktree" >&2; exit 2 ;; esac
  [ -f "$mutated" ] || { echo "COULD_NOT_OBSERVE: $name protection file is absent" >&2; exit 2; }

  baseline=$(bash "$ROOT/$suite" 2>&1); baseline_rc=$?
  [ "$baseline_rc" -eq 0 ] || { echo "COULD_NOT_OBSERVE: $name baseline failed" >&2; exit 2; }
  original_hash=$(git hash-object "$mutated") || exit 2
  backup=$(mktemp "$mutated.recurrence.XXXXXX") || exit 2
  cp "$mutated" "$backup" || exit 2
  occurrences=$(SEARCH=$search perl -0ne '$n += () = /\Q$ENV{SEARCH}\E/g; END { print $n + 0 }' "$mutated")
  [ "$occurrences" -eq 1 ] || { echo "COULD_NOT_OBSERVE: $name mutation target matched $occurrences times" >&2; exit 2; }
  SEARCH=$search REPLACEMENT=$replacement perl -0pi -e 's/\Q$ENV{SEARCH}\E/$ENV{REPLACEMENT}/' "$mutated" || exit 2
  mutated_hash=$(git hash-object "$mutated") || exit 2
  [ "$mutated_hash" != "$original_hash" ] || { echo "COULD_NOT_OBSERVE: $name mutation did not alter its named protection" >&2; exit 2; }
  patch=$(git -C "$ROOT" diff -- "$file")
  [ -n "$patch" ] || { echo "COULD_NOT_OBSERVE: $name produced no re-executable patch" >&2; exit 2; }

  negative=$(bash "$ROOT/$suite" 2>&1); negative_rc=$?
  [ "$negative_rc" -ne 0 ] || { echo "COULD_NOT_OBSERVE: $name target assertion stayed green" >&2; exit 2; }
  printf '%s\n' "$negative" | grep -Fq "$expected" \
    || { echo "COULD_NOT_OBSERVE: $name failed for an unrelated reason; expected $expected" >&2; exit 2; }
  restore_current || { echo "COULD_NOT_OBSERVE: $name restoration hash did not match" >&2; exit 2; }
  confirm=$(bash "$ROOT/$suite" 2>&1); confirm_rc=$?
  [ "$confirm_rc" -eq 0 ] || { echo "COULD_NOT_OBSERVE: $name did not return to baseline" >&2; exit 2; }

  tmp=$(mktemp "$results.XXXXXX") || exit 2
  jq --arg case "$name" --arg protection "$file:$location" --arg assertion "$assertion" \
    --arg mutation "$patch" --arg expected "$expected" --arg observed "$negative" \
    --arg commit "$candidate" '. + [{case:$case,protection:$protection,target_assertion_id:$assertion,
      mutation:$mutation,mutation_verified:true,baseline_pass:true,expected_negative_failure:$expected,
      observed_negative_failure:$observed,failure_matches_expected:true,restored:true,confirm_pass:true,
      candidate_commit:$commit}]' "$results" > "$tmp" || exit 2
  mv "$tmp" "$results" || exit 2
done < <(jq -c '.[]' "$SPEC")

[ -z "$ONLY" ] || [ "$(jq --arg c "$ONLY" '[.[] | select(.case == $c)] | length' "$results")" -eq 1 ] \
  || { echo "COULD_NOT_OBSERVE: unknown case $ONLY" >&2; exit 2; }
[ -n "$ONLY" ] || [ "$(jq 'length' "$results")" -eq 29 ] \
  || { echo "COULD_NOT_OBSERVE: not every required case produced evidence" >&2; exit 2; }
mv "$results" "$OUT" || exit 2
results=
trap - EXIT HUP INT TERM
printf 'wrote %s\n' "$OUT"
