#!/usr/bin/env bash
set -u

ROOT=${FM_REVIEW_RECURRENCE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
SPEC=${FM_REVIEW_RECURRENCE_SPEC:-$ROOT/tests/review-control-mutations.json}
OUT=${FM_REVIEW_RECURRENCE_OUT:-$ROOT/docs/verification/review-control-recurrence-evidence.json}
TMP_PARENT=${FM_REVIEW_RECURRENCE_TMP:-${TMPDIR:-/tmp}/fm-review-recurrence}
ONLY=

if [ "${1:-}" = --case ]; then
  [ "$#" -eq 2 ] || { echo "error: --case requires one exact case name" >&2; exit 2; }
  ONLY=$2
elif [ "$#" -ne 0 ]; then
  echo "error: usage: fm-review-recurrence.sh [--case <exact-case-name>]" >&2
  exit 2
fi

could_not_observe() { echo "COULD_NOT_OBSERVE: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || could_not_observe "jq is unavailable"
command -v git >/dev/null 2>&1 || could_not_observe "git is unavailable"
[ -f "$SPEC" ] || could_not_observe "mutation specification is absent"
[ "$(git -C "$ROOT" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || could_not_observe "source is not a git checkout"
git_dir=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null) || could_not_observe "git directory is unreadable"
common_dir=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || could_not_observe "git common directory is unreadable"
[ "$git_dir" != "$common_dir" ] || could_not_observe "recurrence execution refuses the primary checkout"
[ -z "$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all)" ] || could_not_observe "recurrence execution requires a clean candidate"

candidate=$(git -C "$ROOT" rev-parse HEAD) || could_not_observe "candidate commit is unreadable"
count=$(jq 'length' "$SPEC") || could_not_observe "mutation specification is invalid"
[ "$count" -eq 38 ] || could_not_observe "expected 38 mutation specifications, found $count"
mkdir -p "$TMP_PARENT" || could_not_observe "temporary parent cannot be created"
run_root=$(mktemp -d "$TMP_PARENT/run.XXXXXX") || could_not_observe "temporary directory cannot be created"
workspace=$run_root/candidate
results=$run_root/results.json
cleanup() { rm -rf "$run_root"; }
trap cleanup EXIT HUP INT TERM
git clone --quiet --no-hardlinks "$ROOT" "$workspace" || could_not_observe "disposable local clone failed"
git -C "$workspace" checkout --quiet --detach "$candidate" || could_not_observe "candidate checkout failed"
[ "$(git -C "$workspace" rev-parse HEAD)" = "$candidate" ] || could_not_observe "disposable clone does not match pinned candidate"
[ "$(git -C "$workspace" rev-parse --git-common-dir)" = .git ] || could_not_observe "disposable workspace shares repository administration"
printf '[]\n' > "$results"

while IFS= read -r row; do
  name=$(printf '%s' "$row" | jq -r '.case')
  [ -z "$ONLY" ] || [ "$name" = "$ONLY" ] || continue
  file=$(printf '%s' "$row" | jq -r '.file')
  location=$(printf '%s' "$row" | jq -r '.location')
  assertion_command=$(printf '%s' "$row" | jq -r '.assertion_command | @sh')
  assertion=$(printf '%s' "$row" | jq -r '.target_assertion_id')
  expected=$(printf '%s' "$row" | jq -r '.expected_negative_failure')
  finding=$(printf '%s' "$row" | jq -r '.finding')
  search=$(printf '%s' "$row" | jq -r '.search')
  replacement=$(printf '%s' "$row" | jq -r '.replacement')
  [ -n "$finding" ] && [ -n "$assertion" ] && [ -n "$expected" ] || could_not_observe "$name has an incomplete causal specification"
  case "$file" in /*|../*|*/../*|*/..) could_not_observe "$name names a protection outside the clone" ;; esac
  mutated=$workspace/$file
  [ -f "$mutated" ] || could_not_observe "$name protection file is absent"

  git -C "$workspace" reset --quiet --hard "$candidate" || could_not_observe "$name could not reset to its pinned base"
  git -C "$workspace" clean -qfdx || could_not_observe "$name could not clean its disposable base"
  [ "$(git -C "$workspace" rev-parse HEAD)" = "$candidate" ] || could_not_observe "$name base identity changed"
  baseline=$(cd "$workspace" && eval "set -- $assertion_command; \"\$@\"" 2>&1); baseline_rc=$?
  [ "$baseline_rc" -eq 0 ] || could_not_observe "$name baseline assertion did not pass"
  printf '%s\n' "$baseline" | grep -Fqx "FM_RECURRENCE_ASSERTION_EXECUTED id=$assertion result=PASS" \
    || could_not_observe "$name baseline did not prove the targeted assertion executed"

  occurrences=$(SEARCH=$search perl -0ne '$n += () = /\Q$ENV{SEARCH}\E/g; END { print $n + 0 }' "$mutated")
  [ "$occurrences" -eq 1 ] || could_not_observe "$name mutation target matched $occurrences times"
  before=$(git -C "$workspace" hash-object "$mutated") || could_not_observe "$name protection hash is unreadable"
  SEARCH=$search REPLACEMENT=$replacement perl -0pi -e 's/\Q$ENV{SEARCH}\E/$ENV{REPLACEMENT}/' "$mutated" || could_not_observe "$name mutation failed"
  after=$(git -C "$workspace" hash-object "$mutated") || could_not_observe "$name mutated hash is unreadable"
  [ "$before" != "$after" ] || could_not_observe "$name mutation did not alter its named protection"
  changed=$(git -C "$workspace" diff --name-only)
  [ "$changed" = "$file" ] || could_not_observe "$name mutation escaped its named protection file"
  patch=$(git -C "$workspace" diff -- "$file")
  [ -n "$patch" ] || could_not_observe "$name produced no re-executable patch"

  negative=$(cd "$workspace" && eval "set -- $assertion_command; \"\$@\"" 2>&1); negative_rc=$?
  [ "$negative_rc" -ne 0 ] || could_not_observe "$name target assertion stayed green"
  printf '%s\n' "$negative" | grep -Fqx "FM_RECURRENCE_ASSERTION_EXECUTED id=$assertion result=FAIL failure=$expected" \
    || could_not_observe "$name target failed with an unexpected identity or did not execute"

  git -C "$workspace" reset --quiet --hard "$candidate" || could_not_observe "$name restoration reset failed"
  git -C "$workspace" clean -qfdx || could_not_observe "$name restoration clean failed"
  [ -z "$(git -C "$workspace" status --porcelain=v1 --untracked-files=all)" ] || could_not_observe "$name restoration left dirty bytes"
  [ "$(git -C "$workspace" hash-object "$workspace/$file")" = "$before" ] || could_not_observe "$name restoration hash did not match"
  confirm=$(cd "$workspace" && eval "set -- $assertion_command; \"\$@\"" 2>&1); confirm_rc=$?
  [ "$confirm_rc" -eq 0 ] || could_not_observe "$name did not return to baseline"
  printf '%s\n' "$confirm" | grep -Fqx "FM_RECURRENCE_ASSERTION_EXECUTED id=$assertion result=PASS" \
    || could_not_observe "$name confirmation did not prove the targeted assertion executed"

  tmp=$results.tmp
  jq --arg case "$name" --arg protection "$file:$location" --arg assertion "$assertion" --arg mutation "$patch" \
    --arg expected "$expected" --arg observed "$negative" --arg commit "$candidate" '. + [{case:$case,
      protection:$protection,target_assertion_id:$assertion,mutation:$mutation,mutation_verified:true,
      baseline_pass:true,expected_negative_failure:$expected,observed_negative_failure:$observed,
      failure_matches_expected:true,restored:true,confirm_pass:true,candidate_commit:$commit}]' "$results" > "$tmp" || exit 2
  mv "$tmp" "$results" || exit 2
done < <(jq -c '.[]' "$SPEC")

wanted=38
[ -z "$ONLY" ] || wanted=1
[ "$(jq 'length' "$results")" -eq "$wanted" ] || could_not_observe "not every requested case produced evidence"
mkdir -p "$(dirname "$OUT")" || could_not_observe "evidence directory cannot be created"
cp "$results" "$OUT" || could_not_observe "evidence artifact cannot be written"
printf 'wrote %s\n' "$OUT"
