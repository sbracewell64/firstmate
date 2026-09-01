# shellcheck shell=bash
# fm-commit-identity-lib.sh - the single owner of ONE question, asked before any
# production commit OBJECT exists: which author and committer will this commit
# carry, and is that identity BOUND from the authoritative production policy
# rather than whatever the committing process happened to inherit?
#
# Source it; it defines and runs nothing on its own:
#   # shellcheck source=bin/fm-commit-identity-lib.sh
#   . "$SCRIPT_DIR/fm-commit-identity-lib.sh"
#
# It reads the identity registry through bin/fm-publication-seam-lib.sh, so
# source that library's own prerequisites first, exactly as bin/fm-publication-
# guard.sh does. There is deliberately NO second identity registry here: the
# authoritative production identity is the one config/publication-identity.json
# already declares per venue, and this file adds the half that file's owner never
# had - INSTALLING that identity where a commit will resolve it, and refusing
# before object creation when it cannot.
#
# WHY THIS EXISTS.
#
# bin/fm-publication-seam-lib.sh OBSERVES the author and committer at the exact
# head immediately before a push, and refuses a placeholder identity. That check
# is correct and stays. It is also, on its own, too late and too narrow:
#
#   1. It runs at publication. By then the contaminated commit object exists, is
#      immutable, and is already the thing every later reader will cite.
#   2. It only covers pushes FIRSTMATE ITSELF performs. The no-mistakes pipeline
#      creates durable production commits inside its own gate repository and
#      pushes them from there, so nothing firstmate owns stood between an ambient
#      identity and a published production commit.
#
# The measured failure this closes (2026-09-01, docs/verification/production-
# commit-provenance.md holds the evidence): the gate repository no-mistakes
# commits in carries NO repository-local identity, and the daemon's environment
# sets no GIT_AUTHOR_*/GIT_COMMITTER_*, so every commit its review, document,
# CI-fix and fixer stages created fell through to the machine's GLOBAL git
# identity. Where that global identity was git's own worked example, real
# production commits reached a real remote as `Test <test@example.com>`.
#
# The same run's own worktree commits were correct, which is exactly why the
# selector stayed hidden: the checkout carries a repository-local identity that
# masks the poisoned global, and the gate repository does not. Correct and
# defective provenance therefore ALTERNATE inside one branch, and no
# repository-static or branch-static explanation fits.
#
# WHAT "BOUND" MEANS HERE, precisely, because git has more than one selector.
#
# Git resolves committing identity in this order, strongest first:
#
#   GIT_AUTHOR_NAME/EMAIL, GIT_COMMITTER_NAME/EMAIL  (environment)
#   repository-local config
#   global config, then system config
#
# So a binding is only as strong as the strongest channel it controls:
#
#   - For a process THIS FLEET runs, the environment is available and is the
#     strongest channel, so the identity is exported there.
#   - For the no-mistakes daemon, whose environment was fixed when it started
#     and which this fleet may not restart, the strongest channel available is
#     the gate repository's own local config. The tool exposes no commit-identity
#     configuration to declare it to instead, which is filed upstream as
#     kunchenguid/no-mistakes#924. That beats the global config the
#     defect came through, and it is the lever git provides for "this repository
#     commits as this identity" without changing the tool.
#
# Because that second binding is NOT the strongest channel in absolute terms,
# the daemon's environment is OBSERVED rather than assumed: a daemon carrying an
# identity variable would still override the config binding, and that is a
# refusal, not a silence. Where that environment cannot be read at all the answer
# is could-not-observe - a third value, never folded into either of the others.
#
# WHAT THIS FILE DOES NOT OWN.
#
# It does not decide whether a head may be published or landed; the publication
# and landing seams own that and are unchanged. It does not create commits. It
# makes no claim over a `git commit` typed by a human, a provider web UI, or a
# no-mistakes daemon that was never bound through here - claiming otherwise
# would be the wrong-subject failure this fleet has a vocabulary for
# (.agents/skills/wrong-subject/SKILL.md). Its honest scope is: every production
# commit path this fleet can reach resolves the authoritative identity, or the
# path refuses before a commit object exists.

if [ -n "${FM_COMMIT_IDENTITY_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_COMMIT_IDENTITY_LIB_SOURCED=1

# --- verdict vocabulary ------------------------------------------------------
#
# Three values, never two. A refusal and an unobservable are different facts
# with different repairs, so they are different tokens and different statuses.

# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
FM_COMMIT_IDENTITY_STATUS_BOUND=0
# shellcheck disable=SC2034
FM_COMMIT_IDENTITY_STATUS_REFUSED=1
# shellcheck disable=SC2034
FM_COMMIT_IDENTITY_STATUS_UNOBSERVED=2

# shellcheck disable=SC2034  # contract constants consumed by sourcing callers
FM_CI_TOKEN_BOUND=FM_CI_BOUND_EXACT
# shellcheck disable=SC2034
FM_CI_TOKEN_POLICY_UNREADABLE=FM_CI_POLICY_UNREADABLE
# shellcheck disable=SC2034
FM_CI_TOKEN_POLICY_ABSENT=FM_CI_POLICY_ABSENT
# shellcheck disable=SC2034
FM_CI_TOKEN_VENUE_UNGOVERNED=FM_CI_VENUE_UNGOVERNED
# shellcheck disable=SC2034
FM_CI_TOKEN_VENUE_UNOBSERVED=FM_CI_VENUE_UNOBSERVED
# shellcheck disable=SC2034
FM_CI_TOKEN_UNSTATED=FM_CI_IDENTITY_UNSTATED
# shellcheck disable=SC2034
FM_CI_TOKEN_PLACEHOLDER=FM_CI_IDENTITY_PLACEHOLDER
# shellcheck disable=SC2034
FM_CI_TOKEN_MALFORMED=FM_CI_IDENTITY_MALFORMED
# shellcheck disable=SC2034
FM_CI_TOKEN_DISTINCT=FM_CI_IDENTITY_DISTINCT_UNSUPPORTED
# shellcheck disable=SC2034
FM_CI_TOKEN_AMBIENT_OVERRIDE=FM_CI_AMBIENT_OVERRIDE
# shellcheck disable=SC2034
FM_CI_TOKEN_GATE_UNOBSERVED=FM_CI_GATE_UNOBSERVED
# shellcheck disable=SC2034
FM_CI_TOKEN_INSTALL_FAILED=FM_CI_INSTALL_FAILED
# shellcheck disable=SC2034
FM_CI_TOKEN_UNVERIFIED=FM_CI_BINDING_UNVERIFIED
# shellcheck disable=SC2034
FM_CI_TOKEN_DAEMON_OVERRIDE=FM_CI_DAEMON_ENV_OVERRIDE
# shellcheck disable=SC2034
FM_CI_TOKEN_DAEMON_UNOBSERVED=FM_CI_DAEMON_ENV_UNOBSERVED

# The environment variables that outrank a repository-local identity binding.
# GIT_CONFIG_* are here because they can REPLACE the config files the binding was
# written into, which defeats it just as completely as naming an identity does.
FM_CI_OVERRIDING_ENV='GIT_AUTHOR_NAME
GIT_AUTHOR_EMAIL
GIT_COMMITTER_NAME
GIT_COMMITTER_EMAIL
GIT_CONFIG_GLOBAL
GIT_CONFIG_SYSTEM
GIT_CONFIG_COUNT
EMAIL'

FM_COMMIT_IDENTITY_TOKEN=
FM_COMMIT_IDENTITY_REASON=
FM_COMMIT_IDENTITY_AUTHOR=
FM_COMMIT_IDENTITY_COMMITTER=
FM_COMMIT_IDENTITY_VENUE=
FM_COMMIT_IDENTITY_GENERATION=

fm_commit_identity_set() {  # <token> <reason>
  # shellcheck disable=SC2034  # read by sourcing callers, not inside this file
  FM_COMMIT_IDENTITY_TOKEN=${1:-}
  # shellcheck disable=SC2034
  FM_COMMIT_IDENTITY_REASON=${2:-}
}

# --- identity shape ----------------------------------------------------------
#
# `Name <email>` split once, here, so no caller re-derives it. A value that does
# not parse is MALFORMED and refuses: an identity nobody can decompose into the
# two fields git actually stores has not been stated, it has been mistyped, and
# committing under half of it is worse than not committing.

FM_COMMIT_IDENTITY_NAME=
FM_COMMIT_IDENTITY_EMAIL=

fm_commit_identity_split() {  # <identity> -> sets NAME and EMAIL
  local id=${1-} name email
  FM_COMMIT_IDENTITY_NAME=
  FM_COMMIT_IDENTITY_EMAIL=
  case $id in
    *'<'*'>') ;;
    *) return 1 ;;
  esac
  # Control characters would be carried straight into a commit header, where
  # they can forge a field boundary, so they are refused rather than escaped.
  case $id in
    *[[:cntrl:]]*) return 1 ;;
  esac
  name=${id%%<*}
  name=${name%"${name##*[![:space:]]}"}
  name=${name#"${name%%[![:space:]]*}"}
  email=${id#*<}
  email=${email%%>*}
  case $name in
    '' | *'<'* | *'>'*) return 1 ;;
  esac
  case $email in
    '' | *'<'* | *'>'* | *[[:space:]]*) return 1 ;;
  esac
  FM_COMMIT_IDENTITY_NAME=$name
  FM_COMMIT_IDENTITY_EMAIL=$email
  return 0
}

# --- the authoritative identity, RESOLVED and not accepted -------------------
#
# Resolution is total: every path sets a token, and only one of them is the
# allowing token. The policy's own readability is settled by its owner, and an
# absent policy is deliberately NOT the same answer as a policy that omits this
# venue - a home that declared no publication governance at all has said
# something different from a home that governs three venues and not this one.

fm_commit_identity_resolve() {  # <config-dir> <venue>
  local config=${1:-} venue=${2:-} axis raw
  FM_COMMIT_IDENTITY_AUTHOR=
  FM_COMMIT_IDENTITY_COMMITTER=
  # shellcheck disable=SC2034
  FM_COMMIT_IDENTITY_VENUE=$venue
  FM_COMMIT_IDENTITY_GENERATION=

  if [ -z "$venue" ]; then
    fm_commit_identity_set "$FM_CI_TOKEN_VENUE_UNOBSERVED" \
      "the venue this checkout publishes to could not be read from its remote, so which declared identity governs it is unknown"
    return 2
  fi

  fm_pub_seam_policy_read "$config"
  case "$FM_PUB_SEAM_POLICY_STATE" in
    unreadable)
      fm_commit_identity_set "$FM_CI_TOKEN_POLICY_UNREADABLE" \
        "the publication identity policy exists but could not be read as JSON, so the identity it declares for $venue is unknown"
      return 2
      ;;
    absent)
      fm_commit_identity_set "$FM_CI_TOKEN_POLICY_ABSENT" \
        "this home declares no publication identity policy, so no authoritative production identity exists to bind for $venue"
      return 1
      ;;
  esac

  if ! fm_pub_seam_policy_venue_governed "$venue"; then
    fm_commit_identity_set "$FM_CI_TOKEN_VENUE_UNGOVERNED" \
      "the publication identity policy names other venues but not $venue, so the identity its production commits must carry is unstated"
    return 1
  fi

  FM_COMMIT_IDENTITY_GENERATION=$(fm_pub_seam_policy_get '.generation // ""')

  for axis in author committer; do
    raw=$(fm_pub_seam_policy_identity "$venue" "$axis")
    if [ -z "$raw" ]; then
      fm_commit_identity_set "$FM_CI_TOKEN_UNSTATED" \
        "the policy governs $venue but leaves its $axis identity unstated, and an unstated axis at a load-bearing admission is could-not-observe rather than a weaker promise"
      return 1
    fi
    if fm_pub_seam_identity_is_placeholder "$raw"; then
      fm_commit_identity_set "$FM_CI_TOKEN_PLACEHOLDER" \
        "the policy's $axis identity for $venue is the placeholder '$raw', which is never a governed party whatever a policy says"
      return 1
    fi
    if ! fm_commit_identity_split "$raw"; then
      fm_commit_identity_set "$FM_CI_TOKEN_MALFORMED" \
        "the policy's $axis identity for $venue ('$raw') does not parse as 'Name <email>', so it cannot be installed as the two fields a commit stores"
      return 1
    fi
    case $axis in
      author) FM_COMMIT_IDENTITY_AUTHOR=$raw ;;
      committer) FM_COMMIT_IDENTITY_COMMITTER=$raw ;;
    esac
  done

  if [ "$FM_COMMIT_IDENTITY_AUTHOR" != "$FM_COMMIT_IDENTITY_COMMITTER" ]; then
    fm_commit_identity_set "$FM_CI_TOKEN_DISTINCT" \
      "the policy declares distinct author and committer identities for $venue, but repository-local git identity provides one pair for both axes, so neither axis may be silently substituted"
    return 1
  fi

  fm_commit_identity_set "$FM_CI_TOKEN_BOUND" \
    "policy generation ${FM_COMMIT_IDENTITY_GENERATION:-<unstated>} declares author and committer for $venue"
  return 0
}

# --- ambient channels that outrank the binding -------------------------------
#
# Named, not counted: the caller has to repair a specific variable, and a bare
# "your environment is dirty" makes that a search. A variable already holding the
# authoritative value is NOT an override - it is the binding, arrived at early -
# so it is reported clean rather than refused, which keeps `bind` idempotent
# under its own exported environment.

fm_commit_identity_env_overrides() {  # -> prints offending NAME=VALUE lines
  local var value found=1
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    eval "value=\${$var-}"
    [ -n "${value:-}" ] || continue
    case "$var" in
      GIT_AUTHOR_NAME | GIT_COMMITTER_NAME)
        [ "$value" = "$FM_COMMIT_IDENTITY_NAME" ] && continue ;;
      GIT_AUTHOR_EMAIL | GIT_COMMITTER_EMAIL)
        [ "$value" = "$FM_COMMIT_IDENTITY_EMAIL" ] && continue ;;
    esac
    printf '%s=%s\n' "$var" "$value"
    found=0
  done <<< "$FM_CI_OVERRIDING_ENV"
  return $found
}

# What git will ACTUALLY use in this repository once the environment stops
# speaking for it - which is the no-mistakes daemon's measured condition, and the
# condition the config binding has to win in. Scrubbing is the point: verifying
# under the caller's own exported identity would confirm the caller's export and
# credit the answer to the repository, which is the wrong subject.
fm_commit_identity_effective() {  # <git-dir-or-worktree> <author|committer>
  local repo=${1:-} which=${2:-} var out
  case $which in
    author) var=GIT_AUTHOR_IDENT ;;
    committer) var=GIT_COMMITTER_IDENT ;;
    *) return 1 ;;
  esac
  out=$(env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME \
    -u GIT_COMMITTER_EMAIL -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM \
    -u GIT_CONFIG_COUNT -u EMAIL \
    git --no-optional-locks -C "$repo" var "$var" 2>/dev/null) || return 1
  # `git var` appends " <unix-timestamp> <tz>"; the identity is what precedes it.
  printf '%s' "${out%> *}>"
}

# --- installing the binding --------------------------------------------------
#
# Installation is followed by RE-OBSERVATION every time, never by assuming the
# write took. A `git config` that silently lost a lock race, a repository whose
# config is read-only, and a worktree-scoped config extension all produce the
# same thing: a write that returned success and changed nothing git will read.
# Only the re-observation distinguishes those from a real binding.

fm_commit_identity_install_repo() {  # <git-dir-or-worktree>
  local repo=${1:-} seen
  git --no-optional-locks -C "$repo" config --local user.name "$FM_COMMIT_IDENTITY_NAME" 2>/dev/null || return 1
  git --no-optional-locks -C "$repo" config --local user.email "$FM_COMMIT_IDENTITY_EMAIL" 2>/dev/null || return 1
  seen=$(fm_commit_identity_effective "$repo" author) || return 2
  [ "$seen" = "$FM_COMMIT_IDENTITY_AUTHOR" ] || return 2
  seen=$(fm_commit_identity_effective "$repo" committer) || return 2
  [ "$seen" = "$FM_COMMIT_IDENTITY_COMMITTER" ] || return 2
  return 0
}

# The exports a production commit path this fleet runs should carry. The
# environment is git's strongest selector, so where the fleet owns the process it
# uses that channel and does not settle for the weaker one.
fm_commit_identity_env_block() {
  printf 'export GIT_AUTHOR_NAME=%s\n' "$(fm_commit_identity_quote "$FM_COMMIT_IDENTITY_NAME")"
  printf 'export GIT_AUTHOR_EMAIL=%s\n' "$(fm_commit_identity_quote "$FM_COMMIT_IDENTITY_EMAIL")"
  printf 'export GIT_COMMITTER_NAME=%s\n' "$(fm_commit_identity_quote "$FM_COMMIT_IDENTITY_NAME")"
  printf 'export GIT_COMMITTER_EMAIL=%s\n' "$(fm_commit_identity_quote "$FM_COMMIT_IDENTITY_EMAIL")"
}

fm_commit_identity_quote() {  # <value>
  printf "'%s'" "$(printf '%s' "${1-}" | sed "s/'/'\\\\''/g")"
}

# --- the gate repository the pipeline actually commits in --------------------
#
# Asked of the tool rather than reconstructed from its private layout:
# `no-mistakes status` prints the gate repository for this checkout, so the path
# comes from the owner that decides it and keeps working if that layout changes.
# A status that does not name one is could-not-observe - the repository may not
# be initialized, the daemon may be unreachable, or the output may have changed -
# and none of those is "there is no gate to bind".

FM_COMMIT_IDENTITY_GATE_STATE=
FM_COMMIT_IDENTITY_GATE=

# Sets FM_COMMIT_IDENTITY_GATE and FM_COMMIT_IDENTITY_GATE_STATE rather than
# printing, because the state is the point: a caller that captured only stdout
# would run this in a subshell and lose the distinction it exists to make.
fm_commit_identity_gate() {  # <checkout> [<timeout-secs>]
  local checkout=${1:-} secs=${2:-20} out gate
  FM_COMMIT_IDENTITY_GATE=
  FM_COMMIT_IDENTITY_GATE_STATE=unobserved
  out=$(fm_nm_run_checked "$checkout" "$secs" status) || return 1
  gate=$(printf '%s\n' "$out" \
    | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' \
    | sed -n 's/^[[:space:]]*gate:[[:space:]]*\([^[:space:]].*\)$/\1/p' \
    | head -1)
  gate=${gate%"${gate##*[![:space:]]}"}
  if [ -n "$gate" ] && [ -d "$gate" ]; then
    FM_COMMIT_IDENTITY_GATE_STATE=present
    # shellcheck disable=SC2034  # read by callers after this returns
    FM_COMMIT_IDENTITY_GATE=$gate
    return 0
  fi
  # A checkout the pipeline was never set up in has no gate repository, and that
  # is NOT APPLICABLE rather than could-not-observe: no pipeline stage will
  # create a commit object here at all. The two must not share a branch, because
  # every delivery mode that never runs the pipeline would otherwise refuse.
  #
  # Matched on the tool's own words rather than its exit status, which is 0 for
  # this refusal (measured against no-mistakes v1.40.3, 2026-09-01, alongside the
  # same measurement in bin/fm-nm-run-lib.sh).
  # shellcheck disable=SC2034  # read by callers to tell the three states apart
  case $out in
    *'repo not initialized'*) FM_COMMIT_IDENTITY_GATE_STATE=uninitialized ;;
  esac
  return 1
}

# --- the one channel this fleet can observe but not set ----------------------
#
# The daemon's environment outranks the gate repository's config, and this fleet
# may neither set it nor restart the daemon to change it. So it is read, from two
# independent sources, and a variable found there is a REFUSAL rather than a
# note: the binding demonstrably would not hold.
#
# Two sources because they fail for different reasons. /proc is exact and Linux
# only; `ps eww` covers the same question where /proc is absent. Where neither
# answers, the answer is could-not-observe, which is not "clean".

fm_commit_identity_daemon_pid() {  # <nm-root>
  local root=${1:-} pid
  [ -f "$root/daemon.pid" ] || return 1
  pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$root/daemon.pid" | head -1)
  case ${pid:-} in
    '' | *[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

# 0 clean, 1 an overriding variable was found (printed), 2 could not observe.
fm_commit_identity_daemon_env() {  # <pid>
  local pid=${1:-} raw='' var hit=0 line
  if [ -r "/proc/$pid/environ" ]; then
    raw=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || raw=''
  fi
  if [ -z "$raw" ]; then
    raw=$(ps eww "$pid" 2>/dev/null | tr ' ' '\n') || raw=''
  fi
  [ -n "$raw" ] || return 2
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    line=$(printf '%s\n' "$raw" | grep -m1 -e "^$var=." 2>/dev/null) || continue
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    hit=1
  done <<< "$FM_CI_OVERRIDING_ENV"
  [ "$hit" -eq 0 ] || return 1
  return 0
}
