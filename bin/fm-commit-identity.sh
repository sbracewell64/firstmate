#!/usr/bin/env bash
# fm-commit-identity.sh - bind the authoritative production commit identity into
# every commit path this fleet can reach, BEFORE a production commit object
# exists, and refuse when it cannot be established.
#
# The failure this prevents, measured 2026-09-01: the no-mistakes gate repository
# carries no repository-local git identity and the daemon's environment names
# none, so every commit the pipeline's review, document, CI-fix and fixer stages
# created fell through to the machine's GLOBAL git identity and reached a real
# remote as `Test <test@example.com>`. The same branch's own worktree commits
# were correct, because the checkout DOES carry a local identity - which is
# exactly why correct and defective provenance alternated inside one branch and
# no repository-static explanation fitted.
#
# bin/fm-commit-identity-lib.sh owns the reasoning, the channel precedence, and
# the honest limits. docs/verification/production-commit-provenance.md holds the
# dated evidence. There is no identity registry here: the authoritative identity
# is the one config/publication-identity.json already declares per venue, read
# through its existing owner.
#
# Usage:
#   fm-commit-identity.sh bind  [<checkout>]   install and verify the binding
#   fm-commit-identity.sh check [<checkout>]   read-only verdict, installs nothing
#   fm-commit-identity.sh env   [<checkout>]   print exports for eval, nothing else
#   fm-commit-identity.sh --help
#
# `bind` is what a production pipeline run must pass before it may start. It
# installs the policy's author and committer as repository-local identity in BOTH
# the checkout (covering commits this fleet's own workers make) and the
# no-mistakes gate repository the pipeline commits in (covering every stage the
# daemon runs), re-observes each one, and reports what it could not establish.
#
# Exit status, three-valued and never folded:
#   0  bound      the authoritative identity is installed and re-observed in
#                 every reachable channel
#   1  refused    a channel contradicts the binding, or the policy states no
#                 usable identity for this venue - do not create commits
#   2  unobserved a channel could not be read at all, so whether the binding
#                 holds is UNKNOWN - which is not a pass
#  64  usage
#
# Environment:
#   FM_HOME               operational home (default: repo root)
#   FM_CONFIG_OVERRIDE    config dir holding publication-identity.json
#   FM_COMMIT_IDENTITY_NM_TIMEOUT  seconds bounding the `no-mistakes status`
#                                  read that discovers the gate repository (20)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
NM_TIMEOUT="${FM_COMMIT_IDENTITY_NM_TIMEOUT:-20}"

# shellcheck source=bin/fm-outbound-artifact-lib.sh
. "$SCRIPT_DIR/fm-outbound-artifact-lib.sh"
# shellcheck source=bin/fm-landing-authorization-lib.sh
. "$SCRIPT_DIR/fm-landing-authorization-lib.sh"
# shellcheck source=bin/fm-publication-seam-lib.sh
. "$SCRIPT_DIR/fm-publication-seam-lib.sh"
# shellcheck source=bin/fm-task-base-lib.sh
. "$SCRIPT_DIR/fm-task-base-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-commit-identity-lib.sh
. "$SCRIPT_DIR/fm-commit-identity-lib.sh"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; $d'; }

say() { printf '%s\n' "$*"; }
refuse() { printf '%s: %s\n' "${1:-REFUSED}" "${2:-}" >&2; }

# The venue this checkout publishes to, normalized by the owner that already
# decides venue identity everywhere else, so the key looked up here is the same
# key the publication seam binds an authority to.
resolve_venue() {  # <checkout>
  local checkout=${1:-} url safe identity
  url=$(git --no-optional-locks -C "$checkout" remote get-url --push origin 2>/dev/null) \
    || url=$(git --no-optional-locks -C "$checkout" remote get-url origin 2>/dev/null) \
    || return 1
  [ -n "$url" ] || return 1
  safe=$(task_base_remote_safe_url "$url" 2>/dev/null) || safe=$url
  identity=$(task_base_venue_identity_alias "$safe" 2>/dev/null) \
    || identity=$(task_base_venue_identity "$safe" 2>/dev/null) \
    || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity"
}

VERB=${1:-}
case "$VERB" in
  -h | --help | help | '') usage; exit 0 ;;
  bind | check | env) shift ;;
  *) refuse USAGE "unknown verb '$VERB'"; exit 64 ;;
esac

CHECKOUT=${1:-.}
if ! git --no-optional-locks -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1; then
  refuse USAGE "'$CHECKOUT' is not a git repository"
  exit 64
fi

VENUE=$(resolve_venue "$CHECKOUT" || true)
fm_commit_identity_resolve "$CONFIG" "$VENUE"
RESOLVED=$?
if [ "$RESOLVED" -ne 0 ]; then
  refuse "$FM_COMMIT_IDENTITY_TOKEN" "$FM_COMMIT_IDENTITY_REASON"
  exit "$RESOLVED"
fi
if [ "$VERB" = env ]; then
  fm_commit_identity_env_block
  exit 0
fi

# The environment this command was invoked in is the environment the worker's own
# `git commit` will run in, so an identity variable found here is not somebody
# else's problem: it outranks every binding below and would silently win.
if OVERRIDES=$(fm_commit_identity_env_overrides); then
  refuse "$FM_CI_TOKEN_AMBIENT_OVERRIDE" \
    "this environment sets an identity variable that outranks the binding, so a commit made here would carry it instead: $(printf '%s' "$OVERRIDES" | tr '\n' ' ')"
  exit 1
fi

STATUS=0
say "venue:     $VENUE"
say "policy:    generation ${FM_COMMIT_IDENTITY_GENERATION:-<unstated>}"
say "author:    $FM_COMMIT_IDENTITY_AUTHOR"
say "committer: $FM_COMMIT_IDENTITY_COMMITTER"

# --- the checkout: where this fleet's own workers commit ---------------------

report_channel() {  # <label> <repo>
  local label=${1:-} repo=${2:-} seen_a seen_c
  seen_a=$(fm_commit_identity_effective "$repo" author) || {
    say "$label: UNOBSERVED - git could not report the identity it would use in $repo"
    return 2
  }
  seen_c=$(fm_commit_identity_effective "$repo" committer) || {
    say "$label: UNOBSERVED - git could not report the committer identity it would use in $repo"
    return 2
  }
  if [ "$seen_a" = "$FM_COMMIT_IDENTITY_AUTHOR" ] && [ "$seen_c" = "$FM_COMMIT_IDENTITY_COMMITTER" ]; then
    say "$label: bound - $seen_a"
    return 0
  fi
  say "$label: NOT BOUND - would commit as author $seen_a / committer $seen_c"
  return 1
}

bind_channel() {  # <label> <repo>
  local label=${1:-} repo=${2:-} rc=0
  fm_commit_identity_install_repo "$repo" || rc=$?
  case $rc in
    0) say "$label: bound - $FM_COMMIT_IDENTITY_AUTHOR" ; return 0 ;;
    1) say "$label: REFUSED - the identity could not be written into $repo" ; return 1 ;;
    3) say "$label: REFUSED $FM_COMMIT_IDENTITY_TOKEN - $FM_COMMIT_IDENTITY_REASON" ; return 1 ;;
    *) say "$label: UNVERIFIED - the identity was written into $repo but git does not report it back" ; return 1 ;;
  esac
}

if [ "$VERB" = bind ]; then
  bind_channel "checkout " "$CHECKOUT" || STATUS=1
else
  report_channel "checkout " "$CHECKOUT" || STATUS=$?
fi

# --- the gate repository: where the pipeline's stages commit -----------------

fm_commit_identity_gate "$CHECKOUT" "$NM_TIMEOUT" || true
GATE=$FM_COMMIT_IDENTITY_GATE
if [ "$FM_COMMIT_IDENTITY_GATE_STATE" = uninitialized ]; then
  say "gate:      not applicable - the pipeline is not initialized for this checkout, so no pipeline stage creates commit objects here"
elif [ -z "$GATE" ]; then
  say "gate:      UNOBSERVED - the pipeline did not report a gate repository for this checkout, so whether its stages would commit under the authoritative identity is unknown"
  [ "$STATUS" -eq 1 ] || STATUS=2
else
  say "gate:      $GATE"
  if [ "$VERB" = bind ]; then
    bind_channel "gate     " "$GATE" || STATUS=1
  else
    report_channel "gate     " "$GATE"
    RC=$?
    if [ "$RC" -eq 1 ]; then
      STATUS=1
    elif [ "$RC" -ne 0 ] && [ "$STATUS" -ne 1 ]; then
      STATUS=2
    fi
  fi

  # The one channel this fleet can read but never set. A daemon carrying an
  # identity variable outranks the gate binding just written, so finding one is a
  # refusal; finding nothing to read is could-not-observe and not a clean bill.
  NM_ROOT=$(dirname "$(dirname "$GATE")")
  DPID=$(fm_commit_identity_daemon_pid "$NM_ROOT" || true)
  if [ -z "$DPID" ]; then
    say "daemon:    UNOBSERVED - no running pipeline daemon was identifiable under $NM_ROOT, so its environment could not be checked against the binding"
    [ "$STATUS" -eq 1 ] || STATUS=2
  else
    DENV=$(fm_commit_identity_daemon_env "$DPID")
    case $? in
      0) say "daemon:    clean - pid $DPID sets no identity variable that would outrank the gate binding" ;;
      1)
        say "daemon:    REFUSED - pid $DPID sets $(printf '%s' "$DENV" | tr '\n' ' ') which outranks the gate binding, so its commits would carry that identity"
        STATUS=1
        ;;
      *)
        say "daemon:    UNOBSERVED - the environment of pid $DPID could not be read, so whether it overrides the gate binding is unknown"
        [ "$STATUS" -eq 1 ] || STATUS=2
        ;;
    esac
  fi
fi

case $STATUS in
  0) say "verdict:   $FM_CI_TOKEN_BOUND - every reachable production commit path resolves the authoritative identity" ;;
  1) say "verdict:   REFUSED - do not create production commits until the channel above is repaired" ;;
  *) say "verdict:   COULD-NOT-OBSERVE - a production commit path could not be shown to carry the authoritative identity, which is not a pass" ;;
esac
exit "$STATUS"
