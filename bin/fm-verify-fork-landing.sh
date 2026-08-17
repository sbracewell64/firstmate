#!/usr/bin/env bash
# fm-verify-fork-landing.sh - the bound verifier for the fork-landing LoopSpec.
#
# WHAT IT DECIDES, and only this: for the contribution named by the event key,
# does a pull request exist on the fork, and have that pull request's own checks
# reached a resolved state? That is the whole question. It does not decide
# whether the contribution is good, whether it should merge, or whether anything
# should happen next.
#
# WHY IT IS A LEGITIMATE VERIFIER. A LoopSpec is only genuinely loopable when a
# named verifier can produce different evidence after an iteration because of the
# action that iteration took. That holds here: before the iteration opens the
# fork pull request this reports no pull request and fails; after it does, this
# reports the pull request and its checks. The evidence moves because the action
# moved it, which is exactly the property that distinguishes a loop from mere
# repetition.
#
# It is level l2: deterministic, but reading external evidence (the forge) rather
# than only the local tree. It needs no model, no judgment and no vendor
# diversity, which is why it is preferred while maker/checker vendor separation
# is degraded.
#
# THIS VERIFIER NEVER MERGES. It has no write path at all. The loop it serves
# terminates at ready-for-merge; landing stays a separate act under existing
# authority.
#
# Invocation contract, owned by bin/fm-loopspec.sh verify:
#   --spec <id> --spec-version <n> --event-key <k> --iteration <i>
# The event key is the fork branch name carrying the contribution.
#
# Exit status: 0 pass, 1 fail (ran and rejected), 2 unavailable (could not
# establish the evidence; fail-closed, and never a pass).
#
# Every fact it observes is printed on stdout as one evidence line, and those
# lines become the loop's recorded evidence.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-retrieval-lib.sh
. "$SCRIPT_DIR/fm-retrieval-lib.sh"

REPO="${FM_FORK_REPO:-sbracewell64/firstmate}"
EVENT_KEY=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --event-key) EVENT_KEY=${2:-}; shift 2 ;;
    --spec|--spec-version|--iteration) shift 2 ;;
    *) shift ;;
  esac
done

if [ -z "$EVENT_KEY" ]; then
  printf 'unavailable: no event key supplied, so there is no branch to verify\n'
  exit 2
fi

if ! command -v gh-axi >/dev/null 2>&1; then
  printf 'unavailable: gh-axi is not installed, so forge evidence cannot be read\n'
  exit 2
fi

# Both readers are required now: gh-axi for the check summary, and gh for the
# enumerated pull request read below, because the continuation lives in the
# response headers that the agent-ergonomic wrapper does not expose.
if ! command -v gh >/dev/null 2>&1; then
  printf 'unavailable: gh is not installed, so the open pull requests cannot be enumerated\n'
  exit 2
fi

# The forge is the authority on whether the pull request exists, and this used to
# ask it with `gh-axi pr list --head` and take the first number the listing
# happened to print. That is two mistakes in one line: the listing was never
# enumerated, so "no open pull request" was a negative over an unread universe,
# and the first row is the SOURCE's choice of which pull request this is, not
# this verifier's. bin/fm-control-read.sh enumerates the whole open set, proves
# it did, and matches head.ref by equality rather than by token, because
# "feature/x" occurs as a whole token inside "feature/x/y".
#
# Ambiguity is refused rather than resolved: two open pull requests carrying this
# head are two candidate subjects, and picking either would be a sound reading of
# the wrong one.
# There is no classification annotation here on purpose: routing the read through
# the contract means this line is no longer a direct read for
# bin/fm-retrieval-check.sh to classify, and leaving a stale annotation behind
# would satisfy that check for a future line that went back to calling gh here.
record=$("$SCRIPT_DIR/fm-control-read.sh" \
  endpoint "repos/$REPO/pulls?state=open" \
  --id-field number --text-field head.ref --time-field created_at \
  --identity "$EVENT_KEY" --identity-mode exact --claim latest 2>&1)
status=$?

if ! fm_retrieval_parse "$record"; then
  printf 'unavailable: retrieval returned an unreadable result for %s at head %s\n' \
    "$REPO" "$EVENT_KEY"
  printf 'evidence: %s\n' "$(printf '%s\n' "$record" | tr '\n' ' ')"
  exit 2
fi
retrieval=$FM_RETRIEVAL_COMPLETENESS
matches=$FM_RETRIEVAL_MATCHES
number=$FM_RETRIEVAL_SELECTED_ID

case "$status" in
  0) ;;
  1)
    printf 'fail: no open pull request on %s with head %s (the whole open set was read: %s)\n' \
      "$REPO" "$EVENT_KEY" "$retrieval"
    printf 'evidence: the contribution has not been carried to the fork yet\n'
    exit 1
    ;;
  *)
    printf 'unavailable: could not establish the open pull requests on %s for head %s (retrieval=%s)\n' \
      "$REPO" "$EVENT_KEY" "${retrieval:-unreadable}"
    printf 'evidence: %s\n' "$(printf '%s\n' "$record" | tr '\n' ' ')"
    exit 2
    ;;
esac

if [ "${matches:-0}" != 1 ]; then
  printf 'unavailable: %s open pull requests on %s carry head %s, so the subject is ambiguous\n' \
    "$matches" "$REPO" "$EVENT_KEY"
  exit 2
fi
case "${number:-}" in
  ''|*[!0-9]*)
    printf 'unavailable: the matching pull request on %s for head %s has no usable number\n' \
      "$REPO" "$EVENT_KEY"
    exit 2
    ;;
esac

printf 'evidence: fork pull request %s exists on %s for head %s (open set read completely: %s)\n' \
  "$number" "$REPO" "$EVENT_KEY" "$retrieval"

checks=$(gh-axi pr checks "$number" --repo "$REPO" 2>&1)  # fm-retrieval-audit: complete-source - reconciles the summary's own clauses against its total and refuses when they do not add up, so a partly-read check set is unavailable rather than resolved
status=$?
# `pr checks` exits non-zero when checks are failing, which is a real verdict and
# not an inability to read one. Only an empty read is unavailable.
if [ -z "$checks" ]; then
  printf 'unavailable: could not read the checks for pull request %s\n' "$number"
  exit 2
fi

# Parse the authoritative summary line, never the prose. Counting matches of
# "fail" across the whole listing also matches the summary's own "0 failed" and
# every check whose NAME contains the word, which reaches a plausible verdict for
# entirely the wrong reason.
summary=$(printf '%s\n' "$checks" | sed -n 's/^summary:[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | head -1)
if [ -z "$summary" ]; then
  # A pull request whose checks have not been registered yet reports a different
  # shape entirely. It is unavailable, not resolved: treating "no checks
  # configured" as a resolved empty set would pass a pull request that nothing
  # has examined, which is the exact shape of a verifier that verifies nothing.
  if printf '%s\n' "$checks" | grep -q 'no CI checks configured'; then
    printf 'unavailable: pull request %s has no checks registered yet, so nothing has examined it\n' "$number"
  else
    printf 'unavailable: pull request %s returned no parsable check summary\n' "$number"
  fi
  exit 2
fi

# The summary omits any clause whose count is zero, so an absent clause means
# zero and only an absent TOTAL means the summary could not be read. Requiring
# every clause treated a fully resolved pull request as unreadable; defaulting
# every clause to zero would let a genuinely unreadable summary look resolved.
# The reconciliation below is what makes the difference safe: if the parts do not
# add up to the total, a clause was missed and this refuses rather than guessing.
read_count() {
  local n
  n=$(printf '%s\n' "$summary" | sed -n "s/.*[^0-9]\([0-9][0-9]*\) $1.*/\1/p" | head -1)
  [ -n "$n" ] || n=$(printf '%s\n' "$summary" | sed -n "s/^\([0-9][0-9]*\) $1.*/\1/p" | head -1)
  printf '%s\n' "${n:-0}"
}
passed=$(read_count passed)
failed=$(read_count failed)
pending=$(read_count pending)
total=$(printf '%s\n' "$summary" | sed -n 's/.*[^0-9]\([0-9][0-9]*\) total.*/\1/p' | head -1)
case "${total:-}" in
  ''|*[!0-9]*)
    printf 'unavailable: could not read the total check count from the summary of pull request %s\n' "$number"
    exit 2 ;;
esac
if [ "$((passed + failed + pending))" -ne "$total" ]; then
  printf 'unavailable: check summary of pull request %s does not reconcile (%s passed + %s failed + %s pending != %s total)\n' \
    "$number" "$passed" "$failed" "$pending" "$total"
  exit 2
fi

printf 'evidence: check summary for pull request %s: passed=%s failed=%s pending=%s total=%s\n' \
  "$number" "$passed" "$failed" "$pending" "$total"

if [ "$total" -eq 0 ]; then
  printf 'unavailable: pull request %s reports no checks at all, so nothing was verified\n' "$number"
  exit 2
fi

if [ "$pending" -gt 0 ]; then
  printf 'fail: pull request %s still has %s check(s) in flight, so its state is not yet resolved\n' "$number" "$pending"
  exit 1
fi

# What this pass asserts, exactly: the contribution reached the fork and its
# checks finished. It does NOT assert that they are green, and the failed count
# above is part of the record precisely so this can never be read as a green
# light. Whether a red pull request may land is the merge decision, which this
# loop deliberately never makes.
if [ "$failed" -gt 0 ]; then
  printf 'evidence: NOT GREEN - %s check(s) failed; this pass asserts only that the contribution was carried and its checks resolved\n' "$failed"
fi
printf 'evidence: pull request %s has no checks in flight; the carry is verified and the merge decision has its inputs\n' "$number"
printf 'evidence: verifier made no write of any kind; landing remains a separate act under existing authority\n'
exit 0
