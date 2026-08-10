#!/usr/bin/env bash
# Record a PR-ready task: store one validated canonical pr=<url> and the forge's
# exact pr_head=<sha> when available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# A GitHub pull request URL and a GitLab merge request URL are both accepted,
# including a merge request on a self-hosted GitLab instance.
#
# The request armed is the one that lands in the repository the task's own
# origin pushes to, which is not always the request handed in: where origin
# fetches from one repository and pushes to another, a branch carries both a
# contribution against the fetch remote and the request that lands against the
# push remote. The choice is recorded alongside pr= as pr_role=landing or
# pr_role=contribution-only, the deciding pr_landing_repo=<host>/<path>, and
# pr_contribution=<url> naming a superseded contribution. A landing repository
# that cannot be read, and one carrying more than one open request for the
# branch, refuse instead of arming a watch on a guess.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
"$FM_ROOT/bin/fm-guard.sh" || true

WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)

# Which request lands here. A repository whose origin pushes somewhere other
# than it fetches from carries two requests for one branch: a contribution
# against the fetch remote, which lands on the maintainer's schedule, and the
# request against the push remote, which is the one that lands here. Arming the
# request that was handed in would watch the contribution and miss the landing,
# so the landing repository is read from the task's own repository and the
# choice is recorded with the evidence that decided it. Nothing is inferred: a
# landing repository that cannot be read, and one carrying more than one open
# request for this branch, both refuse rather than pick.
refuse_landing() {
  echo "error: cannot determine which pull request lands for task $ID" >&2
  printf '%s\n' "$1" >&2
  exit 1
}
# The task worktree answers this, and the project clone it was cut from answers
# it identically while outliving it, so a task re-armed after its worktree is
# gone still resolves rather than refusing.
PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
PUSH_URL=
PUSH_SOURCE=
for candidate in "$WT" "$PROJECT"; do
  [ -n "$candidate" ] && [ -d "$candidate" ] || continue
  PUSH_URL=$(cd "$candidate" && git remote get-url --push origin 2>/dev/null) || PUSH_URL=
  if [ -n "$PUSH_URL" ]; then
    PUSH_SOURCE=$candidate
    break
  fi
done
[ -n "$PUSH_URL" ] \
  || refuse_landing "No recorded repository for task $ID has an origin push URL, so the landing repository is unknown."
fm_pr_remote_identity "$PUSH_URL" \
  || refuse_landing "$PUSH_SOURCE pushes to $PUSH_URL, which names no forge repository."
LANDING_REPO="$FM_PR_REMOTE_HOST/$FM_PR_REMOTE_PATH"
PR_ROLE=landing
PR_CONTRIBUTION=
if ! fm_pr_repo_identity_same "$HOST/$PROJECT_PATH" "$LANDING_REPO"; then
  # The handed request is on a different repository than this branch pushes to,
  # so it is a contribution. Its landing counterpart is whichever open request
  # on the landing repository shares this branch.
  [ "$PROVIDER" = github ] \
    || refuse_landing "$URL is not in $LANDING_REPO, where this branch lands, and merge requests on the landing project cannot be enumerated."
  command -v gh >/dev/null 2>&1 \
    || refuse_landing "$URL is not in $LANDING_REPO, where this branch lands, and gh is not on PATH to look for its landing pull request."
  HEAD_BRANCH=$(cd "$PUSH_SOURCE" && gh pr view "$URL" --json headRefName -q .headRefName 2>/dev/null) \
    || refuse_landing "the head branch of $URL could not be read from its forge."
  [ -n "$HEAD_BRANCH" ] \
    || refuse_landing "the head branch of $URL could not be read from its forge."
  LANDING_CANDIDATES=$(cd "$PUSH_SOURCE" \
    && gh pr list --repo "$LANDING_REPO" --head "$HEAD_BRANCH" --state open --json url -q '.[].url' 2>/dev/null) \
    || refuse_landing "open pull requests for $HEAD_BRANCH in $LANDING_REPO could not be listed."
  LANDING_COUNT=$(printf '%s' "$LANDING_CANDIDATES" | grep -c . || true)
  if [ "$LANDING_COUNT" -gt 1 ]; then
    refuse_landing "$LANDING_COUNT open pull requests in $LANDING_REPO share branch $HEAD_BRANCH: $(printf '%s' "$LANDING_CANDIDATES" | tr '\n' ' ')"
  fi
  if [ "$LANDING_COUNT" -eq 0 ]; then
    # Nothing lands here yet, so the contribution is all there is to watch.
    PR_ROLE=contribution-only
    printf 'contribution-only: %s is not in %s, where this branch lands\n' "$URL" "$LANDING_REPO"
  else
    PR_CONTRIBUTION=$URL
    fm_pr_url_parse "$LANDING_CANDIDATES" \
      || refuse_landing "$LANDING_REPO returned $LANDING_CANDIDATES, which is not a pull request URL."
    fm_pr_repo_identity_same "$FM_PR_HOST/$FM_PR_PATH" "$LANDING_REPO" \
      || refuse_landing "$FM_PR_URL was listed for $LANDING_REPO but is not in it."
    URL=$FM_PR_URL
    PROVIDER=$FM_PR_PROVIDER
    HOST=$FM_PR_HOST
    PROJECT_PATH=$FM_PR_PATH
    NUMBER=$FM_PR_NUMBER
    printf 'landing: %s supersedes %s\n' "$URL" "$PR_CONTRIBUTION"
  fi
fi

# pr_head is recorded only when the forge's CLI can supply it. gh exposes the
# head commit as a selectable field; plain glab exposes it only inside its JSON
# output, which would need a JSON processor firstmate does not require, so a
# GitLab task records no pr_head. Both consumers already treat it as optional:
# bin/fm-teardown.sh reads the head from the forge at teardown rather than from
# metadata and falls back to its provider-agnostic content check, and
# bin/fm-review-diff.sh resolves the head from the remote when none is recorded.
PR_HEAD=
if [ "$PROVIDER" = github ] && [ -n "$WT" ] && [ -d "$WT" ] && command -v gh >/dev/null 2>&1; then
  if REMOTE_HEAD=$(cd "$WT" && gh pr view "$URL" --json headRefOid -q .headRefOid 2>/dev/null) \
    && fm_pr_head_valid "$REMOTE_HEAD"; then
    PR_HEAD=$REMOTE_HEAD
  fi
fi

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*|pr_role=*|pr_landing_repo=*|pr_contribution=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
# The landing evidence is written ahead of pr= because fm_pr_metadata_identity_parse
# reads pr= as the start of the canonical identity block and refuses an unknown
# key after it.
printf 'pr_role=%s\n' "$PR_ROLE" >> "$META_TMP" || exit 1
printf 'pr_landing_repo=%s\n' "$LANDING_REPO" >> "$META_TMP" || exit 1
[ -z "$PR_CONTRIBUTION" ] || printf 'pr_contribution=%s\n' "$PR_CONTRIBUTION" >> "$META_TMP" || exit 1
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
printf 'armed: state/%s.check.sh\n' "$ID"
